class_name WarMachine
extends RigidBody3D
## БОЕВАЯ МАШИНА ГНОМОВ (пересборка 2026-07-21, DESIGN §5.В «магия = машины»):
## аппарат, который куёт Машинный цех; рука ставит его на КРЫШУ башни → у руки
## ПОЯВЛЯЕТСЯ глагол (каст ПКМ / обводка / дэш-форма спелла machine_id, через
## SpellSystem.unlock). Сняли машину — глагол гаснет (lock). «Полные трусы
## заклинаний» невозможны структурно: слотов крыши мало (roof_capacity).
##
## Паттерн монтажа скопирован с пилота системы — HarpoonModule (рука хватает,
## отпустила у башни → защёлк на корпус, слой MOUNTED_MODULE, снимается рукой).
## Гарпун при монтаже тоже входит в ROOF_GROUP — слоты общие на все аппараты.

## Общая группа «аппарат стоит на крыше» — учёт занятых слотов (машины + гарпун).
const ROOF_GROUP := &"tower_roof_machine"
const MOUNT_RADIUS := 3.5
## Позиции слотов на крыше (локаль башни): центр + два плеча.
const ROOF_SLOT_OFFSETS: Array = [
	Vector3(0.0, 3.0, 0.0), Vector3(0.95, 3.0, 0.35), Vector3(-0.95, 3.0, 0.35),
]

## Каталог машин: spell id → имя/цвет/цена ковки. Ковка — окно Машинного цеха
## (клик по цеху); знание — свиток/чертёж профиля (KNOWN_DEFAULT — стартовое).
const CATALOG: Dictionary = {
	&"fireball": {"name": "Огнемётная машина", "color": Color(1.0, 0.45, 0.1), "cost": 60},
	&"firestorm": {"name": "Шквал-орга́н", "color": Color(0.9, 0.3, 0.05), "cost": 90},
	&"frost": {"name": "Мороз-конденсатор", "color": Color(0.45, 0.8, 1.0), "cost": 80},
}
const KNOWN_DEFAULT: Array = [&"fireball"]

var machine_id: StringName = &"fireball"

var _mounted: bool = false
var _body_mat: StandardMaterial3D = null
var _snap_tween: Tween = null

@export var highlight_color: Color = Color(1.0, 0.95, 0.4)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6


## Спелл гейтится машиной? (PlayerProfile не анлочит такие свитком напрямую —
## свиток даёт цеху ЗНАНИЕ ковки, каст даёт только установленный аппарат.)
static func is_machine_spell(id: StringName) -> bool:
	return CATALOG.has(id)


## Ёмкость крыши: 1 + узлы верфи (Tower.roof_slots, ось ветки — DESIGN §5.А).
static func roof_capacity(tree: SceneTree) -> int:
	var tower := tree.get_first_node_in_group(Tower.GROUP)
	if tower == null:
		return 1
	var v: Variant = tower.get(&"roof_slots")
	return maxi(int(v), 1) if (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT) else 1


static func mounted_count(tree: SceneTree) -> int:
	var n: int = 0
	for m in tree.get_nodes_in_group(ROOF_GROUP):
		if is_instance_valid(m):
			n += 1
	return n


static func has_free_slot(tree: SceneTree) -> bool:
	return mounted_count(tree) < roof_capacity(tree)


func _ready() -> void:
	_build_visual()
	mass = 5.0
	collision_layer = Layers.ITEMS
	collision_mask = Layers.MASK_ALL_GAMEPLAY
	Grabbable.register(self)
	EventBus.hand_grabbed.connect(_on_hand_grabbed)
	EventBus.hand_released.connect(_on_hand_released)


## Визуал: станина + котёл в цвет спелла + труба-раструб. Один язык на все
## машины, цвет = цвет спелла в трее (читается «какой глагол даёт»).
func _build_visual() -> void:
	var data: Dictionary = CATALOG.get(machine_id, {})
	var col: Color = data.get("color", Color(0.7, 0.7, 0.7))
	var visual := Node3D.new()
	visual.name = &"MachineVisual"
	add_child(visual)
	_body_mat = StandardMaterial3D.new()
	_body_mat.albedo_color = Color(0.45, 0.35, 0.25)
	_body_mat.roughness = 0.8
	_body_mat.emission_enabled = true
	_body_mat.emission = Color(0.45, 0.35, 0.25) * 0.2
	_body_mat.emission_energy_multiplier = 0.0
	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = col
	core_mat.emission_enabled = true
	core_mat.emission = col
	core_mat.emission_energy_multiplier = 0.8
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.66, 0.72, 0.8)
	steel.metallic = 0.7
	steel.roughness = 0.4
	# Станина.
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.9, 0.22, 0.9)
	base.mesh = bm
	base.material_override = _body_mat
	base.position = Vector3(0.0, 0.11, 0.0)
	visual.add_child(base)
	# Котёл-сердце машины (цвет спелла, светится).
	var core := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.26
	cm.bottom_radius = 0.32
	cm.height = 0.5
	core.mesh = cm
	core.material_override = core_mat
	core.position = Vector3(0.0, 0.47, 0.1)
	visual.add_child(core)
	# Труба-раструб вперёд (визуал смотрит в -Z, как жёлоб гарпуна).
	var barrel := MeshInstance3D.new()
	var brm := CylinderMesh.new()
	brm.top_radius = 0.16
	brm.bottom_radius = 0.1
	brm.height = 0.7
	barrel.mesh = brm
	barrel.material_override = steel
	barrel.position = Vector3(0.0, 0.62, -0.45)
	barrel.rotation_degrees = Vector3(-80.0, 0.0, 0.0)
	visual.add_child(barrel)
	# Коллайдер.
	var colshape := CollisionShape3D.new()
	colshape.name = &"MachineCollision"
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.95, 0.9, 1.1)
	colshape.shape = shape
	colshape.position = Vector3(0.0, 0.45, 0.0)
	add_child(colshape)


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


## Установленная машина поворачивается за рукой (единый язык с гарпуном).
func _process(_delta: float) -> void:
	if not _mounted:
		return
	var hand := get_tree().get_first_node_in_group(Hand.HAND_GROUP) as Hand
	if hand == null:
		return
	var target: Vector3 = hand.cursor_world_position()
	target.y = global_position.y
	if target.distance_squared_to(global_position) < 1.0:
		return
	look_at(target, Vector3.UP)


func _on_hand_grabbed(item: Node3D) -> void:
	if item != self:
		return
	if _snap_tween != null and _snap_tween.is_valid():
		_snap_tween.kill()
	_snap_tween = null
	if _mounted:
		call_deferred(&"_unmount")  # реперент НЕ в теле сигнала (busy parent)
	collision_layer = Layers.ITEMS


func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item != self or _mounted:
		return
	var tower := get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	if tower == null or not is_instance_valid(tower):
		return
	var dx: float = tower.global_position.x - global_position.x
	var dz: float = tower.global_position.z - global_position.z
	if dx * dx + dz * dz > MOUNT_RADIUS * MOUNT_RADIUS:
		return
	# Слоты крыши общие (машины + гарпун) + груз MountSlot.
	if not WarMachine.has_free_slot(get_tree()):
		EventBus.tutorial_hint.emit("⚠ Слоты крыши заняты — сними другой аппарат рукой", 4.0)
		return
	var slot := get_tree().get_first_node_in_group(&"tower_top_slot")
	if slot != null and slot.has_method(&"has_cargo") and slot.call(&"has_cargo"):
		EventBus.tutorial_hint.emit("⚠ Крыша башни занята грузом — сними его рукой", 4.0)
		return
	call_deferred(&"_mount", tower)


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
	var slot_idx: int = clampi(WarMachine.mounted_count(get_tree()), 0, ROOF_SLOT_OFFSETS.size() - 1)
	add_to_group(ROOF_GROUP)
	_snap_tween = create_tween()
	_snap_tween.tween_property(self, "position", ROOF_SLOT_OFFSETS[slot_idx] as Vector3, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_snap_tween.tween_callback(func() -> void:
		AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position, 0.9, 8.0))
	# Машина в слоте = глагол у руки. Снимут — глагол погаснет (_unmount).
	SpellSystem.unlock(machine_id)
	var data: Dictionary = CATALOG.get(machine_id, {})
	EventBus.tutorial_hint.emit("⚙ %s установлена — «%s» в трее ожил" % [
		data.get("name", "Машина"),
		String(SpellSystem.get_spell_data(machine_id).get("name", machine_id))], 4.0)


func _unmount() -> void:
	_mounted = false
	remove_from_group(ROOF_GROUP)
	var keep := global_transform
	var scene := get_tree().current_scene
	get_parent().remove_child(self)
	scene.add_child(self)
	global_transform = keep
	freeze = false
	_refresh_spell_gate()


## Спелл гаснет, только если НИ ОДНОЙ машины этого id не осталось на крыше.
func _refresh_spell_gate() -> void:
	for m in get_tree().get_nodes_in_group(ROOF_GROUP):
		if m is WarMachine and is_instance_valid(m) and (m as WarMachine).machine_id == machine_id:
			return
	SpellSystem.lock(machine_id)


func _exit_tree() -> void:
	# Машина исчезла из мира прямо с крыши (смерть башни и т.п.) — глагол гаснет.
	if _mounted:
		remove_from_group(ROOF_GROUP)
		call_deferred(&"_deferred_gate_refresh")


func _deferred_gate_refresh() -> void:
	# После exit_tree дерева уже нет у self — гейт освежает любой живой узел.
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return
	var tree := loop as SceneTree
	for m in tree.get_nodes_in_group(ROOF_GROUP):
		if m is WarMachine and is_instance_valid(m) and (m as WarMachine).machine_id == machine_id:
			return
	SpellSystem.lock(machine_id)
