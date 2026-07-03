extends RigidBody3D
## Деревянная ПЛАШКА-мост — физический предмет вместо стройки моста (пивот 2026-07-03:
## HandBridgeAim/BridgeSite выпилены). Игрок находит плашку у пропасти, поднимает РУКОЙ
## (Grabbable, как ящик) и кладёт поперёк пропасти — она защёлкивается на полосу барьера,
## режет в нём проём и перепекает навмеш: башня/гномы проходят. Схватил обратно — проём
## заделывается, пропасть снова непроходима. Никакой стройки/рабочих/дерева.
##
## ПРОПАСТЬ ФЕЙКОВАЯ (см. SPEC): пол сплошной, путь держит невидимая стена-барьер
## (группа chasm_barrier). Плашка при первом защёлке ЗАБИРАЕТ владение барьером:
## оригинал нейтрализуется, дальше геометрию (боковые сегменты / цельная стена)
## пересобирает сама (_rebuild_barrier) — snap/unsnap повторяемы сколько угодно.
##
## Слои: свободная — ITEMS (обычный предмет, лежит/толкается); защёлкнутая —
## MOUNTED_MODULE (башня его НЕ маскирует → проезжает по доске, GrabArea руки
## маскирует → можно снять обратно). Тот же приём, что у модулей башни.

const CHASM_BARRIER_GROUP := &"chasm_barrier"
const NAVMESH_SOURCE_GROUP := &"navmesh_source"
const NAV_GROUP := &"nav_region"

## Габарит доски: длина по X (поперёк пропасти, с напуском на края), толщина, ширина по Z.
@export var plank_size := Vector3(11.0, 0.35, 4.6)
@export var plank_color := Color(0.55, 0.38, 0.2)
@export var highlight_color := Color(1.0, 0.95, 0.4, 1.0)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6
## Насколько дальше полосы барьера по Z ещё защёлкиваемся (прощение неточного дропа).
@export var snap_margin: float = 3.0

var _snapped := false
## Плашка забрала владение барьером (оригинал нейтрализован, сегменты — наши).
var _captured := false
var _barrier_node: Node3D = null
var _wall_cx: float = 0.0
var _wall_sx: float = 0.0
var _wall_sy: float = 3.0
var _z_min: float = 0.0
var _z_max: float = 0.0
var _barrier_layer: int = Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE
var _barrier_parent: Node = null
var _segments: Array[StaticBody3D] = []
var _mats: Array[StandardMaterial3D] = []
## Твин доводки защёлка — глушим, если доску перехватили, пока она летела на место.
var _snap_tween: Tween = null


func _ready() -> void:
	mass = 6.0
	collision_layer = Layers.ITEMS
	collision_mask = Layers.MASK_ALL_GAMEPLAY
	_build_visual()
	Grabbable.register(self)
	# ВОЛОЧЕНИЕ (юзер 2026-07-03 «чтобы не приклеивалась к руке»): рука не морозит
	# доску, а тянет пружиной за точку хвата — провисает, скребёт землю, можно
	# волочь за конец. Реализация в HandPhysicalActions._apply_haul_force.
	add_to_group(Layers.HAND_HAUL_GROUP)
	EventBus.hand_grabbed.connect(_on_hand_grabbed)
	EventBus.hand_released.connect(_on_hand_released)


## Доска + две поперечины-клата снизу (читается как мосток, не ящик).
func _build_visual() -> void:
	var deck := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = plank_size
	deck.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = plank_color
	mat.roughness = 0.9
	deck.material_override = mat
	add_child(deck)
	_mats.append(mat)
	var beam_mat := StandardMaterial3D.new()
	beam_mat.albedo_color = plank_color.darkened(0.35)
	beam_mat.roughness = 0.95
	_mats.append(beam_mat)
	for sx in [-0.35, 0.35]:
		var beam := MeshInstance3D.new()
		var bbox := BoxMesh.new()
		bbox.size = Vector3(0.55, 0.22, plank_size.z * 0.92)
		beam.mesh = bbox
		beam.material_override = beam_mat
		beam.position = Vector3(plank_size.x * float(sx), -plank_size.y * 0.5 - 0.11, 0.0)
		add_child(beam)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = plank_size
	col.shape = shape
	add_child(col)


## Контракт Grabbable: рамка-кандидат руки.
func set_highlighted(value: bool) -> void:
	for mat in _mats:
		if value:
			mat.emission_enabled = true
			mat.emission = Color(highlight_color.r, highlight_color.g, highlight_color.b)
			mat.emission_energy_multiplier = highlight_intensity
		else:
			mat.emission_enabled = false


## Схватили защёлкнутую доску → пропасть закрывается обратно. freeze снимаем САМИ:
## haul-режим руки не морозит предмет (заморозка защёлка — наша, наша и разморозка).
func _on_hand_grabbed(item: Node3D) -> void:
	if item != self or not _snapped:
		return
	_snapped = false
	if _snap_tween != null and _snap_tween.is_valid():
		_snap_tween.kill()  # перехватили в полёте доводки — твин не должен бороться с пружиной
	_snap_tween = null
	freeze = false
	collision_layer = Layers.ITEMS
	_rebuild_barrier(NAN, NAN)
	_schedule_rebake()
	var root: Node = get_tree().current_scene
	if root != null:
		AoeVisual.spawn_dust(root, Vector3(_wall_cx, 0.0, global_position.z))


## Отпустили доску: над полосой пропасти → защёлк поперёк; иначе — обычный предмет.
func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item != self or _snapped:
		return
	_try_snap()


func _try_snap() -> void:
	if not _peek_bounds():
		return
	var p := global_position
	if absf(p.x - _wall_cx) > _wall_sx * 0.5 + plank_size.x * 0.5:
		return
	if p.z < _z_min - snap_margin or p.z > _z_max + snap_margin:
		return
	_commit_capture()
	var cz: float = clampf(p.z, _z_min + plank_size.z * 0.5, _z_max - plank_size.z * 0.5)
	_snapped = true
	freeze = true
	collision_layer = Layers.MOUNTED_MODULE
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	var target := Transform3D(Basis.IDENTITY, Vector3(_wall_cx, plank_size.y * 0.5 + 0.02, cz))
	_snap_tween = create_tween()
	_snap_tween.tween_property(self, "global_transform", target, 0.16) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_snap_tween.tween_callback(_snap_land)
	if LogConfig.master_enabled:
		print("[BridgePlank] защёлк через пропасть, z=%.1f" % cz)


## Доска легла: пыль-удар по обоим концам, проём в барьере, навмеш заново.
func _snap_land() -> void:
	if not _snapped:
		return  # успели схватить, пока летела
	var root: Node = get_tree().current_scene
	if root != null:
		var half: float = plank_size.x * 0.45
		AoeVisual.spawn_dust(root, global_position + Vector3(half, 0.0, 0.0))
		AoeVisual.spawn_dust(root, global_position + Vector3(-half, 0.0, 0.0))
	EventBus.camera_shake.emit(0.3, global_position)
	_rebuild_barrier(global_position.z - plank_size.z * 0.5, global_position.z + plank_size.z * 0.5)
	_schedule_rebake()


## Прочитать габариты барьера (без разрушения) — для проверки «над пропастью ли дроп».
func _peek_bounds() -> bool:
	if _captured:
		return true
	_barrier_node = get_tree().get_first_node_in_group(CHASM_BARRIER_GROUP) as Node3D
	if _barrier_node == null:
		return false
	var cs := _find_collision_shape(_barrier_node)
	var box: BoxShape3D = null
	if cs != null:
		box = cs.shape as BoxShape3D
	if box == null:
		return false
	var w: Transform3D = cs.global_transform
	_wall_cx = w.origin.x
	_wall_sx = box.size.x
	_wall_sy = box.size.y
	_z_min = w.origin.z - box.size.z * 0.5
	_z_max = w.origin.z + box.size.z * 0.5
	if _barrier_node is CollisionObject3D:
		_barrier_layer = (_barrier_node as CollisionObject3D).collision_layer
	_barrier_parent = _barrier_node.get_parent()
	return true


## Первый защёлк: нейтрализуем оригинальный барьер СРАЗУ (queue_free отложен) —
## дальше геометрией владеет плашка через _rebuild_barrier.
func _commit_capture() -> void:
	if _captured:
		return
	if _barrier_node != null and is_instance_valid(_barrier_node):
		if _barrier_node.is_in_group(NAVMESH_SOURCE_GROUP):
			_barrier_node.remove_from_group(NAVMESH_SOURCE_GROUP)
		if _barrier_node.is_in_group(CHASM_BARRIER_GROUP):
			_barrier_node.remove_from_group(CHASM_BARRIER_GROUP)
		if _barrier_node is CollisionObject3D:
			(_barrier_node as CollisionObject3D).collision_layer = 0
		var cs := _find_collision_shape(_barrier_node)
		if cs != null:
			cs.disabled = true
		_barrier_node.queue_free()
	_barrier_node = null
	_captured = true


## Пересобрать барьер: с проёмом [gap_lo..gap_hi] по Z (доска лежит) либо цельный
## (NAN = закрыто). Старые наши сегменты нейтрализуются сразу и уходят.
func _rebuild_barrier(gap_lo: float, gap_hi: float) -> void:
	if not _captured:
		return
	for seg in _segments:
		if not is_instance_valid(seg):
			continue
		if seg.is_in_group(NAVMESH_SOURCE_GROUP):
			seg.remove_from_group(NAVMESH_SOURCE_GROUP)
		if seg.is_in_group(CHASM_BARRIER_GROUP):
			seg.remove_from_group(CHASM_BARRIER_GROUP)
		seg.collision_layer = 0
		var cs := _find_collision_shape(seg)
		if cs != null:
			cs.disabled = true
		seg.queue_free()
	_segments.clear()
	if is_nan(gap_lo):
		_spawn_barrier_segment(_z_min, _z_max)
		return
	if gap_lo > _z_min + 0.1:
		_spawn_barrier_segment(_z_min, gap_lo)
	if gap_hi < _z_max - 0.1:
		_spawn_barrier_segment(gap_hi, _z_max)


## Сегмент барьера [z_lo..z_hi] — тот же слой/группы, что у оригинала (навмеш его
## выгрызает, башня/скелеты упираются).
func _spawn_barrier_segment(z_lo: float, z_hi: float) -> void:
	if _barrier_parent == null or not is_instance_valid(_barrier_parent):
		_barrier_parent = get_tree().current_scene
	var sb := StaticBody3D.new()
	sb.collision_layer = _barrier_layer
	sb.collision_mask = 0
	sb.add_to_group(NAVMESH_SOURCE_GROUP)
	sb.add_to_group(CHASM_BARRIER_GROUP)
	_barrier_parent.add_child(sb)
	sb.global_position = Vector3(_wall_cx, 0.0, (z_lo + z_hi) * 0.5)
	var col := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(_wall_sx, _wall_sy, z_hi - z_lo)
	col.shape = b
	col.position = Vector3(0.0, _wall_sy * 0.5, 0.0)
	sb.add_child(col)
	_segments.append(sb)


## Перепечь навмеш следующим кадром (после flush'а queue_free — см. паттерн BridgeSite).
func _schedule_rebake() -> void:
	var nav := get_tree().get_first_node_in_group(NAV_GROUP)
	if nav != null and nav.has_method(&"rebake"):
		get_tree().create_timer(0.05).timeout.connect(Callable(nav, &"rebake"))


func _find_collision_shape(body: Node) -> CollisionShape3D:
	for c in body.get_children():
		if c is CollisionShape3D:
			return c as CollisionShape3D
	return null
