class_name CampEconomy
extends RefCounted
## Ресурсная экономика лагеря — выделена из Camp как самостоятельный slice.
## Хранит пул накопленных ресурсов и предоставляет атомарную трату/проверку.
## Один инстанс на Camp (создаётся в Camp._init/_ready). Сигнал об изменении
## идёт через EventBus.resources_changed — слушатели не знают о CampEconomy.
##
## ResourceType.* — int (ResourcePile.ResourceType). Экономика хранит ключи
## как int, а не как enum-значение, чтобы Dictionary естественно покрывал
## «тип ещё не встречался — нет ключа».

## Пул ресурсов: Dictionary[int, int] (тип → количество).
## Приватный: внешний доступ через get_resource / can_afford.
var _resources: Dictionary = {}

## Потолок запаса на КАЖДЫЙ материал (дерево/камень/железо/еда). Золото — валюта
## победы, НЕ ограничивается (см. _is_capped). Склады поднимают через _cap_bonus.
## base_cap намеренно невысокий: добытое сверх упирается в потолок → стимул строить
## склады (фундамент спины «экономика снаружи»). Тюнится.
var base_cap: int = 60
## Прибавка к потолку от складов. Camp пересчитывает в _on_grid_buildings_changed
## (count_built(WAREHOUSE) × warehouse_cap_bonus) и зовёт set_cap_bonus.
var _cap_bonus: int = 0


## GOLD не капится (валюта победы — потолок заблокировал бы выигрыш). Прочие
## материалы — да.
func _is_capped(type: int) -> bool:
	return type != ResourcePile.ResourceType.GOLD


## Текущий потолок для типа. Для GOLD — практически бесконечность.
func cap_for(type: int) -> int:
	if not _is_capped(type):
		return 1 << 30
	return base_cap + _cap_bonus


## True если материал уже под потолок (HUD красит янтарным — «склад полон»).
func is_full(type: int) -> bool:
	return _is_capped(type) and get_resource(type) >= cap_for(type)


## Прибавка к потолку от складов. Camp зовёт при изменении набора зданий. HUD
## перерисовывает X/cap по EventBus.camp_buildings_changed (тот же тик).
func set_cap_bonus(bonus: int) -> void:
	_cap_bonus = maxi(bonus, 0)


## Гном принёс единицу ресурса. amount > 0 — обычно 1, но контракт не
## запрещает batch-кредит (магия каравана, бонусные постройки, refund).
## Клампится потолком cap_for(type): излишек НЕ копится (план сбора уводит гномов
## с забитого типа — см. Camp._effective_collection_weight, так что потерь почти нет).
func add_resource(type: int, amount: int) -> void:
	if amount <= 0:
		return
	var current: int = int(_resources.get(type, 0))
	var capped: int = mini(current + amount, cap_for(type))
	if capped == current:
		return  # уже под потолок — излишек теряется, ничего не меняем
	_resources[type] = capped
	EventBus.resources_changed.emit(type, capped)


func get_resource(type: int) -> int:
	return int(_resources.get(type, 0))


## Атомарная трата нескольких ресурсов одновременно. cost — Dictionary[int, int]
## (тип → стоимость). Либо все ресурсы есть и списываются разом (с emit'ом
## по каждому типу), либо ничего не меняется. Возвращает true на успех.
##
## Атомарность важна: если первая трата успела пройти, а на второй не хватило —
## игрок остался без первого ресурса, не получив постройки. Вместо try-rollback
## делаем сначала проверку всего, потом списание.
func try_spend(cost: Dictionary) -> bool:
	if not can_afford(cost):
		return false
	for type in cost:
		var amount: int = int(cost[type])
		if amount <= 0:
			continue
		_resources[type] = int(_resources.get(type, 0)) - amount
		EventBus.resources_changed.emit(type, _resources[type])
	return true


func can_afford(cost: Dictionary) -> bool:
	for type in cost:
		if int(_resources.get(type, 0)) < int(cost[type]):
			return false
	return true
