class_name GoldBank
extends Node
## Казна room-режима (монетная экономика). **Одна валюта внутри** — целое `_value` в
## БРОНЗА-ЭКВИВАЛЕНТЕ; три номинала (🥉/🥈/🥇) — лишь ОТОБРАЖЕНИЕ (одометр). Размена как
## проблемы не существует: покупка вычитает из общего числа, дисплей сам пересобирает монеты.
## Курсы: 1🥈 = 10🥉, 1🥇 = 25🥈 → 🥇 = 250🥉. Бронза с добычи сама «копится» в серебро/золото
## (визуально), ручная чеканка не нужна. Один на сцену. См. [[project_ebm_coin_economy]].
##
## Публичный API сохранён: add_coin/get_coin (номинал↔значение), can_afford/spend_cost
## (составная цена-словарь), add_gold/try_spend/get_gold (trade_ui — «золото» = весь кошелёк).

const GROUP := &"gold_bank"
const RT := ResourcePile.ResourceType

## Курсы номиналов (сколько мелких в одной крупной).
const BRONZE_PER_SILVER := 10
const SILVER_PER_GOLD := 25
const BRONZE_PER_GOLD := BRONZE_PER_SILVER * SILVER_PER_GOLD  # 250

## ЕДИНАЯ лесенка номиналов (бронза < серебро < золото). Раньше порядок тиров был
## продублирован в pad_building._upgraded_coin — теперь один источник истины здесь.
const TIER_ORDER: Array = [
	ResourcePile.ResourceType.BRONZE,
	ResourcePile.ResourceType.SILVER,
	ResourcePile.ResourceType.GOLD,
]


## Номинал на тир выше (чеканный двор-сапорт и т.п.). Золото — потолок.
static func next_tier(coin_type: int) -> int:
	var i: int = TIER_ORDER.find(coin_type)
	if i < 0 or i >= TIER_ORDER.size() - 1:
		return coin_type
	return TIER_ORDER[i + 1]

## Стартовый капитал (DEBUG) — задаётся по номиналам, суммируется в общий кошелёк.
## Дефолт 0 (обнулено 2026-07-07): полная казна с порога обходила экономическую
## арку туториала (Room4 стол опустошает → Room5 рубка = заработок на мостки).
## Для тестов города крути в инспекторе.
@export var start_bronze: int = 0
@export var start_silver: int = 0
@export var start_gold: int = 0

var _value: int = 0  # всего денег в бронза-эквиваленте


func _ready() -> void:
	add_to_group(GROUP)
	_value = start_bronze + start_silver * BRONZE_PER_SILVER + start_gold * BRONZE_PER_GOLD


## Ценность номинала в бронза-эквиваленте.
func _unit(type: int) -> int:
	match type:
		RT.SILVER:
			return BRONZE_PER_SILVER
		RT.GOLD:
			return BRONZE_PER_GOLD
		_:
			return 1  # бронза (и всё прочее)


## Стоимость составной цены в бронза-эквиваленте.
func _cost_value(cost: Dictionary) -> int:
	var v: int = 0
	for t in cost:
		v += int(cost[t]) * _unit(int(t))
	return v


# --- Составная цена (постройки) ---

## Хватает ли на составную цену cost = {ResourceType: int}.
func can_afford(cost: Dictionary) -> bool:
	return _value >= _cost_value(cost)


## Списать составную цену (атомарно). true = оплачено.
func spend_cost(cost: Dictionary) -> bool:
	var c: int = _cost_value(cost)
	if _value < c:
		return false
	_value -= c
	if c > 0:
		EventBus.coins_spent.emit(c)
	return true


# --- Произвольный номинал ---

## Зачислить amount монет номинала type (по курсу в общий кошелёк).
func add_coin(type: int, amount: int) -> void:
	if amount > 0:
		_value += amount * _unit(type)


## Переплавка единицы материала в монету: [coin_type, amount]. ЕДИНАЯ точка конверсии
## (2026-07-03) — зовёт разгрузочная платформа, когда башня паркуется с трюмом.
## Тир интуитивен: дерево→бронза×N, камень→серебро, железо→золото (было камень→золото —
## поправлено); редкие серебряная/золотая руда — свой номинал.
const SMELT_BRONZE_PER_WOOD := 5
func smelt_yield(material: int) -> Array:
	match material:
		ResourcePile.ResourceType.IRON, ResourcePile.ResourceType.GOLD:
			return [ResourcePile.ResourceType.GOLD, 1]
		ResourcePile.ResourceType.STONE, ResourcePile.ResourceType.SILVER:
			return [ResourcePile.ResourceType.SILVER, 1]
		_:
			return [ResourcePile.ResourceType.BRONZE, SMELT_BRONZE_PER_WOOD]


## Сколько монет номинала ПОКАЗАТЬ (одометр): золото = value/250, остаток → серебро, остаток → бронза.
func get_coin(type: int) -> int:
	match type:
		RT.GOLD:
			return _value / BRONZE_PER_GOLD
		RT.SILVER:
			return (_value % BRONZE_PER_GOLD) / BRONZE_PER_SILVER
		_:
			return _value % BRONZE_PER_SILVER  # бронза


# --- Совместимость trade_ui (найм): «золото» = весь кошелёк (единая валюта) ---

func add_gold(amount: int) -> void:
	if amount > 0:
		_value += amount


func try_spend(amount: int) -> bool:
	if amount <= 0:
		return true
	if _value < amount:
		return false
	_value -= amount
	EventBus.coins_spent.emit(amount)
	return true


func get_gold() -> int:
	return _value
