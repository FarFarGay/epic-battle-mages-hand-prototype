class_name Item
extends RigidBody3D
## Подбираемый предмет. Цвет настраивается на инстансе через @export.
## Масса задаётся встроенным свойством RigidBody3D.mass.

@export var item_color: Color = Color(0.7, 0.7, 0.7)


func _ready() -> void:
	var mesh_node := $MeshInstance3D as MeshInstance3D
	if mesh_node:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = item_color
		mesh_node.material_override = mat
