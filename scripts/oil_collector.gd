class_name OilCollector
extends StaticBody3D
## Коллектор — центральный хаб нефтесети (Room8, на месте бывшего бура). Принимает
## нефть со ВСЕХ буров по трубам (add_oil), копит = счётчик победы матча. Это цель
## обороны: при штурме враги ломятся к нему (HP/урон — слой обороны позже).
##
## Буры подключаются к коллектору трубопроводом из секций ([PipeSegment], ставятся
## рукой как стены). Связность считает сам коллектор по совпадению концов-портов
## (_recompute_network) и зовёт bur.set_collector(self). Коллектор пассивен: буры
## сами шлют ему add_oil каждый тик добычи.

const GROUP := &"oil_collector"
## Допуск совпадения КОНЦОВ (портов) труб/инлетов/буров. Снап ставит концы встык
## (≈0), 0.6 — запас.
const PORT_TOL := 0.6

signal oil_changed(oil: float, goal: float)
signal filled

## Цель матча — накопить столько нефти со всех буров (победа). Подключим к
## WinOverlay следующим куском (HUD-счётчик + победа).
@export var oil_goal: float = 200.0
## Меш «уровень нефти» в баке коллектора — растёт по Y от 0 до полного.
@export var fill_path: NodePath = NodePath("Fill")
## Вынос конца инлета вперёд/назад (±Z локально) от центра — порты стыковки трубы
## (на концах трубчатых выступов спереди/сзади).
@export var inlet_dist: float = 3.0

var _oil: float = 0.0
var _full: bool = false
var _fill: Node3D = null
var _net_timer: float = 0.0


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(PipeSegment.PORT_HOST_GROUP)  # коллектор даёт порты для снапа/сети
	_fill = get_node_or_null(fill_path) as Node3D
	_update_fill()
	_build_inlet_stub(1.0)   # перёд (+Z)
	_build_inlet_stub(-1.0)  # зад (−Z)


## Трубчатый выступ-инлет (цилиндр вдоль Z + фланец на конце) спереди/сзади. Конец
## выступа = порт стыковки (см. pipe_ports).
func _build_inlet_stub(dir_sign: float) -> void:
	var mat := PipeSegment.material()
	var z0: float = 2.0          # от края бака
	var z1: float = inlet_dist   # до конца-порта
	var stub := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = 0.22
	c.bottom_radius = 0.22
	c.height = z1 - z0
	stub.mesh = c
	stub.material_override = mat
	stub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stub.position = Vector3(0, PipeSegment.PIPE_Y, (z0 + z1) * 0.5 * dir_sign)
	stub.rotation = Vector3(PI / 2, 0, 0)  # ось цилиндра вдоль Z
	add_child(stub)
	var fl := MeshInstance3D.new()
	var fc := CylinderMesh.new()
	fc.top_radius = 0.34
	fc.bottom_radius = 0.34
	fc.height = 0.12
	fl.mesh = fc
	fl.material_override = mat
	fl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fl.position = Vector3(0, PipeSegment.PIPE_Y, z1 * dir_sign)
	fl.rotation = Vector3(PI / 2, 0, 0)
	add_child(fl)


## Порты коллектора (мировые концы инлетов спереди/сзади) — контракт pipe_port_host.
func pipe_ports() -> Array:
	var fz: Vector3 = global_transform.basis.z.normalized() * inlet_dist
	return [global_position + fz, global_position - fz]


## Периодически пересчитываем связность сети и подключаем/отключаем буры. Дёшево
## (узлов мало), троттлим. Заливка от инлетов по смежным трубам до буров.
func _process(delta: float) -> void:
	_net_timer -= delta
	if _net_timer > 0.0:
		return
	_net_timer = 0.7
	_recompute_network()


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
		if LogConfig.master_enabled:
			print("[OilCollector] ★ КОЛЛЕКТОР ПОЛОН (%.0f) — цель добычи достигнута" % oil_goal)


func get_oil() -> float:
	return _oil


func get_goal() -> float:
	return oil_goal


func _update_fill() -> void:
	if _fill == null:
		return
	var frac: float = clampf(_oil / maxf(oil_goal, 0.001), 0.0, 1.0)
	_fill.scale.y = maxf(frac, 0.001)
