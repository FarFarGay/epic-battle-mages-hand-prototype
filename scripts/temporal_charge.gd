class_name TemporalCharge
extends Node3D
## Темпоральный заряд врага-меха — медленный самонаводящийся «пузырь», летит на
## башню (live-homing, как ракеты, но медленнее и слабее по доворту). НЕ метит
## зону на земле — сам пузырь и есть угроза: видишь, уворачивайся. Догнал башню
## (proximity) → лопается в [SlowField] (slow-зону). Не успел за lifetime — гаснет
## без эффекта (увернулся честно). Урона не наносит — это сетап под ракеты.

var _speed: float = 11.0
var _turn: float = 2.5
var _life: float = 5.0
var _burst_radius: float = 2.5
var _vel: Vector3 = Vector3.ZERO
# Параметры зоны, в которую лопнет (передаются в SlowField.setup).
var _f_radius: float = 6.0
var _f_duration: float = 3.0
var _f_slow: float = 0.45
var _f_refresh: float = 0.15
var _color: Color = Color(0.55, 0.4, 1.0, 0.85)

var _elapsed: float = 0.0
var _bursted: bool = false
var _bubble: MeshInstance3D = null


## start — точка вылета (над дулом меха). target_pos — текущая позиция башни (для
## стартового направления; дальше ведём живую цель из группы Tower).
func setup(start: Vector3, target_pos: Vector3, speed: float, turn: float, lifetime: float,
		burst_radius: float, f_radius: float, f_duration: float, f_slow: float,
		f_refresh: float, color: Color) -> void:
	global_position = start
	_speed = speed
	_turn = turn
	_life = lifetime
	_burst_radius = burst_radius
	_f_radius = f_radius
	_f_duration = f_duration
	_f_slow = f_slow
	_f_refresh = f_refresh
	_color = color
	var dir: Vector3 = target_pos - start
	dir.y = 0.0
	_vel = (dir.normalized() if dir.length_squared() > 0.01 else Vector3.FORWARD) * _speed
	_build_bubble()


func _build_bubble() -> void:
	# Двухслойный пузырь: прозрачное ядро + ярче-кромка (double-sided — видно
	# «сквозь», читается как мыльный пузырь).
	var core := SphereMesh.new()
	core.radius = 0.95
	core.height = 1.9
	core.radial_segments = 20
	core.rings = 12
	_bubble = MeshInstance3D.new()
	_bubble.mesh = core
	_bubble.material_override = _make_mat(0.22, 1.4)
	_bubble.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bubble)


func _make_mat(alpha: float, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(_color.r, _color.g, _color.b, alpha)
	mat.emission_enabled = true
	mat.emission = Color(_color.r, _color.g, _color.b, 1.0)
	mat.emission_energy_multiplier = energy
	return mat


func _physics_process(delta: float) -> void:
	if _bursted:
		return
	_elapsed += delta
	var tower: Node = get_tree().get_first_node_in_group(Tower.GROUP)
	if tower == null or not is_instance_valid(tower):
		queue_free()  # цель пропала — фитиль
		return
	var tpos: Vector3 = (tower as Node3D).global_position
	var to: Vector3 = Vector3(tpos.x - global_position.x, 0.0, tpos.z - global_position.z)
	var dist: float = to.length()
	# Догнал → лопается зоной. Истёк lifetime вне радиуса → гаснет (увернулся).
	if dist <= _burst_radius:
		_burst()
		return
	if _elapsed >= _life:
		queue_free()
		return
	# Homing: плавный доворот к текущей позиции башни (exp-decay), движение в XZ.
	var desired: Vector3 = to / maxf(dist, 0.001)
	var cur: Vector3 = _vel.normalized() if _vel.length_squared() > 0.001 else desired
	var decay: float = 1.0 - exp(-_turn * delta)
	_vel = cur.slerp(desired, decay).normalized() * _speed
	global_position += _vel * delta
	# Лёгкий пульс пузыря.
	if is_instance_valid(_bubble):
		var p: float = 1.0 + 0.1 * sin(_elapsed * 8.0)
		_bubble.scale = Vector3(p, p, p)


## Лопается: спавнит slow-зону под собой (≈ на игроке, т.к. долетел) + pop-анимация.
func _burst() -> void:
	_bursted = true
	var root: Node = get_tree().current_scene
	if root != null:
		var field := SlowField.new()
		root.add_child(field)
		var c: Vector3 = global_position
		c.y = 0.0
		field.setup(c, _f_radius, _f_duration, _f_slow, _f_refresh, _color)
	if is_instance_valid(_bubble):
		var mat := _bubble.material_override as StandardMaterial3D
		var tw := create_tween()
		tw.tween_property(_bubble, "scale", Vector3.ONE * 3.0, 0.25)
		if mat != null:
			tw.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.25)
		tw.tween_callback(queue_free)
	else:
		queue_free()
