class_name Item
extends RigidBody3D
## Подбираемый предмет. Цвет, размер и масса настраиваются на инстансе.
## Размер применяется к мешу и форме коллизии в _ready
## (создаются уникальные ресурсы — общие из item.tscn остаются только для превью в редакторе).
## Масса задаётся встроенным свойством RigidBody3D.mass.
##
## Публичный API:
## - set_highlighted(value: bool) — включает/выключает emission на материале
##   (рука дёргает этот метод, когда предмет становится текущим кандидатом захвата).

@export var item_color: Color = Color(0.7, 0.7, 0.7)
@export var item_size: Vector3 = Vector3(1, 1, 1)
@export var highlight_color: Color = Color(1.0, 0.95, 0.4, 1.0)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6

var _material: StandardMaterial3D


func _ready() -> void:
	_apply_visual()
	_apply_shape()


func _apply_visual() -> void:
	var mesh_node := $MeshInstance3D as MeshInstance3D
	if not mesh_node:
		return
	var box_mesh := BoxMesh.new()
	box_mesh.size = item_size
	mesh_node.mesh = box_mesh
	_material = StandardMaterial3D.new()
	_material.albedo_color = item_color
	mesh_node.material_override = _material


func _apply_shape() -> void:
	var col_node := $CollisionShape3D as CollisionShape3D
	if not col_node:
		return
	var box_shape := BoxShape3D.new()
	box_shape.size = item_size
	col_node.shape = box_shape


func set_highlighted(value: bool) -> void:
	if not _material:
		return
	if value:
		_material.emission_enabled = true
		_material.emission = highlight_color
		_material.emission_energy_multiplier = highlight_intensity
	else:
		_material.emission_enabled = false
