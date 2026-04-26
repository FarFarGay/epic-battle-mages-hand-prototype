class_name ResourcePile
extends Node3D
## Куча ресурсов вокруг развёрнутого лагеря — гномы берут оттуда по 1 единице.
## Когда units доходит до 0 — куча queue_free.
##
## Регистрируется в группе ResourcePile.GROUP, чтобы гномы могли её находить
## через get_tree().get_nodes_in_group без жёсткой связи.

const GROUP := &"resource_pile"

@export var units: int = 5
@export var pile_color: Color = Color(0.4, 0.75, 0.3)
@export var pile_size: Vector3 = Vector3(0.6, 0.6, 0.6)

@onready var _mesh: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	add_to_group(GROUP)
	_apply_visual()


func _apply_visual() -> void:
	var box := BoxMesh.new()
	box.size = pile_size
	_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = pile_color
	_mesh.material_override = mat


## Гном забирает 1 единицу. Возвращает true, если получилось.
func take_one() -> bool:
	if units <= 0:
		return false
	units -= 1
	if units == 0:
		queue_free()
	return true
