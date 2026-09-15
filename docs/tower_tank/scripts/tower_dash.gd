extends Node3D
## Short Space release -> dash; hold -> super aim -> RMB, without an initial dash.
const Geo = preload("res://scripts/geo.gd")
const SPEED := 22.0
const DISTANCE := SPEED * 0.24
const SUPER_SPEED := 34.0
const SUPER_DISTANCE := SUPER_SPEED * 0.34
const COOLDOWN := 0.8
const HOLD_THRESHOLD := 0.3
const SLOWMO := 0.15
enum Mode { IDLE, HOLDING, AIMING, WAIT_RELEASE }
var actor
var arena
var mode := Mode.IDLE
var active := false
var is_super := false
var cooldown := 0.0
var remaining := 0.0
var total_distance := 1.0
var direction := Vector3.FORWARD
var hold_time := 0.0
var press_started_usec := 0
var pending_normal := false
var pending_super := false
var pending_target := Vector3.ZERO
var landing := Vector3.ZERO
var preview_blocked := false
var visual_amount := 0.0
var echo_timer := 0.0
var normal_count := 0
var super_count := 0
var hit_ids: Array[int] = []
var marker: MeshInstance3D
var range_line: MeshInstance3D
var preview_shape: Shape3D

func _ready() -> void:
	preview_shape = actor.hull_shape.duplicate()
	var mat := Geo.material(Color("70dcd5"), 0, 1.5)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker = Geo.ring(arena, 1.4, 0.07, Vector3.ZERO, mat)
	marker.scale.y = 0.1
	range_line = Geo.box(arena, Vector3(0.075, 0.035, 1.0), Vector3.ZERO, mat)
	Geo.mark_ui(marker)
	Geo.mark_ui(range_line)
	_hide_preview()

func is_aiming() -> bool:
	return mode == Mode.AIMING

func blocks_gun() -> bool:
	return is_aiming() or pending_super

func space(pressed: bool) -> void:
	if actor.dead: return
	if not pressed:
		# Classify using real input time, including a release before the next frame.
		var short_tap := mode == Mode.HOLDING and _held_seconds() < HOLD_THRESHOLD
		if is_aiming(): _leave_aim()
		mode = Mode.IDLE
		hold_time = 0.0
		press_started_usec = 0
		if short_tap and arena.crew.crewed and not arena.tuning_open and cooldown <= 0.0 and not active:
			pending_normal = true
		return
	if not arena.crew.crewed or not arena.crew.input_armed or arena.tuning_open or mode != Mode.IDLE:
		return
	if cooldown > 0.0 or active or pending_normal or pending_super:
		arena.crew.tell("Рывок: %.1f с до готовности" % cooldown)
		return
	mode = Mode.HOLDING
	hold_time = 0.0
	press_started_usec = Time.get_ticks_usec()

func _held_seconds() -> float:
	return float(Time.get_ticks_usec() - press_started_usec) / 1000000.0

func commit() -> bool:
	if not is_aiming() or arena.pointer_over_ui(): return false
	pending_target = landing_point(arena.ground_aim_position)
	pending_super = true
	_leave_aim()
	mode = Mode.WAIT_RELEASE
	return true

func frame(real_dt: float) -> void:
	if actor.dead or not arena.crew.crewed or arena.tuning_open:
		if active or mode != Mode.IDLE or pending_normal or pending_super: cancel()
		return
	if mode == Mode.HOLDING:
		hold_time = _held_seconds()
		if hold_time >= HOLD_THRESHOLD:
			active = false
			remaining = 0.0
			actor.stop_drive()
			actor.kick_velocity = Vector3.ZERO
			actor.buffered_shot = 0.0
			mode = Mode.AIMING
			actor.crossbows.cancel_trigger()
			Engine.time_scale = SLOWMO
			arena.sound.play("dash_charge", -4.0)
	if is_aiming():
		landing = landing_point(arena.ground_aim_position)
		marker.show()
		range_line.show()
		marker.global_position = landing + Vector3.UP * 0.055
		var from: Vector3 = actor.global_position + Vector3.UP * 0.06
		var to := landing + Vector3.UP * 0.06
		range_line.global_position = (from + to) * 0.5
		range_line.scale.z = maxf(from.distance_to(to), 0.001)
		if from.distance_squared_to(to) > 0.001: range_line.look_at(to)
	visual_amount = lerpf(visual_amount, 1.0 if active else 0.0, 1.0 - exp(-14.0 * real_dt))

func landing_point(cursor: Vector3) -> Vector3:
	var origin: Vector3 = actor.global_position
	var offset := Vector3(cursor.x - origin.x, 0, cursor.z - origin.z)
	var length := minf(offset.length(), SUPER_DISTANCE)
	if length < 0.05:
		preview_blocked = false
		return origin
	var motion := offset.normalized() * length
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = preview_shape
	query.transform = actor.global_transform
	query.transform.origin += Vector3.UP * actor.HULL_HEIGHT * 0.5
	query.motion = motion
	query.collision_mask = 1
	# Range targets can be rammed through; permanent walls still stop the whole hull.
	var excluded: Array[RID] = [actor.get_rid()]
	for target in arena.targets:
		if float(target.get_meta("hp")) <= 130.0: excluded.append(target.get_rid())
	query.exclude = excluded
	var sweep := get_world_3d().direct_space_state.cast_motion(query)
	var fraction: float = sweep[0] if not sweep.is_empty() else 1.0
	preview_blocked = fraction < 0.999
	return origin + motion * maxf(0.0, fraction - (0.025 / length if preview_blocked else 0.0))

func tick(dt: float) -> void:
	cooldown = maxf(0.0, cooldown - dt)
	if pending_super:
		pending_super = false
		pending_normal = false
		var offset: Vector3 = pending_target - actor.global_position
		offset.y = 0.0
		if offset.length() > 0.05 and arena.crew.crewed:
			_start(offset.normalized(), minf(offset.length(), SUPER_DISTANCE), true)
	elif pending_normal:
		pending_normal = false
		if arena.crew.crewed and cooldown <= 0.0:
			_start(actor.dash_direction(), DISTANCE, false)

func _start(dir: Vector3, distance: float, super_dash: bool) -> void:
	active = true
	is_super = super_dash
	direction = dir.normalized()
	remaining = distance
	total_distance = distance
	cooldown = COOLDOWN
	echo_timer = 0.0
	hit_ids.clear()
	actor.stop_drive()
	actor.kick_velocity = Vector3.ZERO
	actor.walker.brace(1.1 if super_dash else 0.5)
	if super_dash: super_count += 1
	else: normal_count += 1
	arena.sound.play("dash", -1.0 if super_dash else -6.0, 0.72 if super_dash else 1.0)
	arena.add_trauma(0.35 if super_dash else 0.13)
	arena.fx.ring(actor.global_position + Vector3.UP * 0.06, 0.55 if super_dash else 0.28, arena.fx.dash_mat)
	if super_dash:
		arena.flash_alpha = maxf(arena.flash_alpha, 0.075)
		arena.zoom_punch = 0.65

func move(dt: float) -> void:
	var travel := minf(remaining, (SUPER_SPEED if is_super else SPEED) * dt)
	var motion := direction * travel
	var start: Vector3 = actor.global_position
	var blocked := false
	for i in 8:
		if motion.length_squared() < 0.000001: break
		var collision: KinematicCollision3D = actor.move_and_collide(motion, false, 0.001)
		if collision == null: break
		var collider := collision.get_collider()
		if collider is Node3D and (collider.has_meta("target") or collider.has_meta("enemy")):
			var id: int = collider.get_instance_id()
			if not hit_ids.has(id):
				hit_ids.append(id)
				arena._damage_target(collider, 130.0 if is_super else 100.0, direction, 18.0)
			if not arena.combat_targets().has(collider):
				motion = collision.get_remainder()
				continue
		blocked = true
		break
	var moved: float = (actor.global_position - start).length()
	remaining = maxf(0.0, remaining - moved)
	actor.velocity = (actor.global_position - start) / maxf(dt, 0.00001)
	echo_timer -= dt
	if echo_timer <= 0.0:
		echo_timer = 0.05
		arena.fx.dash_echo(actor, direction, is_super)
		if is_super: arena.fx.ring(actor.global_position + Vector3.UP * 0.05, 0.20, arena.fx.dash_mat)
	if blocked or remaining <= 0.005 or moved < 0.0001:
		_finish(blocked)

func _finish(blocked: bool) -> void:
	active = false
	remaining = 0.0
	actor.speed = 0.0
	actor.velocity = Vector3.ZERO
	actor.walker.brace(1.2 if is_super else 0.55)
	var pos: Vector3 = actor.global_position + Vector3.UP * 0.06
	arena.fx.ring(pos, 0.65 if is_super else 0.30, arena.fx.dash_mat if is_super else arena.fx.dust_mat)
	for i in (14 if is_super else 7):
		var outward := Vector3(sin(i * 2.4), 0, cos(i * 2.4))
		arena.fx.dust(pos + outward * 0.8, outward * -8.0)
	arena.sound.play("step", 0.0 if is_super else -6.0, 0.7)
	arena.add_trauma(0.40 if is_super else (0.24 if blocked else 0.10))
	if is_super:
		arena.freeze = maxf(arena.freeze, 0.065)
		arena.props.blast(pos, 2.8)

func _hide_preview() -> void:
	if marker: marker.hide()
	if range_line: range_line.hide()

func _leave_aim() -> void:
	Engine.time_scale = 1.0
	_hide_preview()
	actor.buffered_shot = 0.0

func cancel() -> void:
	_leave_aim()
	mode = Mode.IDLE
	hold_time = 0.0
	press_started_usec = 0
	pending_normal = false
	pending_super = false
	active = false
	remaining = 0.0

func reset() -> void:
	cancel()
	cooldown = 0.0
	visual_amount = 0.0
	normal_count = 0
	super_count = 0
	hit_ids.clear()

func _exit_tree() -> void:
	Engine.time_scale = 1.0
