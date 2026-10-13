extends Node
## Real physics checks for light momentum, direct steering and planted boots.
var arena
var tank
var checks := {}
var metrics := {}
const ACTIONS := ["tank_forward", "tank_reverse", "tank_left", "tank_right"]

func _ready() -> void:
	arena = get_parent()
	tank = arena.tank
	_run.call_deferred()

func _frames(count: int) -> void:
	for i in count: await get_tree().physics_frame

func _reset() -> void:
	_shift(false)
	for action in ACTIONS + ["tank_fire", "tank_cruise"]: Input.action_release(action)
	arena.tuning_open = false
	arena.reset_range()
	arena.test_aim = true
	arena.aim_position = Vector3(0, 1.5, -8)
	await _frames(3)

func _screen_motion(delta: Vector3) -> Vector2:
	var right: Vector3 = arena.aim_camera.global_basis.x
	var back: Vector3 = arena.aim_camera.global_basis.z
	right.y = 0
	back.y = 0
	return Vector2(delta.dot(right.normalized()), delta.dot(back.normalized()))

func _shift(pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_SHIFT
	event.keycode = KEY_SHIFT
	event.shift_pressed = pressed
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _cruise_lane() -> void:
	await _reset()
	# A clear lane inside the walls, away from the static shooting targets.
	tank.position = Vector3(-20, 0.03, 18)
	tank.rotation.y = -PI / 4.0
	tank.walker.reset_pose()
	arena.aim_position = Vector3(20, 0, -22)
	await _frames(3)

func _check_cruise() -> void:
	await _cruise_lane()
	_shift(true)
	checks.shift_binding_works = Input.is_action_pressed("tank_cruise")
	await _frames(20)
	checks.cruise_does_not_move_or_charge_at_rest = not tank.cruising and tank.speed < 0.01
	Input.action_press("tank_right")
	await _frames(6)
	checks.cruise_starts_with_normal_acceleration = tank.speed > 0.5 and tank.speed < tank.forward_speed
	await _frames(24)
	checks.cruise_builds_speed_progressively = tank.speed > tank.forward_speed + 0.5 and tank.speed < tank.forward_speed * 1.5
	var stable := true
	var attached := true
	var supported := true
	var max_leg := 0.0
	var frames := 30
	while tank.speed < tank.forward_speed * tank.cruise_multiplier - 0.01 and frames < 115:
		var before: Array[Dictionary] = []
		for leg in tank.walker.legs: before.append({"pos": leg.foot.global_position, "swing": leg.swing})
		await _frames(1)
		frames += 1
		var airborne := 0
		for i in 2:
			var leg: Dictionary = tank.walker.legs[i]
			max_leg = maxf(max_leg, leg.stem.scale.y)
			attached = attached and leg.stem.to_global(Vector3(0, -0.5, 0)).distance_to(leg.foot.to_global(Vector3(0, 0.88, 0.11))) < 0.005
			if not before[i].swing and not leg.swing:
				stable = stable and before[i].pos.distance_to(leg.foot.global_position) < 0.002
			if leg.foot.global_position.y > 0.10: airborne += 1
		supported = supported and airborne <= 1
	metrics.cruise_full_speed_time_s = frames / 60.0
	metrics.cruise_speed_mps = tank.speed
	metrics.cruise_max_leg_length_m = max_leg
	checks.cruise_reaches_double_speed = absf(tank.speed - 20.4) < 0.02 and frames >= 40 and frames <= 55
	checks.cruise_boots_planted_and_attached = stable and attached and supported and max_leg < 3.4
	await arena._capture(arena.verification_path("cruise_01_running.png"))
	_shift(false)
	await _frames(3)
	checks.shift_release_eases_speed_down = not tank.cruising and tank.speed > tank.forward_speed and tank.speed < 20.4
	await _frames(15)
	checks.shift_release_restores_walking_speed = absf(tank.speed - tank.forward_speed) < 0.02

	await _cruise_lane()
	_shift(true)
	Input.action_press("tank_forward")
	Input.action_press("tank_right")
	await _frames(96)
	checks.cruise_diagonal_not_faster = absf(tank.speed - 20.4) < 0.02
	Input.action_release("tank_forward")
	Input.action_release("tank_right")
	var start: Vector3 = tank.position
	await _frames(27)
	metrics.cruise_stopping_distance_m = tank.position.distance_to(start)
	checks.releasing_wasd_stops_cruise = not tank.cruising and tank.speed < 0.02 and metrics.cruise_stopping_distance_m < 3.2

	await _cruise_lane()
	_shift(true)
	Input.action_press("tank_right")
	await _frames(96)
	var bolts: int = tank.crossbows.shot_count
	tank.crossbows.trigger(true)
	await _frames(3)
	tank.crossbows.trigger(false)
	checks.cruise_allows_crossbows = tank.crossbows.shot_count > bolts and tank.cruising
	var shots: int = tank.shot_count
	Input.action_press("tank_fire")
	await _frames(2)
	Input.action_release("tank_fire")
	checks.cruise_allows_cannon = tank.shot_count > shots and tank.cruising
	await _frames(5)
	tank.dash.space(true)
	tank.dash.space(false)
	await _frames(2)
	checks.cruise_dash_takes_priority = tank.dash.active and not tank.cruising
	await _frames(19)
	checks.cruise_reaccelerates_after_dash = not tank.dash.active and tank.speed < tank.forward_speed * 1.5

	await _cruise_lane()
	_shift(true)
	Input.action_press("tank_right")
	await _frames(36)
	arena.tuning_open = true
	await _frames(2)
	checks.tuning_stops_cruise = not tank.cruising and tank.speed < 0.02
	arena.tuning_open = false
	await _frames(18)
	arena._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _frames(2)
	checks.focus_loss_cancels_cruise = not tank.cruising and not Input.is_action_pressed("tank_cruise")
	_shift(true)
	var disembarked: bool = arena.crew.disembark()
	await _frames(3)
	checks.disembark_stops_cruise = disembarked and not tank.cruising and tank.speed < 0.02
	await _reset()
	tank.position = Vector3(25, 0.03, 0)
	tank.drive_velocity = Vector3(20.4, 0, 0)
	tank.walker.reset_pose()
	_shift(true)
	Input.action_press("tank_right")
	Input.action_press("tank_reverse")
	await _frames(24)
	checks.cruise_wall_stops_without_stored_speed = tank.position.x < 27.15 and tank.drive_velocity.length() < 0.05
	await _reset()
	checks.reset_clears_cruise = not tank.cruising and tank.speed < 0.02

func _crowd_lane(boosted: bool) -> Array:
	await _reset()
	arena.battle.waves_enabled = false
	for target in arena.targets:
		target.collision_layer = 0
		target.queue_free()
	arena.targets.clear()
	tank.position = Vector3(-18, 0.03, 15)
	tank.walker.reset_pose()
	var crowd := []
	for row in 22:
		for column in 3:
			var enemy = arena.battle.spawn_enemy(Vector3(-15 + row * 1.0, 0.04, 15 + (column - 1) * 0.9))
			enemy.move_speed = 0.0
			enemy.hp = 1000.0
			enemy.attack_damage = 0.0
			crowd.append(enemy)
	await _frames(3)
	Input.action_press("tank_right")
	Input.action_press("tank_reverse")
	_shift(boosted)
	tank.drive_velocity = Vector3.RIGHT * tank.forward_speed * (tank.cruise_multiplier if boosted else 1.0)
	return crowd

func _check_crowd_momentum() -> void:
	var crowd := await _crowd_lane(false)
	var walk_start: Vector3 = tank.position
	arena.trauma = 0.0
	await _frames(35)
	checks.walking_does_not_shove_or_damage = crowd.all(func(e): return e.bump_cooldown <= 0.0 and e.hp == 1000.0)
	checks.walking_passes_through_crowd = tank.position.distance_to(walk_start) > 2.5 and absf(tank.speed - tank.forward_speed * 0.5) < 0.05
	checks.walking_has_no_impact_shake = arena.trauma < 0.01

	crowd = await _crowd_lane(true)
	var touched := false
	var slowed := false
	var reached_walk := false
	var max_drop := 0.0
	var shoved := {}
	var peak_impulse := 0.0
	var peak_shake := 0.0
	var knocked_down := false
	var walk_distance := 0.0
	for frame in 100:
		var before: float = tank.speed
		var before_pos: Vector3 = tank.position
		await _frames(1)
		peak_shake = maxf(peak_shake, arena.trauma)
		for enemy in crowd:
			if enemy.bump_cooldown > 0.0: shoved[enemy.get_instance_id()] = true
			peak_impulse = maxf(peak_impulse, enemy.impulse.length())
			knocked_down = knocked_down or enemy.knockdown_left > 0.0
		if reached_walk: walk_distance += tank.position.distance_to(before_pos)
		if tank.crowd_contact_left > 0.0:
			touched = true
			if before > tank.forward_speed + 0.1:
				max_drop = maxf(max_drop, before - tank.speed)
			slowed = slowed or (tank.speed > tank.forward_speed + 1.0 and tank.speed < 19.0)
			if tank.speed <= tank.forward_speed + 0.05: reached_walk = true
	metrics.crowd_max_speed_drop_per_frame = max_drop
	metrics.crowd_skeletons_shoved = shoved.size()
	metrics.crowd_peak_impulse = peak_impulse
	metrics.crowd_peak_shake = peak_shake
	metrics.crowd_walk_distance = walk_distance
	checks.cruise_scatters_and_knocks_down = peak_impulse > 16.0 and peak_impulse <= 20.0 and knocked_down
	checks.crowd_impact_shake_is_bounded = peak_shake > 0.1 and peak_shake <= 0.25
	checks.crowd_keeps_moving_after_slowdown = walk_distance > 2.0 and absf(tank.speed - tank.forward_speed * 0.5) < 0.05
	metrics.crowd_slow_speed = tank.speed
	checks.cruise_shoves_multiple_skeletons = shoved.size() >= 3
	checks.crowd_slows_cruise_gradually = touched and slowed and max_drop > 0.3 and max_drop <= 0.5
	checks.crowd_exhausts_extra_speed_with_shift_held = reached_walk and tank.speed <= tank.forward_speed + 0.05
	checks.cruise_shove_does_not_damage = crowd.all(func(e): return e.hp == 1000.0)
	await _frames(30)
	checks.walking_in_crowd_stops_shoving_with_shift_held = crowd.all(func(e): return e.bump_cooldown <= 0.0)
	# Once the path clears, holding Shift should recover speed normally.
	arena.battle.reset()
	Input.action_release("tank_right")
	Input.action_release("tank_reverse")
	Input.action_press("tank_forward")
	await _frames(65)
	checks.cruise_recovers_after_path_clears = tank.speed > tank.forward_speed * 1.8
	# Stop first: running footfalls have their own small camera impulses.
	Input.action_release("tank_forward")
	_shift(false)
	await _frames(40)
	checks.crowd_impact_shake_fades = arena.trauma < 0.01
	await _reset()
	checks.reset_clears_crowd_resistance = tank.crowd_contact_left == 0.0 and tank.crowd_load == 0.0

func _check_damage_feedback() -> void:
	await _reset()
	arena.battle.waves_enabled = false
	arena.trauma = 0.0
	var hp_before: float = tank.hp
	for i in 40: tank.take_damage(1.0)
	checks.simultaneous_hits_do_not_shake = is_zero_approx(arena.trauma)
	checks.damage_feedback_preserves_all_damage = tank.hp == hp_before - 40.0 and tank.damage_pulse == 1.0
	checks.damage_lights_hull = tank.model.damage_amount == 1.0 and tank.model.damage_materials.all(func(e): return e.material.emission_energy_multiplier > 0.0 and e.material.albedo_color != e.color)
	await arena._capture(arena.verification_path("damage_01_hit.png"))
	var peak := 0.0
	for frame in 60:
		tank.take_damage(1.0)
		peak = maxf(peak, arena.trauma)
		await _frames(1)
	checks.sustained_hits_do_not_shake = is_zero_approx(peak)
	await _frames(40)
	checks.damage_visual_fades_after_hits = tank.damage_pulse == 0.0 and tank.model.damage_materials.all(func(e): return e.material.emission_energy_multiplier == 0.0 and e.material.albedo_color == e.color)
	await arena._capture(arena.verification_path("damage_02_faded.png"))
	arena.trauma = 0.6
	tank.take_damage(1.0)
	checks.damage_does_not_amplify_other_camera_impulses = is_equal_approx(arena.trauma, 0.6)
	await _reset()
	checks.reset_clears_damage_visual = tank.damage_pulse == 0.0 and tank.model.damage_amount == 0.0

func _run() -> void:
	await _reset()
	var requested := [Vector2(0, -1), Vector2(0, 1), Vector2(-1, 0), Vector2(1, 0)]
	for i in 4:
		await _reset()
		# A/D must work even when the body initially faces somewhere else.
		tank.rotation.y = 1.7
		tank.walker.reset_pose()
		var start: Vector3 = tank.position
		Input.action_press(ACTIONS[i])
		await _frames(6)
		var first := _screen_motion(tank.position - start)
		checks[ACTIONS[i] + "_responds_without_waiting_for_turn"] = first.dot(requested[i]) > 0.08
		await _frames(24)
		var delta := _screen_motion(tank.position - start)
		checks[ACTIONS[i] + "_screen_direction"] = delta.normalized().dot(requested[i]) > 0.999 and delta.length() > 2.6
		checks[ACTIONS[i] + "_full_speed"] = absf(tank.speed - 10.2) < 0.02
		Input.action_release(ACTIONS[i])

	await _reset()
	var start: Vector3 = tank.position
	Input.action_press("tank_forward")
	var frames := 0
	while tank.speed < tank.forward_speed * 0.9 and frames < 60:
		await _frames(1)
		frames += 1
	metrics.time_to_90_percent_speed_s = frames / 60.0
	checks.light_acceleration = frames >= 12 and frames <= 17
	checks.first_step_starts_with_input = tank.walker.legs[0].swing or tank.walker.legs[1].swing
	await _frames(12)
	Input.action_release("tank_forward")
	start = tank.position
	frames = 0
	while tank.speed > 0.03 and frames < 60:
		await _frames(1)
		frames += 1
	metrics.stop_time_s = frames / 60.0
	metrics.stopping_distance_m = start.distance_to(tank.position)
	checks.short_coast_on_release = frames >= 9 and frames <= 14 and start.distance_to(tank.position) > 0.45 and start.distance_to(tank.position) < 0.85

	await _reset()
	Input.action_press("tank_forward")
	await _frames(20)
	Input.action_release("tank_forward")
	Input.action_press("tank_reverse")
	frames = 0
	while _screen_motion(tank.drive_velocity).y <= 0.1 and frames < 60:
		await _frames(1)
		frames += 1
	metrics.reversal_time_s = frames / 60.0
	checks.quick_reversal = frames <= 7
	# Let the new direction finish its short acceleration ramp before comparing top speeds.
	await _frames(18)
	checks.down_same_speed_as_up = absf(tank.speed - tank.forward_speed) < 0.02

	await _reset()
	Input.action_press("tank_forward")
	Input.action_press("tank_right")
	start = tank.position
	await _frames(30)
	var delta := _screen_motion(tank.position - start)
	checks.diagonal_direction = delta.normalized().dot(Vector2(1, -1).normalized()) > 0.999
	checks.diagonal_not_faster = absf(tank.speed - tank.forward_speed) < 0.02
	Input.action_press("tank_reverse")
	Input.action_press("tank_left")
	await _frames(15)
	checks.opposite_keys_cancel = tank.speed < 0.02

	await _reset()
	var max_leg := 0.0
	var attached := true
	var stable := true
	var supported := true
	for action in ["tank_right", "tank_left", "tank_forward", "tank_reverse", "tank_right"]:
		for old in ACTIONS: Input.action_release(old)
		Input.action_press(action)
		for frame in 22:
			var before: Array[Dictionary] = []
			for leg in tank.walker.legs: before.append({"pos": leg.foot.global_position, "swing": leg.swing})
			await _frames(1)
			var airborne := 0
			for i in 2:
				var leg: Dictionary = tank.walker.legs[i]
				max_leg = maxf(max_leg, leg.stem.scale.y)
				attached = attached and leg.stem.global_position.is_finite() and leg.stem.to_global(Vector3(0, -0.5, 0)).distance_to(leg.foot.to_global(Vector3(0, 0.88, 0.11))) < 0.005
				if not before[i].swing and not leg.swing:
					stable = stable and before[i].pos.distance_to(leg.foot.global_position) < 0.002
				if leg.foot.global_position.y > 0.10: airborne += 1
			supported = supported and airborne <= 1
	for action in ACTIONS: Input.action_release(action)
	await _frames(80)
	checks.support_boot_stays_planted = stable
	checks.one_support_boot = supported
	checks.simple_legs_stay_attached = attached
	checks.boots_settle_after_changes = tank.walker.legs.all(func(leg): return not leg.swing)
	metrics.max_leg_length = max_leg

	await _reset()
	tank.rotation.y = -PI / 2.0
	tank.walker.reset_pose()
	arena.aim_position = Vector3(12, 1.5, 3)
	arena.zoom = 20.0
	await _frames(70)
	await arena._capture(arena.verification_path("concept_01_ready.png"))
	Input.action_press("tank_right")
	await _frames(16)
	await arena._capture(arena.verification_path("concept_02_walking.png"))
	Input.action_release("tank_right")
	await _frames(60)
	var yaw_before: float = tank.rotation.y
	arena.aim_position = tank.position + Vector3(-12, 1.5, -5)
	await _frames(100)
	checks.mouse_does_not_turn_body = absf(angle_difference(yaw_before, tank.rotation.y)) < 0.001
	checks.turret_aim_independent = absf(angle_difference(tank.rotation.y, tank.turret_yaw)) > 0.5
	await arena._capture(arena.verification_path("concept_03_other_side.png"))
	await _check_cruise()
	await _check_crowd_momentum()
	await _check_damage_feedback()
	var all_ok := true
	for value in checks.values(): all_ok = all_ok and value
	var report := {"passed": all_ok, "checks": checks, "metrics": metrics}
	var file := FileAccess.open(arena.verification_path("drive_result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("DRIVE_RESULT: ", JSON.stringify(report))
	get_tree().quit(0 if all_ok else 1)
