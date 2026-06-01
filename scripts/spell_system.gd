extends Node
## Система заклинаний башни. Регистрируется как autoload `SpellSystem`.
##
## Источник истины о том, какие заклинания разблокированы и какой у них
## уровень прокачки. Конкретные подмодули руки (HandSpellFireball и т.п.)
## читают параметры через `get_current_level_data(id)` — damage / cooldown /
## mana_cost / radius на текущем уровне.
##
## Каталог `SPELL_CATALOG` декларативный — id → Dictionary с полями:
##   - `name`, `description`, `icon_color`
##   - `unlocked_by_default: bool` (true для базовых заклинаний)
##   - `unlock_cost: Dictionary` (ResourceType → amount; обычно PAGE)
##   - `levels: Array[Dictionary]` — параметры по уровням. Индекс 0 = базовый
##     (выдаётся при unlock'е), 1+ — после апгрейдов. Каждый уровень содержит
##     gameplay-параметры конкретного заклинания (для fireball это damage,
##     cooldown, mana_cost, radius, burn_*, etc).
##   - `upgrade_costs: Array[Dictionary]` — стоимость каждого следующего
##     уровня. upgrade_costs[i] — цена перехода level i → i+1. Длина =
##     levels.size() - 1.
##
## Прокачка через PAGE — отдельный ресурс ResourcePile.ResourceType.PAGE.
## Списание/проверка идут через Camp.try_spend / Camp.can_afford — тот же
## механизм что и постройки в журнале (CAMP_BUILDING_CATALOG).
##
## Каталог пока содержит один реальный заклинание (fireball) и заглушки для
## будущих. Дизайнер дозаполняет по мере появления.

const CAMP_GROUP := &"camp"

## Каталог. Параметры levels'а конкретны для fireball — другие заклинания
## будут иметь свой набор полей (damage, radius, cooldown, mana_cost — общий
## минимум). Подмодули знают, что читать у своего id.
const SPELL_CATALOG: Dictionary = {
	&"fireball": {
		"name": "Огненный шар",
		"description": "Магическая ракета: вылетает из башни, наводится на курсор, взрывается с AOE-уроном и оставляет горящую зону.",
		"icon_color": Color(1.0, 0.45, 0.1, 1.0),
		"unlocked_by_default": true,
		"unlock_cost": {},  # доступен сразу
		# Баланс 2026-05-10 (v5): +20% damage поверх v4 (итого ×1.82 от
		# исходного). Магия должна быть эффективнее луков (DefenderGnome
		# одновременно ослаблен на симметричные −20%). Radius/cooldown/mana
		# не трогаем — только урон.
		"levels": [
			{"damage": 47.0, "radius": 3.5, "cooldown": 0.4, "mana_cost": 12.0, "burn_damage_per_tick": 18.0, "burn_radius": 2.8, "burn_duration": 2.5, "burn_tick_interval": 0.5},
			{"damage": 58.0, "radius": 3.8, "cooldown": 0.36, "mana_cost": 11.0, "burn_damage_per_tick": 24.0, "burn_radius": 3.0, "burn_duration": 2.5, "burn_tick_interval": 0.5},
			{"damage": 77.0, "radius": 4.2, "cooldown": 0.32, "mana_cost": 10.0, "burn_damage_per_tick": 29.0, "burn_radius": 3.3, "burn_duration": 3.0, "burn_tick_interval": 0.45},
			{"damage": 101.0, "radius": 4.5, "cooldown": 0.28, "mana_cost": 9.0, "burn_damage_per_tick": 37.0, "burn_radius": 3.5, "burn_duration": 3.5, "burn_tick_interval": 0.4},
		],
		"upgrade_costs": [
			{ResourcePile.ResourceType.PAGE: 3},
			{ResourcePile.ResourceType.PAGE: 6},
			{ResourcePile.ResourceType.PAGE: 12},
		],
	},
	&"firestorm": {
		"name": "Огненный шквал",
		"description": "Серия из 4 малых фаерболов. Вылетают по очереди с короткой задержкой, ложатся в небольшую область вокруг прицела — накрывают плотную группу.",
		"icon_color": Color(0.9, 0.3, 0.05, 1.0),
		"unlocked_by_default": true,
		"unlock_cost": {},
		# Баланс 2026-05-10 (v5): +20% damage поверх v4.
		"levels": [
			{"shot_count": 4, "shot_interval": 0.15, "shot_damage": 40.0, "shot_radius": 3.0, "scatter_radius": 2.8, "cooldown": 2.0, "mana_cost": 50.0,
				"burn_damage_per_tick": 11.0, "burn_radius": 2.0, "burn_duration": 2.0, "burn_tick_interval": 0.5},
			{"shot_count": 5, "shot_interval": 0.13, "shot_damage": 52.0, "shot_radius": 3.2, "scatter_radius": 3.0, "cooldown": 1.8, "mana_cost": 55.0,
				"burn_damage_per_tick": 14.0, "burn_radius": 2.2, "burn_duration": 2.0, "burn_tick_interval": 0.5},
			{"shot_count": 6, "shot_interval": 0.11, "shot_damage": 64.0, "shot_radius": 3.5, "scatter_radius": 3.2, "cooldown": 1.6, "mana_cost": 60.0,
				"burn_damage_per_tick": 18.0, "burn_radius": 2.4, "burn_duration": 2.5, "burn_tick_interval": 0.45},
		],
		"upgrade_costs": [
			{ResourcePile.ResourceType.PAGE: 6},
			{ResourcePile.ResourceType.PAGE: 12},
		],
	},
	&"super": {
		"name": "Великий удар",
		"description": "Носитель из башни вылетает в воздух над целью и разделяется на серию маленьких фаерболов. Требует полную шкалу великой силы и QTE-паттерн.",
		"icon_color": Color(1.0, 0.55, 0.15, 1.0),
		"unlocked_by_default": true,
		"unlock_cost": {},
		# Балансовые параметры супер-удара. Прокачка опциональна (пока 1 уровень).
		# Carrier-параметры (boost/homing/visual_scale) и QTE-параметры
		# (pattern_length, time_scale) живут @export'ами в hand_super.gd —
		# это motion/feel, не balance.
		"levels": [
			{"payload_count": 12, "payload_damage": 47.0, "payload_radius": 7.0, "payload_radius_aoe": 4.0, "pattern_length": 4},
		],
		"upgrade_costs": [],
	},
	&"meteor": {
		"name": "Метеоритный дождь",
		"description": "(заглушка) Серия фаерболов из неба по большой области.",
		"icon_color": Color(0.85, 0.2, 0.15, 1.0),
		"unlocked_by_default": false,
		"unlock_cost": {ResourcePile.ResourceType.PAGE: 15},
		"levels": [
			{"damage": 50.0, "radius": 8.0, "count": 6, "mana_cost": 70.0},
		],
		"upgrade_costs": [],
	},
	&"spark": {
		"name": "Искра",
		"description": "Лёгкое заклинание-зачистка. Жёлтая искра вылетает из башни, ищет ближайшего врага в области под курсором и хаотично-зигзагом летит к нему. Один враг — один заряд. Стоит копейки маны, почти без кулдауна.",
		"icon_color": Color(1.0, 0.95, 0.3, 1.0),
		"unlocked_by_default": true,
		"unlock_cost": {},
		# Параметры подобраны под Skeleton.hp=30: damage=35 → one-shot обычного
		# скелета, не уничтожает archer/giant за раз (их hp выше). mana=3 при
		# tower-regen ~5/с → можно прожимать раз в секунду без оглядки на
		# манабар. cooldown=0.15 → визуально читается как «непрерывный поток
		# искр» когда зажат cast-бинд (не одна искра в кадр).
		# impact_radius — радиус sphere-scan в точке падения: бьёт ОДНОГО
		# ближайшего к точке. Маленький (1.5м) — нужна точность; промах —
		# просто искра в землю.
		"levels": [
			{"damage": 35.0, "cooldown": 0.15, "mana_cost": 3.0, "impact_radius": 1.5},
		],
		"upgrade_costs": [],
	},
	&"frost": {
		"name": "Мороз",
		"description": "Ледяная ракета: вылетает из башни, наводится на курсор. Прямое попадание полностью замораживает врагов в зоне взрыва. На земле остаётся пятно льда, которое замедляет всех вошедших.",
		"icon_color": Color(0.45, 0.8, 1.0, 1.0),
		"unlocked_by_default": true,
		"unlock_cost": {},
		# Frost — control-spell, не damage. damage=0; rebalance делается через
		# hit_freeze_duration / patch_radius / patch_duration / patch_slow_factor.
		"levels": [
			{"damage": 0.0, "radius": 3.5, "cooldown": 0.6, "mana_cost": 18.0,
				"hit_freeze_duration": 2.0, "patch_radius": 5.0, "patch_duration": 4.0, "patch_slow_factor": 0.4},
			{"damage": 0.0, "radius": 3.8, "cooldown": 0.55, "mana_cost": 17.0,
				"hit_freeze_duration": 2.4, "patch_radius": 5.5, "patch_duration": 4.5, "patch_slow_factor": 0.35},
			{"damage": 0.0, "radius": 4.2, "cooldown": 0.5, "mana_cost": 16.0,
				"hit_freeze_duration": 3.0, "patch_radius": 6.0, "patch_duration": 5.0, "patch_slow_factor": 0.3},
		],
		"upgrade_costs": [
			{ResourcePile.ResourceType.PAGE: 4},
			{ResourcePile.ResourceType.PAGE: 8},
		],
	},
	&"mine_scatter": {
		"name": "Минное рассеивание",
		"description": "Башня запускает в небо снаряд, тот рассыпает над целью N мин. Мины приземляются, ждут жертв — рвут любого в радиусе (включая своих). Стратегическое оружие зоны контроля.",
		"icon_color": Color(0.8, 0.3, 0.2, 1.0),
		"unlocked_by_default": true,
		"unlock_cost": {},
		"levels": [
			{"mine_count": 11, "scatter_radius": 5.0, "mine_damage": 30.0, "mine_aoe_radius": 1.8, "cooldown": 4.0, "mana_cost": 40.0},
			{"mine_count": 12, "scatter_radius": 5.5, "mine_damage": 36.0, "mine_aoe_radius": 2.0, "cooldown": 3.6, "mana_cost": 42.0},
			{"mine_count": 13, "scatter_radius": 6.0, "mine_damage": 44.0, "mine_aoe_radius": 2.2, "cooldown": 3.2, "mana_cost": 44.0},
		],
		"upgrade_costs": [
			{ResourcePile.ResourceType.PAGE: 6},
			{ResourcePile.ResourceType.PAGE: 12},
		],
	},
}

## id → true: разблокированные заклинания. Инициализируется в _ready по
## флагу unlocked_by_default; растёт через try_unlock.
var _unlocked: Dictionary = {}
## id → int: текущий уровень. 0 = базовый (выдаётся при unlock'е). Растёт
## через try_upgrade. Не присутствует в _levels пока заклинание locked.
var _levels: Dictionary = {}


func _ready() -> void:
	for id in SPELL_CATALOG.keys():
		var data: Dictionary = SPELL_CATALOG[id]
		if data.get("unlocked_by_default", false):
			_unlocked[id] = true
			_levels[id] = 0


# --- Публичный API: query ---

func is_unlocked(id: StringName) -> bool:
	return _unlocked.get(id, false)


## Текущий уровень заклинания (0 = базовый). -1 если заклинание ещё не
## разблокировано — пользуй is_unlocked для phaseчёткой проверки.
func get_level(id: StringName) -> int:
	if not is_unlocked(id):
		return -1
	return int(_levels.get(id, 0))


## Полная Dictionary'я каталога для id (name, description, levels, ...).
## Empty Dictionary если id неизвестен.
func get_spell_data(id: StringName) -> Dictionary:
	return SPELL_CATALOG.get(id, {})


## Параметры текущего уровня. Empty если не unlocked. Подмодуль руки читает
## damage/cooldown/etc отсюда — single source of truth.
func get_current_level_data(id: StringName) -> Dictionary:
	if not is_unlocked(id):
		return {}
	var data: Dictionary = SPELL_CATALOG.get(id, {})
	var levels: Array = data.get("levels", [])
	var lvl: int = clampi(get_level(id), 0, levels.size() - 1)
	if lvl < 0:
		return {}
	return levels[lvl]


## True если у заклинания есть ещё уровни прокачки (текущий < последний).
func can_upgrade_further(id: StringName) -> bool:
	if not is_unlocked(id):
		return false
	var data: Dictionary = SPELL_CATALOG.get(id, {})
	var levels: Array = data.get("levels", [])
	return get_level(id) < levels.size() - 1


## Стоимость следующего апгрейда (level+1) или empty если апгрейдов больше нет.
func get_next_upgrade_cost(id: StringName) -> Dictionary:
	if not can_upgrade_further(id):
		return {}
	var data: Dictionary = SPELL_CATALOG.get(id, {})
	var costs: Array = data.get("upgrade_costs", [])
	var next_idx: int = get_level(id)
	if next_idx >= costs.size():
		return {}
	return costs[next_idx]


# --- Публичный API: mutation ---

## Пытается разблокировать заклинание. Возвращает true если получилось.
## Условия: id известен, ещё не разблокирован, Camp есть и в нём хватает
## ресурсов (списываем атомарно через try_spend).
func try_unlock(id: StringName) -> bool:
	if is_unlocked(id):
		return false
	if not SPELL_CATALOG.has(id):
		push_warning("SpellSystem.try_unlock: неизвестный id %s" % id)
		return false
	var camp: Node = get_tree().get_first_node_in_group(CAMP_GROUP)
	if camp == null:
		return false
	var cost: Dictionary = SPELL_CATALOG[id].get("unlock_cost", {})
	if not cost.is_empty() and not camp.economy.try_spend(cost):
		return false
	_unlocked[id] = true
	_levels[id] = 0
	if LogConfig.master_enabled:
		print("[SpellSystem] разблокировано: %s" % id)
	EventBus.spell_unlocked.emit(id)
	return true


## Пытается прокачать заклинание на следующий уровень. Возвращает true если
## получилось. Списывает upgrade_costs[level] через Camp.try_spend.
func try_upgrade(id: StringName) -> bool:
	if not can_upgrade_further(id):
		return false
	var camp: Node = get_tree().get_first_node_in_group(CAMP_GROUP)
	if camp == null:
		return false
	var cost: Dictionary = get_next_upgrade_cost(id)
	if not cost.is_empty() and not camp.economy.try_spend(cost):
		return false
	_levels[id] = int(_levels.get(id, 0)) + 1
	if LogConfig.master_enabled:
		print("[SpellSystem] %s прокачано до уровня %d" % [id, _levels[id]])
	EventBus.spell_upgraded.emit(id, _levels[id])
	return true
