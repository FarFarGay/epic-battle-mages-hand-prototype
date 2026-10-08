extends Node
## Real authored pads, input dispatch, shared crystals and swept-bolt collision.
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
	var point: Vector2 = arena.aim_camera.unproject_position(site.global_position+Vector3.UP*0.2)
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

func _run() -> void:
	await _frames(8)
	arena.level.cancel_spawning()
	arena.level.automatic_encounters = false
	arena.battle.reset()
	arena.test_aim = true
	checks.three_authored_sites = defense.sites.size()==3
	checks.editable_prefabs = defense.sites.all(func(s): return s.scene_file_path=="res://scenes/defense_site.tscn" and s.crystal_cost==10)
	site = defense.sites[1]
	var pads_clear := true
	var ground := []
	for pad in defense.sites:
		ground.append([pad.global_position,arena.ground_height(pad.global_position)])
		pads_clear = pads_clear and absf(arena.ground_height(pad.global_position)-pad.global_position.y)<0.1
		var q := PhysicsShapeQueryParameters3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = 0.92
		shape.height = 3.4
		q.shape = shape
		q.transform.origin = pad.global_position+Vector3.UP*1.8
		q.collision_mask = 1|8|32
		pads_clear = pads_clear and arena.get_world_3d().direct_space_state.intersect_shape(q).is_empty()
	checks.pads_on_mesa_and_clear_of_houses = pads_clear
	metrics.site_ground = ground
	await _place_near(site)
	arena.set_physics_process(false)
	# Input is still dispatched; game simulation is advanced explicitly below.
	await _pad_click()
	checks.gun_mode_cannot_build = defense.mode==defense.Mode.IDLE
	arena.hand.set_enabled(true)
	arena.crew.input_armed = true
	await _pad_click()
	checks.hand_click_opens_dropdown = defense.mode==defense.Mode.MENU
	checks.insufficient_crystals_disabled = defense.choice.disabled and arena.crew.loot.crystals==0
	await _choose()
	checks.disabled_choice_does_not_build = defense.mode==defense.Mode.MENU and not is_instance_valid(site.tower)
	defense.cancel()
	arena.crew.crewed = false
	await _pad_click()
	checks.on_foot_cannot_build = defense.mode==defense.Mode.IDLE
	arena.crew.crewed = true
	await _pad_click()
	# A real mining resource delivery enables the last missing crystal.
	arena.crew.loot.crystals = 9
	var crystal = arena.crew.loot.spawn_crystal(arena.tank.position+Vector3.UP)
	checks.accepts_mined_resource = arena.crew.loot.deposit_crystal(crystal)
	for i in 120:
		arena.crew.loot.tick(1.0/60)
		await _frames(1)
	defense.tick(0.016)
	checks.delivery_updates_menu = arena.crew.loot.crystals==10 and not defense.choice.disabled
	await arena._capture(arena.verification_path("defense_01_menu.png"))
	await _choose()
	checks.choice_enters_direction_stage = defense.mode==defense.Mode.AIM and is_instance_valid(defense.ghost) and defense.sector.visible
	if not checks.choice_enters_direction_stage:
		metrics.menu_debug = {"mode":defense.mode,"rect":defense.menu.get_global_rect(),"button":defense.choice.get_global_rect(),"viewport":get_viewport().get_visible_rect(),"reachable":defense.reachable(site),"context":defense._context_valid(),"disabled":defense.choice.disabled}
		_finish()
		return
	checks.preview_is_free_and_nonphysical = arena.crew.loot.crystals==10 and defense.ghost.collision_layer==0
	await _aim_at(site.global_position+Vector3.LEFT*12)
	checks.pointer_sets_world_heading = defense.direction_valid and absf(angle_difference(defense.heading,PI/2))<0.02
	metrics.first_heading = defense.heading
	await arena._capture(arena.verification_path("defense_02_direction.png"))
	await _click(arena.hand.test_pointer,MOUSE_BUTTON_RIGHT)
	checks.right_click_cancels_without_cost = defense.mode==defense.Mode.IDLE and not is_instance_valid(site.tower) and arena.crew.loot.crystals==10
	await _pad_click()
	await _choose()
	await _key(KEY_ESCAPE)
	checks.escape_cancels_without_quitting = defense.mode==defense.Mode.IDLE and arena.crew.loot.crystals==10
	await _pad_click()
	await _choose()
	await _key(KEY_EQUAL)
	checks.hide_ui_cancels_preview = not arena.interface_visible and defense.mode==defense.Mode.IDLE and not defense.sector.visible and arena.crew.loot.crystals==10
	await _key(KEY_EQUAL)
	await _pad_click()
	await _choose()
	await _key(KEY_F)
	checks.mode_switch_cancels_preview = not arena.hand.enabled and defense.mode==defense.Mode.IDLE and arena.crew.loot.crystals==10
	arena.hand.set_enabled(true)
	arena.crew.input_armed = true
	await _pad_click()
	await _choose()
	arena.tank.position += Vector3.LEFT*45
	defense.tick(0.016)
	checks.leaving_reach_cancels_without_cost = defense.mode==defense.Mode.IDLE and arena.crew.loot.crystals==10
	await _place_near(site)
	await _pad_click()
	await _choose()
	await _aim_at(site.global_position+Vector3.LEFT*12)
	arena.crew.loot.crystals = 9
	await _click(arena.hand.test_pointer)
	checks.rechecks_currency_at_confirmation = not is_instance_valid(site.tower) and defense.mode==defense.Mode.IDLE and arena.crew.loot.crystals==9
	arena.crew.loot.crystals = 10
	await _pad_click()
	await _choose()
	await _aim_at(site.global_position+Vector3.LEFT*12)
	await _click(arena.hand.test_pointer)
	checks.confirm_creates_tower_and_spends_once = is_instance_valid(site.tower) and arena.crew.loot.crystals==0 and defense.mode==defense.Mode.IDLE
	checks.menu_does_not_fire_cannon_or_grab = arena.tank.shot_count==0 and not is_instance_valid(arena.hand.held)
	checks.second_confirm_rejected = not defense.confirm() and arena.crew.loot.crystals==0
	var tower = site.tower
	if not is_instance_valid(tower): _finish(); return
	checks.built_tower_blocks_actors = tower.collision_layer==(1|2048)
	var initial_heading: float = tower.global_rotation.y
	await _pad_click()
	checks.built_click_offers_free_rotation = defense.mode==defense.Mode.MENU and defense.reorienting and not defense.choice.disabled
	await _choose()
	await _aim_at(site.global_position+Vector3.FORWARD*12)
	await _click(arena.hand.test_pointer,MOUSE_BUTTON_RIGHT)
	checks.cancel_rotation_keeps_heading = absf(angle_difference(tower.global_rotation.y,initial_heading))<0.02
	await _pad_click()
	await _choose()
	await _aim_at(site.global_position+Vector3.LEFT*12+Vector3.FORWARD*4)
	var desired: float = defense.heading
	await _click(arena.hand.test_pointer)
	checks.rotation_is_free_and_applied = absf(angle_difference(tower.global_rotation.y,desired))<0.02 and arena.crew.loot.crystals==0
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
	arena.hand.set_enabled(true)
	arena.crew.input_armed = true
	arena.crew.loot.crystals = 30
	for pad in defense.sites:
		if is_instance_valid(pad.tower): continue
		await _place_near(pad)
		defense.open_menu(pad,Vector2(300,300))
		defense.begin_orientation()
		defense.update_direction(arena.aim_camera.unproject_position(pad.global_position+Vector3.LEFT*15))
		checks["build_"+pad.name] = defense.confirm()
	checks.all_three_slots_built = defense.sites.all(func(p): return is_instance_valid(p.tower)) and arena.crew.loot.crystals==10
	arena.focus = arena.level.C+Vector3(-9,0,0)
	arena.zoom = 42
	arena._update_camera(1.0)
	await arena._capture(arena.verification_path("defense_04_village.png"))
	# Measure only the new controller's CPU cost with a dense 600-enemy fixture.
	# This is not a whole-game FPS benchmark; enemies stay fixed for repeatability.
	arena.battle.reset()
	for i in 600:
		var enemy = _enemy(Vector3(2+(i%20)*0.9,0,-16+floori(i/20.0)*1.7))
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
	checks.projectiles_remain_bounded = metrics.live_bolts_600<=15
	arena.reset_range()
	arena.level.cancel_spawning()
	arena.battle.reset()
	await _frames(4)
	checks.reset_restores_empty_pads_and_currency = defense.sites.all(func(p): return not is_instance_valid(p.tower) and p.ring.visible) and arena.crew.loot.crystals==0
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
