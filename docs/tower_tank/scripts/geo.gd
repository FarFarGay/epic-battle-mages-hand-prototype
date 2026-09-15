extends RefCounted
## Small procedural mesh kit. All assets are original and generated locally.
const UI_LAYER := 1 << 19

static func mark_ui(node: Node) -> void:
	# Camera filtering preserves each marker's own visibility rules across toggles.
	if node is VisualInstance3D: node.layers = UI_LAYER
	if node is GeometryInstance3D: node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children(): mark_ui(child)

static func material(color: Color, metallic: float = 0.0, glow: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = 0.74 if metallic < 0.5 else 0.38
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = glow
	return m

static func mesh(parent: Node3D, shape: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.mesh = shape
	n.material_override = mat
	parent.add_child(n)
	n.position = pos
	return n

static func box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var shape := BoxMesh.new()
	shape.size = size
	return mesh(parent, shape, pos, mat)

static func cylinder(parent: Node3D, radius: float, height: float, pos: Vector3, mat: Material, sides: int = 12, top: float = -1.0) -> MeshInstance3D:
	var shape := CylinderMesh.new()
	shape.bottom_radius = radius
	shape.top_radius = radius if top < 0.0 else top
	shape.height = height
	shape.radial_segments = sides
	return mesh(parent, shape, pos, mat)

static func sphere(parent: Node3D, radius: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var shape := SphereMesh.new()
	shape.radius = radius
	shape.height = radius * 2.0
	shape.radial_segments = 12
	shape.rings = 6
	return mesh(parent, shape, pos, mat)

static func ring(parent: Node3D, radius: float, width: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var shape := TorusMesh.new()
	shape.inner_radius = maxf(radius - width, 0.001)
	shape.outer_radius = radius
	shape.rings = 40
	shape.ring_segments = 6
	return mesh(parent, shape, pos, mat)

static func collider(parent: Node3D, size: Vector3, pos: Vector3) -> CollisionShape3D:
	var n := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	n.shape = shape
	parent.add_child(n)
	n.position = pos
	return n

static func line(parent: Node3D, a: Vector3, b: Vector3, width: float, mat: Material) -> MeshInstance3D:
	var n := box(parent, Vector3(width, width, maxf(a.distance_to(b), 0.001)), (a + b) * 0.5, mat)
	if a.distance_squared_to(b) > 0.0001:
		n.look_at(b, Vector3.RIGHT if absf((b - a).normalized().y) > 0.98 else Vector3.UP)
	return n
