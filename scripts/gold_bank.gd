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

## Стартовый капитал (DEBUG) — задаётся по номиналам, суммируется в общий кошелёк.
@export var start_bronze: int = 0
@export var start_silver: int = 0
@export var start_gold: int = 100

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
	return true


# --- Произвольный номинал ---

## Зачислить amount монет номинала type (по курсу в общий кошелёк).
func add_coin(type: int, amount: int) -> void:
	if amount > 0:
		_value += amount * _unit(type)


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
	return true


func get_gold() -> int:
	return _value
