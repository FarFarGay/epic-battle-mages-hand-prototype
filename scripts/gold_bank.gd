extends Node
## Казна монет для room-режима (монетная экономика, 2026-06-25). Три номинала:
## BRONZE / SILVER / GOLD (см. [ResourcePile.ResourceType]). Держим через [CampEconomy]
## (standalone), который шлёт EventBus.resources_changed(type, amount) — HUD-счётчики
## обновляются реактивно. Постройки стоят СОСТАВНУЮ цену (Dictionary{type:int}),
## проверяется can_afford / списывается spend_cost при установке. Один на сцену.
##
## Старые add_gold/try_spend(int)/get_gold (GOLD) сохранены для trade_ui (найм за золото).

const GROUP := &"gold_bank"
const RT := ResourcePile.ResourceType

## Стартовый капитал (DEBUG — щедро, чтобы тестить стройку до готовой добычи монет).
## Крутить здесь; добыча/чеканка появятся следующими шагами.
@export var start_bronze: int = 500
@export var start_silver: int = 50
@export var start_gold: int = 100

var _econ := CampEconomy.new()


func _ready() -> void:
	add_to_group(GROUP)
	# Deferred: HUD-счётчики подписываются на resources_changed в своём _ready — выдаём
	# стартовые монеты следующим кадром, чтобы em'ит не ушёл в пустоту.
	call_deferred(&"_grant_start")


func _grant_start() -> void:
	if start_bronze > 0:
		_econ.add_resource(RT.BRONZE, start_bronze)
	if start_silver > 0:
		_econ.add_resource(RT.SILVER, start_silver)
	if start_gold > 0:
		_econ.add_resource(RT.GOLD, start_gold)


# --- Составная цена (постройки) ---

## Хватает ли на составную цену cost = {ResourceType: int}.
func can_afford(cost: Dictionary) -> bool:
	return _econ.can_afford(cost)


## Списать составную цену (атомарно — CampEconomy не спишет, если не хватает). true = оплачено.
func spend_cost(cost: Dictionary) -> bool:
	return _econ.try_spend(cost)


# --- Произвольный номинал ---

func add_coin(type: int, amount: int) -> void:
	if amount > 0:
		_econ.add_resource(type, amount)


func get_coin(type: int) -> int:
	return _econ.get_resource(type)


# --- GOLD-совместимость (trade_ui: найм за золото) ---

func add_gold(amount: int) -> void:
	if amount <= 0:
		return
	_econ.add_resource(RT.GOLD, amount)


func try_spend(amount: int) -> bool:
	if amount <= 0:
		return true
	return _econ.try_spend({RT.GOLD: amount})


func get_gold() -> int:
	return _econ.get_resource(RT.GOLD)
# монетная экономика — см. [[project_ebm_coin_economy]]
