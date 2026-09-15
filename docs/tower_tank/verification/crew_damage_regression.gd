extends Node
## Source parity + real Space input, barrel chains, casualties and cargo lifecycle.
const Geo = preload("res://scripts/geo.gd")
var arena
var crew
var checks := {}

func _ready() -> void:
	arena = get_parent()
	crew = arena.crew
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

func _place(pos: Vector3) -> void:
	crew.anchor = pos
	crew.motion = Vector3.ZERO
	crew.facing = Vector3.FORWARD
	for i in crew.members.size():
		crew.members[i].global_position = pos + crew._slot(i, Vector3.FORWARD)
		crew.members[i].velocity = Vector3.ZERO
		crew.members[i].knockback = Vector3.ZERO

func _fresh(pos: Vector3 = Vector3(12, 0.05, 12)) -> void:
	arena.set_physics_process(false)
	arena.reset_range()
	for target in arena.targets:
		target.collision_layer = 0
		target.queue_free()
	arena.targets.clear()
	for prop in arena.props.props:
		prop.collision_layer = 0
		prop.queue_free()
	arena.props.props.clear()
	crew.crewed = false
	for member in crew.members: member.set_embarked(false)
	_place(pos)
	arena.test_aim = true
	arena.ground_aim_position = pos + Vector3.FORWARD * 9.0
	arena.aim_position = arena.ground_aim_position + Vector3.UP
	arena.focus = pos
	await _frames(3)

func _target(pos: Vector3, barrel: bool = false) -> StaticBody3D:
	arena._spawn_target({"pos": Vector3(pos.x, 0, pos.z), "barrel": barrel, "id": 80 + arena.targets.size()})
	return arena.targets.back()

func _run() -> void:
	await _frames(4)
	await _fresh()
	var center: Vector3 = crew.center()
	var front := _target(center + Vector3(0, 0, -4))
	var back := _target(center + Vector3(0, 0, 4))
	var outside := _target(center + Vector3(-7.5, 0, 0))
	var behind_wall := _target(center + Vector3(4, 0, 0))
	var wall := StaticBody3D.new()
	arena.add_child(wall)
	wall.position = center + Vector3(2.2, 0, 0)
	Geo.collider(wall, Vector3(0.3, 3, 4), Vector3.UP * 1.5)
	var fragile := []
	for i in 3: fragile.append(arena.props.spawn_prop(center + Vector3(-3, -center.y, i - 1), i))
	var protected_prop = arena.props.spawn_prop(center + Vector3(4, -center.y, -1))
	var distant_prop = arena.props.spawn_prop(center + Vector3(-7.5, -center.y, 1))
	await _frames(2)
	arena.set_physics_process(true)
	await _frames(2)
	_key(KEY_SPACE, true)
	await _frames(2)
	_key(KEY_SPACE, false)
	checks.space_hits_front_and_back = front.get_meta("hp") == 44.0 and back.get_meta("hp") == 44.0
	checks.strike_breaks_pots_crates_barrels = fragile.all(func(p): return not is_instance_valid(p) or not arena.props.props.has(p))
	checks.strike_range_and_walls = outside.get_meta("hp") == 100.0 and behind_wall.get_meta("hp") == 100.0 and arena.props.props.has(protected_prop) and arena.props.props.has(distant_prop)
	checks.strike_hitstop_and_cooldown = arena.freeze > 0.0 and crew.combat.spear_cd > 5.8
	await arena._capture(arena.verification_path("crew_damage_01_strike.png"))
	arena.set_physics_process(false)
	wall.queue_free()
	await _frames(2)
	crew.combat.strike()
	checks.cooldown_prevents_repeat = front.get_meta("hp") == 44.0
	crew.members[0].take_damage(1000.0)
	crew.combat.spear_cd = 0.0
	front.set_meta("hp", 100.0)
	crew.combat.strike()
	checks.one_surviving_pike_deals_28 = front.get_meta("hp") == 72.0
	var pike = crew.combat._available("pikeman")[0]
	pike.hauling = true
	crew.combat.spear_cd = 0.0
	crew.combat.strike()
	checks.hauling_pike_cannot_strike = crew.combat.spear_cd == 0.0 and front.get_meta("hp") == 72.0
	pike.take_damage(1000.0)
	crew.combat.strike()
	checks.no_pikes_no_strike = crew.role_count("pikeman") == 0 and crew.combat.spear_cd == 0.0
	var survivor_count: int = crew.members.size()
	pike.take_damage(1000.0)
	checks.death_is_idempotent = crew.members.size() == survivor_count

	# One real barrel blast kills 18 HP archers; robust classes take exactly 25.
	await _fresh()
	center = crew.center()
	var barrel := _target(center + Vector3(2.6, 0, 0), true)
	var chained := _target(center + Vector3(6.6, 0, 0), true)
	var unchained := _target(center + Vector3(12, 0, 0), true)
	checks.barrel_source_health = barrel.get_meta("hp") == 8.0
	var archers: Array = crew.combat._available("archer_squad").duplicate()
	await _frames(2)
	arena._damage_target(barrel, 8.0)
	await _frames(3)
	checks.barrel_kills_archers = crew.members.size() == 6 and archers.all(func(m): return m.dead and m.hp == 0.0 and m.collision_layer == 0 and not m.visible)
	checks.barrel_source_damage = crew.members.all(func(m): return m.hp == m.max_hp - 25.0)
	checks.role_source_health = crew.roster[0].max_hp == 100.0 and crew.roster[2].max_hp == 18.0 and crew.roster[5].max_hp == 120.0 and crew.roster[7].max_hp == 60.0
	await _frames(20)
	checks.chain_blast_reaches_near_barrel_only = not is_instance_valid(chained) and is_instance_valid(unchained) and arena.targets.has(unchained)
	await arena._capture(arena.verification_path("crew_damage_02_casualties.png"))
	var arrows: int = crew.combat.arrows_fired
	crew.input_armed = true
	Input.action_press("tank_fire")
	crew.combat.tick(0.016)
	Input.action_release("tank_fire")
	checks.dead_archers_do_not_shoot = crew.combat.arrows_fired == arrows
	_place(arena.tank.position + Vector3(5, 0, 0))
	await _frames(2)
	var before_hp: float = crew.members[0].hp
	checks.survivors_can_board = crew.board() and crew.members.size() == 6
	arena._explode(arena.tank.position + Vector3.UP, null, true)
	checks.cabin_protects_without_healing = crew.members[0].hp == before_hp and crew.members.size() == 6
	checks.casualties_stay_dead_after_exit = crew.disembark() and crew.members.size() == 6 and archers.all(func(m): return m.dead and not m.visible)
	_place(Vector3(12, 0.05, 12))
	var still_center: Vector3 = crew.center()
	arena.freeze = 0.0
	arena.set_physics_process(true)
	await _frames(90)
	checks.surviving_formation_does_not_drift = Vector2(crew.center().x - still_center.x, crew.center().z - still_center.z).length() < 0.2

	# Spear itself detonates powder barrels, even behind the squad.
	await _fresh()
	center = crew.center()
	barrel = _target(center + Vector3(0, 0, 5.6), true)
	await _frames(2)
	crew.combat.strike()
	checks.spear_detonates_powder_barrel = not arena.targets.has(barrel)
	await _frames(3)

	# Losing a hauler drops a real physics cargo; a dead squad cannot loot/board.
	await _fresh()
	var cargo: RigidBody3D = crew.loot.spawn_cargo(crew.center(), 3)
	await _frames(3)
	checks.cargo_picked_up = crew.loot.pickup_cargo(cargo)
	crew.loot.tick(0.016)
	crew.loot.haulers[0].take_damage(1000.0)
	checks.dead_hauler_drops_cargo = crew.loot.cargo == null and not cargo.freeze and cargo.collision_layer == 8 and crew.members.all(func(m): return not m.hauling)
	var death_center: Vector3 = crew.center()
	for member in crew.members.duplicate(): member.take_damage(1000.0)
	checks.all_dead_cannot_board = crew.members.is_empty() and not crew.can_board() and not crew.board() and not crew.disembark()
	checks.dead_camera_stays_near_squad = crew.center().distance_to(death_center) < 3.0 and crew.center().length() > 5.0
	var coins_before: int = crew.loot.coins
	crew.loot.spawn_coin(crew.center() + Vector3.UP * 0.8, Vector3.ZERO)
	crew.loot.tick(0.016)
	checks.dead_crew_cannot_loot = crew.loot.coins == coins_before and not crew.loot.pickup_cargo(cargo)
	arena.set_physics_process(true)
	_key(KEY_SPACE, true)
	Input.action_press("tank_fire")
	Input.action_press("crew_special")
	await _frames(8)
	_key(KEY_SPACE, false)
	Input.action_release("tank_fire")
	Input.action_release("crew_special")
	checks.dead_crew_cannot_attack = crew.combat.arrows_fired == 0 and crew.combat.spells_fired == 0 and crew.combat.spear_cd == 0.0 and arena.tank.shot_count == 0
	await arena._capture(arena.verification_path("crew_damage_03_defeat.png"))
	_key(KEY_R, true)
	await _frames(2)
	_key(KEY_R, false)
	await _frames(5)
	checks.r_restores_full_crew = crew.crewed and crew.members.size() == 9 and crew.members.all(func(m): return not m.dead and m.hp == m.max_hp and not m.hauling)

	# Old deferred barrel events must never hit a freshly reset range.
	await _fresh()
	barrel = _target(crew.center() + Vector3(2, 0, 0), true)
	arena._damage_target(barrel, 99.0)
	arena.reset_range()
	await _frames(20)
	checks.reset_cancels_pending_blast = arena.kills == 0 and crew.members.size() == 9 and crew.members.all(func(m): return m.hp == m.max_hp)
	await _fresh()
	center = crew.center()
	arena._explode(center + Vector3.UP * 0.6)
	checks.cannon_explosion_hurts_crew = crew.role_count("archer_squad") == 0 and crew.role_count("fire_mage") == 0 and crew.members.size() == 4
	checks.cannon_damage_once = crew.members.all(func(m): return m.hp == m.max_hp - 60.0)
	await _fresh()
	center = crew.center()
	var distant = crew.roster[6]
	distant.position += Vector3(9, 0, 0)
	crew.blast(center, 4.5, 25.0)
	checks.outside_blast_radius_unharmed = distant.hp == 120.0
	crew.blast(center, 4.5, 25.0)
	checks.mages_survive_two_barrels = crew.role_count("fire_mage") == 2 and crew.roster[7].hp == 10.0
	crew.blast(center, 4.5, 25.0)
	checks.third_barrel_kills_mages = crew.role_count("fire_mage") == 0 and crew.role_count("pikeman") == 2
	crew.blast(center, 4.5, 25.0)
	checks.fourth_barrel_kills_pikes = crew.role_count("pikeman") == 0 and crew.roster[5].hp == 20.0
	crew.blast(center, 4.5, 25.0)
	checks.fifth_barrel_kills_worker = crew.members.size() == 1 and crew.members[0] == distant
	var passed := true
	for value in checks.values(): passed = passed and value
	var report := {"passed": passed, "checks": checks}
	var file := FileAccess.open(arena.verification_path("crew_damage_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("CREW_DAMAGE_CHECK: ", JSON.stringify(report))
	get_tree().quit(0 if passed else 1)
