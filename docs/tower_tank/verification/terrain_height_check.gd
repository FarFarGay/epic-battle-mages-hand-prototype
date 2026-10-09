extends SceneTree
## Compare the spatial index with the original exact surface calculation.
var terrain
var samples := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _reference(point: Vector3) -> float:
	var height := 0.0
	var flat := Vector2(point.x,point.z)
	for shelf in terrain.shelves:
		if shelf.bounds.has_point(flat) and Geometry2D.is_point_in_polygon(flat,shelf.polygon): height = maxf(height,shelf.height)
	for slope in terrain.ramps:
		var delta: Vector3 = point-slope.from
		delta.y = 0
		var along: float = delta.dot(slope.direction)
		if along>=-0.01 and along<=slope.length+0.01 and absf(delta.dot(slope.side))<=slope.width*0.5:
			height = maxf(height,lerpf(slope.from.y,slope.to.y,clampf(along/slope.length,0,1)))
	return height

func _check(point: Vector3) -> void:
	samples += 1
	if absf(_reference(point)-terrain.height_at(point))>0.00001:
		failures += 1
		if failures<5: push_error("Height mismatch at "+str(point))

func _run() -> void:
	var arena = load("res://desert.tscn").instantiate()
	root.add_child(arena)
	arena.set_physics_process(false)
	arena.level.cancel_spawning()
	terrain = arena.level.terrain
	var rng := RandomNumberGenerator.new()
	rng.seed = 81723
	var bounds: Rect2 = arena.world_bounds
	for i in 12000:
		_check(Vector3(rng.randf_range(bounds.position.x,bounds.end.x),0,rng.randf_range(bounds.position.y,bounds.end.y)))
	for slope in terrain.ramps:
		for t in [-0.011,-0.009,0.0,0.01,0.25,0.5,0.75,0.99,1.0,1.009,1.011]:
			for side in [-0.501,-0.5,-0.499,0.0,0.499,0.5,0.501]:
				_check(slope.from+slope.direction*slope.length*t+slope.side*slope.width*side)
	# Tile boundaries and rotated slopes, including after an in-place edit.
	terrain.ramps.append({"from":Vector3(-8,0,-8),"to":Vector3(8,4,8),"direction":Vector3(1,0,1).normalized(),"side":Vector3(-1,0,1).normalized(),"length":sqrt(512.0),"width":5.0})
	for i in 4000: _check(Vector3(rng.randf_range(-12,12),0,rng.randf_range(-12,12)))
	terrain.ramps.back().width = 7.0
	terrain.rebuild_height_index()
	for x in range(-3,4):
		for z in range(-3,4):
			for epsilon in [-0.001,0.0,0.001]: _check(Vector3(x*8.0+epsilon,0,z*8.0+epsilon))
	print("TERRAIN_HEIGHT_CHECK: ",JSON.stringify({"passed":failures==0,"samples":samples,"failures":failures}))
	arena.queue_free()
	await process_frame
	quit(0 if failures==0 else 1)
