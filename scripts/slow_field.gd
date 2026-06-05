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
var _dome: MeshInstance3D = null
var _ring: MeshInstance3D = null
var _fading: bool = false
## Фаза надувания (раздувается от маленького к полному на спавне) — пока true,
## пульс кромки не трогаем, чтобы не перебивать tween масштаба.
var _inflating: bool = true

const _DOME_SCALE := Vector3(1.0, 0.55, 1.0)  # целевой масштаб купола (приплюснут)


## center — точка на земле (y≈0). Зовётся ПОСЛЕ add_child (нужен tree для global_position).
func setup(center: Vector3, radius: float, duration: float, slow_factor: float, refresh_interval: float, color: Color) -> void:
	global_position = Vector3(center.x, 0.0, center.z)
	_radius = maxf(radius, 0.5)
	_duration = maxf(duration, 0.1)
	_slow_factor = clampf(slow_factor, 0.05, 1.0)
	_refresh = maxf(refresh_interval, 0.05)
	_color = color
	_build_visual()
	_inflate()


func _build_visual() -> void:
	# Купол-пузырь над зоной (полупрозрачная сфера, приплюснутая в купол). Низ
	# уходит под пол — видно «мыльный пузырь» над областью замедления.
	var sphere := SphereMesh.new()
	sphere.radius = _radius
	sphere.height = _radius * 2.0
	sphere.radial_segments = 28
	sphere.rings = 14
	_dome = MeshInstance3D.new()
	_dome.mesh = sphere
	_dome.material_override = _make_mat(0.13)
	_dome.scale = _DOME_SCALE * 0.12  # стартуем маленьким — раздуется в _inflate
	_dome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_dome)
	# Кольцо-кромка на земле — читается граница зоны.
	var torus := TorusMesh.new()
	torus.inner_radius = _radius * 0.93
	torus.outer_radius = _radius
	torus.rings = 8
	torus.ring_segments = 32
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.material_override = _make_mat(0.8)
	_ring.position.y = 0.06
	_ring.scale = Vector3(0.1, 1.0, 0.1)  # стартует маленьким — раздуется в _inflate
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)


## Надувание пузыря: купол и кромка раздуваются от маленького к полному с лёгким
## overshoot (TRANS_BACK) — «бульк». По завершении включается пульс кромки.
func _inflate() -> void:
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_dome, "scale", _DOME_SCALE, 0.4)
	tw.parallel().tween_property(_ring, "scale", Vector3.ONE, 0.4)
	tw.tween_callback(func() -> void: _inflating = false)


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
	# «Дыхание» зоны (медленный пульс — застывшее время). Не трогаем кромку, пока
	# идёт надувание — иначе перебьёт tween масштаба.
	if not _inflating and is_instance_valid(_ring):
		var pulse: float = 1.0 + 0.12 * sin(_elapsed * 4.0)
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
		for mi in [_dome, _ring]:
			if is_instance_valid(mi):
				var mat := mi.material_override as StandardMaterial3D
				if mat != null:
					var tw := create_tween()
					tw.tween_property(mat, "albedo_color:a", 0.0, 0.4)
		var t2 := create_tween()
		t2.tween_interval(0.42)
		t2.tween_callback(queue_free)
