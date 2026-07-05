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
## Единая группа «гном бьёт точку → действие» (горшки + рычаги). Гном заряжается на
## цель и СТРАЙКОМ вызывает gnome_hit() — как с горшком, не проходом через область.
const GNOME_STRIKE_GROUP := Layers.GNOME_STRIKE_TARGET_GROUP

## Визуал — в сцене lever.tscn (узлы Base / Handle{Arm,Knob}); скрипт = только
## поведение. Материал ручки — local_to_scene → у каждого инстанса свой (мутируем
## цвет независимо). Раньше визуал генерился в коде (_build_visual) — убрано.
@export var target_path: NodePath
## Гном-взаимодействие (единая система «гном → точка → действие»): рычаг — strike-
## цель, гном ЗАРЯЖАЕТСЯ на него и перекидывает УДАРОМ (gnome_hit), как горшок.
## Активен с _ready (без enable/RedDiode-цепочки), горит ready-цветом как задача.
## Для «башня не лезет — пошли гнома».
@export var gnome_pullable: bool = false
## Требуемая роль гнома (soldier_type). Пусто = любой. Рычаг ФИЗИЧЕСКИЙ — копейщику
## ок; магический механизм потребует искрового (шаг 2).
@export var gnome_required_role: StringName = &""
## true → гном-рычаг ЗАПИТАН: доступен гному только после enable() (цепь искра →
## синий диод → ток → красный диод). false → активен сразу (standalone). Это кооп:
## башня питает цепь искрой, гном перекидывает рычаг.
@export var gnome_needs_power: bool = false
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
@onready var _handle: Node3D = $Handle
@onready var _handle_mat: StandardMaterial3D = ($Handle/Arm as MeshInstance3D).material_override
var _highlighted: bool = false


func _ready() -> void:
	_handle.rotation.z = deg_to_rad(start_angle_deg)  # OFF-положение (наклон вбок)
	# Standalone гном-рычаг — активен сразу; запитанный (gnome_needs_power) ждёт
	# enable() от RedDiode (цепь искра → синий → красный).
	if gnome_pullable and not gnome_needs_power:
		enable()


## Активация рычага. Hand-рычаг зовёт RedDiode (ток дошёл); гном-рычаг — RedDiode
## по той же цепи (искра→синий→красный). До enable рычаг мёртв.
func enable() -> void:
	if _enabled:
		return
	_enabled = true
	if gnome_pullable:
		add_to_group(GNOME_STRIKE_GROUP)  # гном теперь может БИТЬ рычаг (strike-цель)
		if gnome_needs_power:
			# Маркер «запитанный гном-рычаг ожил» — для читателей вроде
			# TutorialHint (подсказка «пошли артель к рычагу»).
			add_to_group(&"gnome_lever_powered")
	else:
		add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)  # рука подсвечивает/тянет
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
	if _thrown:
		return
	# Гном-рычаг рукой не тянем — только гном бьёт (через gnome_hit). Hand-pull
	# только для не-gnome рычагов и только после enable.
	if not _enabled or gnome_pullable:
		return
	var hand := _resolve_hand()
	if hand == null:
		return
	var hp: Vector3 = hand.cursor_world_position()
	# Не хватать рычаг клик-командами aim-режимов (стройка/команда/супер), кликом по HUD
	# и при удержании предмета — иначе commit-зажатие ЛКМ рядом перекидывает рычаг.
	var grabbing: bool = Input.is_action_pressed(ACTION_GRAB) \
		and not (hand.is_in_aim_mode() or hand.is_pointer_over_ui() or hand.is_holding())
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


## Контракт strike-цели: может ли этот гном перекинуть рычаг (роль). Гейт по роли —
## физический рычаг копейщику ок, магический потребует искрового (gnome_required_role).
func can_gnome_interact(gnome: Node) -> bool:
	if _thrown or not _enabled:
		return false
	# Роль через get() (не прямой .soldier_type) — контракт duck-typed на Node.
	return gnome_required_role == &"" or gnome.get(&"soldier_type") == gnome_required_role


## Контракт strike-цели: гном ударил по рычагу → перекидываем (как gnome_hit горшка).
func gnome_hit(_gnome: Node = null) -> void:
	if _thrown:
		return
	_throw()


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
