extends CharacterBody3D
const Geo = preload("res://scripts/geo.gd")
const Walker = preload("res://scripts/walker.gd")
const Dash = preload("res://scripts/tower_dash.gd")
const Crossbows = preload("res://scripts/side_crossbows.gd")
const Model = preload("res://scripts/tower_model.gd")
const HULL_RADIUS := 1.32
const HULL_HEIGHT := 5.8
const MAX_HP := 1000.0
var hp := MAX_HP
var dead := false
var damage_pulse := 0.0

@export_group("Driving")
@export var forward_speed := 7.4
# A short build-up and coast give the tower weight; countersteering stays quick.
@export var acceleration := 28.0
@export var braking := 38.0
@export var direction_braking := 80.0
@export var turn_speed := 8.0
@export_range(0.6, 1.6, 0.05) var drive_response := 1.0
@export_group("Cruising")
@export_range(1.0, 3.0, 0.1) var cruise_multiplier := 2.0
@export var cruise_acceleration := 6.0
@export_group("Gun feel")
@export var aim_lag := 0.18
@export var turret_speed := 3.1
@export var reload_time := 1.65
@export var recoil_force := 1.0

var arena
var body_visual: Node3D
var turret: Node3D
var gun_pitch: Node3D
var barrel: Node3D
var muzzle: Marker3D
var vents: Array[MeshInstance3D] = []
var walker
var dash
var crossbows
var model
var hull_shape: CylinderShape3D
var drive_velocity := Vector3.ZERO
var speed := 0.0
var steering := 0.0
var cruising := false
var turret_yaw := 0.0
var cooldown := 0.0
var reload_phase := 0
var recoil := 0.0
var recoil_velocity := 0.0
var rock := Vector2.ZERO
var rock_velocity := Vector2.ZERO
var kick_velocity := Vector3.ZERO
var aim_world := Vector3(0, 0, -12)
var shot_count := 0
var buffered_shot := 0.0

func _ready() -> void:
	name = "TowerTank"
	collision_layer = 2
	collision_mask = 65
	hull_shape = CylinderShape3D.new()
	hull_shape.radius = HULL_RADIUS
	hull_shape.height = HULL_HEIGHT
	var collider := CollisionShape3D.new()
	collider.shape = hull_shape
	collider.position.y = HULL_HEIGHT * 0.5
	add_child(collider)
	_build()
	dash = Dash.new()
	dash.actor = self
	dash.arena = arena
	add_child(dash)
	crossbows = Crossbows.new()
	crossbows.actor = self
	crossbows.arena = arena
	add_child(crossbows)

func _build() -> void:
	model = Model.new()
	model.build(self)
	walker = Walker.new()
	add_child(walker)
	walker.build(self, body_visual)

func input_direction() -> Vector3:
	var input := Input.get_vector("tank_left", "tank_right", "tank_forward", "tank_reverse")
	if input.is_zero_approx() or arena.aim_camera == null: return Vector3.ZERO
	var right: Vector3 = arena.aim_camera.global_basis.x
	var back: Vector3 = arena.aim_camera.global_basis.z
	right.y = 0.0
	back.y = 0.0
	return (right.normalized() * input.x + back.normalized() * input.y).limit_length(1.0)

func dash_direction() -> Vector3:
	var direction := input_direction()
	return direction.normalized() if not direction.is_zero_approx() else -global_basis.z.normalized()

func stop_drive() -> void:
	drive_velocity = Vector3.ZERO
	speed = 0.0
	steering = 0.0
	cruising = false

func tick(dt: float) -> void:
	damage_pulse = maxf(0.0, damage_pulse - dt * 2.0)
	if dead:
		stop_drive()
		velocity = Vector3.ZERO
		buffered_shot = 0.0
		crossbows.tick(dt)
		arena.sound.engine(0.0)
		body_visual.rotation.z = 0.16
		return
	dash.tick(dt)
	buffered_shot = maxf(0.0, buffered_shot - dt)
	var direction := input_direction()
	var blocked: bool = arena.tuning_open or not arena.crew.crewed or dash.active or dash.is_aiming()
	if blocked: direction = Vector3.ZERO
	var previous_drive := drive_velocity
	cruising = not blocked and not direction.is_zero_approx() and Input.is_action_pressed("tank_cruise")
	var target_speed := forward_speed
	if cruising:
		# Build extra speed from actual motion: no charge while idle or against a wall.
		# Only the speed ramp is slow; steering keeps the normal responsive rates.
		target_speed = minf(forward_speed * cruise_multiplier, maxf(forward_speed, drive_velocity.length()) + cruise_acceleration * drive_response * dt)
	var desired := direction * target_speed
	var rate := braking if direction.is_zero_approx() else acceleration
	if not cruising and drive_velocity.length() > forward_speed:
		rate = braking
	if not direction.is_zero_approx() and drive_velocity.dot(direction) < drive_velocity.length() * 0.5:
		rate = direction_braking
	if blocked:
		stop_drive()
	else:
		drive_velocity = drive_velocity.move_toward(desired, rate * drive_response * dt)
		# Translation follows input immediately; turning is only the body's pose.
		steering = 0.0
		if not direction.is_zero_approx():
			var desired_yaw := atan2(-direction.x, -direction.z)
			var delta_yaw := clampf(angle_difference(rotation.y, desired_yaw), -turn_speed * dt, turn_speed * dt)
			rotation.y += delta_yaw
			steering = delta_yaw / dt
	speed = drive_velocity.length()
	velocity = drive_velocity + kick_velocity
	velocity.y = -2.0
	var previous_position := global_position
	if arena.crew.crewed:
		if dash.active:
			dash.move(dt)
		elif not dash.is_aiming():
			move_and_slide()
	else:
		velocity = Vector3.ZERO
	var actual_velocity := (global_position - previous_position) / maxf(dt, 0.0001)
	actual_velocity.y = 0.0
	if actual_velocity.length_squared() > 0.01:
		arena.props.crush_segment(previous_position, global_position, 1.25, 1.9 if dash.active else 1.0)
	if arena.battle and not dash.active and arena.crew.crewed:
		arena.battle.bump(previous_position, global_position, maxf(actual_velocity.length(), drive_velocity.length()))
	if not dash.active and not dash.is_aiming():
		for i in get_slide_collision_count():
			var normal := get_slide_collision(i).get_normal()
			if absf(normal.y) < 0.4 and drive_velocity.dot(normal) < 0.0:
				drive_velocity = drive_velocity.slide(normal)
		speed = drive_velocity.length()
	kick_velocity = kick_velocity.move_toward(Vector3.ZERO, 6.5 * dt)
	recoil_velocity += (-recoil * 110.0 - recoil_velocity * 17.0) * dt
	recoil += recoil_velocity * dt
	barrel.position.z = recoil
	rock_velocity += (-rock * 85.0 - rock_velocity * 10.0) * dt
	var local_accel := global_basis.inverse() * (drive_velocity - previous_drive)
	rock_velocity.x -= local_accel.z * 0.035
	rock_velocity.y += local_accel.x * 0.025
	rock += rock_velocity * dt
	walker.tick(dt, actual_velocity, clampf(steering, -2.5, 2.5), rock)
	model.tick(dt)
	if arena.crew.crewed:
		_update_gun_aim(dt)
	arena.sound.engine(clampf(absf(speed) / forward_speed + absf(steering) * 0.15, 0.0, 1.0))
	_update_reload(dt)
	crossbows.tick(dt)
	if (Input.is_action_pressed("tank_fire") or buffered_shot > 0.0) and cooldown <= 0.0 and not arena.tuning_open and arena.crew.crewed and arena.crew.input_armed and not arena.pointer_over_ui() and not dash.blocks_gun():
		fire()

func _update_gun_aim(dt: float) -> void:
	# Keep the upper-floor turn lag, but stabilize its roll/pitch after the
	# walker's suspension update. Footfalls and recoil still move the tower.
	var to_aim := aim_world - turret.global_position
	var desired_yaw := atan2(-to_aim.x, -to_aim.z)
	var diff := angle_difference(turret_yaw, desired_yaw)
	turret_yaw += clampf(diff * (1.0 - exp(-dt / maxf(aim_lag, 0.02))), -turret_speed * dt, turret_speed * dt)
	turret.global_rotation = Vector3(0, turret_yaw, 0)
	to_aim = aim_world - gun_pitch.global_position
	var pitch := atan2(to_aim.y, Vector2(to_aim.x, to_aim.z).length())
	gun_pitch.rotation.x = lerpf(gun_pitch.rotation.x, clampf(pitch, -0.6, 0.15), 1.0 - exp(-dt * 18.0))

func fire() -> void:
	if dead or cooldown > 0.0 or not arena.crew.crewed or dash.blocks_gun():
		return
	buffered_shot = 0.0
	cooldown = reload_time
	reload_phase = 0
	shot_count += 1
	var direction := -muzzle.global_basis.z.normalized()
	arena.shoot(muzzle.global_position, direction)
	recoil_velocity = 16.0 * recoil_force
	recoil = 0.21 * recoil_force
	var local_dir := global_basis.inverse() * direction
	rock_velocity += Vector2(-local_dir.z, local_dir.x) * 0.75 * recoil_force
	kick_velocity -= Vector3(direction.x, 0, direction.z) * 1.8 * recoil_force
	walker.brace(recoil_force)

func take_damage(amount: float) -> void:
	if dead or amount <= 0.0: return
	hp = maxf(0.0, hp - amount)
	damage_pulse = 1.0
	arena.add_trauma(0.12)
	if hp > 0.0: return
	dead = true
	if arena.battle: arena.battle.nav_dirty = true
	dash.cancel()
	crossbows.cancel_trigger()
	buffered_shot = 0.0
	stop_drive()
	kick_velocity = Vector3.ZERO
	arena.fx.impact(global_position + Vector3.UP * 2.5, true)
	arena.sound.play("impact", 0.0, 0.6)
	# Keep a physical wreck; the surviving crew can continue fighting on foot.
	if arena.crew.crewed:
		arena.crew.disembark()
	arena.crew.tell("Башня разбита! Экипаж продолжает бой · R — начать заново" if not arena.crew.crewed else "Башня разбита · E — покинуть башню · R — заново")

func _update_reload(dt: float) -> void:
	if cooldown <= 0.0:
		return
	cooldown = maxf(0.0, cooldown - dt)
	var progress := 1.0 - cooldown / reload_time
	if progress >= 0.16 and reload_phase == 0:
		reload_phase = 1
		arena.fx.eject(turret.global_position + turret.global_basis.x * 1.1 + Vector3.UP * 0.45, turret.global_basis.x)
		arena.sound.play("eject", -3.0)
	if progress >= 0.43 and reload_phase == 1:
		reload_phase = 2
		arena.sound.play("chamber", -2.0)
		recoil_velocity += 2.7
	if progress >= 0.86 and reload_phase == 2:
		reload_phase = 3
		arena.sound.play("lock", 0.0)
		recoil_velocity -= 2.6
		rock_velocity.x += 0.1
		arena.add_trauma(0.15)
	if cooldown <= 0.0:
		arena.sound.play("ready", -4.0)
		arena.ready_pulse = 1.0
	for vent in vents:
		vent.scale.y = 0.4 + progress * 0.6

func reset_state() -> void:
	hp = MAX_HP
	dead = false
	damage_pulse = 0.0
	if body_visual: body_visual.rotation = Vector3.ZERO
	if dash: dash.reset()
	if crossbows: crossbows.reset()
	position = Vector3(0, 0.03, 5)
	rotation = Vector3.ZERO
	turret_yaw = 0.0
	stop_drive()
	velocity = Vector3.ZERO
	cooldown = 0.0
	buffered_shot = 0.0
	kick_velocity = Vector3.ZERO
	recoil = 0.0
	recoil_velocity = 0.0
	rock = Vector2.ZERO
	rock_velocity = Vector2.ZERO
	if walker:
		walker.reset_pose()
