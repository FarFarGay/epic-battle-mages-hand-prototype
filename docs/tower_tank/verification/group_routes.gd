extends SceneTree
## Traverse both marked roads with the real tower and moving resident groups.
var arena
var checks := {}
var metrics := {}
const ACTIONS := ["tank_forward","tank_reverse","tank_left","tank_right","tank_cruise"]

func _initialize() -> void:
	_run.call_deferred()

func _frames(n: int) -> void:
	for i in n: await physics_frame

func _fresh() -> void:
	for action in ACTIONS: Input.action_release(action)
	arena.reset_range()
	arena.level.campaign.enabled = false
	for i in 300:
		if not arena.level.world_population_pending and not arena.level.groups_preparing and arena.level.spawn_queue.is_empty(): break
		await physics_frame
	for enemy in arena.battle.enemies.duplicate():
		if enemy.world_resident: continue
		enemy.collision_layer = 0
		arena.battle.enemies.erase(enemy)
		enemy.queue_free()
	arena.tank.position = Vector3(-114,0.04,0)
	arena.tank.stop_drive()
	arena.tank.walker.reset_pose()
	arena.focus = arena.tank.position
	arena.test_aim = true
	await _frames(3)

func _travel(route: Array, label: String) -> void:
	var reached := 0
	var alarmed := {}
	var count := 0
	var start := Time.get_ticks_usec()
	for goal in route:
		for frame in 600:
			var offset: Vector3 = goal-arena.tank.position
			offset.y = 0
			if offset.length() < 1.0:
				reached += 1
				break
			for action in ACTIONS: Input.action_release(action)
			var right: Vector3 = arena.aim_camera.global_basis.x
			var back: Vector3 = arena.aim_camera.global_basis.z
			right.y = 0
			back.y = 0
			var direction := offset.normalized()
			var x := direction.dot(right.normalized())
			var y := direction.dot(back.normalized())
			Input.action_press("tank_right" if x>=0 else "tank_left",absf(x))
			Input.action_press("tank_reverse" if y>=0 else "tank_forward",absf(y))
			Input.action_press("tank_cruise")
			arena.tank.hp = arena.tank.MAX_HP
			arena.aim_position = goal
			await physics_frame
			count += 1
			for i in arena.level.roaming_groups.groups.size():
				if arena.level.roaming_groups.groups[i].alarmed: alarmed[i] = true
	for action in ACTIONS: Input.action_release(action)
	metrics[label] = {"reached":reached,"waypoints":route.size(),"groups_alerted":alarmed.size(),"frames":count,"end":str(arena.tank.position),"wall_seconds":(Time.get_ticks_usec()-start)/1000000.0}
	checks[label+"_physically_passable"] = reached == route.size() and arena.tank.position.y > 3.8
	checks[label+"_encounters"] = alarmed.size()==0 if label=="long" else alarmed.size()==3
	print("GROUP_ROUTE ",label," ",JSON.stringify(metrics[label]))

func _run() -> void:
	arena = load("res://desert.tscn").instantiate()
	root.add_child(arena)
	if not arena.rendering_ready: await arena.rendering_prepared
	await _frames(3)
	await _fresh()
	var clearance := INF
	var manager = arena.level.roaming_groups
	for group in manager.groups:
		for enemy in group.members:
			for phase in [-1.0,0.0,1.0]:
				var pos: Vector3 = group.origin + enemy.group_offset + group.travel * phase
				for i in range(1,manager.LONG_ROUTE.size()):
					var closest := Geometry3D.get_closest_point_to_segment(pos,manager.LONG_ROUTE[i-1],manager.LONG_ROUTE[i])
					clearance = minf(clearance,pos.distance_to(closest))
	metrics.long_route_min_patrol_clearance = clearance
	checks.long_route_clear_for_entire_patrol = clearance > 25.0
	await _travel(arena.level.roaming_groups.LONG_ROUTE,"long")
	await _fresh()
	await _travel(arena.level.roaming_groups.SHORT_ROUTE,"short")
	var lengths := []
	for route in [arena.level.roaming_groups.SHORT_ROUTE,arena.level.roaming_groups.LONG_ROUTE]:
		var length := 0.0
		for i in range(1,route.size()): length += route[i].distance_to(route[i-1])
		lengths.append(length)
	metrics.route_lengths = lengths
	checks.long_route_is_longer = lengths[1] > lengths[0]*1.3
	await _fresh()
	arena.level.map_view.show()
	await arena._capture(arena.verification_path("groups_map.png"))
	arena.level.map_view.hide()
	arena.tank.position = Vector3(-109,0.04,0)
	arena.focus = Vector3(-82,0,7)
	arena.zoom = 48
	arena._update_camera(0.001)
	await arena._capture(arena.verification_path("groups_fork.png"))
	var passed := checks.values().all(func(v): return v)
	var report := {"passed":passed,"checks":checks,"metrics":metrics}
	FileAccess.open(arena.verification_path("group_routes.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"  "))
	print("GROUP_ROUTES_RESULT: ",JSON.stringify(report))
	quit(0 if passed else 1)
