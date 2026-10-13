extends SceneTree
## Isolate the first eight seconds of each defense wave, retaining world patrols.
var arena
var label := "current"
var report := {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--perf-label="): label = arg.trim_prefix("--perf-label=").validate_filename()
	_run.call_deferred()

func _run() -> void:
	arena = load("res://desert.tscn").instantiate()
	root.add_child(arena)
	if not arena.rendering_ready: await arena.rendering_prepared
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	arena.test_aim = true
	arena.level.cancel_spawning()
	arena.level.automatic_encounters = false
	for enemy in arena.battle.enemies.duplicate():
		if not enemy.world_resident:
			arena.battle.enemies.erase(enemy)
			enemy.collision_layer = 0
			enemy.queue_free()
	report.machine = {"cpu":OS.get_processor_name(),"gpu":RenderingServer.get_video_adapter_name(),"display":DisplayServer.get_name()}
	var waves = arena.level.defense_waves
	for index in 3:
		waves.reset()
		arena.tank.position = arena.level.C+Vector3(-12,0.04,9)
		arena.tank.hp = 1000000.0
		arena.tank.stop_drive()
		arena.focus = arena.tank.position
		arena.aim_position = arena.tank.position+Vector3(-30,0,0)
		arena._update_camera(1.0)
		arena.battle._rebuild_navigation()
		await create_timer(0.5).timeout
		arena.battle.movement_profile.clear()
		waves.completed = index
		var start := Time.get_ticks_usec()
		waves.request_wave(index)
		var request_ms := (Time.get_ticks_usec()-start)/1000.0
		var previous := start
		var frames: Array[float] = []
		var slowest: Array[Dictionary] = []
		var spawn_done_ms := -1.0
		var over_33 := 0
		var over_50 := 0
		while Time.get_ticks_usec()-start<8000000:
			await process_frame
			var now := Time.get_ticks_usec()
			var ms := (now-previous)/1000.0
			previous = now
			frames.append(ms)
			arena.tank.hp = 1000000.0
			if ms>33.333: over_33 += 1
			if ms>50.0: over_50 += 1
			if waves.pending.is_empty() and spawn_done_ms<0: spawn_done_ms = (now-start)/1000.0
			if slowest.size()<12 or ms>slowest.back().ms:
				slowest.append({"ms":ms,"at_ms":(now-start)/1000.0,"pending":waves.pending.size(),"nav_building":arena.battle.nav_building,"nav_cursor":arena.battle.nav_build_cursor,"nav_area":arena.battle.nav_build_solid.size(),"battle_us":arena.battle.last_profile.duplicate(),"physics_us":arena.physics_profile.duplicate()})
				slowest.sort_custom(func(a,b): return a.ms>b.ms)
				if slowest.size()>12: slowest.resize(12)
		var total := 0.0
		for value in frames: total += value
		frames.sort()
		var result := {"fps":frames.size()*1000.0/total,"p95_ms":frames[int(frames.size()*0.95)],"p99_ms":frames[int(frames.size()*0.99)],"max_ms":frames.back(),"over_33_ms":over_33,"over_50_ms":over_50,"request_ms":request_ms,"spawn_done_ms":spawn_done_ms,"pending":waves.pending.size(),"spawned":waves.spawned_by_type.values().reduce(func(a,b): return a+b,0),"movement":arena.battle.movement_profile.duplicate(),"slowest":slowest}
		report["wave_%d"%(index+1)] = result
		var summary: Dictionary = result.duplicate()
		summary.erase("slowest")
		print("WAVE_SPAWN_PERF: ",index+1," ",JSON.stringify(summary))
	var file := FileAccess.open(arena.verification_path("wave_spawn_"+label+".json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	quit()
