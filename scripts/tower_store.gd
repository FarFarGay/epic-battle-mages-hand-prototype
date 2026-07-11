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
## Для теста петли разгрузки платформы ставь 30 в инспекторе (юзер 2026-07-03).
## Дефолт 0 — иначе мостки Room5 строятся без рубки, туториал-петля обходится
## (обнулено 2026-07-07 при переводе моста на стройку за дерево).
@export var debug_start_amount: int = 0

var _econ := CampEconomy.new()
## Суммарная прибавка к капу от срезов башни (верфь: «Грузовой ярус»). set_cap_bonus
## в CampEconomy абсолютный — копим здесь и переустанавливаем целиком.
var _cap_bonus: int = 0


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


## Поднять кап трюма (срез «Грузовой ярус» с верфи, TowerUpgrades.install). Кап общий
## на каждый материал, как base_cap. Пингуем HUD через resources_changed — «📦 трюм»
## пересчитает ⚠-порог под новый потолок.
func add_cap_bonus(amount: int) -> void:
	if amount <= 0:
		return
	_cap_bonus += amount
	_econ.set_cap_bonus(_cap_bonus)
	EventBus.resources_changed.emit(ResourcePile.ResourceType.WOOD,
		_econ.get_resource(ResourcePile.ResourceType.WOOD))


## Сдать на склад. ПИВОТ 2026-07-11 «ресурсы прибывают сами»: ритуала сдачи больше нет —
## всё, КРОМЕ ДЕРЕВА, конвертится в монеты прямо в момент прибытия (единая точка
## GoldBank.smelt_yield — та же математика, что была у разгрузочной платформы, только
## без парковки; платформа убрана из колоды). Попап «+N🥉» у башни — доход виден.
## Дерево — стройматериал (мостки/ferry), остаётся буфером с капом.
## Возвращает СКОЛЬКО реально приняли (монетная сдача принимает всё; дерево: 0 = склад
## полон, рабочий встал/ждёт).
func deposit(type: int, amount: int) -> int:
	if amount <= 0:
		return 0
	if type != ResourcePile.ResourceType.WOOD:
		var bank := get_tree().get_first_node_in_group(GoldBank.GROUP) as GoldBank
		if bank != null:
			var pair: Array = bank.smelt_yield(type)
			bank.add_coin(int(pair[0]), int(pair[1]) * amount)
			var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
			if tower != null and is_instance_valid(tower):
				# Попап в бронза-эквиваленте — единый формат «+N🥉» (см. soldier_gnome).
				EventBus.coins_gained_at.emit(
					int(pair[1]) * amount * bank._unit(int(pair[0])), tower.global_position)
			return amount
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
