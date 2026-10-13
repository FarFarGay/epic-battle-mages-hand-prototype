extends SceneTree
## Measure actual throughput, not merely one successful walker per entrance.
var arena
var label := "current"
var keep_arrivals := false
var wave_index := 2
var seconds := 90

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--label="): label = arg.trim_prefix("--label=").validate_filename()
		if arg == "--keep-arrivals": keep_arrivals = true
		if arg.begins_with("--wave="): wave_index = int(arg.trim_prefix("--wave="))-1
		if arg.begins_with("--seconds="): seconds = maxi(15,int(arg.trim_prefix("--seconds=")))
	_run.call_deferred()

func _run() -> void:
	arena = load("res://desert.tscn").instantiate()
	root.add_child(arena)
	if not arena.rendering_ready: await arena.rendering_prepared
	arena.set_physics_process(false)
	arena.test_aim = true
	arena.level.cancel_spawning()
	arena.level.automatic_encounters = false
	var waves = arena.level.defense_waves
	waves.reset()
	arena.battle.reset()
	await physics_frame
	await physics_frame
	arena.tank.position = arena.level.C+Vector3(-12,0.04,9)
	arena.tank.stop_drive()
	arena.focus = arena.tank.position
	arena._update_camera(1.0)
	waves.completed = wave_index
	waves.request_wave(wave_index)
	var arrived := {}
	var counts := {"Center":0,"Right":0,"North":0}
	var history: Array = []
	var cpu := 0
	for frame in seconds*60:
		arena.tank.hp = 1000000.0
		var stamp := Time.get_ticks_usec()
		waves.tick(1.0/60)
		arena.battle.tick(1.0/60)
		cpu += Time.get_ticks_usec()-stamp
		for enemy in arena.battle.enemies.duplicate():
			if enemy.dead or enemy.wave_entrance==&"": continue
			var entrance = waves.get_node("Entrances").get_node(NodePath(enemy.wave_entrance))
			var crest: Vector3 = entrance.get_node("Crest").global_position
			var forward: Vector3 = (crest-entrance.get_node("Foot").global_position)
			forward.y = 0
			forward = forward.normalized()
			if enemy.position.y>=crest.y-0.25 and (enemy.position-crest).dot(forward)>2.0:
				var id: int = enemy.get_instance_id()
				if not arrived.has(id):
					arrived[id] = true
					counts[enemy.wave_entrance] += 1
				if not keep_arrivals:
					waves.enemy_removed(enemy)
					arena.battle.enemies.erase(enemy)
					enemy.collision_layer = 0
					enemy.queue_free()
		await physics_frame
		if frame%900==899:
			var sample := {"seconds":(frame+1)/60,"arrived":counts.duplicate(),"pending":waves.pending.size(),"alive":arena.battle.enemies.size()}
			history.append(sample)
			print("RAMP_CROWD: ",JSON.stringify(sample))
	var stranded: Array = []
	var climbed: Dictionary = counts.duplicate()
	for enemy in arena.battle.enemies:
		if arrived.has(enemy.get_instance_id()): continue
		var crest: Vector3 = waves.get_node("Entrances").get_node(NodePath(enemy.wave_entrance)).get_node("Crest").global_position
		# Throwers can correctly stop to fire just beyond the ramp, before the
		# two-metre exit line used to remove walkers from the throughput fixture.
		if enemy.wave_route.is_empty() and enemy.position.y>=crest.y-0.25: climbed[enemy.wave_entrance] += 1
		if stranded.size()<24: stranded.append({"entrance":enemy.wave_entrance,"position":str(enemy.position),"role":enemy.role,"giant":enemy.giant,"path_next":str(enemy.path[0]) if not enemy.path.is_empty() else "none","direction":str(enemy.move_direction),"route_left":enemy.wave_route.size(),"goal":str(enemy.wave_route[0]) if not enemy.wave_route.is_empty() else "none","clearance":enemy.walk_clearance,"separation":str(enemy.separation_force)})
	var expected: int = waves.waves[wave_index].total()
	var climbed_total: int = climbed.values().reduce(func(a,b): return a+b,0)
	var passed: bool = climbed_total==expected and waves.pending.is_empty()
	var report := {"passed":passed,"expected":expected,"arrived":counts,"total_arrived":arrived.size(),"climbed":climbed,"climbed_total":climbed_total,"pending":waves.pending.size(),"keep_arrivals":keep_arrivals,"seconds":seconds,"mean_ai_spawn_ms":cpu/(seconds*60000.0),"history":history,"stranded":stranded}
	var file := FileAccess.open(arena.verification_path("ramp_crowd_"+label+".json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	print("RAMP_CROWD_RESULT: ",JSON.stringify(report))
	quit(0 if passed else 1)
