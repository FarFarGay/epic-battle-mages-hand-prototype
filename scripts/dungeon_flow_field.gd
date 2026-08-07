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
## ⭐ ОКНО ПЕРЕСЧЁТА в клетках (2026-08-07, фикс «диких просадок»). Раньше BFS
## заливал ВСЮ сетку: в первой комнате волну держали завалы (1000 клеток, 12 мс),
## а в ангаре тоннель открыт — заливалось 11000 клеток, и один пересчёт стоил
## 53 мс при бюджете кадра 16. Просадка была ровно там, где карта открыта.
##
## Поле нужно только рядом с целью — там враг обходит углы. Дальше скелет идёт
## прямо (flow_dir отдаёт ZERO = прежний фолбэк), а за 80 м он вообще в дальнем
## LOD. Окно ограничивает работу СВЕРХУ и не зависит от того, сколько дверей
## игрок успел открыть: 32 клетки ≈ 38 м во все стороны.
const WINDOW := 32

var rebuild_interval: float = 0.25

var _origin := Vector2.ZERO
var _w: int = 0
var _h: int = 0
var _walk := PackedByteArray()
var _dist := PackedInt32Array()
var _dirx := PackedFloat32Array()
var _dirz := PackedFloat32Array()
## Поколение, которым помечена клетка на последнем пересчёте. Заменяет очистку
## _dist: заливать 17700 int'ов каждые 0.25 с — сами по себе миллисекунды, а вне
## окна старые дистанции ещё и врали бы. Клетка валидна ⇔ _stamp[i] == _gen.
var _stamp := PackedInt32Array()
var _gen: int = 0
var _target := Vector3.INF
var _timer: float = 0.0
var _scanned: bool = false
## Клетка, вокруг которой поле построено сейчас, и флаг «стены изменились».
## Цель не вышла из своей клетки и проломов не было → пересчёт дал бы ТО ЖЕ
## поле. Пока отряд стоит (осада, разговор, стройка) флоу-филд не стоит ничего.
var _built_cell := Vector2i(-999999, -999999)
var _dirty: bool = true
## Очередь BFS живёт между пересчётами: resize(n) каждый раз — лишняя аллокация.
var _queue := PackedInt32Array()

## 8 соседей: 4 ортогональных + 4 диагональных (диагональ не режет углы —
## проверяются обе ортогональные клетки). Плоскими int-массивами, а не Vector2i:
## в горячем цикле обращение к .x/.y заметно дороже индекса.
const _NBX := [1, -1, 0, 0, 1, 1, -1, -1]
const _NBZ := [0, 0, 1, -1, 1, -1, 1, -1]
## Направление «назад к родителю» для каждого соседа, уже нормированное
## (диагональ = 1/√2). BFS ставит его прямо в момент открытия клетки: родитель
## по определению сосед с dist−1, то есть лучший из возможных. Отдельного
## прохода «найди лучшего соседа» (ещё 8 проверок на клетку) больше нет.
const _BACKX := [-1.0, 1.0, 0.0, 0.0, -0.70710678, -0.70710678, 0.70710678, 0.70710678]
const _BACKZ := [0.0, 0.0, -1.0, 1.0, -0.70710678, 0.70710678, -0.70710678, 0.70710678]


func setup(min_x: float, min_z: float, max_x: float, max_z: float) -> void:
	_origin = Vector2(min_x, min_z)
	_w = int(ceilf((max_x - min_x) / CELL))
	_h = int(ceilf((max_z - min_z) / CELL))
	var n: int = _w * _h
	_walk.resize(n)
	_dist.resize(n)
	_dirx.resize(n)
	_dirz.resize(n)
	_stamp.resize(n)
	_stamp.fill(0)
	_queue.resize(n)


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
			_dirty = true
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
			# Вне текущего поколения = клетка не покрыта окном пересчёта.
			if _walk[i] == 0 or _stamp[i] != _gen or _dist[i] >= UNREACHED:
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


## BFS от клетки цели в пределах окна WINDOW. Направление клетки ставится сразу
## при её открытии (родитель = сосед с меньшей дистанцией), поэтому второго
## прохода по сетке нет, а очистка дистанций заменена штампом поколения.
func _rebuild() -> void:
	if _w == 0:
		return
	var t := _cell_of(_target)
	if t.x < 0 or t.y < 0 or t.x >= _w or t.y >= _h:
		return
	# Цель в той же клетке и стены не менялись → поле уже правильное.
	if not _dirty and t == _built_cell:
		return
	var start: int = t.y * _w + t.x
	if _walk[start] == 0:
		# Цель в стене (кламп-огрехи) — ищем ближайшую проходимую рядом.
		var found: bool = false
		for k in range(8):
			var ax: int = t.x + _NBX[k]
			var az: int = t.y + _NBZ[k]
			if ax >= 0 and az >= 0 and ax < _w and az < _h and _walk[az * _w + ax] == 1:
				start = az * _w + ax
				found = true
				break
		if not found:
			return
	_gen += 1
	_built_cell = t
	_dirty = false
	# Границы окна: за них волна не выходит, поэтому цена пересчёта ограничена
	# сверху (65×65 клеток) при любой открытости карты.
	var x0: int = maxi(t.x - WINDOW, 0)
	var x1: int = mini(t.x + WINDOW, _w - 1)
	var z0: int = maxi(t.y - WINDOW, 0)
	var z1: int = mini(t.y + WINDOW, _h - 1)
	var head: int = 0
	var tail: int = 0
	_queue[tail] = start
	tail += 1
	_dist[start] = 0
	_stamp[start] = _gen
	_dirx[start] = 0.0
	_dirz[start] = 0.0
	while head < tail:
		var cur: int = _queue[head]
		head += 1
		var cx: int = cur % _w
		var cz: int = cur / _w
		var d: int = _dist[cur] + 1
		for k in range(8):
			var ax: int = cx + _NBX[k]
			var az: int = cz + _NBZ[k]
			if ax < x0 or az < z0 or ax > x1 or az > z1:
				continue
			var ai: int = az * _w + ax
			if _walk[ai] == 0 or _stamp[ai] == _gen:
				continue
			# Диагональ не срезает угол: обе ортогональные клетки проходимы.
			if _NBX[k] != 0 and _NBZ[k] != 0:
				if _walk[cz * _w + ax] == 0 or _walk[az * _w + cx] == 0:
					continue
			_dist[ai] = d
			_stamp[ai] = _gen
			_dirx[ai] = _BACKX[k]
			_dirz[ai] = _BACKZ[k]
			_queue[tail] = ai
			tail += 1
