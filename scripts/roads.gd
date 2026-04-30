extends Node3D

@export var poi_root: NodePath = NodePath("../PointsOfInterest")
@export var width: float = 3.0
@export var height_offset: float = 0.06
@export var wave_amplitude: float = 6.0
@export var waves_per_100m: float = 1.6
@export var noise_amplitude: float = 1.4
@export var noise_frequency: float = 0.05
@export var color: Color = Color(0.55, 0.42, 0.28, 1.0)

const PAIRS: Array = [
	["Poi_Heart", "Poi_ESE"],
	["Poi_Heart", "Poi_NE"],
	["Poi_Heart", "Poi_NNW"],
	["Poi_Heart", "Poi_W"],
	["Poi_Heart", "Poi_SW"],
	["Poi_ESE", "Poi_NE"],
	["Poi_W", "Poi_NNW"],
	["Poi_SW", "Poi_ESE"],
]


func _ready() -> void:
	_build()


func _build() -> void:
	for child in get_children():
		child.queue_free()

	var poi_node := get_node_or_null(poi_root)
	if poi_node == null:
		push_warning("Roads: poi_root not found")
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in PAIRS.size():
		var pair: Array = PAIRS[i]
		var a_node := poi_node.get_node_or_null(NodePath(pair[0])) as Node3D
		var b_node := poi_node.get_node_or_null(NodePath(pair[1])) as Node3D
		if a_node == null or b_node == null:
			push_warning("Roads: missing %s or %s" % [pair[0], pair[1]])
			continue
		var a := Vector3(a_node.position.x, height_offset, a_node.position.z)
		var b := Vector3(b_node.position.x, height_offset, b_node.position.z)
		_add_road(st, a, b, i)

	st.generate_normals()
	var mesh := st.commit()

	var mi := MeshInstance3D.new()
	mi.name = "RoadsMesh"
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.95
	mat.metallic = 0.0
	mi.material_override = mat
	add_child(mi)


func _add_road(st: SurfaceTool, a: Vector3, b: Vector3, road_idx: int) -> void:
	var diff := b - a
	var length := diff.length()
	if length < 1.0:
		return
	var dir := diff / length
	var perp := Vector3(-dir.z, 0.0, dir.x)

	var n_segments: int = maxi(24, int(length / 2.0))

	var rng := RandomNumberGenerator.new()
	rng.seed = hash([int(a.x), int(a.z), int(b.x), int(b.z), road_idx])
	var phase := rng.randf() * TAU
	var freq_periods: float = max(1.0, (waves_per_100m * length / 100.0) * (0.7 + rng.randf() * 0.6))

	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	noise.frequency = noise_frequency

	var prev_left := Vector3.ZERO
	var prev_right := Vector3.ZERO
	var prev_t := 0.0
	var have_prev := false

	for i in n_segments + 1:
		var t: float = float(i) / float(n_segments)
		var pos := a.lerp(b, t)
		var envelope := sin(t * PI)
		var swing := sin(t * TAU * freq_periods + phase) * wave_amplitude * envelope
		var jitter := noise.get_noise_2d(t * length, float(road_idx) * 137.0) * noise_amplitude * envelope
		var center := pos + perp * (swing + jitter)
		var left := center - perp * (width * 0.5)
		var right := center + perp * (width * 0.5)

		if have_prev:
			st.set_uv(Vector2(0.0, prev_t * length / 4.0))
			st.add_vertex(prev_left)
			st.set_uv(Vector2(1.0, prev_t * length / 4.0))
			st.add_vertex(prev_right)
			st.set_uv(Vector2(1.0, t * length / 4.0))
			st.add_vertex(right)

			st.set_uv(Vector2(0.0, prev_t * length / 4.0))
			st.add_vertex(prev_left)
			st.set_uv(Vector2(1.0, t * length / 4.0))
			st.add_vertex(right)
			st.set_uv(Vector2(0.0, t * length / 4.0))
			st.add_vertex(left)

		prev_left = left
		prev_right = right
		prev_t = t
		have_prev = true
