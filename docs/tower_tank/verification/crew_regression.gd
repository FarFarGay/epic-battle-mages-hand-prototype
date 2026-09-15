extends Node
## Real physics/input checks for the cabin -> squad -> loot -> cabin loop.
const Geo = preload("res://scripts/geo.gd")
var arena
var crew
var results := {}

func _ready() -> void:
	arena = get_parent()
	crew = arena.crew
	_run.call_deferred()

func _frames(count: int) -> void:
	for i in count: await get_tree().physics_frame

func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await _frames(2)
	event = InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = false
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	# Commands remain queued during impact hitstop. Wait for their consumption,
	# not just the next two frames (release rendering can reach this earlier).
	var waited := 0
	while (crew.interact_requested or crew.drop_requested or arena._reset_requested or arena.freeze > 0.0) and waited < 24:
		await _frames(1)
		waited += 1
	await _frames(2)

func _place(pos: Vector3) -> void:
	crew.motion = Vector3.ZERO
	crew.anchor = Vector3(pos.x, 0, pos.z)
	crew.facing = Vector3.FORWARD
	for i in crew.members.size():
		crew.members[i].global_position = pos + crew._slot(i, Vector3.FORWARD)
		crew.members[i].velocity = Vector3.ZERO
	await _frames(3)

func _run() -> void:
	await _frames(5)
	arena.test_aim = true
	arena.aim_position = Vector3(0, 1.4, -8)
	var identities := []
	for member in crew.members: identities.append(member.get_instance_id())
	results.starts_in_cabin = crew.crewed and crew.members.size() == 9 and crew.members.all(func(m): return not m.visible and m.collision_layer == 0)
	await _key(KEY_E)
	await _frames(15)
	results.e_disembarks_on_ground = not crew.crewed and crew.members.all(func(m): return m.visible and m.collision_layer == 4 and m.position.y < 0.15 and m.position.y > -0.05)
	await arena._capture(arena.verification_path("crew_01_disembarked.png"))
	var tower_pos: Vector3 = arena.tank.position
	var tower_yaw: float = arena.tank.rotation.y
	var squad_start: Vector3 = crew.center()
	Input.action_press("tank_right")
	Input.action_press("tank_fire")
	await _frames(80)
	Input.action_release("tank_right")
	Input.action_release("tank_fire")
	await _frames(22)
	var displacement: Vector3 = crew.center() - squad_start
	results.camera_relative_wasd = displacement.dot(arena.aim_camera.global_basis.x) > 5.0
	results.parked_tower_inert = arena.tank.position.distance_to(tower_pos) < 0.08 and absf(arena.tank.rotation.y - tower_yaw) < 0.001 and arena.tank.shot_count == 0
	results.outside_lmb_only_archers = crew.combat.arrows_fired >= 3 and arena.tank.shot_count == 0
	results.camera_follows_squad = arena.focus.distance_to(crew.center()) < 4.0
	results.cannot_board_remotely = not crew.board() and not crew.crewed
	# A wall between crew and tank must prevent boarding and cargo collection.
	await _place(Vector3(6, 0.05, 5))
	var wall := StaticBody3D.new()
	arena.add_child(wall)
	wall.position = Vector3(3, 0, 5)
	Geo.collider(wall, Vector3(0.4, 3, 9), Vector3.UP * 1.5)
	await _frames(2)
	results.wall_blocks_boarding = not crew.can_board() and not crew.board()
	wall.queue_free()
	await _frames(2)
	# Shared cargo selection is exercised through the real E event.
	var cargo: RigidBody3D = crew.loot.spawn_cargo(crew.center(), 3)
	await _frames(4)
	await _key(KEY_E)
	results.e_picks_heavy_cargo = crew.loot.cargo == cargo and crew.loot.haulers.size() == 3 and cargo.freeze
	var old: Vector3 = cargo.position
	Input.action_press("tank_reverse")
	await _frames(20)
	Input.action_release("tank_reverse")
	await _frames(10)
	results.cargo_follows_haulers = cargo.position.distance_to(old) > 0.6 and absf(cargo.position.y - 1.5) < 0.02
	results.tower_stays_parked_while_hauling = arena.tank.position.distance_to(tower_pos) < 0.08
	await arena._capture(arena.verification_path("crew_04_cargo.png"))
	var free_archers: int = crew.combat._available("archer_squad").size()
	for member in crew.members: member.shot_cooldown = 0.0
	var before_arrows: int = crew.combat.arrows_fired
	Input.action_press("tank_fire")
	await _frames(3)
	Input.action_release("tank_fire")
	results.haulers_do_not_fire = crew.combat.arrows_fired - before_arrows == free_archers
	await _key(KEY_Q)
	results.drop_restores_physics = crew.loot.cargo == null and not cargo.freeze and cargo.collision_layer == 8 and crew.members.all(func(m): return not m.hauling)
	if not results.drop_restores_physics:
		print("DROP_STATE: cargo=", crew.loot.cargo, " frozen=", cargo.freeze, " layer=", cargo.collision_layer, " queued=", crew.drop_requested, " freeze=", arena.freeze)
	await _place(Vector3(6, 0.05, 5))
	cargo.freeze = true
	cargo.position = crew.center() + Vector3.UP * 0.4
	await _frames(2)
	results.repickup = crew.loot.pickup_cargo(cargo)
	crew.loot.spawn_coin(crew.center() + Vector3.UP * 0.75, Vector3.ZERO)
	await _frames(12)
	var saved_coins: int = crew.loot.coins
	var supplies_before: int = crew.loot.supplies
	# Direct boarding is the UI button path, independent of nearby E items.
	crew.board_requested = true
	Input.action_press("tank_fire")
	await _frames(6)
	results.boarding_deposits_cargo_once = crew.crewed and crew.loot.supplies == supplies_before + 3 and crew.loot.cargo == null
	results.held_fire_does_not_leak = arena.tank.shot_count == 0
	Input.action_release("tank_fire")
	await _frames(2)
	results.coins_survive_boarding = saved_coins > 0 and crew.loot.coins == saved_coins
	results.same_crew_no_duplicates = crew.members.size() == 9
	for i in crew.members.size():
		results.same_crew_no_duplicates = results.same_crew_no_duplicates and crew.members[i].get_instance_id() == identities[i]
	results.embarked_collisions_disabled = crew.members.all(func(m): return not m.visible and m.collision_layer == 0 and m.collision_mask == 0)
	var drive_start: Vector3 = arena.tank.position
	var forward: Vector3 = -arena.aim_camera.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	Input.action_press("tank_forward")
	await _frames(22)
	Input.action_release("tank_forward")
	results.tower_controls_return = (arena.tank.position - drive_start).dot(forward) > 0.5
	Input.action_press("tank_fire")
	await _frames(2)
	Input.action_release("tank_fire")
	results.cannon_returns_after_release = arena.tank.shot_count == 1
	await _frames(15)
	await _key(KEY_E)
	await _place(Vector3(10, 0.05, 6))
	var chest: Dictionary = crew.loot.chests[0]
	var before_coins: int = crew.loot.coins
	await _key(KEY_E)
	await _frames(120)
	results.e_opens_chest = chest.opened
	results.physical_coins_collected = crew.loot.coins > before_coins
	# Archers and both ability buttons damage real range targets.
	arena.reset_range()
	await _frames(4)
	await _key(KEY_E)
	await _place(Vector3(0, 0.05, -2))
	arena.aim_position = Vector3(0, 1.3, -8)
	await _frames(40)
	var target: StaticBody3D = arena.targets[0]
	Input.action_press("tank_fire")
	await _frames(65)
	Input.action_release("tank_fire")
	results.archer_projectiles_damage = not is_instance_valid(target) or float(target.get_meta("hp")) < 100.0
	await _place(Vector3(12, 0.05, 3))
	arena.aim_position = Vector3(12, 1.0, -1)
	await _frames(35)
	var spear_target: StaticBody3D = null
	for t in arena.targets:
		if t.position.distance_to(Vector3(12, 0, -1)) < 0.1: spear_target = t
	await _key(KEY_SPACE)
	results.space_spear_damage = crew.combat.spear_cd > 5.0 and (not is_instance_valid(spear_target) or float(spear_target.get_meta("hp")) < 100.0)
	Input.action_press("crew_special")
	await _frames(2)
	Input.action_release("crew_special")
	results.rmb_both_specialists = crew.combat.wave_cd > 13.0 and crew.combat.mage_cd > 4.0 and crew.combat.spells_fired == 2
	await arena._capture(arena.verification_path("crew_02_combat.png"))
	var previous_cd: float = crew.combat.mage_cd
	await _place(arena.tank.position + Vector3(6, 0.05, 0))
	crew.board()
	await _frames(35)
	results.abilities_continue_in_cabin = crew.crewed and crew.combat.mage_cd < previous_cd - 0.3
	# Corners used to be a common source of dwarves spawning in walls.
	arena.tank.position = Vector3(26, 0.03, 26)
	await _frames(2)
	results.corner_disembark = crew.disembark()
	await _frames(8)
	results.corner_positions_valid = crew.members.all(func(m): return absf(m.position.x) < 28.0 and absf(m.position.z) < 28.0 and m.position.y > -0.05)
	await _key(KEY_R)
	await _frames(4)
	results.reset_clears_crew_world = crew.crewed and crew.members.size() == 9 and crew.loot.coins == 0 and crew.loot.supplies == 0 and crew.loot.items.size() == 3 and crew.combat.bolts.is_empty() and crew.loot.cargo == null
	await _key(KEY_E)
	arena.aim_position = Vector3(0, 1.0, -8)
	await _frames(40)
	await arena._capture(arena.verification_path("crew_03_overview.png"))
	var all_ok := true
	for value in results.values(): all_ok = all_ok and value
	var report := {"passed": all_ok, "checks": results}
	var file := FileAccess.open(arena.verification_path("crew_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("CREW_CHECK: ", JSON.stringify(report))
	get_tree().quit(0 if all_ok else 1)
