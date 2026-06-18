class_name RedDiode
extends Node3D
## Красный диод — второе звено пазла Room3. Синий диод ([SparkDiode]) на попадание
## Искрой зовёт [activate]: по проводу бежит ток (бусина-свечение от синего к
## красному) → красный загорается → включает рычаг ([lever_path].enable()). Сам
## дверь НЕ открывает — это делает рычаг.

## Синий диод (откуда тянем провод и откуда «бежит» ток).
@export var wire_from_path: NodePath
## Рычаг, который включаем, когда ток дошёл.
@export var lever_path: NodePath
@export var idle_color: Color = Color(0.45, 0.1, 0.1)
@export var live_color: Color = Color(1.0, 0.22, 0.18)
## Сколько ток «бежит» по проводу до загорания (сек).
@export var flow_duration: float = 0.9

var _energized: bool = false
## Тело диода — в сцене red_diode.tscn (узел Body), материал local_to_scene.
## ПРОВОД строится процедурно (_build_wire): его длина/ориентация зависят от runtime-
## позиций двух диодов — статичной сценой не выразить.
@onready var _material: StandardMaterial3D = ($Body as MeshInstance3D).material_override
var _wire_material: StandardMaterial3D = null
var _wire_from: Vector3 = Vector3.INF


func _ready() -> void:
	_build_wire()


func _build_wire() -> void:
	var from_node := get_node_or_null(wire_from_path) as Node3D
	if from_node == null:
		return
	_wire_from = from_node.global_position + Vector3.UP * 0.25
	var to: Vector3 = global_position + Vector3.UP * 0.25
	var dir: Vector3 = to - _wire_from
	var length: float = dir.length()
	if length < 0.01:
		return
	_wire_material = _make_emissive(idle_color, 0.4)
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.08
	cyl.bottom_radius = 0.08
	cyl.height = length
	mi.mesh = cyl
	mi.material_override = _wire_material
	# Ориентируем цилиндр (Y-up) вдоль провода. Базис: Y = dir.
	var up: Vector3 = dir / length
	var ref: Vector3 = Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var right: Vector3 = up.cross(ref).normalized()
	var fwd: Vector3 = right.cross(up).normalized()
	mi.transform = Transform3D(Basis(right, up, fwd), (_wire_from + to) * 0.5)
	add_child(mi)


## Синий диод довёл искру — пускаем ток. Идемпотентно.
func activate() -> void:
	if _energized:
		return
	_energized = true
	if _wire_material != null:
		_wire_material.albedo_color = live_color
		_wire_material.emission = live_color
		_wire_material.emission_energy_multiplier = 3.0
	_spawn_current_bead()


## Бусина-свечение бежит по проводу от синего к красному, на финише — загорание.
func _spawn_current_bead() -> void:
	if _wire_from == Vector3.INF:
		_on_current_arrived()
		return
	var bead := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.22
	sph.height = 0.44
	bead.mesh = sph
	bead.material_override = _make_emissive(Color(1.0, 0.85, 0.4), 6.0)
	add_child(bead)
	bead.global_position = _wire_from
	var to: Vector3 = global_position + Vector3.UP * 0.25
	var tween := create_tween()
	tween.tween_property(bead, "global_position", to, flow_duration)
	tween.tween_callback(bead.queue_free)
	tween.tween_callback(_on_current_arrived)


func _on_current_arrived() -> void:
	if _material != null:
		_material.albedo_color = live_color
		_material.emission = live_color
		_material.emission_energy_multiplier = 5.0
	var lever := get_node_or_null(lever_path)
	if lever != null and lever.has_method(&"enable"):
		lever.call(&"enable")


func _make_emissive(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat
