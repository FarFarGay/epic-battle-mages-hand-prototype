extends Node
var arena
var level
var tank
var crew
var hand
var checks := {}
var metrics := {}
const ACTIONS := ["tank_forward","tank_reverse","tank_left","tank_right"]

func _ready() -> void:
	arena = get_parent()
	level = arena.level
	tank = arena.tank
	crew = arena.crew
	hand = arena.hand
	if OS.get_cmdline_user_args().has("--bridge-door-preview"): _preview_bridge_door.call_deferred()
	elif OS.get_cmdline_user_args().has("--level-preview"): _preview.call_deferred()
	else: _run.call_deferred()

func _frames(count: int) -> void:
	for i in count: await get_tree().physics_frame

func _checkpoint(stage: String) -> void:
	var file := FileAccess.open(arena.verification_path("level_progress.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"stage":stage,"checks":checks,"metrics":metrics},"  "))
	file.close()

func _stop() -> void:
	for action in ACTIONS+["tank_fire","tank_cruise"]: Input.action_release(action)

func _place_tank(pos: Vector3) -> void:
	_stop()
	pos.y=arena.ground_height(pos)
	tank.position = pos+Vector3.UP*0.04
	tank.velocity=Vector3.ZERO
	tank.stop_drive()
	tank.kick_velocity = Vector3.ZERO
	tank.walker.reset_pose()
	arena.focus = pos
	arena.aim_position = pos+Vector3(8,0,-8)
	arena._update_camera(1.0)
	await _frames(4)

func _place_crew(pos: Vector3) -> void:
	_stop()
	crew.anchor = pos
	crew.motion = Vector3.ZERO
	crew.facing = Vector3.FORWARD
	for i in crew.members.size():
		crew.members[i].position = pos+crew._slot(i,Vector3.FORWARD)+Vector3.UP*0.04
		crew.members[i].position.y=arena.ground_height(crew.members[i].position)+0.04
		crew.members[i].velocity = Vector3.ZERO
		crew.members[i].knockback = Vector3.ZERO

func _move(goal: Vector3, frames: int = 180, cruise: bool = false) -> void:
	for i in frames:
		var offset: Vector3 = goal-crew.center()
		offset.y = 0
		if offset.length() < 0.45: break
		var direction := offset.normalized()
		var right: Vector3 = arena.aim_camera.global_basis.x
		var back: Vector3 = arena.aim_camera.global_basis.z
		right.y = 0
		back.y = 0
		var x := direction.dot(right.normalized())
		var y := direction.dot(back.normalized())
		_stop()
		if cruise: Input.action_press("tank_cruise")
		Input.action_press("tank_right" if x>0 else "tank_left",absf(x))
		Input.action_press("tank_reverse" if y>0 else "tank_forward",absf(y))
		await _frames(1)
	_stop()
	await _frames(25)

func _point(pos: Vector3, frames: int = 4) -> void:
	for i in frames:
		hand.test_pointer = arena.aim_camera.unproject_position(pos)
		await _frames(1)

func _mouse(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = hand.test_pointer
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _bridge_drop(offset: Vector3, yaw: float) -> bool:
	hand.cancel_drag()
	hand.puzzle.reset()
	arena.camera_yaw = yaw
	await _place_tank(Vector3(-145,0,0))
	hand.set_enabled(true)
	await _frames(3)
	await _point(hand.puzzle.cube.global_position)
	_mouse(true)
	await _frames(3)
	var grabbed: bool = hand.held == hand.puzzle.cube
	await _point(hand.puzzle.socket_position+offset,14)
	var preview: bool = hand.snap_destination=="socket"
	metrics["mouse_drop_%s_%s"%[offset,yaw]] = {"grabbed":grabbed,"preview":preview,"surface":str(hand.cursor_surface),"cargo":str(hand.puzzle.cube.position)}
	_mouse(false)
	await _frames(4)
	return grabbed and preview and hand.puzzle.opened and hand.held==null

func _view(pos: Vector3, zoom: float, filename: String) -> void:
	if DisplayServer.get_name() == "headless": return
	arena.set_physics_process(false)
	arena.set_process(false)
	arena.hud.hide()
	arena.camera.position = pos+Vector3(1,1.3,1).normalized()*zoom/(2*tan(deg_to_rad(arena.camera.fov*0.5)))
	arena.camera.look_at(pos)
	arena.camera.size = zoom
	arena.camera.far = 1000
	await arena._capture(arena.verification_path(filename))
	arena.hud.show()
	arena.set_physics_process(true)
	arena.set_process(true)
	arena._update_camera(1.0)

func _preview() -> void:
	await _frames(70)
	level.automatic_encounters=false
	arena.test_aim=true
	await _frames(12)
	await arena._capture(arena.verification_path("level_07_gameplay.png"))
	await _view(Vector3(-54,0,0),305,"level_01_overview.png")
	await _view(level.A,45,"level_03_puzzle.png")
	await _view(level.B,44,"level_04_dungeon.png")
	await _view(level.C,72,"level_05_mine.png")
	await _place_tank(level.C+Vector3(-19,0,0))
	await _frames(30)
	await arena._capture(arena.verification_path("level_08_plateau_play.png"))
	get_tree().quit()

func _check_entry_attack() -> void:
	level.automatic_encounters = true
	await _frames(32)
	var battle=arena.battle
	checks.entry_240_mixed=_entry_enemies().size()==240 and _entry_enemies().all(func(e): return not e.giant)
	checks.entry_200_regular_40_guards=_entry_enemies().filter(func(e): return e.shield_guard and e.shield_hp==24.0).size()==40 and _entry_enemies().filter(func(e): return not e.shield_guard).size()==200
	checks.entry_guards_spread_along_wave=[0,1,2,3].all(func(i): return _entry_enemies().filter(func(e): return e.shield_guard and e.position.x-level.START.x>=24+i*12 and e.position.x-level.START.x<36+i*12).size()>=6)
	battle.crowd.update_instances()
	checks.entry_shields_batched=battle.crowd.shields.visible_instance_count>0 and battle.crowd.shields.visible_instance_count==battle.crowd.guard_gear.visible_instance_count
	checks.offscreen_wave_actors_culled=battle.crowd.bodies.visible_instance_count<battle.enemies.size()
	# Check culling independently of its implementation: a wide overhead view
	# contains every actor, a camera away from the map contains none, then return.
	var camera: Camera3D = arena.camera
	var saved_transform := camera.global_transform
	var saved_projection := camera.projection
	var saved_size := camera.size
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 550.0
	camera.position = Vector3(0,200,0)
	camera.look_at(Vector3.ZERO,Vector3.FORWARD)
	battle.crowd.update_instances()
	var guards: int = battle.enemies.filter(func(e): return e.shield_guard and e.shield_hp>0.0).size()
	checks.overhead_view_keeps_every_actor=battle.crowd.bodies.visible_instance_count==battle.enemies.size() and battle.crowd.shields.visible_instance_count==guards
	camera.position.x = 10000.0
	battle.crowd.update_instances()
	checks.offscreen_culling_keeps_simulation=battle.crowd.bodies.visible_instance_count==0 and _entry_enemies().size()==240
	camera.projection = saved_projection
	camera.size = saved_size
	camera.global_transform = saved_transform
	battle.crowd.update_instances()
	checks.returning_camera_restores_crowd=battle.crowd.bodies.visible_instance_count>0 and battle.crowd.shields.visible_instance_count>0
	checks.entry_inside_corridor=_entry_enemies().all(func(e): return e.position.x>level.START.x+10 and e.position.x<-140 and absf(e.position.z)<9 and e.position.y>-0.1)
	checks.entry_whole_wave_pursues=_entry_enemies().all(func(e): return e.attack_on_spawn and e.target==tank)
	var depths: Array = _entry_enemies().map(func(e): return e.position.x-level.START.x)
	metrics.entry_front_distance=depths.min()
	metrics.entry_tail_distance=depths.max()
	checks.entry_opening_distance=depths.min()>24 and depths.min()<27
	checks.entry_column_spans_corridor=depths.max()-depths.min()>44 and [0,1,2,3].all(func(i): return depths.filter(func(d): return d>=24+i*12 and d<36+i*12).size()>=40)
	var visible := Rect2(Vector2(24,24),arena.get_viewport().get_visible_rect().size-Vector2(48,160))
	checks.entry_front_visible_at_spawn=_entry_enemies().filter(func(e): return not arena.aim_camera.is_position_behind(e.position) and visible.has_point(arena.aim_camera.unproject_position(e.position+Vector3.UP))).size()>=12
	await arena._capture(arena.verification_path("level_15_wave_start.png"))
	var starts: Dictionary={}
	for enemy in _entry_enemies(): starts[enemy.get_instance_id()]=enemy.position
	await _frames(300)
	# A detour around the central powder can start sideways; every active actor
	# must move, and later must actually gain ground toward the tower.
	checks.entry_active_rows_advance=_entry_enemies().all(func(e): return e.position.distance_to(starts[e.get_instance_id()])>1.0)
	checks.entry_has_time_to_open_fire=is_equal_approx(tank.hp,tank.MAX_HP)
	metrics.entry_moving_count=_entry_enemies().filter(func(e): return e.position.distance_to(starts[e.get_instance_id()])>1).size()
	var lanes: Array = _entry_enemies().map(func(e): return e.position.z)
	lanes.sort()
	metrics.entry_middle_80_percent_width=lanes[ceili(lanes.size()*0.9)-1]-lanes[floori(lanes.size()*0.1)]
	checks.entry_keeps_broad_front=metrics.entry_middle_80_percent_width>10.0
	checks.entry_neighbors_cover_rear=_entry_enemies().all(func(e): return e.position.x>battle.neighbor_origin.x+battle.CROWD_CELL and e.position.x<battle.neighbor_origin.x+(battle.neighbor_width-1)*battle.CROWD_CELL)
	metrics.entry_delayed=_entry_enemies().filter(func(e): return e.position.distance_to(starts[e.get_instance_id()])<=1).map(func(e): return {"start":str(starts[e.get_instance_id()]),"now":str(e.position),"flow":str(e.move_direction),"velocity":str(e.velocity)})
	await arena._capture(arena.verification_path("level_09_entry_attack.png"))
	await _view(level.START+Vector3(35,0,0),78,"level_10_entry_crowd.png")
	# Cursor stays before the crowd: RMB must shoot along the corridor anyway.
	arena.aim_position = tank.global_position + Vector3(3,0,0)
	await _frames(45)
	var count_before: int = _entry_enemies().size()
	tank.crossbows.trigger(true)
	await _frames(180)
	tank.crossbows.trigger(false)
	await _frames(40)
	metrics.entry_crossbow_kills = count_before - _entry_enemies().size()
	checks.entry_directional_burst_hits_crowd = metrics.entry_crossbow_kills >= 3 and tank.crossbows.hit_count >= 12
	await arena._capture(arena.verification_path("level_11_directional_burst.png"))
	for i in 900:
		await _frames(1)
		var all_progressed: bool = _entry_enemies().all(func(e): return e.position.distance_to(tank.position)<starts[e.get_instance_id()].distance_to(tank.position)-1.0)
		if tank.hp<tank.MAX_HP and all_progressed: break
	checks.entry_reaches_and_attacks=tank.hp<tank.MAX_HP and _entry_enemies().any(func(e): return e.hits>0)
	metrics.entry_tower_hp=tank.hp
	checks.entry_stays_on_corridor=_entry_enemies().all(func(e): return e.position.y>-0.2 and absf(e.position.z)<10)
	checks.entry_all_active_make_progress=_entry_enemies().all(func(e): return e.position.distance_to(tank.position)<starts[e.get_instance_id()].distance_to(tank.position)-1.0)
	metrics.entry_late_delayed=_entry_enemies().filter(func(e): return e.position.distance_to(tank.position)>=starts[e.get_instance_id()].distance_to(tank.position)-1.0).map(func(e): return {"start":str(starts[e.get_instance_id()]),"now":str(e.position),"flow":str(e.move_direction),"velocity":str(e.velocity)})
	# An aimed opening at powder should remove a meaningful slice of the wave.
	arena.reset_range()
	await _frames(32)
	arena.aim_position = level.entry_barrel_positions[0]+Vector3.UP*0.95
	await _frames(35)
	tank.crossbows.trigger(true)
	for frame in 240:
		await _frames(1)
		if _entry_barrels().size()<=8: break
	tank.crossbows.trigger(false)
	await _frames(30)
	metrics.entry_opening_kills = battle.kills
	checks.entry_powder_opening_thins_wave = _entry_barrels().size()<=8 and battle.kills>=12
	checks.entry_powder_opening_uses_only_repeaters = tank.shot_count==0 and tank.crossbows.shot_count>0
	checks.entry_survivors_keep_advancing = _entry_enemies().all(func(e): return e.attack_on_spawn and e.target==tank)
	await arena._capture(arena.verification_path("level_14_powder_opening.png"))
	# The remaining fixtures exercise the bridge and atolls in isolation.
	level.automatic_encounters = false
	arena.reset_range()
	level.cancel_spawning()
	battle.reset()
	await _frames(6)

func _entry_enemies() -> Array:
	return arena.battle.enemies.filter(func(e): return not e.world_resident)

func _check_world_population() -> void:
	var battle=arena.battle
	checks.world_generated_on_first_launch=level.world_spawn_positions.size()==120 and not level.world_population_pending
	var initial_layout: Array = level.world_spawn_positions.duplicate()
	level.automatic_encounters=false
	arena.set_physics_process(false)
	await _frames(2)
	while not level.spawn_queue.is_empty(): level._spawn_batch()
	var residents: Array = battle.enemies.filter(func(e): return e.world_resident)
	checks.world_initial_population=residents.size()==120 and _entry_enemies().size()==240
	checks.world_population_types=residents.filter(func(e): return e.shield_guard).size()==15 and residents.filter(func(e): return not e.shield_guard and not e.giant).size()==105
	checks.world_starts_off_atolls=residents.all(func(e): return absf(level.ground_height(e.position))<0.01 and level._world_spawn_open(Vector3(e.position.x,0,e.position.z)))
	var nearest := INF
	var regions := PackedInt32Array()
	regions.resize(9)
	regions.fill(0)
	var originals := {}
	for i in residents.size():
		var enemy=residents[i]
		originals[enemy.get_instance_id()]=enemy.position
		var column := clampi(int((enemy.position.x+120)/80),0,2)
		var row := clampi(int((enemy.position.z+78)/52),0,2)
		regions[row*3+column]+=1
		for j in range(i+1,residents.size()): nearest=minf(nearest,enemy.position.distance_to(residents[j].position))
	metrics.world_regions=Array(regions)
	metrics.world_min_spacing=nearest
	checks.world_spread_across_map=Array(regions).all(func(count): return count>=6)
	checks.world_no_spawn_piles=nearest>4.4
	checks.world_exit_is_populated=residents.any(func(e): return e.position.x>128)
	checks.world_door_landing_clear=residents.all(func(e): return e.position.x>-113)
	for enemy in _entry_enemies():
		enemy.collision_layer=0
		battle.enemies.erase(enemy)
		enemy.queue_free()
	arena.set_physics_process(true)
	var travelled := {}
	var previous := originals.duplicate()
	var stays_off_atolls := true
	for enemy in residents: travelled[enemy.get_instance_id()]=0.0
	for sample in 50:
		await _frames(12)
		for enemy in residents:
			var id: int = enemy.get_instance_id()
			travelled[id]+=enemy.position.distance_to(previous[id])
			previous[id]=enemy.position
			stays_off_atolls=stays_off_atolls and absf(level.ground_height(enemy.position))<0.01 and level._world_spawn_open(Vector3(enemy.position.x,0,enemy.position.z))
	metrics.world_patrol_moving=residents.filter(func(e): return travelled[e.get_instance_id()]>2.0).size()
	checks.world_distant_population_patrols=metrics.world_patrol_moving>=114 and residents.all(func(e): return not is_instance_valid(e.target))
	checks.world_patrol_avoids_atolls=stays_off_atolls
	checks.world_patrol_keeps_local_routes=residents.all(func(e): return e.position.distance_to(e.patrol_origin)<=14.1)
	await _check_patrol_obstacle(residents)
	await _view(Vector3(0,0,0),250,"level_20_world_population.png")
	var candidate
	var approach := Vector3.ZERO
	for enemy in residents:
		approach=enemy.position+Vector3(12,-enemy.position.y,0)
		if not level._world_spawn_open(approach): continue
		var ray := PhysicsRayQueryParameters3D.create(enemy.position+Vector3.UP,approach+Vector3.UP,1|32)
		if arena.get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			candidate=enemy
			break
	checks.world_has_open_approach=candidate!=null
	if candidate:
		await _place_tank(approach)
		var before: float = candidate.position.distance_to(tank.position)
		await _frames(75)
		checks.world_nearby_skeleton_engages=candidate.target==tank and candidate.position.distance_to(tank.position)<before-1.0
	var far = residents.filter(func(e): return e.position.distance_to(tank.position)>60)[0]
	far.take_damage(1.0)
	await _frames(30)
	checks.world_long_range_hit_provokes=far.attack_on_spawn and far.target==tank
	arena.reset_range()
	await _frames(2)
	checks.world_reset_restores_same_layout=level.world_spawn_positions==initial_layout

func _check_patrol_obstacle(residents: Array) -> void:
	var walker
	var start := Vector3.ZERO
	for enemy in residents:
		start=enemy.patrol_origin
		var excluded: Array[RID] = [enemy.get_rid()]
		if not level._world_spawn_open(start+Vector3.RIGHT*10,excluded): continue
		var ray := PhysicsRayQueryParameters3D.create(start+Vector3.UP,start+Vector3.RIGHT*10+Vector3.UP,1|32)
		if arena.get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			walker=enemy
			break
	if not walker:
		checks.world_patrol_detours_around_prop=false
		return
	walker.position=start
	var obstacle := start+Vector3.RIGHT*4
	obstacle.y=0.0
	var prop=arena.props.spawn_prop(obstacle,1)
	await _frames(2)
	walker.patrol_goal=start+Vector3.RIGHT*10
	walker.patrol_wait=0.0
	var clearance := INF
	var progress := 0.0
	var sideways := 0.0
	for sample in 50:
		await _frames(12)
		clearance=minf(clearance,Vector2(walker.position.x-obstacle.x,walker.position.z-obstacle.z).length())
		progress=maxf(progress,walker.position.x-start.x)
		sideways=maxf(sideways,absf(walker.position.z-start.z))
	metrics.world_patrol_obstacle={"clearance":clearance,"progress":progress,"sideways":sideways}
	checks.world_patrol_detours_around_prop=clearance>0.8 and progress>6.0 and sideways>0.7
	checks.world_patrol_leaves_props_intact=arena.props.props.has(prop) and not prop.get_meta("broken")

func _entry_barrels() -> Array:
	return arena.targets.filter(func(t): return t.get_meta("spec",{}).get("entry_supply",false))

func _check_bridge_door() -> void:
	var door = level.bridge_door
	checks.bridge_door_stops_walking = not door.broken and tank.position.x<door.global_position.x-1.2
	checks.bridge_door_after_far_bank = door.global_position.x> -128.0 and door.global_position.x< -120.0
	await _place_tank(door.global_position+Vector3(-6,0,0))
	arena.aim_position = door.global_position+Vector3.UP*2.3
	await _frames(90)
	await arena._capture(arena.verification_path("level_18_bridge_door.png"))
	tank.crossbows.trigger(true)
	await _frames(30)
	tank.crossbows.trigger(false)
	tank.cooldown = 0.0
	tank.fire()
	await _frames(60)
	checks.bridge_door_survives_both_guns = not door.broken and door.collision_layer==1 and tank.shot_count>0 and tank.crossbows.shot_count>0
	await _place_tank(door.global_position+Vector3(-4.4,0,0))
	tank.dash._start(Vector3.RIGHT,tank.dash.DISTANCE,false)
	await _frames(40)
	checks.bridge_door_survives_normal_dash = not door.broken and tank.position.x<door.global_position.x-1.2
	# Commit uses the preview result, so a truncated marker would stop the dash
	# before impact even if the collision handler itself could break the door.
	await _place_tank(door.global_position+Vector3(-6,0,0))
	arena.aim_position = door.global_position+Vector3(6,0,0)
	arena.ground_aim_position = arena.aim_position
	var preview: Vector3 = tank.dash.landing_point(arena.ground_aim_position)
	checks.bridge_door_preview_reaches_other_side = preview.x>door.global_position.x+3 and not tank.dash.preview_blocked
	metrics.bridge_door_preview = str(preview)
	tank.dash.mode = tank.dash.Mode.AIMING
	checks.bridge_door_super_commit = tank.dash.commit()
	await _frames(45)
	checks.bridge_door_breaks_on_super_dash = door.broken and door.collision_layer==0 and not door.panels.visible
	checks.bridge_door_dash_continues_through = tank.position.x>door.global_position.x+3
	metrics.bridge_door_dash_end = str(tank.position)
	checks.bridge_door_open_ray = arena.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(door.global_position+Vector3(-2,2,0),door.global_position+Vector3(2,2,0),1)).is_empty()
	await arena._capture(arena.verification_path("level_19_bridge_door_broken.png"))
	# The rest of the palisade must remain solid even to a super dash.
	await _place_tank(door.global_position+Vector3(-3,0,6))
	var side_preview: Vector3 = tank.dash.landing_point(tank.position+Vector3.RIGHT*11.56)
	tank.dash._start(Vector3.RIGHT,11.56,true)
	await _frames(45)
	checks.bridge_fence_stops_super_dash = side_preview.x<door.global_position.x-1.2 and tank.position.x<door.global_position.x-1.2

func _preview_bridge_door() -> void:
	level.automatic_encounters = false
	level.cancel_spawning()
	arena.battle.reset()
	arena.test_aim = true
	await _frames(8)
	hand.puzzle.seat(hand.puzzle.cube)
	arena.camera_yaw = -PI/4
	await _place_tank(level.bridge_door.global_position+Vector3(-6,0,0))
	await _check_bridge_door()
	var passed := checks.values().all(func(value): return value)
	print("BRIDGE_DOOR_PREVIEW: ",JSON.stringify({"passed":passed,"checks":checks}))
	get_tree().quit(0 if passed else 1)

func _entry_props() -> Array:
	return arena.props.props.filter(func(p): return p.get_meta("entry_supply",false))

func _check_entry_supplies() -> void:
	var barrels := _entry_barrels()
	checks.entry_supply_counts = barrels.size()==12 and _entry_props().size()==48
	checks.entry_supply_variety = _entry_props().any(func(p): return p.get_meta("kind")==1) and _entry_props().any(func(p): return p.get_meta("kind")==2)
	checks.barricades_cross_travel_lanes=_entry_props().filter(func(p): return absf(p.position.z)<4).size()>=20
	checks.barricades_have_turns=_entry_props().any(func(p): return p.rotation.y>0.15) and _entry_props().any(func(p): return p.rotation.y< -0.15)
	var first: Node3D = barrels[0]
	var second: Node3D = barrels[1]
	var first_pos := first.global_position
	var second_pos := second.global_position
	var victims: Array[Node3D] = []
	for pos in [first_pos+Vector3(0,0,2),first_pos+Vector3(1.5,0,1.5),second_pos+Vector3(0,0,3)]:
		var enemy = arena.battle.spawn_enemy(pos)
		enemy.move_speed = 0.0
		victims.append(enemy)
	arena.aim_position = first_pos+Vector3.UP*0.65
	await _frames(90)
	tank.cooldown = 0.0
	tank.fire()
	await _frames(24)
	await arena._capture(arena.verification_path("level_12_supply_chain.png"))
	await _frames(65)
	checks.entry_cannon_detonates_powder = not is_instance_valid(first)
	checks.entry_powder_pair_chains = not is_instance_valid(second)
	checks.entry_blast_kills_skeletons = victims.all(func(e): return not is_instance_valid(e) or e.dead)
	metrics.entry_chain_props_destroyed = 48-_entry_props().size()
	checks.entry_blast_breaks_supplies = metrics.entry_chain_props_destroyed >= 2
	checks.entry_chain_stays_local = _entry_barrels().size()==8
	# Driving through ordinary supplies must crush them and leave a usable route.
	var crate: Node3D = _entry_props().filter(func(p): return p.get_meta("kind")==1)[0]
	var crate_pos := crate.global_position
	await _place_tank(crate_pos+Vector3(-4,0,0))
	await _move(crate_pos+Vector3(3,0,0),120)
	checks.entry_steps_crush_crates = not is_instance_valid(crate)
	arena.reset_range()
	level.cancel_spawning()
	arena.battle.reset()
	await _frames(6)
	checks.entry_reset_restores_supplies = _entry_barrels().size()==12 and _entry_props().size()==48

func _check_coins() -> void:
	var loot = crew.loot
	var samples: Array[RigidBody3D] = []
	var points := [level.START+Vector3(7,0,-6),level.START+Vector3(11,0,6),level.A+Vector3(3,0,7),level.A+Vector3(-25,0,0)]
	for i in points.size():
		var point: Vector3 = points[i]
		point.y = arena.ground_height(point)+(10.0 if i==1 else 1.2)
		loot.spawn_coin(point,Vector3(0,-28,0) if i==1 else Vector3(0.35,3.0,0.2))
		samples.append(loot.loose_coins.back())
	var bounced := false
	var falling := false
	for i in 600:
		await _frames(1)
		if samples[0].linear_velocity.y < -0.5: falling = true
		if falling and samples[0].linear_velocity.y > 0.3: bounced = true
	var bottoms: Array = []
	for coin in samples:
		var mesh: MeshInstance3D = coin.get_child(1)
		# Compare with the supporting plane, also on slopes (not with a
		# horizontal plane passing through the middle of a slanted coin).
		var p := coin.position
		var slope_x: float = (arena.ground_height(p+Vector3.RIGHT*0.2)-arena.ground_height(p-Vector3.RIGHT*0.2))/0.4
		var slope_z: float = (arena.ground_height(p+Vector3.BACK*0.2)-arena.ground_height(p-Vector3.BACK*0.2))/0.4
		var normal := Vector3(-slope_x,1,-slope_z).normalized()
		var vertical := absf(mesh.global_basis.y.normalized().dot(normal))
		var extent := 0.17*sqrt(maxf(0.0,1.0-vertical*vertical))+0.035*vertical
		bottoms.append((coin.position.y-arena.ground_height(coin.position))*normal.y-extent)
	metrics.coin_surface_clearance = bottoms
	metrics.coin_bounced = bounced
	metrics.coin_rest_speeds = samples.map(func(c): return c.linear_velocity.length())
	checks.coins_stay_above_terrain=bottoms.all(func(y): return y>=-0.015 and y<0.10)
	checks.coins_bounce_then_settle=bounced and samples.all(func(c): return c.linear_velocity.length()<0.15)
	checks.coins_settle_flat_on_level_ground=[0,1,2].all(func(i): return absf(samples[i].get_child(1).global_basis.y.normalized().y)>0.9)
	await arena._capture(arena.verification_path("level_16_coins.png"))
	await _view(samples[0].position,2.5,"level_17_coin_close.png")
	# Collection after resting must preserve the accumulated value.
	var total_before: int = loot.coins
	await _place_tank(samples[0].position+Vector3(0,0,1.6))
	await _frames(100)
	checks.settled_coins_can_be_collected=loot.coins>total_before
	arena.reset_range()
	level.cancel_spawning()
	arena.battle.reset()
	await _frames(6)

func _run() -> void:
	await _frames(8)
	await _check_world_population()
	level.automatic_encounters = false
	arena.test_aim = true
	checks.compact_hud_hides_crew_button=arena.hud.compact_mode() and not arena.hud.crew_button.visible
	var help := InputEventKey.new()
	help.keycode = KEY_F1
	help.physical_keycode = KEY_F1
	help.pressed = true
	Input.parse_input_event(help)
	Input.flush_buffered_events()
	await _frames(3)
	checks.hold_f1_shows_full_hud=not arena.hud.compact_mode() and arena.hud.crew_button.visible
	await arena._capture(arena.verification_path("level_13_help.png"))
	help = help.duplicate()
	help.pressed = false
	Input.parse_input_event(help)
	Input.flush_buffered_events()
	await _frames(3)
	checks.release_f1_restores_compact_hud=arena.hud.compact_mode() and not arena.hud.crew_button.visible
	await _check_entry_attack()
	await _check_entry_supplies()
	await _check_coins()
	checks.new_level_is_default = arena.desert_mode and level != null
	checks.layout_dimensions = arena.world_bounds == Rect2(-224,-88,388,176)
	checks.entry_shortened = level.ENTRY_LENGTH==96.0 and level.ENTRY_RECT.size.y==20.0
	checks.perspective_camera = arena.camera.projection==Camera3D.PROJECTION_PERSPECTIVE and arena.aim_camera.projection==Camera3D.PROJECTION_PERSPECTIVE
	checks.raised_atolls = level.ground_height(level.A)==4.0 and level.ground_height(level.B)==5.0 and level.ground_height(level.C)==4.0
	checks.open_plateau_edges=true
	for center in [level.A,level.B,level.C]:
		var half := 28.0 if center==level.C else 16.0
		var query := PhysicsRayQueryParameters3D.create(center+Vector3(0,2,half-2),center+Vector3(0,2,half+4),1)
		checks.open_plateau_edges = checks.open_plateau_edges and arena.get_world_3d().direct_space_state.intersect_ray(query).is_empty()
	metrics.atoll_gaps = {"A_B":level.A.distance_to(level.B)-32,"A_C":level.A.distance_to(level.C)-44,"B_C":level.B.distance_to(level.C)-44}
	checks.atoll_spacing_matches_pdf = absf(metrics.atoll_gaps.A_B-65)<2 and absf(metrics.atoll_gaps.A_C-70)<2 and absf(metrics.atoll_gaps.B_C-50)<2
	checks.world_population_replaces_road_spawns = level.encounters.is_empty() and not arena.battle.waves_enabled and arena.battle.enemies.is_empty()
	checks.full_ore_field = level.ore.size()>100
	checks.crew_can_exit_at_world_edge = crew.disembark()
	checks.small_crew_scale = is_equal_approx(crew.members[0].get_child(0).shape.height,0.7)
	checks.crew_can_board_at_world_edge = crew.board()
	await _view(Vector3(-54,0,0),305,"level_01_overview.png")
	await _view(Vector3((level.ENTRY_WEST-128)*0.5,0,0),100,"level_02_entry.png")
	await _move(Vector3(-145,0,0),800,true)
	checks.long_corridor_drive_through = tank.position.x>-147 and tank.position.y>-0.1
	checks.bridge_mouse_near_edge = await _bridge_drop(Vector3(-4,0,0),PI/4)
	checks.bridge_mouse_far_edge = await _bridge_drop(Vector3(4,0,0),PI/4)
	checks.bridge_mouse_rotated_camera = await _bridge_drop(Vector3(0,0,2.3),-PI/4)
	checks.bridge_mouse_corner = await _bridge_drop(Vector3(-4,0,-2.3),PI*0.75)
	checks.bridge_mouse_opposite_corner = await _bridge_drop(Vector3(4,0,2.3),PI*1.25)
	checks.bridge_mouse_outside_rejected = not await _bridge_drop(Vector3(-6,0,5),PI/4) and not hand.puzzle.opened
	hand.puzzle.cube.freeze = false
	hand.puzzle.cube.position = Vector3(-133,-2,7)
	await _frames(5)
	checks.bridge_returns_from_chasm = hand.puzzle.cube.position.distance_to(Vector3(-147,0.5,-6.5))<0.1 and not hand.puzzle.opened
	hand.puzzle.reset()
	hand.set_enabled(false)
	arena.camera_yaw = PI/4
	await _place_tank(Vector3(-142,0,0))
	await _move(Vector3(-133,0,0),100)
	checks.chasm_blocks_walking = tank.position.x < -139.0
	tank.dash._start(Vector3.RIGHT,11.56,true)
	await _frames(45)
	checks.chasm_blocks_superdash = tank.position.x < -139.0 and tank.position.y > -0.1
	await _place_tank(Vector3(-145,0,0))
	hand.set_enabled(true)
	await _frames(3)
	checks.bridge_can_be_grabbed = hand.grab(hand.puzzle.cube)
	await _point(hand.puzzle.socket_position,20)
	metrics.bridge_drag = {"pos":str(hand.held.position) if is_instance_valid(hand.held) else "null","snap":hand._snap_destination(),"surface":str(hand.cursor_surface)}
	checks.bridge_snap_over_void = hand._snap_destination()=="socket"
	hand._release(true,true)
	await _frames(4)
	checks.bridge_installed = hand.puzzle.opened and (level.bridge_body.collision_layer&1)!=0 and level.bridge_guards.all(func(e): return e.collision_layer==0)
	hand.set_enabled(false)
	await _move(Vector3(-122,0,0),280)
	checks.bridge_drive_through = tank.position.x > -128 and tank.position.y > -0.1
	await _check_bridge_door()
	# Item recovery and crew landing must use the full map, not the old 56 m range.
	await _place_tank(level.A+Vector3(-22,0,-8))
	await _move(level.A+Vector3(-11,0,-8),100)
	checks.low_tunnel_excludes_tower = tank.position.x < level.A.x-18
	hand.set_enabled(true)
	await _frames(3)
	checks.canopy_excludes_hand = not hand.grab(level.weight)
	checks.handle_locked_before_weight = not hand.grab(level.gate_handle)
	hand.set_enabled(false)
	await _place_tank(level.A+Vector3(-22,0,0))
	await _move(level.A,110)
	checks.closed_gate_excludes_tower = tank.position.x < level.A.x-17
	await _place_tank(level.A+Vector3(-22,0,0))
	checks.crew_exits_at_atoll_a = crew.disembark()
	_place_crew(level.A+Vector3(-21,0,-8))
	await _move(level.A+Vector3(-11,0,-8),160)
	metrics.tunnel_crew = str(crew.center()-level.A)
	metrics.tunnel_members = crew.members.map(func(m): return str(m.position-level.A))
	checks.crew_passes_low_tunnel = crew.members.all(func(m): return m.position.x>level.A.x-15)
	checks.weight_picked_by_crew = crew.loot.pickup_cargo(level.weight)
	await _move(level.A+Vector3(-8.5,0,-8),70)
	# The physical carrier stands off-centre in the formation; align the cargo itself.
	var correction: Vector3 = level.A+Vector3(-8.5,0,-8)-level.weight.position
	correction.y = 0
	await _move(crew.center()+correction,70)
	crew.loot.drop_cargo()
	await _frames(90)
	metrics.weight = str(level.weight.position-level.A)
	checks.weight_unlocks_only_not_opens = level.unlocked and not level.gate_open
	var resting_weight: Vector3 = level.weight.position
	level.weight.freeze = true
	level.weight.position += Vector3(0,0,3)
	await _frames(3)
	checks.removing_weight_relocks_handle = not level.unlocked and not level.gate_handle.can_hand_grab()
	level.weight.position = resting_weight
	level.weight.freeze = false
	await _frames(4)
	checks.cargo_stays_on_large_map = level.weight.position.distance_to(resting_weight)<0.1
	await _move(level.A+Vector3(-22,0,-8),210)
	checks.return_through_low_tunnel = crew.center().x<level.A.x-18
	checks.board_after_puzzle = crew.board()
	await _place_tank(level.A+Vector3(-22,0,0))
	hand.set_enabled(true)
	await _frames(3)
	checks.handle_available_after_weight = hand.grab(level.gate_handle)
	await _point(level.gate_handle.home+Vector3(-5,0,0),15)
	metrics.handle = str(level.gate_handle.global_position-level.gate_handle.home)
	hand.place_gently()
	await _frames(115)
	checks.hand_opens_gate = level.gate_open and level.gate.collision_layer==0
	level.weight.freeze = true
	level.weight.position += Vector3(0,0,3)
	await _frames(4)
	checks.open_gate_stays_latched_without_weight = level.gate_open and level.gate.collision_layer==0
	hand.set_enabled(false)
	await _move(level.A+Vector3(6,0,0),300)
	metrics.workbench_tower=str(tank.position-level.A)
	checks.tower_reaches_workbench = tank.position.distance_to(level.A+Vector3(6,0,0))<3
	tank.hp = 100
	tank.crossbows.ammo = 20
	level.interact("workbench")
	checks.workbench_services = tank.hp==1000 and tank.crossbows.ammo==200
	await _view(level.A,45,"level_03_puzzle.png")
	await _place_tank(level.B+Vector3(-36,0,4.5))
	await _move(level.B+Vector3(-8,0,4.5),330)
	checks.tower_climbs_b = tank.position.y>level.B.y-0.1 and tank.position.x>level.B.x-12
	await _frames(45)
	metrics.plateau_feet=tank.walker.legs.map(func(leg): return str(leg.foot.global_position-level.B))
	checks.feet_on_raised_ground = tank.walker.legs.all(func(leg): return absf(leg.foot.global_position.y-level.B.y)<0.1)
	checks.crew_exits_on_plateau = crew.disembark()
	checks.crew_spawns_on_plateau = crew.members.all(func(m): return m.position.y>level.B.y-0.1)
	checks.crew_boards_on_plateau = crew.board()
	var elevated_point: Vector3=level.B+Vector3(3,0,4)
	var elevated_pointer: Vector2=arena.aim_camera.unproject_position(elevated_point)
	var picked: Vector3=arena.terrain_point(arena.aim_camera.project_ray_origin(elevated_pointer),arena.aim_camera.project_ray_normal(elevated_pointer))
	checks.mouse_projects_to_plateau = picked.distance_to(elevated_point)<0.1
	var cargo=crew.loot.spawn_cargo(level.B+Vector3(-5,0,7),1)
	await _frames(30)
	hand.set_enabled(true)
	await _frames(3)
	checks.hand_grabs_on_plateau=hand.grab(cargo)
	await _point(level.B+Vector3(-4,0,7),12)
	hand.place_gently()
	await _frames(70)
	checks.cargo_rests_on_plateau=cargo.position.y>level.B.y and cargo.position.y<level.B.y+1
	hand.set_enabled(false)
	await _view(level.B,44,"level_04_dungeon.png")
	_checkpoint("B complete")
	await _move(level.B+Vector3(-36,0,4.5),350)
	checks.tower_descends_b=tank.position.x<level.B.x-34 and tank.position.y<0.2
	await _place_tank(level.C+Vector3(-21,0,0))
	_checkpoint("C enemy climb")
	var climber=arena.battle.spawn_enemy(level.C+Vector3(-42,0,0),false)
	await _frames(850)
	metrics.enemy_ramp=str(climber.position-level.C)
	checks.enemy_climbs_ramp=climber.position.x>level.C.x-28 and climber.position.y>level.C.y-0.1
	_checkpoint("C enemy reached plateau")
	arena.battle.reset()
	await _frames(3)
	var pot=arena.props.spawn_prop(level.C+Vector3(-19,0,0),0)
	await _move(level.C+Vector3(-17,0,0),90)
	checks.steps_break_props_on_plateau=not is_instance_valid(pot)
	_checkpoint("C stomp")
	var victim=arena.battle.spawn_enemy(level.C+Vector3(-3,0,0),false)
	victim.move_speed=0
	arena.aim_position=victim.position+Vector3.UP
	await _frames(90)
	tank.cooldown=0
	tank.fire()
	await _frames(70)
	checks.cannon_hits_on_plateau=not is_instance_valid(victim) or victim.dead
	_checkpoint("C cannon")
	arena.battle.reset()
	await _place_tank(level.C+Vector3(-35,0,8))
	var cliff_preview: Vector3=tank.dash.landing_point(tank.position+Vector3.RIGHT*11.56)
	_checkpoint("C dash preview")
	tank.dash._start(Vector3.RIGHT,11.56,true)
	await _frames(45)
	checks.cliff_stops_dash=tank.position.x<level.C.x-29 and tank.position.y<0.1
	checks.cliff_preview_matches=Vector2(cliff_preview.x-tank.position.x,cliff_preview.z-tank.position.z).length()<0.5
	await _place_tank(level.C+Vector3(-24,0,18))
	var dash_start: Vector3=tank.position
	var preview: Vector3=tank.dash.landing_point(tank.position+Vector3.LEFT*11.56)
	tank.dash._start(Vector3.LEFT,11.56,true)
	await _frames(45)
	metrics.ramp_dash={"start":str(dash_start-level.C),"preview":str(preview-level.C),"end":str(tank.position-level.C)}
	checks.superdash_descends_ramp=tank.position.x<level.C.x-34 and tank.position.y<level.C.y-1
	checks.dash_preview_follows_ramp=Vector2(preview.x-tank.position.x,preview.z-tank.position.z).length()<0.6
	tank.dash._start(Vector3.RIGHT,11.56,true)
	await _frames(45)
	checks.superdash_climbs_ramp=tank.position.x>level.C.x-26 and tank.position.y>level.C.y-0.1
	await _place_tank(level.C+Vector3(-16,0,-45))
	await _move(level.C+Vector3(-16,0,-25),260)
	checks.north_mine_ramp_works=tank.position.z>level.C.z-27 and tank.position.y>level.C.y-0.1
	await _place_tank(level.C+Vector3(-35,0,0))
	await _move(level.C+Vector3(-17,0,0),200)
	checks.main_mine_entry_fits_tower = tank.position.x>level.C.x-23
	checks.crew_exits_at_mine = crew.disembark()
	_place_crew(level.C+Vector3(-6,0,0))
	level.automatic_encounters = true
	var before: int = level.ore.size()
	await _move(level.C+Vector3(-1,0,0),165)
	checks.workers_mine_real_blocks = level.ore.size()<before and not crew.loot.loose_crystals.is_empty() and crew.loot.crystals==0
	checks.mining_emits_story_hook_without_auto_wave = level.mine_defense_started and level.defense_waves.events.has(&"first_ore_mined") and level.defense_waves.active==-1
	level.automatic_encounters = false
	level.mining = false
	var first = level.ore.front()
	before = level.ore.size()
	arena._explode(first.position+Vector3.UP,first)
	checks.cannon_mines_blocks = level.ore.size()<before
	await _view(level.C,72,"level_05_mine.png")
	# Run a real encounter far from the original origin, with the shared flow field.
	crew.crewed = true
	for member in crew.members: member.set_embarked(true)
	await _place_tank(Vector3(140,0,0))
	var enemy = arena.battle.spawn_enemy(Vector3(134,0,0),true)
	var distance_before: float = enemy.position.distance_to(tank.position)
	await _frames(120)
	checks.ai_works_beyond_old_range = enemy.position.distance_to(tank.position)<distance_before-1.0 and arena.battle.nav_origin.x>100
	checks.crowd_visible_on_large_map = arena.battle.crowd.bodies.visible_instance_count>0 and arena.battle.crowd.bodies.custom_aabb.has_point(enemy.position)
	await _frames(100)
	checks.old_small_mine_attack_replaced = level.defense_waves.active==-1 and level.spawn_queue.is_empty()
	before = arena.battle.enemies.size()
	level.automatic_encounters = true
	await _place_tank(Vector3(-115,0,19))
	await _frames(30)
	checks.approach_does_not_spawn_small_groups = level.encounters.is_empty() and arena.battle.enemies.size()==before and level.spawn_queue.is_empty()
	level.automatic_encounters = false
	await _place_tank(Vector3(155,0,0))
	checks.exit_reached = level.completed
	level.toggle_map()
	await arena._capture(arena.verification_path("level_06_map.png"))
	checks.map_toggle = level.map_view.visible
	arena.set_interface_visible(false)
	checks.interface_toggle_includes_map = not level.map_view.is_visible_in_tree()
	checks.interface_toggle_includes_world_labels = (arena.camera.cull_mask & hand.puzzle.label.layers)==0
	arena.set_interface_visible(true)
	arena.reset_range()
	await _frames(6)
	checks.reset_restores_level = not level.gate_open and not hand.puzzle.opened and level.mined==0 and level.ore.size()==level.ore_total and arena.battle.remaining()==360 and tank.position.distance_to(level.START)<0.1
	checks.reset_restores_bridge_door = not level.bridge_door.broken and level.bridge_door.collision_layer==1 and level.bridge_door.panels.visible
	await _frames(65)
	checks.reset_restores_exactly_240=_entry_enemies().size()==240 and level.spawn_queue.is_empty()
	checks.reset_restores_40_intact_shields=_entry_enemies().filter(func(e): return e.shield_guard and e.shield_hp==24.0).size()==40
	checks.reset_restores_advancing_wave=_entry_enemies().all(func(e): return e.attack_on_spawn and e.target==tank)
	checks.reset_restores_world_population=arena.battle.enemies.filter(func(e): return e.world_resident).size()==120
	await arena._capture(arena.verification_path("level_07_gameplay.png"))
	var passed := true
	for value in checks.values(): passed = passed and value
	var result := {"passed":passed,"checks":checks,"metrics":metrics}
	var file := FileAccess.open(arena.verification_path("level_check.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"  "))
	file.close()
	print("LEVEL_CHECK: ",JSON.stringify(result))
	get_tree().quit(0 if passed else 1)
