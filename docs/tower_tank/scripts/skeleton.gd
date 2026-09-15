extends CharacterBody3D
## Ordinary Skeleton/Enemy from the main project, without its world autoloads.
## Same base stats, variance, windup -> lunge -> recovery and interruptible attacks.
const Geo = preload("res://scripts/geo.gd")
enum State { APPROACH, WINDUP, LUNGE, RECOVERY, STAGGER }
var battle
var arena
var giant := false
var body_size := 1.0
var body_radius := 0.4
var body_height := 1.9
var hp := 30.0
var max_hp := 30.0
var move_speed := 2.0
var attack_damage := 8.0
var attack_windup := 0.4
var close_windup := 0.1
var attack_cooldown := 1.0
var dead := false
var state := State.APPROACH
var timer := 0.0
var target: Node3D
var attack_direction := Vector3.FORWARD
var impulse := Vector3.ZERO
var scan_left := 0.0
var path_left := 0.0
var path := PackedVector3Array()
var stride := 0.0
var hit_flash := 0.0
var bump_cooldown := 0.0
var attacks := 0
var hits := 0
var visual: Node3D
var warning: Node3D
var animation_speed := 0.0
var body_lean := 0.1
var move_direction := Vector3.ZERO
var separation_force := Vector3.ZERO
var separation_wait := 0.0
var walk_clearance := 1.0
var pending_dt := 0.0
var render_from := Vector3.ZERO
var render_stride := 0.0
var render_time := -1.0
var render_period := 0.0333333
var sim_slot := 0
var crowd_index := 0
var hand_held := false
var hand_thrown := false

func _ready() -> void:
	name = "SkeletonBrute" if giant else "Skeleton"
	if giant:
		body_size = 1.8
		body_radius = 0.72
		body_height = 3.42
		hp = 360.0
		move_speed = 1.55
		attack_damage = 24.0
		attack_windup = 0.75
		close_windup = 0.5
		attack_cooldown = 1.65
	collision_layer = 64
	collision_mask = 0 # Queryable by weapons; walking collision uses the crowd grid.
	floor_snap_length = 0.3
	set_meta("enemy", true)
	var rng: RandomNumberGenerator = battle.rng
	if not giant: hp *= rng.randf_range(0.8, 1.2)
	max_hp = hp
	move_speed *= rng.randf_range(0.85, 1.15)
	attack_damage *= rng.randf_range(0.8, 1.2)
	attack_windup *= rng.randf_range(0.8, 1.2)
	close_windup *= rng.randf_range(0.8, 1.2)
	attack_cooldown *= rng.randf_range(0.85, 1.15)
	scan_left = rng.randf_range(0.0, 0.4)
	path_left = rng.randf_range(0.0, 0.5)
	separation_wait = rng.randf_range(0.0, 0.12)
	var capsule := CapsuleShape3D.new()
	capsule.radius = body_radius
	capsule.height = body_height
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = body_height * 0.5
	add_child(shape)
	_build()
	preload("res://scripts/tower_hand.gd").register_item(self, Vector3(body_radius * 2.0, body_height, body_radius * 2.0), "СКЕЛЕТ-ГРОМИЛА" if giant else "СКЕЛЕТ", Vector3.UP * body_height * 0.5)

func _build() -> void:
	visual = Node3D.new()
	add_child(visual)
	warning = Node3D.new()
	add_child(warning)
	warning.hide()

func tick(dt: float) -> void:
	var profile_start := Time.get_ticks_usec() if battle.profile_enabled else 0
	if dead: return
	bump_cooldown = maxf(0.0, bump_cooldown - dt)
	hit_flash = maxf(0.0, hit_flash - dt)
	if hand_held:
		warning.hide()
		stride += dt * 9.0
		animation_speed = 0.0
		return
	if hand_thrown:
		_tick_throw(dt)
		return
	scan_left -= dt
	if not battle.valid_target(target) or scan_left <= 0.0:
		target = battle.choose_target(self)
		scan_left = 0.4
	var desired := Vector3.ZERO
	timer -= dt
	if state == State.STAGGER:
		desired = impulse
		impulse = impulse.move_toward(Vector3.ZERO, 20.0 * dt)
		if timer <= 0.0: state = State.APPROACH
	elif state == State.LUNGE:
		desired = attack_direction * (6.0 if giant else 8.0)
		if timer <= 0.0:
			state = State.RECOVERY
			timer = attack_cooldown
	elif state == State.RECOVERY:
		if timer <= 0.0: state = State.APPROACH
	elif battle.valid_target(target):
		var offset := target.global_position - global_position
		offset.y = 0.0
		var direction := offset.normalized()
		rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), 1.0 - exp(-12.0 * dt))
		var reach: float = (1.32 if target == arena.tank else 0.0) + (0.5 if giant else 0.0)
		if state == State.WINDUP:
			desired = direction * 1.5
			if timer <= 0.0: _strike(direction)
		elif offset.length() <= 1.5 + reach and battle.clear_sight(global_position, target.global_position, target):
			state = State.WINDUP
			timer = close_windup if offset.length() <= 1.05 + reach else attack_windup
		else:
			path_left -= dt
			if path_left <= 0.0:
				move_direction = battle.flow_direction(position, target.position)
				path_left = 0.10
			desired = move_direction * move_speed
	else:
		state = State.APPROACH
	var profile_steer := Time.get_ticks_usec() if battle.profile_enabled else 0
	separation_wait -= dt
	if separation_wait <= 0.0:
		separation_wait = 0.10
		var neighbors: Vector4 = battle.separation(crowd_index, position, move_direction)
		separation_force = Vector3(neighbors.x, neighbors.y, neighbors.z)
		walk_clearance = neighbors.w
	if state == State.APPROACH: desired *= walk_clearance
	if state != State.STAGGER: desired += separation_force
	var profile_move := Time.get_ticks_usec() if battle.profile_enabled else 0
	velocity = Vector3(desired.x, -2.0 if position.y < 0.19 else velocity.y - 20.0 * dt, desired.z)
	battle.move_ground(self, dt)
	if battle.profile_enabled:
		battle.last_profile.logic += profile_steer - profile_start
		battle.last_profile.separation += profile_move - profile_steer
		battle.last_profile.move += Time.get_ticks_usec() - profile_move
	_animate(dt, desired.length())

func can_hand_grab() -> bool:
	return not dead and not giant

func on_hand_grab() -> void:
	hand_held = true
	hand_thrown = false
	velocity = Vector3.ZERO
	impulse = Vector3.ZERO
	state = State.APPROACH
	timer = 0.0
	warning.hide()
	visual.rotation = Vector3.ZERO
	visual.scale = Vector3.ONE
	visual.position = Vector3.ZERO
	body_lean = 0.0

func on_hand_release(motion: Vector3) -> void:
	hand_held = false
	if dead:
		collision_layer = 0
		collision_mask = 0
		return
	hand_thrown = true
	velocity = motion
	floor_snap_length = 0.0
	collision_mask = 71 | 8 | 32
	warning.hide()

func _tick_throw(dt: float) -> void:
	velocity.y -= 20.0 * dt
	var collision := move_and_collide(velocity * dt)
	visual.rotation.z += dt * velocity.length() * 0.13
	if not collision: return
	var normal := collision.get_normal()
	var speed := velocity.length()
	var direction := velocity.normalized()
	var other = collision.get_collider()
	if speed > 8.0:
		if is_instance_valid(other):
			if other.has_meta("enemy"): other.take_damage(minf(55.0, speed * 1.8), direction, 10.0)
			elif other.has_meta("breakable"): arena.props.shatter(other, direction, 1.5)
			elif other.has_meta("target"): arena._damage_target(other, minf(55.0, speed * 1.8), direction, 8.0)
		arena.fx.repeater_hit(global_position + Vector3.UP * 0.7, -direction)
		arena.sound.play("shatter", -9.0, 0.7)
		take_damage(clampf((speed - 8.0) * 2.0, 0.0, 60.0), direction, 0.0)
		if dead: return
	if normal.dot(Vector3.UP) > 0.45:
		hand_thrown = false
		floor_snap_length = 0.3
		collision_mask = 0
		visual.rotation = Vector3.ZERO
		state = State.RECOVERY
		timer = 0.45
		velocity = Vector3.ZERO
		path.clear()
		path_left = 0.0
	else:
		velocity = velocity.bounce(normal) * 0.3

func _strike(direction: Vector3) -> void:
	state = State.LUNGE
	timer = 0.2
	attack_direction = direction
	attacks += 1
	for victim in battle.player_targets():
		var offset: Vector3 = victim.global_position - global_position
		offset.y = 0.0
		var radius := 1.95 + (1.32 if victim == arena.tank else 0.0) + (0.5 if giant else 0.0)
		if offset.length() <= radius and battle.clear_sight(global_position, victim.global_position, victim):
			if victim == arena.tank: victim.take_damage(attack_damage)
			else: victim.take_damage(attack_damage, offset.normalized() * 0.2)
			hits += 1
			arena.fx.repeater_hit(victim.global_position + Vector3.UP * 0.8, -direction)
	var slash := Geo.line(arena.fx, position + Vector3.UP * body_size + direction * 0.4, position + Vector3.UP * body_size + direction * (1.8 + (0.5 if giant else 0.0)), 0.065 * body_size, arena.fx.hot)
	arena.fx.add_piece(slash, direction * 3.0, 0.12)
	arena.sound.play("bow", -10.0 if giant else -14.0, 0.42 if giant else 0.65)

func _animate(dt: float, speed: float) -> void:
	stride += speed * dt * 3.3 / body_size
	animation_speed = speed
	var windup := state == State.WINDUP
	warning.visible = windup
	body_lean = lerpf(body_lean, -0.22 if windup else (0.48 if state == State.LUNGE else 0.10), 1.0 - exp(-22.0 * dt))
func take_damage(amount: float, direction: Vector3 = Vector3.ZERO, force: float = 0.0, source: StringName = &"") -> void:
	if dead or amount <= 0.0: return
	if giant and source == &"crew": amount *= 0.5
	var before := hp
	hp = maxf(0.0, hp - amount)
	hit_flash = 0.11
	scan_left = 0.0
	arena.hit_pulse = 1.0
	if hp <= 0.0:
		dead = true
		collision_layer = 0
		collision_mask = 0
		hide()
		var power := 1.0 + clampf((amount - before) / maxf(before, 1.0), 0.0, 3.0) * 0.6
		battle.crowd.scatter(self, direction, power)
		battle.killed(self)
		queue_free()
	elif force > 0.0 and (not giant or force >= 6.0):
		state = State.STAGGER
		timer = 0.25
		impulse = direction * force * (0.4 if giant else 1.0)
		warning.hide()
