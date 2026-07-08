class_name GateRuin
extends Node3D
## Древние Врата — проход из Верхнего Предела обратно в гномьи рукава, к
## подземной столице (финал акта II). Механизм цел, но ЖАДЕН: открывается
## за плату из казны ([exit_price_bronze]) — накопи и кликни рукой по плите.
## Руны на плите — одометр накопления: теплеют по третям цены (казна/цена),
## все три вспыхивают на оплате.
##
## ОПЛАТА БУДИТ СТРАЖА: грохот древнего механизма поднимает нежить всей
## долины — предупреждение → мех-страж ([EnemyMech], соло-дуэль, СТРОГО один —
## канон) + финальная осада со всех сторон ([WaveDirector.launch_final_siege]).
## Страж пал → створ съезжает под землю → башня в проёме = победа акта.
## «Последняя ночь» наступает, когда игрок накопил и заплатил: цена = ручка
## темпа акта, убежать с арены втихую нельзя.

const GROUP := &"gate_ruin"
const ACTION_GRAB := &"hand_grab"

## Плата за проход (бронза-эквивалент единой казны). Балансируется под
## «~3 игровых суток с полным развитием замка».
@export var exit_price_bronze: int = 900
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


## ЛКМ-клик по плите врат = попытка оплаты. Input.is_action_just_pressed
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
		_try_pay()


func is_paid() -> bool:
	return _paid


func is_awake() -> bool:
	return _awake


func is_open() -> bool:
	return _open


func is_guard_down() -> bool:
	return _awake and _mech == null


func price() -> int:
	return exit_price_bronze


func _bank() -> Node:
	return get_tree().get_first_node_in_group(GoldBank.GROUP)


func _poll() -> void:
	_check_victory()
	_tick_approach_hint()
	# Руны-одометр: казна/цена по третям (третья загорается только оплатой).
	var lit: int = 3
	if not _paid:
		var bank := _bank()
		var have: int = 0 if bank == null else int(bank.call(&"get_gold"))
		lit = clampi(int(3.0 * float(have) / float(maxi(exit_price_bronze, 1))), 0, 2)
	if lit == _lit_runes:
		return
	var grew: bool = lit > _lit_runes
	_lit_runes = lit
	_update_runes()
	if grew and not _paid:
		AoeVisual.spawn_pulse_sparks(get_tree().current_scene,
			global_position + Vector3.UP * 2.0, 1.6, 10.0)
		EventBus.tutorial_hint.emit(
			"Руна Врат теплеет — казна растёт (%d/3 платы)" % _lit_runes, 5.0)


## Первый подъезд башни к вратам → подсказка про плату (один раз).
func _tick_approach_hint() -> void:
	if _approach_hinted or _paid:
		return
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	if tower == null:
		return
	var d: Vector3 = tower.global_position - global_position
	if Vector2(d.x, d.z).length() > 16.0:
		return
	_approach_hinted = true
	EventBus.tutorial_hint.emit(
		"Врата в подземную столицу. Механизм требует плату: %d🥉 — накопи и кликни по плите" % exit_price_bronze,
		8.0)


func _update_runes() -> void:
	for i in _runes.size():
		var mat := _runes[i].material_override as StandardMaterial3D
		if mat != null:
			mat.emission_energy_multiplier = \
				rune_live_energy if i < _lit_runes else rune_dead_energy


func _try_pay() -> void:
	var bank := _bank()
	if bank == null:
		return
	if not bank.call(&"try_spend", exit_price_bronze):
		var have: int = int(bank.call(&"get_gold"))
		EventBus.tutorial_hint.emit(
			"Механизму мало: проход %d🥉, в казне %d🥉" % [exit_price_bronze, have], 4.0)
		return
	_paid = true
	_awake = true
	_lit_runes = 3
	_update_runes()
	_on_awakened()


## Оплата принята — механизм оживает. Финал акта: предупреждение → из врат
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
