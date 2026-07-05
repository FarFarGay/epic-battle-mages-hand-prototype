class_name RelayItem
extends RigidBody3D
## Диод-ретранслятор — переносной предмет (пазл Room3): игрок рукой (Grabbable,
## как мосток) вставляет его в гнездо [RelaySocket] — цепь замыкается, ток идёт
## насквозь. Схватил обратно — гнездо снова пустое. Визуал = кристалл-цилиндр
## как у диодов (родня цепи), но тусклый: «не запитан», вспыхивает на проходе тока.
##
## Слои: свободный — ITEMS (рука морозит при захвате сама); в гнезде —
## MOUNTED_MODULE (башня проезжает, GrabArea руки видит → можно снять). Тот же
## приём, что у BridgePlank/модулей башни.

@export var crystal_color: Color = Color(0.4, 0.55, 0.8)
@export var pass_color: Color = Color(1.0, 0.85, 0.4)
@export var highlight_color: Color = Color(1.0, 0.95, 0.4, 1.0)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6
## В каком радиусе от гнезда дроп засчитывается как посадка.
@export var snap_radius: float = 2.5

var _socket: RelaySocket = null
var _material: StandardMaterial3D = null
var _snap_tween: Tween = null


func _ready() -> void:
	mass = 3.0
	collision_layer = Layers.ITEMS
	collision_mask = Layers.MASK_ALL_GAMEPLAY
	_build_visual()
	Grabbable.register(self)
	EventBus.hand_grabbed.connect(_on_hand_grabbed)
	EventBus.hand_released.connect(_on_hand_released)


## Кристалл диодной формы (усечённый цилиндр, как spark_diode) на тёмном торце.
func _build_visual() -> void:
	var body := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.32
	cyl.bottom_radius = 0.42
	cyl.height = 0.45
	body.mesh = cyl
	_material = StandardMaterial3D.new()
	_material.albedo_color = crystal_color
	_material.emission_enabled = true
	_material.emission = crystal_color
	_material.emission_energy_multiplier = 1.2
	body.material_override = _material
	add_child(body)
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.42
	shape.height = 0.45
	col.shape = shape
	add_child(col)


## Контракт Grabbable: рамка-кандидат руки.
func set_highlighted(value: bool) -> void:
	if _material == null:
		return
	if value:
		_material.emission = Color(highlight_color.r, highlight_color.g, highlight_color.b)
		_material.emission_energy_multiplier = highlight_intensity + 1.2
	else:
		_material.emission = crystal_color
		_material.emission_energy_multiplier = 1.2


## Ток прошёл через кристалл (зовёт RelaySocket) — тёплая вспышка.
func on_current_pass() -> void:
	if _material == null:
		return
	_material.emission = pass_color
	_material.emission_energy_multiplier = 6.0
	var tw := create_tween()
	tw.tween_property(_material, "emission_energy_multiplier", 2.0, 0.6)
	tw.parallel().tween_property(_material, "emission", crystal_color, 0.6)


## Схватили из гнезда → разрыв цепи снова открыт. Заморозку снимает рука.
func _on_hand_grabbed(item: Node3D) -> void:
	if item != self:
		return
	if _snap_tween != null and _snap_tween.is_valid():
		_snap_tween.kill()
	_snap_tween = null
	collision_layer = Layers.ITEMS
	if _socket != null and is_instance_valid(_socket):
		_socket.unseat()
	_socket = null


## Отпустили: рядом свободное гнездо → посадка с доводкой.
func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item != self or _socket != null:
		return
	var socket := _nearest_socket()
	if socket == null or socket.is_seated():
		return
	if global_position.distance_to(socket.global_position) > snap_radius:
		return
	_socket = socket
	freeze = true
	collision_layer = Layers.MOUNTED_MODULE
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	socket.seat(self)
	_snap_tween = create_tween()
	_snap_tween.tween_property(self, "global_transform", socket.seat_transform(), 0.14) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_snap_tween.tween_callback(func() -> void:
		AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position, 0.8, 6.0))


func _nearest_socket() -> RelaySocket:
	var best: RelaySocket = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group(&"relay_socket"):
		var s := n as RelaySocket
		if s == null:
			continue
		var d: float = s.global_position.distance_squared_to(global_position)
		if d < best_d:
			best_d = d
			best = s
	return best
