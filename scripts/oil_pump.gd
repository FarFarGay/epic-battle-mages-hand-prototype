class_name OilPump
extends StaticBody3D
## Модуль-насос нефтекачалки (путь A — строится как обычное здание из
## [RoomBuildings] рядом с буром). На достройке ([RoomBuildSite._finish]
## инстансит эту сцену) сам регистрируется на ближайший [OilRig] в его зоне:
## бур оживает (PUMPING) и +oil_per_pump к добыче. Бура в зоне нет → насос
## инертен (предупреждение) — поставь ближе к буру.

## В каком радиусе вообще искать бур (в свою зону пускает уже сам бур).
const RIG_SEARCH_RADIUS := 40.0

## Период качания поршня (визуал работающего насоса).
@export var pump_period: float = 1.1
@export var pump_amplitude: float = 0.14

@onready var _arm: Node3D = get_node_or_null("Arm")
var _arm_base_y: float = 0.0
var _t: float = 0.0
var _registered: bool = false


func _ready() -> void:
	if _arm != null:
		_arm_base_y = _arm.position.y
	set_process(false)
	# Регистрация ОТЛОЖЕННО: RoomBuildSite ставит global_position ПОСЛЕ add_child,
	# а _ready срабатывает во время add_child — на нём позиция ещё (0,0,0), и бур
	# «не найден» по дистанции. call_deferred выполнится уже с верной позицией.
	call_deferred(&"_register_to_rig")


func _register_to_rig() -> void:
	var rig := _nearest_rig()
	if rig != null and rig.has_method(&"register_pump"):
		_registered = bool(rig.call(&"register_pump", self))
	if not _registered:
		push_warning("[OilPump] бура в зоне нет — насос инертен (поставь ближе к буру)")
	set_process(_registered)


func _process(delta: float) -> void:
	if _arm == null:
		return
	_t += delta
	_arm.position.y = _arm_base_y + sin(_t / maxf(pump_period, 0.05) * TAU) * pump_amplitude


func _nearest_rig() -> Node3D:
	var best: Node3D = null
	var best_d: float = RIG_SEARCH_RADIUS * RIG_SEARCH_RADIUS
	for n in get_tree().get_nodes_in_group(&"oil_rig"):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var d: float = (node.global_position - global_position).length_squared()
		if d < best_d:
			best_d = d
			best = node
	return best
