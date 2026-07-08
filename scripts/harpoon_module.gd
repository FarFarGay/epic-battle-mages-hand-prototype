@tool
class_name HarpoonModule
extends RigidBody3D
## Гарпунная турель — МОДУЛЬ-АППАРАТ башни (пилот модульной системы 2026-07-07,
## «кафедры производят вещи, рука ставит их на башню»).
##
## Жизненный цикл: гильдия инженеров куёт аппарат (или стартовый лежит в Room1)
## → рука хватает (Grabbable, как клетка/плашка) → отпустил РЯДОМ С БАШНЕЙ →
## защёлк на корпус (reparent к башне, freeze, слой MOUNTED_MODULE — башня
## возит его на себе, рука может снять обратно). Установлен → из башни вылезает
## ГНОМ-ОПЕРАТОР (декор) и спелл «Гарпун» в трее оживает (группа MOUNTED_GROUP —
## гейт в HandSpellHarpoon). Снял → гном прячется, гарпун глохнет.
##
## @tool: визуал виден в редакторе (как GnomeCage). Дети кода без owner —
## в .tscn не сохраняются.

## Группа-маркер «модуль установлен на башню» — гейт спелла гарпуна.
const MOUNTED_GROUP := &"harpoon_module_mounted"
## Радиус защёлка: отпустил ближе этого от башни (XZ) → монтаж.
const MOUNT_RADIUS := 3.5
## Локальная позиция на корпусе башни (сбоку, «навесной аппарат»).
const MOUNT_LOCAL := Vector3(1.45, 1.9, 0.0)

@export var highlight_color: Color = Color(1.0, 0.95, 0.4)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6

var _mounted: bool = false
var _body_mat: StandardMaterial3D = null
var _gnome_visual: Node3D = null
var _snap_tween: Tween = null


func _ready() -> void:
	_build_visual()
	if Engine.is_editor_hint():
		return
	mass = 5.0
	collision_layer = Layers.ITEMS
	collision_mask = Layers.MASK_ALL_GAMEPLAY
	Grabbable.register(self)
	EventBus.hand_grabbed.connect(_on_hand_grabbed)
	EventBus.hand_released.connect(_on_hand_released)


## Мини-баллиста: станина + вертлюг + жёлоб со стрелой + бухта каната. Гном-
## оператор — отдельный узел, виден только когда модуль установлен.
func _build_visual() -> void:
	var old := get_node_or_null(^"ModuleVisual")
	if old != null:
		old.free()
	var visual := Node3D.new()
	visual.name = &"ModuleVisual"
	add_child(visual)
	_body_mat = StandardMaterial3D.new()
	_body_mat.albedo_color = Color(0.45, 0.35, 0.25)
	_body_mat.roughness = 0.8
	_body_mat.emission_enabled = true
	_body_mat.emission = Color(0.45, 0.35, 0.25) * 0.2
	_body_mat.emission_energy_multiplier = 0.0
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.66, 0.72, 0.8)
	steel.metallic = 0.7
	steel.roughness = 0.4
	# Станина-основание.
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.9, 0.22, 0.9)
	base.mesh = bm
	base.material_override = _body_mat
	base.position = Vector3(0.0, 0.11, 0.0)
	visual.add_child(base)
	# Вертлюг-стойка.
	var pivot := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.12
	pm.bottom_radius = 0.16
	pm.height = 0.35
	pivot.mesh = pm
	pivot.material_override = steel
	pivot.position = Vector3(0.0, 0.38, 0.0)
	visual.add_child(pivot)
	# Жёлоб (ложе стрелы), наклонён чуть вверх.
	var bed := MeshInstance3D.new()
	var bedm := BoxMesh.new()
	bedm.size = Vector3(0.26, 0.14, 1.2)
	bed.mesh = bedm
	bed.material_override = _body_mat
	bed.position = Vector3(0.0, 0.62, 0.0)
	bed.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	visual.add_child(bed)
	# Заряженная стрела с наконечником.
	var bolt := MeshInstance3D.new()
	var boltm := BoxMesh.new()
	boltm.size = Vector3(0.09, 0.09, 1.05)
	bolt.mesh = boltm
	bolt.material_override = steel
	bolt.position = Vector3(0.0, 0.74, -0.1)
	bolt.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	visual.add_child(bolt)
	var tip := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 0.0
	tm.bottom_radius = 0.12
	tm.height = 0.3
	tip.mesh = tm
	tip.material_override = steel
	tip.position = Vector3(0.0, 0.83, -0.72)
	tip.rotation_degrees = Vector3(-98.0, 0.0, 0.0)
	visual.add_child(tip)
	# Бухта каната сбоку (пеньковый цвет верёвки гарпуна — родство).
	var rope := StandardMaterial3D.new()
	rope.albedo_color = Color(0.72, 0.55, 0.3)
	rope.roughness = 0.9
	var coil := MeshInstance3D.new()
	var cm := TorusMesh.new()
	cm.inner_radius = 0.08
	cm.outer_radius = 0.2
	coil.mesh = cm
	coil.material_override = rope
	coil.position = Vector3(0.42, 0.45, 0.25)
	coil.rotation_degrees = Vector3(0.0, 0.0, 90.0)
	visual.add_child(coil)
	# Гном-оператор (декор): сидит за жёлобом, виден ТОЛЬКО на башне.
	_gnome_visual = Node3D.new()
	_gnome_visual.name = &"GnomeOperator"
	_gnome_visual.visible = false
	visual.add_child(_gnome_visual)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.35, 0.62, 0.3)
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.16
	cap.height = 0.5
	body.mesh = cap
	body.material_override = gm
	body.position = Vector3(0.0, 0.5, 0.55)
	_gnome_visual.add_child(body)
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.9, 0.75, 0.6)
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.11
	hm.height = 0.22
	head.mesh = hm
	head.material_override = skin
	head.position = Vector3(0.0, 0.82, 0.55)
	_gnome_visual.add_child(head)
	# Коллайдер — прямой ребёнок тела.
	var old_col := get_node_or_null(^"ModuleCollision")
	if old_col != null:
		old_col.free()
	var col := CollisionShape3D.new()
	col.name = &"ModuleCollision"
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.95, 0.9, 1.2)
	col.shape = shape
	col.position = Vector3(0.0, 0.45, 0.0)
	add_child(col)


## Контракт Grabbable: рамка-кандидат руки.
func set_highlighted(value: bool) -> void:
	if _body_mat == null:
		return
	if value:
		_body_mat.emission = highlight_color
		_body_mat.emission_energy_multiplier = highlight_intensity + 1.0
	else:
		_body_mat.emission = Color(0.45, 0.35, 0.25) * 0.2
		_body_mat.emission_energy_multiplier = 0.0


func is_mounted() -> bool:
	return _mounted


## Схватили с башни → демонтаж: обратно в мир, гарпун глохнет, гном прячется.
func _on_hand_grabbed(item: Node3D) -> void:
	if item != self:
		return
	if _snap_tween != null and _snap_tween.is_valid():
		_snap_tween.kill()
	_snap_tween = null
	if _mounted:
		call_deferred(&"_unmount")  # реперент НЕ в теле сигнала (busy parent)
	collision_layer = Layers.ITEMS


## Отпустили рядом с башней → монтаж на корпус.
func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item != self or _mounted:
		return
	var tower := get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	if tower == null or not is_instance_valid(tower):
		return
	# Один слот (пилот): другой аппарат уже стоит — этот падает рядом.
	var occupied := get_tree().get_first_node_in_group(MOUNTED_GROUP)
	if occupied != null and occupied != self:
		return
	var dx: float = tower.global_position.x - global_position.x
	var dz: float = tower.global_position.z - global_position.z
	if dx * dx + dz * dz > MOUNT_RADIUS * MOUNT_RADIUS:
		return
	call_deferred(&"_mount", tower)  # реперент НЕ в теле сигнала (busy parent)


## Монтаж: freeze + reparent к башне (едет на корпусе) + слой MOUNTED_MODULE
## (башня не сталкивается, GrabArea руки видит → можно снять) + доводка-tween.
func _mount(tower: Node3D) -> void:
	_mounted = true
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_layer = Layers.MOUNTED_MODULE
	var keep := global_transform
	get_parent().remove_child(self)
	tower.add_child(self)
	global_transform = keep
	add_to_group(MOUNTED_GROUP)
	if _gnome_visual != null:
		_gnome_visual.visible = true  # оператор вылез и сел за аппарат
	_snap_tween = create_tween()
	_snap_tween.tween_property(self, "transform",
		Transform3D(Basis.IDENTITY, MOUNT_LOCAL), 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_snap_tween.tween_callback(func() -> void:
		AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position, 0.9, 8.0))
	EventBus.tutorial_hint.emit("⚙ Гарпунная турель установлена — «Гарпун» в трее заклинаний ожил", 4.0)


## Демонтаж: обратно ребёнком сцены, физика оживает (дальше рукой владеет Hand).
func _unmount() -> void:
	_mounted = false
	remove_from_group(MOUNTED_GROUP)
	if _gnome_visual != null:
		_gnome_visual.visible = false  # оператор спрятался в башню
	var keep := global_transform
	var scene := get_tree().current_scene
	get_parent().remove_child(self)
	scene.add_child(self)
	global_transform = keep
	freeze = false
