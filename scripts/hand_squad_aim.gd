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
const ACTION_AIM_CANCEL := &"ui_cancel"  # Esc — отмена aim'а (Godot-дефолт)

@export_group("Visual")
## Цвет ground-ring'а под курсором когда враги ВНЕ зоны прицеливания.
## Голубой — отличается от золотого aim_indicator'а супер-удара и
## оранжевого warning'а магии.
@export var aim_ring_color: Color = Color(0.4, 0.85, 1.0, 0.9)
## Цвет когда внутри зоны есть враги — красный «опасность здесь, отряд
## пойдёт в бой». Используется как сигнал «это указание цели, не просто
## точки».
@export var aim_ring_color_hostile: Color = Color(1.0, 0.25, 0.25, 0.95)
## Радиус кольца в метрах. Используется и как визуал «куда пойдёт отряд»,
## и как зона сканирования врагов: если в радиусе кольца есть скелет —
## кольцо подсвечивается hostile-цветом.
@export var aim_ring_radius: float = 3.5
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
	# _camp пытаемся резолвить тут, но Camp может ещё не быть в группе
	# (порядок _ready bottom-up — HandSquadAim._ready зовётся до Camp._ready
	# если Hand-узел стоит выше Camp в main.tscn). Lazy-lookup в _commit_aim.
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
	if squad == null:
		push_warning("[Hand:SquadAim] start_aim получил null squad")
		return
	if not is_instance_valid(_hand):
		push_warning("[Hand:SquadAim] start_aim — _hand не задан (setup не вызван?)")
		return
	if _active_squad != null:
		cancel_aim()
	_active_squad = squad
	_pre_aim_category = _hand.active_category
	_hand.set_active_category(Hand.Category.SQUAD_AIM)
	_spawn_indicator()
	if debug_log and LogConfig.master_enabled:
		print("[Hand:SquadAim] aim старт для %s, prev_category=%s" % [str(squad), Hand.Category.keys()[_pre_aim_category]])


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
		# Подсветка hostile когда враги в радиусе кольца — игрок видит, что
		# это указание цели, а не просто перемещение в пустое место.
		_set_ring_hostile(_has_enemies_in_aim_zone(ground))
	# Esc — отмена aim'а без команды. UI-гейт не нужен: ui_cancel не должен
	# использоваться никакой кнопкой HUD'а как клавиатурный shortcut.
	if Input.is_action_just_pressed(ACTION_AIM_CANCEL):
		cancel_aim()
		return
	# ПКМ — commit точки. Используем Input.is_action_just_pressed: aim mode
	# единственный listener в этой категории, конфликтов нет. UI-гейт: если
	# курсор над виджетом HUD'а, ПКМ — это клик по кнопке, не команда отряду
	# (иначе клик «За башней» во время aim'а ставил бы юнитов в случайную точку).
	if Input.is_action_just_pressed(ACTION_AIM_COMMIT) and not _hand.is_pointer_over_ui():
		_commit_aim()


## True если в круге aim_ring_radius вокруг центра есть живой враг любого типа.
## Идём через `Enemy.ENEMY_GROUP` — все наследники Enemy (melee-Skeleton +
## Archer + Giant + Thrower + любой будущий тип), NEAR и FAR-LOD одинаково.
## SKELETON_GROUP-only был бы асимметрией: каменщик / обычный archer не
## вошли бы в неё (они extends Archer, не Skeleton) → кольцо не подсвечивалось
## бы hostile-цветом, хотя SoldierGnome их теперь атакует через ENEMY_GROUP.
## См. [[feedback-symmetric-interactions]].
##
## Дёшево: ~50 врагов max × 1 frame, без sqrt.
func _has_enemies_in_aim_zone(center: Vector3) -> bool:
	var r_sq: float = aim_ring_radius * aim_ring_radius
	for n in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(n):
			continue
		var node3d := n as Node3D
		if node3d == null:
			continue
		var dx: float = node3d.global_position.x - center.x
		var dz: float = node3d.global_position.z - center.z
		if dx * dx + dz * dz <= r_sq:
			return true
	return false


## Меняет albedo + emission материала кольца на hostile/neutral.
## StandardMaterial3D создан в AoeVisual.spawn_ground_ring; мы знаем его
## структуру и берём через material_override.
func _set_ring_hostile(hostile: bool) -> void:
	if not is_instance_valid(_aim_indicator):
		return
	var mat := _aim_indicator.material_override as StandardMaterial3D
	if mat == null:
		return
	var c: Color = aim_ring_color_hostile if hostile else aim_ring_color
	mat.albedo_color = c
	mat.emission = Color(c.r, c.g, c.b, 1.0)


func _commit_aim() -> void:
	if _active_squad == null:
		return
	var ground: Vector3 = _hand.cursor_world_position()
	ground.y -= _hand.hand_height
	# Lazy-resolve: если в _ready Camp ещё не был в группе, пробуем сейчас.
	if not is_instance_valid(_camp):
		_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	if is_instance_valid(_camp):
		_camp.command_squad_hold(_active_squad, ground)
		if debug_log and LogConfig.master_enabled:
			print("[Hand:SquadAim] commit %s @ (%.1f, %.1f, %.1f)" % [str(_active_squad), ground.x, ground.y, ground.z])
	else:
		push_warning("[Hand:SquadAim] _camp не резолвится — команда не дошла")
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
