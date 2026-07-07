class_name RubbleStone
extends RigidBody3D
## Валун завала (пивот 2026-07-07: «чертёж Врат» как гейт проходов ВЫПИЛЕН,
## завал разбирается РУКОЙ): тяжёлый Grabbable-камень, паттерн [CoalLump].
## Завал = кучка валунов поперёк прохода; рука растаскивает по одному —
## расчистил значит открыл, никаких счётчиков и триггеров, чистая физика.
##
## Изначально frozen — куча стоит монолитом, башня и скелеты упираются
## (слой ITEMS в их масках). Захват рукой морозит/размораживает штатно
## ([HandPhysical._grab/_release]) — после первого же переноса валун живёт
## обычной физикой, можно докатить или бросить где угодно.

const GROUP := &"rubble_stone"

## Габариты валуна (меш и коллизия строятся кодом — scale на RigidBody нельзя).
@export var size: Vector3 = Vector3(1.4, 1.1, 1.1)
@export var stone_color: Color = Color(0.45, 0.44, 0.5)
@export var highlight_color: Color = Color(1.0, 0.95, 0.4)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.8

var _material: StandardMaterial3D = null


func _ready() -> void:
	mass = 20.0
	freeze = true
	collision_layer = Layers.ITEMS
	collision_mask = Layers.MASK_ALL_GAMEPLAY
	add_to_group(GROUP)
	_build_visual()
	Grabbable.register(self)


func _build_visual() -> void:
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	body.mesh = box
	_material = StandardMaterial3D.new()
	_material.albedo_color = stone_color
	_material.roughness = 0.92
	body.material_override = _material
	add_child(body)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	add_child(col)


## Контракт Grabbable: рамка-кандидат руки.
func set_highlighted(value: bool) -> void:
	if _material == null:
		return
	_material.emission_enabled = value
	if value:
		_material.emission = Color(highlight_color.r, highlight_color.g, highlight_color.b)
		_material.emission_energy_multiplier = highlight_intensity
	else:
		_material.emission_energy_multiplier = 0.0
