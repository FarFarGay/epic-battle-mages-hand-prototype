extends Node3D
## Faceted sandstone models with flat playable caps and continuous ramp colliders.
const Geo = preload("res://scripts/geo.gd")
var level
var shelves: Array[Dictionary] = []
var ramps: Array[Dictionary] = []
var faded: Array[StaticBody3D] = []
var strata := [Color("4b6063"),Color("7a8178"),Color("979787")]
var top_color := Color("a6a08a")
var model_material := Geo.material(Color.WHITE)
var ghost_materials: Dictionary = {}
var occlusion_wait := 0.0
var last_focus := Vector3(INF,0,0)
var last_camera := Vector3(INF,0,0)
const HEIGHT_CELL := 8.0
var height_cells: Dictionary = {}
var indexed_shelves := -1
var indexed_ramps := -1

func _ready() -> void:
	model_material.vertex_color_use_as_albedo = true
	model_material.vertex_color_is_srgb = true
	model_material.roughness = 0.94
	var ghost := model_material.duplicate() as StandardMaterial3D
	ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost.albedo_color.a = 0.16
	ghost_materials[model_material] = ghost

func _footprint(size: Vector2, cut: float) -> PackedVector2Array:
	var x := size.x*0.5
	var z := size.y*0.5
	cut = minf(cut,minf(x,z)*0.7)
	return PackedVector2Array([Vector2(-x+cut,-z),Vector2(x-cut,-z),Vector2(x,-z+cut),Vector2(x,z-cut),Vector2(x-cut,z),Vector2(-x+cut,z),Vector2(-x,z-cut),Vector2(-x,-z+cut)])

func _ring(footprint: PackedVector2Array, y: float, scale: Vector2 = Vector2.ONE, offset: Vector2 = Vector2.ZERO) -> PackedVector3Array:
	var result := PackedVector3Array()
	for point in footprint:
		point = point*scale+offset
		result.append(Vector3(point.x,y,point.y))
	return result

func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var normal := -(b-a).cross(c-a).normalized()
	for point in [a,b,c]:
		surface.set_normal(normal)
		surface.set_color(color)
		surface.add_vertex(point)

func _model(center: Vector3, rings: Array, seed: int, solid: bool = true, cap_material: Material = null) -> StaticBody3D:
	var body := StaticBody3D.new()
	add_child(body)
	body.position = center
	body.collision_layer = 1
	body.collision_mask = 0
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for band in range(rings.size()-1):
		var lower: PackedVector3Array = rings[band]
		var upper: PackedVector3Array = rings[band+1]
		for i in lower.size():
			var j := (i+1)%lower.size()
			var steps := maxi(1,ceili((upper[i].y-lower[i].y)/1.5))
			for layer in steps:
				var t0 := float(layer)/steps
				var t1 := float(layer+1)/steps
				var color: Color = strata[mini(band,2)].lerp(strata[mini(band+1,2)],t0*0.45)
				color = color.darkened(0.025*float(posmod(i+seed,3))+0.045*float(posmod(layer+seed,3)))
				if posmod(layer+band,4)==0: color=color.lerp(Color("92745f"),0.14)
				var a := lower[i].lerp(upper[i],t0)
				var b := lower[j].lerp(upper[j],t0)
				var c := lower[j].lerp(upper[j],t1)
				var d := lower[i].lerp(upper[i],t1)
				if layer>0:
					a.y+=sin(float(seed+i)*1.8+layer*3.0)*0.10
					b.y+=sin(float(seed+j)*1.8+layer*3.0)*0.10
				if layer<steps-1:
					c.y+=sin(float(seed+j)*1.8+(layer+1)*3.0)*0.10
					d.y+=sin(float(seed+i)*1.8+(layer+1)*3.0)*0.10
				var seam_a := a.lerp(d,0.065)
				var seam_b := b.lerp(c,0.065)
				_triangle(surface,a,b,seam_b,color.darkened(0.09))
				_triangle(surface,a,seam_b,seam_a,color.darkened(0.09))
				_triangle(surface,seam_a,seam_b,c,color)
				_triangle(surface,seam_a,c,d,color.lightened(0.015))
	var top: PackedVector3Array = rings.back()
	var middle := Vector3.ZERO
	for point in top: middle+=point
	middle/=top.size()
	var cap_surface := surface
	if cap_material:
		cap_surface = SurfaceTool.new()
		cap_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in top.size(): _triangle(cap_surface,middle,top[i],top[(i+1)%top.size()],top_color)
	Geo.mesh(body,surface.commit(),Vector3.ZERO,model_material)
	if cap_material: Geo.mesh(body,cap_surface.commit(),Vector3.ZERO,cap_material)
	if solid:
		var points := PackedVector3Array()
		for ring in rings: points.append_array(ring)
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		var collider := CollisionShape3D.new()
		collider.shape = shape
		body.add_child(collider)
	return body

func _box(pos: Vector3, size: Vector3, material: Material, solid: bool = false) -> Node3D:
	return level.block(pos,size,material,solid)

func plateau(center: Vector3, diameter: float) -> void:
	var radius := diameter*0.5
	var footprint := _footprint(Vector2(diameter,diameter),4.0 if diameter<40 else 8.0)
	var polygon := PackedVector2Array()
	for point in footprint: polygon.append(point+Vector2(center.x,center.z))
	shelves.append({"bounds":Rect2(center.x-radius,center.z-radius,diameter,diameter).grow(0.01),"polygon":polygon,"height":center.y})
	var rings := [_ring(footprint,0,Vector2(1.025,1.025)),_ring(footprint,center.y*0.45,Vector2(1.015,1.015)),_ring(footprint,center.y-0.45),_ring(footprint,center.y)]
	var body := _model(Vector3(center.x,0,center.z),rings,int(diameter),true,level.dressing.worn_material)
	body.name = "AtollMesa"
	body.set_meta("ground_kind", "mesa")
	body.collision_layer = 1|1024

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
	body.name = "Ramp"
	body.set_meta("ground_kind", "ramp")
	var rise := to.y-from.y
	var points := PackedVector3Array([Vector3(0,-0.4,-width/2),Vector3(0,-0.4,width/2),Vector3(length,-0.4,width/2),Vector3(length,-0.4,-width/2),Vector3(0,0,-width/2),Vector3(0,0,width/2),Vector3(length,rise,width/2),Vector3(length,rise,-width/2)])
	var shape := ConvexPolygonShape3D.new()
	shape.points=points
	var collider := CollisionShape3D.new()
	collider.shape=shape
	body.add_child(collider)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top_surface := SurfaceTool.new()
	top_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in [[4,7,6,5],[0,1,2,3],[0,3,7,4],[1,5,6,2],[3,2,6,7],[0,4,5,1]]:
		var normal := -(points[face[1]]-points[face[0]]).cross(points[face[2]]-points[face[0]]).normalized()
		var target := top_surface if face[0]==4 else surface
		for index in [face[0],face[1],face[2],face[0],face[2],face[3]]:
			target.set_normal(normal)
			target.set_color(top_color if face[0]==4 else strata[1])
			target.add_vertex(points[index])
	Geo.mesh(body,surface.commit(),Vector3.ZERO,model_material)
	Geo.mesh(body,top_surface.commit(),Vector3.ZERO,level.dressing.worn_material)

func height_at(point: Vector3) -> float:
	# The level is static between loads. Only inspect surfaces overlapping this
	# tile; retain the exact polygon/ramp tests (no quantized heights at seams).
	if indexed_shelves!=shelves.size() or indexed_ramps!=ramps.size(): rebuild_height_index()
	var height := 0.0
	var flat := Vector2(point.x,point.z)
	var cell := Vector2i(floori(point.x/HEIGHT_CELL),floori(point.z/HEIGHT_CELL))
	if not height_cells.has(cell): return height
	for index in height_cells[cell]:
		if index<shelves.size():
			var shelf: Dictionary = shelves[index]
			if shelf.bounds.has_point(flat) and Geometry2D.is_point_in_polygon(flat,shelf.polygon): height=maxf(height,shelf.height)
		else:
			var slope: Dictionary = ramps[index-shelves.size()]
			var delta: Vector3=point-slope.from
			delta.y=0
			var along: float=delta.dot(slope.direction)
			if along>=-0.01 and along<=slope.length+0.01 and absf(delta.dot(slope.side))<=slope.width*0.5:
				height=maxf(height,lerpf(slope.from.y,slope.to.y,clampf(along/slope.length,0,1)))
	return height

func rebuild_height_index() -> void:
	height_cells.clear()
	indexed_shelves = shelves.size()
	indexed_ramps = ramps.size()
	for index in shelves.size()+ramps.size():
		var bounds: Rect2
		if index<shelves.size(): bounds = shelves[index].bounds
		else:
			var slope: Dictionary = ramps[index-shelves.size()]
			bounds = Rect2(Vector2(slope.from.x,slope.from.z),Vector2.ZERO)
			for end in [slope.from,slope.to]:
				for sign in [-1.0,1.0]:
					var edge: Vector3 = end+slope.side*slope.width*0.5*sign
					bounds = bounds.expand(Vector2(edge.x,edge.z))
			bounds = bounds.grow(0.02)
		var low := Vector2i((bounds.position/HEIGHT_CELL).floor())
		var high := Vector2i((bounds.end/HEIGHT_CELL).floor())
		for z in range(low.y,high.y+1):
			for x in range(low.x,high.x+1):
				var cell := Vector2i(x,z)
				if not height_cells.has(cell): height_cells[cell] = []
				height_cells[cell].append(index)

func cliff_chain(from: Vector3, to: Vector3, outward: Vector3, height: float=18.0) -> void:
	var length := from.distance_to(to)
	var along := (to-from).normalized()
	var count := ceili(length/12.0)
	for i in count:
		var center := from+along*((i+0.5)*length/count)
		var h := height+sin(float(i)*0.9+from.x)*2.4+sin(i*2.7)*0.8
		var basis := Basis(along,Vector3.UP,along.cross(Vector3.UP))
		var depth_sign := outward.dot(basis.z)
		var footprint := _footprint(Vector2(length/count+0.08,20),0.04)
		var upper_foot := _footprint(Vector2(length/count+0.08,20),minf(2.0,length/count*0.2))
		var lean := sin(float(i)*1.7+from.x)*0.55
		var crown_width := 0.76+sin(float(i)*2.1+from.z)*0.09
		var rings := [_ring(footprint,0),
			_ring(upper_foot,h*0.32,Vector2(1,0.96),Vector2(0,depth_sign*0.4)),
			_ring(upper_foot,h*0.35,Vector2(0.98,0.88),Vector2(lean,depth_sign*1.2)),
			_ring(upper_foot,h*0.67,Vector2(0.97,0.79),Vector2(lean,depth_sign*2.1)),
			_ring(upper_foot,h*0.71,Vector2(0.94,0.67),Vector2(lean*1.6,depth_sign*3.3)),
			_ring(upper_foot,h,Vector2(crown_width,0.48),Vector2(lean*2.6,depth_sign*5.2))]
		var root := _model(center+outward*10.1,rings,i,false)
		root.basis = basis
		Geo.collider(root,Vector3(length/count+0.08,h,20),Vector3(0,h*0.5,0))
		root.set_meta("canyon_occluder",true)

func crag(center: Vector3, size: Vector3, seed: int) -> void:
	var footprint := _footprint(Vector2(size.x,size.z),minf(size.x,size.z)*0.16)
	var rings := [_ring(footprint,0),_ring(footprint,size.y*0.42,Vector2(1,0.97)),_ring(footprint,size.y*0.74,Vector2(0.90,0.84),Vector2(size.x*0.04,-size.z*0.03)),_ring(footprint,size.y,Vector2(0.74,0.72),Vector2(size.x*0.02,-size.z*0.04))]
	var root := _model(center,rings,seed)
	root.set_meta("canyon_occluder",true)

func update_occlusion(camera: Camera3D, focus: Vector3, dt: float = 0.0166667) -> void:
	occlusion_wait-=dt
	if occlusion_wait>0 and focus.distance_squared_to(last_focus)<0.56 and camera.position.distance_squared_to(last_camera)<2.25: return
	occlusion_wait=0.08
	last_focus=focus
	last_camera=camera.position
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
