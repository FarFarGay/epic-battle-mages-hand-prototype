extends Node
## Focused regressions for camera feedback, target edges and footfall shake.

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var arena = get_parent()
	await get_tree().create_timer(0.1).timeout
	arena.set_physics_process(false)
	arena.set_process(false)
	arena.test_aim = false
	arena.tuning_open = false
	var dt := 1.0 / 60.0
	var target := Vector3(0, 1.5, -8)
	var pointer: Vector2 = arena.aim_camera.unproject_position(target)
	# Settle the initial ray sample before isolating changes caused by camera shake.
	arena._update_aim(10.0, pointer)
	arena._update_aim(10.0, pointer)
	var before: Vector3 = arena.aim_position
	var ground_before: Vector3 = arena.ground_aim_position
	var visual_before: Vector2 = arena.camera.unproject_position(target)
	arena.trauma = 1.0
	arena.kick = Vector3(2, 0, -2)
	arena.zoom_punch = 2.0
	arena._update_camera(0.0)
	arena._update_aim(10.0, pointer)
	var drift: float = before.distance_to(arena.aim_position)
	var results := {
		"recoil_does_not_move_mouse_aim": drift < 0.001,
		"target_height_does_not_shift_camera_lead": ground_before.distance_to(arena.ground_aim_position) < 0.001,
		"camera_impact_preserved": visual_before.distance_to(arena.camera.unproject_position(target)) > 2.0,
	}
	var empty_pointer: Vector2 = get_viewport().get_visible_rect().size * Vector2(0.25, 0.72)
	var ground = Plane(Vector3.UP, 0.0).intersects_ray(arena.aim_camera.project_ray_origin(empty_pointer), arena.aim_camera.project_ray_normal(empty_pointer))
	var total: float = before.distance_to(ground)
	arena._update_aim(dt, empty_pointer)
	var first_step: float = before.distance_to(arena.aim_position)
	results["target_to_ground_transition_is_smooth"] = first_step > 0.0 and first_step < total * 0.5
	for i in 90:
		arena._update_aim(dt, empty_pointer)
	results["mouse_aim_settles_exactly"] = arena.aim_position.distance_to(ground) < 0.001
	arena.tank.body_visual.rotation = Vector3(0.12, 0, 0.1)
	arena.tank.aim_world = target
	arena.tank._update_gun_aim(dt)
	results["upper_floor_stabilized_against_steps"] = arena.tank.turret.global_basis.y.dot(Vector3.UP) > 0.99999
	arena.actual_hit = target
	arena.hud.reset_reticle()
	arena.hud.update_reticle(dt)
	var marker_before: Vector2 = arena.hud.gun_reticle
	arena.kick = Vector3(-2, 0, 1)
	arena._update_camera(0.0)
	arena.hud.update_reticle(dt)
	results["marker_ignores_camera_shake"] = marker_before.distance_to(arena.hud.gun_reticle) < 0.001
	arena.actual_hit = Vector3(-8, 0, 0)
	var destination: Vector2 = arena.aim_camera.unproject_position(arena.actual_hit)
	arena.hud.update_reticle(dt)
	var marker_step: float = marker_before.distance_to(arena.hud.gun_reticle)
	results["marker_jump_is_bounded"] = marker_step > 0.0 and marker_step <= 20.001 and marker_step < marker_before.distance_to(destination)
	for i in 90:
		arena.hud.update_reticle(dt)
	results["marker_settles_on_actual_hit"] = destination.distance_to(arena.hud.gun_reticle) < 0.01
	await _check_camera_orbit(arena, results)
	print("AIM_METRICS: ", JSON.stringify({"world_drift_from_recoil": drift, "marker_step_pixels": marker_step}))
	print("AIM_RESULT: ", JSON.stringify(results))
	var file := FileAccess.open(arena.verification_path("aim_result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(results, "\t"))
	var passed := true
	for value in results.values():
		passed = passed and value
	get_tree().quit(0 if passed else 1)

func _mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = Vector2(720, 450)
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _motion(delta: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.relative = delta
	event.screen_relative = delta
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()

func _check_camera_orbit(arena, results: Dictionary) -> void:
	var dt := 1.0 / 60.0
	arena.reset_range()
	arena._update_camera(1.0)
	await get_tree().physics_frame
	var original: Vector3 = arena.aim_camera.position - arena.focus
	results.orbit_preserves_default_isometric_view = original.distance_to(Vector3(24, 24, 24)) < 0.001
	var yaw: float = arena.camera_yaw
	_motion(Vector2(80, 30))
	results.mouse_without_middle_does_not_orbit = arena.camera_yaw == yaw
	var aim: Vector3 = arena.aim_position
	_mouse(MOUSE_BUTTON_MIDDLE, true)
	results.middle_captures_orbit = arena.camera_rotating and (DisplayServer.get_name() == "headless" or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	_motion(Vector2(160, 25))
	results.drag_rotates_view = absf(angle_difference(yaw, arena.camera_yaw)) > 0.7 and is_equal_approx((arena.aim_camera.position - arena.focus).y, 24.0)
	results.orbit_keeps_distance_and_projection = absf((arena.aim_camera.position - arena.focus).length() - original.length()) < 0.001 and arena.camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	arena._update_aim(10.0, Vector2(900, 600))
	results.orbit_holds_world_aim = arena.aim_position.distance_to(aim) < 0.001
	_mouse(MOUSE_BUTTON_LEFT, true)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	arena.crew.tick(dt)
	arena.tank.tick(dt)
	results.orbit_does_not_fire = arena.tank.shot_count == 0 and arena.tank.crossbows.shot_count == 0
	var view_before_vertical: Transform3D = arena.aim_camera.global_transform
	_motion(Vector2(0, 9000))
	results.vertical_drag_down_preserves_view = arena.aim_camera.global_transform.is_equal_approx(view_before_vertical)
	_motion(Vector2(0, -9000))
	results.vertical_drag_up_preserves_view = arena.aim_camera.global_transform.is_equal_approx(view_before_vertical)
	_motion(Vector2(0, 36))
	_mouse(MOUSE_BUTTON_MIDDLE, false)
	results.release_stops_orbit_and_releases_cursor = not arena.camera_rotating and (DisplayServer.get_name() == "headless" or Input.mouse_mode == Input.MOUSE_MODE_HIDDEN)
	arena.crew.tick(dt)
	arena.tank.tick(dt)
	results.orbit_buttons_do_not_leak_to_weapons = arena.tank.shot_count == 0 and arena.tank.crossbows.shot_count == 0
	_mouse(MOUSE_BUTTON_LEFT, false)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	arena.crew.tick(dt)
	yaw = arena.camera_yaw
	_motion(Vector2(90, 0))
	results.release_preserves_chosen_angle = arena.camera_yaw == yaw
	var right: Vector3 = arena.aim_camera.global_basis.x
	right.y = 0
	Input.action_press("tank_right")
	results.wasd_follows_rotated_camera = arena.tank.input_direction().dot(right.normalized()) > 0.999
	Input.action_release("tank_right")
	var zoom: float = arena.zoom
	_mouse(MOUSE_BUTTON_WHEEL_UP, true)
	_mouse(MOUSE_BUTTON_WHEEL_UP, false)
	results.scroll_still_zooms = arena.zoom < zoom
	_mouse(MOUSE_BUTTON_MIDDLE, true)
	_key(KEY_TAB)
	results.tuning_releases_orbit = arena.tuning_open and not arena.camera_rotating and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
	_mouse(MOUSE_BUTTON_MIDDLE, false)
	_mouse(MOUSE_BUTTON_MIDDLE, true)
	results.tuning_does_not_capture_mouse = not arena.camera_rotating
	_mouse(MOUSE_BUTTON_MIDDLE, false)
	_key(KEY_TAB)
	_mouse(MOUSE_BUTTON_MIDDLE, true)
	arena._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	results.focus_loss_releases_orbit = not arena.camera_rotating and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	_mouse(MOUSE_BUTTON_MIDDLE, false)

	arena.reset_range()
	arena.tank.position = Vector3(16, 0.03, 6)
	arena.crew.loot.items[0].position = Vector3(16, 0.5, 11)
	arena.focus = arena.tank.position + Vector3.UP
	arena._update_camera(1.0)
	await get_tree().physics_frame
	var hand = arena.hand
	hand.set_enabled(true)
	arena.crew.tick(dt)
	var cargo: RigidBody3D = arena.crew.loot.items[0]
	results.no_roof_hand_fixture = hand.rack.get_child_count() == 0
	results.hand_available_before_orbit = hand.grab(cargo)
	hand.test_pointer = arena.aim_camera.unproject_position(Vector3(14, 0, 8))
	hand.tick(dt)
	var cargo_position: Vector3 = cargo.position
	_mouse(MOUSE_BUTTON_MIDDLE, true)
	_motion(Vector2(200, 15))
	hand.tick(dt)
	results.orbit_preserves_carried_object = hand.held == cargo and cargo.position.distance_to(cargo_position) < 0.001 and not hand.hand_mesh.visible
	_mouse(MOUSE_BUTTON_MIDDLE, false)
	# Match the restored cursor in this deterministic pointer-driven test.
	hand.test_pointer = arena.aim_camera.unproject_position(hand.cursor_world)
	hand.tick(dt)
	results.hand_resumes_without_jump = hand.held == cargo and cargo.position.distance_to(cargo_position) < 0.05 and hand.velocity_history.is_empty()
	_mouse(MOUSE_BUTTON_MIDDLE, true)
	_mouse(MOUSE_BUTTON_LEFT, false)
	hand.tick(dt)
	results.release_during_orbit_places_gently = hand.held == null and not cargo.freeze and cargo.linear_velocity.length() < 0.01
	_mouse(MOUSE_BUTTON_MIDDLE, false)
	arena.crew.tick(dt)
	var disembarked: bool = arena.crew.disembark()
	_mouse(MOUSE_BUTTON_MIDDLE, true)
	_motion(Vector2(-70, 10))
	results.orbit_available_on_foot = disembarked and arena.camera_rotating
	_mouse(MOUSE_BUTTON_MIDDLE, false)
	# Capture both the clean roof in hand mode and the changed viewing angle.
	arena.reset_range()
	arena._update_camera(1.0)
	arena.hand.set_enabled(true)
	arena.hand.test_pointer = Vector2(800, 500)
	arena.crew.tick(dt)
	arena.hand.tick(dt)
	arena.hud.queue_redraw()
	await arena._capture(arena.verification_path("camera_01_clean_roof.png"))
	_mouse(MOUSE_BUTTON_MIDDLE, true)
	_motion(Vector2(240, 55))
	_mouse(MOUSE_BUTTON_MIDDLE, false)
	arena.hand.tick(dt)
	arena.hud.queue_redraw()
	await arena._capture(arena.verification_path("camera_02_orbit.png"))
	_key(KEY_EQUAL)
	await arena._capture(arena.verification_path("interface_01_hidden.png"))
	_key(KEY_EQUAL)
	await arena._capture(arena.verification_path("interface_02_restored.png"))
	_mouse(MOUSE_BUTTON_MIDDLE, true)
	arena.reset_range()
	results.reset_restores_camera_and_cursor = not arena.camera_rotating and is_equal_approx(arena.camera_yaw, arena.CAMERA_DEFAULT_YAW) and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	_mouse(MOUSE_BUTTON_MIDDLE, false)
