class_name KeystoneElement
extends ArtifactElement
## АККУМУЛЯТОР звёздной энергии (сюжет «Верхний Предел»; файл исторически
## keystone_element — раньше тут была Ключ-плита Врат). Хранится в заброшенном
## храме на каньоне (комната «Разлом»): добыча = экзамен руки+гарпуна (стащить
## блок-мост через ущелье, переехать, забрать). Доставка [ArtifactElement] в
## ИНСТИТУТ МАГИИ → институт ур.2: Искра становится МОЛНИЕЙ (spark level 2),
## открывается Огненный шквал (наш «магический залп»).
##
## Визуал: кристалл-батарея — тёмный корпус с ярким светящимся ядром.


func _ready() -> void:
	deliver_role = &"magic"
	pickup_hint = "⚡ Аккумулятор древних! Неси в 🔮 ИНСТИТУТ МАГИИ — Искра станет Молнией, откроется Огненный шквал. Можно везти на крыше башни"
	super()


## Корпус-обойма + светящееся ядро. Один материал — highlight красит разом.
func _build_visual() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.3, 0.32, 0.42)
	_material.metallic = 0.5
	_material.roughness = 0.35
	_material.emission_enabled = true
	_material.emission = Color(0.5, 0.85, 1.0)
	_material.emission_energy_multiplier = 1.6
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.55, 0.9, 0.55)
	body.mesh = box
	body.material_override = _material
	add_child(body)
	var core := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.16
	cyl.bottom_radius = 0.16
	cyl.height = 1.05
	core.mesh = cyl
	core.material_override = _material
	add_child(core)
	for y in [-0.32, 0.0, 0.32]:
		var ring := MeshInstance3D.new()
		var rb := BoxMesh.new()
		rb.size = Vector3(0.62, 0.08, 0.62)
		ring.mesh = rb
		ring.position = Vector3(0, y, 0)
		ring.material_override = _material
		add_child(ring)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.62, 1.05, 0.62)
	col.shape = shape
	add_child(col)


## Институт ур.2: Молния (spark level 2) + Огненный шквал (залп).
func _on_delivered(_receiver: Node3D) -> void:
	SpellSystem.grant_level(&"spark")
	SpellSystem.unlock(&"firestorm")
	EventBus.tutorial_hint.emit(
		"⚡ Аккумулятор встроен — Институт ур.2! Искра стала МОЛНИЕЙ, открыт Огненный шквал", 8.0)
