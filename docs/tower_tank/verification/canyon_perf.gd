extends Node
## Wall-clock benchmark of the real canyon, including crowd, orbit and traversal.
var arena
var label := "current"
var orbiting := false
var firing := false
var elapsed := 0.0
var report := {}

func _ready() -> void:
	arena = get_parent()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--perf-label="): label=arg.trim_prefix("--perf-label=").validate_filename()
	_run.call_deferred()

func _process(dt: float) -> void:
	elapsed += dt
	arena.tank.hp = arena.tank.MAX_HP
	if orbiting: arena.camera_yaw += dt*0.65
	if firing: arena.aim_position=arena.tank.position+Vector3(28,1.0,sin(elapsed*0.7)*7)

func _sample(name: String, seconds: float) -> void:
	var times: Array[float]=[]
	var physics := 0.0
	var draws := 0.0
	var slow_33 := 0
	var slow_50 := 0
	var max_nav_usec := 0
	var slow_frames: Array = []
	var previous := Time.get_ticks_usec()
	var end := previous+int(seconds*1000000)
	while Time.get_ticks_usec()<end:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var frame := (now-previous)/1000.0
		previous=now
		times.append(frame)
		physics+=Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0
		draws+=Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		if frame>33.3: slow_33+=1
		if frame>50.0: slow_50+=1
		if arena.battle.nav_building: max_nav_usec=maxi(max_nav_usec,arena.battle.last_nav_slice_usec)
		if frame>20.0 and slow_frames.size()<80:
			slow_frames.append({"ms":frame,"process_ms":Performance.get_monitor(Performance.TIME_PROCESS)*1000.0,"physics_ms":Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0,"physics_stages_us":arena.physics_profile.duplicate(),"battle_us":arena.battle.last_profile.duplicate(),"fx":arena.fx.pieces.size(),"coins":arena.crew.loot.loose_coins.size(),"enemies":arena.battle.enemies.size(),"draws":Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),"freeze":arena.freeze})
	var total := 0.0
	for value in times: total+=value
	times.sort()
	report[name]={"fps":times.size()*1000.0/total,"p95_ms":times[int(times.size()*0.95)],"p99_ms":times[int(times.size()*0.99)],"max_ms":times.back(),"frames":times.size(),"over_33_ms":slow_33,"over_50_ms":slow_50,"physics_ms":physics/times.size(),"draw_calls":draws/times.size(),"max_nav_slice_ms":max_nav_usec/1000.0}
	report[name].slow_frames = slow_frames
	var summary: Dictionary = report[name].duplicate()
	summary.erase("slow_frames")
	print("CANYON_PERF_PHASE: ",name," ",JSON.stringify(summary))

func _run() -> void:
	if not arena.rendering_ready: await arena.rendering_prepared
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps=0
	arena.test_aim=true
	arena.level.automatic_encounters=false
	arena.aim_position=arena.tank.position+Vector3(30,1,0)
	report.machine={"cpu":OS.get_processor_name(),"gpu":RenderingServer.get_video_adapter_name(),"version":ProjectSettings.get_setting("application/config/version")}
	await _sample("approach",5.0)
	orbiting=true
	await _sample("orbit",5.0)
	orbiting=false
	arena.camera_yaw=-PI/4
	Input.action_press("tank_forward")
	Input.action_press("tank_right")
	firing=true
	arena.tank.crossbows.trigger(true)
	await _sample("advance_burst",8.0)
	await arena._capture(arena.verification_path("perf_combat.png"))
	firing=false
	arena.tank.crossbows.trigger(false)
	Input.action_release("tank_forward")
	Input.action_release("tank_right")
	arena.level.cancel_spawning()
	# Keep the same living residents to measure traversal of the populated world.
	for enemy in arena.battle.enemies.duplicate():
		if not enemy.world_resident:
			enemy.collision_layer=0
			arena.battle.enemies.erase(enemy)
			enemy.queue_free()
	arena.tank.position=Vector3(-105,0.04,-45)
	arena.tank.stop_drive()
	arena.focus=arena.tank.position
	arena.camera_yaw=-PI/4
	arena.aim_position=arena.tank.position+Vector3(28,1,0)
	# Despawning the corridor fixtures is a benchmark transition, not traversal.
	await _sample("world_transition",0.5)
	Input.action_press("tank_forward")
	Input.action_press("tank_right")
	firing=true
	arena.tank.crossbows.trigger(true)
	await _sample("world_travel",8.0)
	await arena._capture(arena.verification_path("perf_world_combat.png"))
	firing=false
	arena.tank.crossbows.trigger(false)
	Input.action_release("tank_forward")
	Input.action_release("tank_right")
	arena.battle.reset()
	for entry in [["atoll_a",arena.level.A],["atoll_b",arena.level.B],["atoll_c",arena.level.C]]:
		arena.tank.position=entry[1]+Vector3(-8,0.04,0)
		arena.tank.stop_drive()
		arena.focus=arena.tank.position
		arena.aim_position=arena.tank.position+Vector3(12,0,0)
		orbiting=true
		await get_tree().create_timer(0.35).timeout
		await _sample(entry[0],4.0)
	orbiting=false
	arena.tank.position=arena.level.C+Vector3(-18,0.04,0)
	arena.tank.stop_drive()
	arena.focus=arena.tank.position
	arena.camera_yaw=-PI/4
	arena._update_camera(1.0)
	arena.crew.disembark()
	_place_squad(arena.level.C+Vector3(-15,0,0))
	await get_tree().create_timer(0.35).timeout
	await _sample("crew_roam",4.0)
	_place_squad(arena.level.C+Vector3(-7,0,0))
	var right: Vector3=arena.aim_camera.global_basis.x
	var back: Vector3=arena.aim_camera.global_basis.z
	right.y=0
	back.y=0
	var x:=Vector3.RIGHT.dot(right.normalized())
	var y:=Vector3.RIGHT.dot(back.normalized())
	Input.action_press("tank_right" if x>0 else "tank_left",absf(x))
	Input.action_press("tank_reverse" if y>0 else "tank_forward",absf(y))
	await _sample("mining",8.0)
	for action in ["tank_forward","tank_reverse","tank_left","tank_right"]: Input.action_release(action)
	report.mined_blocks=arena.level.mined
	await arena._capture(arena.verification_path("perf_mining.png"))
	var file := FileAccess.open(arena.verification_path("canyon_perf_"+label+".json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	print("CANYON_PERF_RESULT: ",JSON.stringify(report))
	get_tree().quit()

func _place_squad(pos: Vector3) -> void:
	var crew=arena.crew
	crew.anchor=pos
	crew.motion=Vector3.ZERO
	crew.facing=Vector3.RIGHT
	arena.aim_position=pos+Vector3.RIGHT*20
	arena.ground_aim_position=arena.aim_position
	for index in crew.members.size():
		var member=crew.members[index]
		member.position=pos+crew._slot(index,Vector3.RIGHT)+Vector3.UP*0.04
		member.velocity=Vector3.ZERO
		member.knockback=Vector3.ZERO
