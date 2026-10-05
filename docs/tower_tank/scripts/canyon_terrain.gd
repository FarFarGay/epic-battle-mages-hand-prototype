extends Node3D
## Stepped sandstone masses, raised playable shelves and continuous ramp colliders.
const Geo = preload("res://scripts/geo.gd")
var level
var shelves: Array[Dictionary] = []
var ramps: Array[Dictionary] = []
var faded: Array[StaticBody3D] = []
var strata := [Geo.material(Color("775044")),Geo.material(Color("995f48")),Geo.material(Color("b48057")),Geo.material(Color("c79c6a"))]
var top_mat := Geo.material(Color("93846b"))
var rim_mat := Geo.material(Color("796b68"))
var ghost_materials: Dictionary = {}

func _box(pos: Vector3, size: Vector3, material: Material, solid: bool = false) -> Node3D:
	return level.block(pos,size,material,solid)

func plateau(center: Vector3, diameter: float) -> void:
	var radius := diameter*0.5
	var limit := diameter-6.0 if diameter<40 else diameter-10.0
	for z in range(int(-radius),int(radius),4):
		var half := radius
		while half-2.0+absf(z+2.0)>limit: half-=4.0
		var bounds := Rect2(center.x-half,center.z+z,half*2,4)
		shelves.append({"bounds":bounds,"height":center.y})
		var rock := _box(Vector3(center.x,0,center.z+z+2),Vector3(half*2,center.y,4),strata[1],true)
		rock.collision_layer=1|1024
		# The cap replaces the top six centimetres; coincident faces flicker in perspective.
		rock.get_child(0).mesh.size.y=center.y-0.06
		rock.get_child(0).position.y=(center.y-0.06)*0.5
		Geo.box(rock,Vector3(half*2+0.18,0.55,4.06),Vector3(0,center.y*0.43,0),strata[0])
		Geo.box(rock,Vector3(half*2+0.12,0.36,4.04),Vector3(0,center.y-0.5,0),strata[2])
		Geo.box(rock,Vector3(half*2,0.06,4),Vector3(0,center.y-0.03,0),top_mat)
		# A few offset vertical blocks break the shelf silhouette; never a wall above it.
		for side in [-1,1]:
			var width := 0.65+0.15*posmod(z,3)
			_box(Vector3(center.x+side*(half+0.1),0,center.z+z+2),Vector3(width,center.y-0.4,2.8),strata[posmod(z,3)],false)

func ramp(from: Vector3, to: Vector3, width: float) -> void:
	var along := Vector3(to.x-from.x,0,to.z-from.z)
	var length := along.length()
	var direction := along/length
	var side := direction.cross(Vector3.UP)
	ramps.append({"from":from,"to":to,"direction":direction,"side":side,"length":length,"width":width})
	var body := StaticBody3D.new()
	add_child(body)
	body.collision_layer=1|1024
	body.position=from
	body.basis=Basis(direction,Vector3.UP,side)
	var rise := to.y-from.y
	var points := PackedVector3Array([Vector3(0,-0.4,-width/2),Vector3(0,-0.4,width/2),Vector3(length,-0.4,width/2),Vector3(length,-0.4,-width/2),Vector3(0,0,-width/2),Vector3(0,0,width/2),Vector3(length,rise,width/2),Vector3(length,rise,-width/2)])
	var shape := ConvexPolygonShape3D.new()
	shape.points=points
	var collider := CollisionShape3D.new()
	collider.shape=shape
	body.add_child(collider)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in [[4,7,6,5],[0,1,2,3],[0,3,7,4],[1,5,6,2],[3,2,6,7],[0,4,5,1]]:
		var normal := -(points[face[1]]-points[face[0]]).cross(points[face[2]]-points[face[0]]).normalized()
		for index in [face[0],face[1],face[2],face[0],face[2],face[3]]:
			surface.set_normal(normal)
			surface.add_vertex(points[index])
	Geo.mesh(body,surface.commit(),Vector3.ZERO,top_mat)
	# Flat seams provide scale without making stairs collide with the feet.
	for i in range(1,int(length/2)):
		var t := float(i)*2/length
		var seam := Geo.box(body,Vector3(0.045,0.012,width),Vector3(t*length,t*rise+0.012,0),rim_mat)
		seam.rotation.z=atan2(rise,length)

func height_at(point: Vector3) -> float:
	var height := 0.0
	var flat := Vector2(point.x,point.z)
	for shelf in shelves:
		if shelf.bounds.has_point(flat): height=maxf(height,shelf.height)
	for slope in ramps:
		var delta: Vector3=point-slope.from
		delta.y=0
		var along: float=delta.dot(slope.direction)
		if along>=-0.01 and along<=slope.length+0.01 and absf(delta.dot(slope.side))<=slope.width*0.5:
			height=maxf(height,lerpf(slope.from.y,slope.to.y,clampf(along/slope.length,0,1)))
	return height

func cliff_chain(from: Vector3, to: Vector3, outward: Vector3, height: float=18.0) -> void:
	var length := from.distance_to(to)
	var along := (to-from).normalized()
	var count := ceili(length/12.0)
	for i in count:
		var center := from+along*((i+0.5)*length/count)
		var h := height+sin(float(i)*0.9+from.x)*2.4+sin(i*2.7)*0.8
		var root := StaticBody3D.new()
		add_child(root)
		root.position=center+outward*10.1
		root.basis=Basis(along,Vector3.UP,along.cross(Vector3.UP))
		Geo.collider(root,Vector3(length/count+0.08,h,20),Vector3(0,h*0.5,0))
		for layer in 3:
			var size := Vector3(length/count+0.12-layer*0.35,h/3,20-layer*3.0)
			Geo.box(root,size,Vector3(sin(i+layer)*0.18,(layer+0.5)*h/3,0),strata[layer])
		Geo.box(root,Vector3(length/count-0.5,0.24,13.8),Vector3(0,h+0.12,0),top_mat)
		root.set_meta("canyon_occluder",true)

func crag(center: Vector3, size: Vector3, seed: int) -> void:
	var root := _box(center,Vector3(size.x,size.y*0.5,size.z),strata[seed%3],true) as StaticBody3D
	Geo.box(root,Vector3(size.x*0.9,size.y*0.5,size.z*0.92),Vector3(size.x*0.04,size.y*0.73,-size.z*0.03),strata[(seed+1)%3])
	Geo.collider(root,Vector3(size.x*0.9,size.y*0.5,size.z*0.92),Vector3(size.x*0.04,size.y*0.73,-size.z*0.03))
	Geo.box(root,Vector3(size.x*0.86,0.2,size.z*0.86),Vector3(size.x*0.04,size.y,-size.z*0.03),top_mat)
	root.set_meta("canyon_occluder",true)

func update_occlusion(camera: Camera3D, focus: Vector3) -> void:
	var next: Array[StaticBody3D]=[]
	var samples: Array[Vector3]=[]
	var forward := -camera.global_basis.z
	forward.y=0
	forward=forward.normalized()
	# Clear a patch of ground around the feet as well as the upper tower.
	# A ray to the torso alone leaves neighbouring cliff caps across the boots.
	for side in [-6.0,0.0,6.0]:
		for depth in [-6.0,0.0,6.0]:
			var point: Vector3 = focus+camera.global_basis.x*side+forward*depth
			point.y=level.ground_height(point)+0.25
			samples.append(point)
	for side in [-3.0,0.0,3.0]: samples.append(focus+Vector3.UP*5.5+camera.global_basis.x*side)
	for point in samples:
		var excluded: Array[RID]=[]
		for i in 5:
			var ray := PhysicsRayQueryParameters3D.create(camera.global_position,point,1,excluded)
			var hit := get_world_3d().direct_space_state.intersect_ray(ray)
			if hit.is_empty() or not hit.collider.has_meta("canyon_occluder"): break
			var body: StaticBody3D=hit.collider
			excluded.append(body.get_rid())
			if not next.has(body): next.append(body)
	for body in faded:
		if not next.has(body): _fade(body,false)
	for body in next:
		if not faded.has(body): _fade(body,true)
	faded=next

func _fade(body: StaticBody3D, value: bool) -> void:
	for child in body.get_children():
		if not child is MeshInstance3D: continue
		if not child.has_meta("opaque_material"): child.set_meta("opaque_material",child.material_override)
		var mat: StandardMaterial3D=child.get_meta("opaque_material")
		if value and not ghost_materials.has(mat):
			var ghost := mat.duplicate() as StandardMaterial3D
			ghost.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
			ghost.albedo_color.a=0.16
			ghost_materials[mat]=ghost
		child.material_override=ghost_materials[mat] if value else mat
