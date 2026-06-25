class_name Castle
extends StaticBody3D
## Коллектор — центральный хаб нефтесети (Room8, на месте бывшего бура). Принимает
## нефть со ВСЕХ буров по трубам (add_oil), копит = счётчик победы матча. Это цель
## обороны: при штурме враги ломятся к нему (HP/урон — слой обороны позже).
##
## Буры подключаются к коллектору трубопроводом из секций ([PipeSegment], ставятся
## рукой как стены). Связность считает сам коллектор по совпадению концов-портов
## (_recompute_network) и зовёт bur.set_collector(self). Коллектор пассивен: буры
## сами шлют ему add_oil каждый тик добычи.

const GROUP := &"castle"
## Допуск совпадения КОНЦОВ (портов) труб/инлетов/буров. Снап ставит концы встык
## (≈0), 0.6 — запас.
const PORT_TOL := 0.6
## ЛКМ-захват рукой — клик по замку = найм РАБОЧИХ за золото (тот же стол, что казармы).
const ACTION_GRAB := &"hand_grab"
## Радиус (XZ) вокруг замка, в котором рука «нанимает» по ЛКМ (замок крупный, ~4.6м).
@export var hire_radius: float = 3.5

signal oil_changed(oil: float, goal: float)
signal filled

## Цель матча — накопить столько нефти со всех буров (победа). Подключим к
## WinOverlay следующим куском (HUD-счётчик + победа).
@export var oil_goal: float = 200.0
## Вынос порта стыковки трубы вперёд/назад (±Z) — ЛЕГАСИ нефтесети (трубы ретайрятся,
## Фаза 3). Кратно клетке (3.0), pipe_ports() ещё считает по нему.
@export var inlet_dist: float = 3.0

var _oil: float = 0.0
var _full: bool = false
var _fill: Node3D = null
var _net_timer: float = 0.0
var _hand: Hand = null


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(PipeSegment.PORT_HOST_GROUP)  # коллектор даёт порты для снапа/сети
	add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)  # замок = кнопка найма рабочих (hover + ЛКМ)
	_build_castle()
	_update_fill()


# --- Визуал: мини-замок (центр грид-города). Строится кодом, как трубы (один путь). ---

const _STONE := Color(0.56, 0.55, 0.6)
const _TRIM := Color(0.4, 0.38, 0.43)


func _build_castle() -> void:
	var stone := _mat(_STONE, 0.9)
	var trim := _mat(_TRIM, 0.85)
	# Донжон: квадратный корпус-стена.
	_box(Vector3(3.4, 2.2, 3.4), Vector3(0, 1.1, 0), stone)
	_battlements(1.7, 2.2, trim)  # зубцы по верху стен
	# Угловые башенки — КВАДРАТНЫЕ короба выше стен + квадратные пирамидальные крыши.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var c := Vector3(sx * 1.7, 0, sz * 1.7)
			_box(Vector3(1.0, 3.4, 1.0), c + Vector3(0, 1.7, 0), stone)
			_pyramid(0.6, 0.9, c + Vector3(0, 3.85, 0), trim)
	# Ворота (тёмный проём спереди).
	_box(Vector3(1.1, 1.5, 0.25), Vector3(0, 0.75, 1.72), trim)
	# Уровень нефти = светящийся столб в центре двора, растёт по Y (oil → победа).
	_fill = Node3D.new()
	add_child(_fill)
	_fill.position = Vector3(0, 2.2, 0)  # от верха стен вверх
	var glow := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(0.9, 2.0, 0.9)
	glow.mesh = gm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.95, 0.55, 0.18)
	gmat.emission_enabled = true
	gmat.emission = Color(1.0, 0.6, 0.2)
	gmat.emission_energy_multiplier = 1.6
	glow.mesh.material = gmat
	glow.position = Vector3(0, 1.0, 0)  # низ столба на верхе стен, растёт вверх
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fill.add_child(glow)


## Зубцы (мерлоны) по периметру верха стен: ряд кубиков на каждой из 4 сторон.
func _battlements(half: float, top_y: float, mat: StandardMaterial3D) -> void:
	var n := 4
	var mh := 0.5
	var mw := 0.36
	var step := (half * 2.0) / float(n)
	for i in n:
		var o: float = -half + step * (float(i) + 0.5)
		var y: float = top_y + mh * 0.5
		_box(Vector3(mw, mh, mw), Vector3(o, y, half), mat)
		_box(Vector3(mw, mh, mw), Vector3(o, y, -half), mat)
		_box(Vector3(mw, mh, mw), Vector3(half, y, o), mat)
		_box(Vector3(mw, mh, mw), Vector3(-half, y, o), mat)


func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


func _box(size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	add_child(mi)


## Квадратная пирамида (крыша башенки): CylinderMesh с 4 сегментами, повёрнут на 45°,
## чтобы грани шли вдоль осей (как у короба башни). half — полуширина квадрата основания.
func _pyramid(half: float, height: float, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = 0.0
	c.bottom_radius = half * 1.4142  # описанный радиус квадрата стороной 2·half
	c.height = height
	c.radial_segments = 4
	mi.mesh = c
	mi.material_override = mat
	mi.position = pos
	mi.rotation.y = PI / 4.0
	add_child(mi)


## Порты коллектора (мировые концы инлетов спереди/сзади) — контракт pipe_port_host.
func pipe_ports() -> Array:
	var fz: Vector3 = global_transform.basis.z.normalized() * inlet_dist
	return [global_position + fz, global_position - fz]


## Периодически пересчитываем связность сети и подключаем/отключаем буры. Дёшево
## (узлов мало), троттлим. Заливка от инлетов по смежным трубам до буров.
func _process(delta: float) -> void:
	_tick_hire_click()
	_net_timer -= delta
	if _net_timer > 0.0:
		return
	_net_timer = 0.7
	# Легаси нефтесеть (буры/трубы) в room-режиме отсутствует → не гоняем заливку впустую.
	if get_tree().get_nodes_in_group(&"oil_rig").is_empty():
		return
	_recompute_network()


## ЛКМ вблизи замка (вне открытой модалки) → стол найма РАБОЧИХ. Зеркало
## PadBuilding._tick_hire_click / GnomeHouse._process, но цель — рабочие (population).
func _tick_hire_click() -> void:
	var tree := get_tree()
	var trade := tree.get_first_node_in_group(&"trade_ui")
	if trade != null and trade.has_method(&"is_open") and trade.call(&"is_open"):
		return  # стол торга уже открыт
	if not Input.is_action_just_pressed(ACTION_GRAB):
		return
	var hand := _resolve_hand()
	if hand == null:
		return
	# Не реагируем на клик-команды aim-режимов, клик по HUD и при удержании предмета.
	if hand.is_in_aim_mode() or hand.is_pointer_over_ui() or hand.is_holding():
		return
	var hp: Vector3 = hand.cursor_world_position()
	var dx: float = hp.x - global_position.x
	var dz: float = hp.z - global_position.z
	if dx * dx + dz * dz <= hire_radius * hire_radius:
		_open_hire()


## Открыть стол торга под РАБОЧИХ с адресным колбэком — замок сам спавнит/доливает
## артель (cap 7 клампит request_squad), не дёргая broadcast.
func _open_hire() -> void:
	var trade := get_tree().get_first_node_in_group(&"trade_ui")
	if trade != null and trade.has_method(&"open"):
		trade.call(&"open", SoldierSystem.ROLE_WORKER, Callable(self, &"_on_hired_workers"))


## Оплата прошла → заказываем рабочих у спавнера (request_squad клампит до cap 7).
## Рабочие — мобильная утилитная артель (без гарнизона); спавнятся у замка.
func _on_hired_workers(unit_type: StringName, want: int) -> void:
	var spawner := get_tree().get_first_node_in_group(&"squad_spawner")
	if spawner == null or not spawner.has_method(&"request_squad"):
		return
	var ground := Vector3(global_position.x, 0.5, global_position.z)
	spawner.call(&"request_squad", unit_type, want, ground)


## Контракт hover-подсветки (Hand._update_pickup_highlight): emission по коробам замка.
## Светящийся столб-нефти (_fill / glow) — под Node3D-ребёнком, не direct MeshInstance →
## не затрагивается (его собственный emission остаётся).
func set_highlighted(value: bool) -> void:
	for ch in get_children():
		var mi := ch as MeshInstance3D
		if mi == null:
			continue
		var mat := mi.material_override as StandardMaterial3D
		if mat == null:
			continue
		mat.emission_enabled = value
		mat.emission = Color(0.55, 0.7, 1.0)
		mat.emission_energy_multiplier = 0.5 if value else 0.0


func _resolve_hand() -> Hand:
	if _hand != null and is_instance_valid(_hand):
		return _hand
	_hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP)
	return _hand


## Заливка по СОВПАДАЮЩИМ КОНЦАМ (портам): от портов коллектора по трубам, чьи концы
## встыкованы, до буров. Труба подключена, если её порт совпал с портом достигнутого
## хоста; бур подключён, если его порт совпал с портом достигнутой трубы/коллектора.
func _recompute_network() -> void:
	var cports: Array = pipe_ports()
	var pipes: Array = []
	var pports: Array = []
	for n in get_tree().get_nodes_in_group(&"oil_pipe"):
		if is_instance_valid(n) and n.has_method(&"pipe_ports"):
			pipes.append(n)
			pports.append(n.call(&"pipe_ports"))
	var reached: Dictionary = {}
	var frontier: Array[int] = []
	for i in pipes.size():
		if _ports_touch(pports[i], cports):
			reached[i] = true
			frontier.append(i)
	while not frontier.is_empty():
		var i: int = frontier.pop_back()
		for j in pipes.size():
			if reached.has(j):
				continue
			if _ports_touch(pports[i], pports[j]):
				reached[j] = true
				frontier.append(j)
	for d in get_tree().get_nodes_in_group(&"oil_rig"):
		if not (is_instance_valid(d) and d.has_method(&"set_collector") and d.has_method(&"pipe_ports")):
			continue
		var dports: Array = d.call(&"pipe_ports")
		var conn: bool = _ports_touch(dports, cports)
		if not conn:
			for k in reached:
				if _ports_touch(dports, pports[k]):
					conn = true
					break
		d.call(&"set_collector", self if conn else null)


## Совпадает ли хоть одна пара концов из двух наборов (по XZ, в пределах PORT_TOL).
func _ports_touch(a: Array, b: Array) -> bool:
	for pa in a:
		for pb in b:
			var dx: float = (pa as Vector3).x - (pb as Vector3).x
			var dz: float = (pa as Vector3).z - (pb as Vector3).z
			if dx * dx + dz * dz <= PORT_TOL * PORT_TOL:
				return true
	return false


## Залить нефть (зовут подключённые буры в добыче). На oil_goal — filled.
func add_oil(amount: float) -> void:
	if _full or amount <= 0.0:
		return
	_oil = minf(_oil + amount, oil_goal)
	_update_fill()
	oil_changed.emit(_oil, oil_goal)
	if _oil >= oil_goal:
		_full = true
		filled.emit()
		EventBus.match_won.emit()  # замок наполнен нефтью → победа (WinOverlay слушает)
		if LogConfig.master_enabled:
			print("[Castle] ★ КОЛЛЕКТОР ПОЛОН (%.0f) — цель добычи достигнута" % oil_goal)


func get_oil() -> float:
	return _oil


func get_goal() -> float:
	return oil_goal


func _update_fill() -> void:
	if _fill == null:
		return
	var frac: float = clampf(_oil / maxf(oil_goal, 0.001), 0.0, 1.0)
	_fill.scale.y = maxf(frac, 0.001)
