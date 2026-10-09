extends RefCounted
## The saved scene is authoritative. Runtime snapshots only restore its objects
## after R; they never regenerate or overwrite the designer's layout.
const Placement = preload("res://scripts/level_placement.gd")
const Hand = preload("res://scripts/tower_hand.gd")
var level
var placements: Array[Dictionary] = []
var player_transform := Transform3D.IDENTITY
var workbench_position := Vector3.ZERO
var bridge_transform := Transform3D.IDENTITY
var bridge_size := Vector3(10,0.04,6)
var roles := {}

func bind() -> void:
	for node in level.find_children("*", "Node3D", true, false):
		if node.has_meta("level_role"): roles[node.get_meta("level_role")] = node
	level.terrain = level.get_node("TerrainData")
	level.terrain.level = level
	_rebuild_height_cache()
	level.bridge_body = roles.bridge_deck
	level.bridge_guards.assign([roles.bridge_edge_west,roles.bridge_edge_east])
	level.bridge_door = roles.dash_door
	level.bridge_door.level = level
	level.gate = roles.puzzle_gate
	level.gate_bars = roles.gate_bars
	level.gate_bars_rest = level.gate_bars.position
	level.gate_handle = roles.gate_handle
	level.gate_handle.level = level
	level.gate_handle.home = level.gate_handle.global_position
	Hand.register_item(level.gate_handle,Vector3(0.7,0.7,1.1),"РУКОЯТЬ ВОРОТ · ПОТЯНИ ОТ СТЕНЫ")
	level.platform = roles.weight_plate
	level.platform_rest = level.platform.global_position
	level.A = roles.atoll_a.global_position
	level.B = roles.atoll_b.global_position
	level.C = roles.atoll_c.global_position
	workbench_position = roles.workbench.global_position
	bridge_transform = roles.bridge_socket.global_transform
	bridge_transform.basis = bridge_transform.basis.orthonormalized()
	var deck = level.bridge_body.get_child(0)
	bridge_size = Vector3(deck.mesh.size.x,0.04,deck.mesh.size.z) * level.bridge_body.global_basis.get_scale()
	# Snapshot before detaching: parent transforms and edited meshes/colliders
	# are preserved. Templates never remain as hidden physical duplicates.
	for node in level.find_children("*", "Node3D", true, false):
		if not node is Placement: continue
		if node.enabled:
			var entry := {"kind":node.kind,"transform":node.global_transform,"enemy_type":node.enemy_type,"patrol":node.patrol,"health":node.health,"wave_count":node.wave_count,"wave_giants":node.wave_giants}
			var body: Node3D = node.get_node_or_null("Body")
			if body:
				entry.transform = body.global_transform
				_own(body,body)
				var scene := PackedScene.new()
				var error := scene.pack(body)
				assert(error==OK,"Unable to snapshot a level object")
				entry.scene = scene
			placements.append(entry)
			if node.kind == "Player": player_transform = node.global_transform
		node.get_parent().remove_child(node)
		node.queue_free()
	level.START = player_transform.origin
	level.ENTRY_ATTACK_SIZE = placements.filter(func(p): return p.kind=="Enemy" and not p.patrol).size()
	level.WORLD_SKELETONS = placements.filter(func(p): return p.kind=="Enemy" and p.patrol).size()
	level.set_bridge(false)
	_batch_decoration()

func _own(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_own(child,root)

func _rebuild_height_cache() -> void:
	var terrain = level.terrain
	terrain.shelves.clear()
	terrain.ramps.clear()
	for body in level.find_children("*", "StaticBody3D", true, false):
		if not body.has_meta("ground_kind"): continue
		var shape: CollisionShape3D
		for child in body.get_children():
			if child is CollisionShape3D: shape = child; break
		if shape == null or not shape.shape is ConvexPolygonShape3D: continue
		var points: PackedVector3Array = shape.shape.points
		if body.get_meta("ground_kind") == "mesa":
			var top := -INF
			for p in points: top = maxf(top,p.y)
			var polygon := PackedVector2Array()
			var height := 0.0
			for p in points:
				if absf(p.y-top)>0.01: continue
				var world := shape.to_global(p)
				height = world.y
				polygon.append(Vector2(world.x,world.z))
			polygon = Geometry2D.convex_hull(polygon)
			var bounds := Rect2(polygon[0],Vector2.ZERO)
			for p in polygon: bounds = bounds.expand(p)
			terrain.shelves.append({"bounds":bounds.grow(0.01),"polygon":polygon,"height":height})
		else:
			var from := shape.to_global((points[4]+points[5])*0.5)
			var to := shape.to_global((points[6]+points[7])*0.5)
			var along := Vector3(to.x-from.x,0,to.z-from.z)
			var direction := along.normalized()
			terrain.ramps.append({"from":from,"to":to,"direction":direction,"side":direction.cross(Vector3.UP),"length":along.length(),"width":shape.to_global(points[4]).distance_to(shape.to_global(points[5]))})
	terrain.rebuild_height_index()

func build_targets() -> void:
	level.entry_barrel_positions.clear()
	level.entry_prop_specs.clear()
	for p in placements:
		if p.kind == "Powder":
			var spec := {"pos":p.transform.origin,"barrel":true,"id":level.arena.target_specs.size()+1,"placement":p}
			level.arena.target_specs.append(spec)
			spawn_body(p)
		elif p.kind == "Prop":
			level.entry_prop_specs.append({"pos":p.transform.origin,"kind":0,"yaw":p.transform.basis.get_euler().y})

func spawn_body(p: Dictionary) -> PhysicsBody3D:
	var arena = level.arena
	var body: PhysicsBody3D = p.scene.instantiate()
	var parent: Node = level
	if body is RigidBody3D: body.arena = arena
	if p.kind in ["Cargo","Weight","Chest"]: parent = arena.crew.loot
	elif p.kind == "Prop": parent = arena.props
	elif p.kind == "Powder": parent = arena
	parent.add_child(body)
	body.global_transform = p.transform
	if body.has_meta("hand_size"):
		Hand.register_item(body,body.get_meta("hand_size"),body.get_meta("hand_label"),body.get_meta("hand_center",Vector3.ZERO))
	match p.kind:
		"Powder":
			var spec: Dictionary = body.get_meta("spec").duplicate()
			spec.pos = body.global_position
			body.set_meta("spec",spec)
			body.set_meta("hp",p.health)
			arena.targets.append(body)
			if spec.get("entry_supply",false): level.entry_barrel_positions.append(body.global_position)
		"Ore":
			body.set_meta("hp",p.health)
			level.ore.append(body)
			arena.targets.append(body)
			var cell = level._ore_cell(body.global_position)
			if not level.ore_cells.has(cell): level.ore_cells[cell] = []
			level.ore_cells[cell].append(body)
		"Prop": arena.props.props.append(body)
		"Cargo", "Weight":
			arena.crew.loot.items.append(body)
			if p.kind == "Weight": level.weight = body
		"Chest": arena.crew.loot.chests.append({"node":body,"lid":body.get_node("Lid"),"opened":false})
	return body

func spawn_gameplay() -> void:
	for p in placements:
		if p.kind in ["Ore","Prop","Cargo","Weight","Chest"]: spawn_body(p)

func spawn_bridge(parent: Node) -> RigidBody3D:
	for p in placements:
		if p.kind != "BridgeSection": continue
		var body: RigidBody3D = p.scene.instantiate()
		body.arena = level.arena
		parent.add_child(body)
		body.global_transform = p.transform
		Hand.register_item(body,body.get_meta("hand_size"),body.get_meta("hand_label"))
		return body
	return null

func queue_enemies(patrol: bool) -> void:
	if patrol: level.world_spawn_positions.clear()
	var slot := 0
	for p in placements:
		if p.kind != "Enemy" or p.patrol != patrol: continue
		var entry := {"shield_guard":p.enemy_type=="Shield","giant":p.enemy_type=="Giant","slot":slot,"yaw":p.transform.basis.get_euler().y}
		entry["world_pos" if patrol else "entry_pos"] = p.transform.origin
		level.spawn_queue.append(entry)
		if patrol: level.world_spawn_positions.append(p.transform.origin)
		slot += 1

func queue_mine_defense() -> void:
	for p in placements:
		if p.kind == "MineDefense": level._queue_encounter(p.transform.origin,p.wave_count,p.wave_giants)

func _batch_decoration() -> void:
	# Keep individual scenery pieces editable on disk, merge once at load so
	# editor convenience does not cost thousands of draw calls during play.
	for root in level.find_children("*", "Node3D", true, false):
		if root.get_meta("batch_instances",false):
			_batch_instances(root)
			continue
		if not root.get_meta("batch_decoration",false): continue
		var surfaces := {}
		for mesh in root.find_children("*", "MeshInstance3D", true, false):
			var mat = mesh.material_override
			if not surfaces.has(mat):
				var surface := SurfaceTool.new()
				surface.begin(Mesh.PRIMITIVE_TRIANGLES)
				surfaces[mat] = surface
			for i in mesh.mesh.get_surface_count(): surfaces[mat].append_from(mesh.mesh,i,root.global_transform.affine_inverse()*mesh.global_transform)
			mesh.hide()
			mesh.queue_free()
		for mat in surfaces:
			var mesh := MeshInstance3D.new()
			mesh.mesh = surfaces[mat].commit()
			mesh.material_override = mat
			root.add_child(mesh)

func _batch_instances(root: Node3D) -> void:
	var batches := {}
	for mesh in root.find_children("*", "MeshInstance3D", true, false):
		var key := "%s_%s"%[mesh.mesh.get_instance_id(),mesh.material_override.get_instance_id()]
		if not batches.has(key): batches[key] = []
		batches[key].append(mesh)
	for meshes in batches.values():
		var node := MultiMeshInstance3D.new()
		var data := MultiMesh.new()
		data.transform_format = MultiMesh.TRANSFORM_3D
		data.use_colors = true
		data.mesh = meshes[0].mesh
		data.instance_count = meshes.size()
		for i in meshes.size():
			data.set_instance_transform(i,root.global_transform.affine_inverse()*meshes[i].global_transform)
			data.set_instance_color(i,meshes[i].get_meta("instance_tint",Color.WHITE))
			meshes[i].hide()
			meshes[i].queue_free()
		node.multimesh = data
		node.material_override = meshes[0].material_override
		node.cast_shadow = meshes[0].cast_shadow
		root.add_child(node)
