extends Node
const Geo = preload("res://scripts/geo.gd")
var arena
var battle
var crew
var checks := {}

func _ready() -> void:
	arena = get_parent()
	battle = arena.battle
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

func _mouse(button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = Vector2(800, 440)
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _place_crew(pos: Vector3) -> void:
	crew.anchor = pos
	crew.motion = Vector3.ZERO
	crew.facing = Vector3.FORWARD
	for i in crew.members.size():
		crew.members[i].position = pos + crew._slot(i, Vector3.FORWARD)
		crew.members[i].velocity = Vector3.ZERO
		crew.members[i].knockback = Vector3.ZERO

func _fresh(outside: bool = false) -> void:
	arena.set_physics_process(false)
	for action in ["tank_fire", "crew_special", "crew_strike", "tank_forward"]: Input.action_release(action)
	battle.waves_enabled = false
	arena.reset_range()
	for target in arena.targets:
		target.collision_layer = 0
		target.queue_free()
	arena.targets.clear()
	for prop in arena.props.props:
		prop.collision_layer = 0
		prop.queue_free()
	arena.props.props.clear()
	arena.test_aim = true
	arena.aim_position = Vector3(0, 1, -8)
	if outside:
		crew.crewed = false
		for member in crew.members: member.set_embarked(false)
		_place_crew(Vector3(10, 0.05, 9))
		arena.focus = crew.center()
	await _frames(3)
	battle._rebuild_navigation()
	arena.set_physics_process(true)
	await _frames(3)

func _stationary(pos: Vector3, hp: float = 30.0) -> CharacterBody3D:
	var enemy: CharacterBody3D = battle.spawn_enemy(pos)
	enemy.move_speed = 0.0
	enemy.hp = hp
	enemy.max_hp = hp
	return enemy

func _run() -> void:
	await _frames(5)
	await _fresh()
	battle.waves_enabled = true
	battle.next_wave = 0.0
	await _frames(5)
	checks.first_wave_has_12_skeletons = battle.wave == 1 and battle.enemies.size() == 12
	checks.original_stat_ranges = battle.enemies.all(func(e): return e.hp >= 24.0 and e.hp <= 36.0 and e.move_speed >= 1.7 and e.move_speed <= 2.3 and e.attack_damage >= 6.4 and e.attack_damage <= 9.6 and e.attack_windup >= 0.32 and e.attack_windup <= 0.48)
	checks.spawns_safe = battle.enemies.all(func(e): return e.position.distance_to(arena.tank.position) > 9.0 and absf(e.position.x) < 28.0 and absf(e.position.z) < 28.0)
	var approacher = battle.enemies[0]
	var distance_before: float = approacher.position.distance_to(arena.tank.position)
	await _frames(100)
	checks.ai_approaches_tower = approacher.position.distance_to(arena.tank.position) < distance_before - 1.5
	checks.ai_targets_occupied_tower = battle.enemies.all(func(e): return e.target == arena.tank)
	await arena._capture(arena.verification_path("battle_01_wave.png"))
	_key(KEY_N, true)
	_key(KEY_N, false)
	await _frames(3)
	checks.n_cannot_stack_waves = battle.wave == 1 and battle.enemies.size() == 12
	for enemy in battle.enemies.duplicate(): enemy.take_damage(100.0, Vector3.FORWARD)
	await _frames(3)
	checks.wave_clear_counts_and_coins = battle.kills == 12 and battle.enemies.is_empty() and battle.next_wave > 7.0 and crew.loot.loose_coins.size() >= 12
	_key(KEY_N, true)
	_key(KEY_N, false)
	await _frames(3)
	checks.n_starts_next_wave = battle.wave == 2 and battle.enemies.size() == 16

	await _fresh()
	var melee = battle.spawn_enemy(Vector3(0, 0, 2.4))
	await _frames(3)
	checks.visible_windup_before_damage = melee.state == melee.State.WINDUP and melee.warning.visible and arena.tank.hp == 1000.0
	await _frames(35)
	checks.lunge_damages_hull_once = melee.attacks == 1 and melee.hits == 1 and arena.tank.hp < 1000.0 and arena.tank.hp >= 990.4
	checks.melee_never_hurts_hidden_crew = crew.members.size() == 9 and crew.members.all(func(m): return m.hp == m.max_hp)
	var attacks: int = melee.attacks
	await _frames(16)
	checks.attack_has_recovery = melee.attacks == attacks
	await _frames(90)
	checks.enemy_repeats_attacks = melee.attacks > attacks and arena.tank.hp < 986.0
	melee.state = melee.State.WINDUP
	melee.timer = 0.3
	attacks = melee.attacks
	melee.take_damage(1.0, Vector3.FORWARD, 11.0)
	checks.knockback_interrupts_windup = melee.state == melee.State.STAGGER and not melee.warning.visible
	await _frames(10)
	checks.interrupted_attack_does_not_land = melee.attacks == attacks

	await _fresh(true)
	var center: Vector3 = crew.center()
	melee = battle.spawn_enemy(center + Vector3(0, 0, -2.7))
	await _frames(3)
	checks.disembarked_crew_becomes_target = crew.members.has(melee.target)
	var victim = crew.combat._available("archer_squad")[0]
	victim.hp = 1.0
	melee.position = victim.position + Vector3.FORWARD * 1.0
	melee.target = victim
	melee._strike(Vector3.BACK)
	checks.melee_kills_gnome = victim.dead and crew.members.size() < 9
	await arena._capture(arena.verification_path("battle_02_melee.png"))
	# Dodge during windup: moving beyond the strike radius makes it miss.
	melee.state = melee.State.WINDUP
	melee.timer = 0.20
	_place_crew(Vector3(18, 0.05, 18))
	var hp_before := []
	for member in crew.members: hp_before.append(member.hp)
	await _frames(18)
	checks.dodge_avoids_melee_damage = true
	for i in crew.members.size(): checks.dodge_avoids_melee_damage = checks.dodge_avoids_melee_damage and crew.members[i].hp == hp_before[i]
	_place_crew(arena.tank.position + Vector3(5, 0, 0))
	await _frames(3)
	checks.board_during_battle = crew.board()
	await _frames(28)
	checks.boarding_retargets_enemy = melee.target == arena.tank and crew.members.all(func(m): return m.embarked)

	# A shared navigation grid routes bodies around a real blocking wall.
	await _fresh()
	var wall := StaticBody3D.new()
	arena.add_child(wall)
	wall.position = Vector3(0, 0, -1)
	Geo.collider(wall, Vector3(6, 3, 0.5), Vector3.UP * 1.5)
	melee = battle.spawn_enemy(Vector3(0, 0, -5))
	await _frames(3)
	battle.nav_dirty = true
	var max_side := 0.0
	for i in 460:
		await _frames(1)
		max_side = maxf(max_side, absf(melee.position.x))
	checks.navigates_around_wall = max_side > 3.0 and melee.position.z > 0.0
	wall.queue_free()

	# Real projectile paths, not direct damage shortcuts.
	await _fresh()
	var enemy = _stationary(Vector3(0, 0, -8))
	await _frames(70)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(2)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(35)
	checks.cannon_projectile_kills_skeleton = not is_instance_valid(enemy) and battle.kills == 1 and arena.tank.shot_count == 1
	await _fresh()
	enemy = _stationary(Vector3(0, 0, -8))
	await _frames(70)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(55)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	checks.crossbow_bolts_kill_skeleton = not is_instance_valid(enemy) and battle.kills == 1 and arena.tank.crossbows.hit_count >= 4
	await arena._capture(arena.verification_path("battle_03_crossbows.png"))
	await _fresh(true)
	center = crew.center()
	enemy = _stationary(center + Vector3.FORWARD * 7.0)
	arena.aim_position = enemy.position + Vector3.UP
	await _frames(60)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(100)
	_mouse(MOUSE_BUTTON_LEFT, false)
	checks.archer_arrows_kill_skeleton = not is_instance_valid(enemy) and crew.combat.arrows_fired >= 3 and battle.kills == 1
	await _fresh(true)
	center = crew.center()
	_stationary(center + Vector3.FORWARD * 4.0)
	_stationary(center + Vector3.BACK * 4.0)
	await _frames(3)
	_key(KEY_SPACE, true)
	await _frames(2)
	_key(KEY_SPACE, false)
	checks.spears_kill_front_and_back = battle.enemies.is_empty() and battle.kills == 2
	await arena._capture(arena.verification_path("battle_04_spears.png"))
	await _fresh(true)
	center = crew.center()
	enemy = _stationary(center + Vector3.FORWARD * 7.0, 120.0)
	for mage in crew.combat._available("fire_mage"): mage.hauling = true
	arena.aim_position = enemy.position + Vector3.UP
	await _frames(50)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(3)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _frames(40)
	checks.worker_wave_hits_skeleton = is_instance_valid(enemy) and is_equal_approx(enemy.hp, 30.0)
	await _fresh(true)
	center = crew.center()
	enemy = _stationary(center + Vector3.FORWARD * 7.0)
	for worker in crew.combat._available("worker"): worker.hauling = true
	arena.aim_position = enemy.position + Vector3.UP
	await _frames(50)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(3)
	_mouse(MOUSE_BUTTON_RIGHT, false)
	await _frames(80)
	checks.mage_fire_kills_skeleton = not is_instance_valid(enemy) and crew.combat.spells_fired == 2
	await _fresh()
	enemy = _stationary(Vector3(10, 0, 10), 100.0)
	crew.combat.burns.append({"pos": enemy.position, "life": 3.0, "tick": 0.01})
	await _frames(3)
	checks.fire_patch_damages_skeleton = is_equal_approx(enemy.hp, 96.0)
	arena._spawn_target({"pos": Vector3(12, 0, 10), "barrel": true, "id": 98})
	arena._damage_target(arena.targets.back(), 8.0)
	await _frames(5)
	checks.barrel_explosion_kills_skeleton = not is_instance_valid(enemy) and battle.kills == 1

	await _fresh()
	enemy = _stationary(Vector3(0, 0, 1.8))
	_key(KEY_SPACE, true)
	await _frames(2)
	_key(KEY_SPACE, false)
	await _frames(25)
	checks.dash_rams_skeleton = not is_instance_valid(enemy) and battle.kills == 1 and arena.tank.dash.normal_count == 1 and arena.tank.position.z < 1.0
	await _fresh()
	var direction: Vector3 = -arena.aim_camera.global_basis.z
	direction.y = 0.0
	direction = direction.normalized()
	enemy = _stationary(arena.tank.position + direction * 2.8)
	Input.action_press("tank_forward")
	await _frames(28)
	Input.action_release("tank_forward")
	checks.walking_tower_pushes_skeleton = not is_instance_valid(enemy) or enemy.hp < 30.0

	await _fresh()
	arena.tank.hp = 1.0
	melee = battle.spawn_enemy(arena.tank.position + Vector3.FORWARD * 2.5)
	await _frames(45)
	checks.hull_can_be_destroyed = arena.tank.dead and arena.tank.hp == 0.0
	checks.crew_evacuates_wreck_alive = not crew.crewed and crew.members.size() == 9 and crew.members.all(func(m): return not m.embarked and not m.dead)
	checks.cannot_board_destroyed_hull = not crew.can_board() and not crew.board()
	var shots: int = arena.tank.shot_count
	arena.tank.fire()
	arena.tank.crossbows.trigger(true)
	arena.tank.dash.space(true)
	await _frames(4)
	checks.wreck_cannot_fire_or_dash = arena.tank.shot_count == shots and not arena.tank.crossbows.trigger_held and not arena.tank.dash.active
	await arena._capture(arena.verification_path("battle_05_wreck.png"))
	_place_crew(arena.tank.position + Vector3(0, 0, -6))
	melee.position = arena.tank.position + Vector3(0, 0, 5)
	melee.state = melee.State.APPROACH
	melee.path_left = 0.0
	max_side = 0.0
	for i in 420:
		await _frames(1)
		max_side = maxf(max_side, absf(melee.position.x - arena.tank.position.x))
	checks.enemy_routes_around_wreck = max_side > 1.5 and melee.position.z < arena.tank.position.z
	for member in crew.members.duplicate(): member.take_damage(1000.0)
	attacks = melee.attacks
	await _frames(100)
	checks.all_dead_stops_enemy_attacks = melee.attacks == attacks and battle.player_targets().is_empty()
	_key(KEY_R, true)
	await _frames(3)
	_key(KEY_R, false)
	await _frames(5)
	checks.reset_restores_battle_and_crew = arena.tank.hp == 1000.0 and not arena.tank.dead and crew.members.size() == 9 and crew.crewed and battle.enemies.is_empty() and battle.kills == 0 and battle.wave == 0
	# Empty-field timer starts another wave without pressing N.
	battle.waves_enabled = true
	battle.wave = 2
	battle.next_wave = 0.04
	await _frames(6)
	checks.automatic_next_wave = battle.wave == 3 and battle.enemies.size() == 20
	# Sustained battle on the real prop/target-filled range, not the empty fixtures.
	var physics_ms := 0.0
	for i in 1000:
		await _frames(1)
		physics_ms += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	checks.full_range_enemies_reach_combat = battle.enemies.any(func(e): return e.attacks > 0)
	checks.full_range_hull_takes_damage = arena.tank.hp < 1000.0
	checks.full_range_bodies_stay_on_field = battle.enemies.all(func(e): return absf(e.position.x) < 28.5 and absf(e.position.z) < 28.5 and e.position.y > -0.2)
	await arena._capture(arena.verification_path("battle_06_full_range.png"))
	var passed := true
	for value in checks.values(): passed = passed and value
	var report := {"passed": passed, "checks": checks, "metrics": {"average_full_range_physics_ms": physics_ms / 1000.0}}
	var file := FileAccess.open(arena.verification_path("battle_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("BATTLE_CHECK: ", JSON.stringify(report))
	get_tree().quit(0 if passed else 1)
