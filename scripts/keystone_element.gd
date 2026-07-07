class_name KeystoneElement
extends RelayItem
## Ключ-плита — элемент механизма Врат из комнаты А «Разлом» (§5.27.2):
## лежит за широким разломом, добыча = экзамен РУКИ (мосток поперёк барьера,
## башня переезжает, рука забирает и несёт в гнездо Врат под давлением охраны).
## Grab / сокет-снап / вспышка тока — целиком от [RelayItem]; здесь только
## визуал: каменная плита с рунной полосой (семья элементов, но не кристалл).


## Плита + рунная полоса. Один материал — highlight/ток красят разом.
func _build_visual() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.5, 0.48, 0.55)
	_material.roughness = 0.7
	_material.emission_enabled = true
	_material.emission = crystal_color
	_material.emission_energy_multiplier = 1.0
	var slab := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.2, 0.3, 0.8)
	slab.mesh = box
	slab.material_override = _material
	add_child(slab)
	var stripe := MeshInstance3D.new()
	var sbox := BoxMesh.new()
	sbox.size = Vector3(1.0, 0.08, 0.22)
	stripe.mesh = sbox
	stripe.position = Vector3(0, 0.19, 0)
	stripe.material_override = _material
	add_child(stripe)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.2, 0.3, 0.8)
	col.shape = shape
	add_child(col)
