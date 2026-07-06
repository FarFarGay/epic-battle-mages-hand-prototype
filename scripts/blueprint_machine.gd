class_name BlueprintMachine
extends Node3D
## Станок-чертёжник гномов — ФИЗИЧЕСКИЙ пазл растопки (переработан 2026-07-07;
## раньше был «Саймон»-последовательность из 3 диодов — юзер заменил на связку
## трёх глаголов игрока):
##   1. ТОПКА — кинь рукой уголь ([CoalLump]) в приёмник ([furnace_area_path]);
##      нужно [coal_needed] кусков, пасть топки разгорается ступенчато.
##   2. КОНТАКТ — топка горит → диод ([diode_path]) расглушается, бей Искрой.
##   3. ПУСКАЧ — контакт запитан → рычаг ([lever_path]) включается; дёрнул →
##      станок оживает: PlayerProfile.unlock_building + печать чертежа.
## Шаги строго по цепочке — каждый открывает следующий; на каждом шаге
## плашка-подсказка (EventBus.tutorial_hint) ведёт дальше.

## Сколько кусков угля надо закинуть в топку.
@export var coal_needed: int = 2
## Area3D-приёмник топки (ловит RigidBody-уголь, маска ITEMS).
@export var furnace_area_path: NodePath
## Меш «пасти» топки — эмиссия разгорается с каждым углём.
@export var furnace_mouth_path: NodePath
## Диод-контакт ([SparkDiode]): заглушен до растопки.
@export var diode_path: NodePath
## Финальный рычаг-пускач ([Lever]). Стартует disabled; включаем после контакта.
@export var lever_path: NodePath
## Меш-ядро станка — подсветим эмиссией на запуске (опц.).
@export var core_path: NodePath

@export_group("Печать чертежа")
## Сцена предмета-чертежа (напр. [CastleBlueprint]): на запуске станок отпечатывает
## его и выталкивает вперёд, к пускачу (+Z). null — станок только открывает знание.
@export var print_scene: PackedScene
## Плашка-подсказка после печати (пустая — не показывать).
@export var print_hint: String = ""

@export_group("Отладка")
@export var debug_log: bool = true

## Цвет жара топки (эмиссия пасти).
const FIRE_COLOR := Color(1.0, 0.5, 0.15)

var _coal_count: int = 0
var _fire_lit: bool = false
var _powered: bool = false
var _ignited: bool = false
var _diode: SparkDiode = null
var _lever: Node = null
var _mouth_mat: StandardMaterial3D = null
var _core_mat: StandardMaterial3D = null


func _ready() -> void:
	var area := get_node_or_null(furnace_area_path) as Area3D
	if area != null:
		area.body_entered.connect(_on_furnace_body)
	else:
		push_warning("[BlueprintMachine] furnace_area_path не Area3D: %s" % furnace_area_path)
	_diode = get_node_or_null(diode_path) as SparkDiode
	if _diode != null:
		_diode.locked = true  # до растопки Искра по контакту не засчитывается
		_diode.sparked.connect(_on_diode_sparked)
	_lever = get_node_or_null(lever_path)
	if _lever != null and _lever.has_method(&"disable"):
		_lever.call(&"disable")
	var mouth := get_node_or_null(furnace_mouth_path) as MeshInstance3D
	if mouth != null:
		_mouth_mat = mouth.material_override as StandardMaterial3D
	var core := get_node_or_null(core_path) as MeshInstance3D
	if core != null and core.get_surface_override_material(0) != null:
		_core_mat = core.get_surface_override_material(0)
	elif core != null and core.material_override is StandardMaterial3D:
		_core_mat = core.material_override as StandardMaterial3D


## Уголь долетел до приёмника топки: поглотить кусок, поднять жар на ступень.
func _on_furnace_body(body: Node3D) -> void:
	if _fire_lit or body == null or not body.is_in_group(CoalLump.GROUP):
		return
	var pos: Vector3 = body.global_position
	body.queue_free()
	_coal_count += 1
	var scene := get_tree().current_scene
	if scene != null:
		AoeVisual.spawn_pulse_sparks(scene, pos, 0.9, 8.0)
	_update_mouth_glow()
	if debug_log and LogConfig.master_enabled:
		print("[BlueprintMachine] уголь %d/%d" % [_coal_count, coal_needed])
	if _coal_count >= coal_needed:
		_fire_lit = true
		if _diode != null:
			_diode.locked = false
		EventBus.camera_shake.emit(0.2, global_position)
		EventBus.tutorial_hint.emit("Топка гудит! Теперь ударь Искрой [1] по контакту станка", 7.0)
	else:
		EventBus.tutorial_hint.emit("Уголь в топке: %d/%d — кидай ещё" % [_coal_count, coal_needed], 4.0)


## Жар пасти: разгорается ступенчато с каждым углём.
func _update_mouth_glow() -> void:
	if _mouth_mat == null:
		return
	_mouth_mat.emission_enabled = true
	_mouth_mat.emission = FIRE_COLOR
	var t: float = clampf(float(_coal_count) / float(maxi(coal_needed, 1)), 0.0, 1.0)
	_mouth_mat.emission_energy_multiplier = 0.6 + 3.0 * t


## Контакт запитан Искрой (диод расглушен только после растопки) → пускач ожил.
func _on_diode_sparked() -> void:
	if _powered or not _fire_lit:
		return
	_powered = true
	if _lever != null and _lever.has_method(&"enable"):
		_lever.call(&"enable")
	EventBus.tutorial_hint.emit("Контакт запитан! Дёрни рычаг-пускач — станок отпечатает чертёж", 7.0)
	if debug_log and LogConfig.master_enabled:
		print("[BlueprintMachine] контакт запитан → пускач включён")


## Зовёт рычаг ([Lever].target_path → станок) когда игрок его перекинул.
func activate() -> void:
	_ignite()


## Станок оживает: вспышка ядра + искры + знание о постройках + печать чертежа.
func _ignite() -> void:
	if _ignited:
		return
	_ignited = true
	var root: Node = get_tree().current_scene
	if is_instance_valid(root):
		AoeVisual.spawn_explosion(root, global_position + Vector3.UP * 0.8, 2.0)
		AoeVisual.spawn_pulse_sparks(root, global_position + Vector3.UP * 0.8, 2.5, 18.0)
	EventBus.camera_shake.emit(0.4, global_position)
	if _core_mat != null:
		_core_mat.emission_enabled = true
		_core_mat.emission = Color(1.0, 0.8, 0.3)
		_core_mat.emission_energy_multiplier = 4.0
	var profile := get_tree().get_first_node_in_group(&"player_profile")
	if profile != null and profile.has_method(&"unlock_building"):
		profile.call(&"unlock_building")
	_print_blueprint()
	if debug_log and LogConfig.master_enabled:
		print("[BlueprintMachine] ★ СТАНОК ЗАПУЩЕН — знание о постройках открыто")


## Печать предмета-чертежа: выброс вперёд с подскоком — «станок выплюнул лист».
func _print_blueprint() -> void:
	if print_scene == null:
		return
	var root: Node = get_tree().current_scene
	if root == null:
		return
	var item := print_scene.instantiate()
	root.add_child(item)
	if item is RigidBody3D:
		var rb := item as RigidBody3D
		rb.global_position = global_position + global_transform.basis * Vector3(0, 1.6, 1.4)
		rb.linear_velocity = global_transform.basis * Vector3(0, 3.0, 3.5)
	elif item is Node3D:
		(item as Node3D).global_position = global_position + Vector3.UP * 1.2
	if print_hint != "":
		EventBus.tutorial_hint.emit(print_hint, 8.0)
