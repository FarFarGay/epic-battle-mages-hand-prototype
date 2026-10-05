extends Node3D
## Two alternating repeaters, one magazine. Projectiles live in world space.
const Geo = preload("res://scripts/geo.gd")
const CAPACITY := 200
const FIRE_RATE := 20.0
const RELOAD_TIME := 4.5
const BOLT_SPEED := 72.0
const BOLT_RANGE := 48.0
const DAMAGE := 8.0
const AIM_STRIP_HALF_WIDTH := 0.85
const AIM_SCAN_INTERVAL := 0.06
var actor
var arena
var ammo := CAPACITY
var reload_left := 0.0
var reload_phase := 0
var shot_delay := 0.0
var trigger_held := false
var pending_tap := false
var shot_count := 0
var side_counts := [0, 0]
var hit_count := 0
var next_side := 0
var firing_pulse := 0.0
var ready_pulse := 0.0
var fire_heading := Vector3.FORWARD
var aim_scan_left := 0.0
var line_target: Node3D
var line_aim := Vector3.ZERO
var mounts: Array[Dictionary] = []
var bolts: Array[Dictionary] = []
var rng := RandomNumberGenerator.new()
var bolt_mat := Geo.material(Color("ffe5a0"), 0.25, 1.8)

func _ready() -> void:
	name = "SideCrossbows"
	rng.seed = 8302
	_build()

func _build() -> void:
	var iron := Geo.material(Color("34464a"), 0.7)
	var steel := Geo.material(Color("9bafa7"), 0.7)
	var brass := Geo.material(Color("c29251"), 0.65)
	var wood := Geo.material(Color("715039"))
	for side in [-1, 1]:
		Geo.box(actor.turret, Vector3(0.55, 0.22, 0.52), Vector3(side * 1.09, 0.19, -0.10), iron)
		var pivot := Node3D.new()
		pivot.name = "PortCrossbow" if side < 0 else "StarboardCrossbow"
		actor.turret.add_child(pivot)
		pivot.position = Vector3(side * 1.43, 0.23, -0.22)
		var rail := Node3D.new()
		pivot.add_child(rail)
		Geo.box(rail, Vector3(0.31, 0.26, 1.48), Vector3(0, 0, -0.36), wood)
		Geo.box(rail, Vector3(0.12, 0.08, 1.64), Vector3(0, 0.16, -0.39), steel)
		Geo.box(rail, Vector3(0.43, 0.38, 0.46), Vector3(0, -0.02, 0.24), iron)
		var magazine := Node3D.new()
		pivot.add_child(magazine)
		magazine.position = Vector3(side * 0.19, -0.23, 0.17)
		var drum := Geo.cylinder(magazine, 0.32, 0.40, Vector3.ZERO, brass, 12)
		drum.rotation.z = PI / 2.0
		for offset in [-0.21, 0.21]:
			var rim := Geo.cylinder(magazine, 0.34, 0.055, Vector3(offset, 0, 0), iron, 12)
			rim.rotation.z = PI / 2.0
		var arms: Array[Node3D] = []
		var strings: Array[MeshInstance3D] = []
		for wing in [-1, 1]:
			var arm := Node3D.new()
			rail.add_child(arm)
			arm.position.z = -0.90
			Geo.line(arm, Vector3.ZERO, Vector3(wing * 0.52, 0.04, 0.16), 0.105, steel)
			Geo.line(arm, Vector3(wing * 0.52, 0.04, 0.16), Vector3(wing * 0.64, 0.04, 0.40), 0.07, brass)
			arms.append(arm)
			strings.append(Geo.line(rail, Vector3(wing * 0.64, 0.04, -0.50), Vector3(0, 0.04, 0.06), 0.022, steel))
		var muzzle := Marker3D.new()
		rail.add_child(muzzle)
		muzzle.position = Vector3(0, 0.13, -1.25)
		mounts.append({"pivot": pivot, "rail": rail, "magazine": magazine, "muzzle": muzzle, "arms": arms, "strings": strings, "recoil": 0.0, "feed": 0.0})

func trigger(pressed: bool) -> void:
	if not pressed:
		trigger_held = false
		return
	if not _can_operate():
		cancel_trigger()
		return
	trigger_held = true
	pending_tap = true

func cancel_trigger() -> void:
	trigger_held = false
	pending_tap = false

func _can_operate() -> bool:
	return arena.weapon_mode_active() and not actor.dead and arena.crew.crewed and arena.crew.input_armed and not arena.tuning_open and not arena.pointer_over_ui() and not actor.dash.blocks_gun()

func tick(dt: float) -> void:
	_tick_bolts(dt)
	_tick_reload(dt)
	firing_pulse = maxf(0.0, firing_pulse - dt * 9.0)
	ready_pulse = maxf(0.0, ready_pulse - dt * 1.5)
	_update_mounts(dt)
	if not _can_operate(): cancel_trigger()
	if not trigger_held and not pending_tap:
		shot_delay = maxf(0.0, shot_delay - dt)
		return
	if reload_left > 0.0:
		pending_tap = false
		shot_delay = 0.0
		return
	shot_delay -= dt
	# Preserve cadence at uneven frame times, without banking shots while idle.
	while shot_delay <= 0.0 and ammo > 0:
		_fire()
		pending_tap = false
		shot_delay += 1.0 / FIRE_RATE
		if not trigger_held or reload_left > 0.0: break

func _update_mounts(dt: float) -> void:
	if arena.crew.crewed and arena.weapon_mode_active(): _update_line_aim(dt)
	for mount in mounts:
		var pivot: Node3D = mount.pivot
		if arena.crew.crewed and arena.weapon_mode_active():
			var local: Vector3 = actor.turret.global_basis.inverse() * (line_aim - pivot.global_position)
			var yaw := clampf(atan2(-local.x, -local.z), -0.25, 0.25)
			var pitch := clampf(atan2(local.y, Vector2(local.x, local.z).length()), -0.9, 0.18)
			pivot.rotation.y = lerp_angle(pivot.rotation.y, yaw, 1.0 - exp(-dt * 18.0))
			pivot.rotation.x = lerpf(pivot.rotation.x, pitch, 1.0 - exp(-dt * 18.0))
		mount.recoil = move_toward(mount.recoil, 0.0, dt * 2.4)
		mount.rail.position.z = mount.recoil
		for i in 2:
			mount.arms[i].rotation.y = mount.recoil * (1.8 if i == 0 else -1.8)
			mount.strings[i].scale.z = 1.0 - mount.recoil * 1.8
		var progress := 1.0 - reload_left / RELOAD_TIME
		var lowered := sin(PI * clampf(progress / 0.72, 0.0, 1.0)) if reload_left > 0.0 else 0.0
		mount.magazine.position.y = -0.23 - lowered * 0.40
		mount.magazine.rotation.x = lerp_angle(mount.magazine.rotation.x, mount.feed + (progress * TAU if reload_left > 0.0 else 0.0), 1.0 - exp(-dt * 20.0))

func _aimable(target: Node3D) -> bool:
	if not is_instance_valid(target) or target.is_queued_for_deletion(): return false
	if target.has_meta("hand_owner"): return false
	if target.has_meta("enemy"): return not target.dead and not target.hand_held
	if target.has_meta("breakable"): return not target.get_meta("broken", false)
	return float(target.get_meta("hp", 0.0)) > 0.0

func _line_depth(target: Node3D) -> float:
	if not _aimable(target): return INF
	var offset: Vector3 = target.global_position - actor.global_position
	offset.y = 0.0
	var depth := offset.dot(fire_heading)
	if depth < 3.0 or depth > BOLT_RANGE - 1.0: return INF
	var radius: float = target.body_radius if target.has_meta("enemy") else 0.4
	if (offset - fire_heading * depth).length_squared() > pow(AIM_STRIP_HALF_WIDTH + radius, 2): return INF
	return depth

func _update_line_aim(dt: float) -> void:
	# Mouse distance never sets bolt range. A short dead zone avoids flipping
	# the repeaters when the pointer crosses the tower's feet.
	var heading: Vector3 = arena.ground_aim_position - actor.global_position
	heading.y = 0.0
	if heading.length_squared() > 1.0:
		heading = heading.normalized()
		if heading.dot(fire_heading) < 0.995: aim_scan_left = 0.0
		fire_heading = heading
	aim_scan_left -= dt
	if is_instance_valid(line_target) and _line_depth(line_target) == INF:
		line_target = null
		aim_scan_left = 0.0
	if aim_scan_left <= 0.0:
		aim_scan_left = AIM_SCAN_INTERVAL
		line_target = null
		var nearest := INF
		# One shared, throttled scan for both mounts, including large hordes.
		for candidates in [arena.battle.enemies, arena.targets, arena.props.props]:
			for candidate in candidates:
				var depth := _line_depth(candidate)
				if depth < nearest:
					nearest = depth
					line_target = candidate
	line_aim = actor.global_position + fire_heading * BOLT_RANGE
	line_aim.y = arena.ground_height(line_aim) + 1.0
	if is_instance_valid(line_target):
		# Roof-mounted guns need elevation assistance to hit ordinary skeletons.
		# Only targets inside the fire strip qualify; bolts remain straight,
		# physical projectiles stopped by the first obstacle.
		line_aim = line_target.global_position
		if line_target.has_meta("enemy"):
			line_aim.y += line_target.body_height * 0.55
		elif line_target.has_meta("breakable"):
			line_aim.y += 0.45
		else:
			line_aim.y += 0.6 if line_target.get_meta("spec", {}).get("barrel", false) else 1.2

func _fire() -> void:
	var side := next_side
	next_side = 1 - next_side
	var mount: Dictionary = mounts[side]
	var muzzle: Marker3D = mount.muzzle
	var direction := -muzzle.global_basis.z.normalized()
	direction = direction.rotated(muzzle.global_basis.y.normalized(), rng.randf_range(-0.009, 0.009))
	direction = direction.rotated(muzzle.global_basis.x.normalized(), rng.randf_range(-0.006, 0.006)).normalized()
	var origin := muzzle.global_position
	ammo -= 1
	shot_count += 1
	side_counts[side] += 1
	mount.recoil = 0.14
	mount.feed += PI / 6.0
	firing_pulse = 1.0
	# Check the barrel path too, so a muzzle poking through a wall cannot fire through it.
	var root: Vector3 = mount.pivot.global_position
	var query := PhysicsRayQueryParameters3D.create(root, origin, 97)
	query.hit_from_inside = true
	var obstruction := get_world_3d().direct_space_state.intersect_ray(query)
	if obstruction:
		_hit(obstruction, direction)
	else:
		var node := Geo.box(arena, Vector3(0.055, 0.055, 0.64), origin, bolt_mat)
		node.name = "RepeaterBolt"
		node.look_at(origin + direction)
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bolts.append({"node": node, "direction": direction, "remaining": BOLT_RANGE})
		arena.fx.repeater_muzzle(origin, direction)
	arena.sound.play("repeater", -8.0, 1.04 if side == 0 else 0.94)
	actor.rock_velocity += Vector2(0.022, -0.025 if side == 0 else 0.025)
	arena.trauma = maxf(arena.trauma, 0.13)
	if ammo == 0:
		reload_left = RELOAD_TIME
		reload_phase = 0
		arena.sound.play("repeater_reload", -4.0)

func _tick_reload(dt: float) -> void:
	if reload_left <= 0.0: return
	reload_left = maxf(0.0, reload_left - dt)
	var progress := 1.0 - reload_left / RELOAD_TIME
	if progress >= 0.48 and reload_phase == 0:
		reload_phase = 1
		arena.sound.play("chamber", -7.0, 0.7)
	if progress >= 0.90 and reload_phase == 1:
		reload_phase = 2
		arena.sound.play("lock", -3.0, 0.75)
		for mount in mounts: mount.recoil = 0.10
	if reload_left <= 0.0:
		ammo = CAPACITY
		ready_pulse = 1.0
		arena.sound.play("ready", -3.0, 1.35)

func _tick_bolts(dt: float) -> void:
	for i in range(bolts.size() - 1, -1, -1):
		var bolt: Dictionary = bolts[i]
		var start: Vector3 = bolt.node.global_position
		var travel := minf(BOLT_SPEED * dt, bolt.remaining)
		var finish: Vector3 = start + bolt.direction * travel
		var query := PhysicsRayQueryParameters3D.create(start, finish, 97)
		query.hit_from_inside = true
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		var end: Vector3 = hit.position if hit else finish
		arena.fx.repeater_trail(start, end)
		bolt.node.global_position = end
		bolt.remaining -= travel
		if hit: _hit(hit, bolt.direction)
		if hit or bolt.remaining <= 0.0:
			bolt.node.queue_free()
			bolts.remove_at(i)

func _hit(hit: Dictionary, direction: Vector3) -> void:
	if hit.collider.has_meta("target") or hit.collider.has_meta("enemy"):
		hit_count += 1
		arena._damage_target(hit.collider, DAMAGE, direction, 1.3)
	elif hit.collider.has_meta("breakable"):
		arena.props.shatter(hit.collider, direction)
	arena.fx.repeater_hit(hit.position, hit.normal)
	# Short clicks overlap into a mechanical rattle, without cannon-sized explosions.
	arena.sound.play("bolt_hit", -19.0)

func reset() -> void:
	cancel_trigger()
	for bolt in bolts: bolt.node.queue_free()
	bolts.clear()
	ammo = CAPACITY
	reload_left = 0.0
	reload_phase = 0
	shot_delay = 0.0
	shot_count = 0
	side_counts = [0, 0]
	hit_count = 0
	next_side = 0
	firing_pulse = 0.0
	ready_pulse = 0.0
	fire_heading = Vector3.FORWARD
	aim_scan_left = 0.0
	line_target = null
	line_aim = Vector3.ZERO
	for mount in mounts:
		mount.recoil = 0.0
		mount.feed = 0.0
		mount.pivot.rotation = Vector3.ZERO
		mount.rail.position = Vector3.ZERO
		mount.magazine.position.y = -0.23
		mount.magazine.rotation = Vector3.ZERO
