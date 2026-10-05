extends RigidBody3D
## Physical small object: swept flight, one impact, and recovery outside the range.
var arena
var thrown := false
var flight_age := 0.0
var previous_velocity := Vector3.ZERO
var safe_position := Vector3.INF
var navigation_position := Vector3.INF

func _ready() -> void:
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 8
	linear_damp = 1.6
	angular_damp = 2.0
	body_entered.connect(_on_contact)

func on_hand_grab() -> void:
	thrown = false
	previous_velocity = Vector3.ZERO
	_update_navigation(true)

func on_hand_release(motion: Vector3) -> void:
	linear_velocity = motion
	previous_velocity = motion
	flight_age = 0.0
	thrown = motion.length() >= 8.0
	if thrown: collision_mask |= 2 | 4 | 32 | 64
	_update_navigation(true)

func _update_navigation(force: bool = false) -> void:
	if not (collision_layer & (33 if arena.level else 1)) or not is_instance_valid(arena.battle): return
	if force or not navigation_position.is_finite() or navigation_position.distance_to(global_position) > 0.75:
		navigation_position = global_position
		arena.battle.nav_dirty = true

func _physics_process(dt: float) -> void:
	if freeze: return
	_update_navigation()
	flight_age += dt
	if not safe_position.is_finite(): safe_position = get_meta("hand_home", global_position)
	var height: float=global_position.y-arena.ground_height(global_position)
	if arena.world_bounds.grow(-1.5).has_point(Vector2(global_position.x, global_position.z)) and height > -0.1 and height < 4.0 and linear_velocity.length() < 1.0:
		safe_position = global_position
	if global_position.y < -8.0 or not arena.world_bounds.grow(4.0).has_point(Vector2(global_position.x, global_position.z)):
		global_position = safe_position + Vector3.UP
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		_finish_throw()
	if thrown and flight_age > 0.25 and linear_velocity.length() < 1.0: _finish_throw()
	previous_velocity = linear_velocity

func _finish_throw() -> void:
	thrown = false
	collision_mask = get_meta("hand_free_mask", 9)

func _on_contact(other: Node) -> void:
	if not thrown or freeze or flight_age < 0.025: return
	var motion := previous_velocity if previous_velocity.length() > linear_velocity.length() else linear_velocity
	if motion.length() < 5.0: return
	_finish_throw()
	_resolve_impact.call_deferred(weakref(other), motion)

func _resolve_impact(ref: WeakRef, motion: Vector3) -> void:
	if is_queued_for_deletion() or freeze or has_meta("hand_owner"): return
	var other = ref.get_ref()
	var direction := motion.normalized()
	var damage := clampf(motion.length() * mass * 0.8, 6.0, 60.0)
	if is_instance_valid(other):
		if other.has_meta("enemy"): other.take_damage(damage, direction, 10.0)
		elif other.has_meta("breakable"): arena.props.shatter(other, direction, 1.5)
		elif other.has_meta("target"): arena._damage_target(other, damage, direction, 8.0)
		elif other.has_method("take_damage") and other != arena.tank: other.take_damage(damage, direction * 4.0)
	if get_meta("breakable", false):
		arena.props.shatter(self, direction, clampf(motion.length() / 10.0, 1.0, 3.0))
	elif has_meta("spec") and get_meta("spec").barrel:
		arena._damage_target(self, 99.0, direction)
	else:
		arena.fx.repeater_hit(global_position, -direction)
		arena.sound.play("lock", -10.0, 0.65)
