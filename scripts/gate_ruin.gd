class_name GateRuin
extends Node3D
## Древние Врата — проход из Верхнего Предела обратно в гномьи рукава, к
## подземной столице (финал акта II). Механизм цел, но МЁРТВ: ему нужно живое
## ядро — СЕРДЦЕ ЛАДЬИ ([LadyaHeart]) из разбитой башни посреди поля. Гномы
## выковыривают его и несут к своей башне; сердце на месте — Врата откликаются.
## Руны на плите: две теплеют на подходе башни, все три вспыхивают на сердце.
##
## ⚠ ПЛАТА 900🥉 УБРАНА (пивот 2026-08-12). Копить можно сидя на месте, а
## сходить за сердцем нельзя — выход из уровня обязан быть ВЫЛАЗКОЙ, а не
## таймером казны. Заодно это развело валюты: золото тратится на уровне, а
## финал стоит поступка. Возвращать оплату не надо — цепочка ниже та же.
##
## СЕРДЦЕ БУДИТ СТРАЖА: грохот древнего механизма поднимает нежить всей
## долины — предупреждение → мех-страж ([EnemyMech], соло-дуэль, СТРОГО один —
## канон) + финальная осада со всех сторон ([WaveDirector.launch_final_siege]).
## Страж пал → створ съезжает под землю → башня в проёме = победа акта.
## «Последняя ночь» наступает, когда игрок накопил и заплатил: цена = ручка
## темпа акта, убежать с арены втихую нельзя.

const GROUP := &"gate_ruin"
const ACTION_GRAB := &"hand_grab"

## Зона ЛКМ-клика по вратам (полуразмеры XZ в локальных осях: плита + пилоны).
@export var click_half_extents: Vector2 = Vector2(6.5, 3.0)
## Руны на плите — теплеют по третям накопленной платы.
@export var rune_paths: Array[NodePath] = []
@export var rune_dead_energy: float = 0.15
@export var rune_live_energy: float = 3.0
## Плита-створ (Blocker-StaticBody): после смерти стража съезжает под землю.
@export var slab_path: NodePath = ^"Slab"
## Мех-страж Врат ([EnemyMech], СОЛО-дуэль — канон «строго 1 за раз»).
@export var mech_scene: PackedScene
## Задержка выхода стража после оплаты (сек) — время на предупреждение.
@export var mech_delay: float = 3.0
## Насколько плита уезжает вниз при открытии.
@export var slab_slide_depth: float = 7.0

var _runes: Array[MeshInstance3D] = []
var _lit_runes: int = 0
var _paid: bool = false
var _awake: bool = false
var _mech: Node3D = null
var _open: bool = false
var _won: bool = false
var _approach_hinted: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	for p: NodePath in rune_paths:
		var r := get_node_or_null(p) as MeshInstance3D
		if r != null:
			_runes.append(r)
	var poll := Timer.new()
	poll.wait_time = 0.5
	poll.autostart = true
	add_child(poll)
	poll.timeout.connect(_poll)


## ЛКМ-клик по плите врат = ОСМОТР: механизм сам ничего не принимает, он ждёт
## сердце. Клик оставлен, потому что игрок всё равно ткнёт в единственный
## заметный объект — и должен получить ответ, а не тишину.
## Input.is_action_just_pressed
## живёт один кадр — ловим в _process, не в поллинге (гейты как у
## PadBuilding._clicked_on_self: модалка/aim/HUD/занятая рука — не клик).
func _process(_delta: float) -> void:
	if _paid or not Input.is_action_just_pressed(ACTION_GRAB):
		return
	var tree := get_tree()
	var trade := tree.get_first_node_in_group(&"trade_ui")
	if trade != null and trade.has_method(&"is_open") and trade.call(&"is_open"):
		return
	var hand := tree.get_first_node_in_group(Hand.HAND_GROUP) as Hand
	if hand == null:
		return
	if hand.is_in_aim_mode() or hand.is_pointer_over_ui() or hand.is_holding():
		return
	var local: Vector3 = to_local(hand.cursor_world_position())
	if absf(local.x) <= click_half_extents.x and absf(local.z) <= click_half_extents.y:
		EventBus.tutorial_hint.emit(
			"Механизм мёртв: ему нужно живое ядро. Сердце Ладьи — в разбитой башне на поле", 5.0)


## Сердце доставлено (историческое имя — раньше это была оплата).
func is_paid() -> bool:
	return _paid


func is_awake() -> bool:
	return _awake


func is_open() -> bool:
	return _open


func is_guard_down() -> bool:
	return _awake and _mech == null


## ⛔ Цены больше нет: финал открывает сердце, а не казна. Оставлено нулём,
## потому что старый чеклист заданий ещё спрашивает (ValleyQuests._gate_price).
func price() -> int:
	return 0


func _poll() -> void:
	_check_victory()
	_tick_approach_hint()
	# Руны: две теплеют, когда башня подошла к вратам (механизм чует машину),
	# третья — только на сердце. Одометр казны выпилен вместе с платой.
	var lit: int = 3
	if not _paid:
		lit = 2 if _tower_near(20.0) else 0
	if lit == _lit_runes:
		return
	var grew: bool = lit > _lit_runes
	_lit_runes = lit
	_update_runes()
	if grew and not _paid:
		AoeVisual.spawn_pulse_sparks(get_tree().current_scene,
			global_position + Vector3.UP * 2.0, 1.6, 10.0)
		EventBus.tutorial_hint.emit(
			"Руны Врат теплеют — механизм чует Ладью. Не хватает живого ядра", 5.0)


## Первый подъезд башни к вратам → подсказка, чего механизму надо (один раз).
func _tick_approach_hint() -> void:
	if _approach_hinted or _paid:
		return
	if not _tower_near(16.0):
		return
	_approach_hinted = true
	EventBus.tutorial_hint.emit(
		"Врата в подземную столицу. Механизм мёртв — ему нужно Сердце Ладьи из разбитой башни",
		8.0)


## Башня в радиусе (XZ). Одна проверка на две ветки — подсказку и руны.
func _tower_near(radius: float) -> bool:
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	if tower == null:
		return false
	var d: Vector3 = tower.global_position - global_position
	return Vector2(d.x, d.z).length() <= radius


func _update_runes() -> void:
	for i in _runes.size():
		var mat := _runes[i].material_override as StandardMaterial3D
		if mat != null:
			mat.emission_energy_multiplier = \
				rune_live_energy if i < _lit_runes else rune_dead_energy


## ⭐ ТОЧКА ВХОДА ФИНАЛА. Зовёт [LadyaHeart], когда гномы донесли сердце до
## башни. Идемпотентна: второе сердце (или повторная доставка) не поднимает
## второго стража — канон «мех СТРОГО один за раз».
func awaken_by_heart() -> void:
	if _paid:
		return
	_paid = true
	_awake = true
	_lit_runes = 3
	_update_runes()
	_on_awakened()


## Сердце на месте — механизм оживает. Финал акта: предупреждение → из врат
## выходит мех-страж (соло-дуэль, СТРОГО один — канон
## [[project_ebm_mech_solo_apex]]) + грохот поднимает нежить всей долины
## (финальная осада со всех сторон) → убил стража → створ открывается →
## башня в проёме = победа (см. [_poll] хвост).
func _on_awakened() -> void:
	EventBus.camera_shake.emit(0.5, global_position)
	AoeVisual.spawn_explosion(get_tree().current_scene,
		global_position + Vector3.UP * 3.0, 3.0)
	EventBus.tutorial_hint.emit(
		"⚙ Плата принята. Механизм Врат гудит — грохот поднимает нежить со ВСЕЙ долины…", 8.0)
	EventBus.boss_wave_incoming.emit(mech_delay)
	var wd := get_tree().get_first_node_in_group(WaveDirector.GROUP)
	if wd != null and wd.has_method(&"launch_final_siege"):
		wd.call(&"launch_final_siege")
	var t := get_tree().create_timer(mech_delay)
	t.timeout.connect(_spawn_mech)


func _spawn_mech() -> void:
	if mech_scene == null:
		push_warning("[GateRuin] mech_scene не задан — страж не выйдет, врата откроются сразу")
		_open_gates()
		return
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	_mech = mech_scene.instantiate() as Node3D
	scene.add_child(_mech)
	_mech.global_position = global_position + Vector3(0, 1.2, 6.0)
	if _mech.has_signal(&"destroyed"):
		_mech.connect(&"destroyed", _on_mech_destroyed)
	AoeVisual.spawn_explosion(scene, _mech.global_position, 2.5)
	EventBus.camera_shake.emit(0.6, _mech.global_position)
	EventBus.tutorial_hint.emit("⚔ СТРАЖ ВРАТ! Срази его — путь домой за ним", 8.0)


func _on_mech_destroyed() -> void:
	_mech = null
	_open_gates()


## Створ уезжает под землю (как MetalDoor): навмеш снимаем СИНХРОННО в конце
## съезда — физика и навмеш согласованы, агенты не ходят «сквозь» плиту.
func _open_gates() -> void:
	if _open:
		return
	_open = true
	EventBus.tutorial_hint.emit("⚑ Врата открыты! Веди башню в проём — путь к подземной столице свободен", 10.0)
	var slab := get_node_or_null(slab_path) as Node3D
	if slab == null:
		return
	var tween := create_tween()
	tween.tween_property(slab, "position:y", slab.position.y - slab_slide_depth, 2.2) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(func() -> void:
		if is_instance_valid(slab):
			if slab.is_in_group(&"navmesh_source"):
				slab.remove_from_group(&"navmesh_source")
			var nav := get_tree().get_first_node_in_group(&"nav_region")
			if nav != null and nav.has_method(&"rebake"):
				nav.rebake()
			slab.queue_free())
	AoeVisual.spawn_dust(get_tree().current_scene, global_position + Vector3.UP * 0.5)
	EventBus.camera_shake.emit(0.5, global_position)


## Башня вошла в открытый проём (полоса врат, XZ) → победа акта.
func _check_victory() -> void:
	if not _open or _won:
		return
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	if tower == null:
		return
	var p: Vector3 = tower.global_position
	if absf(p.x - global_position.x) <= 4.5 and p.z <= global_position.z - 0.5:
		_won = true
		EventBus.match_won.emit()
