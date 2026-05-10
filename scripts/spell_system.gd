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
		# Баланс 2026-05-10 (v3): ещё +15% damage поверх v2 (итого ×1.38 от
		# исходного). Radius/cooldown/mana не трогаем — только урон.
		"levels": [
			{"damage": 35.0, "radius": 3.5, "cooldown": 0.4, "mana_cost": 12.0, "burn_damage_per_tick": 14.0, "burn_radius": 2.8, "burn_duration": 2.5},
			{"damage": 44.0, "radius": 3.8, "cooldown": 0.36, "mana_cost": 11.0, "burn_damage_per_tick": 18.0, "burn_radius": 3.0, "burn_duration": 2.5},
			{"damage": 58.0, "radius": 4.2, "cooldown": 0.32, "mana_cost": 10.0, "burn_damage_per_tick": 22.0, "burn_radius": 3.3, "burn_duration": 3.0},
			{"damage": 76.0, "radius": 4.5, "cooldown": 0.28, "mana_cost": 9.0, "burn_damage_per_tick": 28.0, "burn_radius": 3.5, "burn_duration": 3.5},
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
		# Баланс 2026-05-10 (v3): shot_damage ещё +15% к v2 (итого 26→30,
		# 34→39, 42→48). shot_count 4/5/6 без изменений.
		"levels": [
			{"shot_count": 4, "shot_interval": 0.15, "shot_damage": 30.0, "shot_radius": 3.0, "scatter_radius": 2.8, "cooldown": 2.0, "mana_cost": 50.0},
			{"shot_count": 5, "shot_interval": 0.13, "shot_damage": 39.0, "shot_radius": 3.2, "scatter_radius": 3.0, "cooldown": 1.8, "mana_cost": 55.0},
			{"shot_count": 6, "shot_interval": 0.11, "shot_damage": 48.0, "shot_radius": 3.5, "scatter_radius": 3.2, "cooldown": 1.6, "mana_cost": 60.0},
		],
		"upgrade_costs": [
			{ResourcePile.ResourceType.PAGE: 6},
			{ResourcePile.ResourceType.PAGE: 12},
		],
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
	if not cost.is_empty() and not camp.try_spend(cost):
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
	if not cost.is_empty() and not camp.try_spend(cost):
		return false
	_levels[id] = int(_levels.get(id, 0)) + 1
	if LogConfig.master_enabled:
		print("[SpellSystem] %s прокачано до уровня %d" % [id, _levels[id]])
	EventBus.spell_upgraded.emit(id, _levels[id])
	return true
