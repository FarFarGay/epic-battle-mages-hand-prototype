class_name SlowField
extends Node3D
## Темпоральное поле врага-меха — наземная зона, которая ЗАМЕДЛЯЕТ башню (ходьбу
## и рывок), пока та внутри. Чистый сетап: урона не наносит — ловит мобильность,
## чтобы мех достреливал ракетами/Шквалом (см. EnemyMech). Зеркало FrostPatch, но
## цель — игрок (Tower.apply_movement_slow), а не Enemy.
##
## Само-достаточный нод (без .tscn): визуал строит в setup, по истечении duration
## плавно гаснет и удаляется. Тематически — фиолетово-голубое «застывшее время».

var _radius: float = 6.0
var _duration: float = 3.0
var _slow_factor: float = 0.45
var _refresh: float = 0.15
var _color: Color = Color(0.55, 0.4, 1.0, 0.85)

var _elapsed: float = 0.0
var _tick_t: float = 0.0
var _disc: MeshInstance3D = null
var _ring: MeshInstance3D = null
var _fading: bool = false


## center — точка на земле (y≈0). Зовётся ПОСЛЕ add_child (нужен tree для global_position).
func setup(center: Vector3, radius: float, duration: float, slow_factor: float, refresh_interval: float, color: Color) -> void:
	global_position = Vector3(center.x, 0.0, center.z)
	_radius = maxf(radius, 0.5)
	_duration = maxf(duration, 0.1)
	_slow_factor = clampf(slow_factor, 0.05, 1.0)
	_refresh = maxf(refresh_interval, 0.05)
	_color = color
	_build_visual()


func _build_visual() -> void:
	# Заливка-диск.
	var cyl := CylinderMesh.new()
	cyl.top_radius = _radius
	cyl.bottom_radius = _radius
	cyl.height = 0.08
	cyl.radial_segments = 32
	_disc = MeshInstance3D.new()
	_disc.mesh = cyl
	_disc.material_override = _make_mat(0.18)
	_disc.position.y = 0.05
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_disc)
	# Кольцо-кромка (ярче — читается граница зоны).
	var torus := TorusMesh.new()
	torus.inner_radius = _radius * 0.92
	torus.outer_radius = _radius
	torus.rings = 8
	torus.ring_segments = 32
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.material_override = _make_mat(0.85)
	_ring.position.y = 0.06
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)


func _make_mat(alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(_color.r, _color.g, _color.b, alpha)
	mat.emission_enabled = true
	mat.emission = Color(_color.r, _color.g, _color.b, 1.0)
	mat.emission_energy_multiplier = 1.2
	return mat


func _physics_process(delta: float) -> void:
	_elapsed += delta
	# «Дыхание» зоны (медленный пульс — застывшее время).
	var pulse: float = 1.0 + 0.12 * sin(_elapsed * 4.0)
	if is_instance_valid(_ring):
		_ring.scale = Vector3(pulse, 1.0, pulse)
	# Замедление башни — рефреш каждый _refresh, пока она внутри радиуса.
	_tick_t -= delta
	if _tick_t <= 0.0:
		_tick_t = _refresh
		var tower: Node = get_tree().get_first_node_in_group(Tower.GROUP)
		if tower != null and is_instance_valid(tower) and tower.has_method("apply_movement_slow"):
			var dx: float = (tower as Node3D).global_position.x - global_position.x
			var dz: float = (tower as Node3D).global_position.z - global_position.z
			if dx * dx + dz * dz <= _radius * _radius:
				# Длительность чуть больше периода рефреша — без «дыр» между тиками.
				tower.apply_movement_slow(_slow_factor, _refresh * 2.0)
	# Финал: плавно гаснем и удаляемся.
	if not _fading and _elapsed >= _duration:
		_fading = true
		for mi in [_disc, _ring]:
			if is_instance_valid(mi):
				var mat := mi.material_override as StandardMaterial3D
				if mat != null:
					var tw := create_tween()
					tw.tween_property(mat, "albedo_color:a", 0.0, 0.4)
		var t2 := create_tween()
		t2.tween_interval(0.42)
		t2.tween_callback(queue_free)
