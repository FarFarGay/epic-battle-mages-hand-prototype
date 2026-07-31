extends Node3D
## ФЛОУ-ФИЛД данжа (референс юзера 2026-07-30: карта делится на клетки, каждая
## указывает направление к игроку). Одна сетка на всех врагов: BFS от отряда раз
## в rebuild_interval — толпа к одной цели читает ОДНО поле, по расчёту на кадр
## вместо пути на каждого агента. Godot-навмеш в данже не используется вовсе
## (один путь навигации, не два).
##
## Подключение: сандбокс делает setup(bounds), каждый тик зовёт set_target
## (центр отряда/Ладья), скелетам выставляет flow_provider = этот узел.
## Скелет спрашивает flow_dir(pos): ZERO = «иди прямо как раньше» (близко к
## цели, вне сетки или поле ещё не готово) — прямой ход остаётся фолбэком.
## Проломы стен (тайник/завал/ворота) обязаны звать refresh_around.

## Размер клетки (м). Крупнее = дешевле BFS, грубее обход углов.
const CELL := 1.2
## Дистанция (в клетках), ближе которой поле молчит — скелет идёт прямо.
const NEAR_STRAIGHT := 2
const UNREACHED := 1 << 30

var rebuild_interval: float = 0.25

var _origin := Vector2.ZERO
var _w: int = 0
var _h: int = 0
var _walk := PackedByteArray()
var _dist := PackedInt32Array()
var _dirx := PackedFloat32Array()
var _dirz := PackedFloat32Array()
var _target := Vector3.INF
var _timer: float = 0.0
var _scanned: bool = false

## 8 соседей: 4 ортогональных + 4 диагональных (диагональ не режет углы —
## проверяются обе ортогональные клетки).
const _NB := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]


func setup(min_x: float, min_z: float, max_x: float, max_z: float) -> void:
	_origin = Vector2(min_x, min_z)
	_w = int(ceilf((max_x - min_x) / CELL))
	_h = int(ceilf((max_z - min_z) / CELL))
	var n: int = _w * _h
	_walk.resize(n)
	_dist.resize(n)
	_dirx.resize(n)
	_dirz.resize(n)


func set_target(p: Vector3) -> void:
	_target = p


func _physics_process(delta: float) -> void:
	# Растеризация — на первом физтике (в _ready физ-мир ещё не готов).
	if not _scanned:
		_scanned = true
		_rescan_box(0, 0, _w, _h)
		_rebuild()
		return
	# Отложенные перечитки регионов (проломы/двери).
	for i in range(_pending.size() - 1, -1, -1):
		var job: Array = _pending[i]
		job[2] = float(job[2]) - delta
		if float(job[2]) <= 0.0:
			var lo: Vector2i = job[0]
			var hi: Vector2i = job[1]
			_rescan_box(maxi(lo.x, 0), maxi(lo.y, 0), mini(hi.x + 1, _w), mini(hi.y + 1, _h))
			_rebuild()
			_pending.remove_at(i)
	_timer -= delta
	if _timer <= 0.0 and _target != Vector3.INF:
		_timer = rebuild_interval
		_rebuild()


## Пролом/открытие двери → перечитать проходимость вокруг точки. `delay` —
## сколько ждать (queue_free тела чистит физику лишь на следующем тике, а
## двери-слайды освобождают проём вообще за ~секунду). Очередь тикает в
## _physics_process — без лямбд-таймеров (capture freed-нод у нас уже стрелял).
var _pending: Array = []

func refresh_around(p: Vector3, radius: float, delay: float = 0.3) -> void:
	var lo := _cell_of(Vector3(p.x - radius, 0.0, p.z - radius))
	var hi := _cell_of(Vector3(p.x + radius, 0.0, p.z + radius))
	_pending.append([lo, hi, delay])


## Направление хода из позиции (билинейная смесь 4 клеток — без зигзага на
## границах). ZERO = поле молчит: иди прямо (близко/вне сетки/не построено).
func flow_dir(p: Vector3) -> Vector3:
	if _w == 0 or _target == Vector3.INF:
		return Vector3.ZERO
	var fx: float = (p.x - _origin.x) / CELL - 0.5
	var fz: float = (p.z - _origin.y) / CELL - 0.5
	var ix: int = int(floorf(fx))
	var iz: int = int(floorf(fz))
	var tx: float = fx - float(ix)
	var tz: float = fz - float(iz)
	var sum_x: float = 0.0
	var sum_z: float = 0.0
	var near: int = UNREACHED
	for oz in range(2):
		for ox in range(2):
			var cx: int = ix + ox
			var cz: int = iz + oz
			if cx < 0 or cz < 0 or cx >= _w or cz >= _h:
				continue
			var i: int = cz * _w + cx
			if _walk[i] == 0 or _dist[i] >= UNREACHED:
				continue
			near = mini(near, _dist[i])
			var w: float = (tx if ox == 1 else 1.0 - tx) * (tz if oz == 1 else 1.0 - tz)
			sum_x += _dirx[i] * w
			sum_z += _dirz[i] * w
	if near >= UNREACHED or near <= NEAR_STRAIGHT:
		return Vector3.ZERO
	var v := Vector3(sum_x, 0.0, sum_z)
	return v.normalized() if v.length_squared() > 0.0001 else Vector3.ZERO


func _cell_of(p: Vector3) -> Vector2i:
	return Vector2i(int(floorf((p.x - _origin.x) / CELL)), int(floorf((p.z - _origin.y) / CELL)))


## Проходимость клеток прямоугольника [x0..x1) × [z0..z1): бокс-запросом по
## стенам (TERRAIN + гейты). Пол на y≤0 запрос не задевает (окно y 0.7..1.7);
## мебель/щиты (ITEMS) — НЕ блокеры: щит артели обязан оставаться грызомой
## преградой, а не оббегаемой.
func _rescan_box(x0: int, z0: int, x1: int, z1: int) -> void:
	var space := get_world_3d().direct_space_state
	var shape := BoxShape3D.new()
	shape.size = Vector3(CELL * 0.9, 1.0, CELL * 0.9)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.collision_mask = Layers.TERRAIN | Layers.WALL_GATE_BLOCK
	for cz in range(z0, z1):
		for cx in range(x0, x1):
			q.transform = Transform3D(Basis.IDENTITY, Vector3(
					_origin.x + (float(cx) + 0.5) * CELL, 1.2,
					_origin.y + (float(cz) + 0.5) * CELL))
			_walk[cz * _w + cx] = 0 if not space.intersect_shape(q, 1).is_empty() else 1


## BFS от клетки цели + направления «к соседу с меньшей дистанцией».
func _rebuild() -> void:
	var n: int = _w * _h
	for i in range(n):
		_dist[i] = UNREACHED
	var t := _cell_of(_target)
	if t.x < 0 or t.y < 0 or t.x >= _w or t.y >= _h:
		return
	var start: int = t.y * _w + t.x
	if _walk[start] == 0:
		# Цель в стене (кламп-огрехи) — ищем ближайшую проходимую рядом.
		var found: bool = false
		for nb in _NB:
			var ax: int = t.x + nb.x
			var az: int = t.y + nb.y
			if ax >= 0 and az >= 0 and ax < _w and az < _h and _walk[az * _w + ax] == 1:
				start = az * _w + ax
				found = true
				break
		if not found:
			return
	var queue := PackedInt32Array()
	queue.resize(n)
	var head: int = 0
	var tail: int = 0
	queue[tail] = start
	tail += 1
	_dist[start] = 0
	while head < tail:
		var cur: int = queue[head]
		head += 1
		var cx: int = cur % _w
		var cz: int = cur / _w
		var d: int = _dist[cur] + 1
		for nb in _NB:
			var ax: int = cx + nb.x
			var az: int = cz + nb.y
			if ax < 0 or az < 0 or ax >= _w or az >= _h:
				continue
			var ai: int = az * _w + ax
			if _walk[ai] == 0 or _dist[ai] != UNREACHED:
				continue
			# Диагональ не срезает угол: обе ортогональные клетки проходимы.
			if nb.x != 0 and nb.y != 0:
				if _walk[cz * _w + ax] == 0 or _walk[az * _w + cx] == 0:
					continue
			_dist[ai] = d
			queue[tail] = ai
			tail += 1
	# Направления: к лучшему соседу (диагонали с тем же анти-срезом).
	for cz in range(_h):
		for cx in range(_w):
			var i: int = cz * _w + cx
			if _walk[i] == 0 or _dist[i] >= UNREACHED or _dist[i] == 0:
				_dirx[i] = 0.0
				_dirz[i] = 0.0
				continue
			var best: int = _dist[i]
			var bx: float = 0.0
			var bz: float = 0.0
			for nb in _NB:
				var ax: int = cx + nb.x
				var az: int = cz + nb.y
				if ax < 0 or az < 0 or ax >= _w or az >= _h:
					continue
				if nb.x != 0 and nb.y != 0:
					if _walk[cz * _w + ax] == 0 or _walk[az * _w + cx] == 0:
						continue
				var ai: int = az * _w + ax
				if _walk[ai] == 1 and _dist[ai] < best:
					best = _dist[ai]
					bx = float(nb.x)
					bz = float(nb.y)
			var l: float = sqrt(bx * bx + bz * bz)
			if l > 0.001:
				_dirx[i] = bx / l
				_dirz[i] = bz / l
			else:
				_dirx[i] = 0.0
				_dirz[i] = 0.0
