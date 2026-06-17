extends Node
## Реестр «добрых дел» игрока для поселения гномов. Дело = {id, label, value}, где
## value — «вес доброй воли» (скидка в торге). Источник сейчас один: убийство
## Скелета Гиганта (ловим EventBus.enemy_destroyed + группа skeleton_giant). Дела
## ТРАТЯТСЯ при покупке (consume). Узел в сцене, ищется через группу GROUP.

const GROUP := &"deeds_log"
const GIANT_GROUP := &"skeleton_giant"

signal deeds_changed()

## Сид-дело для отладки торга без необходимости каждый раз убивать гиганта.
@export var debug_seed_giant_deed: bool = true

var _deeds: Array = []  # Array[Dictionary]: {id: StringName, label: String, value: int}
var _counter: int = 0


func _ready() -> void:
	add_to_group(GROUP)
	EventBus.enemy_destroyed.connect(_on_enemy_destroyed)
	if debug_seed_giant_deed:
		add_deed("Убил Скелета Гиганта", 150)


func _on_enemy_destroyed(enemy: Node3D) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	if enemy.is_in_group(GIANT_GROUP):
		add_deed("Убил Скелета Гиганта", 150)


func add_deed(label: String, value: int) -> void:
	_counter += 1
	_deeds.append({"id": StringName("deed_%d" % _counter), "label": label, "value": value})
	deeds_changed.emit()


func get_deeds() -> Array:
	return _deeds


## Удаляет дела по id (потрачены в покупке).
func consume(ids: Array) -> void:
	if ids.is_empty():
		return
	_deeds = _deeds.filter(func(d: Dictionary) -> bool: return not (d["id"] in ids))
	deeds_changed.emit()
