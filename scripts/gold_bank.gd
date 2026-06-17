extends Node
## Банк золота для room-режима. В level_rooms нет Camp/CampEconomy, поэтому держим
## ЗОЛОТО здесь, переиспользуя класс [CampEconomy] (standalone-инстанс) — тот сам
## шлёт EventBus.resources_changed(GOLD, amount), и лейбл золота в GameplayHud
## обновляется реактивно (без Camp). Найти узел через группу GROUP.
##
## Награда за гиганта кладёт золото сюда (add_gold); покупка гномов будет тратить
## (try_spend). Один на сцену — кладём в level_rooms.

const GROUP := &"gold_bank"

var _econ := CampEconomy.new()


func _ready() -> void:
	add_to_group(GROUP)


func add_gold(amount: int) -> void:
	if amount <= 0:
		return
	_econ.add_resource(ResourcePile.ResourceType.GOLD, amount)


func try_spend(amount: int) -> bool:
	if amount <= 0:
		return true
	return _econ.try_spend({ResourcePile.ResourceType.GOLD: amount})


func get_gold() -> int:
	return _econ.get_resource(ResourcePile.ResourceType.GOLD)
