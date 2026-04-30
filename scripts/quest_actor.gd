class_name QuestActor
extends Node3D
## Сюжетный «актор» — выдатчик задания на конкретной POI.
##
## Состояние читается из QuestProgress по `quest_order`. Визуал — капсула
## с цветом по состоянию: locked = тусклый серый, active = яркий жёлтый
## с emission, completed = зелёный.
##
## `actor_id` — уникальный ID для будущих скриптовых триггеров (диалог,
## выдача награды, ивенты в EventBus). Сейчас не используется кроме логов,
## но фиксируется в инспекторе на каждой инстансе.
##
## Подписан на `EventBus.quest_advanced`, чтобы перекраситься без явных
## связей с другими акторами.

@export var actor_id: StringName
@export var quest_order: int = 0

@onready var _mesh: MeshInstance3D = $Mesh

var _material: StandardMaterial3D


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_mesh.material_override = _material
	EventBus.quest_advanced.connect(_on_quest_advanced)
	_refresh_visual()


func _on_quest_advanced(_new_index: int) -> void:
	_refresh_visual()


func _refresh_visual() -> void:
	if QuestProgress.is_completed(quest_order):
		_material.albedo_color = Color(0.3, 0.7, 0.35, 1.0)
		_material.emission_enabled = false
	elif QuestProgress.is_active(quest_order):
		_material.albedo_color = Color(0.95, 0.85, 0.25, 1.0)
		_material.emission_enabled = true
		_material.emission = Color(0.95, 0.85, 0.25, 1.0)
		_material.emission_energy_multiplier = 0.7
	else:
		_material.albedo_color = Color(0.32, 0.32, 0.38, 1.0)
		_material.emission_enabled = false
