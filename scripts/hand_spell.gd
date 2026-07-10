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

enum SpellType { FIREBALL, FIRESTORM, MINE_SCATTER, FROST, SPARK, ARBALEST, HARPOON }

const ACTION_ACTION := &"hand_action"

@export var equipped: SpellType = SpellType.FIREBALL:
	set(value):
		if equipped == value:
			return
		equipped = value
		if is_inside_tree() and debug_log and LogConfig.master_enabled:
			print("[Hand:Spell] экипировано: %s" % SpellType.keys()[value])

@export var debug_log: bool = true

var _hand: Hand

## Кеш Tower'а — три spell-модуля и Super дёргают find_tower на каждом каст'е,
## раньше каждый делал свой `get_first_node_in_group`. Инвалидируется на
## EventBus.tower_destroyed (см. _on_tower_destroyed). Если Tower ещё не
## зареди'нился (race на старте) — lazy-резолв на следующем вызове.
var _tower_cache: Node3D = null

@onready var _fireball: HandSpellFireball = $Fireball
@onready var _firestorm: HandSpellFirestorm = $Firestorm
@onready var _mine_scatter: HandSpellMineScatter = $MineScatter
@onready var _frost: HandSpellFrost = $Frost
@onready var _spark: HandSpellSpark = $Spark
@onready var _arbalest: HandSpellArbalest = $Arbalest
@onready var _harpoon: HandSpellHarpoon = $Harpoon


## Готово ли заклинание к кастy. ActionBar дёргает для тусклой подсветки
## слотов на кулдауне.
func is_spell_ready(type: int) -> bool:
	match type:
		SpellType.FIREBALL:
			return _fireball.can_trigger()
		SpellType.FIRESTORM:
			return _firestorm.can_trigger()
		SpellType.MINE_SCATTER:
			return _mine_scatter.can_trigger()
		SpellType.FROST:
			return _frost.can_trigger()
		SpellType.SPARK:
			return _spark.can_trigger()
		SpellType.ARBALEST:
			return _arbalest.can_trigger()
		SpellType.HARPOON:
			return _harpoon.can_trigger()
	return true


## Каталожный id (SpellSystem.SPELL_CATALOG) текущего экипированного заклинания.
## Tower читает при входе в супер-дэш: dash_form/unlock-гейт живут в каталоге.
func equipped_spell_id() -> StringName:
	match equipped:
		SpellType.FIREBALL:
			return &"fireball"
		SpellType.FIRESTORM:
			return &"firestorm"
		SpellType.MINE_SCATTER:
			return &"mine_scatter"
		SpellType.FROST:
			return &"frost"
		SpellType.SPARK:
			return &"spark"
		SpellType.ARBALEST:
			return &"arbalest_volley"
		SpellType.HARPOON:
			return &"harpoon"
	return &""


func _ready() -> void:
	_fireball.spell_cast.connect(spell_cast.emit)
	_firestorm.spell_cast.connect(spell_cast.emit)
	_mine_scatter.spell_cast.connect(spell_cast.emit)
	_frost.spell_cast.connect(spell_cast.emit)
	_spark.spell_cast.connect(spell_cast.emit)
	_arbalest.spell_cast.connect(spell_cast.emit)
	_harpoon.spell_cast.connect(spell_cast.emit)
	EventBus.tower_destroyed.connect(_on_tower_destroyed)
	EventBus.super_dash_impact.connect(_on_super_dash_impact)


func _on_tower_destroyed() -> void:
	_tower_cache = null


## Импакт супер-дэша: башня доехала до цели — заклинание дэш-формы отрабатывает
## в точке. Диспатч на модуль-владелец (он знает свои параметры/сцены). Ману не
## трогаем — уплачена Tower'ом на коммите рывка.
func _on_super_dash_impact(position: Vector3, spell_id: StringName) -> void:
	match spell_id:
		&"fireball":
			_fireball.super_dash_burst(position)
		&"firestorm":
			_firestorm.super_dash_volley(position)


# --- Shared spell-cast helpers (используют 3 spell-модуля + HandSuper) ---

## Tower или null. Кешируется до tower_destroyed. Lazy-резолв если cache пуст.
## Несколько Tower'ов на сцене не поддерживаются — возвращается первый
## (мультибашня не в SPEC).
func find_tower() -> Node3D:
	if _tower_cache != null and is_instance_valid(_tower_cache):
		return _tower_cache
	_tower_cache = get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	return _tower_cache


## Точка launch'а снаряда: верх башни (+offset по Y) если Tower есть, иначе
## позиция руки. Fallback нужен для дев-сцен без Tower'а и для случая
## «башня уничтожена в момент каста».
func tower_launch_position(offset_y: float, hand: Hand) -> Vector3:
	var tower := find_tower()
	if tower != null:
		return tower.global_position + Vector3.UP * offset_y
	return hand.global_position


## Попытка списать ману с башни. true — мана списана (или Tower'а нет —
## fallback «free cast» для дев-сцен). false — есть Tower и маны не хватило,
## caller отменяет каст без cooldown'а. Контракт по `try_consume_mana` —
## не лочим тип на Tower (мана-провайдером может быть другой источник).
func try_consume_tower_mana(cost: float) -> bool:
	var tower := find_tower()
	if tower == null:
		return true
	if not tower.has_method(&"try_consume_mana"):
		return true
	return tower.try_consume_mana(cost)


## Координатор Hand вызывает этот метод после собственного _ready, передавая
## ссылку на руку. Подмодули получают ссылку через нас же.
func setup(hand: Hand) -> void:
	_hand = hand
	_fireball.setup(_hand, self)
	_firestorm.setup(_hand, self)
	_mine_scatter.setup(_hand, self)
	_frost.setup(_hand, self)
	_spark.setup(_hand, self)
	_arbalest.setup(_hand, self)
	_harpoon.setup(_hand, self)


func _process(delta: float) -> void:
	# Тикаем подмодули (cooldown'ы) независимо от категории — иначе после
	# каста и переключения на физику cooldown «замораживается».
	_fireball.tick(delta)
	_firestorm.tick(delta)
	_mine_scatter.tick(delta)
	_frost.tick(delta)
	_spark.tick(delta)
	_arbalest.tick(delta)
	_harpoon.tick(delta)
	_handle_input()


# --- Ввод ---

func _handle_input() -> void:
	# В SUPER / SQUAD_AIM / BUILD_AIM режимах весь магический ввод (equip + cast)
	# заглушаем — соответствующий координатор сам вернёт категорию на завершении.
	if _hand.is_in_aim_mode():
		return
	# Equip-биндинги — переключают Hand в MAGIC и выбирают конкретное
	# заклинание. Слушаются всегда (даже когда сейчас PHYSICAL).
	# Equip-биндинги (3/4/5) — теперь в GameplayHud через slot-mapping
	# (см. action-bar drag-and-drop). HandSpell только слушает ACTION_ACTION
	# для каста.

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
		SpellType.FROST:
			if _frost.can_trigger():
				_frost.on_press()
			elif debug_log and LogConfig.master_enabled:
				print("[Hand:Spell] мороз на кулдауне")
		SpellType.SPARK:
			if _spark.can_trigger():
				_spark.on_press()
			elif debug_log and LogConfig.master_enabled:
				print("[Hand:Spell] искра на кулдауне")
		SpellType.ARBALEST:
			if _arbalest.can_trigger():
				_arbalest.on_press()
			elif debug_log and LogConfig.master_enabled:
				print("[Hand:Spell] арбалеты не готовы (кулдаун/нет экипажа в башне)")
		SpellType.HARPOON:
			if _harpoon.can_trigger():
				_harpoon.on_press()
			elif debug_log and LogConfig.master_enabled:
				print("[Hand:Spell] гарпун на кулдауне")
