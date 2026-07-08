class_name StarCrystal
extends ArtifactElement
## Звёздный кристалл — КЛАД (сюжет «Верхний Предел»): заперт в глубине заставы
## за электро-дверью, добыча = экзамен искры+цепи (диод → ток → рычаг → дверь
## съезжает). Опциональная вылазка риск-ревард: доставка [ArtifactElement] в
## ДОК ГОРОДА («unload») → крупная сумма в казну — ускоряет плату за Врата.

## Выручка за клад (бронза-эквивалент единой казны).
@export var treasure_bronze: int = 300


func _ready() -> void:
	deliver_role = &"unload"
	super()


## Ядро-сфера + 6 шипов крестом. Один материал — highlight красит разом.
func _build_visual() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.85, 0.9, 1.0)
	_material.metallic = 0.3
	_material.roughness = 0.2
	_material.emission_enabled = true
	_material.emission = Color(0.7, 0.8, 1.0)
	_material.emission_energy_multiplier = 2.2
	var core := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.32
	sph.height = 0.64
	sph.radial_segments = 8
	sph.rings = 4
	core.mesh = sph
	core.material_override = _material
	add_child(core)
	for axis in [Vector3.RIGHT, Vector3.UP, Vector3.FORWARD]:
		for sign_dir in [1.0, -1.0]:
			var spike := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.12, 0.55, 0.12)
			spike.mesh = box
			spike.material_override = _material
			var dir: Vector3 = axis * sign_dir
			spike.position = dir * 0.45
			if axis != Vector3.UP:
				spike.rotation = Vector3(PI / 2.0, 0, 0) if axis == Vector3.FORWARD \
					else Vector3(0, 0, PI / 2.0)
			add_child(spike)
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.55
	col.shape = shape
	add_child(col)


## Клад продан: монеты в казну (одометр казны сам разложит по номиналам).
func _on_delivered(_receiver: Node3D) -> void:
	var bank := get_tree().get_first_node_in_group(GoldBank.GROUP)
	if bank != null:
		bank.call(&"add_gold", treasure_bronze)
	EventBus.tutorial_hint.emit(
		"💎 Клад заставы продан в доке: +%d🥉 в казну" % treasure_bronze, 7.0)
