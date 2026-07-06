class_name CoalLump
extends RigidBody3D
## Уголь — топливо станка-чертёжника: Grabbable-ком, рука хватает и КИДАЕТ в
## приёмник топки ([BlueprintMachine._on_furnace_body] поглощает по группе).
## Паттерн [RelayItem] без гнезда: свободный RigidBody на ITEMS, рука морозит
## при захвате сама, бросок = обычный release со скоростью руки.

const GROUP := &"coal_lump"

@export var coal_color: Color = Color(0.13, 0.12, 0.14)
@export var highlight_color: Color = Color(1.0, 0.95, 0.4)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.8

var _material: StandardMaterial3D = null


func _ready() -> void:
	mass = 1.5
	collision_layer = Layers.ITEMS
	collision_mask = Layers.MASK_ALL_GAMEPLAY
	add_to_group(GROUP)
	_build_visual()
	Grabbable.register(self)


## Угловатый чёрный ком: low-poly сфера читается как кусок породы.
func _build_visual() -> void:
	var body := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.3
	sph.height = 0.5
	sph.radial_segments = 6
	sph.rings = 3
	body.mesh = sph
	_material = StandardMaterial3D.new()
	_material.albedo_color = coal_color
	_material.roughness = 0.9
	body.material_override = _material
	add_child(body)
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.3
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
