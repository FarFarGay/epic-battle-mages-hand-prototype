extends Node
var arena
var waves
var checks := {}
var metrics := {}

func _ready() -> void:
	arena = get_parent()
	waves = arena.level.defense_waves
	_run.call_deferred()

func _frames(count: int) -> void:
	for i in count: await get_tree().physics_frame

func _clear() -> void:
	waves.reset()
	arena.battle.reset()
	await _frames(2)

func _run() -> void:
	await _frames(8)
	arena.set_physics_process(false)
	arena.level.cancel_spawning()
	arena.level.automatic_encounters = false
	arena.test_aim = true
	await _clear()
	arena.tank.position = Vector3(36,4.04,19)
	arena.tank.stop_drive()
	arena.focus = arena.tank.position
	arena._update_camera(1.0)
	await _frames(2)
	arena.battle._rebuild_navigation()
	checks.authored_totals = waves.waves.map(func(w): return w.total())==[300,500,600]
	checks.authored_sides = waves.waves.map(func(w): return w.entrances.size())==[1,2,3]
	checks.giants_and_specials = waves.waves[1].giants==2 and waves.waves[1].bombers>0 and waves.waves[2].throwers>0
	checks.no_automatic_start = waves.active==-1 and waves.remaining()==0
	checks.cannot_skip_order = not waves.request_wave(1)
	checks.unrelated_event_no_start = not waves.notify_story_event(&"unrelated") and waves.active==-1
	# Actual input path, then concurrent starts must be rejected.
	var key := InputEventKey.new()
	key.keycode = KEY_N
	key.physical_keycode = KEY_N
	key.pressed = true
	arena._input(key)
	checks.hotkey_starts_first = waves.active==0 and waves.pending.size()==300
	checks.no_duplicate = not waves.request_wave(0) and not waves.request_wave(1)
	for number in 3:
		if number>0: checks["start_%d"%number] = waves.notify_story_event(waves.waves[number].start_event)
		var loops := 0
		# Remove each real batch so all tickets can be checked without a long battle.
		while waves.active>=0 and loops<1000:
			waves.tick(1.0/60)
			for enemy in arena.battle.enemies.duplicate():
				if enemy.wave_owner==waves:
					enemy.dead = true
					waves.enemy_removed(enemy)
					arena.battle.enemies.erase(enemy)
					enemy.collision_layer = 0
					enemy.queue_free()
			loops += 1
			await _frames(1)
		var actual: Dictionary = waves.spawned_by_type
		var expected: Dictionary = waves.waves[number].composition()
		checks["exact_composition_%d"%number] = expected.keys().all(func(k): return actual.get(k,0)==expected[k])
		checks["exact_sides_%d"%number] = waves.spawned_by_entrance.size()==number+1
		var per_side: Array = waves.spawned_by_entrance.values()
		checks["balanced_sides_%d"%number] = per_side.max()-per_side.min()<=1
		checks["completion_%d"%number] = waves.completed==number+1 and waves.active==-1
		metrics["counts_%d"%number] = {"types":actual.duplicate(),"entrances":waves.spawned_by_entrance.duplicate(),"frames":loops}
		for i in 20: waves.tick(1.0)
		checks["waits_for_condition_%d"%number] = waves.active==-1
	checks.cannot_replay_finished = not waves.start_next_test_wave()
	await _clear()
	waves.request_wave(0)
	waves.tick(1.0/60)
	checks.incremental_spawn = waves.pending.size()>0 and waves.living.size()>0 and waves.living.size()<=waves.waves[0].spawn_per_frame
	await _clear()
	checks.reset_cancels_spawn_and_actors = waves.active==-1 and waves.remaining()==0 and arena.battle.enemies.is_empty()
	# Real traversals of all three ramps, with the same movement as a full wave.
	var walkers: Array = []
	for entrance in waves.get_node("Entrances").get_children():
		var start: Vector3 = entrance.get_node("Foot").global_position+entrance.get_node("Spawn").global_basis.z*3.0
		var enemy = arena.battle.spawn_enemy(start)
		enemy.attack_on_spawn = true
		enemy.wave_route = entrance.route(0.0)
		enemy.hp = 10000
		walkers.append(enemy)
	for i in 1800:
		arena.tank.hp = arena.tank.MAX_HP
		arena.battle.tick(1.0/60)
		await _frames(1)
		if walkers.all(func(e): return e.wave_route.is_empty()): break
	checks.three_ramps_traversed = walkers.all(func(e): return e.wave_route.is_empty() and e.position.y>3.5)
	metrics.ramp_positions = walkers.map(func(e): return {"position":str(e.position),"route_left":e.wave_route.size()})
	await _clear()
	# Special attacks against the tank and interruption by the hand / damage.
	var bomber = arena.battle.spawn_enemy(arena.tank.position+Vector3.LEFT*2.5,false,false,&"bomber")
	bomber.target = arena.tank
	bomber.state = bomber.State.WINDUP
	bomber.timer = 0.0
	var hp: float = arena.tank.hp
	bomber._special_attack(0.016,Vector3.RIGHT,2.5,1.32)
	checks.bomber_explodes_and_dies = bomber.dead and arena.tank.hp<hp
	await _frames(2)
	bomber = arena.battle.spawn_enemy(arena.tank.position+Vector3.LEFT*2.5,false,false,&"bomber")
	bomber.state = bomber.State.WINDUP
	bomber.timer = 0.01
	bomber.on_hand_grab()
	hp = arena.tank.hp
	bomber.tick(2.0)
	checks.hand_interrupts_fuse = not bomber.dead and arena.tank.hp==hp and bomber.state==bomber.State.APPROACH
	bomber.take_damage(999.0)
	checks.kill_prevents_explosion = arena.tank.hp==hp
	var thrower = arena.battle.spawn_enemy(arena.tank.position+Vector3.LEFT*10,false,false,&"thrower")
	thrower.target = arena.tank
	thrower.throw_aim = arena.tank.position
	thrower.state = thrower.State.WINDUP
	thrower.timer = 0.0
	thrower._special_attack(0.016,Vector3.RIGHT,10,1.32)
	checks.thrower_creates_telegraphed_stone = arena.battle.ordnance.stones.size()==1 and thrower.state==thrower.State.RECOVERY
	for i in 120:
		arena.battle.ordnance.tick(1.0/60)
		await _frames(1)
	checks.stone_hits_tank = arena.tank.hp<hp and arena.battle.ordnance.stones.is_empty()
	arena.battle.ordnance.throw_stone(thrower.position+Vector3.UP*2,arena.tank.position,thrower.special_settings)
	await _clear()
	checks.reset_clears_projectiles = arena.battle.ordnance.stones.is_empty()
	# All 600 tickets stay alive together: exercise congestion and spawn retries.
	waves.completed = 2
	waves.request_wave(2)
	var cpu := 0
	var cpu_max := 0
	var peak_alive := 0
	var arrivals := {}
	var stages := {"logic":0,"separation":0,"move":0,"shared":0,"wave":0}
	arena.battle.profile_enabled = true
	for i in 4500:
		arena.tank.hp = 100000.0
		var stamp := Time.get_ticks_usec()
		waves.tick(1.0/60)
		stages.wave += Time.get_ticks_usec()-stamp
		arena.battle.tick(1.0/60)
		for stage in ["logic","separation","move","shared"]: stages[stage]+=arena.battle.last_profile[stage]
		var cost := Time.get_ticks_usec()-stamp
		cpu += cost
		cpu_max = maxi(cpu_max,cost)
		peak_alive = maxi(peak_alive,arena.battle.enemies.size())
		if i%60==0:
			for enemy in arena.battle.enemies:
				if enemy.wave_route.is_empty(): arrivals[enemy.wave_entrance]=true
		await _frames(1)
		if i%600==599:
			print("WAVE_PROFILE: ",i+1," ",JSON.stringify(stages)," movement=",JSON.stringify(arena.battle.movement_profile))
	checks.full_wave_spawns_all_600 = waves.pending.is_empty() and waves.spawned_by_type.values().reduce(func(a,b): return a+b,0)==600
	checks.full_wave_reaches_all_three_sides = arrivals.size()==3
	checks.full_wave_crowd_capacity = peak_alive<=arena.battle.crowd.CAPACITY
	metrics.full_wave = {"peak_alive":peak_alive,"pending":waves.pending.size(),"arrived_sides":arrivals.keys(),"mean_ai_spawn_ms":cpu/4500000.0,"max_ai_spawn_ms":cpu_max/1000.0}
	if DisplayServer.get_name()!="headless":
		await arena._capture(arena.verification_path("waves_combat.png"))
	await _clear()
	var passed: bool = checks.values().all(func(v): return v)
	var report := {"passed":passed,"checks":checks,"metrics":metrics}
	var file := FileAccess.open(arena.verification_path("waves_check.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	print("WAVES_CHECK: ",JSON.stringify(report))
	get_tree().quit(0 if passed else 1)
