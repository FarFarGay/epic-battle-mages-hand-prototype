extends SceneTree
## One-time creation of ordinary editable PackedScenes. Never overwrites the map.
const Geo = preload("res://scripts/geo.gd")

func _initialize() -> void:
	_run.call_deferred()

func _own(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own(child,owner_node)

func _save(node: Node, path: String) -> void:
	_own(node,node)
	var packed := PackedScene.new()
	var error := packed.pack(node)
	assert(error==OK)
	error = ResourceSaver.save(packed,path)
	assert(error==OK)
	node.free()

func _run() -> void:
	if FileAccess.file_exists("res://scenes/defense_tower.tscn"):
		push_error("Defense prefabs already exist. Edit their scenes directly.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://scenes")
	var stone := Geo.material(Color("b8ad90"))
	var wood := Geo.material(Color("76583e"))
	var iron := Geo.material(Color("445d61"),0.5)
	var gold := Geo.material(Color("dcad58"),0.3)
	var teal := Geo.material(Color("63cfc1"),0.2,0.3)
	var tower := StaticBody3D.new()
	tower.name = "DefenseTower"
	tower.collision_layer = 0
	tower.collision_mask = 0
	root.add_child(tower)
	Geo.cylinder(tower,1.12,0.35,Vector3(0,0.175,0),stone,8).name = "Foundation"
	Geo.cylinder(tower,0.86,0.5,Vector3(0,0.58,0),stone,8)
	for x in [-0.60,0.60]:
		for z in [-0.60,0.60]:
			Geo.box(tower,Vector3(0.24,1.75,0.24),Vector3(x,1.5,z),wood)
	Geo.line(tower,Vector3(-0.6,0.8,0.6),Vector3(0.6,2.3,0.6),0.15,wood)
	Geo.line(tower,Vector3(0.6,0.8,0.6),Vector3(-0.6,2.3,0.6),0.15,wood)
	Geo.line(tower,Vector3(-0.6,0.8,-0.6),Vector3(-0.6,2.3,0.6),0.15,wood)
	Geo.cylinder(tower,1.1,0.2,Vector3(0,2.4,0),wood,8)
	Geo.cylinder(tower,0.7,0.16,Vector3(0,2.57,0),iron,12)
	var turret := Node3D.new()
	turret.name = "Turret"
	tower.add_child(turret)
	turret.position.y = 2.9
	Geo.box(turret,Vector3(1.05,0.6,0.8),Vector3(0,0,0.15),iron)
	Geo.box(turret,Vector3(1.2,0.13,0.95),Vector3(0,0.36,0.1),gold)
	Geo.box(turret,Vector3(0.48,0.3,0.65),Vector3(0,0.60,0.15),wood).name = "BoltMagazine"
	for i in 4: Geo.box(turret,Vector3(0.05,0.05,0.6),Vector3(-0.15+i*0.10,0.79,0.08),gold)
	var rail := Node3D.new()
	rail.name = "Rail"
	turret.add_child(rail)
	Geo.box(rail,Vector3(0.22,0.22,1.8),Vector3(0,0,-0.65),wood)
	Geo.box(rail,Vector3(0.1,0.1,1.95),Vector3(0,0.15,-0.75),iron)
	Geo.line(rail,Vector3(-1.05,0,-0.8),Vector3(0,0,-1.2),0.14,iron)
	Geo.line(rail,Vector3(1.05,0,-0.8),Vector3(0,0,-1.2),0.14,iron)
	Geo.line(rail,Vector3(-1.05,0,-0.8),Vector3(0,0,-0.2),0.03,gold)
	Geo.line(rail,Vector3(1.05,0,-0.8),Vector3(0,0,-0.2),0.03,gold)
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	rail.add_child(muzzle)
	muzzle.position = Vector3(0,0.1,-1.8)
	var col := CollisionShape3D.new()
	col.name = "Collision"
	var shape := CylinderShape3D.new()
	shape.radius = 0.92
	shape.height = 3.5
	col.shape = shape
	tower.add_child(col)
	col.position.y = 1.75
	tower.set_script(load("res://scripts/defense_tower.gd"))
	_save(tower,"res://scenes/defense_tower.tscn")
	var site := Node3D.new()
	site.name = "DefenseSite"
	root.add_child(site)
	Geo.cylinder(site,1.55,0.10,Vector3(0,0.05,0),stone,12).name = "Platform"
	Geo.ring(site,1.43,0.12,Vector3(0,0.13,0),teal).name = "BuildRing"
	Geo.box(site,Vector3(1.35,0.02,0.15),Vector3(0,0.115,0),iron)
	Geo.box(site,Vector3(0.15,0.02,1.35),Vector3(0,0.115,0),iron)
	for i in 4:
		var pos := Vector3.RIGHT.rotated(Vector3.UP,i*PI/2)*1.40
		pos.y = 0.19
		Geo.box(site,Vector3(0.28,0.25,0.28),pos,gold)
	var pick := StaticBody3D.new()
	pick.name = "Pick"
	pick.collision_layer = 2048
	pick.collision_mask = 0
	site.add_child(pick)
	var pick_shape := CylinderShape3D.new()
	pick_shape.radius = 1.65
	pick_shape.height = 0.35
	col = CollisionShape3D.new()
	col.shape = pick_shape
	pick.add_child(col)
	col.position.y = 0.175
	site.set_script(load("res://scripts/defense_site.gd"))
	site.tower_scene = load("res://scenes/defense_tower.tscn")
	_save(site,"res://scenes/defense_site.tscn")
	print("DEFENSE_PREFABS_SAVED")
	quit()
