extends RefCounted
## Code-built 3D interpretation of the supplied tower-in-boots concept.
const Geo = preload("res://scripts/geo.gd")
var cloth_materials: Array[ShaderMaterial] = []
var actor

func build(tower) -> void:
	actor = tower
	var stone := Geo.material(Color("686980"))
	var pale := Geo.material(Color("898ba1"))
	var dark := Geo.material(Color("272a3e"), 0.35)
	var iron := Geo.material(Color("676b88"), 0.35)
	var brass := Geo.material(Color("bc944f"), 0.65)
	var black := Geo.material(Color("141625"))
	actor.body_visual = Node3D.new()
	actor.body_visual.name = "StoneTowerBody"
	actor.add_child(actor.body_visual)
	var body: Node3D = actor.body_visual
	_bricks(body, 1.08, 1.03, 3.14, 10, 20)
	Geo.cylinder(body, 1.04, 0.18, Vector3(0, 1.08, 0), dark, 40)
	_bricks(body, 1.17, 2.01, 2.24, 1, 16)
	_window(body, 0.18, 2.40, Color("ffd364"), pale, dark)
	_window(body, 1.65, 1.30, Color("f38299"), pale, dark)
	_window(body, -1.72, 2.40, Color("ffd364"), pale, dark)
	_door(body, 0.86, 1.12)
	_build_cloth(body)
	actor.turret = Node3D.new()
	actor.turret.name = "ArmoredRoundUpperFloor"
	body.add_child(actor.turret)
	actor.turret.position.y = 3.14
	var turret: Node3D = actor.turret
	Geo.cylinder(turret, 1.19, 0.11, Vector3(0, 0.02, 0), dark, 32)
	Geo.cylinder(turret, 1.23, 0.93, Vector3(0, 0.53, 0), iron, 16)
	for i in 8:
		var angle := TAU * i / 8.0
		var plate := Node3D.new()
		turret.add_child(plate)
		plate.position = Vector3(sin(angle), 0, cos(angle)) * 1.18 + Vector3.UP * 0.53
		plate.rotation.y = angle
		Geo.box(plate, Vector3(0.89, 0.88, 0.10), Vector3.ZERO, stone if i % 2 == 0 else iron)
		for x in [-0.37, 0.37]:
			for y in [-0.36, 0.36]:
				Geo.sphere(plate, 0.045, Vector3(x, y, 0.078), pale)
		if i in [0, 2, 6]:
			Geo.box(plate, Vector3(0.65, 0.23, 0.045), Vector3(0, 0.09, 0.079), pale)
			Geo.box(plate, Vector3(0.55, 0.12, 0.052), Vector3(0, 0.09, 0.105), black)
			actor.vents.append(Geo.box(plate, Vector3(0.33, 0.018, 0.012), Vector3(0, 0.045, 0.135), brass))
	Geo.cylinder(turret, 1.25, 0.11, Vector3(0, 1.02, 0), dark, 32)
	var dome := Geo.sphere(turret, 1.13, Vector3(0, 1.035, 0), iron)
	dome.scale.y = 0.25
	Geo.cylinder(turret, 0.38, 0.09, Vector3(0, 1.32, 0), dark, 20)
	var hatch := Geo.sphere(turret, 0.34, Vector3(0, 1.36, 0), pale)
	hatch.scale.y = 0.28
	actor.gun_pitch = Node3D.new()
	turret.add_child(actor.gun_pitch)
	actor.gun_pitch.position = Vector3(0, 0.52, -0.94)
	var pitch: Node3D = actor.gun_pitch
	Geo.box(pitch, Vector3(0.86, 0.79, 0.30), Vector3.ZERO, dark)
	Geo.box(pitch, Vector3(0.71, 0.64, 0.34), Vector3(0, 0, -0.045), pale)
	for x in [-0.30, 0.30]:
		for y in [-0.27, 0.27]: Geo.sphere(pitch, 0.037, Vector3(x, y, -0.23), dark)
	actor.barrel = Node3D.new()
	actor.barrel.name = "RecoilingBarrel"
	pitch.add_child(actor.barrel)
	var barrel: Node3D = actor.barrel
	var tube := Geo.cylinder(barrel, 0.22, 2.0, Vector3(0, 0, -1.12), iron, 16, 0.26)
	tube.rotation.x = PI / 2.0
	for z in [-0.25, -0.81, -1.52]:
		var band := Geo.cylinder(barrel, 0.27, 0.10, Vector3(0, 0, z), dark, 16)
		band.rotation.x = PI / 2.0
	var muzzle_rim := Geo.cylinder(barrel, 0.31, 0.26, Vector3(0, 0, -2.14), pale, 16)
	muzzle_rim.rotation.x = PI / 2.0
	var bore := Geo.cylinder(barrel, 0.225, 0.015, Vector3(0, 0, -2.28), black, 20)
	bore.rotation.x = PI / 2.0
	var lip := Geo.ring(barrel, 0.303, 0.040, Vector3(0, 0, -2.29), dark)
	lip.rotation.x = PI / 2.0
	actor.muzzle = Marker3D.new()
	barrel.add_child(actor.muzzle)
	actor.muzzle.position.z = -2.36

func _bricks(parent: Node3D, radius: float, bottom: float, top: float, rows: int, columns: int) -> void:
	Geo.cylinder(parent, radius - 0.025, top - bottom, Vector3(0, (top + bottom) * 0.5, 0), Geo.material(Color("34374b")), 40)
	var shades := ["686980", "71738b", "62657d", "7a7b90", "5e6179"]
	var surfaces: Array[SurfaceTool] = []
	for shade in shades:
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		surface.set_material(Geo.material(Color(shade)))
		surfaces.append(surface)
	var height := (top - bottom) / rows
	for row in rows:
		for column in columns:
			var start := (float(column) + (0.5 if row % 2 else 0.0)) * TAU / columns + 0.008
			var finish := start + TAU / columns - 0.016
			var y0 := bottom + row * height + 0.009
			var y1 := bottom + (row + 1) * height - 0.009
			var surface: SurfaceTool = surfaces[(row * 7 + column * 3) % shades.size()]
			for step in 2:
				var a := lerpf(start, finish, step / 2.0)
				var b := lerpf(start, finish, (step + 1) / 2.0)
				var pa := Vector3(sin(a), 0, cos(a)) * radius
				var pb := Vector3(sin(b), 0, cos(b)) * radius
				_quad(surface, pa + Vector3.UP * y0, pb + Vector3.UP * y0, pb + Vector3.UP * y1, pa + Vector3.UP * y1)
				_quad(surface, pa + Vector3.UP * y1, pb + Vector3.UP * y1, pb * 0.96 + Vector3.UP * y1, pa * 0.96 + Vector3.UP * y1)
	for surface in surfaces:
		surface.generate_normals()
		Geo.mesh(parent, surface.commit(), Vector3.ZERO, null)

static func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, reverse: bool = false) -> void:
	for point in ([a, b, c, a, c, d] if reverse else [a, c, b, a, d, c]): surface.add_vertex(point)

func _arch(parent: Node3D, width: float, height: float, pos: Vector3, mat: Material) -> void:
	var radius := width * 0.5
	var stem := height - radius
	var points: Array[Vector3] = [Vector3(-radius, 0, 0), Vector3(radius, 0, 0)]
	for i in 13:
		var angle := PI * i / 12.0
		points.append(Vector3(cos(angle) * radius, stem + sin(angle) * radius, 0))
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(1, points.size() - 1):
		for p in [points[0], points[i + 1], points[i]]: surface.add_vertex(p)
	surface.generate_normals()
	Geo.mesh(parent, surface.commit(), pos, mat)

func _wall_detail(parent: Node3D, angle: float, y: float) -> Node3D:
	var root := Node3D.new()
	parent.add_child(root)
	root.position = Vector3(sin(angle) * 1.09, y, cos(angle) * 1.09)
	root.rotation.y = angle
	return root

func _window(parent: Node3D, angle: float, y: float, glow: Color, pale: Material, dark: Material) -> void:
	var root := _wall_detail(parent, angle, y)
	root.name = "ArchedWindow"
	_arch(root, 0.39, 0.63, Vector3.ZERO, pale)
	_arch(root, 0.29, 0.55, Vector3(0, 0.035, 0.008), dark)
	_arch(root, 0.17, 0.46, Vector3(0, 0.062, 0.016), Geo.material(glow, 0.0, 0.8))
	Geo.box(root, Vector3(0.43, 0.065, 0.15), Vector3(0, 0.015, 0.015), pale)

func _door(parent: Node3D, angle: float, y: float) -> void:
	var root := _wall_detail(parent, angle, y)
	root.name = "ArchedCrewDoor"
	var frame := Geo.material(Color("ac553b"))
	var wood := Geo.material(Color("733b31"))
	var dark := Geo.material(Color("28212a"))
	_arch(root, 0.64, 0.82, Vector3.ZERO, dark)
	_arch(root, 0.59, 0.78, Vector3(0, 0.01, 0.008), frame)
	_arch(root, 0.48, 0.69, Vector3(0, 0.018, 0.015), wood)
	for x in [-0.14, -0.045, 0.05, 0.14]:
		Geo.line(root, Vector3(x, 0.025, 0.023), Vector3(x, 0.60, 0.023), 0.012, dark)
	for level in [0.18, 0.48]:
		Geo.box(root, Vector3(0.47, 0.047, 0.027), Vector3(0, level, 0.035), dark)
		for x in [-0.19, 0.19]: Geo.sphere(root, 0.023, Vector3(x, level, 0.060), frame)
	Geo.sphere(root, 0.037, Vector3(0.13, 0.34, 0.055), Geo.material(Color("d0a05c"), 0.5))

func _build_cloth(parent: Node3D) -> void:
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode cull_disabled; uniform vec4 tint : source_color; uniform vec2 sway = vec2(0.0); uniform float pace = 0.0; void vertex() { float w = clamp((1.29 - VERTEX.y) / 1.11, 0.0, 1.0); VERTEX.xz += sway * w * w; VERTEX.x += sin(TIME * 8.0 + VERTEX.z * 4.0) * 0.025 * pace * w; VERTEX.z += cos(TIME * 7.0 + VERTEX.x * 5.0) * 0.035 * pace * w; } void fragment() { ALBEDO = tint.rgb; ROUGHNESS = 0.94; }"
	for hem in [false, true]:
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in 72:
			var a := TAU * i / 72.0
			var b := TAU * (i + 1) / 72.0
			var y0 := 0.17 if hem else 0.29
			var y1 := 0.29 if hem else 1.29
			_quad(surface, _cloth_point(a, y0), _cloth_point(b, y0), _cloth_point(b, y1), _cloth_point(a, y1))
		surface.generate_normals()
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("tint", Color("ecc45c") if hem else Color("c5274a"))
		cloth_materials.append(mat)
		var cloth := Geo.mesh(parent, surface.commit(), Vector3.ZERO, mat)
		cloth.name = "GoldClothHem" if hem else "CrimsonCloth"

func _cloth_point(angle: float, y: float) -> Vector3:
	var weight := clampf((1.29 - y) / 1.12, 0.0, 1.0)
	var fold := cos(angle * 12.0) * 0.065 * weight
	var radius := 1.09 + weight * 0.20 + fold
	return Vector3(sin(angle) * radius, y + sin(angle * 12.0 + 0.4) * 0.035 * weight, cos(angle) * radius)

func tick(_dt: float) -> void:
	var local: Vector3 = actor.global_basis.inverse() * actor.velocity
	var sway := Vector2(-local.x, -local.z) * 0.024
	if actor.dash.active: sway = sway.limit_length(0.30)
	for mat in cloth_materials:
		mat.set_shader_parameter("sway", sway)
		mat.set_shader_parameter("pace", clampf(actor.speed / actor.forward_speed, 0, 1))

static func boot(parent: Node3D, side: float) -> void:
	var leather := Geo.material(Color("8e593a"))
	var cuff := Geo.material(Color("b17c4e"))
	var dark := Geo.material(Color("422d29"))
	var gold := Geo.material(Color("bb985d"), 0.35)
	var sole := Geo.sphere(parent, 1.0, Vector3(0, 0.12, -0.22), dark)
	sole.scale = Vector3(0.43, 0.10, 0.74)
	var shoe := Geo.sphere(parent, 1.0, Vector3(0, 0.28, -0.24), leather)
	shoe.scale = Vector3(0.39, 0.26, 0.66)
	Geo.cylinder(parent, 0.29, 0.64, Vector3(0, 0.43, 0.11), leather, 12, 0.32)
	Geo.cylinder(parent, 0.36, 0.13, Vector3(0, 0.78, 0.11), cuff, 12)
	Geo.cylinder(parent, 0.285, 0.012, Vector3(0, 0.85, 0.11), dark, 12)
	for y in [0.44, 0.64]:
		Geo.cylinder(parent, 0.31, 0.075, Vector3(0, y, 0.11), dark, 12)
		var buckle := Geo.box(parent, Vector3(0.075, 0.15, 0.17), Vector3(side * 0.31, y, 0.10), gold)
		Geo.box(buckle, Vector3(0.085, 0.08, 0.09), Vector3(side * 0.01, 0, 0), dark)
	for row in 4:
		var y := 0.37 + row * 0.045
		var z := -0.54 + row * 0.09
		Geo.line(parent, Vector3(-0.18, y, z), Vector3(0.18, y + 0.014, z + 0.04), 0.032, cuff)
	var tip := SurfaceTool.new()
	tip.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sections := [Vector3(-0.64, 0.26, 0.23), Vector3(-0.91, 0.30, 0.13), Vector3(-1.04, 0.48, 0.07), Vector3(-1.05, 0.64, 0.005)]
	for segment in 3:
		var a: Vector3 = sections[segment]
		var b: Vector3 = sections[segment + 1]
		for i in 10:
			var t := TAU * i / 10.0
			var u := TAU * (i + 1) / 10.0
			_quad(tip, Vector3(cos(t) * a.z, a.y + sin(t) * a.z * 0.7, a.x), Vector3(cos(u) * a.z, a.y + sin(u) * a.z * 0.7, a.x), Vector3(cos(u) * b.z, b.y + sin(u) * b.z * 0.7, b.x), Vector3(cos(t) * b.z, b.y + sin(t) * b.z * 0.7, b.x), true)
	tip.generate_normals()
	Geo.mesh(parent, tip.commit(), Vector3.ZERO, leather)
