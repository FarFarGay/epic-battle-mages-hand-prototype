class_name CastleBlueprint
extends RigidBody3D
## Чертёж замка — квестовый предмет базы Долины (акт II): его печатает
## станок-чертёжник на заставе ([BlueprintMachine].print_scene), рука несёт
## на плиту-фундамент в центре долины ([CastleFoundation]) — вклад запускает
## стройку замка артелью. Замок из палитры стройки убран (2026-07-07):
## закладка ТОЛЬКО чертежом на привязанную точку.
##
## Grabbable-паттерн [RelayItem] (рука морозит при захвате сама, слой ITEMS):
## отпустил в [snap_radius] от фундамента → фундамент поглощает чертёж и
## спавнит стройплощадку замка. Визуал = светящаяся «синька» с моделькой
## башенки сверху — читается как чертёж с высоты камеры.

const GROUP := &"castle_blueprint"

@export var sheet_color: Color = Color(0.35, 0.6, 1.0)
@export var highlight_color: Color = Color(1.0, 0.95, 0.4)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6
## В каком радиусе от фундамента дроп засчитывается как вклад.
@export var snap_radius: float = 3.0

var _material: StandardMaterial3D = null
var _seated: bool = false


func _ready() -> void:
	mass = 2.0
	collision_layer = Layers.ITEMS
	collision_mask = Layers.MASK_ALL_GAMEPLAY
	add_to_group(GROUP)
	_build_visual()
	Grabbable.register(self)
	EventBus.hand_released.connect(_on_hand_released)


## «Синька»: тонкая светящаяся плита-лист + белая мини-башенка (модель на чертеже).
func _build_visual() -> void:
	var sheet := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.1, 0.08, 0.8)
	sheet.mesh = box
	sheet.position = Vector3(0, 0.04, 0)
	_material = StandardMaterial3D.new()
	_material.albedo_color = sheet_color
	_material.emission_enabled = true
	_material.emission = sheet_color
	_material.emission_energy_multiplier = 1.4
	sheet.material_override = _material
	add_child(sheet)
	var model := MeshInstance3D.new()
	var mbox := BoxMesh.new()
	mbox.size = Vector3(0.28, 0.3, 0.28)
	model.mesh = mbox
	model.position = Vector3(0, 0.23, 0)
	var mmat := StandardMaterial3D.new()
	mmat.albedo_color = Color(0.92, 0.95, 1.0)
	mmat.emission_enabled = true
	mmat.emission = Color(0.85, 0.9, 1.0)
	mmat.emission_energy_multiplier = 0.9
	model.material_override = mmat
	add_child(model)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.1, 0.4, 0.8)
	col.shape = shape
	col.position = Vector3(0, 0.2, 0)
	add_child(col)


## Контракт Grabbable: рамка-кандидат руки.
func set_highlighted(value: bool) -> void:
	if _material == null:
		return
	if value:
		_material.emission = Color(highlight_color.r, highlight_color.g, highlight_color.b)
		_material.emission_energy_multiplier = highlight_intensity + 1.4
	else:
		_material.emission = sheet_color
		_material.emission_energy_multiplier = 1.4


## Отпустили рядом с фундаментом → вклад. Дальше фундамент сам ведёт доводку,
## растворение чертежа и закладку стройки; повторный захват отрезаем слоем.
func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item != self or _seated:
		return
	var foundation := _nearest_foundation()
	if foundation == null or foundation.is_used():
		return
	if global_position.distance_to(foundation.global_position) > snap_radius:
		return
	_seated = true
	freeze = true
	collision_layer = 0  # рука больше не видит — предмет уходит в фундамент
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	foundation.seat(self)


func _nearest_foundation() -> CastleFoundation:
	var best: CastleFoundation = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group(CastleFoundation.GROUP):
		var f := n as CastleFoundation
		if f == null:
			continue
		var d: float = f.global_position.distance_squared_to(global_position)
		if d < best_d:
			best_d = d
			best = f
	return best
