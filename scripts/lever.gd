class_name Lever
extends Node3D
## Рычаг-механизм. Игрок хватает рукой (ЛКМ [code]hand_grab[/code]) у основания и
## ТАЩИТ вбок — рукоять поворачивается вокруг основания вслед за смещением руки по X.
## Доведённый до дальнего края (progress=1) фиксируется и активирует цель
## ([target_path].activate(), обычно дверь). Работает ТОЛЬКО после [enable] —
## его зовёт [RedDiode], когда по проводу добежал ток. До этого не хватается.
##
## Своя ось ввода, НЕ через HandPhysical.grab: рычаг не Grabbable RigidBody, поэтому
## рука рядом ничего не «схватывает» — конфликта нет, рычаг сам читает hand_grab.

const ACTION_GRAB := &"hand_grab"

@export var target_path: NodePath
## Длина рукояти-стойки (торчит вверх).
@export var handle_length: float = 1.6
## Радиус захвата у основания (XZ). Зажал ЛКМ в нём → рычаг «в руке».
@export var engage_radius: float = 2.6
## Короткий рывок вбок (по X, м), после которого тумблер ПЕРЕКИДЫВАЕТСЯ в ON. Не
## плавный поворот — дёрнул за порог → перекинулся сам (как настоящий рубильник).
@export var throw_distance: float = 1.0
## Длительность перекида (сек) — быстрый снап с пружинкой.
@export var snap_duration: float = 0.16
## Наклон рукояти ВБОК (°, вокруг Z) в положениях OFF и ON. Стойка перекидывается
## из лево-наклона в право-наклон через вертикаль — флип, не горизонтальный поворот.
@export var start_angle_deg: float = 50.0
@export var end_angle_deg: float = -50.0
@export var idle_color: Color = Color(0.55, 0.55, 0.6)
## Подсветка рукояти когда рычаг включён (готов к использованию).
@export var ready_color: Color = Color(0.95, 0.85, 0.35)
## Подсветка при наведении руки (hover).
@export var hover_color: Color = Color(1.0, 0.95, 0.5)

var _enabled: bool = false
var _engaged: bool = false
var _thrown: bool = false
var _engage_ref_x: float = 0.0
var _hand: Hand = null
var _handle: Node3D = null
var _handle_mat: StandardMaterial3D = null
var _highlighted: bool = false


func _ready() -> void:
	_build_visual()
	_handle.rotation.z = deg_to_rad(start_angle_deg)  # OFF-положение (наклон вбок)


func _build_visual() -> void:
	# Основание — короткий цилиндр на земле.
	var base := MeshInstance3D.new()
	var base_cyl := CylinderMesh.new()
	base_cyl.top_radius = 0.5
	base_cyl.bottom_radius = 0.6
	base_cyl.height = 0.4
	base.mesh = base_cyl
	base.material_override = _make_mat(idle_color, 0.0)
	base.position.y = 0.2
	add_child(base)
	# Пивот у основания + рукоять-СТОЙКА вверх + набалдашник на конце. Наклоняется
	# вбок (вокруг Z) как тумблер — НЕ метёт по горизонтали.
	_handle = Node3D.new()
	_handle.position.y = 0.35
	add_child(_handle)
	_handle_mat = _make_mat(idle_color, 0.0)
	var arm := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.16, handle_length, 0.16)
	arm.mesh = box
	arm.material_override = _handle_mat
	arm.position = Vector3(0.0, handle_length * 0.5, 0.0)
	_handle.add_child(arm)
	var knob := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.22
	sph.height = 0.44
	knob.mesh = sph
	knob.material_override = _handle_mat
	knob.position = Vector3(0.0, handle_length, 0.0)
	_handle.add_child(knob)


## Зовёт RedDiode когда ток дошёл. До этого рычаг мёртв (не хватается, не подсвечен).
func enable() -> void:
	if _enabled:
		return
	_enabled = true
	add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)  # теперь рука подсвечивает наведение
	_refresh_handle_color()


## Контракт pickup-подсветки руки (Hand._update_pickup_highlight).
func set_highlighted(value: bool) -> void:
	_highlighted = value
	_refresh_handle_color()


func _refresh_handle_color() -> void:
	if _handle_mat == null:
		return
	if not _enabled:
		_handle_mat.albedo_color = idle_color
		_handle_mat.emission_energy_multiplier = 0.0
		return
	var c: Color = hover_color if _highlighted else ready_color
	_handle_mat.albedo_color = c
	_handle_mat.emission_enabled = true
	_handle_mat.emission = c
	_handle_mat.emission_energy_multiplier = 2.5 if _highlighted else 1.4


func _process(_delta: float) -> void:
	if _thrown or not _enabled:
		return
	var hand := _resolve_hand()
	if hand == null:
		return
	var hp: Vector3 = hand.cursor_world_position()
	var grabbing: bool = Input.is_action_pressed(ACTION_GRAB)
	if not _engaged:
		var flat_d: float = Vector2(hp.x - global_position.x, hp.z - global_position.z).length()
		if grabbing and flat_d <= engage_radius:
			_engaged = true
			_engage_ref_x = hp.x
	else:
		if not grabbing:
			# Отпустил, не дёрнув за порог → щёлкаем обратно в OFF.
			_engaged = false
			_snap_to(start_angle_deg)
			return
		var pull: float = hp.x - _engage_ref_x
		if pull >= throw_distance:
			_throw()
		else:
			# Лёгкий нудж в сторону переключения — тактильный feedback, не полный ход.
			var lean: float = clampf(pull / throw_distance, 0.0, 1.0) * 0.18
			_handle.rotation.z = deg_to_rad(lerpf(start_angle_deg, end_angle_deg, lean))


## Щелчок тумблера в ON: быстрый снап с пружинкой, на финише — активация цели.
func _throw() -> void:
	_thrown = true
	_engaged = false
	var tw := create_tween()
	tw.tween_property(_handle, "rotation:z", deg_to_rad(end_angle_deg), snap_duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_trigger_target)


func _trigger_target() -> void:
	var target := get_node_or_null(target_path)
	if target != null and target.has_method(&"activate"):
		target.call(&"activate")


## Плавный возврат рукояти в заданный угол (снап-back при отпускании без щелчка).
func _snap_to(angle_deg: float) -> void:
	if _handle == null:
		return
	var tw := create_tween()
	tw.tween_property(_handle, "rotation:z", deg_to_rad(angle_deg), 0.1)


func _resolve_hand() -> Hand:
	if _hand != null and is_instance_valid(_hand):
		return _hand
	_hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP)
	return _hand


func _make_mat(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if energy > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = energy
	return mat
