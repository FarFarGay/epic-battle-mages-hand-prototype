extends Node3D
## Гигантская рука. Курсор мыши = позиция руки в мире.
## ЛКМ зажать → поднять ближайший Item в GrabArea.
##   Если Item только в MagnetArea — рука его притягивает, пока не дотянется.
## ЛКМ отпустить → бросить с инерцией движения руки.
##
## Внешний интерфейс — только сигналы. Слушатели подключаются без правок руки.

signal grabbed(item: Item)
signal released(item: Item, velocity: Vector3)

@export var hand_height: float = 2.5
@export var throw_strength: float = 1.2
@export var max_throw_speed: float = 30.0
@export var hold_offset: Vector3 = Vector3(0, -1.0, 0)
@export var magnet_force: float = 30.0

const VELOCITY_HISTORY_FRAMES := 6

@onready var grab_area: Area3D = $GrabArea
@onready var magnet_area: Area3D = $MagnetArea

var _held: Item = null
var _is_grabbing: bool = false
var _velocity_history: Array[Vector3] = []
var _previous_pos: Vector3
var _initialized: bool = false


func _process(delta: float) -> void:
	_follow_cursor()
	_track_velocity(delta)
	_handle_grab_input()
	_update_held_position()


func _physics_process(_delta: float) -> void:
	# Магнит и попытка захвата — в физик-кадре, чтобы силы суммировались стабильно
	if _is_grabbing and not _held:
		_try_grab()
		if not _held:
			_apply_magnet()


func _follow_cursor() -> void:
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)
	var plane := Plane(Vector3.UP, hand_height)
	var hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
	if hit != null:
		global_position = hit


func _track_velocity(delta: float) -> void:
	if not _initialized:
		_previous_pos = global_position
		_initialized = true
		return
	if delta <= 0.0:
		return
	var instant_v: Vector3 = (global_position - _previous_pos) / delta
	_velocity_history.append(instant_v)
	if _velocity_history.size() > VELOCITY_HISTORY_FRAMES:
		_velocity_history.pop_front()
	_previous_pos = global_position


func _handle_grab_input() -> void:
	if Input.is_action_just_pressed("hand_grab"):
		_is_grabbing = true
		_try_grab()
	elif Input.is_action_just_released("hand_grab"):
		_is_grabbing = false
		_release()


func _try_grab() -> void:
	if _held:
		return
	var closest := _find_closest_item(grab_area.get_overlapping_bodies())
	if closest:
		_attach(closest)


func _apply_magnet() -> void:
	var closest := _find_closest_item(magnet_area.get_overlapping_bodies())
	if not closest:
		return
	var to_hand: Vector3 = global_position - closest.global_position
	if to_hand.length_squared() < 0.0001:
		return
	closest.apply_central_force(to_hand.normalized() * magnet_force)


func _find_closest_item(bodies: Array[Node3D]) -> Item:
	var closest: Item = null
	var closest_dist := INF
	for body in bodies:
		if body is Item:
			var d := global_position.distance_to(body.global_position)
			if d < closest_dist:
				closest_dist = d
				closest = body
	return closest


func _attach(item: Item) -> void:
	_held = item
	_held.linear_velocity = Vector3.ZERO
	_held.angular_velocity = Vector3.ZERO
	_held.freeze = true
	grabbed.emit(_held)


func _release() -> void:
	if not _held:
		return
	_held.freeze = false
	var v := _smoothed_velocity() * throw_strength
	if v.length() > max_throw_speed:
		v = v.normalized() * max_throw_speed
	_held.linear_velocity = v
	released.emit(_held, v)
	_held = null


func _update_held_position() -> void:
	if _held:
		_held.global_position = global_position + hold_offset


func _smoothed_velocity() -> Vector3:
	if _velocity_history.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for v in _velocity_history:
		sum += v
	return sum / _velocity_history.size()
