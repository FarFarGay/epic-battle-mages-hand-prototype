class_name HandPhysicalSlam
extends Node
## Slam (хлопок по земле) — physical-категория, AOE-разлёт через PhysicsShapeQueryParameters3D.
## Триггерится координатором PhysicalActions, когда `equipped == SLAM` и нажата ПКМ.
##
## Связь с Hand устанавливается через setup(hand, coord) от координатора —
## никаких get_parent()-цепочек.

signal slammed(position: Vector3, radius: float)

const SLAM_VISUAL_POOL_CAP: int = 3
const SLAM_VISUAL_BASE_RADIUS: float = 0.2
const SLAM_VISUAL_BASE_HEIGHT: float = 0.4
const SLAM_VISUAL_TWEEN_DURATION: float = 0.3
const SLAM_VISUAL_EMISSION_ENERGY: float = 2.0

class SlamHit:
	extends RefCounted
	var direction: Vector3
	var falloff: float

	func _init(d: Vector3, f: float) -> void:
		direction = d
		falloff = f


@export_group("Balance")
@export var slam_radius: float = 5.0
@export var slam_force: float = 30.0
@export var slam_lift_factor: float = 0.4
## Базовый урон в эпицентре. С линейным falloff'ом fall(d) = 1 − d/radius
## фактический урон = slam_damage × fall. На skeleton hp=30:
##   - d ≤ 2.5м (50% радиуса) → ≥30 dmg, ваншот при прицельном попадании;
##   - 2.5 < d ≤ 3.75 → 2 удара (средний пояс AOE — туда попадают
##     коллатеральные скелеты при slam'е по основной цели);
##   - d > 3.75 → 3+ удара (рим, скелета задело краем визуала).
## Раньше было 80 — 1-шотовая зона занимала 62% радиуса, и в реальной игре
## 2-шот почти не возникал (аиминг обычно близко к эпицентру).
@export var slam_damage: float = 60.0
@export var slam_cooldown: float = 0.5
## По каким слоям бьёт хлопок: Items + Enemies по умолчанию (Layers.MASK_HAND_TARGETS = 18).
@export_flags_3d_physics var slam_mask: int = 18
@export var slam_visual_color: Color = Color(1.0, 0.7, 0.3, 0.6)
## Длительность knockback'а на kinematic-целях (в течение этого времени AI отключён).
@export var slam_knockback_duration: float = 0.4

@export_group("")
## Куда добавлять визуалы хлопка. Если NodePath пуст или не резолвится —
## fallback на current_scene (визуал должен остаться в точке хлопка, а не
## таскаться за рукой; поэтому _hand как родитель не подходит).
@export var effects_root_path: NodePath
@export var debug_log: bool = true

var _hand: Hand
var _coord: HandPhysicalActions
var _slam_cooldown_remaining: float = 0.0
var _effects_root: Node = null

# Пул визуалов хлопка — переиспользуем MeshInstance3D'ы вместо create+free на каждый slam.
var _slam_visual_pool: Array[MeshInstance3D] = []


## Вызывается координатором HandPhysicalActions._ready после установления связи с Hand.
func setup(hand: Hand, coord: HandPhysicalActions) -> void:
	_hand = hand
	_coord = coord
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = _hand.get_tree().current_scene


## Slam одноразовый, hold-state не имеет — для симметрии с Flick.
func is_active() -> bool:
	return false


# --- Публичный API (вызывается координатором PhysicalActions) ---

func can_trigger() -> bool:
	return _slam_cooldown_remaining <= 0.0


func on_press() -> void:
	_perform_slam()


func on_release() -> void:
	# Slam — one-shot, релиз ничего не делает.
	pass


func tick(delta: float) -> void:
	if _slam_cooldown_remaining > 0.0:
		_slam_cooldown_remaining = maxf(_slam_cooldown_remaining - delta, 0.0)


# --- Slam ---

func _perform_slam() -> void:
	var origin: Vector3 = _hand.global_position
	_slam_cooldown_remaining = slam_cooldown

	var space := _hand.get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = slam_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), origin)
	query.collision_mask = slam_mask
	query.collide_with_bodies = true
	var results := space.intersect_shape(query, 32)

	var held: Item = _coord.get_held_item() if _coord else null
	var affected_count := 0
	for r in results:
		var collider = r.collider
		if not Damageable.is_damageable(collider):
			continue
		# Только пойманный рукой собственный Item исключаем — чтобы хлопок не
		# толкал свой же ящик. Прочие freeze=true RigidBody (декорации/динамика)
		# теперь нормально получают damage; push на них всё равно будет no-op
		# (Item.apply_push вернёт ранний return при freeze).
		if collider == held:
			continue
		var hit := _slam_direction_and_falloff(collider.global_position, origin)
		if hit.falloff <= 0.0:
			continue
		var velocity_change: Vector3 = hit.direction * slam_force * hit.falloff
		Pushable.try_push(collider, velocity_change, slam_knockback_duration)
		Damageable.try_damage(collider, slam_damage * hit.falloff)
		affected_count += 1

	if debug_log and LogConfig.master_enabled:
		print("[Hand:Physical:Slam] хлопок @ (%.1f, %.1f, %.1f), задело: %d" % [origin.x, origin.y, origin.z, affected_count])

	_spawn_slam_visual(origin)
	slammed.emit(origin, slam_radius)


func _slam_direction_and_falloff(target_pos: Vector3, origin: Vector3) -> SlamHit:
	var to_target: Vector3 = target_pos - origin
	var horizontal_dist := Vector2(to_target.x, to_target.z).length()
	var falloff: float = clampf(1.0 - horizontal_dist / slam_radius, 0.0, 1.0)
	if falloff <= 0.0:
		return SlamHit.new(Vector3.UP, 0.0)
	var horizontal_dir := VecUtil.horizontal(to_target)
	if horizontal_dir.length_squared() < VecUtil.EPSILON_SQ:
		horizontal_dir = Vector3.UP
	else:
		horizontal_dir = horizontal_dir.normalized() + Vector3.UP * slam_lift_factor
		horizontal_dir = horizontal_dir.normalized()
	return SlamHit.new(horizontal_dir, falloff)


func _spawn_slam_visual(pos: Vector3) -> void:
	var mesh: MeshInstance3D
	var sphere: SphereMesh
	var mat: StandardMaterial3D

	# Чистим пул от freed-меш'ей до reuse — могли исчезнуть вместе со сценой.
	while not _slam_visual_pool.is_empty() and not is_instance_valid(_slam_visual_pool.back()):
		_slam_visual_pool.pop_back()
	if not _slam_visual_pool.is_empty():
		mesh = _slam_visual_pool.pop_back()
		sphere = mesh.mesh as SphereMesh
		mat = mesh.material_override as StandardMaterial3D
		mat.albedo_color = slam_visual_color
		mat.emission = _opaque(slam_visual_color)
		mesh.scale = Vector3.ONE
		mesh.visible = true
		if not mesh.is_inside_tree():
			_effects_root.add_child(mesh)
	else:
		mesh = MeshInstance3D.new()
		sphere = SphereMesh.new()
		sphere.radius = SLAM_VISUAL_BASE_RADIUS
		sphere.height = SLAM_VISUAL_BASE_HEIGHT
		mesh.mesh = sphere

		mat = StandardMaterial3D.new()
		mat.albedo_color = slam_visual_color
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = _opaque(slam_visual_color)
		mat.emission_energy_multiplier = SLAM_VISUAL_EMISSION_ENERGY
		mesh.material_override = mat
		_effects_root.add_child(mesh)

	mesh.global_position = pos

	var target_scale: float = slam_radius / sphere.radius
	var tween := mesh.create_tween()
	tween.set_parallel(true)
	tween.tween_property(mesh, "scale", Vector3.ONE * target_scale, SLAM_VISUAL_TWEEN_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, SLAM_VISUAL_TWEEN_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.finished.connect(_recycle_slam_visual.bind(mesh))


func _recycle_slam_visual(mesh: MeshInstance3D) -> void:
	if not is_instance_valid(mesh):
		return
	if _slam_visual_pool.size() < SLAM_VISUAL_POOL_CAP:
		mesh.visible = false
		_slam_visual_pool.append(mesh)
	else:
		mesh.queue_free()


static func _opaque(c: Color) -> Color:
	return Color(c.r, c.g, c.b)
