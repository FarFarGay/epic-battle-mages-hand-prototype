extends Node3D
## Standalone equivalent of main-project pot.gd: tower contact, shards, coins.
## Swept contact also catches small props between frames during a super dash.
const Geo = preload("res://scripts/geo.gd")
const HandObject = preload("res://scripts/hand_object.gd")
var arena
var props: Array[RigidBody3D] = []
var broken_count := 0
var clay := Geo.material(Color("ba7954"))
var wood := Geo.material(Color("8e7150"))
var band := Geo.material(Color("465357"), 0.5)
var rim := Geo.material(Color("dcc798"))
var crack_sound_cd := 0.0

func reset() -> void:
	for prop in props:
		prop.collision_layer = 0
		prop.queue_free()
	props.clear()
	broken_count = 0
	crack_sound_cd = 0.0
	# Piles along clear approach lanes; varied silhouettes identify fragile scenery.
	var centers := [Vector3(0, 0, 0), Vector3(-5, 0, 3), Vector3(5, 0, 1), Vector3(8, 0, -3), Vector3(-10, 0, -6), Vector3(15, 0, 8), Vector3(-14, 0, 12), Vector3(5, 0, 17)]
	for i in centers.size():
		for j in 6:
			var offset := Vector3(float(j % 2) * 1.15 - 0.57, 0, float(j / 2) * 1.0 - 1.0)
			spawn_prop(centers[i] + offset, (i + j) % 3)

func spawn_prop(pos: Vector3, kind: int = 0) -> RigidBody3D:
	var prop := HandObject.new()
	prop.arena = arena
	prop.freeze = true
	prop.mass = 2.0 if kind == 0 else 3.0
	add_child(prop)
	prop.name = "FragileScenery"
	prop.position = pos
	prop.collision_layer = 32
	prop.collision_mask = 9 | 32
	prop.set_meta("breakable", true)
	prop.set_meta("kind", kind)
	prop.set_meta("broken", false)
	Geo.collider(prop, Vector3(0.68, 0.90, 0.68), Vector3.UP * 0.45)
	match kind:
		0:
			Geo.cylinder(prop, 0.31, 0.48, Vector3.UP * 0.32, clay, 9, 0.38)
			Geo.cylinder(prop, 0.38, 0.22, Vector3.UP * 0.66, clay, 9, 0.21)
			Geo.ring(prop, 0.24, 0.06, Vector3.UP * 0.81, rim)
			Geo.cylinder(prop, 0.17, 0.025, Vector3.UP * 0.76, band, 9)
		1:
			Geo.box(prop, Vector3(0.70, 0.70, 0.70), Vector3.UP * 0.36, wood)
			for x in [-0.26, 0.26]:
				Geo.box(prop, Vector3(0.09, 0.74, 0.74), Vector3(x, 0.36, 0), rim)
			Geo.line(prop, Vector3(-0.29, 0.08, -0.365), Vector3(0.29, 0.66, -0.365), 0.08, rim)
		2:
			Geo.cylinder(prop, 0.34, 0.85, Vector3.UP * 0.44, wood, 10)
			for y in [0.16, 0.72]:
				Geo.cylinder(prop, 0.36, 0.09, Vector3.UP * y, band, 10)
	props.append(prop)
	preload("res://scripts/tower_hand.gd").register_item(prop, Vector3(0.68, 0.9, 0.68), ["ГОРШОК", "ЯЩИК", "БОЧКА"][kind], Vector3.UP * 0.45)
	return prop

func tick(dt: float) -> void:
	crack_sound_cd = maxf(0.0, crack_sound_cd - dt)

func crush_segment(from: Vector3, to: Vector3, radius: float, force: float = 1.0, include_carried: bool = false) -> void:
	var start := Vector3(from.x, 0, from.z)
	var end := Vector3(to.x, 0, to.z)
	for prop in props.duplicate():
		if prop.has_meta("hand_owner") and not include_carried: continue
		var closest := Geometry3D.get_closest_point_to_segment(prop.position, start, end)
		if prop.position.distance_to(closest) > radius + 0.34:
			continue
		var ray := PhysicsRayQueryParameters3D.create(closest + Vector3.UP * 0.6, prop.position + Vector3.UP * 0.6, 1)
		if get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			shatter(prop, (end - start).normalized(), force)

func stomp(pos: Vector3, power: float = 1.0) -> void:
	crush_segment(pos, pos, 0.80, power)

func blast(pos: Vector3, radius: float) -> void:
	crush_segment(pos, pos, radius, 1.4, true)

func shatter(prop: RigidBody3D, direction: Vector3 = Vector3.ZERO, power: float = 1.0) -> void:
	if not is_instance_valid(prop) or not props.has(prop) or prop.get_meta("broken", false):
		return
	prop.set_meta("broken", true)
	props.erase(prop)
	prop.collision_layer = 0
	prop.hide()
	var pos := prop.global_position
	var kind: int = prop.get_meta("kind")
	prop.queue_free()
	broken_count += 1
	var mat: Material = clay if kind == 0 else wood
	for i in 10:
		var angle := i * 2.4 + broken_count
		var size := Vector3(0.11, 0.08, 0.23) if kind == 0 else Vector3(0.10, 0.09, 0.39)
		var shard := Geo.box(arena.fx, size, pos + Vector3.UP * 0.40, mat if i % 3 else rim)
		var velocity := Vector3(cos(angle), 1.0 + (i % 3) * 0.3, sin(angle)) * (2.0 + power)
		arena.fx.add_piece(shard, velocity + direction * power * 3.0, 1.0 + (i % 3) * 0.25, 15.0, "piece", Vector3(4, 5, 3))
	for i in 3:
		arena.fx.dust(pos + Vector3.UP * 0.15, Vector3(sin(i * 2.1), 0, cos(i * 2.1)) * -3.0)
		arena.crew.loot.spawn_coin(pos + Vector3.UP * 0.5, Vector3(sin(i * 2.1) * 2.0, 3.0, cos(i * 2.1) * 2.0))
	if crack_sound_cd <= 0.0:
		arena.sound.play("shatter", -4.0, 1.12 if kind == 0 else 0.8)
		crack_sound_cd = 0.065
	arena.add_trauma(0.025 * minf(power, 2.0))
