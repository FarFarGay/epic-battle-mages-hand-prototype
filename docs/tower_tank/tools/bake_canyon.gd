extends RefCounted
## One-time migration utility. It refuses to overwrite an authored scene.
const Placement = preload("res://scripts/level_placement.gd")
var arena
var level
var output: Node3D
var groups := {}
var assets := {}
var next_asset := 0

func run(source: Node3D) -> void:
	arena = source
	level = arena.level
	if level.authored:
		push_error("The canyon is already authored. Edit desert.tscn; do not rebake it.")
		arena.get_tree().quit(1)
		return
	var frozen := {}
	for item in arena.crew.loot.items:
		frozen[item] = item.freeze
		item.freeze = true
	# Synchronize static collision for the original resident distribution.
	for i in 2: await arena.get_tree().physics_frame
	level._queue_world_population()
	for item in frozen: item.freeze = frozen[item]
	var spawns: Array = level.spawn_queue.duplicate(true)
	output = Node3D.new()
	output.name = "CanyonDemo"
	arena.get_tree().root.add_child(output)
	level.reparent(output,true)
	level.name = "CanyonLevel"
	_make_groups()
	for node in arena.get_children():
		if node is WorldEnvironment or node is DirectionalLight3D:
			node.reparent(output,true)
			node.name = "Environment" if node is WorldEnvironment else "Sun"
	# Explicit roles survive renaming and moving nodes inside the scene tree.
	_role(level.bridge_body,"bridge_deck","Deck",groups.Bridge)
	level.bridge_body.show()
	for i in level.bridge_guards.size():
		_role(level.bridge_guards[i],"bridge_edge_west" if i==0 else "bridge_edge_east","SafetyEdgeWest" if i==0 else "SafetyEdgeEast",groups.Bridge)
	_role(level.bridge_door,"dash_door","SuperDashDoor",groups.Bridge)
	_role(level.gate,"puzzle_gate","Gate",groups.AtollA)
	level.gate_bars.set_meta("level_role","gate_bars")
	level.gate_bars.name = "Bars"
	_role(level.gate_handle,"gate_handle","PullHandle",groups.AtollA)
	_role(level.platform,"weight_plate","WeightPlate",groups.AtollA)
	_marker("bridge_socket","BridgeSocket",arena.hand.puzzle.socket_position,groups.Bridge)
	_marker("atoll_a","Center",level.A,groups.AtollA)
	_marker("atoll_b","Center",level.B,groups.AtollB)
	_marker("atoll_c","Center",level.C,groups.AtollC)
	_marker("workbench","WorkbenchInteraction",level.A+Vector3(7,0,0),groups.AtollA)
	# Preserve each plateau and ramp's collision and authored transforms.
	for node in level.terrain.get_children(): _geometry(node)
	level.terrain.name = "TerrainData"
	for node in level.get_children():
		if node in groups.values() or node in [level.terrain,level.dressing] or node.get_meta("ore",false): continue
		_geometry(node)
	_convert_dressing()
	for body in arena.targets:
		if body.get_meta("ore",false): continue
		_placement(body,"Powder",_region(body.global_position)).health = float(body.get_meta("hp"))
	for body in arena.props.props: _placement(body,"Prop",_region(body.global_position))
	for body in arena.crew.loot.items:
		_placement(body,"Weight" if body==level.weight else "Cargo",_region(body.global_position))
	for chest in arena.crew.loot.chests:
		chest.lid.name = "Lid"
		_placement(chest.node,"Chest",_region(chest.node.global_position))
	for body in level.ore: _placement(body,"Ore",groups.AtollC).health = float(body.get_meta("hp"))
	_placement(arena.hand.puzzle.cube,"BridgeSection",groups.Bridge)
	var player = Placement.new()
	player.name = "PlayerStart"
	player.kind = "Player"
	groups.Entry.add_child(player)
	player.global_transform = arena.tank.global_transform
	for child in arena.tank.get_children():
		var preview := _visual_copy(child)
		if preview: player.add_child(preview)
	var crowd = arena.battle.crowd
	for entry in spawns:
		if not entry.has("entry_pos") and not entry.has("world_pos"): continue
		var enemy = Placement.new()
		enemy.kind = "Enemy"
		enemy.patrol = entry.has("world_pos")
		enemy.enemy_type = "Shield" if entry.shield_guard else "Ordinary"
		enemy.name = ("PatrolGuard" if entry.shield_guard else "PatrolSkeleton") if enemy.patrol else ("Guard" if entry.shield_guard else "Skeleton")
		var parent = groups.Patrols if enemy.patrol else groups.EntryEnemies
		parent.add_child(enemy,true)
		enemy.global_position = entry.get("world_pos",entry.get("entry_pos",Vector3.ZERO))
		enemy.rotation.y = sin(float(entry.get("slot",0))*2.399)*PI if enemy.patrol else -PI/2
		for spec in [["Skeleton",crowd.bodies],["Shield",crowd.shields],["GuardGear",crowd.guard_gear]]:
			var mesh := MeshInstance3D.new()
			mesh.name = spec[0]
			mesh.mesh = spec[1].mesh
			mesh.material_override = crowd.get_child(0).material_override
			mesh.visible = spec[0]=="Skeleton" or entry.shield_guard
			enemy.add_child(mesh)
	for pos in [level.C+Vector3(-33,0,0),level.C+Vector3(-16,0,-33),level.C+Vector3(-33,0,18)]:
		var wave = Placement.new()
		wave.kind = "MineDefense"
		wave.name = "MineDefense"
		groups.AtollC.add_child(wave,true)
		wave.global_position = pos
		var marker := Marker3D.new()
		marker.gizmo_extents = 2.0
		wave.add_child(marker)
	arena._update_camera(1.0)
	var camera := Camera3D.new()
	camera.name = "GameplayCameraPreview"
	camera.transform = arena.camera.global_transform
	camera.fov = arena.camera.fov
	camera.far = 1000
	output.add_child(camera)
	level.authored = true
	level.set_process_mode(Node.PROCESS_MODE_INHERIT)
	_name_children(output)
	_own(output)
	DirAccess.make_dir_recursive_absolute("res://level_assets")
	_externalize(output)
	# Attach the gameplay script only after leaving the tree: it must not run
	# another game during the conversion.
	arena.get_tree().root.remove_child(output)
	output.set_script(load("res://scripts/arena.gd"))
	output.desert_mode = true
	var scene := PackedScene.new()
	var error := scene.pack(output)
	assert(error==OK)
	error = ResourceSaver.save(scene,"res://desert.tscn")
	assert(error==OK)
	print("CANYON_BAKED: ",spawns.size()," enemy starts; ",next_asset," external mesh/shape resources")
	output.free()
	arena.get_tree().quit()

func _make_groups() -> void:
	for label in ["Ground","Cliffs","Entry","Bridge","AtollA","AtollB","AtollC","Wreck","OpenWorld","Patrols"]:
		var group := Node3D.new()
		group.name = label
		level.add_child(group)
		groups[label] = group
	groups.AtollA.position = Vector3(level.A.x,0,level.A.z)
	groups.AtollB.position = Vector3(level.B.x,0,level.B.z)
	groups.AtollC.position = Vector3(level.C.x,0,level.C.z)
	groups.Entry.position = Vector3(level.START.x,0,0)
	groups.Bridge.position = Vector3(-133,0,0)
	var enemies := Node3D.new()
	enemies.name = "EnemyWave"
	groups.Entry.add_child(enemies)
	groups.EntryEnemies = enemies

func _region(pos: Vector3) -> Node3D:
	if pos.x<-139: return groups.Entry
	if pos.x<-120 and absf(pos.z)<28: return groups.Bridge
	for pair in [[groups.AtollA,level.A,38.0],[groups.AtollB,level.B,38.0],[groups.AtollC,level.C,48.0]]:
		var delta: Vector3 = pos-pair[1]
		if absf(delta.x)<pair[2] and absf(delta.z)<(30.0 if pair[2]<40 else 32.0): return pair[0]
	if pos.distance_to(Vector3(-34,0,4))<18: return groups.Wreck
	return groups.OpenWorld

func _geometry(node: Node3D) -> void:
	var parent := _region(node.global_position)
	if node.get_meta("canyon_occluder",false) and (absf(node.global_position.z)>77 or node.global_position.x<-128 or node.global_position.x>125): parent = groups.Cliffs
	if node is MeshInstance3D and node.mesh is ArrayMesh and node.position==Vector3.ZERO: parent = groups.Ground
	if node is StaticBody3D and node.get_child_count()>0:
		var mesh = node.get_child(0)
		if mesh is MeshInstance3D and mesh.mesh is BoxMesh and mesh.mesh.size.x>70: parent = groups.Ground
	node.reparent(parent,true)
	if str(node.name).begins_with("@"): node.name = "Rock" if node.get_meta("canyon_occluder",false) else "Block"

func _role(node: Node3D, role: String, label: String, parent: Node3D) -> void:
	node.set_meta("level_role",role)
	node.name = label
	node.reparent(parent,true)

func _marker(role: String, label: String, pos: Vector3, parent: Node3D) -> void:
	var marker := Marker3D.new()
	marker.name = label
	marker.set_meta("level_role",role)
	parent.add_child(marker)
	marker.global_position = pos

func _placement(body: PhysicsBody3D, kind: String, parent: Node3D) -> Node3D:
	var placement = Placement.new()
	placement.name = kind
	placement.kind = kind
	placement.process_mode = Node.PROCESS_MODE_DISABLED
	parent.add_child(placement,true)
	placement.global_transform = body.global_transform
	body.reparent(placement,true)
	body.name = "Body"
	body.owner = null
	return placement

func _visual_copy(source: Node) -> Node3D:
	if not source is Node3D or source is CollisionShape3D or source is Light3D: return null
	var node: Node3D
	if source is MeshInstance3D:
		var mesh := MeshInstance3D.new()
		mesh.mesh = source.mesh
		mesh.material_override = source.material_override
		node = mesh
	else: node = Node3D.new()
	node.transform = source.transform
	node.name = source.name
	node.visible = source.visible
	for child in source.get_children():
		var copy := _visual_copy(child)
		if copy: node.add_child(copy)
	return node

func _convert_dressing() -> void:
	for source in level.dressing.get_children():
		if source is MultiMeshInstance3D:
			var parent := Node3D.new()
			parent.name = source.name
			parent.set_meta("batch_instances",true)
			groups.OpenWorld.add_child(parent)
			for i in source.multimesh.instance_count:
				var mesh := MeshInstance3D.new()
				mesh.name = "Rock" if source.name=="Talus" else "Scrub"
				mesh.mesh = source.multimesh.mesh
				mesh.material_override = source.material_override
				mesh.set_meta("instance_tint",source.multimesh.get_instance_color(i))
				mesh.cast_shadow = source.cast_shadow
				parent.add_child(mesh,true)
				mesh.global_transform = source.global_transform*source.multimesh.get_instance_transform(i)
		else:
			var region := _region(source.global_position)
			var deco := region.get_node_or_null("Decoration")
			if deco == null:
				deco = Node3D.new()
				deco.name = "Decoration"
				deco.set_meta("batch_decoration",true)
				region.add_child(deco)
			source.reparent(deco,true)
	level.dressing.get_parent().remove_child(level.dressing)
	level.dressing.queue_free()

func _name_children(node: Node) -> void:
	for child in node.get_children():
		if str(child.name).begins_with("@"):
			child.name = "Mesh" if child is MeshInstance3D else ("Collision" if child is CollisionShape3D else "Part")
		_name_children(child)

func _own(node: Node) -> void:
	for child in node.get_children():
		child.owner = output
		_own(child)

func _asset(resource: Resource) -> void:
	if resource == null or not resource.resource_path.is_empty() or assets.has(resource): return
	assets[resource] = true
	next_asset += 1
	var error := ResourceSaver.save(resource,"res://level_assets/geometry_%04d.res"%next_asset,ResourceSaver.FLAG_COMPRESS|ResourceSaver.FLAG_CHANGE_PATH)
	assert(error==OK)

func _externalize(node: Node) -> void:
	if node is MeshInstance3D and node.mesh is ArrayMesh: _asset(node.mesh)
	if node is CollisionShape3D and node.shape is ConvexPolygonShape3D: _asset(node.shape)
	for child in node.get_children(): _externalize(child)
