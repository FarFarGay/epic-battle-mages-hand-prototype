extends Node
const Geo = preload("res://scripts/geo.gd")
var arena
var tank
var guns
var checks := {}
var metrics := {}

func _ready() -> void:
	arena = get_parent()
	tank = arena.tank
	guns = tank.crossbows
	_run.call_deferred()

func _frames(count: int) -> void:
	for i in count: await get_tree().physics_frame

func _real(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout

func _mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = Vector2(720, 450)
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _reset() -> void:
	_mouse(MOUSE_BUTTON_RIGHT, false)
	_mouse(MOUSE_BUTTON_LEFT, false)
	_key(KEY_SPACE, false)
	for action in ["tank_forward", "tank_reverse", "tank_left", "tank_right"]: Input.action_release(action)
	arena.tuning_open = false
	arena.hud.panel.hide()
	arena.reset_range()
	arena.test_aim = true
	arena.aim_position = Vector3(0, 4, -25)
	await _frames(4)

func _wall(z: float) -> StaticBody3D:
	var wall := StaticBody3D.new()
	arena.add_child(wall)
	wall.position = Vector3(0, 3.5, z)
	Geo.collider(wall, Vector3(8, 7, 0.06), Vector3.ZERO)
	return wall

func _run() -> void:
	await _reset()
	checks.full_magazine = guns.ammo == 200 and guns.reload_left == 0.0
	checks.two_visible_mounts = guns.mounts.size() == 2 and guns.mounts[0].pivot.is_visible_in_tree() and guns.mounts[1].pivot.is_visible_in_tree()
	await _frames(35)
	await arena._capture(arena.verification_path("crossbow_01_ready.png"))
	_mouse(MOUSE_BUTTON_RIGHT, true)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _frames(3)
	checks.quick_click_fires_once = guns.shot_count == 1 and guns.ammo == 199
	await _frames(8)
	checks.release_stops_fire = guns.shot_count == 1
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(30)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	var count: int = guns.shot_count
	metrics.bolts_in_half_second = count - 1
	checks.machine_gun_cadence = count >= 10 and count <= 12
	checks.alternating_both_sides = guns.side_counts[0] > 0 and guns.side_counts[1] > 0 and absi(guns.side_counts[0] - guns.side_counts[1]) <= 1
	checks.real_projectiles = not guns.bolts.is_empty()
	checks.secondary_only = tank.shot_count == 0 and arena.crew.combat.spells_fired == 0
	await _frames(8)
	checks.no_extra_bolts_on_release = guns.shot_count == count
	checks.no_early_reload = guns.reload_left == 0.0 and guns.ammo == 200 - count

	# Empty the entire magazine through the actual held mouse path.
	await _reset()
	_mouse(MOUSE_BUTTON_RIGHT, true)
	var elapsed := 0
	var peak_bolts := 0
	while guns.reload_left <= 0.0 and elapsed < 660:
		await _frames(1)
		elapsed += 1
		peak_bolts = maxi(peak_bolts, guns.bolts.size())
		if elapsed == 80: await arena._capture(arena.verification_path("crossbow_02_burst.png"))
	metrics.magazine_seconds = elapsed / 60.0
	metrics.peak_projectiles = peak_bolts
	checks.magazine_exactly_200 = guns.shot_count == 200 and guns.ammo == 0 and guns.side_counts == [100, 100]
	checks.ten_second_burst = elapsed >= 590 and elapsed <= 608
	checks.projectiles_bounded = peak_bolts <= 16
	checks.auto_reload_starts = guns.reload_left > 6.8
	await _frames(180)
	checks.reload_blocks_held_fire = guns.shot_count == 200 and guns.ammo == 0 and guns.reload_left > 3.8
	await arena._capture(arena.verification_path("crossbow_03_reload.png"))
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _frames(270)
	checks.full_refill_after_long_reload = guns.ammo == 200 and guns.reload_left == 0.0 and guns.shot_count == 200
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(4)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	checks.fires_after_reload = guns.shot_count > 200 and guns.ammo < 200

	# Aim at a real target, then check a thin wall between it and the guns.
	await _reset()
	arena.aim_position = Vector3(0, 1.5, -8)
	await _frames(60)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(90)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	checks.bolts_destroy_target = arena.kills >= 1 and guns.hit_count >= 13
	await _reset()
	arena.aim_position = Vector3(0, 1.5, -8)
	var wall := _wall(-1.0)
	await _frames(60)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(45)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _frames(45)
	checks.thin_wall_stops_bolts = guns.hit_count == 0 and arena.kills == 0 and float(arena.targets[0].get_meta("hp")) == 100.0
	wall.queue_free()
	await _frames(3)
	wall = _wall(4.0)
	await _frames(3)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(30)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _frames(40)
	checks.muzzle_cannot_shoot_through_wall = guns.hit_count == 0 and arena.kills == 0
	wall.queue_free()
	await _frames(3)
	await _reset()
	var prop: StaticBody3D = arena.props.spawn_prop(Vector3(0, 0, -4))
	arena.aim_position = Vector3(0, 0.35, -4)
	await _frames(60)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(50)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	checks.bolts_break_small_props = not is_instance_valid(prop) or prop.get_meta("broken", false)

	await _reset()
	_mouse(MOUSE_BUTTON_RIGHT, true)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(30)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	_mouse(MOUSE_BUTTON_LEFT, false)
	checks.both_weapons_independent = tank.shot_count == 1 and guns.shot_count >= 8 and tank.cooldown > 0.0
	await _reset()
	Input.action_press("tank_forward")
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(35)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	Input.action_release("tank_forward")
	checks.fires_while_walking = tank.position.z < 4.5 and guns.shot_count >= 10

	await _reset()
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(5)
	_key(KEY_SPACE, true)
	await _real(0.38)
	count = guns.shot_count
	await _real(0.15)
	checks.super_aim_stops_burst = tank.dash.is_aiming() and guns.shot_count == count and not guns.trigger_held
	_mouse(MOUSE_BUTTON_RIGHT, false)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _real(0.5)
	_key(KEY_SPACE, false)
	await _frames(5)
	checks.super_click_never_fires_bolts = tank.dash.super_count == 1 and guns.shot_count == count and not guns.trigger_held
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _frames(3)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(5)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	checks.fresh_click_after_super_fires = guns.shot_count > count

	await _reset()
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(5)
	_key(KEY_TAB, true)
	_key(KEY_TAB, false)
	count = guns.shot_count
	await _frames(15)
	_key(KEY_TAB, true)
	_key(KEY_TAB, false)
	await _frames(10)
	checks.tuning_cancels_held_fire = guns.shot_count == count and not guns.trigger_held
	await _reset()
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(5)
	arena._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	count = guns.shot_count
	await _frames(10)
	checks.focus_loss_cancels_fire = guns.shot_count == count and not guns.trigger_held

	await _reset()
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(10)
	_key(KEY_E, true)
	_key(KEY_E, false)
	await _frames(6)
	count = guns.shot_count
	var ammo_before: int = guns.ammo
	await _frames(10)
	checks.disembark_stops_burst = not arena.crew.crewed and guns.shot_count == count and arena.crew.combat.spells_fired == 0
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _frames(4)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(5)
	checks.outside_right_click_is_crew_special = arena.crew.combat.spells_fired == 2 and guns.shot_count == count
	_key(KEY_E, true)
	_key(KEY_E, false)
	await _frames(8)
	checks.boarding_preserves_ammo_and_requires_release = arena.crew.crewed and guns.ammo == ammo_before and guns.shot_count == count
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _frames(4)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(5)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	checks.fresh_click_after_boarding_fires = guns.shot_count > count
	_key(KEY_R, true)
	_key(KEY_R, false)
	await _frames(5)
	checks.reset_restores_weapon = guns.ammo == 200 and guns.reload_left == 0.0 and guns.shot_count == 0 and guns.bolts.is_empty() and not guns.trigger_held
	await arena._capture(arena.verification_path("crossbow_04_reset.png"))
	var passed := true
	for value in checks.values(): passed = passed and value
	var report := {"passed": passed, "checks": checks, "metrics": metrics}
	var file := FileAccess.open(arena.verification_path("crossbow_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("CROSSBOW_CHECK: ", JSON.stringify(report))
	get_tree().quit(0 if passed else 1)
