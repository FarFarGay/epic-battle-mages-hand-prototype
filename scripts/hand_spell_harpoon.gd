class_name HandSpellHarpoon
extends Node
## Подмодуль «Гарпун» — стрела с цепью из башни (см. [HarpoonBolt]).
##
## Каст по образцу Spark: ПКМ → стрела из башни ПРЯМО в сторону курсора
## (плоское направление, полёт на фиксированной высоте над землёй).
## Мелочь пробивает, тяжёлых/предметы цепляет и тянет к башне.
## Параметры — из [SpellSystem.get_current_level_data] (single source of
## truth), @export'ы — fallback для дев-сцен без autoload'а.

signal spell_cast(spell_name: StringName, position: Vector3)

@export_group("Balance")
@export var damage: float = 60.0
@export var cooldown: float = 2.5
@export var mana_cost: float = 25.0
@export var max_range: float = 20.0
@export var bolt_speed: float = 40.0
@export var pull_speed: float = 14.0

@export_group("Visual")
## Высота полёта стрелы над землёй (уровень груди скелета).
@export var flight_height: float = 1.0

@export_group("")
@export var debug_log: bool = true

var _hand: Hand
var _coord: HandSpell
var _cooldown_remaining: float = 0.0
var _effects_root: Node = null
## Живой гарпун этого кастера (один одновременно): повторный ПКМ при
## выбранном гарпуне ОТМЕНЯЕТ его (bolt.cancel), не стреляет новым.
var _active_bolt: HarpoonBolt = null


func setup(hand: Hand, coord: HandSpell) -> void:
	_hand = hand
	_coord = coord
	_effects_root = _hand.get_tree().current_scene


func can_trigger() -> bool:
	if _cancelable_bolt() != null:
		return true  # слот активен: нажатие = отмена висящего гарпуна
	# МОДУЛЬНЫЙ ГЕЙТ (пилот 2026-07-07): гарпун стреляет ТОЛЬКО с установленной
	# Гарпунной турелью на корпусе (аппарат-вещь, рука ставит). Нет аппарата —
	# слот в трее тусклый.
	if _mounted_module() == null:
		return false
	return _cooldown_remaining <= 0.0


## Установленный на башню аппарат гарпуна (или null).
func _mounted_module() -> Node3D:
	return get_tree().get_first_node_in_group(HarpoonModule.MOUNTED_GROUP) as Node3D


func on_press() -> void:
	# Приоритет отмены: есть зацепленный/воткнутый гарпун → ПКМ гасит его
	# (без маны и кулдауна). В полёте не отменяем (см. can_cancel).
	var bolt := _cancelable_bolt()
	if bolt != null:
		bolt.cancel()
		_active_bolt = null
		return
	if _cooldown_remaining <= 0.0:
		_perform_cast()


func _cancelable_bolt() -> HarpoonBolt:
	if _active_bolt != null and is_instance_valid(_active_bolt) and _active_bolt.can_cancel():
		return _active_bolt
	return null


func tick(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)


func _perform_cast() -> void:
	if SpellSystem != null and not SpellSystem.is_unlocked(&"harpoon"):
		return
	var lvl: Dictionary = SpellSystem.get_current_level_data(&"harpoon") if SpellSystem != null else {}
	var p_damage: float = float(lvl.get("damage", damage))
	var p_cooldown: float = float(lvl.get("cooldown", cooldown))
	var p_mana_cost: float = float(lvl.get("mana_cost", mana_cost))
	var p_range: float = float(lvl.get("range", max_range))
	var p_bolt_speed: float = float(lvl.get("bolt_speed", bolt_speed))
	var p_pull_speed: float = float(lvl.get("pull_speed", pull_speed))

	var tower := _coord.find_tower()
	if tower == null:
		return  # гарпун — оружие башни, без башни не кастуется
	var module := _mounted_module()
	if module == null:
		EventBus.tutorial_hint.emit("Нужна Гарпунная турель на корпусе: поднеси аппарат рукой к башне", 4.0)
		return
	var target_pos: Vector3 = _hand.cursor_world_position()
	target_pos.y -= _hand.hand_height
	var dir: Vector3 = VecUtil.horizontal(target_pos - tower.global_position)
	if dir.length() < 0.5:
		return  # клик в саму башню — направления нет
	if not _coord.try_consume_tower_mana(p_mana_cost):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Spell:Harpoon] не хватает маны (нужно %.0f)" % p_mana_cost)
		return
	_cooldown_remaining = p_cooldown

	# Старт: ИЗ АППАРАТА (он на корпусе — рядом с башней), на высоте полёта у цели.
	var flight_y: float = target_pos.y + flight_height
	var start: Vector3 = Vector3(module.global_position.x, flight_y, module.global_position.z) \
		+ dir.normalized() * 1.2
	var bolt := HarpoonBolt.new()
	bolt.damage = p_damage
	bolt.max_range = p_range
	bolt.bolt_speed = p_bolt_speed
	bolt.pull_speed = p_pull_speed
	_active_bolt = bolt
	_effects_root.add_child(bolt)
	bolt.add_to_group(&"player_projectile")  # мех уклоняется от снарядов игрока
	bolt.setup(tower as Node3D, start, dir, _effects_root)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:Harpoon] гарпун → (%.1f, %.1f) damage=%.0f" % [target_pos.x, target_pos.z, p_damage])
	spell_cast.emit(&"harpoon", target_pos)
	EventBus.tower_fired.emit(target_pos)  # отдача башни
