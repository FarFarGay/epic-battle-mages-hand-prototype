class_name MineCharge
extends RigidBody3D
## МИННЫЙ ЗАРЯД — расходник башни (категория верфи, 2026-07-12): куёт Мастерская
## навесок кликом (после турели, см. PadBuilding._tick_forge_click), рука кладёт
## его на ВЕРХ БАШНИ — паркуется штатным грузовым слотом ([MountSlot], путь
## tower_cargo: свой монтаж-код не нужен). Слот «Минного рассеивания» в трее
## ПОЯВЛЯЕТСЯ только с зарядом на борту и гаснет без него (юзер 2026-07-13;
## [refresh_tray] → SpellSystem.unlock/lock); залп СЪЕДАЕТ заряд (один заряд =
## один залп, см. [HandSpellMineScatter]). Запас зарядов можно копить на земле.
##
## Визуал: связка тёмных мин-сфер с тлеющим красным глазком — язык самой Mine
## (боевой объект, не флавор — [[feedback_visual_language_unique]]).

## Мина-заряд, припаркованная на крыше башни, находится в группе tower_cargo
## ([MountSlot.CARGO_GROUP]); «заряд на борту?» ищем по ней + типу (см. mounted_on_tower).

@export var highlight_color: Color = Color(1.0, 0.95, 0.4)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6

var _body_mat: StandardMaterial3D = null
var _eye_mat: StandardMaterial3D = null


func _ready() -> void:
	mass = 4.0
	collision_layer = Layers.ITEMS
	collision_mask = Layers.MASK_ALL_GAMEPLAY
	_build_visual()
	Grabbable.register(self)
	# Трей-гейт: положили на башню / сняли с неё — слот мин появляется/гаснет.
	# Deferred: наш хендлер может отработать РАНЬШЕ парковки MountSlot на том же
	# сигнале — проверяем группу после всех.
	EventBus.hand_released.connect(_on_hand_moved)
	EventBus.hand_grabbed.connect(_on_hand_moved)


func _on_hand_moved(item: Node3D, _velocity: Vector3 = Vector3.ZERO) -> void:
	if item == self:
		MineCharge.refresh_tray.call_deferred(get_tree())


## Связка из трёх мин-сфер на поддоне + красный глазок-запал на каждой.
func _build_visual() -> void:
	_body_mat = StandardMaterial3D.new()
	_body_mat.albedo_color = Color(0.22, 0.22, 0.26)
	_body_mat.metallic = 0.4
	_body_mat.roughness = 0.5
	_eye_mat = StandardMaterial3D.new()
	_eye_mat.albedo_color = Color(0.9, 0.25, 0.15)
	_eye_mat.emission_enabled = true
	_eye_mat.emission = Color(1.0, 0.25, 0.1)
	_eye_mat.emission_energy_multiplier = 1.8
	var tray := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.95, 0.12, 0.95)
	tray.mesh = tm
	tray.position = Vector3(0.0, 0.06, 0.0)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.45, 0.32, 0.2)
	wood.roughness = 0.85
	tray.material_override = wood
	add_child(tray)
	for off in [Vector3(-0.24, 0.0, -0.16), Vector3(0.26, 0.0, -0.1), Vector3(0.0, 0.0, 0.26)]:
		var orb := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.21
		sm.height = 0.42
		orb.mesh = sm
		orb.material_override = _body_mat
		orb.position = off + Vector3(0.0, 0.32, 0.0)
		add_child(orb)
		var eye := MeshInstance3D.new()
		var em := SphereMesh.new()
		em.radius = 0.05
		em.height = 0.1
		eye.mesh = em
		eye.material_override = _eye_mat
		eye.position = off + Vector3(0.0, 0.53, 0.0)
		add_child(eye)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.95, 0.66, 0.95)
	col.shape = shape
	col.position = Vector3(0.0, 0.33, 0.0)
	add_child(col)


## Контракт Grabbable: рамка-кандидат руки.
func set_highlighted(value: bool) -> void:
	if _body_mat == null:
		return
	if value:
		_body_mat.emission_enabled = true
		_body_mat.emission = highlight_color
		_body_mat.emission_energy_multiplier = highlight_intensity + 1.0
	else:
		_body_mat.emission_enabled = false


## Заряд, лежащий на крыше башни (запас на земле не считается), или null.
static func mounted_on_tower(tree: SceneTree) -> MineCharge:
	for n in tree.get_nodes_in_group(MountSlot.CARGO_GROUP):
		if n is MineCharge and is_instance_valid(n):
			return n as MineCharge
	return null


## Пересчитать слот «Минного рассеивания» в трее: заряд на борту → слот есть,
## нет → слота нет (SpellSystem.unlock/lock → HUD пересобирает трей теми же
## сигналами, что и у кафедр-школ). Идемпотентно.
static func refresh_tray(tree: SceneTree) -> void:
	if tree == null or SpellSystem == null:
		return
	if mounted_on_tower(tree) != null:
		if not SpellSystem.is_unlocked(&"mine_scatter"):
			SpellSystem.unlock(&"mine_scatter")
			EventBus.tutorial_hint.emit("💣 Мины на борту — «Минное рассеивание» в трее: залп по клику", 5.0)
	else:
		SpellSystem.lock(&"mine_scatter")


## Залп выпущен — заряд потрачен: из группы борта СРАЗУ (queue_free отложен до
## конца кадра — [[reference_godot_queue_free_deferred]]), искры, слот трея гаснет.
func consume() -> void:
	remove_from_group(MountSlot.CARGO_GROUP)
	AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position, 1.0, 10.0)
	queue_free()
	MineCharge.refresh_tray(get_tree())


## Страховка: заряд ушёл из мира любым путём (потрачен/сцена) — слот пересчитать.
func _exit_tree() -> void:
	var tree := get_tree()
	if tree != null:
		MineCharge.refresh_tray.call_deferred(tree)
