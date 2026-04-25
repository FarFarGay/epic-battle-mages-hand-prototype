extends Node
## Категория "Физические действия" руки.
##
## Действия:
##   1. Захват / бросок (ЛКМ) — постоянно доступен.
##   2. Активная способность (ПКМ) — диспатчится по `equipped`:
##        - "slam"  — хлопок по земле, AOE-разлёт.
##        - "flick" — щелбан, орбита вокруг цели и выстрел.
##      Смена способности на клавишах 1 / 2.
##
## Зависит только от родителя — типа Hand. Через него получает позицию,
## сглаженную скорость, доступ к Area-зонам и lock_position() для щелбана.

signal grabbed(item: Item)
signal released(item: Item, velocity: Vector3)
signal slammed(position: Vector3, radius: float)
signal flicked(target: Item, velocity: Vector3)

const ABILITY_SLAM := "slam"
const ABILITY_FLICK := "flick"

@export var max_lift_mass: float = 10.0
@export var throw_strength: float = 1.2
@export var max_throw_speed: float = 30.0
@export var hold_offset: Vector3 = Vector3(0, -1.0, 0)
@export var magnet_force: float = 30.0

@export_group("Equipment")
## Текущая активная способность. Меняется клавишами 1 / 2 в рантайме.
@export_enum("slam", "flick") var equipped: String = ABILITY_SLAM:
	set(value):
		if equipped == value:
			return
		equipped = value
		if is_inside_tree() and debug_log:
			print("[Hand:Physical] экипировано: %s" % value)

@export_group("Slam (RMB)")
@export var slam_radius: float = 5.0
@export var slam_force: float = 30.0
@export var slam_lift_factor: float = 0.4
@export var slam_damage: float = 20.0
@export var slam_cooldown: float = 0.5
## По каким слоям бьёт хлопок: Items + Actors по умолчанию.
@export_flags_3d_physics var slam_mask: int = 6
@export var slam_visual_color: Color = Color(1.0, 0.7, 0.3, 0.6)

@export_group("Flick (RMB hold-release)")
@export var flick_orbit_radius: float = 1.5
@export var flick_force: float = 25.0
@export var flick_damage: float = 5.0

@export_group("")
@export var debug_log: bool = true

var _hand: Hand
var _held: Item = null
var _is_grabbing: bool = false
var _current_candidate: Item = null
var _slam_cooldown_remaining: float = 0.0
# Текущее активное действие на ПКМ ("" если нет, "slam" если хлопок только что выпущен,
# "flick" если рука сейчас в орбите). Slam-у это поле нужно, только чтобы корректно
# игнорировать LMB-грабинг во время фик'а.
var _action_active: String = ""
var _flick_target: Item = null
# Текущее горизонтальное направление от цели к руке. Обновляется каждый кадр
# из cursor_world_position(); если курсор «заехал» прямо на цель и горизонталь
# пропала — держим прошлое направление, а не дрожим.
var _flick_orbit_dir: Vector3 = Vector3.RIGHT

# Логирование (фронт-триггеры)
var _was_magnetizing: bool = false
var _magnet_target_name: String = ""


func _ready() -> void:
	_hand = get_parent() as Hand
	if not _hand:
		push_error("HandPhysical: родитель не Hand")


func _process(delta: float) -> void:
	if _slam_cooldown_remaining > 0.0:
		_slam_cooldown_remaining = maxf(_slam_cooldown_remaining - delta, 0.0)
	_handle_input()
	_update_held_position()
	_update_candidate_highlight()
	_update_flick(delta)


func _physics_process(_delta: float) -> void:
	# Магнит и попытка захвата — в физик-кадре, чтобы силы суммировались стабильно.
	if _is_grabbing and not _held:
		_try_grab()
		if not _held:
			_apply_magnet()
		elif debug_log and _was_magnetizing:
			_was_magnetizing = false
			_magnet_target_name = ""


# --- Публичный API ---

func get_held_item() -> Item:
	return _held


func is_holding() -> bool:
	return _held != null


# --- Ввод ---

func _handle_input() -> void:
	# Смена экипировки доступна всегда.
	if Input.is_action_just_pressed("equip_slam"):
		equipped = ABILITY_SLAM
	elif Input.is_action_just_pressed("equip_flick"):
		equipped = ABILITY_FLICK

	# Триггер активной способности (ПКМ).
	if _action_active == "":
		if Input.is_action_just_pressed("hand_action"):
			_dispatch_action_press()
	else:
		if Input.is_action_just_released("hand_action"):
			_dispatch_action_release()
			_action_active = ""

	# LMB-грабинг — пока активен flick, отключён, чтобы не схватить цель щелбана.
	if _action_active == ABILITY_FLICK:
		return
	if Input.is_action_just_pressed("hand_grab"):
		_is_grabbing = true
		_try_grab()
	elif Input.is_action_just_released("hand_grab"):
		_is_grabbing = false
		_release()


func _dispatch_action_press() -> void:
	match equipped:
		ABILITY_SLAM:
			if _slam_cooldown_remaining <= 0.0:
				_perform_slam()
			elif debug_log:
				print("[Hand:Physical] хлопок на кулдауне (%.2fs)" % _slam_cooldown_remaining)
			# Slam — one-shot, никакого hold-state не остаётся.
		ABILITY_FLICK:
			_flick_pressed()
			if _flick_target != null:
				_action_active = ABILITY_FLICK


func _dispatch_action_release() -> void:
	match _action_active:
		ABILITY_FLICK:
			_flick_released()


# --- Захват / бросок / магнит ---

func _try_grab() -> void:
	if _held:
		return
	var closest := _find_closest_item(_hand.grab_area.get_overlapping_bodies())
	if closest:
		_attach(closest)


func _apply_magnet() -> void:
	var closest := _find_closest_item(_hand.magnet_area.get_overlapping_bodies())
	if not closest:
		if debug_log and _was_magnetizing:
			print("[Hand:Physical] магнит: цели нет")
			_was_magnetizing = false
			_magnet_target_name = ""
		return
	var to_hand: Vector3 = _hand.global_position - closest.global_position
	if to_hand.length_squared() < 0.0001:
		return
	closest.apply_central_force(to_hand.normalized() * magnet_force)
	if debug_log and (not _was_magnetizing or _magnet_target_name != str(closest.name)):
		print("[Hand:Physical] магнит тянет %s (mass=%.1f, dist=%.2f)" % [closest.name, closest.mass, to_hand.length()])
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
			var d := _hand.global_position.distance_to(item.global_position)
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
		print("[Hand:Physical] схвачен %s (mass=%.1f)" % [item.name, item.mass])
	grabbed.emit(_held)


func _release() -> void:
	if not _held:
		return
	var item_name := str(_held.name)
	_held.freeze = false
	var v := _hand.smoothed_velocity() * throw_strength
	if v.length() > max_throw_speed:
		v = v.normalized() * max_throw_speed
	_held.linear_velocity = v
	if debug_log:
		print("[Hand:Physical] отпущен %s, v=(%.2f, %.2f, %.2f), |v|=%.2f" % [item_name, v.x, v.y, v.z, v.length()])
	released.emit(_held, v)
	_held = null


func _update_held_position() -> void:
	if _held:
		_held.global_position = _hand.global_position + hold_offset


# --- Slam ---

func _perform_slam() -> void:
	var origin: Vector3 = _hand.global_position
	_slam_cooldown_remaining = slam_cooldown

	var space := _hand.get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = slam_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), origin)
	query.collision_mask = slam_mask
	query.collide_with_bodies = true
	var results := space.intersect_shape(query, 32)

	var affected_count := 0
	for r in results:
		var collider = r.collider
		if collider is Item:
			var item := collider as Item
			if item.freeze:
				continue
			_apply_slam_to(item, origin)
			affected_count += 1

	if debug_log:
		print("[Hand:Physical] хлопок @ (%.1f, %.1f, %.1f), задело: %d" % [origin.x, origin.y, origin.z, affected_count])

	_spawn_slam_visual(origin)
	slammed.emit(origin, slam_radius)


func _apply_slam_to(item: Item, origin: Vector3) -> void:
	var to_item: Vector3 = item.global_position - origin
	var horizontal_dist := Vector2(to_item.x, to_item.z).length()
	var falloff: float = clampf(1.0 - horizontal_dist / slam_radius, 0.0, 1.0)
	if falloff <= 0.0:
		return
	var horizontal_dir := Vector3(to_item.x, 0.0, to_item.z)
	if horizontal_dir.length_squared() < 0.0001:
		horizontal_dir = Vector3.UP
	else:
		horizontal_dir = horizontal_dir.normalized() + Vector3.UP * slam_lift_factor
		horizontal_dir = horizontal_dir.normalized()
	item.apply_central_impulse(horizontal_dir * slam_force * falloff)
	item.take_damage(slam_damage * falloff)


func _spawn_slam_visual(pos: Vector3) -> void:
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.2
	sphere.height = 0.4
	mesh.mesh = sphere

	var mat := StandardMaterial3D.new()
	mat.albedo_color = slam_visual_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(slam_visual_color.r, slam_visual_color.g, slam_visual_color.b)
	mat.emission_energy_multiplier = 2.0
	mesh.material_override = mat

	var scene_root := get_tree().current_scene
	scene_root.add_child(mesh)
	mesh.global_position = pos

	var target_scale: float = slam_radius / sphere.radius
	var tween := mesh.create_tween()
	tween.set_parallel(true)
	tween.tween_property(mesh, "scale", Vector3.ONE * target_scale, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	get_tree().create_timer(0.31).timeout.connect(mesh.queue_free)


# --- Flick (щелбан) ---

func _flick_pressed() -> void:
	if _held:
		if debug_log:
			print("[Hand:Physical] щелбан: рука занята, сначала отпустите предмет")
		return
	var target := _find_closest_item(_hand.grab_area.get_overlapping_bodies())
	if not target:
		if debug_log:
			print("[Hand:Physical] щелбан: предмета под рукой нет")
		return
	_flick_target = target
	# Стартовое направление — текущая горизонтальная разница руки и цели.
	# Если рука прямо над целью (XZ почти совпадают) — берём дефолтный +X.
	var to_hand_h := Vector3(_hand.global_position.x - target.global_position.x, 0.0, _hand.global_position.z - target.global_position.z)
	if to_hand_h.length_squared() > 0.0001:
		_flick_orbit_dir = to_hand_h.normalized()
	else:
		_flick_orbit_dir = Vector3.RIGHT
	_hand.lock_position(true)
	if debug_log:
		print("[Hand:Physical] щелбан: захват цели %s" % target.name)


func _update_flick(_delta: float) -> void:
	if _action_active != ABILITY_FLICK:
		return
	if not is_instance_valid(_flick_target):
		# Цель уничтожилась во время прицеливания — отменяем.
		_hand.lock_position(false)
		_flick_target = null
		_action_active = ""
		return
	# Направление берём из курсора: куда мышь — там и рука относительно цели.
	# Если курсор совсем близко к цели — держим прошлое направление, без рывков.
	var cursor: Vector3 = _hand.cursor_world_position()
	var to_cursor_h := Vector3(cursor.x - _flick_target.global_position.x, 0.0, cursor.z - _flick_target.global_position.z)
	if to_cursor_h.length_squared() > 0.0001:
		_flick_orbit_dir = to_cursor_h.normalized()
	_hand.global_position = _flick_target.global_position + _flick_orbit_dir * flick_orbit_radius


func _flick_released() -> void:
	_hand.lock_position(false)
	if not is_instance_valid(_flick_target):
		_flick_target = null
		return
	var dir: Vector3 = _flick_target.global_position - _hand.global_position
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		_flick_target = null
		return
	dir = dir.normalized()
	var velocity: Vector3 = dir * flick_force
	_flick_target.apply_central_impulse(velocity)
	_flick_target.take_damage(flick_damage)
	if debug_log:
		print("[Hand:Physical] щелбан: %s полетел в (%.2f, %.2f), |v|=%.2f" % [_flick_target.name, dir.x, dir.z, velocity.length()])
	flicked.emit(_flick_target, velocity)
	_flick_target = null


# --- Подсветка кандидата ---

func _update_candidate_highlight() -> void:
	var candidate: Item = null
	if not _held:
		candidate = _find_closest_item(_hand.grab_area.get_overlapping_bodies())
	if candidate == _current_candidate:
		return
	if _current_candidate and is_instance_valid(_current_candidate):
		_current_candidate.set_highlighted(false)
	if candidate:
		candidate.set_highlighted(true)
	if debug_log:
		if candidate:
			print("[Hand:Physical] кандидат: %s" % candidate.name)
		elif _current_candidate:
			print("[Hand:Physical] кандидат: —")
	_current_candidate = candidate
