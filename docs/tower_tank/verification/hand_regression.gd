extends Node
## Input routing + real rigid-body carrying, roof ownership, socket and lifecycle.
const Geo = preload("res://scripts/geo.gd")
var arena
var tank
var hand
var checks := {}
var metrics := {}

func _ready() -> void:
	arena = get_parent()
	tank = arena.tank
	hand = arena.hand
	_run.call_deferred()

func _frames(count: int) -> void:
	for i in count: await get_tree().physics_frame

func _key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _tap(code: Key) -> void:
	_key(code, true)
	_key(code, false)

func _mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = Vector2(720, 450)
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _point(world: Vector3, frames: int = 3) -> void:
	for i in frames:
		hand.test_pointer = arena.aim_camera.unproject_position(world)
		await _frames(1)

func _reset() -> void:
	_mouse(MOUSE_BUTTON_LEFT, false)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	_key(KEY_SPACE, false)
	_key(KEY_SHIFT, false)
	for action in ["tank_forward", "tank_reverse", "tank_left", "tank_right"]: Input.action_release(action)
	arena.tuning_open = false
	arena.hud.panel.hide()
	arena.reset_range()
	arena.test_aim = true
	arena.aim_position = Vector3(15, 0, 14)
	tank.position = Vector3(16, 0.03, 6)
	arena.crew.loot.items[0].position = Vector3(16, 0.5, 11)
	tank.walker.reset_pose()
	await _frames(8)

func _enable() -> void:
	_tap(KEY_F)
	await _frames(3)

func _run() -> void:
	await _repeat_cube_throws()
	await _expanded_grabs()
	await _reset()
	checks.starts_in_weapon_mode = not hand.enabled and arena.weapon_mode_active()
	await _enable()
	checks.f_selects_hand = hand.enabled and not arena.weapon_mode_active()
	await _point(Vector3(15, 0, 10))
	_mouse(MOUSE_BUTTON_LEFT, true)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	tank.fire()
	await _frames(20)
	checks.hand_blocks_both_weapons = tank.shot_count == 0 and tank.crossbows.shot_count == 0
	checks.gun_reticle_hidden = arena.hud.reticle_alpha == 0.0
	_tap(KEY_F)
	await _frames(10)
	checks.held_buttons_do_not_fire_on_mode_switch = tank.shot_count == 0 and tank.crossbows.shot_count == 0
	_mouse(MOUSE_BUTTON_LEFT, false)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _frames(4)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(3)
	_mouse(MOUSE_BUTTON_LEFT, false)
	checks.f_restores_cannon = tank.shot_count == 1

	await _reset()
	await _enable()
	var box: RigidBody3D = arena.crew.loot.items[0]
	await _point(box.global_position)
	checks.cursor_finds_cargo = hand.candidate == box
	await arena._capture(arena.verification_path("hand_01_hover.png"))
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(3)
	checks.hold_grabs_physical_cargo = hand.held == box and box.freeze and box.get_meta("hand_owner", "") == "hand"
	await _point(Vector3(14, 0, 8), 12)
	checks.drag_moves_cargo = box.global_position.distance_to(Vector3(16.5, 1.5, 10.5)) < 0.4
	metrics.drag_position = str(box.global_position)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(2)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	_mouse(MOUSE_BUTTON_LEFT, false)
	checks.soft_release_restores_physics = hand.held == null and not box.freeze and box.collision_layer == 8 and box.collision_mask == 9 and not box.has_meta("hand_owner") and box.linear_velocity.length() < 1.0
	await _frames(40)
	checks.released_cargo_lands_on_floor = box.global_position.y > 0.25 and box.global_position.y < 0.5

	await _point(box.global_position)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(3)
	await _point(tank.global_position, 12)
	checks.tower_snap_preview = hand.snap_destination == "tower"
	metrics.tower_snap = {"held": hand.held == box, "position": str(box.position), "surface": str(hand.cursor_surface), "reach": hand.can_reach(box)}
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(3)
	checks.release_attaches_to_roof = hand.mounted == box and hand.held == null and box.freeze and (box.collision_layer & hand.HELD_LAYER) != 0
	await arena._capture(arena.verification_path("hand_02_roof.png"))
	_tap(KEY_F)
	await _frames(3)
	Input.action_press("tank_right")
	_key(KEY_SHIFT, true)
	await _frames(35)
	Input.action_release("tank_right")
	_key(KEY_SHIFT, false)
	await _frames(15)
	checks.roof_cargo_follows_cruise_and_turret = hand.mounted == box and box.global_position.distance_to(hand._cargo_position(box)) < 0.03
	tank.dash.space(true)
	tank.dash.space(false)
	await _frames(20)
	checks.dash_preserves_roof_cargo = hand.mounted == box and box.global_position.distance_to(hand._cargo_position(box)) < 0.03
	await _enable()
	await _point(box.global_position)
	checks.roof_cargo_can_be_targeted = hand.candidate == box
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(2)
	checks.grab_detaches_roof_cargo = hand.held == box and hand.mounted == null
	_tap(KEY_F)
	checks.mode_exit_drops_held_cargo = hand.held == null and not box.freeze and not box.has_meta("hand_owner")

	await _reset()
	await _enable()
	box = arena.crew.loot.items[0]
	box.mass = 10.0
	checks.heavy_cargo_rejected = not hand.grab(box)
	box.mass = 2.0
	arena.crew.loot.cargo = box
	checks.crew_owned_cargo_rejected = not hand.grab(box)
	arena.crew.loot.cargo = null
	box.position = Vector3(-20, 0.5, -20)
	checks.out_of_reach_rejected = not hand.grab(box)
	tank.position = Vector3(18, 0.03, 8)
	box.position = Vector3(18, 0.5, 12)
	await _frames(3)
	var wall := StaticBody3D.new()
	arena.add_child(wall)
	wall.position = Vector3(18, 3.5, 14)
	Geo.collider(wall, Vector3(12, 7, 0.2), Vector3.ZERO)
	await _frames(3)
	checks.can_grab_before_wall = hand.grab(box)
	await _point(Vector3(16, 0, 18), 6)
	checks.whole_cargo_cannot_cross_wall = box.position.z < 13.7
	hand.cancel_drag()
	box.position = Vector3(18, 0.5, 16)
	await _frames(3)
	checks.wall_blocks_remote_grab = not hand.grab(box)
	wall.queue_free()
	await _frames(3)

	await _reset()
	await _enable()
	var cube: RigidBody3D = hand.puzzle.cube
	await _point(cube.global_position)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(3)
	checks.grabs_puzzle_cube = hand.held == cube
	metrics.cube_pick = {"candidate": str(hand.candidate), "surface": str(hand.cursor_surface), "reachable": hand.can_reach(cube), "armed": arena.crew.input_armed}
	await _point(hand.puzzle.socket_position, 12)
	checks.socket_preview = hand.snap_destination == "socket"
	metrics.socket_drag_position = str(cube.global_position)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(60)
	checks.cube_opens_gate = hand.puzzle.seated and hand.puzzle.opened and hand.puzzle.gate.collision_layer == 0 and cube.freeze
	await arena._capture(arena.verification_path("hand_03_gate.png"))
	await _point(cube.global_position)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(3)
	checks.detach_cube_closes_gate = hand.held == cube and not hand.puzzle.seated and not hand.puzzle.opened and hand.puzzle.gate.collision_layer == 1
	hand.cancel_drag()
	_mouse(MOUSE_BUTTON_LEFT, false)
	hand.puzzle.seat(cube)
	tank.position = hand.puzzle.gate_position
	hand.puzzle.unseat(cube)
	await _frames(3)
	checks.gate_wont_close_through_tower = hand.puzzle.opened
	tank.position = Vector3(10, 0.03, 8)
	await _frames(3)
	checks.gate_closes_when_clear = not hand.puzzle.opened

	await _reset()
	await _enable()
	var chest: Dictionary = arena.crew.loot.chests[0]
	await _point(chest.node.global_position + Vector3.UP * 0.3)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _point(hand._center(chest.node), 6)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(3)
	checks.hand_opens_chest = chest.opened and tank.shot_count == 0
	box = arena.crew.loot.items[0]
	await _frames(3)
	hand.grab(box)
	_tap(KEY_TAB)
	checks.tuning_releases_cargo = hand.held == null and not box.freeze
	_tap(KEY_TAB)
	await _frames(3)
	hand.grab(box)
	arena._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	checks.focus_loss_releases_cargo = hand.held == null and not box.freeze and not hand.grab_pressed
	await _frames(3)
	hand.grab(box)
	var left: bool = arena.crew.disembark()
	checks.disembark_exits_hand = left and not hand.enabled and hand.held == null and not box.freeze
	_tap(KEY_F)
	checks.on_foot_cannot_enter_hand = not hand.enabled

	await _reset()
	await _enable()
	box = arena.crew.loot.items[0]
	hand.grab(box)
	await _point(tank.position, 10)
	hand.trigger(false)
	await _frames(3)
	var second: RigidBody3D = hand.puzzle.cube
	checks.second_item_grab_with_full_roof = hand.grab(second)
	await _point(tank.position, 10)
	checks.full_roof_has_no_snap = hand.snap_destination == "" and hand.mounted == box
	hand.place_gently()
	await _frames(3)
	checks.full_roof_does_not_replace_or_lose_cargo = hand.mounted == box and not second.freeze and not second.has_meta("hand_owner")
	tank.take_damage(2000.0)
	await _frames(4)
	checks.destroyed_tower_releases_roof_cargo = tank.dead and not hand.enabled and hand.mounted == null and not box.freeze and not box.has_meta("hand_owner")

	await _reset()
	await _enable()
	hand.grab(arena.crew.loot.items[0])
	_key(KEY_SPACE, true)
	await get_tree().create_timer(0.36, true, false, true).timeout
	await _frames(2)
	checks.superdash_aim_cancels_hand_drag = tank.dash.is_aiming() and hand.held == null
	arena.aim_position = tank.position + Vector3(0, 0, -8)
	await _frames(2)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(3)
	checks.superdash_commit_works_in_hand = tank.dash.super_count == 1 and tank.crossbows.shot_count == 0 and tank.shot_count == 0
	_mouse(MOUSE_BUTTON_RIGHT, false)
	_key(KEY_SPACE, false)
	await _frames(30)
	checks.superdash_returns_to_hand = hand.enabled and not tank.dash.active and Engine.time_scale == 1.0

	await _reset()
	await _enable()
	tank.cooldown = 0.2
	tank.crossbows.ammo = 0
	tank.crossbows.reload_left = 0.2
	await _frames(20)
	checks.reloading_continues_in_hand = tank.cooldown <= 0.0 and tank.crossbows.ammo == 200 and tank.crossbows.reload_left <= 0.0
	hand.grab(hand.puzzle.cube)
	_tap(KEY_R)
	await _frames(4)
	checks.reset_cleans_hand_and_puzzle = not hand.enabled and hand.held == null and hand.mounted == null and not hand.puzzle.seated and not hand.puzzle.opened and is_instance_valid(hand.puzzle.cube)
	var passed := true
	for result in checks.values(): passed = passed and result
	var report := {"passed": passed, "checks": checks, "metrics": metrics}
	var file := FileAccess.open(arena.verification_path("hand_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("HAND_RESULT: ", JSON.stringify(report))
	get_tree().quit(0 if passed else 1)

func _repeat_cube_throws() -> void:
	await _reset()
	await _enable()
	var cube: RigidBody3D = hand.puzzle.cube
	var repeat_ok := true
	var mount_ok := true
	for i in 8:
		await _point(cube.global_position, 6)
		_mouse(MOUSE_BUTTON_LEFT, true)
		await _frames(3)
		if hand.held != cube:
			print("REPEAT_GRAB_FAILED: ", {"iteration": i, "cube": str(cube.global_position), "layer": cube.collision_layer, "mask": cube.collision_mask, "owner": cube.get_meta("hand_owner", ""), "freeze": cube.freeze, "reachable": hand.can_reach(cube), "candidate": str(hand.candidate), "surface": str(hand.cursor_surface), "armed": arena.crew.input_armed})
			repeat_ok = false
			_mouse(MOUSE_BUTTON_LEFT, false)
			break
		if i % 2 == 0:
			await _point(tank.position, 10)
			_mouse(MOUSE_BUTTON_LEFT, false)
			await _frames(3)
			mount_ok = mount_ok and hand.mounted == cube
			await _point(cube.global_position, 3)
			_mouse(MOUSE_BUTTON_LEFT, true)
			await _frames(3)
			mount_ok = mount_ok and hand.held == cube and hand.mounted == null
		await _point(Vector3(11, 0, 10), 10)
		for step in 6: await _point(Vector3(11 + step * 1.15, 0, 10 + step * 0.2), 1)
		_mouse(MOUSE_BUTTON_LEFT, false)
		await _frames(90)
	checks.repeated_cube_throws_remain_grabbable = repeat_ok
	checks.repeated_cube_mount_detach_throws = mount_ok

func _expanded_grabs() -> void:
	for kind in 3:
		await _reset()
		await _enable()
		var prop: RigidBody3D = arena.props.spawn_prop(Vector3(16, 0, 12), kind)
		await _frames(3)
		await _point(hand._center(prop))
		_mouse(MOUSE_BUTTON_LEFT, true)
		await _frames(3)
		checks["small_prop_%d_grab" % kind] = hand.held == prop
		await _point(tank.position, 10)
		_mouse(MOUSE_BUTTON_LEFT, false)
		await _frames(3)
		checks["small_prop_%d_mount" % kind] = hand.mounted == prop
		arena.props.stomp(tank.position, 2.0)
		checks["small_prop_%d_survives_carriage" % kind] = is_instance_valid(prop) and arena.props.props.has(prop)
		hand.grab(prop)
		await _point(Vector3(14, 0, 10), 10)
		hand.place_gently()
		await _frames(60)
		checks["small_prop_%d_gentle_drop" % kind] = is_instance_valid(prop) and arena.props.props.has(prop) and not prop.freeze
		checks["small_prop_%d_regrab" % kind] = hand.grab(prop)
		await _point(Vector3(14, 0, 10), 5)
		hand.velocity_history.assign([Vector3(18, 0, 0)])
		hand._release(false, false)
		await _frames(90)
		checks["small_prop_%d_breaks_on_throw" % kind] = not is_instance_valid(prop) or not arena.props.props.has(prop)

	await _reset()
	await _enable()
	var chest: Dictionary = arena.crew.loot.chests[0]
	chest.node.position = Vector3(16, 0, 12)
	await _frames(3)
	await _point(hand._center(chest.node))
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _point(hand._center(chest.node), 16)
	checks.chest_hold_carries_without_opening = hand.held == chest.node and not chest.opened
	metrics.chest_hold = {"held": str(hand.held), "candidate": str(hand.candidate), "age": hand.grab_age, "opened": chest.opened}
	await _point(Vector3(14, 0, 10), 8)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(60)
	checks.chest_reusable_after_drop = hand.grab(chest.node)
	hand.cancel_drag()

	await _reset()
	await _enable()
	arena._spawn_target({"pos": Vector3(16, 0, 12), "barrel": true, "id": 90})
	var barrel: RigidBody3D = arena.targets.back()
	await _frames(3)
	checks.powder_barrel_grabbable = hand.grab(barrel)
	await _point(Vector3(14, 0, 10), 5)
	hand.velocity_history.assign([Vector3(18, 0, 0)])
	hand._release(false, false)
	await _frames(90)
	checks.thrown_powder_barrel_explodes = not is_instance_valid(barrel) or not arena.targets.has(barrel)

	await _reset()
	await _enable()
	var enemy = arena.battle.spawn_enemy(Vector3(16, 0, 12))
	await _frames(3)
	await _point(hand._center(enemy))
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(3)
	checks.skeleton_picked_through_mouse = hand.held == enemy and enemy.hand_held
	await _point(Vector3(14, 0, 8), 8)
	var hp_before: float = tank.hp
	var attacks_before: int = enemy.attacks
	await _frames(45)
	checks.held_skeleton_cannot_attack = enemy.attacks == attacks_before and tank.hp == hp_before and enemy.hand_held
	await arena._capture(arena.verification_path("hand_04_skeleton.png"))
	hand.place_gently()
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(60)
	checks.skeleton_survives_soft_release_and_recovers = is_instance_valid(enemy) and not enemy.dead and not enemy.hand_held and not enemy.hand_thrown and enemy.collision_layer == 64
	checks.skeleton_can_be_picked_again = hand.grab(enemy)
	await _point(Vector3(14, 0, 10), 8)
	checks.skeleton_not_stored_as_roof_cargo = hand._snap_destination() == "" and hand.mounted == null
	hand.velocity_history.assign([Vector3(24, 0, 0)])
	hand._release(false, false)
	await _frames(5)
	await arena._capture(arena.verification_path("hand_05_throw.png"))
	await _frames(65)
	checks.skeleton_throw_has_impact_damage = not is_instance_valid(enemy) or enemy.hp < enemy.max_hp

	await _reset()
	await _enable()
	enemy = arena.battle.spawn_enemy(Vector3(16, 0, 12))
	var victim = arena.battle.spawn_enemy(Vector3(20, 0, 12))
	victim.move_speed = 0.0
	await _frames(3)
	hand.grab(enemy)
	await _point(Vector3(13.5, 0, 9.5), 8)
	hand.velocity_history.assign([Vector3(18, 0, 0)])
	hand._release(false, false)
	await _frames(40)
	checks.skeleton_throw_damages_other_skeleton = not is_instance_valid(victim) or victim.hp < victim.max_hp

	await _reset()
	await _enable()
	enemy = arena.battle.spawn_enemy(Vector3(16, 0, 12))
	await _frames(3)
	hand.grab(enemy)
	await _point(Vector3(14, 0, 10), 8)
	hand.velocity_history.assign([Vector3(10, 0, 0)])
	hand._release(false, false)
	await _frames(3)
	checks.flying_skeleton_can_be_caught = hand.grab(enemy) and enemy.hand_held and not enemy.hand_thrown
	_tap(KEY_F)
	await _frames(60)
	checks.mode_exit_releases_skeleton = not hand.enabled and hand.held == null and is_instance_valid(enemy) and not enemy.hand_held and not enemy.hand_thrown

	await _reset()
	await _enable()
	enemy = arena.battle.spawn_enemy(Vector3(20, 0, 12))
	enemy.move_speed = 0.0
	var cube: RigidBody3D = hand.puzzle.cube
	await _frames(3)
	hand.grab(cube)
	await _point(Vector3(13.5, 0, 9.5), 10)
	hand.velocity_history.assign([Vector3(18, 0, 0)])
	hand._release(false, false)
	await _frames(75)
	checks.thrown_cube_damages_skeleton = not is_instance_valid(enemy) or enemy.hp < enemy.max_hp
	checks.cube_survives_combat_throw = is_instance_valid(cube) and not cube.freeze and cube.collision_layer == 8

	await _reset()
	await _enable()
	enemy = arena.battle.spawn_enemy(Vector3(16, 0, 12))
	await _frames(3)
	checks.doomed_skeleton_grabbed = hand.grab(enemy)
	enemy.take_damage(999.0)
	await _frames(3)
	checks.held_skeleton_death_clears_hand = hand.held == null and arena.battle.enemies.is_empty()

	await _reset()
	await _enable()
	arena.crew.loot.spawn_coin(Vector3(16, 0.4, 12), Vector3.ZERO)
	var coin: RigidBody3D = arena.crew.loot.loose_coins.back()
	await _frames(4)
	checks.coin_grabbable = hand.grab(coin)
	await _point(Vector3(14, 0, 9), 6)
	checks.coin_not_stolen_by_magnet_while_held = is_instance_valid(coin) and hand.held == coin
	hand.place_gently()
	await _frames(20)
	checks.coin_returns_to_physics = is_instance_valid(coin) and not coin.freeze and coin.collision_layer == 16
