extends SceneTree
const Placement = preload("res://scripts/level_placement.gd")
var checks := {}
var expected := {}
var directory := "res://verification/editor_scene"

func _initialize() -> void:
	_run.call_deferred()

func _world(node: Node3D) -> Transform3D:
	var transform := node.transform
	var parent := node.get_parent()
	while parent is Node3D:
		transform = parent.transform * transform
		parent = parent.get_parent()
	return transform

func _own(node: Node, owner_root: Node) -> void:
	for child in node.get_children():
		child.owner = owner_root
		_own(child,owner_root)

func _strip_scripts(node: Node) -> void:
	for child in node.get_children(): _strip_scripts(child)
	node.set_script(null)
	if node is RigidBody3D: node.freeze = true

func _capture_scene() -> void:
	var preview = load("res://desert.tscn").instantiate()
	checks.scene_contains_geometry_without_running = preview.find_children("*","MeshInstance3D",true,false).size()>2000
	checks.scene_contains_colliders_without_running = preview.find_children("*","CollisionShape3D",true,false).size()>300
	if DisplayServer.get_name()!="headless":
		_strip_scripts(preview)
		root.add_child(preview)
		var camera: Camera3D = preview.get_node("GameplayCameraPreview")
		camera.current = true
		for spec in [[Vector3(-52,0,0),Vector3(65,260,210),"editor_overview.png"],[Vector3(-190,0,0),Vector3(-23,40,23),"editor_entry.png"],[Vector3(48,4,10),Vector3(40,65,48),"editor_mine.png"]]:
			camera.position = spec[0]+spec[1]
			camera.look_at(spec[0])
			for i in 4: await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(directory.path_join(spec[2]))
		root.remove_child(preview)
	preview.free()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	await _capture_scene()
	var saved = load("res://desert.tscn").instantiate()
	var level = saved.get_node("CanyonLevel")
	var nodes: Array = saved.find_children("*","Node3D",true,false)
	var props: Array = nodes.filter(func(n): return n is Placement and n.kind=="Prop")
	var ores: Array = nodes.filter(func(n): return n is Placement and n.kind=="Ore")
	var powder: Array = nodes.filter(func(n): return n is Placement and n.kind=="Powder")
	var entry: Array = nodes.filter(func(n): return n is Placement and n.kind=="Enemy" and not n.patrol)
	checks.authored_counts_match_game = props.size()==72 and powder.size()==18 and entry.size()==240
	checks.authored_patrol_count = nodes.filter(func(n): return n is Placement and n.kind=="Enemy" and n.patrol).size()==120
	# Reproduce actual editor operations, then SAVE and RELOAD the fixture.
	var prop = props[0]
	prop.position += Vector3(0,0,1.7)
	prop.rotation.y += 0.5
	var body = prop.get_node("Body")
	var mesh = body.find_children("*","MeshInstance3D",true,false)[0]
	mesh.mesh = mesh.mesh.duplicate()
	mesh.mesh.size.x = 1.2
	var collider = body.find_children("*","CollisionShape3D",true,false)[0]
	collider.shape = collider.shape.duplicate()
	collider.shape.size.x = 1.2
	body.set_meta("edited_fixture",true)
	expected.prop = _world(body)
	var copy = prop.duplicate()
	copy.position += Vector3(2,0,0)
	prop.get_parent().add_child(copy)
	var ore = ores[0]
	ore.health = 120.0
	ore.position += Vector3(0,0,0.2)
	ore.get_node("Body").set_meta("edited_ore",true)
	expected.ore = _world(ore.get_node("Body"))
	var deleted = ores.back()
	deleted.get_parent().remove_child(deleted)
	deleted.free()
	var atoll = level.get_node("AtollA")
	atoll.position += Vector3(1.5,0,2.0)
	atoll.rotation.y = 0.1
	expected.atoll = _world(atoll.get_node("Center")).origin
	var plate = atoll.get_node("WeightPlate")
	expected.plate = _world(plate).origin
	var ramp = atoll.get_node("Ramp")
	var ramp_shape = ramp.find_children("*","CollisionShape3D",true,false)[0]
	var points: PackedVector3Array = ramp_shape.shape.points
	expected.ramp = _world(ramp_shape)*((points[4]+points[5]+points[6]+points[7])*0.25)
	var bridge = level.get_node("Bridge")
	bridge.position.z += 1.0
	bridge.rotation.y = 0.07
	expected.socket = _world(bridge.find_children("*","Marker3D",true,false).filter(func(n): return n.get_meta("level_role","")=="bridge_socket")[0]).origin
	var start = level.get_node("Entry/PlayerStart")
	start.position += Vector3(2,0,0)
	start.rotation.y += 0.2
	expected.player = _world(start)
	entry[0].enabled = false
	entry[1].enemy_type = "Giant"
	entry[2].position += Vector3(0.3,0,0.2)
	expected.enemy = _world(entry[2]).origin
	_own(saved,saved)
	var packed := PackedScene.new()
	checks.edited_scene_packs = packed.pack(saved)==OK
	var path := directory.path_join("edited_fixture.tscn")
	checks.edited_scene_saves = ResourceSaver.save(packed,path)==OK
	saved.free()
	var arena = ResourceLoader.load(path,"",ResourceLoader.CACHE_MODE_IGNORE).instantiate()
	root.add_child(arena)
	level = arena.level
	arena.set_physics_process(false)
	checks.player_transform_used = arena.tank.position.distance_to(expected.player.origin)<0.001 and absf(arena.tank.rotation.y-expected.player.basis.get_euler().y)<0.001
	checks.atoll_marker_follows_transform = level.A.distance_to(expected.atoll)<0.001
	checks.atoll_collision_height_follows_transform = is_equal_approx(level.ground_height(level.A),4.0)
	checks.puzzle_plate_follows_transform = level.platform_rest.distance_to(expected.plate)<0.001
	checks.props_can_be_duplicated = arena.props.props.size()==73
	var edited: Array = arena.props.props.filter(func(p): return p.has_meta("edited_fixture"))
	checks.prop_transform_used = edited.size()==2 and edited[0].global_transform.is_equal_approx(expected.prop)
	checks.edited_mesh_used = is_equal_approx(edited[0].find_children("*","MeshInstance3D",true,false)[0].mesh.size.x,1.2)
	checks.edited_collision_used = is_equal_approx(edited[0].find_children("*","CollisionShape3D",true,false)[0].shape.size.x,1.2)
	checks.rotated_ramp_height_follows_scene = is_equal_approx(level.ground_height(expected.ramp),expected.ramp.y)
	checks.bridge_socket_follows_group = arena.hand.puzzle.socket_position.distance_to(expected.socket)<0.001
	checks.ore_can_be_deleted = level.ore.size()==ores.size()-1
	var edited_ore = level.ore.filter(func(o): return o.has_meta("edited_ore"))[0]
	checks.ore_position_and_health_used = edited_ore.global_position.distance_to(expected.ore.origin)<0.001 and edited_ore.get_meta("hp")==120.0
	checks.enemy_disabled = level.spawn_queue.size()==239
	checks.enemy_count_reflects_editor_deletions = level.ENTRY_ATTACK_SIZE==239 and level.WORLD_SKELETONS==120
	checks.enemy_variant_used = level.spawn_queue.any(func(e): return e.get("giant",false))
	checks.enemy_position_used = level.spawn_queue.any(func(e): return e.get("entry_pos",Vector3.INF).distance_to(expected.enemy)<0.001)
	checks.no_hidden_placement_duplicates = level.find_children("*","Node3D",true,false).filter(func(n): return n is Placement).is_empty()
	checks.ore_index_uses_edited_position = level.ore_cells[level._ore_cell(expected.ore.origin)].has(edited_ore)
	level.unlocked = true
	level.gate_handle.hand_move(level.gate_handle.home-level.gate_handle.global_basis.x.normalized()*2.0)
	checks.rotated_puzzle_handle_works = level.gate_open
	level.cancel_spawning()
	arena.props.shatter(edited[0])
	level.automatic_encounters = false
	level.damage_ore(edited_ore,1000.0,Vector3.RIGHT)
	arena.reset_range()
	level.cancel_spawning()
	checks.reset_restores_edited_layout = arena.props.props.size()==73 and level.ore.size()==ores.size()-1 and arena.tank.position.distance_to(expected.player.origin)<0.001
	checks.reset_restores_edited_ore_health = level.ore.filter(func(o): return o.has_meta("edited_ore"))[0].get_meta("hp")==120.0
	checks.no_duplicate_hand_registrations = arena.props.props.all(func(p): return p.is_in_group(arena.hand.ITEM_GROUP))
	var report := {"passed":checks.values().all(func(v):return v),"checks":checks}
	var file := FileAccess.open(directory.path_join("layout_check.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	print("LAYOUT_CHECK: ",JSON.stringify(report))
	quit(0 if report.passed else 1)
