extends Node
var arena
var tank
var dash
var results := {}
var metrics := {}

func _ready() -> void:
	arena = get_parent()
	tank = arena.tank
	dash = tank.dash
	_run.call_deferred()

func _frames(count: int) -> void:
	for i in count: await get_tree().physics_frame

func _real(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout

func _key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _right(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _reset() -> void:
	_key(KEY_SPACE, false)
	_right(false)
	for action in ["tank_forward", "tank_reverse", "tank_left", "tank_right", "tank_fire", "crew_special", "crew_strike"]:
		Input.action_release(action)
	arena.tuning_open = false
	arena.hud.panel.hide()
	arena.reset_range()
	arena.test_aim = true
	arena.aim_position = Vector3(0, 0, -8)
	await _frames(3)

func _aim_mode() -> void:
	_key(KEY_SPACE, true)
	await _real(0.39)

func _run() -> void:
	await _frames(4)
	await _reset()
	var start: Vector3 = tank.position
	_key(KEY_SPACE, true)
	await _frames(2)
	results.press_does_not_dash = not dash.active and not dash.pending_normal and dash.normal_count == 0 and tank.position.distance_to(start) < 0.02
	_key(KEY_SPACE, false)
	await _frames(2)
	results.release_starts_dash = dash.active and dash.normal_count == 1 and tank.position.distance_to(start) > 0.10
	await _real(0.30)
	var distance: float = tank.position.distance_to(start)
	metrics.normal_distance = distance
	results.normal_range = distance > 5.0 and distance < 5.5
	results.tap_does_not_slow_time = is_equal_approx(Engine.time_scale, 1.0) and not dash.is_aiming()
	results.dash_crushes_small_props = arena.props.broken_count >= 4
	var count: int = dash.normal_count
	_key(KEY_SPACE, true)
	await _frames(2)
	_key(KEY_SPACE, false)
	await _frames(2)
	results.cooldown_prevents_spam = dash.normal_count == count
	await _real(0.30)
	results.landing_feet_valid = true
	for leg in tank.walker.legs:
		results.landing_feet_valid = results.landing_feet_valid and leg.foot.position.is_finite() and leg.stem.global_position.is_finite() and leg.stem.to_global(Vector3(0, -0.5, 0)).distance_to(leg.foot.to_global(Vector3(0, 0.88, 0.11))) < 0.005
	await arena._capture(arena.verification_path("dash_01_crushed.png"))
	await _reset()
	Input.action_press("tank_reverse")
	start = tank.position
	_key(KEY_SPACE, true)
	await _frames(2)
	_key(KEY_SPACE, false)
	await _real(0.25)
	var waited := 0
	while dash.active and waited < 60:
		await _frames(1)
		waited += 1
	Input.action_release("tank_reverse")
	var screen_back: Vector3 = arena.aim_camera.global_basis.z
	screen_back.y = 0.0
	metrics.down_travel = (tank.position - start).dot(screen_back.normalized())
	results.dash_follows_screen_input = metrics.down_travel > 5.0
	# Continuous walking and individual footfall contacts both break scenery.
	await _reset()
	var prop: RigidBody3D = arena.props.spawn_prop(Vector3(-1.03, 0, 2.6))
	Input.action_press("tank_forward")
	await _real(0.85)
	Input.action_release("tank_forward")
	results.walking_breaks_objects = not is_instance_valid(prop) or prop.get_meta("broken", false)
	await _real(0.35)
	results.shards_and_coins = arena.fx.pieces.size() > 0 and arena.crew.loot.coins > 0
	var foot_pos: Vector3 = tank.walker.legs[0].planted
	prop = arena.props.spawn_prop(foot_pos)
	var before: int = arena.props.broken_count
	tank.walker._land(tank.walker.legs[0])
	arena.props.shatter(prop)
	results.footfall_breaks_once = arena.props.broken_count == before + 1
	await _reset()
	start = tank.position
	await _aim_mode()
	results.hold_enters_slowmo = dash.is_aiming() and is_equal_approx(Engine.time_scale, 0.15)
	results.super_aim_has_no_initial_dash = dash.normal_count == 0 and not dash.active and tank.position.distance_to(start) < 0.02 and is_zero_approx(dash.cooldown)
	start = tank.position
	var target := start + Vector3(10, 0, 3)
	arena.aim_position = target
	await _real(0.12)
	results.preview_tracks_mouse = dash.landing.distance_to(target) < 0.10 and dash.marker.visible
	await arena._capture(arena.verification_path("dash_02_super_aim.png"))
	Input.action_press("tank_fire")
	await _frames(3)
	Input.action_release("tank_fire")
	results.aim_suppresses_cannon = tank.shot_count == 0
	_right(true)
	await _frames(3)
	results.super_commits = dash.active and dash.is_super and dash.super_count == 1 and is_equal_approx(Engine.time_scale, 1.0)
	results.super_does_not_cast_crew = arena.crew.combat.spells_fired == 0
	await _real(0.07)
	await arena._capture(arena.verification_path("dash_03_super_launch.png"))
	_right(false)
	_key(KEY_SPACE, false)
	await _real(0.50)
	metrics.super_travel = tank.position.distance_to(start)
	metrics.landing_error = tank.position.distance_to(target)
	results.super_lands_at_marker = tank.position.distance_to(target) < 0.20 and not dash.active
	results.super_release_has_no_extra_dash = dash.normal_count == 0 and dash.super_count == 1
	results.super_longer_than_normal = tank.position.distance_to(start) > 9.5
	await arena._capture(arena.verification_path("dash_04_landing.png"))
	# Clamp range and stop before a wall using the whole hull, not a centre ray.
	await _reset()
	var far: Vector3 = dash.landing_point(tank.position + Vector3(40, 0, 0))
	results.preview_range_limited = absf(far.distance_to(tank.position) - dash.SUPER_DISTANCE) < 0.10
	tank.position = Vector3(0, 0.03, 24)
	tank.rotation.y = PI
	tank.walker.reset_pose()
	await _frames(2)
	var wall_landing: Vector3 = dash.landing_point(Vector3(0, 0, 50))
	var hull_limit: float = 28.4 - tank.HULL_RADIUS
	results.preview_stops_before_wall = wall_landing.z <= hull_limit + 0.01 and dash.preview_blocked
	_key(KEY_SPACE, true)
	await _frames(2)
	_key(KEY_SPACE, false)
	await _real(0.35)
	results.dash_does_not_tunnel_walls = tank.position.z <= hull_limit + 0.01 and tank.position.z > 26.0 and not dash.active
	# A durable target may only take one ram hit from the same dash.
	await _reset()
	arena._spawn_target({"pos": Vector3(0, 0, 1), "barrel": false, "id": 99})
	var durable: PhysicsBody3D = arena.targets.back()
	durable.set_meta("hp", 250.0)
	await _frames(2)
	_key(KEY_SPACE, true)
	await _frames(2)
	_key(KEY_SPACE, false)
	await _real(0.35)
	results.ram_hits_once = is_instance_valid(durable) and is_equal_approx(float(durable.get_meta("hp")), 150.0)
	# Every interruption must restore time and remove the targeting visuals.
	await _reset()
	await _aim_mode()
	_key(KEY_SPACE, false)
	await _frames(2)
	results.release_cancels_super = not dash.is_aiming() and is_equal_approx(Engine.time_scale, 1.0) and dash.super_count == 0 and not dash.marker.visible
	results.cancelled_super_has_no_normal_dash = dash.normal_count == 0 and not dash.active and not dash.pending_normal
	await _reset()
	_key(KEY_SPACE, true)
	await _frames(2)
	_key(KEY_TAB, true)
	_key(KEY_TAB, false)
	_key(KEY_SPACE, false)
	await _frames(3)
	results.cancelled_short_press_has_no_dash = dash.normal_count == 0 and not dash.active and not dash.pending_normal
	await _reset()
	await _aim_mode()
	_key(KEY_TAB, true)
	_key(KEY_TAB, false)
	await _frames(2)
	results.tuning_cancels_slowmo = arena.tuning_open and is_equal_approx(Engine.time_scale, 1.0) and not dash.is_aiming()
	await _reset()
	await _aim_mode()
	_key(KEY_E, true)
	_key(KEY_E, false)
	await _real(0.16)
	results.disembark_cancels_dash = not arena.crew.crewed and not dash.active and is_equal_approx(Engine.time_scale, 1.0)
	_key(KEY_SPACE, false)
	await _frames(2)
	count = dash.normal_count
	_key(KEY_SPACE, true)
	await _frames(2)
	_key(KEY_SPACE, false)
	results.outside_space_still_spears = dash.normal_count == count and arena.crew.combat.spear_cd > 0.0
	var c: Vector3 = arena.crew.center()
	prop = arena.props.spawn_prop(c)
	await _frames(4)
	results.gnomes_do_not_crush_props = is_instance_valid(prop) and not prop.get_meta("broken", false)
	await _reset()
	await _aim_mode()
	arena._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	results.focus_loss_restores_time = is_equal_approx(Engine.time_scale, 1.0) and not dash.is_aiming()
	await _reset()
	await _aim_mode()
	_key(KEY_R, true)
	_key(KEY_R, false)
	await _frames(4)
	results.reset_restores_everything = is_equal_approx(Engine.time_scale, 1.0) and not dash.active and dash.normal_count == 0 and arena.props.broken_count == 0 and arena.props.props.size() == 48
	_key(KEY_SPACE, false)
	var all_ok := true
	for value in results.values(): all_ok = all_ok and value
	var report := {"passed": all_ok, "checks": results, "metrics": metrics}
	var file := FileAccess.open(arena.verification_path("dash_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("DASH_CHECK: ", JSON.stringify(report))
	get_tree().quit(0 if all_ok else 1)
