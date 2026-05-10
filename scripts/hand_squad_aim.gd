class_name HandSquadAim
extends Node
## Координатор aim-режима для команды отряду «Идти сюда». Ввод ПКМ при
## активном aim'е считается подтверждением точки — squad получает команду
## командования hold(pos), aim завершается.
##
## По образцу HandSuper.AIMING_TARGET, но без предшествующего QTE — это
## мгновенный command-targeting. UI (gameplay_hud) запускает через
## `start_aim(squad)`; повторный клик той же squad-кнопки → `cancel_aim()`
## (toggle).
##
## Hand-категория переключается в SQUAD_AIM на время aim'а — все остальные
## ввод-системы (hand_physical / hand_spell / hand_super) гасятся ранним return.

const ACTION_AIM_COMMIT := &"hand_action"  # ПКМ — commit точки

@export_group("Visual")
## Цвет ground-ring'а под курсором. Голубой — отличается от золотого
## aim_indicator'а супер-удара и оранжевого warning'а магии.
@export var aim_ring_color: Color = Color(0.4, 0.85, 1.0, 0.9)
## Радиус кольца в метрах. Не привязан к squad'у — это маркер «вот здесь
## будет точка», не AOE.
@export var aim_ring_radius: float = 1.5
@export var debug_log: bool = true

@export_group("")
@export var effects_root_path: NodePath

var _hand: Hand
var _camp: Camp
var _effects_root: Node = null
var _active_squad: Squad = null
## Категория Hand'а до старта aim'а — на завершении возвращаем (PHYSICAL/MAGIC).
var _pre_aim_category: int = Hand.Category.PHYSICAL
var _aim_indicator: MeshInstance3D = null


func _ready() -> void:
	_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene


func setup(hand: Hand) -> void:
	_hand = hand


## True если сейчас идёт aim для указанного squad'а. UI использует для
## показа highlighted-state кнопки «Идти сюда» на карточке.
func is_aiming(squad: Squad) -> bool:
	return _active_squad != null and _active_squad == squad


## True если идёт aim вообще (для какого-то squad'а).
func is_aiming_any() -> bool:
	return _active_squad != null


## Toggle: если aim активен на этом squad'е → cancel. Иначе → start.
## UI зовёт при клике «Идти сюда».
func toggle_aim_for(squad: Squad) -> void:
	if _active_squad == squad:
		cancel_aim()
	else:
		start_aim(squad)


## Запуск aim'а. Если уже активен на другом squad'е — сначала отменяем
## предыдущий, потом стартуем новый (один aim в один момент времени).
func start_aim(squad: Squad) -> void:
	if squad == null or not is_instance_valid(_hand):
		return
	if _active_squad != null:
		cancel_aim()
	_active_squad = squad
	_pre_aim_category = _hand.active_category
	_hand.set_active_category(Hand.Category.SQUAD_AIM)
	_spawn_indicator()
	if debug_log and LogConfig.master_enabled:
		print("[Hand:SquadAim] aim для %s" % str(squad))


## Отмена без команды (повторный клик «Идти сюда» / squad распущен).
func cancel_aim() -> void:
	if _active_squad == null:
		return
	if debug_log and LogConfig.master_enabled:
		print("[Hand:SquadAim] aim отменён")
	_finish_aim()


func _process(_delta: float) -> void:
	if _active_squad == null:
		return
	# Двигаем ring под курсором каждый кадр. Ground-Y берём из cursor world
	# минус hand_height (как у Super.AIMING_TARGET).
	if is_instance_valid(_aim_indicator):
		var ground: Vector3 = _hand.cursor_world_position()
		ground.y -= _hand.hand_height
		_aim_indicator.global_position = ground + Vector3.UP * 0.05
	# ПКМ — commit точки. Используем Input.is_action_just_pressed: aim mode
	# единственный listener в этой категории, конфликтов нет.
	if Input.is_action_just_pressed(ACTION_AIM_COMMIT):
		_commit_aim()


func _commit_aim() -> void:
	if _active_squad == null:
		return
	var ground: Vector3 = _hand.cursor_world_position()
	ground.y -= _hand.hand_height
	if _camp != null and is_instance_valid(_camp):
		_camp.command_squad_hold(_active_squad, ground)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:SquadAim] commit @ (%.1f, %.1f, %.1f)" % [ground.x, ground.y, ground.z])
	_finish_aim()


func _finish_aim() -> void:
	_clear_indicator()
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.SQUAD_AIM:
		_hand.set_active_category(_pre_aim_category)
	_active_squad = null


func _spawn_indicator() -> void:
	_clear_indicator()
	if _effects_root == null:
		return
	# duration=0 → AoeVisual возвращает mesh без auto-fade.
	_aim_indicator = AoeVisual.spawn_ground_ring(
		_effects_root,
		_hand.cursor_world_position() - Vector3.UP * _hand.hand_height,
		aim_ring_radius,
		0.0,
		aim_ring_color,
	)


func _clear_indicator() -> void:
	if is_instance_valid(_aim_indicator):
		_aim_indicator.queue_free()
	_aim_indicator = null
