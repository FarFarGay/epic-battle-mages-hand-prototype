extends SceneTree
## Real-frame defense benchmark: run with --script res://verification/waves_perf.gd -- --profile.
var arena
var label := "current"
var report := {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--perf-label="): label = arg.trim_prefix("--perf-label=").validate_filename()
	_run.call_deferred()

func _sample(name: String, seconds: float) -> void:
	var frames: Array[float] = []
	var stages := {"logic":0.0,"separation":0.0,"move":0.0,"shared":0.0}
	var previous := Time.get_ticks_usec()
	var end := previous + int(seconds*1000000)
	var peak := 0
	var physics := 0.0
	while Time.get_ticks_usec() < end:
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now-previous)/1000.0)
		previous = now
		arena.tank.hp = 1000000.0
		peak = maxi(peak,arena.battle.enemies.size())
		physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0
		for stage in stages: stages[stage] += arena.battle.last_profile.get(stage,0)/1000.0
	var total := 0.0
	for value in frames: total += value
	frames.sort()
	for stage in stages: stages[stage] /= frames.size()
	report[name] = {"fps":frames.size()*1000.0/total,"p95_ms":frames[int(frames.size()*0.95)],"max_ms":frames.back(),"physics_ms":physics/frames.size(),"battle_stages_ms":stages,"peak_alive":peak,"pending":arena.level.defense_waves.pending.size()}
	print("WAVES_PERF: ",name," ",JSON.stringify(report[name]))

func _run() -> void:
	arena = load("res://desert.tscn").instantiate()
	root.add_child(arena)
	if not arena.rendering_ready: await arena.rendering_prepared
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	arena.test_aim = true
	arena.level.cancel_spawning()
	arena.level.automatic_encounters = false
	report.machine = {"cpu":OS.get_processor_name(),"gpu":RenderingServer.get_video_adapter_name(),"display":DisplayServer.get_name()}
	for index in 3:
		arena.level.defense_waves.reset()
		arena.battle.reset()
		await physics_frame
		arena.tank.position = Vector3(36,4.04,19)
		arena.tank.stop_drive()
		arena.tank.hp = 1000000.0
		arena.focus = arena.tank.position
		arena.aim_position = arena.tank.position+Vector3(-30,0,0)
		arena._update_camera(1.0)
		arena.level.defense_waves.completed = index
		arena.level.defense_waves.request_wave(index)
		await _sample("wave_%d_approach"%(index+1),12.0)
		await _sample("wave_%d_congested"%(index+1),12.0)
	var file := FileAccess.open(arena.verification_path("waves_perf_"+label+".json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	quit()
