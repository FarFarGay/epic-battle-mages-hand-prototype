extends SceneTree
var checks := {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var arena = load("res://desert.tscn").instantiate()
	root.add_child(arena)
	if not arena.rendering_ready: await arena.rendering_prepared
	arena.set_physics_process(false)
	arena.level.cancel_spawning()
	arena.level.automatic_encounters = false
	arena.battle.reset()
	var waves = arena.level.defense_waves
	var sites := []
	for offset in [Vector3(-25,0,6),Vector3(6,0,-8),Vector3(6,0,8)]:
		sites.append(arena.defenses.create_site(arena.level.C+offset))
	checks.entry_has_no_village_objective = not waves.status_visible()
	arena.tank.position = Vector3(-110,0.04,0)
	waves.tick(30.0)
	checks.open_zone_shows_destination = waves.status_visible() and waves.status_text().contains("ДОБЕРИСЬ")
	checks.travel_does_not_start_wave = waves.active==-1 and waves.first_wave_left<0.0
	arena.tank.position = arena.level.C+Vector3(-12,0.04,9)
	waves.tick(30.0)
	checks.arrival_shows_construction_goal = waves.status_text().contains("ПОСТРОЙ 1")
	checks.arrival_does_not_start_wave = waves.active==-1
	checks.mining_does_not_start_wave = not waves.notify_story_event(&"first_ore_mined") and waves.first_wave_left<0.0
	checks.story_cannot_bypass_construction = not waves.notify_story_event(waves.waves[0].start_event)
	checks.hotkey_cannot_bypass_construction = not waves.start_next_test_wave() and waves.active==-1
	sites[0].construct(0.0)
	checks.first_tower_arms_five_seconds = waves.first_wave_left==5.0 and waves.active==-1
	waves.tick(2.0)
	sites[1].construct(0.0)
	sites[0].construct(1.0)
	sites[0].tower.change_heading(1.0)
	checks.extra_build_and_rotation_preserve_countdown = waves.first_wave_left==3.0
	checks.countdown_visible = waves.status_text().contains("3 С")
	checks.hotkey_cannot_skip_countdown = not waves.start_next_test_wave() and waves.active==-1
	arena.focus = arena.tank.position
	arena._update_camera(1.0)
	await arena._capture(arena.verification_path("first_defense_countdown.png"))
	arena.tank.position = Vector3(-110,0.04,0)
	waves.tick(2.99)
	checks.not_started_at_4_99_seconds = waves.active==-1
	waves.tick(0.01)
	checks.starts_at_five_seconds_even_after_leaving = waves.active==0 and waves.remaining()==300
	sites[2].construct(0.0)
	checks.later_build_does_not_queue_another_wave = waves.first_wave_left<0.0 and waves.active==0 and waves.remaining()==300
	arena.reset_range()
	sites = [arena.defenses.create_site(arena.level.C+Vector3(6,0,-8)),arena.defenses.create_site(arena.level.C+Vector3(6,0,8))]
	checks.reset_clears_progress = waves.active==-1 and waves.first_wave_left<0.0 and not waves.status_visible()
	sites[0].construct(0.0)
	waves.tick(2.0)
	arena.reset_range()
	sites = [arena.defenses.create_site(arena.level.C+Vector3(6,0,-8)),arena.defenses.create_site(arena.level.C+Vector3(6,0,8))]
	waves.tick(10.0)
	checks.reset_cancels_pending_countdown = waves.active==-1 and waves.first_wave_left<0.0
	sites[0].construct(0.0)
	checks.new_run_can_arm_again = waves.first_wave_left==5.0
	waves.reset()
	waves.completed = 1
	sites[1].construct(0.0)
	waves.tick(10.0)
	checks.building_does_not_start_wave_two = waves.active==-1 and waves.first_wave_left<0.0
	arena.tank.position = arena.level.C+Vector3(-12,0.04,9)
	checks.later_hotkey_cannot_skip_campaign = not waves.start_next_test_wave() and waves.active==-1
	var passed := true
	for value in checks.values(): passed = passed and value
	var report := {"passed":passed,"checks":checks}
	var file := FileAccess.open(arena.verification_path("first_defense_check.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	print("FIRST_DEFENSE_CHECK: ",JSON.stringify(report))
	quit(0 if passed else 1)
