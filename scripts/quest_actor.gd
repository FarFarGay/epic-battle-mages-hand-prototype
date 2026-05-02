class_name QuestActor
extends Node3D
## Сюжетный «актор» — выдатчик задания на конкретной POI.
##
## Визуал — костёр (поленья + GPUParticles3D пламени и дыма + OmniLight3D).
## Состояние читается из QuestProgress по `quest_order`:
##   - locked    — потухший: тлеющие поленья, лёгкий дым, без пламени, без света;
##   - active    — горящий: яркое оранжевое пламя, активный дым, тёплый свет;
##   - completed — отгоревший: бело-голубое тление, минимум дыма, тусклый зелёный свет
##                 (символика «задание сделано», в отличие от обычного потухшего костра).
##
## `actor_id` — уникальный ID для будущих скриптовых триггеров (диалог,
## выдача награды, ивенты в EventBus). Сейчас не используется кроме логов.
##
## Подписан на `EventBus.quest_advanced`, чтобы перекраситься без явных
## связей с другими акторами.

@export var actor_id: StringName
@export var quest_order: int = 0

@onready var _logs_root: Node3D = $Logs
@onready var _flame_core: MeshInstance3D = $FlameCore
@onready var _flame_particles: GPUParticles3D = $FlameParticles
@onready var _smoke_particles: GPUParticles3D = $SmokeParticles
@onready var _light: OmniLight3D = $Light

# Per-instance копия материала поленьев — иначе все QuestActor'ы на сцене
# делили бы один material_override и emission переключался бы у всех разом.
var _log_material: StandardMaterial3D


func _ready() -> void:
	_clone_log_material()
	EventBus.quest_advanced.connect(_on_quest_advanced)
	_refresh_visual()


func _on_quest_advanced(_new_index: int) -> void:
	_refresh_visual()


## Каждый Log* в .tscn ссылается на общий sub_resource Material_log.
## Чтобы менять emission per-instance (locked / active / completed), делаем
## уникальную копию и переназначаем на все 4 полена один раз в _ready.
func _clone_log_material() -> void:
	if _logs_root == null:
		return
	var first_log := _logs_root.get_child(0) as MeshInstance3D
	if first_log == null or first_log.material_override == null:
		_log_material = StandardMaterial3D.new()
	else:
		_log_material = (first_log.material_override as StandardMaterial3D).duplicate()
	for child in _logs_root.get_children():
		var mi := child as MeshInstance3D
		if mi != null:
			mi.material_override = _log_material


func _refresh_visual() -> void:
	if QuestProgress.is_completed(quest_order):
		_apply_completed()
	elif QuestProgress.is_active(quest_order):
		_apply_active()
	else:
		_apply_locked()


## Locked — костёр не разожжён. Тёмные поленья, дыма мало (просто струйка),
## нет пламени, без света. Как место будущего костра, но без задания не зажжён.
func _apply_locked() -> void:
	_log_material.emission_enabled = true
	_log_material.emission = Color(0.5, 0.2, 0.05, 1.0)
	_log_material.emission_energy_multiplier = 0.05
	_flame_core.visible = false
	_flame_particles.emitting = false
	_smoke_particles.emitting = true
	_smoke_particles.amount = 5
	_light.light_energy = 0.0


## Active — горящий костёр. Яркое пламя, активный дым, тёплый свет.
func _apply_active() -> void:
	_log_material.emission_enabled = true
	_log_material.emission = Color(0.95, 0.35, 0.05, 1.0)
	_log_material.emission_energy_multiplier = 0.6
	_flame_core.visible = true
	_flame_particles.emitting = true
	_smoke_particles.emitting = true
	_smoke_particles.amount = 14
	_light.light_color = Color(1.0, 0.55, 0.2, 1.0)
	_light.light_energy = 1.6


## Completed — задание выполнено. Костёр догорел, но угли тлеют бело-голубым
## (магический след). Свет тусклый зелёный — игрок видит, что был тут и закрыл.
func _apply_completed() -> void:
	_log_material.emission_enabled = true
	_log_material.emission = Color(0.4, 0.85, 0.55, 1.0)
	_log_material.emission_energy_multiplier = 0.3
	_flame_core.visible = false
	_flame_particles.emitting = false
	_smoke_particles.emitting = true
	_smoke_particles.amount = 3
	_light.light_color = Color(0.5, 0.95, 0.6, 1.0)
	_light.light_energy = 0.7
