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
@export var max_lift_mass: float = 10.0
@export var throw_strength: float = 1.2
@export var max_throw_speed: float = 30.0
@export var hold_offset: Vector3 = Vector3(0, -1.0, 0)
@export var magnet_force: float = 30.0
## По каким слоям raycast поднимает руку (Terrain + Items по умолчанию).
## Actors и Projectiles исключены — иначе рука прыгала бы на врагов и снаряды.
@export_flags_3d_physics var terrain_mask: int = 3
@export var debug_log: bool = true

const VELOCITY_HISTORY_FRAMES := 6

@onready var grab_area: Area3D = $GrabArea
@onready var magnet_area: Area3D = $MagnetArea

var _held: Item = null
var _is_grabbing: bool = false
var _velocity_history: Array[Vector3] = []
var _previous_pos: Vector3
var _initialized: bool = false
# Текущий кандидат на захват (ближайший Item в GrabArea, проходящий по массе).
# Обновляется каждый кадр, на нём подсвечивается emission.
var _current_candidate: Item = null

# Состояние для лога: фронт-триггеры
var _last_surface_label: String = ""
var _was_magnetizing: bool = false
var _magnet_target_name: String = ""


func _process(delta: float) -> void:
	_follow_cursor()
	_track_velocity(delta)
	_handle_grab_input()
	_update_held_position()
	_update_candidate_highlight()


func _physics_process(_delta: float) -> void:
	# Магнит и попытка захвата — в физик-кадре, чтобы силы суммировались стабильно
	if _is_grabbing and not _held:
		_try_grab()
		if not _held:
			_apply_magnet()
		elif debug_log and _was_magnetizing:
			# Магнит дотянул, рука схватила — закрываем магнит-фазу в логе
			_was_magnetizing = false
			_magnet_target_name = ""


func _follow_cursor() -> void:
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	# Этап 1: raycast'ом узнаём Y поверхности под курсором.
	# Если луч ни во что не попал (курсор за краем карты) — считаем y=0.
	# Удерживаемый предмет исключаем — иначе рука бесконечно «уезжает» от него вверх.
	var result := _raycast_terrain(ray_origin, ray_dir)
	var surface_y: float = 0.0
	if not result.is_empty():
		surface_y = (result.position as Vector3).y

	# Этап 2: рука лежит на луче камеры (строго под пиксельным курсором),
	# на высоте surface_y + hand_height. В изометрии нельзя просто прибавить UP к
	# точке попадания — результат уйдёт с луча, и на экране возникнет сдвиг.
	var plane := Plane(Vector3.UP, surface_y + hand_height)
	var plane_hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
	if plane_hit != null:
		global_position = plane_hit

	if debug_log:
		_log_surface(result, surface_y)


func _raycast_terrain(origin: Vector3, dir: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * 1000.0)
	query.collision_mask = terrain_mask
	if _held:
		query.exclude = [_held.get_rid()]
	return space.intersect_ray(query)


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
		if debug_log and _was_magnetizing:
			print("[Hand] магнит: цели нет")
			_was_magnetizing = false
			_magnet_target_name = ""
		return
	var to_hand: Vector3 = global_position - closest.global_position
	if to_hand.length_squared() < 0.0001:
		return
	closest.apply_central_force(to_hand.normalized() * magnet_force)
	if debug_log and (not _was_magnetizing or _magnet_target_name != str(closest.name)):
		print("[Hand] магнит тянет %s (mass=%.1f, dist=%.2f)" % [closest.name, closest.mass, to_hand.length()])
		_was_magnetizing = true
		_magnet_target_name = str(closest.name)


func _find_closest_item(bodies: Array[Node3D]) -> Item:
	var closest: Item = null
	var closest_dist := INF
	for body in bodies:
		if body is Item:
			var item := body as Item
			if item.mass >= max_lift_mass:
				continue
			var d := global_position.distance_to(item.global_position)
			if d < closest_dist:
				closest_dist = d
				closest = item
	return closest


func _attach(item: Item) -> void:
	_held = item
	_held.linear_velocity = Vector3.ZERO
	_held.angular_velocity = Vector3.ZERO
	_held.freeze = true
	if debug_log:
		print("[Hand] схвачен %s (mass=%.1f, layer=[%s])" % [item.name, item.mass, _layer_name(item.collision_layer)])
	grabbed.emit(_held)


func _release() -> void:
	if not _held:
		return
	var item_name := str(_held.name)
	_held.freeze = false
	var v := _smoothed_velocity() * throw_strength
	if v.length() > max_throw_speed:
		v = v.normalized() * max_throw_speed
	_held.linear_velocity = v
	if debug_log:
		print("[Hand] отпущен %s, v=(%.2f, %.2f, %.2f), |v|=%.2f" % [item_name, v.x, v.y, v.z, v.length()])
	released.emit(_held, v)
	_held = null


func _update_held_position() -> void:
	if _held:
		_held.global_position = global_position + hold_offset


func _update_candidate_highlight() -> void:
	# Кандидат — ближайший Item в GrabArea, проходящий по массе.
	# Пока что-то держим — кандидата нет (всё равно не сможем поднять второй).
	var candidate: Item = null
	if not _held:
		candidate = _find_closest_item(grab_area.get_overlapping_bodies())
	if candidate == _current_candidate:
		return
	if _current_candidate and is_instance_valid(_current_candidate):
		_current_candidate.set_highlighted(false)
	if candidate:
		candidate.set_highlighted(true)
	if debug_log:
		if candidate:
			print("[Hand] кандидат: %s" % candidate.name)
		elif _current_candidate:
			print("[Hand] кандидат: —")
	_current_candidate = candidate


func _smoothed_velocity() -> Vector3:
	if _velocity_history.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for v in _velocity_history:
		sum += v
	return sum / _velocity_history.size()


# --- Логирование ---

func _log_surface(result: Dictionary, surface_y: float) -> void:
	var label: String
	if result.is_empty():
		label = "(none)"
	else:
		var collider = result.collider
		var n := str(collider.name) if collider else "?"
		var layer_bits: int = 0
		if collider and "collision_layer" in collider:
			layer_bits = collider.collision_layer
		label = "%s [%s]" % [n, _layer_name(layer_bits)]
	if label != _last_surface_label:
		print("[Hand] поверхность: %s, y=%.2f" % [label, surface_y])
		_last_surface_label = label


func _layer_name(bits: int) -> String:
	if bits == 0:
		return "—"
	var names: Array[String] = []
	for i in range(32):
		if (bits & (1 << i)) != 0:
			var key := "layer_names/3d_physics/layer_%d" % (i + 1)
			var raw = ProjectSettings.get_setting(key, "")
			var n: String = str(raw) if raw else ""
			if n.is_empty():
				n = "layer_%d" % (i + 1)
			names.append(n)
	return ",".join(names)
