extends SceneTree
var arena
var checks := {}
var metrics := {}

func _initialize() -> void:
	_run.call_deferred()

func frames(count: int) -> void:
	for i in count: await physics_frame

func click(point: Vector2) -> void:
	arena.hand.test_pointer = point
	for pressed in [true,false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = root.get_final_transform()*point
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await frames(2)

func win_wave() -> void:
	var waves = arena.level.defense_waves
	for i in 100:
		waves.tick(.016)
		for ref in waves.living.values():
			var enemy = ref.get_ref()
			if is_instance_valid(enemy): enemy.take_damage(10000,Vector3.ZERO)
		if waves.active<0: return
		await frames(1)
	checks.wave_finished_without_timeout = false

func view_at(point: Vector3, filename: String) -> void:
	arena.focus = point
	arena.zoom = 28
	arena._update_camera(1)
	await frames(3)
	await arena._capture(arena.verification_path(filename))

func _run() -> void:
	arena = load("res://desert.tscn").instantiate()
	root.add_child(arena)
	if not arena.rendering_ready: await arena.rendering_prepared
	arena.set_physics_process(false)
	arena.level.cancel_spawning()
	arena.level.automatic_encounters = false
	arena.battle.reset()
	var level = arena.level
	var flow = level.campaign
	var waves = level.defense_waves
	var tank = arena.tank
	var shop = arena.defenses.mechanic
	var loot = arena.crew.loot
	# Keep the real ordered scheduler, spawning and completion; use tiny combat fixtures.
	for config in waves.waves:
		config.ordinary = 2
		config.shields = 0
		config.giants = 0
		config.bombers = 0
		config.throwers = 0
	checks.starts_without_cannon = not tank.cannon_installed and not tank.gun_pitch.visible
	var shots: int = tank.shot_count
	tank.fire()
	checks.locked_cannon_cannot_fire = tank.shot_count==shots
	arena.crew.input_armed = true
	tank.crossbows.trigger(true)
	tank.crossbows.tick(.016)
	tank.crossbows.trigger(false)
	checks.side_weapons_work_without_cannon = tank.crossbows.shot_count>0
	checks.workshop_initially_absent = not shop.visible and shop.structure.collision_layer==0
	loot.coins = 1000
	loot.crystals = 1000
	checks.cannot_buy_before_rescue = not shop.purchase(arena) and loot.coins==1000
	tank.position = level.A+Vector3(7,.04,5)
	flow.tick(100)
	checks.early_visit_cannot_rescue = flow.phase==flow.Phase.FIRST_DEFENSE
	level.unlocked = true
	level.open_gate()
	checks.gate_waits_for_first_defense = not level.gate_open and not level.gate_handle.can_hand_grab()
	level.unlocked = false
	tank.position = level.C+Vector3(-12,.04,9)
	await frames(3)
	checks.future_house_has_floor = absf(arena.ground_height(shop.global_position)-shop.global_position.y)<.1
	checks.future_house_lot_reserved = not arena.defenses.placement.reason(shop.global_position).is_empty()
	var probe := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4,3,5)
	probe.shape = box
	probe.transform.origin = shop.global_position+Vector3.UP*1.7
	probe.collision_mask = 1|2|8|32|64
	var overlaps: Array = arena.get_world_3d().direct_space_state.intersect_shape(probe)
	metrics.house_overlaps = overlaps.map(func(hit): return str(hit.collider.get_path()))
	checks.future_house_lot_physically_clear = overlaps.is_empty()
	var site = arena.defenses.create_site(level.C+Vector3(-25,0,6))
	site.construct(0)
	waves.tick(4.99)
	checks.first_wave_waits_five_seconds = waves.active==-1
	waves.tick(.01)
	checks.first_wave_starts = waves.active==0
	await win_wave()
	checks.first_victory_sends_to_mechanic = flow.phase==flow.Phase.RESCUE_MECHANIC and waves.completed==1
	checks.n_cannot_skip_mechanic = not waves.start_next_test_wave()
	checks.legacy_event_cannot_skip_mechanic = not waves.notify_story_event(waves.waves[1].start_event)
	flow.tick(100)
	checks.no_timer_while_mechanic_captive = flow.seconds_left<0 and waves.active<0
	# Real pressure plate and hand button; physical tunnel traversal is in level_regression.
	level.weight.freeze = true
	level.weight.global_position = level.platform_rest+Vector3.UP*.44
	level.tick(.016)
	checks.weight_enables_button = level.unlocked and not level.gate_open
	tank.position = level.A+Vector3(-22,.04,0)
	arena.hand.set_enabled(true)
	arena.crew.input_armed = true
	await frames(3)
	checks.hand_press_opens_gate = arena.hand.grab(level.gate_handle) and level.gate_open
	arena.hand.place_gently()
	arena.hand.tick(.016)
	arena.hand.set_enabled(false)
	level.tick(2)
	tank.position = flow.mechanic.global_position+Vector3(0,0,3)
	await view_at(level.A,"campaign_mechanic.png")
	flow.tick(.016)
	checks.rescue_after_gate = flow.phase==flow.Phase.RETURN_MECHANIC and not flow.mechanic.visible
	flow.tick(100)
	checks.no_timer_until_return = flow.seconds_left<0 and waves.active<0 and not shop.available
	tank.position = level.C+Vector3(-12,.04,9)
	flow.tick(.016)
	checks.return_builds_house_and_starts_60 = shop.available and shop.visible and shop.structure.collision_layer==1 and flow.seconds_left==60 and flow.phase==flow.Phase.PREPARE_SECOND
	# With no residents left, preparation must still build the whole approach map.
	for i in 500:
		arena.battle.tick(1.0/60)
		if arena.battle.defense_navigation and not arena.battle.nav_building and not arena.battle.nav_dirty: break
	checks.preparation_builds_navigation_without_enemies = arena.battle.defense_navigation and not arena.battle.nav_building and not arena.battle.nav_dirty
	arena.tuning_open = true
	flow.tick(30)
	checks.settings_pause_timer = flow.seconds_left==60
	arena.tuning_open = false
	tank.position = level.C+Vector3(-60,.04,0)
	flow.tick(10)
	tank.position = level.C+Vector3(-12,.04,9)
	flow.tick(1)
	checks.reenter_does_not_reset_timer = flow.seconds_left==49
	loot.coins = 99
	loot.crystals = 20
	checks.cannon_checks_gold = not shop.purchase(arena) and loot.coins==99 and loot.crystals==20
	loot.coins = 100
	loot.crystals = 19
	checks.cannon_checks_crystals = not shop.purchase(arena) and loot.coins==100 and loot.crystals==19
	loot.crystals = 20
	arena.crew.input_armed = true
	tank.position = shop.global_position+Vector3(-7,.04,2)
	await view_at(shop.global_position,"campaign_workshop.png")
	await click(arena.aim_camera.unproject_position(shop.global_position+Vector3.UP*2))
	metrics.menu_pick = str(arena.defenses.pick_site(arena.aim_camera.unproject_position(shop.global_position+Vector3.UP*2)))
	metrics.menu_reachable = arena.defenses.reachable(shop)
	metrics.menu_context = arena.defenses._context_valid()
	checks.house_click_opens_upgrade_menu = arena.defenses.mode==arena.defenses.Mode.MENU and arena.defenses.active_shop==shop
	await arena._capture(arena.verification_path("campaign_shop_menu.png"))
	await click(arena.defenses.choice.get_global_rect().get_center())
	checks.menu_purchase_exact_price = tank.cannon_installed and loot.coins==0 and loot.crystals==0
	checks.installed_cannon_visible = tank.gun_pitch.visible
	loot.coins = 100
	loot.crystals = 20
	checks.cannot_buy_twice = not shop.purchase(arena) and loot.coins==100 and loot.crystals==20
	arena.defenses.cancel()
	shots = tank.shot_count
	tank.fire()
	checks.installed_cannon_fires = tank.shot_count==shots+1
	await view_at(tank.position,"campaign_cannon.png")
	# Simulate navigation following the trip from the return point to the shop.
	for i in 500:
		arena.battle.tick(1.0/60)
		if not arena.battle.nav_building and not arena.battle.nav_dirty: break
	flow.tick(48.99)
	checks.second_wave_not_early = waves.active==-1
	flow.tick(.01)
	checks.second_wave_starts_at_60 = waves.active==1 and flow.phase==flow.Phase.SECOND_DEFENSE
	var prepared_grid = arena.battle.grid
	arena.battle.tick(1.0/60)
	checks.wave_start_reuses_prepared_navigation = arena.battle.grid==prepared_grid and not arena.battle.nav_building
	await win_wave()
	checks.second_victory_sends_to_dungeon = flow.phase==flow.Phase.DUNGEON
	checks.n_cannot_skip_dungeon = not waves.start_next_test_wave()
	tank.position = Vector3(level.B.x,.04,level.B.z)
	flow.tick(1)
	checks.dungeon_requires_plateau_height = flow.phase==flow.Phase.DUNGEON
	tank.position = level.B+Vector3(0,.04,0)
	flow.tick(.016)
	checks.dungeon_visit_completes_objective = flow.phase==flow.Phase.RETURN_DUNGEON
	flow.tick(100)
	checks.final_timer_waits_for_return = flow.seconds_left<0 and waves.active<0
	tank.position = level.C+Vector3(-12,.04,9)
	flow.tick(.016)
	checks.final_return_starts_60 = flow.phase==flow.Phase.PREPARE_FINAL and flow.seconds_left==60
	flow.tick(59.99)
	checks.final_wave_not_early = waves.active==-1
	flow.tick(.01)
	checks.final_wave_starts_at_60 = waves.active==2
	await win_wave()
	checks.final_victory_finishes_prototype = flow.phase==flow.Phase.COMPLETE and level.completed and waves.completed==3
	flow.tick(1000)
	checks.no_extra_wave_or_boss = waves.active<0 and waves.remaining()==0
	arena.reset_range()
	arena.level.cancel_spawning()
	arena.battle.reset()
	checks.reset_clears_campaign = flow.phase==flow.Phase.FIRST_DEFENSE and flow.seconds_left<0 and not tank.cannon_installed and not shop.available and flow.mechanic.visible and not level.gate_open and not level.completed
	# Independent timer branch: buying a cannon is optional, not a hidden start trigger.
	waves.completed = 1
	flow.phase = flow.Phase.RETURN_MECHANIC
	tank.position = level.C+Vector3(-12,.04,9)
	flow.tick(.016)
	flow.tick(60)
	checks.second_wave_starts_without_purchase = waves.active==1 and not tank.cannon_installed
	arena.reset_range()
	checks.reset_during_wave_cancels_timers = flow.phase==flow.Phase.FIRST_DEFENSE and waves.active<0 and waves.remaining()==0 and not shop.visible
	var passed: bool = checks.values().all(func(value): return value)
	var report := {"passed":passed,"checks":checks,"metrics":metrics}
	var file := FileAccess.open(arena.verification_path("campaign_check.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	print("CAMPAIGN_CHECK: ",JSON.stringify(report))
	quit(0 if passed else 1)
