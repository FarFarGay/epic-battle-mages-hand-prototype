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
	print("AIM_METRICS: ", JSON.stringify({"world_drift_from_recoil": drift, "marker_step_pixels": marker_step}))
	print("AIM_RESULT: ", JSON.stringify(results))
	var file := FileAccess.open(arena.verification_path("aim_result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(results, "\t"))
	var passed := true
	for value in results.values():
		passed = passed and value
	get_tree().quit(0 if passed else 1)
