extends Node3D
## Two simple legs joining the skirt to planted, alternating boots.
## Planted support feet follow direct movement while the round body turns.
const Geo = preload("res://scripts/geo.gd")

const RIDE_HEIGHT := 1.18
const STANCE := 0.78
const FLOOR_Y := 0.025

var actor
var suspension: Node3D
var legs: Array[Dictionary] = []
var next_leg := 0
var compression := 0.0
var compression_velocity := 0.0
var weight_shift := 0.0
var motion_amount := 0.0
var footfalls := 0
var was_dashing := false

func build(tower, body: Node3D) -> void:
	actor = tower
	suspension = body
	name = "BootedLegs"
	suspension.position.y = RIDE_HEIGHT
	var black := Geo.material(Color("20202b"))
	for side in [-1.0, 1.0]:
		var leg_root := Node3D.new()
		leg_root.name = "LeftLeg" if side < 0 else "RightLeg"
		add_child(leg_root)
		var stem := Geo.cylinder(leg_root, 0.12, 1.0, Vector3.ZERO, black, 12, 0.145)
		stem.name = "SimpleLeg"
		var foot := Node3D.new()
		leg_root.add_child(foot)
		foot.name = "PlantedBoot"
		preload("res://scripts/tower_model.gd").boot(foot, side)
		legs.append({
			"side": side, "foot": foot, "stem": stem,
			"planted": Vector3.ZERO, "from": Vector3.ZERO, "to": Vector3.ZERO,
			"yaw": 0.0, "from_yaw": 0.0, "to_yaw": 0.0,
			"swing": false, "progress": 1.0, "duration": 0.3, "lift": 0.4,
		})
	reset_pose()

func _neutral(side: float, yaw: float) -> Vector3:
	var pos: Vector3 = actor.global_position + Basis(Vector3.UP, yaw) * Vector3(side * STANCE, 0, -0.06)
	pos.y = _floor_y(pos)
	return pos

func _floor_y(point: Vector3) -> float:
	return maxf(actor.arena.ground_height(point),actor.global_position.y-0.85)+FLOOR_Y if actor.arena.level else FLOOR_Y

func reset_pose() -> void:
	compression = 0.0
	compression_velocity = 0.0
	weight_shift = 0.0
	motion_amount = 0.0
	footfalls = 0
	was_dashing = false
	next_leg = 0
	suspension.position = Vector3(0, RIDE_HEIGHT, 0)
	suspension.rotation = Vector3.ZERO
	for leg in legs:
		var rest := _neutral(leg.side, actor.global_rotation.y)
		leg.planted = rest
		leg.from = rest
		leg.to = rest
		leg.yaw = actor.global_rotation.y
		leg.swing = false
		leg.progress = 1.0
		leg.foot.global_position = rest
		leg.foot.global_rotation = Vector3(0, leg.yaw, 0)
		_pose_leg(leg)

func brace(force: float) -> void:
	# The body absorbs recoil while both boot soles stay planted.
	compression_velocity -= 1.4 * force

func tick(dt: float, travel_velocity: Vector3, angular_speed: float, recoil_rock: Vector2) -> void:
	if actor.dash != null and actor.dash.active:
		_tick_dash(recoil_rock)
		return
	if was_dashing:
		was_dashing = false
		for leg in legs:
			leg.planted = _neutral(leg.side, actor.global_rotation.y)
			leg.yaw = actor.global_rotation.y
			leg.swing = false
			leg.progress = 1.0
			_land(leg)
	var planar_speed := Vector2(travel_velocity.x, travel_velocity.z).length()
	var activity := maxf(planar_speed / actor.forward_speed, absf(angular_speed) * 0.45)
	var just_started: bool = motion_amount < 0.02 and (absf(actor.speed) > 0.1 or absf(angular_speed) > 0.05)
	motion_amount = move_toward(motion_amount, clampf(activity, 0, 1), dt * 10.0)
	var moving := planar_speed > 0.08 or absf(angular_speed) > 0.06
	var swinging := false
	var support_side := 0.0
	for leg in legs:
		if leg.swing:
			# Correct the landing early in the swing when accelerating, braking
			# or changing direction; the support foot remains locked in place.
			if leg.progress < 0.65:
				var landing_yaw: float = actor.global_rotation.y + angular_speed * leg.duration * 0.40
				var landing: Vector3 = _neutral(leg.side, landing_yaw) + travel_velocity.limit_length(maxf(8.0, actor.forward_speed * actor.cruise_multiplier)) * leg.duration * 0.78
				landing.y = _floor_y(landing)
				var follow := 1.0 - exp(-dt * 12.0)
				leg.to = leg.to.lerp(landing, follow)
				leg.to_yaw = lerp_angle(leg.to_yaw, landing_yaw, follow)
			leg.progress = minf(1.0, leg.progress + dt / leg.duration)
			var p: float = leg.progress
			var ease := smoothstep(0.0, 1.0, p)
			var foot_pos: Vector3 = leg.from.lerp(leg.to, ease)
			foot_pos.y += sin(PI * p) * leg.lift
			leg.foot.global_position = foot_pos
			leg.foot.global_rotation = Vector3(0, lerp_angle(leg.from_yaw, leg.to_yaw, ease), 0)
			support_side = -leg.side * sin(PI * p)
			if p >= 1.0:
				leg.swing = false
				leg.planted = leg.to
				leg.yaw = leg.to_yaw
				_land(leg)
			else:
				swinging = true
		else:
			# World-space lock: no conveyor-belt sliding during the support phase.
			leg.foot.global_position = leg.planted
			leg.foot.global_rotation = Vector3(0, leg.yaw, 0)
	if not swinging:
		var selected := next_leg if just_started else -1
		var best_error := 0.0
		for offset in 2:
			var idx := (next_leg + offset) % 2
			var leg: Dictionary = legs[idx]
			var neutral := _neutral(leg.side, actor.global_rotation.y)
			var error: float = leg.planted.distance_to(neutral)
			var yaw_error := absf(angle_difference(leg.yaw, actor.global_rotation.y))
			var threshold := lerpf(0.18, 0.38, motion_amount) if moving else 0.10
			if error > threshold or yaw_error > (0.24 if moving else 0.08):
				var score := error + yaw_error * 0.6
				if not just_started and (selected < 0 or score > best_error + 0.06):
					selected = idx
					best_error = score
		if selected >= 0:
			_start_step(selected, travel_velocity, angular_speed, moving)
	compression_velocity += (-compression * 110.0 - compression_velocity * 14.0) * dt
	compression = clampf(compression + compression_velocity * dt, -0.20, 0.12)
	weight_shift = lerpf(weight_shift, support_side * 0.065, 1.0 - exp(-dt * 12.0))
	suspension.position = Vector3(weight_shift, RIDE_HEIGHT + compression, 0)
	var local_motion: Vector3 = actor.global_basis.inverse() * travel_velocity
	suspension.rotation.x = recoil_rock.x - local_motion.z * 0.004
	suspension.rotation.z = recoil_rock.y - weight_shift * 0.5
	_dash_lean()
	for leg in legs:
		_pose_leg(leg)

func _start_step(index: int, travel_velocity: Vector3, angular_speed: float, moving: bool) -> void:
	var leg: Dictionary = legs[index]
	leg.duration = lerpf(0.24, 0.155, motion_amount) if moving else 0.20
	leg.lift = lerpf(0.26, 0.43, motion_amount) if moving else 0.16
	if moving:
		# Faster, slightly higher steps keep the planted leg under the cruising body.
		var pace := maxf(1.0, travel_velocity.length() / actor.forward_speed)
		leg.duration = maxf(0.10, leg.duration / sqrt(pace))
		leg.lift += clampf(pace - 1.0, 0.0, 1.0) * 0.08
	leg.from = leg.foot.global_position
	leg.from_yaw = leg.foot.global_rotation.y
	leg.to_yaw = actor.global_rotation.y + angular_speed * leg.duration * 0.40
	leg.to = _neutral(leg.side, leg.to_yaw) + travel_velocity.limit_length(maxf(8.0, actor.forward_speed * actor.cruise_multiplier)) * leg.duration * 0.78
	leg.to.y = _floor_y(leg.to)
	leg.progress = 0.0
	leg.swing = true
	next_leg = 1 - index

func _land(leg: Dictionary) -> void:
	footfalls += 1
	var power := 0.45 + motion_amount * 0.55
	compression_velocity -= 0.95 * power
	actor.rock_velocity.y += leg.side * power * 0.12
	actor.arena.sound.play("step", -8.0 + power * 2.0, 0.9 + power * 0.10)
	actor.arena.add_trauma(0.038 * power)
	if actor.arena.props != null and actor.arena.crew.crewed:
		actor.arena.props.stomp(leg.planted, power)
	for i in 5:
		var angle := TAU * i / 5.0
		var outward := Vector3(cos(angle), 0, sin(angle))
		actor.arena.fx.dust(leg.planted + outward * 0.35 + Vector3.UP * 0.07, -outward * 3.0 * power)

func _tick_dash(recoil_rock: Vector2) -> void:
	was_dashing = true
	motion_amount = 1.0
	var progress: float = 1.0 - actor.dash.remaining / actor.dash.total_distance
	var lift := sin(PI * progress) * 0.28
	suspension.position = Vector3(0, RIDE_HEIGHT - 0.14 + lift * 0.5, 0)
	suspension.rotation = Vector3(recoil_rock.x, 0, recoil_rock.y)
	_dash_lean()
	for leg in legs:
		var pos := _neutral(leg.side, actor.global_rotation.y)
		pos += actor.dash.direction * -0.20
		pos.y += 0.12 + lift
		leg.foot.global_position = pos
		leg.foot.global_rotation = Vector3(0, actor.global_rotation.y, 0)
		_pose_leg(leg)

func _dash_lean() -> void:
	if actor.dash == null: return
	var local_dir: Vector3 = actor.global_basis.inverse() * actor.dash.direction
	suspension.rotation.x += local_dir.z * actor.dash.visual_amount * 0.20
	suspension.rotation.z -= local_dir.x * actor.dash.visual_amount * 0.20

func _pose_leg(leg: Dictionary) -> void:
	# A single smooth leg: its upper end stays inside the skirt, with no elbow
	# or exposed joint between the moving body and the planted boot.
	var hip_pos := suspension.to_global(Vector3(leg.side * 0.62, 0.75, 0.04))
	var boot_top: Vector3 = leg.foot.to_global(Vector3(0, 0.88, 0.11))
	var stem: Node3D = leg.stem
	stem.global_position = (hip_pos + boot_top) * 0.5
	stem.global_basis = Basis(Quaternion(Vector3.UP, (hip_pos - boot_top).normalized()))
	stem.scale.y = hip_pos.distance_to(boot_top)
