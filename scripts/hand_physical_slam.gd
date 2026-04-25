extends Node
## Slam (хлопок по земле) — physical-категория, AOE-разлёт через PhysicsShapeQueryParameters3D.
## Триггерится координатором PhysicalActions, когда `equipped == SLAM` и нажата ПКМ.
##
## Зависит только от родителя — Hand-координатор предоставляет `global_position`,
## `get_world_3d()`, `get_tree()`. Hand находится через `get_parent().get_parent()`
## (PhysicalActions → Hand).

signal slammed(position: Vector3, radius: float)

const SLAM_VISUAL_POOL_CAP: int = 3

class SlamHit:
	extends RefCounted
	var direction: Vector3
	var falloff: float

	func _init(d: Vector3, f: float) -> void:
		direction = d
		falloff = f


@export var slam_radius: float = 5.0
@export var slam_force: float = 30.0
@export var slam_lift_factor: float = 0.4
@export var slam_damage: float = 20.0
@export var slam_cooldown: float = 0.5
## По каким слоям бьёт хлопок: Items + Enemies по умолчанию.
@export_flags_3d_physics var slam_mask: int = 18
@export var slam_visual_color: Color = Color(1.0, 0.7, 0.3, 0.6)
## Длительность knockback'а на врагах (в течение этого времени их AI отключён).
@export var slam_knockback_duration: float = 0.4

@export var debug_log: bool = true

var _hand: Hand
var _slam_cooldown_remaining: float = 0.0

# Пул визуалов хлопка — переиспользуем MeshInstance3D'ы вместо create+free на каждый slam.
var _slam_visual_pool: Array[MeshInstance3D] = []


func _ready() -> void:
	_hand = get_parent().get_parent() as Hand
	if not _hand:
		push_error("HandPhysicalSlam: ожидается Hand через PhysicalActions → Hand")
		set_process(false)
		set_physics_process(false)
		return


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

	var affected_count := 0
	for r in results:
		var collider = r.collider
		if collider is Item:
			var item := collider as Item
			if item.freeze:
				continue
			_apply_slam_to_item(item, origin)
			affected_count += 1
		elif collider is Enemy:
			_apply_slam_to_enemy(collider as Enemy, origin)
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


func _apply_slam_to_item(item: Item, origin: Vector3) -> void:
	var hit := _slam_direction_and_falloff(item.global_position, origin)
	if hit.falloff <= 0.0:
		return
	item.apply_central_impulse(hit.direction * slam_force * hit.falloff)
	item.take_damage(slam_damage * hit.falloff)


func _apply_slam_to_enemy(enemy: Enemy, origin: Vector3) -> void:
	var hit := _slam_direction_and_falloff(enemy.global_position, origin)
	if hit.falloff <= 0.0:
		return
	# CharacterBody3D — нет apply_central_impulse, поэтому передаём через
	# apply_knockback: enemy подменяет velocity и затухает к нулю.
	enemy.apply_knockback(hit.direction * slam_force * hit.falloff, slam_knockback_duration)
	enemy.take_damage(slam_damage * hit.falloff)


func _spawn_slam_visual(pos: Vector3) -> void:
	var mesh: MeshInstance3D
	var sphere: SphereMesh
	var mat: StandardMaterial3D

	if not _slam_visual_pool.is_empty():
		# Переиспользуем меш из пула — сбрасываем scale/alpha/visibility.
		mesh = _slam_visual_pool.pop_back()
		sphere = mesh.mesh as SphereMesh
		mat = mesh.material_override as StandardMaterial3D
		mat.albedo_color = slam_visual_color
		mat.emission = Color(slam_visual_color.r, slam_visual_color.g, slam_visual_color.b)
		mesh.scale = Vector3.ONE
		mesh.visible = true
		if not mesh.is_inside_tree():
			get_tree().current_scene.add_child(mesh)
	else:
		mesh = MeshInstance3D.new()
		sphere = SphereMesh.new()
		sphere.radius = 0.2
		sphere.height = 0.4
		mesh.mesh = sphere

		mat = StandardMaterial3D.new()
		mat.albedo_color = slam_visual_color
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = Color(slam_visual_color.r, slam_visual_color.g, slam_visual_color.b)
		mat.emission_energy_multiplier = 2.0
		mesh.material_override = mat

		var scene_root := get_tree().current_scene
		scene_root.add_child(mesh)

	mesh.global_position = pos

	var target_scale: float = slam_radius / sphere.radius
	var tween := mesh.create_tween()
	tween.set_parallel(true)
	tween.tween_property(mesh, "scale", Vector3.ONE * target_scale, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.finished.connect(_recycle_slam_visual.bind(mesh))


func _recycle_slam_visual(mesh: MeshInstance3D) -> void:
	if not is_instance_valid(mesh):
		return
	if _slam_visual_pool.size() < SLAM_VISUAL_POOL_CAP:
		mesh.visible = false
		_slam_visual_pool.append(mesh)
	else:
		mesh.queue_free()
