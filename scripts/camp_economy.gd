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


## Гном принёс единицу ресурса. amount > 0 — обычно 1, но контракт не
## запрещает batch-кредит (магия каравана, бонусные постройки, refund).
func add_resource(type: int, amount: int) -> void:
	if amount <= 0:
		return
	var current: int = int(_resources.get(type, 0))
	_resources[type] = current + amount
	EventBus.resources_changed.emit(type, _resources[type])


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
