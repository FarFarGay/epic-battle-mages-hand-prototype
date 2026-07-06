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
## Плашка в этой группе, пока лежит мостом — маркер «переход открыт» для
## внешних читателей (TutorialHint глушит «нужен мост» и т.п.).
const SNAPPED_GROUP := &"bridge_snapped"

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
## Трансформ ШЕЙПА барьера на момент захвата. Вся математика — в его ЛОКАЛЬНЫХ
## осях: local X = ось перехода (толщина пропасти), local Z = длина полосы.
## Повернул барьер в сцене → плашка/сегменты сами подстроились (Room5 identity,
## Room2 yaw 90° — один код).
var _wall_xf: Transform3D = Transform3D.IDENTITY
## Горизонтальная (yaw) проекция осей барьера — базис укладки доски и сегментов.
var _yaw_basis: Basis = Basis.IDENTITY
var _wall_sx: float = 0.0
var _wall_sy: float = 3.0
## Полудлина полосы барьера по его локальной Z.
var _half_len: float = 0.0
var _barrier_layer: int = Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE
var _barrier_parent: Node = null
var _segments: Array[StaticBody3D] = []
var _mats: Array[StandardMaterial3D] = []
## Твин доводки защёлка — глушим, если доску перехватили, пока она летела на место.
var _snap_tween: Tween = null

## Доска-МЕТЛА (2026-07-07): пока доска В РУКЕ и движется быстрее порога — скелеты
## вдоль её короба расталкиваются push'ем, а РЯДОВЫЕ ещё и получают смертельный
## урон (взмах моста косит мелочь). Тяжёлые (super_dash_only: гигант/метатель) —
## только толчок, урона нет: симметрия с тараном башни, тяжёлых берёт лишь
## супер-рывок. Per-skeleton кулдаун, чтобы не бить каждый физкадр контакта.
const SWEEP_MIN_SPEED := 3.0
const SWEEP_PUSH := 8.0
const SWEEP_DAMAGE := 60.0
const SWEEP_COOLDOWN_MSEC := 350
const _SWEEP_CD_META := &"_plank_sweep_cd_msec"
## Доска сейчас в руке (haul). Ставится/снимается в hand_grabbed/released.
var _held: bool = false


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
	if item == self:
		_held = true
	if item != self or not _snapped:
		return
	_snapped = false
	remove_from_group(SNAPPED_GROUP)
	if _snap_tween != null and _snap_tween.is_valid():
		_snap_tween.kill()  # перехватили в полёте доводки — твин не должен бороться с пружиной
	_snap_tween = null
	freeze = false
	collision_layer = Layers.ITEMS
	_rebuild_barrier(NAN, NAN)
	_schedule_rebake()
	var root: Node = get_tree().current_scene
	if root != null:
		AoeVisual.spawn_dust(root, Vector3(global_position.x, 0.0, global_position.z))


## Отпустили доску: над полосой пропасти → защёлк поперёк; иначе — обычный предмет.
func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item == self:
		_held = false
	if item != self or _snapped:
		return
	_try_snap()


## Метла: скелеты в коробе несомой доски получают push по её скорости. Работает
## только В РУКЕ (полёт после броска не расталкивает) и не на защёлкнутой.
func _physics_process(_delta: float) -> void:
	if not _held or _snapped:
		return
	var vel: Vector3 = linear_velocity
	vel.y = 0.0
	var spd: float = vel.length()
	if spd < SWEEP_MIN_SPEED:
		return
	var inv: Transform3D = global_transform.affine_inverse()
	var dir: Vector3 = vel / spd
	var now: int = Time.get_ticks_msec()
	for n in get_tree().get_nodes_in_group(&"skeleton"):
		var sk := n as Node3D
		if sk == null or not is_instance_valid(sk):
			continue
		var l: Vector3 = inv * sk.global_position
		if absf(l.x) > plank_size.x * 0.5 + 0.6 or absf(l.z) > plank_size.z * 0.5 + 0.9 \
				or absf(l.y) > 2.5:
			continue
		if now < int(sk.get_meta(_SWEEP_CD_META, 0)):
			continue
		sk.set_meta(_SWEEP_CD_META, now + SWEEP_COOLDOWN_MSEC)
		if sk.has_method(&"apply_knockback"):
			sk.call(&"apply_knockback", dir * SWEEP_PUSH + Vector3.UP * 2.0, 0.2)
		# Рядовых взмах КОСИТ (60 > hp 30 даже с вариацией); тяжёлые — только толчок.
		if not sk.is_in_group(&"super_dash_only"):
			Damageable.try_damage(sk, SWEEP_DAMAGE)


func _try_snap() -> void:
	if not _peek_bounds():
		return
	var l: Vector3 = _wall_xf.affine_inverse() * global_position
	if absf(l.x) > _wall_sx * 0.5 + plank_size.x * 0.5:
		return
	if absf(l.z) > _half_len + snap_margin:
		return
	_commit_capture()
	var cz: float = clampf(l.z, -_half_len + plank_size.z * 0.5, _half_len - plank_size.z * 0.5)
	_snapped = true
	add_to_group(SNAPPED_GROUP)
	freeze = true
	collision_layer = Layers.MOUNTED_MODULE
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	var origin: Vector3 = _wall_xf * Vector3(0.0, 0.0, cz)
	origin.y = plank_size.y * 0.5 + 0.02
	var target := Transform3D(_yaw_basis, origin)
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
		AoeVisual.spawn_dust(root, global_position + _yaw_basis.x * half)
		AoeVisual.spawn_dust(root, global_position - _yaw_basis.x * half)
	EventBus.camera_shake.emit(0.3, global_position)
	var lz: float = (_wall_xf.affine_inverse() * global_position).z
	_rebuild_barrier(lz - plank_size.z * 0.5, lz + plank_size.z * 0.5)
	_schedule_rebake()


## Прочитать габариты барьера (без разрушения) — для проверки «над пропастью ли дроп».
## Барьер — БЛИЖАЙШИЙ из группы (пропастей в сцене может быть несколько, Room2+Room5);
## меряем по шейпу, не по узлу — origin узла бывает смещён от полосы (Room5).
func _peek_bounds() -> bool:
	if _captured:
		return true
	_barrier_node = _nearest_barrier()
	if _barrier_node == null:
		return false
	var cs := _find_collision_shape(_barrier_node)
	var box: BoxShape3D = null
	if cs != null:
		box = cs.shape as BoxShape3D
	if box == null:
		return false
	_wall_xf = cs.global_transform.orthonormalized()
	var bx: Vector3 = _wall_xf.basis.x
	bx.y = 0.0
	bx = bx.normalized() if bx.length_squared() > 0.001 else Vector3.RIGHT
	_yaw_basis = Basis(bx, Vector3.UP, bx.cross(Vector3.UP))
	_wall_sx = box.size.x
	_wall_sy = box.size.y
	_half_len = box.size.z * 0.5
	if _barrier_node is CollisionObject3D:
		_barrier_layer = (_barrier_node as CollisionObject3D).collision_layer
	_barrier_parent = _barrier_node.get_parent()
	return true


## Ближайший к плашке барьер группы chasm_barrier (по центру ШЕЙПА). Дистанция
## естественно разводит и чужие пропасти, и сегменты чужих плашек (та же группа).
func _nearest_barrier() -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group(CHASM_BARRIER_GROUP):
		var n3 := n as Node3D
		if n3 == null:
			continue
		var cs := _find_collision_shape(n3)
		var ref: Vector3 = cs.global_position if cs != null else n3.global_position
		var d: float = ref.distance_squared_to(global_position)
		if d < best_d:
			best_d = d
			best = n3
	return best


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
		_spawn_barrier_segment(-_half_len, _half_len)
		return
	if gap_lo > -_half_len + 0.1:
		_spawn_barrier_segment(-_half_len, gap_lo)
	if gap_hi < _half_len - 0.1:
		_spawn_barrier_segment(gap_hi, _half_len)


## Сегмент барьера [z_lo..z_hi] (локальная Z полосы) — тот же слой/группы, что у
## оригинала (навмеш его выгрызает, башня/скелеты упираются).
func _spawn_barrier_segment(z_lo: float, z_hi: float) -> void:
	if _barrier_parent == null or not is_instance_valid(_barrier_parent):
		_barrier_parent = get_tree().current_scene
	var sb := StaticBody3D.new()
	sb.collision_layer = _barrier_layer
	sb.collision_mask = 0
	sb.add_to_group(NAVMESH_SOURCE_GROUP)
	sb.add_to_group(CHASM_BARRIER_GROUP)
	_barrier_parent.add_child(sb)
	var pos: Vector3 = _wall_xf * Vector3(0.0, 0.0, (z_lo + z_hi) * 0.5)
	pos.y = 0.0
	sb.global_transform = Transform3D(_yaw_basis, pos)
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
