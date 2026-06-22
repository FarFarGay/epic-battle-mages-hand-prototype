class_name SparkDiode
extends Node3D
## Электрический диод на земле — пазл-механизм. Попадание Искрой ([SparkBolt]
## оповещает группу [SPARK_TARGET_GROUP] в своём impact_radius) → [on_spark] →
## активирует связанную дверь ([door_path].open()). Одноразовый.
##
## Idle — синий glow; после активации — зелёный + электро-вспышка. Только Искра
## активирует диоды (notify живёт в SparkBolt, не в других снарядах).

const SPARK_TARGET_GROUP := Layers.SPARK_TARGET_GROUP

## Emit при УСПЕШНОМ попадании Искрой (после смены цвета). Координатор-пазл
## ([BlueprintMachine]) слушает у группы диодов, чтобы валидировать порядок —
## дверной кейс (target_path.activate) сигнал просто игнорирует.
signal sparked

## Что активировать на попадание Искрой. Зовём target.activate() (duck-typing) —
## может быть дверь (MetalDoor.activate=open) или красный диод (RedDiode.activate).
@export var target_path: NodePath
@export var idle_color: Color = Color(0.3, 0.6, 1.0)
@export var active_color: Color = Color(0.3, 1.0, 0.45)

## Пока true — Искра по диоду no-op (нет on_spark). Координатор глушит диоды на
## время демо-показа последовательности, чтобы случайный каст не «засчитался».
var locked: bool = false
var _activated: bool = false
## Визуал — в сцене spark_diode.tscn (узел Body); материал local_to_scene (свой у
## каждого инстанса). Раньше генерился кодом (_build_visual) — убрано.
@onready var _material: StandardMaterial3D = ($Body as MeshInstance3D).material_override


func _ready() -> void:
	add_to_group(SPARK_TARGET_GROUP)


## Вызывается SparkBolt при попадании Искрой в радиусе. Одноразово открывает дверь.
func on_spark() -> void:
	if _activated or locked:
		return
	_activated = true
	_set_lit(true)
	# Электро-вспышка на активации.
	AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position + Vector3.UP * 0.3, 1.5, 10.0)
	var target := get_node_or_null(target_path)
	if target != null and target.has_method(&"activate"):
		target.call(&"activate")
	elif not target_path.is_empty():
		# Путь к двери/диоду не разрешился — пазл молча мёртв, иначе баг невидим.
		push_warning("[SparkDiode] target_path не разрешён/без activate(): %s (%s)" % [target_path, name])
	sparked.emit()


## Сбросить диод в idle (для re-sparkable пазлов-последовательностей: координатор
## зовёт при ошибке порядка). Дверной кейс не использует — диод одноразовый.
func reset() -> void:
	_activated = false
	_set_lit(false)


## Кратко подсветить диод (демо-показ последовательности координатором). Не
## меняет _activated — это только «смотри, вот этот», без засчёта. No-op если диод
## уже зажжён по-настоящему.
func flash_hint(duration: float = 0.4) -> void:
	if _material == null or _activated:
		return
	_material.emission = active_color
	_material.emission_energy_multiplier = 6.0
	var tw := create_tween()
	tw.tween_property(_material, "emission_energy_multiplier", 3.0, duration)
	tw.parallel().tween_property(_material, "emission", idle_color, duration)


## Зелёный «активирован» / синий idle. Вынесено из on_spark — переиспользует reset.
func _set_lit(lit: bool) -> void:
	if _material == null:
		return
	var c: Color = active_color if lit else idle_color
	_material.albedo_color = c
	_material.emission = c
	_material.emission_energy_multiplier = 5.0 if lit else 3.0
