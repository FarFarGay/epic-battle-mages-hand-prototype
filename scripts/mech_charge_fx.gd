class_name MechChargeFx
extends Node3D
## Телеграф зарядки супер-залпа меха (см. EnemyMech._tick_missile_super): сгустки
## энергии сходятся к точке пуска ракет (над корпусом) за время зарядки, по ходу
## закручиваясь внутрь и разгораясь. На пике — лопаются (залп вылетает оттуда же).
## Читается как «мех копит рой». Цвет = телеграф супера (красно-оранжевый), чтобы
## игрок связал свечение меха с кольцом на земле и приготовил парирование (Q).
##
## Само-достаточный нод: вешается РЕБЁНКОМ меха (следует за ним, не зависит от
## dash-наклона меша) на локальную позицию точки пуска; по duration сам queue_free.

const ORB_COUNT := 7
const ORB_RADIUS := 0.26

var _color: Color = Color(1.0, 0.35, 0.12, 1.0)
var _gather_radius: float = 3.0
var _duration: float = 1.3
## Сколько держится готовый сгусток, пока из него вылетают ракеты (затем гаснет).
var _emit_time: float = 0.4
var _elapsed: float = 0.0
var _done: bool = false
## Один сгусток: меш + стартовое смещение (откуда сходится) + угловая скорость спина.
var _orbs: Array = []


## duration — время зарядки (= телеграф супера). color — цвет сгустков. gather_radius
## — с какого радиуса они слетаются к центру. emit_time — сколько держится готовый
## сгусток, пока из него вылетают ракеты. Зовётся ПОСЛЕ add_child.
func setup(duration: float, color: Color, gather_radius: float, emit_time: float = 0.4) -> void:
	_duration = maxf(duration, 0.1)
	_color = color
	_gather_radius = maxf(gather_radius, 0.5)
	_emit_time = maxf(emit_time, 0.05)
	_build()


func _build() -> void:
	for i in range(ORB_COUNT):
		var sphere := SphereMesh.new()
		sphere.radius = ORB_RADIUS
		sphere.height = ORB_RADIUS * 2.0
		sphere.radial_segments = 10
		sphere.rings = 6
		var mi := MeshInstance3D.new()
		mi.mesh = sphere
		mi.material_override = _make_mat()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		# Стартовое смещение: точка на сфере радиуса _gather_radius (случайный угол +
		# высота) — сгустки слетаются со всех сторон к точке пуска.
		var ang: float = TAU * float(i) / float(ORB_COUNT) + randf_range(-0.4, 0.4)
		var y_off: float = randf_range(-0.6, 1.2)
		var start: Vector3 = Vector3(cos(ang), 0.0, sin(ang)) * _gather_radius + Vector3.UP * y_off
		mi.position = start
		_orbs.append({
			"mi": mi,
			"start": start,
			"spin": randf_range(2.0, 4.0) * (1.0 if i % 2 == 0 else -1.0),
		})


func _make_mat() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(_color.r, _color.g, _color.b, 0.5)
	mat.emission_enabled = true
	mat.emission = Color(_color.r, _color.g, _color.b, 1.0)
	mat.emission_energy_multiplier = 1.2
	return mat


func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	if _elapsed <= _duration:
		_tick_gather()
	else:
		_tick_emit()


## Фаза 1 — схождение: сгустки слетаются к центру (ускоряясь) + спин, разгораясь.
func _tick_gather() -> void:
	var t: float = clampf(_elapsed / _duration, 0.0, 1.0)
	var converge: float = t * t  # ease-in — слетаются всё быстрее
	for orb in _orbs:
		var mi := orb["mi"] as MeshInstance3D
		if not is_instance_valid(mi):
			continue
		var spun: Vector3 = (orb["start"] as Vector3).rotated(Vector3.UP, float(orb["spin"]) * _elapsed)
		mi.position = spun.lerp(Vector3.ZERO, converge)
		var mat := mi.material_override as StandardMaterial3D
		if mat != null:
			mat.emission_energy_multiplier = lerpf(1.2, 4.5, t)
			mat.albedo_color.a = lerpf(0.5, 1.0, t)
		mi.scale = Vector3.ONE * lerpf(0.7, 1.4, t)


## Фаза 2 — сгусток: все слились в один яркий шар над корпусом, держится и пульсирует,
## пока из него вылетают ракеты; по emit_time гаснет и удаляется.
func _tick_emit() -> void:
	var et: float = clampf((_elapsed - _duration) / _emit_time, 0.0, 1.0)
	# Лёгкая пульсация размера сгустка + затухание к концу эмиссии.
	var pulse: float = 1.0 + 0.15 * sin(_elapsed * 30.0)
	for orb in _orbs:
		var mi := orb["mi"] as MeshInstance3D
		if not is_instance_valid(mi):
			continue
		mi.position = Vector3.ZERO  # все в центре → один сгусток
		mi.scale = Vector3.ONE * 1.7 * pulse * (1.0 - 0.5 * et)
		var mat := mi.material_override as StandardMaterial3D
		if mat != null:
			mat.emission_energy_multiplier = lerpf(4.5, 1.0, et)
			mat.albedo_color.a = lerpf(1.0, 0.0, et)
	if et >= 1.0:
		_done = true
		queue_free()
