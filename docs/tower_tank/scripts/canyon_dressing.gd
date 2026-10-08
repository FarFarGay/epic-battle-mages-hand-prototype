extends Node3D
## Static, collision-free scenery. Small repeated details share MultiMesh batches.
const Geo = preload("res://scripts/geo.gd")
const GroundShader = preload("res://shaders/canyon_ground.gdshader")
const StoneShader = preload("res://shaders/canyon_stone.gdshader")
const ScrubShader = preload("res://shaders/canyon_scrub.gdshader")
var level
var rng := RandomNumberGenerator.new()
var rock_instances: Array[Transform3D] = []
var grass_instances: Array[Transform3D] = []
var ground_material: ShaderMaterial
var worn_material: ShaderMaterial
var stone_material: ShaderMaterial
var ore_material: ShaderMaterial
var timber := Geo.material(Color("424d48"))
var iron := Geo.material(Color("39494e"), 0.4)
var plaster := Geo.material(Color("9baca8"))
var tile := Geo.material(Color("a45649"))
var cloth := Geo.material(Color("487b78"))
var lamp := Geo.material(Color("f6c078"), 0.15, 1.1)

func _ready() -> void:
	rng.seed = 83041
	ground_material = ShaderMaterial.new()
	ground_material.shader = GroundShader
	var routes := PackedVector4Array([
		Vector4(level.ENTRY_WEST,0,-124,0), Vector4(-124,0,-97,11),
		Vector4(-97,11,-94,46), Vector4(-97,11,-67,5),
		Vector4(-67,5,-62,-41.5), Vector4(-67,5,-10,-16),
		Vector4(-10,-16,10,10), Vector4(10,10,40,53),
		Vector4(40,53,105,27), Vector4(105,27,150,0),
		Vector4(-94,46,-52,45), Vector4(-80,38,-68.5,38),
		Vector4(-62,-41.5,-28,-41.5), Vector4(-28,-41.5,-28,-52),
		Vector4(2,10,39,10), Vector4(32,-34,32,10)])
	ground_material.set_shader_parameter("routes",routes)
	ground_material.set_shader_parameter("route_count",routes.size())
	worn_material = ground_material.duplicate()
	worn_material.set_shader_parameter("wear",0.10)
	stone_material = ShaderMaterial.new()
	stone_material.shader = StoneShader
	ore_material = stone_material.duplicate()
	ore_material.set_shader_parameter("stone_color",Color("47524f"))
	ore_material.set_shader_parameter("mineral",1.0)

func build() -> void:
	_scatter_edges()
	for center in [level.A,level.B,level.C]: _scatter_shelf(center,28.0 if center==level.C else 16.0)
	_decorate_workshop()
	_decorate_dungeon()
	_decorate_village()
	_decorate_wreck()
	if not OS.get_cmdline_user_args().has("--bake-level"): _merge_details()
	var rock := SphereMesh.new()
	rock.radial_segments = 5
	rock.rings = 2
	rock.radius = 0.5
	rock.height = 1.0
	_batch("Talus",rock,Geo.material(Color("65706a")),rock_instances)
	var scrub := ShaderMaterial.new()
	scrub.shader = ScrubShader
	_batch("DryScrub",_grass_mesh(),scrub,grass_instances)

func _merge_details() -> void:
	# Bake authored transforms once; collision, interactables and fading cliffs
	# live outside this subtree and retain their own nodes.
	var surfaces := {}
	for detail in find_children("*","MeshInstance3D",true,false):
		var material: Material = detail.material_override
		if not surfaces.has(material):
			var surface := SurfaceTool.new()
			surface.begin(Mesh.PRIMITIVE_TRIANGLES)
			surfaces[material] = surface
		for i in detail.mesh.get_surface_count():
			surfaces[material].append_from(detail.mesh,i,global_transform.affine_inverse()*detail.global_transform)
		detail.queue_free()
	for material in surfaces:
		Geo.mesh(self,surfaces[material].commit(),Vector3.ZERO,material).name = "BakedScenery"

func _batch(label: String, mesh: Mesh, material: Material, instances: Array[Transform3D]) -> void:
	var batch := MultiMeshInstance3D.new()
	batch.name = label
	batch.multimesh = MultiMesh.new()
	batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	batch.multimesh.use_colors = true
	batch.multimesh.mesh = mesh
	batch.multimesh.instance_count = instances.size()
	batch.material_override = material
	if material is StandardMaterial3D: material.vertex_color_use_as_albedo = true
	for i in instances.size():
		batch.multimesh.set_instance_transform(i,instances[i])
		var tone := rng.randf_range(0.78,1.16)
		batch.multimesh.set_instance_color(i,Color(tone,tone,tone))
	batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(batch)

func _grass_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 5:
		var angle := float(i)*TAU/5.0
		var side := Vector3(cos(angle),0,sin(angle))*0.14
		var tip := Vector3(sin(angle)*0.36,0.55+float(i%3)*0.16,cos(angle)*0.36)
		for point in [-side,side,tip,side,-side,tip]:
			surface.set_normal(Vector3.UP)
			surface.add_vertex(point)
	return surface.commit()

func _scatter(point: Vector3, scale_factor: float = 1.0) -> void:
	var size := rng.randf_range(0.2,0.8)*scale_factor
	var basis := Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(size*1.8,size*0.65,size))
	rock_instances.append(Transform3D(basis,point+Vector3.UP*size*0.18))
	if rng.randf()<0.42:
		var plant_size := rng.randf_range(0.5,1.1)
		grass_instances.append(Transform3D(Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3.ONE*plant_size),point+Vector3(0.45,0,-0.25)))

func _scatter_edges() -> void:
	for i in level.OUTLINE.size():
		var a: Vector2 = level.OUTLINE[i]
		var b: Vector2 = level.OUTLINE[(i+1)%level.OUTLINE.size()]
		if a.x==b.x and absf(a.x)==128: continue
		var along := (b-a).normalized()
		var inside := Vector2(-along.y,along.x)
		for j in int(a.distance_to(b)*1.8):
			var flat := a.lerp(b,rng.randf())+inside*rng.randf_range(0.4,3.0)
			if sin(flat.x*0.47+flat.y*0.53)>0.2: continue
			_scatter(Vector3(flat.x,0.03,flat.y))
	for side in [-1.0,1.0]:
		for i in 160:
			var x := rng.randf_range(level.ENTRY_WEST+2,-139)
			if sin(x*0.63+side)>0.35: continue
			_scatter(Vector3(x,0.025,side*rng.randf_range(8.8,9.6)),0.75)
	for spec in [[Vector3(-79,0,-21),8.0],[Vector3(77,0,-41),12.0]]:
		for i in 100:
			var angle := rng.randf()*TAU
			var radius := rng.randf_range(spec[1],spec[1]+4.0)
			_scatter(spec[0]+Vector3(cos(angle)*radius,0.025,sin(angle)*radius))

func _scatter_shelf(center: Vector3, radius: float) -> void:
	for side in [-1.0,1.0]:
		for i in 45:
			var pos := center+Vector3(rng.randf_range(-radius+5,radius-5),0.025,side*(radius-rng.randf_range(0.4,1.6)))
			# Leave the mine's north entrance clear.
			if center==level.C and side<0 and absf(pos.x-(center.x-16))<4: continue
			_scatter(pos,0.65)

func _beam(parent: Node3D, from: Vector3, to: Vector3, width: float = 0.16) -> void:
	Geo.line(parent,from,to,width,timber)

func _lantern(parent: Node3D, pos: Vector3) -> void:
	Geo.box(parent,Vector3(0.38,0.55,0.38),pos,iron)
	Geo.box(parent,Vector3(0.29,0.33,0.40),pos,lamp)
	Geo.box(parent,Vector3(0.40,0.33,0.29),pos,lamp)
	Geo.box(parent,Vector3(0.48,0.09,0.48),pos+Vector3.UP*0.31,iron)

func _decorate_workshop() -> void:
	var p: Vector3 = level.A+Vector3(8,0,-1)
	for offset in [-1.2,0.0,1.2]:
		Geo.box(self,Vector3(0.12,0.15,2.3),p+Vector3(offset,1.38,0),timber)
	Geo.cylinder(self,0.35,0.18,p+Vector3(0,1.48,0),iron,8)
	Geo.box(self,Vector3(0.95,0.2,0.4),p+Vector3(0,1.63,0),iron)
	for side in [-1.0,1.0]:
		_beam(self,p+Vector3(side*2,0,0),p+Vector3(side*2,3.3,0),0.2)
		_lantern(self,p+Vector3(side*1.8,2.8,0.2))
	for i in 5: Geo.box(self,Vector3(4.1,0.05,0.26),p+Vector3(0,3.52,-1.7+i*0.55),cloth)
	var gate: Vector3 = level.A+Vector3(-16,0,0)
	for side in [-1.0,1.0]:
		for y in 7:
			Geo.box(self,Vector3(1.2,0.86,1.1),gate+Vector3(0,y*0.91+0.43,side*3.1),plaster)
		_lantern(self,gate+Vector3(-0.8,3.0,side*3.1))

func _decorate_dungeon() -> void:
	var p: Vector3 = level.B+Vector3(0,0,-7.94)
	for side in [-1.0,1.0]:
		for i in 6:
			Geo.box(self,Vector3(1.1,0.72,0.32),p+Vector3(side*1.58,0.4+i*0.77,0.02),plaster)
		Geo.box(self,Vector3(1.5,0.22,0.5),p+Vector3(side*1.58,4.95,0.03),iron)
		_lantern(self,p+Vector3(side*2.4,1.5,0.2))
	Geo.box(self,Vector3(4.3,0.5,0.4),p+Vector3(0,5.25,0.04),plaster)
	var seal := Geo.box(self,Vector3(0.6,0.6,0.18),p+Vector3(0,4.2,0.10),cloth)
	seal.rotation.z = PI/4
	for i in 3: Geo.box(self,Vector3(0.12,0.52-i*0.10,0.07),p+Vector3((i-1)*0.25,4.2,0.24),lamp)
	for side in [-1.0,1.0]:
		Geo.box(self,Vector3(0.95,2.4,0.035),p+Vector3(side*3.6,2.4,0.10),cloth)
		Geo.box(self,Vector3(1.2,0.12,0.16),p+Vector3(side*3.6,3.6,0.10),iron)
	for i in 7:
		var height := 0.40+float(posmod(i*3,5))*0.15
		Geo.box(self,Vector3(1.85,height,1.0),p+Vector3((i-3)*1.87,6.0+height*0.5,-0.45),plaster)
	Geo.box(self,Vector3(4.8,0.22,0.6),p+Vector3(0,5.55,-0.05),iron)
	for side in [-1.0,1.0]:
		Geo.box(self,Vector3(1.2,0.9,1.25),p+Vector3(side*5.35,6.45,-3.4),plaster)

func _decorate_village() -> void:
	for offset in [Vector2(-17,-18),Vector2(-9,-21),Vector2(-14,-10),Vector2(-18,14),Vector2(-9,12),Vector2(-9,23)]:
		var p: Vector3 = level.C+Vector3(offset.x,0,offset.y)
		for side in [-1.0,1.0]:
			var roof := Geo.box(self,Vector3(2.68,0.16,4.55),p+Vector3(side*1.17,3.97,0),tile)
			roof.rotation.z = side*-0.37
			Geo.box(self,Vector3(0.13,3.15,0.12),p+Vector3(side*2.17,1.57,2.06),timber)
			Geo.box(self,Vector3(0.66,0.8,0.08),p+Vector3(side*1.3,1.8,2.07),iron)
			Geo.box(self,Vector3(0.47,0.55,0.09),p+Vector3(side*1.3,1.8,2.09),lamp)
			Geo.box(self,Vector3(0.08,0.65,0.12),p+Vector3(side*1.3,1.8,2.15),timber)
		Geo.box(self,Vector3(4.6,0.18,0.14),p+Vector3(0,2.96,2.07),timber)
		Geo.box(self,Vector3(0.48,1.15,0.50),p+Vector3(1.35,4.25,-1.15),plaster)
		Geo.box(self,Vector3(0.63,0.12,0.65),p+Vector3(1.35,4.84,-1.15),iron)
		for i in 4: Geo.box(self,Vector3(0.35,0.025,1.9),p+Vector3((i-1.5)*0.83,2.3,2.9),plaster)
	var p: Vector3 = level.C+Vector3(-24,0,-21)
	_beam(self,p,p+Vector3(0,6.5,0),0.40)
	_beam(self,p+Vector3(0,5.9,0),p+Vector3(5,5.9,0),0.33)
	_beam(self,p+Vector3(0,2.7,0),p+Vector3(3.3,5.9,0),0.25)
	Geo.line(self,p+Vector3(4.3,5.9,0),p+Vector3(4.3,2.9,0),0.055,iron)
	Geo.ring(self,0.3,0.09,p+Vector3(4.3,2.7,0),iron).rotation.x=PI/2

func _decorate_wreck() -> void:
	var wreck := Node3D.new()
	add_child(wreck)
	wreck.position=Vector3(-34,0,4)
	wreck.rotation.y=-0.24
	for x in range(-14,15): Geo.box(wreck,Vector3(0.92,0.08,7.8),Vector3(x,1.54,0),timber)
	for side in [-1.0,1.0]:
		for i in 9:
			var plank := Geo.box(wreck,Vector3(2.7,0.28,0.18),Vector3((i-4)*3,1.9+float(i%3)*0.34,side*3.83),timber)
			plank.rotation.z=sin(float(i))*0.09
		Geo.line(wreck,Vector3(-4,7,0),Vector3(10,2,side*3.4),0.045,iron)
