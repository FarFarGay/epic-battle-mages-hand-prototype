class_name CastleBlueprint
extends RigidBody3D
## Чертёж замка — квестовый предмет базы Долины (акт II): его печатает
## станок-чертёжник на заставе ([BlueprintMachine].print_scene). ПИВОТ 2026-07-11:
## рука кладёт чертёж на ВЕРХ БАШНИ (как груз-артефакты, [MountSlot]) — башня
## ЗАПОМИНАЕТ его НАВСЕГДА (learned), предмет растворяется, а в панели стройки
## открывается карточка «Замок» (вне колоды). Ставится замок по-прежнему ТОЛЬКО
## на фундамент ([CastleFoundation] — привязка в [HandPlaceAim]).
##
## ЯЗЫК ЧЕРТЕЖЕЙ единый: «синька» кладётся на верх башни → знание в башне.
## Наследники (чертёж Кафедры огня из храма, [keystone_element.gd]) меняют
## эффект в [_on_learned] и цвет модельки (model_color).
##
## Grabbable-паттерн [RelayItem] (рука морозит при захвате сама, слой ITEMS).
## Визуал = светящаяся «синька» с моделькой башенки сверху — читается как
## чертёж с высоты камеры.

const GROUP := &"castle_blueprint"

## Башня выучила чертёж (навсегда на сессию): гейт карточки «Замок» в панели стройки.
static var learned := false

@export var sheet_color: Color = Color(0.35, 0.6, 1.0)
## Цвет мини-модели на листе (наследники: чертёж кафедры — цвет школы).
@export var model_color: Color = Color(0.9, 0.93, 1.0)
@export var highlight_color: Color = Color(1.0, 0.95, 0.4)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6
## В каком радиусе (XZ до tower_top_slot) дроп засчитывается как «положил на башню»
## — тот же порог, что у груза MountSlot.cargo_snap_radius.
@export var snap_radius: float = 2.5

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
	mmat.albedo_color = model_color
	mmat.emission_enabled = true
	mmat.emission = model_color
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


## Отпустили у верха башни → башня запоминает чертёж: доводка к слоту, растворение,
## эффект наследника в [_on_learned].
func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item != self or _seated:
		return
	var slot := _nearest_top_slot()
	if slot == null:
		return
	var dx: float = global_position.x - slot.global_position.x
	var dz: float = global_position.z - slot.global_position.z
	if dx * dx + dz * dz > snap_radius * snap_radius:
		return
	_seated = true
	freeze = true
	collision_layer = 0  # рука больше не видит — предмет уходит в башню
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	var tw := create_tween()
	tw.tween_property(self, "global_position", slot.global_position + Vector3.UP * 0.5, 0.3) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "scale", Vector3.ONE * 0.05, 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		if is_instance_valid(self):
			AoeVisual.spawn_pulse_sparks(get_tree().current_scene,
				global_position, 1.5, 8.0)
			queue_free())
	_on_learned()


## Эффект изучения — наследники переопределяют (чертёж кафедры → карта в колоду).
## База: карточка «Замок» в панели стройки оживает (гейт по learned).
func _on_learned() -> void:
	learned = true
	EventBus.tutorial_hint.emit("🏰 Башня запомнила чертёж замка — закладывай из панели стройки на фундамент", 6.0)


func _nearest_top_slot() -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group(&"tower_top_slot"):
		var s := n as Node3D
		if s == null or not is_instance_valid(s):
			continue
		var d: float = s.global_position.distance_squared_to(global_position)
		if d < best_d:
			best_d = d
			best = s
	return best
