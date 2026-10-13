extends Node
## Mason menu, free placement, transaction boundaries and real tower combat.
const Geo = preload("res://scripts/geo.gd")
var arena
var defense
var site
var checks := {}
var metrics := {}

func _ready() -> void:
	arena = get_parent()
	defense = arena.defenses
	_run.call_deferred()

func _frames(n: int) -> void:
	for i in n: await get_tree().physics_frame

func _click(point: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	arena.hand.test_pointer = point
	for pressed in [true,false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = get_viewport().get_final_transform()*point
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await _frames(2)

func _key(code: Key) -> void:
	for pressed in [true,false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await _frames(1)

func _place_near(pad: Node3D) -> void:
	arena.tank.position = pad.global_position+(Vector3(-4,0.04,-5) if pad==defense.sites[0] else Vector3(6,0.04,3))
	arena.tank.stop_drive()
	arena.tank.walker.reset_pose()
	arena.focus = arena.tank.position
	arena._update_camera(1.0)
	arena.crew.input_armed = true
	await _frames(3)

func _pad_click() -> void:
	var point: Vector2 = arena.aim_camera.unproject_position(site.global_position+Vector3.UP*2.0)
	await _click(point)

func _choose() -> void:
	await _click(defense.choice.get_global_rect().get_center())

func _aim_at(pos: Vector3) -> void:
	pos.y = arena.ground_height(pos)
	arena.hand.test_pointer = arena.aim_camera.unproject_position(pos)
	defense.update_direction(arena.hand.test_pointer)
	defense._draw_sector()
	await _frames(2)

func _enemy(pos: Vector3, shield: bool = false):
	var enemy = arena.battle.spawn_enemy(pos,false,shield)
	enemy.move_speed = 0
	return enemy

func _simulate(tower, seconds: float) -> void:
	for i in ceili(seconds*60):
		tower.tick(1.0/60)
		await _frames(1)

func _workshop_click() -> void:
	await _click(arena.aim_camera.unproject_position(defense.workshop.global_position+Vector3.UP*2.0))

func _position_at(point: Vector3) -> void:
	arena.hand.test_pointer = arena.aim_camera.unproject_position(point)
	defense.update_placement(arena.hand.test_pointer)
	await _frames(2)

func _run() -> void:
	await _frames(8)
	arena.set_physics_process(false)
	arena.level.cancel_spawning()
	arena.level.automatic_encounters = false
	arena.battle.reset()
	arena.test_aim = true
	await _frames(3)
	checks.no_fixed_build_points = defense.sites.is_empty() and arena.level.get_node("AtollC/DefenseSites").get_child_count()==0
	var build_point: Vector3 = arena.level.C+Vector3(-25.5,0,5.5)
	arena.tank.position = arena.level.C+Vector3(-12,0.04,9)
	arena.tank.stop_drive()
	arena.focus = arena.level.C+Vector3(-12,0,-7)
	arena.zoom = 42
	arena._update_camera(1.0)
	arena.crew.input_armed = true
	await _frames(3)
	checks.house_has_workshop_sign = defense.workshop.has_node("WorkshopSign")
	checks.construction_available_across_atoll = defense.reachable(defense.workshop)
	await _workshop_click()
	checks.house_click_opens_menu_in_gun_mode = defense.mode==defense.Mode.MENU and not arena.hand.enabled
	checks.insufficient_crystals_disabled = defense.choice.disabled
	arena.crew.loot.coins = 50
	checks.menu_does_not_fire_cannon = arena.tank.shot_count==0
	arena.crew.loot.crystals = 9
	var crystal = arena.crew.loot.spawn_crystal(arena.tank.position+Vector3.UP)
	checks.accepts_mined_resource = arena.crew.loot.deposit_crystal(crystal)
	for i in 120:
		arena.crew.loot.tick(1.0/60)
		await _frames(1)
	defense.tick(0.016)
	checks.delivery_updates_menu = arena.crew.loot.crystals==10 and not defense.choice.disabled
	arena.crew.loot.coins = 49
	defense.tick(0.016)
	checks.gold_required_even_with_crystals = defense.choice.disabled
	arena.crew.loot.coins = 50
	defense.tick(0.016)
	checks.first_wave_warning_shown = defense.cost_label.text.contains("5")
	await arena._capture(arena.verification_path("mason_01_menu.png"))
	await _choose()
	checks.choice_enters_placement = defense.mode==defense.Mode.PLACE and is_instance_valid(defense.ghost)
	if not checks.choice_enters_placement:
		metrics.failure = "Workshop selection did not enter placement"
		_finish()
		return
	checks.preview_is_free_and_nonphysical = arena.crew.loot.crystals==10 and defense.ghost.collision_layer==0 and defense.sites.is_empty()
	checks.preview_does_not_arm_wave = arena.level.defense_waves.first_wave_left<0
	checks.house_footprint_rejected = not defense.placement.reason(defense.workshop.global_position).is_empty()
	checks.player_footprint_rejected = not defense.placement.reason(arena.tank.position-Vector3.UP*.04).is_empty()
	checks.other_atoll_rejected = not defense.placement.reason(arena.level.A).is_empty()
	checks.mine_entrance_rejected = not defense.placement.reason(arena.level.C+Vector3(20,0,0)).is_empty()
	checks.cliff_footprint_rejected = not defense.placement.reason(arena.level.C+Vector3(27,0,0)).is_empty()
	checks.ramp_exits_rejected = true
	for entrance in arena.level.defense_waves.get_node("Entrances").get_children():
		checks.ramp_exits_rejected = checks.ramp_exits_rejected and not defense.placement.reason(entrance.get_node("Crest").global_position).is_empty()
	await _position_at(defense.workshop.global_position)
	checks.invalid_placement_is_red = not defense.placement_valid and defense.ghost_material.albedo_color.r>0.9
	checks.invalid_click_cannot_confirm = not defense.confirm_position()
	await arena._capture(arena.verification_path("mason_02_invalid.png"))
	await _position_at(build_point)
	checks.free_ground_is_valid = defense.placement_valid
	metrics.placement_reason = defense.placement_reason
	if not defense.placement_valid:
		_finish()
		return
	await arena._capture(arena.verification_path("mason_03_placement.png"))
	await _click(arena.hand.test_pointer,MOUSE_BUTTON_RIGHT)
	checks.cancel_placement_is_free = defense.mode==defense.Mode.IDLE and defense.sites.is_empty() and arena.crew.loot.crystals==10
	checks.cancel_keeps_gold = arena.crew.loot.coins==50
	await _workshop_click()
	await _choose()
	var village_position: Vector3 = arena.tank.position
	arena.tank.position = arena.level.A+Vector3.UP*.04
	defense.tick(.016)
	checks.leaving_atoll_cancels_placement = defense.mode==defense.Mode.IDLE and arena.crew.loot.crystals==10
	arena.tank.position = village_position
	await _workshop_click()
	await _choose()
	await _position_at(build_point)
	await _click(arena.hand.test_pointer)
	checks.position_click_enters_orientation = defense.mode==defense.Mode.AIM and defense.sector.visible
	await _key(KEY_ESCAPE)
	checks.cancel_orientation_does_not_arm_wave = defense.mode==defense.Mode.IDLE and arena.level.defense_waves.first_wave_left<0
	await _workshop_click()
	await _choose()
	await _position_at(build_point)
	await _click(arena.hand.test_pointer)
	await _aim_at(build_point+Vector3.LEFT*12)
	arena.crew.loot.crystals = 9
	await _click(arena.hand.test_pointer)
	checks.currency_rechecked_at_final_click = defense.sites.is_empty() and defense.mode==defense.Mode.IDLE
	arena.crew.loot.crystals = 10
	await _workshop_click()
	await _choose()
	await _position_at(build_point)
	await _click(arena.hand.test_pointer)
	await _aim_at(build_point+Vector3.LEFT*12)
	arena.crew.loot.coins = 49
	await _click(arena.hand.test_pointer)
	checks.gold_rechecked_at_final_click = defense.sites.is_empty() and arena.crew.loot.crystals==10 and arena.crew.loot.coins==49
	arena.crew.loot.coins = 50
	await _workshop_click()
	await _choose()
	await _position_at(build_point)
	await _click(arena.hand.test_pointer)
	await _aim_at(build_point+Vector3.LEFT*12)
	# An actor entering the footprint between the two confirmations blocks construction.
	var blocker = _enemy(build_point)
	await _frames(3)
	checks.final_click_rechecks_occupancy = not defense.confirm() and defense.sites.is_empty()
	blocker.collision_layer = 0
	arena.battle.enemies.erase(blocker)
	blocker.queue_free()
	await _frames(3)
	await _position_at(build_point)
	await _click(arena.hand.test_pointer)
	await _aim_at(build_point+Vector3.LEFT*12)
	site = defense.selected
	await arena._capture(arena.verification_path("mason_04_direction.png"))
	await _click(arena.hand.test_pointer)
	checks.confirm_spends_once_and_constructs = defense.sites.size()==1 and is_instance_valid(site.tower) and arena.crew.loot.crystals==0
	checks.confirm_spends_exact_gold = arena.crew.loot.coins==0
	checks.first_build_arms_countdown = arena.level.defense_waves.first_wave_left==5.0
	checks.second_confirm_rejected = not defense.confirm()
	var tower = site.tower
	if not is_instance_valid(tower): _finish(); return
	checks.occupied_tower_position_rejected = not defense.placement.reason(build_point).is_empty()
	await _pad_click()
	checks.built_click_offers_rotation = defense.mode==defense.Mode.MENU and defense.reorienting
	await _choose()
	await _aim_at(site.global_position+Vector3.FORWARD*12)
	var desired: float = defense.heading
	await _click(arena.hand.test_pointer)
	checks.rotation_is_free_and_applied = absf(angle_difference(tower.global_rotation.y,desired))<0.02 and arena.crew.loot.crystals==0
	checks.rotation_preserves_wave_timer = arena.level.defense_waves.first_wave_left==5.0
	checks.rotation_costs_no_gold = arena.crew.loot.coins==0
	tower.change_heading(PI/2)
	var front = _enemy(site.global_position+Vector3.LEFT*12)
	front.hp = 1000
	front.max_hp = 1000
	var rear = _enemy(site.global_position+Vector3.RIGHT*12)
	var far_enemy = _enemy(site.global_position+Vector3.LEFT*32)
	await _frames(3)
	checks.front_inside_rear_and_far_outside = tower.in_sector(front) and not tower.in_sector(rear) and not tower.in_sector(far_enemy)
	front.hand_held = true
	checks.carried_skeleton_ignored = not tower.in_sector(front)
	front.hand_held = false
	front.hand_thrown = true
	checks.thrown_skeleton_ignored = not tower.in_sector(front)
	front.hand_thrown = false
	checks.clear_line_of_sight = tower.has_sight(front)
	var fired_at := []
	var previous := 0
	for frame in 240:
		tower.tick(1.0/60)
		if tower.shots_fired!=previous:
			fired_at.append(frame)
			previous = tower.shots_fired
		await _frames(1)
	metrics.shot_frames = fired_at
	metrics.damage_after_two_bursts = 1000-front.hp
	checks.five_shot_bursts_and_longer_pause = fired_at.size()==10 and fired_at[4]-fired_at[0]<=32 and fired_at[5]-fired_at[4]>=107
	checks.real_bolts_damage_enemy = front.hp==920
	checks.rear_enemy_untouched = rear.hp==rear.max_hp
	await arena._capture(arena.verification_path("defense_03_built.png"))
	# Opaque collision blocks acquisition and also catches an already fired bolt.
	var wall := StaticBody3D.new()
	arena.add_child(wall)
	wall.position = site.global_position+Vector3.LEFT*6
	Geo.collider(wall,Vector3(0.6,8,4),Vector3.UP*2)
	Geo.box(wall,Vector3(0.6,8,4),Vector3.UP*2,Geo.material(Color("8c9286")))
	await _frames(3)
	checks.wall_blocks_sight = not tower.has_sight(front)
	var old_shots: int = tower.shots_fired
	await _simulate(tower,2.5)
	checks.no_shots_through_wall = tower.shots_fired==old_shots
	tower.target = front
	tower._fire() # Force one in-flight bolt to verify collision, independently of targeting.
	var old_hp: float = front.hp
	await _simulate(tower,0.7)
	checks.bolt_collision_stops_at_wall = front.hp==old_hp and tower.bolts.is_empty()
	wall.queue_free()
	arena.battle.reset()
	await _frames(3)
	front = _enemy(site.global_position+Vector3.LEFT*9)
	front.hp = 13
	await _frames(2)
	tower.reload_left = 0
	tower.burst_left = 0
	await _simulate(tower,1)
	checks.ordinary_dies_from_burst = not is_instance_valid(front) or front.dead
	front = _enemy(site.global_position+Vector3.LEFT*9,true)
	front.hp = 13
	front.shield_hp = 24
	await _frames(2)
	tower.reload_left = 0
	tower.burst_left = 0
	await _simulate(tower,1.1)
	checks.shield_guard_dies_after_shield_break = not is_instance_valid(front) or front.dead
	arena.battle.reset()
	await _frames(3)
	front = _enemy(site.global_position+Vector3.LEFT*9)
	front.hp = 1000
	await _frames(2)
	old_shots = tower.shots_fired
	arena.hand.set_enabled(false)
	tower.reload_left = 0
	tower.burst_left = 0
	for i in 65:
		defense.tick(1.0/60)
		await _frames(1)
	checks.auto_defense_works_outside_hand_mode = tower.shots_fired>old_shots and front.hp<1000
	arena.crew.crewed = false
	old_shots = tower.shots_fired
	tower.reload_left = 0
	tower.burst_left = 0
	for i in 65:
		defense.tick(1.0/60)
		await _frames(1)
	checks.auto_defense_works_with_crew_outside = tower.shots_fired>old_shots
	arena.crew.crewed = true
	arena.hand.set_enabled(false)
	arena.crew.input_armed = true
	arena.crew.loot.crystals = 40
	arena.crew.loot.coins = 200
	arena.battle.reset()
	await _frames(3)
	for i in 3:
		var point := Vector3.INF
		for x in range(-20,15,4):
			for z in range(-20,23,4):
				var candidate: Vector3 = arena.level.C+Vector3(x,0,z)
				if defense.placement.reason(candidate).is_empty():
					point = candidate
					break
			if point.is_finite(): break
		defense.open_menu(defense.workshop,Vector2(300,300))
		defense.begin_orientation()
		await _position_at(point)
		var placed: bool = defense.confirm_position()
		await _aim_at(point+Vector3.LEFT*12)
		checks["additional_free_build_%d"%i] = placed and defense.confirm()
		await _frames(3)
	checks.more_than_three_towers_allowed = defense.sites.size()==4 and arena.crew.loot.crystals==10
	checks.multiple_builds_spend_gold_once = arena.crew.loot.coins==50
	arena.focus = arena.level.C+Vector3(-9,0,0)
	arena.zoom = 42
	arena._update_camera(1.0)
	await arena._capture(arena.verification_path("mason_05_village.png"))
	# Measure only the new controller's CPU cost with a dense 600-enemy fixture.
	# This is not a whole-game FPS benchmark; enemies stay fixed for repeatability.
	arena.battle.reset()
	for i in 600:
		var enemy = _enemy(arena.level.C+Vector3(-46+(i%20)*0.9,-arena.level.C.y,-26+floori(i/20.0)*1.7))
		enemy.hp = 10000
	await _frames(3)
	var cpu_total := 0
	var cpu_max := 0
	var shots_before: int = defense.sites.reduce(func(n,p): return n+p.tower.shots_fired,0)
	for i in 180:
		var stamp := Time.get_ticks_usec()
		defense.tick(1.0/60)
		var cost := Time.get_ticks_usec()-stamp
		cpu_total += cost
		cpu_max = maxi(cpu_max,cost)
		await _frames(1)
	metrics.defense_tick_mean_ms_600 = cpu_total/180000.0
	metrics.defense_tick_max_ms_600 = cpu_max/1000.0
	metrics.live_bolts_600 = defense.sites.reduce(func(n,p): return n+p.tower.bolts.size(),0)
	checks.reacquires_after_target_is_freed = defense.sites.reduce(func(n,p): return n+p.tower.shots_fired,0)>shots_before
	checks.projectiles_remain_bounded = metrics.live_bolts_600<=20
	defense.open_menu(defense.workshop,Vector2(300,300))
	defense.begin_orientation()
	checks.reset_fixture_has_pending_preview = defense.mode==defense.Mode.PLACE and is_instance_valid(defense.ghost)
	arena.reset_range()
	arena.level.cancel_spawning()
	arena.battle.reset()
	await _frames(4)
	checks.reset_removes_free_buildings_and_currency = defense.sites.is_empty() and arena.crew.loot.crystals==0
	checks.reset_removes_bolts_and_preview = arena.find_children("DefenseBolt*","MeshInstance3D",false,false).is_empty() and defense.mode==defense.Mode.IDLE and not is_instance_valid(defense.ghost)
	_finish()

func _finish() -> void:
	var passed: bool = checks.values().all(func(v): return v)
	var report := {"passed":passed,"checks":checks,"metrics":metrics}
	var file := FileAccess.open(arena.verification_path("defense_check.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	print("DEFENSE_CHECK: ",JSON.stringify(report))
	get_tree().quit(0 if passed else 1)
