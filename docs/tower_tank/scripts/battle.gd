extends Node3D
## Small wave arena for the original ordinary skeleton; navigation is shared.
const SkeletonActor = preload("res://scripts/skeleton.gd")
const CrowdVisual = preload("res://scripts/crowd_visual.gd")
const WAVE_SIZE := 600
const GIANT_EVERY := 25 # 576 ordinary skeletons + 24 brutes per wave.
var arena
var enemies: Array[CharacterBody3D] = []
var waves_enabled := true
var wave := 0
var kills := 0
var next_wave := 2.5
var wave_requested := false
var spawn_points: Array[Vector3] = []
var spawn_cursor := 0
var spawning_left := 0
var nav_dirty := true
var nav_wait := 0.0
var nav_origin := Vector3.ZERO
var grid := AStarGrid2D.new()
var rng := RandomNumberGenerator.new()
var probe := SphereShape3D.new()
var giant_probe := SphereShape3D.new()
var crowd
var neighbor_heads := PackedInt32Array()
var neighbor_links := PackedInt32Array()
var neighbor_positions := PackedVector3Array()
var neighbor_radii := PackedFloat32Array()
var neighbor_origin := Vector3.ZERO
var neighbor_width := 44
var neighbor_height := 44
const CROWD_GRID := 44
const CROWD_CELL := 1.5
const NEAR_CELLS := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
var last_tick_usec := 0
var simulation_time := 0.0
var simulation_frame := 0
var profile_enabled := false
var last_profile := {}
var solid := PackedByteArray()
var flow_next := PackedInt32Array()
var flow_distance := PackedInt32Array()
var flow_build := PackedInt32Array()
var flow_build_distance := PackedInt32Array()
var flow_queue := PackedInt32Array()
var flow_head := 0
var flow_tail := 0
var flow_goal := -1
var flow_build_goal := -1
var target_load := {}
var ground_crew: Array[Vector3] = []
var ground_crew_center := Vector3.ZERO
var nav_min := Vector2i(-28,-28)
var nav_width := 57
var nav_height := 57
var nav_area := 57*57
var entry_navigation := false
const DIRECTIONS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]

func _ready() -> void:
	profile_enabled = OS.get_cmdline_user_args().has("--profile")
	rng.seed = 49321
	grid.region = Rect2i(-28, -28, 57, 57)
	grid.cell_size = Vector2.ONE
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	probe.radius = 0.54
	giant_probe.radius = 0.86
	for x in range(-19, 20):
		for z in range(-19, 20):
			var point := Vector3(x * 1.35, 0.04, z * 1.35)
			if point.length_squared() > 100.0: spawn_points.append(point)
	spawn_points.sort_custom(func(a: Vector3, b: Vector3): return a.length_squared() > b.length_squared())
	crowd = CrowdVisual.new()
	crowd.battle = self
	add_child(crowd)

func _process(dt: float) -> void:
	crowd.tick_debris(dt)
	crowd.update_instances()

func reset() -> void:
	for enemy in enemies:
		enemy.collision_layer = 0
		enemy.queue_free()
	enemies.clear()
	crowd.clear_debris()
	flow_next.clear()
	flow_distance.clear()
	flow_build.clear()
	flow_build_distance.clear()
	flow_goal = -1
	flow_build_goal = -1
	wave = 0
	kills = 0
	next_wave = 2.5
	wave_requested = false
	spawning_left = 0
	spawn_cursor = 0
	nav_dirty = true
	nav_wait = 0.0
	rng.seed = 49321

func player_targets() -> Array:
	if arena.crew.members.is_empty(): return []
	if arena.crew.crewed:
		return [arena.tank] if not arena.tank.dead else []
	return arena.crew.members.duplicate()

func valid_target(candidate: Node3D) -> bool:
	if not is_instance_valid(candidate): return false
	if candidate == arena.tank: return arena.crew.crewed and not arena.tank.dead and not arena.crew.members.is_empty()
	return not arena.crew.crewed and arena.crew.members.has(candidate) and not candidate.dead

func choose_target(enemy: CharacterBody3D) -> Node3D:
	var best: Node3D
	var best_score := INF
	for candidate in player_targets():
		var score: float = enemy.position.distance_squared_to(candidate.global_position)
		if arena.level and not enemy.attack_on_spawn and score > 45.0 * 45.0: continue
		# As in the original: prefer at most two attackers per dwarf.
		if candidate != arena.tank:
			var load: int = target_load.get(candidate.get_instance_id(), 0) - (1 if enemy.target == candidate else 0)
			if load >= 2: score += 144.0
		if score < best_score:
			best = candidate
			best_score = score
	if best != enemy.target:
		if is_instance_valid(enemy.target): target_load[enemy.target.get_instance_id()] = maxi(0, target_load.get(enemy.target.get_instance_id(), 0) - 1)
		if best: target_load[best.get_instance_id()] = target_load.get(best.get_instance_id(), 0) + 1
	return best

func clear_sight(from: Vector3, to: Vector3, victim: Node3D = null) -> bool:
	# Terrain and the hull block melee; exclude the hull when it is the victim.
	var excluded: Array[RID] = []
	if victim == arena.tank: excluded.append(arena.tank.get_rid())
	var ray := PhysicsRayQueryParameters3D.create(from+Vector3.UP*0.9,to+Vector3.UP*0.9,3,excluded)
	return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()

func _rebuild_navigation() -> void:
	# Cover the entire narrow entry with fewer cells than the normal local grid.
	# Rear ranks then share the same obstacle routes as those near the tower.
	var player: Vector3 = arena.crew.center()
	entry_navigation = arena.level != null and player.x < -128.0 and absf(player.z)<10.0
	var region := Rect2i(-28,-28,57,57)
	if entry_navigation:
		region = Rect2i(int(arena.level.ENTRY_WEST-nav_origin.x),int(-10-nav_origin.z),int(arena.level.ENTRY_LENGTH)+1,21)
	if grid.region != region:
		grid.region = region
		grid.update()
	nav_min = region.position
	nav_width = region.size.x
	nav_height = region.size.y
	nav_area = nav_width*nav_height
	solid.resize(nav_area)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = probe
	if arena.level:
		var body_probe := CapsuleShape3D.new()
		body_probe.radius = probe.radius
		body_probe.height = 2.05
		query.shape = body_probe
	query.collision_mask = 3 if arena.tank.dead or not arena.crew.crewed else 1
	if arena.level: query.collision_mask |= 32 # Breakable supply crates and barrels.
	for x in range(region.position.x,region.end.x):
		for z in range(region.position.y,region.end.y):
			query.transform.origin = nav_origin + Vector3(x, 1.3 if arena.level else 0.9, z)
			var point := nav_origin+Vector3(x,0,z)
			var floor_y: float=arena.ground_height(point)
			query.transform.origin.y+=floor_y
			var blocked := not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()
			if arena.level:
				for offset in [Vector3.RIGHT,Vector3.LEFT,Vector3.FORWARD,Vector3.BACK]:
					if absf(arena.ground_height(point+offset)-floor_y)>0.65:
						blocked=true
						break
			grid.set_point_solid(Vector2i(x, z), blocked)
			solid[_nav_index(Vector2i(x,z))] = int(blocked)
	nav_dirty = false
	nav_wait = 0.35
	flow_next.clear()
	flow_distance.clear()
	flow_build.clear()
	flow_build_distance.clear()
	flow_goal = -1
	flow_build_goal = -1

func _update_flow() -> void:
	if solid.size() != nav_area: return
	var destination: Vector3 = arena.tank.position if arena.crew.crewed else arena.crew.center()
	var cell := _walkable(_cell(destination))
	var goal := _nav_index(cell)
	if flow_build.is_empty() and goal != flow_goal:
		flow_build.resize(nav_area)
		flow_build.fill(-1)
		flow_build_distance.resize(nav_area)
		flow_build_distance.fill(-1)
		flow_queue.resize(nav_area)
		flow_build[goal] = goal
		flow_build_distance[goal] = 0
		flow_queue[0] = goal
		flow_head = 0
		flow_tail = 1
		flow_build_goal = goal
	if flow_build.is_empty(): return
	# Amortize shared path finding; movement uses the previous completed field.
	var limit := mini(flow_head + 384, nav_area)
	while flow_head < flow_tail and flow_head < limit:
		var current := flow_queue[flow_head]
		flow_head += 1
		var x := current % nav_width
		var z := current / nav_width
		for d in DIRECTIONS:
			var nx: int = x + d.x
			var nz: int = z + d.y
			if nx < 0 or nz < 0 or nx >= nav_width or nz >= nav_height: continue
			var next := nz * nav_width + nx
			if solid[next] != 0 or flow_build[next] >= 0: continue
			if d.x != 0 and d.y != 0 and (solid[z * nav_width + nx] != 0 or solid[nz * nav_width + x] != 0): continue
			flow_build[next] = current
			flow_build_distance[next] = flow_build_distance[current]+1
			flow_queue[flow_tail] = next
			flow_tail += 1
	if flow_head >= flow_tail:
		flow_next = flow_build
		flow_distance = flow_build_distance
		flow_build = PackedInt32Array()
		flow_build_distance = PackedInt32Array()
		flow_goal = flow_build_goal

func flow_direction(from: Vector3, to: Vector3, approach_lane: float = INF) -> Vector3:
	if not grid.region.has_point(Vector2i(roundi(from.x-nav_origin.x),roundi(from.z-nav_origin.z))):
		return Vector3(to.x - from.x, 0, to.z - from.z).normalized()
	var cell := _cell(from)
	var index := _nav_index(cell)
	if solid.size() == nav_area and solid[index] != 0:
		var closest := INF
		var escape := Vector3.ZERO
		for offset in DIRECTIONS:
			var point := nav_origin + Vector3(cell.x + offset.x, from.y, cell.y + offset.y)
			var distance := from.distance_squared_to(point)
			if distance >= closest or not _ground_open(point): continue
			var ray := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 0.9, point + Vector3.UP * 0.9, 33 if arena.level else 1)
			if get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
				closest = distance
				escape = (point - from).normalized()
		return escape
	if flow_next.size() == nav_area:
		var next := flow_next[index]
		if next >= 0 and next != index:
			# Among equally short routes, retain each walker's side of the
			# corridor. The whole column no longer shares one diagonal queue.
			if entry_navigation and is_finite(approach_lane) and flow_distance.size()==nav_area:
				var spread := clampf((absf(from.x-to.x)-6.0)/14.0,0.0,1.0)
				var lane := lerpf(to.z,approach_lane,spread)
				var best_score := INF
				for offset in DIRECTIONS:
					var candidate: Vector2i = cell+offset
					if not grid.region.has_point(candidate): continue
					var candidate_index := _nav_index(candidate)
					if solid[candidate_index]!=0 or flow_distance[candidate_index]!=flow_distance[index]-1: continue
					if offset.x!=0 and offset.y!=0 and (grid.is_point_solid(cell+Vector2i(offset.x,0)) or grid.is_point_solid(cell+Vector2i(0,offset.y))): continue
					var world := nav_origin+Vector3(candidate.x,0,candidate.y)
					var score := absf(world.z-lane)+0.18*Vector2(world.x-from.x,world.z-from.z).length()
					if score<best_score:
						best_score=score
						next=candidate_index
			var point := nav_origin + Vector3(next % nav_width + nav_min.x, 0, next / nav_width + nav_min.y)
			return (point - Vector3(from.x, 0, from.z)).normalized()
	return Vector3(to.x - from.x, 0, to.z - from.z).normalized()

func _ground_open(pos: Vector3, clearance: float = 0.0) -> bool:
	var x := roundi(pos.x - nav_origin.x) - nav_min.x
	var z := roundi(pos.z - nav_origin.z) - nav_min.y
	if x < 0 or x >= nav_width or z < 0 or z >= nav_height or solid[z * nav_width + x] != 0: return false
	if clearance > 0.0:
		return _ground_open(pos + Vector3.RIGHT * clearance) and _ground_open(pos + Vector3.LEFT * clearance) and _ground_open(pos + Vector3.FORWARD * clearance) and _ground_open(pos + Vector3.BACK * clearance)
	return true

func move_ground(enemy: CharacterBody3D, dt: float) -> void:
	# The shared grid handles obstacles and cliff edges; analytic terrain heights
	# keep the crowd on ramps without a separate physics sweep for every skeleton.
	var clearance: float = enemy.body_radius - 0.4
	var floor_y: float=arena.ground_height(enemy.position)
	if absf(enemy.position.y-floor_y-0.04) > 0.15 or solid.size() != nav_area or not _ground_open(enemy.position, clearance):
		enemy.collision_mask = 39 if arena.level else 7
		enemy.move_and_slide()
		return
	enemy.collision_mask = 0
	var start := enemy.position
	var next := start + Vector3(enemy.velocity.x, 0, enemy.velocity.z) * dt
	if not _ground_open(next, clearance):
		var side := Vector3(next.x, start.y, start.z)
		if _ground_open(side, clearance): next = side
		else:
			side = Vector3(start.x, start.y, next.z)
			next = side if _ground_open(side, clearance) else start
	var hull_offset: Vector3 = next - arena.tank.position
	hull_offset.y = 0.0
	var hull_radius: float = 1.32 + enemy.body_radius
	if hull_offset.length_squared() < hull_radius * hull_radius and absf(enemy.position.y-arena.tank.position.y)<1.0:
		if hull_offset.is_zero_approx(): hull_offset = Vector3.RIGHT
		next = arena.tank.position + hull_offset.normalized() * hull_radius
	if not ground_crew.is_empty() and next.distance_squared_to(ground_crew_center) < 64.0:
		for member in ground_crew:
			var gap := Vector3(next.x - member.x, 0, next.z - member.z)
			var crew_radius: float = 0.25 + enemy.body_radius
			if gap.length_squared() < crew_radius * crew_radius and not gap.is_zero_approx(): next = member + gap.normalized() * crew_radius
	next.y = arena.ground_height(next)+0.04
	if absf(next.y-start.y)>0.65: return
	if _ground_open(next, clearance): enemy.position = next

func _cell(pos: Vector3) -> Vector2i:
	return Vector2i(clampi(roundi(pos.x - nav_origin.x),nav_min.x,nav_min.x+nav_width-1),clampi(roundi(pos.z - nav_origin.z),nav_min.y,nav_min.y+nav_height-1))

func _nav_index(cell: Vector2i) -> int:
	return (cell.y-nav_min.y)*nav_width+cell.x-nav_min.x

func _walkable(cell: Vector2i) -> Vector2i:
	if not grid.is_point_solid(cell): return cell
	for radius in range(1, 4):
		for x in range(-radius, radius + 1):
			for y in range(-radius, radius + 1):
				var candidate := cell + Vector2i(x, y)
				if grid.region.has_point(candidate) and not grid.is_point_solid(candidate): return candidate
	return cell

func find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var result := PackedVector3Array()
	var start := _walkable(_cell(from))
	var finish := _walkable(_cell(to))
	if grid.is_point_solid(start) or grid.is_point_solid(finish): return result
	for point in grid.get_point_path(start, finish, true):
		var world := nav_origin+Vector3(point.x,0,point.y)
		world.y=arena.ground_height(world)
		result.append(world)
	# Skip the grid center under the actor to avoid a backwards first step.
	if result.size() > 1: result.remove_at(0)
	return result

func spawn_enemy(pos: Vector3, giant: bool = false, shield_guard: bool = false) -> CharacterBody3D:
	var enemy := SkeletonActor.new()
	enemy.arena = arena
	enemy.battle = self
	enemy.giant = giant
	enemy.shield_guard = shield_guard and not giant
	add_child(enemy)
	enemy.global_position = Vector3(pos.x, arena.ground_height(pos)+0.04, pos.z)
	enemy.approach_lane = pos.z
	enemy.sim_slot = enemies.size() % 2
	enemies.append(enemy)
	return enemy

func _spawn_clear(pos: Vector3, giant: bool = false) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = giant_probe if giant else probe
	query.transform.origin = Vector3(pos.x,arena.ground_height(pos)+1.0,pos.z)
	query.collision_mask = 103 # world, tower, crew, scenery, skeletons
	if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty(): return false
	return true

func start_wave() -> void:
	if not enemies.is_empty() or spawning_left > 0 or player_targets().is_empty(): return
	wave += 1
	spawning_left = WAVE_SIZE
	spawn_cursor = 0
	arena.crew.tell("Волна %d · %d скелетов, из них %d громилы" % [wave, WAVE_SIZE, WAVE_SIZE / GIANT_EVERY])
	arena.sound.play("servo", -4.0, 0.55)
	next_wave = 8.0

func _spawn_wave_batch() -> void:
	var player_position: Vector3 = arena.crew.center()
	var spawned := 0
	var attempts := 0
	while spawning_left > 0 and spawn_cursor < spawn_points.size() and spawned < 24 and attempts < 64:
		var pos := spawn_points[spawn_cursor]
		spawn_cursor += 1
		attempts += 1
		var giant := (WAVE_SIZE - spawning_left + 1) % GIANT_EVERY == 0
		if pos.distance_squared_to(player_position) < 81.0 or not _spawn_clear(pos, giant): continue
		spawn_enemy(pos, giant)
		spawning_left -= 1
		spawned += 1
	if spawn_cursor >= spawn_points.size(): spawning_left = 0

func remaining() -> int:
	return enemies.size() + spawning_left + (arena.level.spawn_queue.size() if arena.level else 0)

func killed(enemy: CharacterBody3D) -> void:
	if not enemies.has(enemy): return
	enemies.erase(enemy)
	kills += 1
	for i in (5 if enemy.giant else 1):
		arena.crew.loot.spawn_coin(enemy.position + Vector3.UP, Vector3.UP * 3.0)
	arena.sound.play("shatter", -9.0, 1.3)
	if enemies.is_empty() and spawning_left == 0 and waves_enabled:
		next_wave = 8.0
		arena.crew.tell("Волна отбита · следующая через 8 с · N — сразу")

func bump(from: Vector3, to: Vector3, speed: float) -> void:
	if speed < 1.0: return
	for enemy in enemies.duplicate():
		if enemy.hand_held or enemy.hand_thrown: continue
		var pos := Vector3(enemy.position.x, 0, enemy.position.z)
		var closest := Geometry3D.get_closest_point_to_segment(pos, Vector3(from.x, 0, from.z), Vector3(to.x, 0, to.z))
		if pos.distance_to(closest) <= 1.4 + enemy.body_radius and enemy.bump_cooldown <= 0.0:
			var direction := (pos - closest).normalized()
			if direction.is_zero_approx(): direction = (to - from).normalized()
			enemy.take_damage(10.0, direction, 10.0)
			enemy.bump_cooldown = 0.5

func _update_neighbors() -> void:
	# Include the rear of the long corridor; clamping it into one edge cell
	# used to exhaust the neighbour budget before nearby walkers were found.
	neighbor_origin = nav_origin-Vector3.ONE*CROWD_GRID*CROWD_CELL*0.5
	neighbor_width = CROWD_GRID
	neighbor_height = CROWD_GRID
	if entry_navigation:
		neighbor_origin = nav_origin+Vector3(nav_min.x-3,0,nav_min.y-3)
		neighbor_width = ceili((nav_width+6)/CROWD_CELL)+1
		neighbor_height = ceili((nav_height+6)/CROWD_CELL)+1
	neighbor_heads.resize(neighbor_width * neighbor_height)
	neighbor_heads.fill(-1)
	neighbor_links.resize(enemies.size())
	neighbor_positions.resize(enemies.size())
	neighbor_radii.resize(enemies.size())
	target_load.clear()
	ground_crew.clear()
	if not arena.crew.crewed:
		ground_crew_center = arena.crew.center()
		for member in arena.crew.members: ground_crew.append(member.position)
	for i in enemies.size():
		var enemy = enemies[i]
		enemy.crowd_index = i
		var pos: Vector3 = enemy.position
		neighbor_positions[i] = pos
		neighbor_radii[i] = enemy.body_radius
		neighbor_links[i] = -1
		if is_instance_valid(enemy.target): target_load[enemy.target.get_instance_id()] = target_load.get(enemy.target.get_instance_id(), 0) + 1
		if enemy.hand_held or enemy.hand_thrown: continue
		var x := clampi(floori((pos.x-neighbor_origin.x)/CROWD_CELL),0,neighbor_width-1)
		var z := clampi(floori((pos.z-neighbor_origin.z)/CROWD_CELL),0,neighbor_height-1)
		var cell := z * neighbor_width + x
		neighbor_links[i] = neighbor_heads[cell]
		neighbor_heads[cell] = i

func separation(index: int, pos: Vector3, forward: Vector3) -> Vector4:
	var result := Vector3.ZERO
	var clearance := 1.0
	var radius := neighbor_radii[index] if index < neighbor_radii.size() else 0.4
	var x := clampi(floori((pos.x-neighbor_origin.x)/CROWD_CELL),1,neighbor_width-2)
	var z := clampi(floori((pos.z-neighbor_origin.z)/CROWD_CELL),1,neighbor_height-2)
	var examined := 0
	for d in NEAR_CELLS:
		var other := neighbor_heads[(z + d.y) * neighbor_width + x + d.x]
		while other >= 0:
			if other != index:
				var gap := pos - neighbor_positions[other]
				gap.y = 0.0
				var distance_squared := gap.length_squared()
				var spacing := radius + neighbor_radii[other] + 0.65
				if distance_squared > 0.000001 and distance_squared < spacing * spacing:
					var distance := sqrt(distance_squared)
					result += gap * ((spacing - distance) * 3.4 / distance)
					var ahead := -gap.dot(forward)
					if ahead > 0.0 and distance_squared - ahead * ahead < spacing * spacing * 0.25:
						clearance = minf(clearance, clampf((ahead - spacing + 0.42) / 0.4, 0.0, 1.0))
				examined += 1
				if examined >= 32:
					result = result.limit_length(3.5)
					return Vector4(result.x, result.y, result.z, clearance)
			other = neighbor_links[other]
	result = result.limit_length(3.5)
	return Vector4(result.x, result.y, result.z, clearance)

func tick(dt: float) -> void:
	var tick_started := Time.get_ticks_usec()
	last_profile = {"logic": 0, "separation": 0, "move": 0, "actors": 0}
	nav_wait = maxf(0.0, nav_wait - dt)
	if arena.tuning_open: return
	if arena.level:
		var player: Vector3 = arena.crew.center()
		var in_entry := player.x < -128.0 and absf(player.z)<10.0
		if in_entry != entry_navigation:
			nav_dirty = true
			nav_wait = 0.0
		if absf(player.x - nav_origin.x) > 12.0 or absf(player.z - nav_origin.z) > 12.0:
			nav_origin = Vector3(snappedf(player.x, 16.0), 0, snappedf(player.z, 16.0))
			nav_dirty = true
			nav_wait = 0.0
			solid.clear()
			flow_next.clear()
			flow_distance.clear()
			flow_build.clear()
			flow_build_distance.clear()
	if (waves_enabled or not enemies.is_empty()) and nav_dirty and nav_wait <= 0.0: _rebuild_navigation()
	if player_targets().is_empty():
		wave_requested = false
		for enemy in enemies.duplicate():
			if enemy.hand_held or enemy.hand_thrown: enemy.tick(dt)
		return
	if waves_enabled and enemies.is_empty() and spawning_left == 0:
		next_wave -= dt
		if next_wave <= 0.0 or wave_requested: start_wave()
	wave_requested = false
	if spawning_left > 0: _spawn_wave_batch()
	_update_neighbors()
	_update_flow()
	last_profile["shared"] = Time.get_ticks_usec() - tick_started
	simulation_time += dt
	simulation_frame += 1
	for enemy in enemies.duplicate():
		enemy.pending_dt += dt
		var full_rate: bool = enemies.size() <= 64 or enemy.giant or enemy.hand_held or enemy.hand_thrown or enemy.state == enemy.State.STAGGER or enemy.state == enemy.State.WINDUP or enemy.state == enemy.State.LUNGE
		if not full_rate and enemy.sim_slot != simulation_frame % 2: continue
		last_profile.actors += 1
		enemy.render_from = enemy.position
		enemy.render_stride = enemy.stride
		enemy.render_time = simulation_time
		enemy.render_period = dt if full_rate else dt * 2.0
		enemy.tick(enemy.pending_dt)
		enemy.pending_dt = 0.0
	last_tick_usec = Time.get_ticks_usec() - tick_started
