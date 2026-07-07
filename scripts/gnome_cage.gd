@tool
class_name GnomeCage
extends RigidBody3D
## Клетка с пленным гномом (Room1, «первое спасение»): grabbable-предмет —
## рука хватает (ЛКМ) и БРОСАЕТ; от удара на скорости клетка разбивается
## (ShatterEffect), гном освобождается и вступает в артель через
## GnomeSquadSpawner.request_squad(ROLE_WORKER) — карточка артели в HUD
## появляется сама (squad_created). Реплики гнома — через шину хинтов.
##
## Слои как у RelayItem: ITEMS (рука морозит при захвате сама).
## @tool: визуал строится и в РЕДАКТОРЕ (юзер двигает клетку во вьюпорте);
## дети кода не получают owner → в .tscn не сохраняются, дублей нет.

## Цвет прутьев (и осколков при разбитии).
@export var bar_color: Color = Color(0.45, 0.38, 0.3)
@export var highlight_color: Color = Color(1.0, 0.95, 0.4)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6
## Минимальная скорость удара (м/с), с которой клетка разбивается. Ниже —
## клетка просто падает, можно схватить и кинуть снова. Калибровка: «тихо
## положил» рукой = 3-5 м/с (см. hand_physical soft_release), бросок — >8.
@export var break_speed: float = 7.0
## Реплика гнома сразу после спасения.
@export var rescue_line: String = "Гном: Фух, спасибо, браток! Я из артели — со мной не пропадёшь. Побуду в башне!"
## Вторая реплика-подсказка (после rescue_line).
@export var follow_line: String = "Артель — карточка справа: рабочие рубят лес и строят по твоему указу"
@export var rescue_line_duration: float = 5.0

var _broken: bool = false
var _bar_material: StandardMaterial3D = null
## Скорость прошлого физкадра: в body_entered contact уже разрешён физикой и
## linear_velocity погашена — порог удара сравниваем с velocity ДО контакта.
var _prev_speed: float = 0.0


func _ready() -> void:
	_build_visual()
	if Engine.is_editor_hint():
		return
	mass = 4.0
	collision_layer = Layers.ITEMS
	collision_mask = Layers.MASK_ALL_GAMEPLAY
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)
	Grabbable.register(self)


## Прутья по кругу + верх/низ-диски + зелёный гном-капсула внутри.
## Идемпотентно: при перезагрузке @tool-скрипта в редакторе старый визуал сносим.
func _build_visual() -> void:
	var old := get_node_or_null(^"CageVisual")
	if old != null:
		old.free()
	var visual := Node3D.new()
	visual.name = &"CageVisual"
	add_child(visual)
	_bar_material = StandardMaterial3D.new()
	_bar_material.albedo_color = bar_color
	_bar_material.emission_enabled = true
	_bar_material.emission = bar_color * 0.2
	_bar_material.emission_energy_multiplier = 0.0
	const BAR_COUNT := 6
	const CAGE_RADIUS := 0.5
	const CAGE_HEIGHT := 1.2
	for i in range(BAR_COUNT):
		var ang: float = TAU * float(i) / float(BAR_COUNT)
		var bar := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.05
		cyl.bottom_radius = 0.05
		cyl.height = CAGE_HEIGHT
		bar.mesh = cyl
		bar.material_override = _bar_material
		bar.position = Vector3(cos(ang) * CAGE_RADIUS, CAGE_HEIGHT * 0.5, sin(ang) * CAGE_RADIUS)
		visual.add_child(bar)
	for y in [0.03, CAGE_HEIGHT]:
		var disc := MeshInstance3D.new()
		var dm := CylinderMesh.new()
		dm.top_radius = CAGE_RADIUS + 0.1
		dm.bottom_radius = CAGE_RADIUS + 0.1
		dm.height = 0.07
		disc.mesh = dm
		disc.material_override = _bar_material
		disc.position = Vector3(0.0, y, 0.0)
		visual.add_child(disc)
	# Пленник: зелёная капсула-гном внутри (визуальный крючок «там кто-то живой»).
	var gnome := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.22
	cap.height = 0.75
	gnome.mesh = cap
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.35, 0.62, 0.3)
	gnome.material_override = gm
	gnome.position = Vector3(0.0, 0.45, 0.0)
	visual.add_child(gnome)
	# Коллайдер — ПРЯМОЙ ребёнок тела (требование физики), не под CageVisual.
	var old_col := get_node_or_null(^"CageCollision")
	if old_col != null:
		old_col.free()
	var col := CollisionShape3D.new()
	col.name = &"CageCollision"
	var shape := CylinderShape3D.new()
	shape.radius = CAGE_RADIUS + 0.12
	shape.height = CAGE_HEIGHT + 0.1
	col.shape = shape
	col.position = Vector3(0.0, CAGE_HEIGHT * 0.5, 0.0)
	add_child(col)


## Контракт Grabbable: рамка-кандидат руки.
func set_highlighted(value: bool) -> void:
	if _bar_material == null:
		return
	if value:
		_bar_material.emission = highlight_color
		_bar_material.emission_energy_multiplier = highlight_intensity + 1.0
	else:
		_bar_material.emission = bar_color * 0.2
		_bar_material.emission_energy_multiplier = 0.0


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_prev_speed = linear_velocity.length()


func _on_body_entered(_body: Node) -> void:
	if _broken:
		return
	if maxf(_prev_speed, linear_velocity.length()) < break_speed:
		return
	_break()


## Разбить клетку: осколки по направлению полёта + шейк + гном в артель + реплики.
func _break() -> void:
	_broken = true
	var scene := get_tree().current_scene
	if scene != null:
		ShatterEffect.spawn(scene, global_position + Vector3.UP * 0.5, bar_color, 12, 1.5,
				linear_velocity)
		EventBus.camera_shake.emit(0.25, global_position)
	# Освобождённый гном = первый рабочий артели (отряд-на-тип: карточка HUD,
	# эскорт башни — прячется внутрь сам, как стартовые рабочие).
	var spawner := get_tree().get_first_node_in_group(&"squad_spawner")
	if spawner != null and spawner.has_method(&"request_squad"):
		spawner.request_squad(SoldierSystem.ROLE_WORKER, 1,
				Vector3(global_position.x, 0.5, global_position.z))
	EventBus.tutorial_hint.emit(rescue_line, rescue_line_duration)
	if not follow_line.is_empty():
		# Таймер на дереве, не на клетке — она сейчас queue_free'нется; EventBus
		# автолоад, capture безопасен.
		var line := follow_line
		get_tree().create_timer(rescue_line_duration + 0.3).timeout.connect(
				func() -> void: EventBus.tutorial_hint.emit(line, 6.0))
	queue_free()
