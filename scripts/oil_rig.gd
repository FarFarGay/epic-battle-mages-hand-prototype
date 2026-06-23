class_name OilRig
extends StaticBody3D
## Бур — ставится игроком (постройка [RoomBuildings.OIL_DRILL]) НА месторождение
## ([OilDeposit]). Зацепился за залежь → добывает нефть (×richness залежи) и гонит
## её по ТРУБОПРОВОДУ в [OilCollector]: коллектор сам считает связность по портам и
## зовёт `set_collector`. Построен НЕ на залежи → инертен (предупреждение). Без трубы
## к коллектору бур крутится, но нефти некуда течь.
##
## group oil_rig. На достройке RoomBuildSite ставит global_position ПОСЛЕ add_child,
## поэтому привязку к залежи делаем отложенно (call_deferred), иначе позиция (0,0,0).

const GROUP := &"oil_rig"
## Локальный конец выходного патрубка бура (порт стыковки трубы). Бур поворачивается
## при установке (MMB) — патрубок целишь в сторону трассы.
const OUTLET_LOCAL := Vector3(-2.2, 0.0, 0.0)

## Базовая добыча (нефть/с), умножается на richness залежи.
@export var oil_per_sec: float = 2.0
## Радиус (XZ), в котором бур цепляется к залежи. Ставь бур на масляное пятно.
@export var deposit_bind_radius: float = 4.0
## Узел бита (крутится в добыче).
@export var drill_path: NodePath = NodePath("DrillBit")
@export var drill_spin_speed: float = 7.0
@export var debug_log: bool = true

var _drill: Node3D = null
var _collector: Node3D = null
var _deposit: Node3D = null
var _richness: float = 1.0
var _active: bool = false  # зацеплен за залежь и добывает


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(PipeSegment.PORT_HOST_GROUP)  # бур даёт порт-патрубок для трубы
	_drill = get_node_or_null(drill_path) as Node3D
	PipeSegment.add_tube(self, OUTLET_LOCAL, 0.22)  # выходной патрубок
	set_process(false)
	call_deferred(&"_bind_deposit")


## Порт бура (мировой конец выходного патрубка) — контракт pipe_port_host.
func pipe_ports() -> Array:
	return [global_transform * OUTLET_LOCAL]


## Зацепиться за ближайшую свободную залежь в радиусе. Нашёл → добыча включается
## (бит крутится; нефть пойдёт, как протянут трубу к коллектору). Нет → инертен.
func _bind_deposit() -> void:
	var dep := _nearest_free_deposit()
	if dep == null:
		if debug_log and LogConfig.master_enabled:
			print("[OilRig] не на месторождении — бур инертен (ставь на масляное пятно)")
		return
	_deposit = dep
	dep.set(&"occupied", true)
	var r = dep.get(&"richness")
	_richness = float(r) if r != null else 1.0
	_active = true
	set_process(true)
	if debug_log and LogConfig.master_enabled:
		print("[OilRig] бур на залежи (×%.1f) — добыча идёт, тяни трубу к коллектору" % _richness)


func _process(delta: float) -> void:
	if not _active:
		return
	if _drill != null:
		_drill.rotation.y += drill_spin_speed * delta
	# Нефть течёт в коллектор ТОЛЬКО если протянута труба (set_collector).
	if _collector != null and is_instance_valid(_collector) and _collector.has_method(&"add_oil"):
		_collector.call(&"add_oil", oil_per_sec * _richness * delta)


## Подключить/отключить коллектор-приёмник (зовёт OilCollector при пересчёте сети,
## раз в ~0.7с). Гард на изменение — иначе спам логов/работы каждый тик.
func set_collector(c: Node3D) -> void:
	if c == _collector:
		return
	_collector = c
	if debug_log and LogConfig.master_enabled:
		print("[OilRig] %s коллектор" % ("подключён" if c != null else "отключён (нет трубы)"))


func is_active() -> bool:
	return _active


func _nearest_free_deposit() -> Node3D:
	var best: Node3D = null
	var best_d: float = deposit_bind_radius * deposit_bind_radius
	for n in get_tree().get_nodes_in_group(&"oil_deposit"):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null or node.get(&"occupied") == true:
			continue
		var dx: float = node.global_position.x - global_position.x
		var dz: float = node.global_position.z - global_position.z
		var d: float = dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best = node
	return best
