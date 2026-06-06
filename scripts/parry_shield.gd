class_name ParryShield
extends Node3D
## Визуал щита парирования башни — полупрозрачный купол-пузырь, накрывающий зону
## ловли снарядов (parry_radius). В отличие от [SlowField] (медленно надувается и
## держится) — щит МГНОВЕННО вспыхивает на полный размер (парирование = «вскинул
## щит», а не растил пузырь) с лёгким «бульк»-overshoot, ярко горит кромкой и за
## ~полсекунды гаснет. Урона/физики не несёт — чистый feedback. Тематически —
## ледяной/энергетический пузырь, цвет передаётся из Tower.parry_color.
##
## Само-достаточный нод (без .tscn): визуал строит в setup, по duration гаснет и
## удаляется. Зеркало структуры SlowField, но семантика «вспышка», не «зона».

const _DOME_SCALE := Vector3(1.0, 0.7, 1.0)  # купол: чуть приплюснут, но «пузырь», не блин

var _color: Color = Color(0.5, 0.9, 1.0, 0.95)
var _dome: MeshInstance3D = null
var _ring: MeshInstance3D = null


## center — точка на земле (y≈0), radius — радиус купола (= parry_radius), duration
## — сколько визуал держится перед удалением (чуть больше окна, чтобы прочитался).
## Зовётся ПОСЛЕ add_child (нужен tree для global_position/tween).
func setup(center: Vector3, radius: float, color: Color, duration: float) -> void:
	global_position = Vector3(center.x, 0.0, center.z)
	_color = color
	var r: float = maxf(radius, 0.5)
	var dur: float = maxf(duration, 0.15)
	_build_visual(r)
	_animate(dur)


func _build_visual(radius: float) -> void:
	# Купол-пузырь: полупрозрачная сфера, приплюснутая в купол. Низ уходит под пол.
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	_dome = MeshInstance3D.new()
	_dome.mesh = sphere
	_dome.material_override = _make_mat(0.18)
	_dome.scale = _DOME_SCALE * 0.85  # стартуем чуть меньше — «бульк» в _animate
	_dome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_dome)
	# Кольцо-кромка на земле — читается граница щита (ярче купола).
	var torus := TorusMesh.new()
	torus.inner_radius = radius * 0.9
	torus.outer_radius = radius
	torus.rings = 8
	torus.ring_segments = 40
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.material_override = _make_mat(0.9)
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
	mat.emission_energy_multiplier = 1.6
	return mat


## Вспышка: купол «булькает» до полного размера за миг (TRANS_BACK overshoot),
## параллельно обе оболочки гаснут по альфе за duration → queue_free.
func _animate(duration: float) -> void:
	var tw := create_tween()
	tw.set_parallel(true)
	# Снап-надувание купола с лёгким overshoot — «вскинул щит».
	tw.tween_property(_dome, "scale", _DOME_SCALE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# Гаснут обе оболочки по альфе.
	for mi in [_dome, _ring]:
		if is_instance_valid(mi):
			var mat := mi.material_override as StandardMaterial3D
			if mat != null:
				tw.tween_property(mat, "albedo_color:a", 0.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.set_parallel(false)
	tw.tween_callback(queue_free)
