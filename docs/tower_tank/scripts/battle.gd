extends Node3D
## Small wave arena for the original ordinary skeleton; navigation is shared.
const SkeletonActor = preload("res://scripts/skeleton.gd")
var arena
var enemies: Array[CharacterBody3D] = []
var waves_enabled := true
var wave := 0
var kills := 0
var next_wave := 2.5
var wave_requested := false
var nav_dirty := true
var nav_wait := 0.0
var grid := AStarGrid2D.new()
var rng := RandomNumberGenerator.new()
var probe := SphereShape3D.new()

func _ready() -> void:
	rng.seed = 49321
	grid.region = Rect2i(-28, -28, 57, 57)
	grid.cell_size = Vector2.ONE
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	probe.radius = 0.54

func reset() -> void:
	for enemy in enemies:
		enemy.collision_layer = 0
		enemy.queue_free()
	enemies.clear()
	wave = 0
	kills = 0
	next_wave = 2.5
	wave_requested = false
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
		# As in the original: prefer at most two attackers per dwarf.
		if candidate != arena.tank:
			var load := 0
			for other in enemies:
				if other != enemy and other.target == candidate: load += 1
			if load >= 2: score += 144.0
		if score < best_score:
			best = candidate
			best_score = score
	return best

func clear_sight(from: Vector3, to: Vector3, victim: Node3D = null) -> bool:
	# Terrain and the hull block melee; exclude the hull when it is the victim.
	var excluded: Array[RID] = []
	if victim == arena.tank: excluded.append(arena.tank.get_rid())
	var ray := PhysicsRayQueryParameters3D.create(Vector3(from.x, 0.9, from.z), Vector3(to.x, 0.9, to.z), 3, excluded)
	return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()

func _rebuild_navigation() -> void:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = probe
	query.collision_mask = 3 if arena.tank.dead or not arena.crew.crewed else 1
	for x in range(-28, 29):
		for z in range(-28, 29):
			query.transform.origin = Vector3(x, 0.9, z)
			grid.set_point_solid(Vector2i(x, z), not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty())
	nav_dirty = false
	nav_wait = 0.35

func _cell(pos: Vector3) -> Vector2i:
	return Vector2i(clampi(roundi(pos.x), -28, 28), clampi(roundi(pos.z), -28, 28))

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
	for point in grid.get_point_path(start, finish, true): result.append(Vector3(point.x, 0, point.y))
	# Skip the grid center under the actor to avoid a backwards first step.
	if result.size() > 1: result.remove_at(0)
	return result

func spawn_enemy(pos: Vector3) -> CharacterBody3D:
	var enemy := SkeletonActor.new()
	enemy.arena = arena
	enemy.battle = self
	add_child(enemy)
	enemy.global_position = Vector3(pos.x, 0.04, pos.z)
	enemies.append(enemy)
	return enemy

func _spawn_clear(pos: Vector3) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = probe
	query.transform.origin = pos + Vector3.UP
	query.collision_mask = 103 # world, tower, crew, scenery, skeletons
	if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty(): return false
	for enemy in enemies:
		if enemy.position.distance_to(pos) < 1.2: return false
	return true

func start_wave() -> void:
	if not enemies.is_empty() or player_targets().is_empty(): return
	wave += 1
	var count := mini(12 + (wave - 1) * 4, 28)
	var spawned := 0
	for attempt in 180:
		var angle := -PI * 0.5 + (attempt % 3 - 1) * 0.95 + float(attempt / 3) * 0.11
		var radius := 20.0 + float((attempt / 3) % 4) * 1.5
		var pos := Vector3(cos(angle), 0.04, sin(angle)) * radius
		pos.y = 0.04
		if pos.distance_to(arena.crew.center()) < 9.0 or not _spawn_clear(pos): continue
		spawn_enemy(pos)
		spawned += 1
		if spawned >= count: break
	if spawned == 0:
		wave -= 1
		next_wave = 1.0
		return
	arena.crew.tell("Волна %d · %d обычных скелетов" % [wave, spawned])
	arena.sound.play("servo", -4.0, 0.55)
	next_wave = 8.0

func killed(enemy: CharacterBody3D) -> void:
	if not enemies.has(enemy): return
	enemies.erase(enemy)
	kills += 1
	arena.crew.loot.spawn_coin(enemy.position + Vector3.UP, Vector3.UP * 3.0)
	arena.sound.play("shatter", -9.0, 1.3)
	if enemies.is_empty() and waves_enabled:
		next_wave = 8.0
		arena.crew.tell("Волна отбита · следующая через 8 с · N — сразу")

func bump(from: Vector3, to: Vector3, speed: float) -> void:
	if speed < 1.0: return
	for enemy in enemies.duplicate():
		var pos := Vector3(enemy.position.x, 0, enemy.position.z)
		var closest := Geometry3D.get_closest_point_to_segment(pos, Vector3(from.x, 0, from.z), Vector3(to.x, 0, to.z))
		if pos.distance_to(closest) <= 1.8 and enemy.bump_cooldown <= 0.0:
			var direction := (pos - closest).normalized()
			if direction.is_zero_approx(): direction = (to - from).normalized()
			enemy.take_damage(10.0, direction, 10.0)
			enemy.bump_cooldown = 0.5

func tick(dt: float) -> void:
	nav_wait = maxf(0.0, nav_wait - dt)
	if arena.tuning_open: return
	if (waves_enabled or not enemies.is_empty()) and nav_dirty and nav_wait <= 0.0: _rebuild_navigation()
	if player_targets().is_empty():
		wave_requested = false
		return
	if waves_enabled and enemies.is_empty():
		next_wave -= dt
		if next_wave <= 0.0 or wave_requested: start_wave()
	wave_requested = false
	for enemy in enemies.duplicate(): enemy.tick(dt)
