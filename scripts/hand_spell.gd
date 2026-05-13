class_name HandSpell
extends Node
## Категория «Заклинания» руки. По образцу HandPhysicalActions: слушает
## equip-биндинг своих заклинаний (3 — Fireball), переключает Hand в
## active_category=MAGIC, диспатчит ПКМ-каст на активный подмодуль.
##
## Дочерние узлы:
##   - Fireball (HandSpellFireball) — баллистический снаряд из Tower с AOE-взрывом.
##   - Firestorm (HandSpellFirestorm) — серия из N малых фаерболов в зону.
##
## Какое заклинание активно — определяется `equipped`. Триггер каста
## (`hand_action`, ПКМ) реагирует только когда `_hand.active_category == MAGIC`.
##
## Архитектурно (унификация рукой и магии — дизайнерское решение 2026-05-03):
## AOE-заклинания используют ту же универсальную маску, что и Slam
## (`Layers.MASK_HAND_SLAM` — враги + гномы + башня + палатки + items), и
## обязаны фильтровать цели через `Layers.is_hand_immune(target)` ПОСЛЕ
## broad-phase-выборки.

signal spell_cast(spell_name: StringName, position: Vector3)

enum SpellType { FIREBALL, FIRESTORM, MINE_SCATTER }

const ACTION_ACTION := &"hand_action"
const ACTION_EQUIP_FIREBALL := &"equip_fireball"
const ACTION_EQUIP_FIRESTORM := &"equip_firestorm"
const ACTION_EQUIP_MINE_SCATTER := &"equip_mine_scatter"

@export var equipped: SpellType = SpellType.FIREBALL:
	set(value):
		if equipped == value:
			return
		equipped = value
		if is_inside_tree() and debug_log and LogConfig.master_enabled:
			print("[Hand:Spell] экипировано: %s" % SpellType.keys()[value])

@export var debug_log: bool = true

var _hand: Hand

@onready var _fireball: HandSpellFireball = $Fireball
@onready var _firestorm: HandSpellFirestorm = $Firestorm
@onready var _mine_scatter: HandSpellMineScatter = $MineScatter


func _ready() -> void:
	_fireball.spell_cast.connect(spell_cast.emit)
	_firestorm.spell_cast.connect(spell_cast.emit)
	_mine_scatter.spell_cast.connect(spell_cast.emit)


## Координатор Hand вызывает этот метод после собственного _ready, передавая
## ссылку на руку. Подмодули получают ссылку через нас же.
func setup(hand: Hand) -> void:
	_hand = hand
	_fireball.setup(_hand, self)
	_firestorm.setup(_hand, self)
	_mine_scatter.setup(_hand, self)


func _process(delta: float) -> void:
	# Тикаем подмодули (cooldown'ы) независимо от категории — иначе после
	# каста и переключения на физику cooldown «замораживается».
	_fireball.tick(delta)
	_firestorm.tick(delta)
	_mine_scatter.tick(delta)
	_handle_input()


# --- Ввод ---

func _handle_input() -> void:
	# В SUPER / SQUAD_AIM / BUILD_AIM режимах весь магический ввод (equip + cast)
	# заглушаем — соответствующий координатор сам вернёт категорию на завершении.
	if _hand.active_category == Hand.Category.SUPER \
			or _hand.active_category == Hand.Category.SQUAD_AIM \
			or _hand.active_category == Hand.Category.BUILD_AIM:
		return
	# Equip-биндинги — переключают Hand в MAGIC и выбирают конкретное
	# заклинание. Слушаются всегда (даже когда сейчас PHYSICAL).
	if Input.is_action_just_pressed(ACTION_EQUIP_FIREBALL):
		equipped = SpellType.FIREBALL
		_hand.set_active_category(Hand.Category.MAGIC)
	elif Input.is_action_just_pressed(ACTION_EQUIP_FIRESTORM):
		equipped = SpellType.FIRESTORM
		_hand.set_active_category(Hand.Category.MAGIC)
	elif Input.is_action_just_pressed(ACTION_EQUIP_MINE_SCATTER):
		equipped = SpellType.MINE_SCATTER
		_hand.set_active_category(Hand.Category.MAGIC)

	# Каст слушаем только если рука сейчас в магической категории и
	# свободна. Держишь предмет — магия не работает (рука занята).
	if _hand.active_category != Hand.Category.MAGIC:
		return
	if _hand.is_holding():
		return

	# UI-гейт на ПКМ-каст: клик по кнопке HUD'а параллельно кастил бы фаербол
	# в точку под виджетом. Equip-биндинги клавиатурой выше гейтом не тронуты.
	if Input.is_action_just_pressed(ACTION_ACTION) and not _hand.is_pointer_over_ui():
		_dispatch_cast()


func _dispatch_cast() -> void:
	match equipped:
		SpellType.FIREBALL:
			if _fireball.can_trigger():
				_fireball.on_press()
			elif debug_log and LogConfig.master_enabled:
				print("[Hand:Spell] фаербол на кулдауне")
		SpellType.FIRESTORM:
			if _firestorm.can_trigger():
				_firestorm.on_press()
			elif debug_log and LogConfig.master_enabled:
				print("[Hand:Spell] шквал на кулдауне")
		SpellType.MINE_SCATTER:
			if _mine_scatter.can_trigger():
				_mine_scatter.on_press()
			elif debug_log and LogConfig.master_enabled:
				print("[Hand:Spell] минное-рассевание на кулдауне")
