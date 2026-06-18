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
## Визуал — в сцене spark_diode.tscn (узел Body); материал local_to_scene (свой у
## каждого инстанса). Раньше генерился кодом (_build_visual) — убрано.
@onready var _material: StandardMaterial3D = ($Body as MeshInstance3D).material_override


func _ready() -> void:
	add_to_group(SPARK_TARGET_GROUP)


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
