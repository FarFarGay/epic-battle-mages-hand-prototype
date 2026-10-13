extends SceneTree
## Builds only the new editable mine subscene, never rebakes the authored canyon.
const Geo = preload("res://scripts/geo.gd")
const Placement = preload("res://scripts/level_placement.gd")
var mine: Node3D
var cells := {}
var ore_count := 0

func gallery(x: float, z: float) -> bool:
	return (x>=20 and x<=125 and absf(z)<=7.5) or (x>=50 and x<=72.5 and z>=-17.5 and z<=0) or (x>=80 and x<=105 and z>=5 and z<=32.5) or (x>=115 and x<=137.5 and z>=-12.5 and z<=20)

func cavity(x: float, z: float) -> bool:
	return x<=32.5 or (x>=55 and x<=65 and z>=-15 and z<=-10) or (x>=87.5 and x<=100 and z>=22.5 and z<=27.5) or (x>=125 and x<=135 and z>=-5 and z<=12.5)

func own(node: Node) -> void:
	for child in node.get_children():
		child.owner = mine
		own(child)

func _initialize() -> void:
	var original = load("res://desert.tscn").instantiate()
	var template = original.get_node_or_null("CanyonLevel/AtollC/Ore/Body")
	if not template:
		var existing = load("res://scenes/deep_mine.tscn").instantiate()
		template = existing.get_node("Deposits/Ore0000/Body").duplicate()
		existing.free()
	else: template = template.duplicate()
	original.free()
	mine = Node3D.new()
	mine.name = "DeepMine"
	for name in ["Deposits","Walls","Roof","Supports","Markers"]:
		var group := Node3D.new()
		group.name = name
		mine.add_child(group)
	var floor_body := StaticBody3D.new()
	floor_body.name = "MineFloor"
	floor_body.collision_layer = 1|1024
	floor_body.set_meta("ground_kind","mesa")
	mine.add_child(floor_body)
	var shape := ConvexPolygonShape3D.new()
	var floor_points := PackedVector3Array()
	for y in [0.0,4.0]:
		for p in [Vector2(18,-21),Vector2(142,-21),Vector2(142,38),Vector2(18,38)]:
			floor_points.append(Vector3(p.x,y,p.y))
	shape.points = floor_points
	var collider := CollisionShape3D.new()
	collider.shape = shape
	floor_body.add_child(collider)
	Geo.box(floor_body,Vector3(124,0.3,59),Vector3(80,3.875,8.5),Geo.material(Color("424d50")))
	var wall_mat := Geo.material(Color("596767"))
	var cap_mat := Geo.material(Color("303b42"))
	var timber := Geo.material(Color("66513e"))
	var lamp := Geo.material(Color("edbf69"),0.0,1.0)
	var wall_mesh := CylinderMesh.new()
	wall_mesh.top_radius = 1.6
	wall_mesh.bottom_radius = 1.9
	wall_mesh.height = 7.5
	wall_mesh.radial_segments = 6
	var wall_shape := BoxShape3D.new()
	wall_shape.size = Vector3(2.5,7.5,2.5)
	for ix in range(7,58):
		for iz in range(-9,17):
			var x := ix*2.5
			var z := iz*2.5
			if gallery(x,z): cells[Vector2i(ix,iz)] = true
	for cell in cells:
		var x: float = cell.x*2.5
		var z: float = cell.y*2.5
		if cavity(x,z): continue
		var ore := Placement.new()
		ore.name = "Ore%04d"%ore_count
		ore.kind = "Ore"
		ore.position = Vector3(x,4,z)
		mine.get_node("Deposits").add_child(ore)
		var body = template.duplicate()
		body.name = "Body"
		body.transform = Transform3D.IDENTITY
		ore.add_child(body)
		ore_count += 1
	var borders := {}
	for cell in cells:
		for offset in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
			var next: Vector2i = cell+offset
			if not cells.has(next) and next.x>=8: borders[next] = true
	for cell in borders:
		var body := StaticBody3D.new()
		body.name = "Rock_%d_%d"%[cell.x,cell.y]
		body.position = Vector3(cell.x*2.5,4,cell.y*2.5)
		mine.get_node("Walls").add_child(body)
		Geo.mesh(body,wall_mesh,Vector3.UP*3.75,wall_mat)
		var collision := CollisionShape3D.new()
		collision.shape = wall_shape
		collision.position.y = 3.75
		body.add_child(collision)
	# Solid overhead sections conceal distant chambers, opening around the player.
	for x in range(40,141,10):
		for z in range(-20,40,10):
			var needed := false
			for dx in [-2.5,2.5]:
				for dz in [-2.5,2.5]: needed = needed or gallery(x+dx,z+dz)
			if needed:
				var roof := Geo.box(mine.get_node("Roof"),Vector3(10.05,1.1,10.05),Vector3(x,11.6,z),cap_mat)
				roof.name = "Roof_%d_%d"%[x,z]
	for x in [23,30,57,90,122]:
		for z in [-8.0,8.0]:
			Geo.box(mine.get_node("Supports"),Vector3(0.45,5.2,0.45),Vector3(x,6.6,z),timber)
			Geo.box(mine.get_node("Supports"),Vector3(0.22,0.45,0.22),Vector3(x,7,z-signf(z)*0.45),lamp)
		Geo.box(mine.get_node("Supports"),Vector3(0.55,0.45,16.5),Vector3(x,9.1,0),timber)
	for spec in [["Entrance",Vector3(25,4,0)],["FirstFace",Vector3(35,4,0)],["NorthPocket",Vector3(60,4,-12.5)],["SouthPocket",Vector3(95,4,25)],["DeepChamber",Vector3(130,4,5)]]:
		var marker := Marker3D.new()
		marker.name = spec[0]
		marker.position = spec[1]
		mine.get_node("Markers").add_child(marker)
	mine.get_node("Supports").set_meta("batch_decoration",true)
	mine.set_script(load("res://scripts/deep_mine.gd"))
	own(mine)
	var scene := PackedScene.new()
	assert(scene.pack(mine)==OK)
	assert(ResourceSaver.save(scene,"res://scenes/deep_mine.tscn")==OK)
	print("DEEP_MINE_BUILT: ore=",ore_count," length=120m walls=",borders.size())
	template.free()
	mine.free()
	quit()
