@tool
class_name QuestMarker
extends Node3D
## Маркер квест-цели (туториал): золотой ромб парит и вращается над объектом.
## Единый визуальный язык «золотой ромб = сюда, это цель шага».
##
## Вешается РЕБЁНКОМ на квест-объект в .tscn → следует за ним и умирает вместе
## с ним (клетка разбилась → queue_free родителя забрал и маркер). Пока предмет
## в руке — маркер скрыт (внимание уже привлечено), на release виден снова.
## `done_group` — маркер-группа «шаг сделан» (те же группы, что у TutorialHint:
## bridge_snapped / relay_seated / ...): группа стала непустой → маркер гаснет
## насовсем. Поллинг Timer 0.3с — сигналов членства групп у движка нет.
## @tool: ромб виден в редакторе (двигать/оценивать на глаз).

@export var marker_height: float = 2.2
@export var marker_color: Color = Color(1.0, 0.85, 0.3)
## Группа-маркер завершения шага (пусто = живёт до смерти родителя).
@export var done_group: StringName = &""
@export var bob_amplitude: float = 0.25
@export var spin_speed: float = 2.0
@export var diamond_size: float = 0.42

var _diamond: MeshInstance3D = null
var _time: float = 0.0
var _dismissed: bool = false


func _ready() -> void:
	_build_visual()
	if Engine.is_editor_hint():
		return
	EventBus.hand_grabbed.connect(_on_hand_grabbed)
	EventBus.hand_released.connect(_on_hand_released)
	if done_group != &"":
		var timer := Timer.new()
		timer.wait_time = 0.3
		timer.autostart = true
		timer.timeout.connect(_poll_done)
		add_child(timer)


## Ромб = куб, повёрнутый углом вниз (два поворота по 45°), яркая эмиссия.
## Идемпотентно для @tool-перезагрузок в редакторе.
func _build_visual() -> void:
	var old := get_node_or_null(^"Diamond")
	if old != null:
		old.free()
	_diamond = MeshInstance3D.new()
	_diamond.name = &"Diamond"
	var box := BoxMesh.new()
	box.size = Vector3.ONE * diamond_size
	_diamond.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = marker_color
	mat.emission_enabled = true
	mat.emission = marker_color
	mat.emission_energy_multiplier = 2.5
	_diamond.material_override = mat
	_diamond.position = Vector3(0.0, marker_height, 0.0)
	_diamond.rotation_degrees = Vector3(45.0, 0.0, 45.0)
	add_child(_diamond)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _diamond == null:
		return
	_time += delta
	_diamond.rotate_y(spin_speed * delta)
	_diamond.position.y = marker_height + sin(_time * 2.5) * bob_amplitude


## Предмет взяли в руку — маркер прячется (не мельтешит перед камерой).
func _on_hand_grabbed(item: Node3D) -> void:
	if item == get_parent():
		visible = false


## Отпустили, а шаг ещё не сделан — показываем снова (предмет легко потерять).
func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item == get_parent() and not _dismissed:
		visible = true


func _poll_done() -> void:
	if _dismissed:
		return
	if get_tree().get_nodes_in_group(done_group).size() > 0:
		dismiss()


## Погасить маркер насовсем (шаг выполнен): схлоп-твин и удаление.
func dismiss() -> void:
	if _dismissed:
		return
	_dismissed = true
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3.ONE * 0.01, 0.25) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)
