class_name HandSpell
extends Node
## Категория "Заклинания" руки.
##
## ЗАГЛУШКА. Логика будет добавлена в следующих итерациях.
## Привязка ввода (план): ПКМ или клавиши 1..N — конкретика TBD.
## Будет зависеть только от родителя (Hand) — позиция и скорость берутся через него.
##
## Внешний контракт (черновик):
##   signal spell_cast(spell_name: String, position: Vector3)

signal spell_cast(spell_name: String, position: Vector3)

@export var debug_log: bool = true

var _hand: Hand


func _ready() -> void:
	# Заглушка — без активной логики не тикаем.
	set_process(false)
	set_physics_process(false)
	# TODO: загрузить реестр заклинаний (имя → cost / cooldown / scene / эффект).


## Координатор Hand вызывает этот метод после собственного _ready, передавая
## ссылку на руку. До setup активной логики нет (ловить ввод нечем).
func setup(hand: Hand) -> void:
	_hand = hand


# TODO: _process — обработка ввода для заклинаний (ПКМ / клавиши).
# TODO: cast(spell_name: String) — проверки cooldown/маны → spell_cast.emit + эффект.
#
# Архитектурно (унификация рукой и магии — дизайнерское решение 2026-05-03):
# AOE-заклинания используют ту же универсальную маску, что и Slam
# (`Layers.MASK_HAND_SLAM` — враги + гномы + башня + палатки + items), и
# обязаны фильтровать цели через `Layers.is_hand_immune(target)` ПОСЛЕ
# broad-phase-выборки. Single-target snaplinks (если будут) — через
# `Layers.MASK_HAND_TARGETS` с тем же иммунити-чеком. Это сохраняет
# симметрию: одна группа `hand_immune` исключает цель и от physical-
# действий руки, и от заклинаний.
