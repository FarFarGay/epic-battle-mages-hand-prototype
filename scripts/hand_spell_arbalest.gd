class_name HandSpellArbalest
extends Node
## Подмодуль «Арбалетный залп» — физическое оружие башни в трее магии.
##
## НЕ снаряд руки: болты выпускает [TowerUpgrades] (срез «Арбалетные окна» на
## башне). Этот модуль — только каст-обвязка по образцу Spark: ПКМ → телеграф-
## кольцо в точке + tower_upgrades.fire_volley(точка). Стволы работают, пока
## внутри башни спрятаны лучники (карточка отряда → «В башню») — без экипажа
## can_trigger()=false, слот трея тусклый.
##
## Маны не тратит (железо, не магия) — гейт только кулдаун залпа + экипаж.
## cooldown читается из SpellSystem.get_current_level_data (single source of
## truth), @export — fallback для дев-сцен без autoload'а.

signal spell_cast(spell_name: StringName, position: Vector3)

const SPELL_ID := &"arbalest_volley"

@export_group("Balance")
## Пауза между ОЧЕРЕДЯМИ (сек). Клик = очередь из burst_count залпов
## (TowerUpgrades.fire_burst); кулдаун должен перекрывать длину очереди.
@export var cooldown: float = 1.2

@export_group("Telegraph")
## Кольцо в точке очереди: живёт, пока идёт очередь (~0.5с) — стальное,
## отлично от жёлтой Искры и оранжевого фаербола.
@export var warning_duration: float = 0.6
@export var warning_color: Color = Color(0.7, 0.78, 0.9, 0.85)

@export_group("")
@export var effects_root_path: NodePath
@export var debug_log: bool = true

var _hand: Hand
var _coord: HandSpell
var _cooldown_remaining: float = 0.0
var _effects_root: Node = null
var _upgrades: TowerUpgrades = null


func setup(hand: Hand, coord: HandSpell) -> void:
	_hand = hand
	_coord = coord
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = _hand.get_tree().current_scene


# --- Публичный API (контракт HandSpell: can_trigger / on_press / tick) ---

## Готов, когда кулдаун прошёл И окнам есть кем стрелять (экипаж в башне).
## HUD-трей тускнит слот, пока false — видно «лучников надо спрятать в башню».
func can_trigger() -> bool:
	if _cooldown_remaining > 0.0:
		return false
	var up := _resolve_upgrades()
	return up != null and up.can_volley()


func on_press() -> void:
	_perform_cast()


func tick(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)


# --- Каст ---

func _perform_cast() -> void:
	if SpellSystem != null and not SpellSystem.is_unlocked(SPELL_ID):
		return
	var up := _resolve_upgrades()
	if up == null:
		return
	var lvl: Dictionary = SpellSystem.get_current_level_data(SPELL_ID) if SpellSystem != null else {}
	var p_cooldown: float = float(lvl.get("cooldown", cooldown))
	var target_pos: Vector3 = _hand.cursor_world_position()
	target_pos.y -= _hand.hand_height
	# ОЧЕРЕДЬ стреляет сама башня (TowerUpgrades): burst_count быстрых залпов, цель
	# у точки / промах в точку. false = стрелять нечем (экипаж вышел между
	# can_trigger и кастом) — без кулдауна.
	if not up.fire_burst(target_pos):
		return
	_cooldown_remaining = p_cooldown
	if _effects_root != null:
		AoeVisual.spawn_ground_ring(_effects_root, target_pos,
			float(up.designate_radius), warning_duration, warning_color)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:Arbalest] залп @ (%.1f, %.1f)" % [target_pos.x, target_pos.z])
	spell_cast.emit(SPELL_ID, target_pos)


## Нода срезов башни (Upgrades в tower.tscn) — lazy через группу, кэш до freed.
func _resolve_upgrades() -> TowerUpgrades:
	if _upgrades != null and is_instance_valid(_upgrades):
		return _upgrades
	_upgrades = get_tree().get_first_node_in_group(TowerUpgrades.GROUP) as TowerUpgrades
	return _upgrades
