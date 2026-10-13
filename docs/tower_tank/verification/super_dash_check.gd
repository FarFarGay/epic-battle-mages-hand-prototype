extends SceneTree
## Charge through actual deaths, then drive through a mixed pack and scenery.
const Geo = preload("res://scripts/geo.gd")
var arena
var dash
var checks := {}
var metrics := {}

func _initialize() -> void:
	_run.call_deferred()

func _frames(count: int) -> void:
	for i in count: await physics_frame

func _fresh() -> void:
	arena.battle.reset()
	arena.tank.reset_state()
	arena.tank.position = Vector3(0,0.04,5)
	arena.freeze = 0.0
	await _frames(2)

func _run() -> void:
	arena = load("res://main.tscn").instantiate()
	root.add_child(arena)
	if not arena.rendering_ready: await arena.rendering_prepared
	arena.set_physics_process(false)
	arena.battle.waves_enabled = false
	arena.test_aim = true
	dash = arena.tank.dash
	for target in arena.targets:
		target.collision_layer = 0
		target.queue_free()
	arena.targets.clear()
	for prop in arena.props.props:
		prop.collision_layer = 0
		prop.queue_free()
	arena.props.props.clear()
	await _fresh()
	dash._start(Vector3.FORWARD,8.0,true)
	checks.empty_meter_blocks_super = not dash.active and dash.super_count==0
	var enemy = arena.battle.spawn_enemy(Vector3(10,0,0))
	enemy.take_damage(1.0)
	checks.damage_without_death_no_charge = dash.super_charge==0
	enemy.take_damage(1000.0)
	checks.death_adds_charge = dash.super_charge==1
	enemy.take_damage(1000.0)
	arena.battle.killed(enemy)
	checks.death_only_counts_once = dash.super_charge==1
	for i in dash.SUPER_KILLS+5:
		enemy = arena.battle.spawn_enemy(Vector3(10,0,0))
		enemy.take_damage(1000.0,Vector3.ZERO,0.0,&"crew")
	checks.crew_kills_count_and_charge_caps = dash.super_charge==dash.SUPER_KILLS
	dash.tick(30.0)
	checks.charge_does_not_decay = dash.super_ready()
	dash.cancel()
	checks.cancel_keeps_charge = dash.super_ready()
	dash.mode = dash.Mode.AIMING
	arena.ground_aim_position = arena.tank.position
	dash.commit()
	dash.tick(1.0/60)
	checks.zero_distance_does_not_spend = dash.super_ready() and not dash.active
	await _fresh()
	checks.reset_clears_charge = dash.super_charge==0
	enemy = arena.battle.spawn_enemy(Vector3(10,0,0),false,false,&"bomber")
	enemy.take_damage(1000.0,Vector3.ZERO,0.0,&"self_destruct")
	checks.bomber_suicide_no_charge = dash.super_charge==0
	await _fresh()
	for z in [2.0,-1.0,-4.0]:
		for x in [-0.8,0.8]: arena.battle.spawn_enemy(Vector3(x,0,z))
	var brute = arena.battle.spawn_enemy(Vector3(0,0,-1),true)
	var flank = arena.battle.spawn_enemy(Vector3(2.8,0,-1))
	var high = arena.battle.spawn_enemy(Vector3(0,5,-1))
	high.position.y = 5.0
	var far = arena.battle.spawn_enemy(Vector3(7,0,-1))
	var brute_hp: float = brute.hp
	await _frames(2)
	dash.super_charge = dash.SUPER_KILLS
	arena.focus = Vector3(0,0,-1)
	arena._update_camera(1.0)
	await arena._capture(arena.verification_path("super_dash_ready.png"))
	dash._start(Vector3.FORWARD,11.0,true)
	checks.start_spends_once = dash.super_charge==0 and arena.tank.collision_mask==1
	var max_us := 0
	for i in 24:
		var stamp := Time.get_ticks_usec()
		if dash.active: dash.move(1.0/60)
		max_us = maxi(max_us,Time.get_ticks_usec()-stamp)
		await physics_frame
	checks.mixed_pack_passed = not dash.active and absf(arena.tank.position.z+6.0)<0.1
	checks.weak_skeletons_killed = arena.battle.kills==6
	checks.ram_kills_recharge = dash.super_charge==6
	checks.brute_hit_once = is_equal_approx(brute.hp,brute_hp-dash.SUPER_DAMAGE)
	checks.brute_knocked_down = brute.knockdown_left>0.8 and brute.state==brute.State.STAGGER
	checks.flank_knocked_down_without_damage = flank.knockdown_left>1.0 and is_equal_approx(flank.hp,flank.max_hp)
	checks.other_floor_untouched = is_equal_approx(high.hp,high.max_hp) and high.knockdown_left==0.0
	checks.outside_corridor_untouched = is_equal_approx(far.hp,far.max_hp) and far.knockdown_left==0.0
	checks.collision_restored_on_finish = arena.tank.collision_mask==65
	brute.take_damage(1.0,Vector3.RIGHT,6.0)
	checks.chip_hit_does_not_wake_brute = brute.timer>=brute.knockdown_left
	brute.target = arena.tank
	arena.battle._update_neighbors()
	var attack_count: int = brute.attacks
	for i in 25:
		brute.tick(1.0/60)
		flank.tick(1.0/60)
	checks.recovery_window_blocks_attacks = brute.attacks==attack_count and brute.state==brute.State.STAGGER
	checks.knockdown_visible = brute.visual.rotation.x<-1.0 and flank.visual.rotation.x<-1.0
	await arena._capture(arena.verification_path("super_dash_after.png"))
	for i in 60: brute.tick(1.0/60)
	checks.brute_gets_up = brute.knockdown_left==0.0 and absf(brute.visual.rotation.x)<0.1
	metrics.mixed_pack_max_sweep_ms = max_us/1000.0
	await _fresh()
	# A parallel wall separates a nearby skeleton from the widened corridor.
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	arena.add_child(wall)
	Geo.collider(wall,Vector3(0.2,4,10),Vector3(2,2,0))
	var sheltered = arena.battle.spawn_enemy(Vector3(2.8,0,0))
	await _frames(2)
	dash.super_charge = dash.SUPER_KILLS
	dash._start(Vector3.FORWARD,8.0,true)
	for i in 20:
		if dash.active: dash.move(1.0/60)
		await physics_frame
	checks.sweep_does_not_hit_through_wall = sheltered.knockdown_left==0.0 and sheltered.hp==sheltered.max_hp
	wall.queue_free()
	await _fresh()
	arena.tank.position = Vector3(0,0.04,24)
	dash.super_charge = dash.SUPER_KILLS
	dash._start(Vector3.BACK,11.0,true)
	for i in 24:
		if dash.active: dash.move(1.0/60)
		await physics_frame
	checks.super_stops_at_wall = not dash.active and arena.tank.position.z<27.2 and arena.tank.collision_mask==65
	await _fresh()
	dash.super_charge = dash.SUPER_KILLS
	dash._start(Vector3.FORWARD,8.0,true)
	dash.cancel()
	checks.cancel_restores_collision_without_refund = arena.tank.collision_mask==65 and dash.super_charge==0
	await _fresh()
	for i in 600:
		arena.battle.spawn_enemy(Vector3((i%30-14.5)*1.1,0,2.5-(i/30)*1.1),i%60==0,i%7==0)
	arena.battle._rebuild_navigation()
	await _frames(2)
	dash.super_charge = dash.SUPER_KILLS
	dash._start(Vector3.FORWARD,dash.SUPER_DISTANCE,true)
	var max_tick := 0
	max_us = 0
	for i in 120:
		arena.tank.hp = arena.tank.MAX_HP
		var stamp := Time.get_ticks_usec()
		arena.tank.tick(1.0/60)
		max_us = maxi(max_us,Time.get_ticks_usec()-stamp)
		stamp = Time.get_ticks_usec()
		arena.battle.tick(1.0/60)
		max_tick = maxi(max_tick,Time.get_ticks_usec()-stamp)
		await physics_frame
	checks.dense_crowd_breakthrough = not dash.active and arena.tank.position.z<-5.5 and arena.battle.kills>=20
	checks.dense_crowd_charge_capped = dash.super_charge<=dash.SUPER_KILLS
	metrics.dense_crowd = {"kills":arena.battle.kills,"tank_max_ms":max_us/1000.0,"ai_max_ms":max_tick/1000.0,"charge":dash.super_charge}
	var passed := true
	for value in checks.values(): passed = passed and value
	var report := {"passed":passed,"checks":checks,"metrics":metrics}
	var file := FileAccess.open(arena.verification_path("super_dash_check.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	print("SUPER_DASH_CHECK: ",JSON.stringify(report))
	quit(0 if passed else 1)
