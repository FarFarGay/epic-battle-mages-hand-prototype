extends Node
## Склад ресурсов БАШНИ (room-режим). В level_rooms нет Camp/CampEconomy, поэтому
## материалы (дерево/камень/железо) держим здесь, переиспользуя standalone [CampEconomy]
## — он сам шлёт EventBus.resources_changed(type, amount), и материал-лейблы в
## GameplayHud обновляются реактивно (без Camp). Зеркало [gold_bank.gd], но для
## материалов с КАПОМ. Один на сцену — кладём в level_rooms; ищем через группу.
##
## Петля стройки: рабочий-гном добывает ресурс из источника (дерево) и СДАЁТ сюда
## (deposit) — копим до капа. Стройка/здание потом ЗАБИРАЕТ отсюда (take). Полный
## склад (is_full) → сдавать нельзя, рабочий встаёт, кольцо приказа краснеет.

const GROUP := Layers.TOWER_STORE_GROUP

## Потолок запаса на каждый материал. CampEconomy.base_cap=60 рассчитан на лагерь;
## в комнатах склад скромнее (мост ~3-24 дерева). Дизайнер крутит в инспекторе.
## С 2026-07-03 склад — НЕВИДИМЫЙ техбуфер (счётчики из HUD вырезаны): руда ждёт тут
## плавильню, дерево отсюда ferry'ится к блюпринт-станку. Игрок видит только монеты/ману/население.
@export var capacity: int = 30
## DEBUG: на старте выдать столько КАЖДОГО материала (дерево/камень/железо).
## 0 = выкл (боевой дефолт: склад стартует пустым, дебаг-сток убран 2026-07-03).
@export var debug_start_amount: int = 0

var _econ := CampEconomy.new()


func _ready() -> void:
	add_to_group(GROUP)
	_econ.base_cap = capacity
	if debug_start_amount > 0:
		_econ.base_cap = maxi(_econ.base_cap, debug_start_amount)
		for type in [
			ResourcePile.ResourceType.WOOD,
			ResourcePile.ResourceType.STONE,
			ResourcePile.ResourceType.IRON,
		]:
			_econ.add_resource(type, debug_start_amount)  # эмитит resources_changed → HUD


## Сдать на склад до капа. Возвращает СКОЛЬКО реально приняли (0 = склад полон по
## этому типу). Рабочий сверяет: принято 0 → ноша осталась, встал/ждёт.
func deposit(type: int, amount: int) -> int:
	if amount <= 0:
		return 0
	var room: int = maxi(0, _econ.cap_for(type) - _econ.get_resource(type))
	var accepted: int = mini(amount, room)
	if accepted > 0:
		_econ.add_resource(type, accepted)  # сам эмитит resources_changed → HUD
	return accepted


## Забрать со склада (стройка/здание тратит). True если хватило всего запрошенного.
func take(type: int, amount: int) -> bool:
	if amount <= 0:
		return true
	return _econ.try_spend({type: amount})


func get_amount(type: int) -> int:
	return _econ.get_resource(type)


func cap_for(type: int) -> int:
	return _econ.cap_for(type)


func is_full(type: int) -> bool:
	return _econ.is_full(type)
