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
	_hand = get_parent() as Hand
	if not _hand:
		push_error("HandSpell: родитель не Hand")
	# TODO: загрузить реестр заклинаний (имя → cost / cooldown / scene / эффект).


# TODO: _process — обработка ввода для заклинаний (ПКМ / клавиши).
# TODO: cast(spell_name: String) — проверки cooldown/маны → spell_cast.emit + эффект.
