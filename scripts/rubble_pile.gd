class_name RubblePile
extends Blocker
## Завал в периметре долины (акт II, §5.27.3): закрывает проход к комнате
## вылазки до своей фазы акта. Вся физика — от [Blocker] (слой CAMP|PALISADE,
## hand_immune / slam_damage_immune / navmesh_source): башня и скелеты
## упираются, рука не уносит, навмеш выгрызается.
##
## [open] — обвал: взрыв каменных обломков (единый язык смерти зданий,
## [ShatterEffect.building_explosion]) и проход свободен. Зовётся фазой
## чертежа Врат (§5.27.1 п.3), когда открываются проходы к вылазкам.

const RUBBLE_GROUP := &"rubble_pile"

## Цвет обломков при обвале — серый камень, в тон greybox-материалу кучи.
@export var stone_color: Color = Color(0.52, 0.51, 0.55)

var _opened: bool = false


func _ready() -> void:
	super()
	add_to_group(RUBBLE_GROUP)


## Разобрать завал: обвал-FX + освобождение прохода. Идемпотентно.
func open() -> void:
	if _opened:
		return
	_opened = true
	ShatterEffect.building_explosion(get_tree().current_scene,
		global_position + Vector3.UP * 1.0, stone_color, 2.4, 14)
	queue_free()
