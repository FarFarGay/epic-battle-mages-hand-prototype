extends Node
## Rendered benchmark: all actors in view, uncapped, reproducible crowded range.
var arena
var battle
var count := 600
var label := "current"
var sample_frames := 90
var report := {}
var firing := false
var aim_wait := 0.0
var refill_cursor := 0
var positions: Array[Vector3] = []
var ordinary_only := false

func _ready() -> void:
	arena = get_parent()
	battle = arena.battle
	for arg in OS.get_cmdline_user_args():
		if arg == "--ordinary-only": ordinary_only = true
		if arg.begins_with("--count="): count = int(arg.trim_prefix("--count="))
		if arg.begins_with("--label="): label = arg.trim_prefix("--label=")
		if arg.begins_with("--frames="): sample_frames = int(arg.trim_prefix("--frames="))
	_run.call_deferred()

func _process(dt: float) -> void:
	# Keep the same crowd alive long enough to measure sustained combat.
	if arena and not arena.tank.dead: arena.tank.hp = arena.tank.MAX_HP
	if not firing: return
	aim_wait -= dt
	if aim_wait > 0.0: return
	aim_wait = 0.2
	var nearest
	var closest := INF
	for enemy in battle.enemies:
		var distance: float = enemy.position.distance_squared_to(arena.tank.position)
		if distance < closest:
			closest = distance
			nearest = enemy
	if is_instance_valid(nearest): arena.aim_position = nearest.position + Vector3.UP
	var attempts := 0
	var giants_needed: int = 0 if ordinary_only else maxi(0, count / battle.GIANT_EVERY - battle.enemies.filter(func(e): return e.giant).size())
	while battle.enemies.size() < count and attempts < 24:
		# Replacements enter from the empty outer rows, not the packed melee.
		var pos := positions[positions.size() - 1 - refill_cursor % positions.size()]
		refill_cursor += 1
		attempts += 1
		var giant := giants_needed > 0
		if battle._spawn_clear(pos, giant):
			battle.spawn_enemy(pos, giant)
			if giant: giants_needed -= 1

func _sample(name: String, frames: int = 0) -> void:
	if frames == 0: frames = sample_frames
	for i in 15: await get_tree().process_frame
	var times: Array[float] = []
	var physics := 0.0
	var ai := 0.0
	var draws := 0.0
	var objects := 0.0
	var pairs := 0.0
	var sampled_enemies := 0
	var min_enemies := count
	var profile := {"logic": 0.0, "separation": 0.0, "move": 0.0, "shared": 0.0, "actors": 0.0}
	var previous := Time.get_ticks_usec()
	for i in frames:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		times.append((now - previous) / 1000.0)
		previous = now
		if arena.is_physics_processing():
			physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			ai += battle.last_tick_usec / 1000.0
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		objects += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		pairs += Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)
		sampled_enemies += battle.enemies.size()
		min_enemies = mini(min_enemies, battle.enemies.size())
		for key in profile: profile[key] += battle.last_profile.get(key, 0)
	var total := 0.0
	for value in times: total += value
	times.sort()
	report[name] = {"frame_ms": total / frames, "p95_ms": times[int(frames * 0.95)], "fps": frames * 1000.0 / total, "physics_ms": physics / frames, "battle_ms": ai / frames, "draw_calls": draws / frames, "render_objects": objects / frames, "enemies": battle.enemies.size()}
	for key in profile: profile[key] /= frames * (1.0 if key == "actors" else 1000.0)
	report[name]["profile"] = profile
	report[name]["collision_pairs"] = pairs / frames
	report[name]["average_enemies"] = float(sampled_enemies) / frames
	report[name]["minimum_enemies"] = min_enemies
	print("HORDE_PHASE: ", name, " ", JSON.stringify(report[name]))

func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	arena.zoom = 72.0
	arena.test_aim = true
	arena.aim_position = Vector3(0, 0, -8)
	arena.ground_aim_position = Vector3.ZERO
	arena.set_physics_process(false)
	await get_tree().physics_frame
	for x in range(-21, 22):
		for z in range(-21, 22):
			var pos := Vector3(x * 1.25, 0.04, z * 1.25)
			if pos.length() > 10.0 and battle._spawn_clear(pos): positions.append(pos)
	positions.sort_custom(func(a: Vector3, b: Vector3): return a.length_squared() < b.length_squared())
	for pos in positions:
		var giant: bool = not ordinary_only and (battle.enemies.size() + 1) % battle.GIANT_EVERY == 0
		if not battle._spawn_clear(pos, giant): continue
		var enemy = battle.spawn_enemy(pos, giant)
		enemy.set_meta("perf_start", pos)
		if battle.enemies.size() >= count: break
		if battle.enemies.size() % 30 == 0: await get_tree().process_frame
	battle._rebuild_navigation()
	report["machine"] = {"cpu": OS.get_processor_name(), "gpu": RenderingServer.get_video_adapter_name(), "viewport": str(get_viewport().get_visible_rect().size), "count": battle.enemies.size()}
	report["giants"] = battle.enemies.filter(func(e): return e.giant).size()
	arena.set_physics_process(true)
	await _sample("approach")
	for i in 720: await get_tree().physics_frame
	await _sample("full", 240)
	report["moving_count"] = battle.enemies.filter(func(e): return e.position.distance_to(e.get_meta("perf_start", e.position)) > 0.5).size()
	report["attacking_count"] = battle.enemies.filter(func(e): return e.attacks > 0).size()
	await arena._capture(arena.verification_path("horde_" + label + ".png"))
	arena.set_physics_process(false)
	await _sample("render_only")
	battle.hide()
	arena.set_physics_process(true)
	await _sample("simulation_only")
	battle.show()
	report["checks"] = {"600_or_requested_alive": battle.enemies.size() == count, "on_field": battle.enemies.all(func(e): return e.position.y > -0.2 and absf(e.position.x) < 28.5 and absf(e.position.z) < 28.5)}
	Input.warp_mouse(Vector2(720, 450))
	arena.crew.input_armed = true
	Input.action_press("tank_fire")
	arena.tank.crossbows.trigger(true)
	firing = true
	await _sample("weapons", 480)
	await arena._capture(arena.verification_path("horde_" + label + "_weapons.png"))
	firing = false
	Input.action_release("tank_fire")
	arena.tank.crossbows.trigger(false)
	report.checks.both_weapons_kill = arena.tank.shot_count >= 2 and arena.tank.crossbows.shot_count >= 40 and battle.kills >= 5
	report["kills"] = battle.kills
	report["cannon_shots"] = arena.tank.shot_count
	report["crossbow_shots"] = arena.tank.crossbows.shot_count
	var file := FileAccess.open(arena.verification_path("horde_" + label + ".json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("HORDE_RESULT: ", JSON.stringify(report))
	var passed := true
	for value in report.checks.values(): passed = passed and value
	get_tree().quit(0 if passed else 1)
