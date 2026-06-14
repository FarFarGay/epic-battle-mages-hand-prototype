class_name SparkDiode
extends Node3D
## Электрический диод на земле — пазл-механизм. Попадание Искрой ([SparkBolt]
## оповещает группу [SPARK_TARGET_GROUP] в своём impact_radius) → [on_spark] →
## активирует связанную дверь ([door_path].open()). Одноразовый.
##
## Idle — синий glow; после активации — зелёный + электро-вспышка. Только Искра
## активирует диоды (notify живёт в SparkBolt, не в других снарядах).

const SPARK_TARGET_GROUP := &"spark_target"

## Что активировать на попадание Искрой. Зовём target.activate() (duck-typing) —
## может быть дверь (MetalDoor.activate=open) или красный диод (RedDiode.activate).
@export var target_path: NodePath
@export var idle_color: Color = Color(0.3, 0.6, 1.0)
@export var active_color: Color = Color(0.3, 1.0, 0.45)

var _activated: bool = false
var _material: StandardMaterial3D = null


func _ready() -> void:
	add_to_group(SPARK_TARGET_GROUP)
	_build_visual()


func _build_visual() -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.45
	cyl.bottom_radius = 0.6
	cyl.height = 0.5
	mi.mesh = cyl
	_material = StandardMaterial3D.new()
	_material.albedo_color = idle_color
	_material.emission_enabled = true
	_material.emission = idle_color
	_material.emission_energy_multiplier = 3.0
	mi.material_override = _material
	mi.position.y = 0.25
	add_child(mi)


## Вызывается SparkBolt при попадании Искрой в радиусе. Одноразово открывает дверь.
func on_spark() -> void:
	if _activated:
		return
	_activated = true
	if _material != null:
		_material.albedo_color = active_color
		_material.emission = active_color
		_material.emission_energy_multiplier = 5.0
	# Электро-вспышка на активации.
	AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position + Vector3.UP * 0.3, 1.5, 10.0)
	var target := get_node_or_null(target_path)
	if target != null and target.has_method(&"activate"):
		target.call(&"activate")
