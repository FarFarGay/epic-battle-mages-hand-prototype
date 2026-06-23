class_name OilDeposit
extends Node3D
## Месторождение — точка на земле (масляный выход), где можно поставить БУР: он
## добывает отсюда. Маркер; дизайнер расставляет в комнатах 6/8/9. group
## oil_deposit. richness — множитель добычи (богатое/слабое). occupied — занято ли
## буром (бур ставит флаг при привязке, чтобы на одну залежь не лез второй).

const GROUP := &"oil_deposit"

## Множитель добычи бура, поставленного на эту залежь (богатая залежь = больше).
@export var richness: float = 1.0

var occupied: bool = false


func _ready() -> void:
	add_to_group(GROUP)
