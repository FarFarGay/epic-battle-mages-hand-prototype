class_name BurnPatch
extends Node3D
## Статичная зона горения. Не двигается, не растёт по площади — пятно
## фиксированного радиуса на земле, тикает урон каждые `tick_interval`
## всем damageable в радиусе, ~`duration` секунд, потом `queue_free`.
##
## Использование: спавнится `Fireball._explode` после AOE-взрыва как
## «остаточный огонь» — догоняет тех, кто пережил основной damage и
## остался стоять в эпицентре. По образцу Slam-AOE: тот же
## `Layers.MASK_HAND_SLAM`, тот же per-target иммунитет, тот же FAR-fallback
## по `Skeleton.SKELETON_GROUP`.
##
## Урон **без falloff** — внутри зоны равномерно (горение не зависит от
## дистанции до центра). Knockback не применяется — горение не толкает.

@export var debug_log: bool = true

var _radius: float = 1.5
var _damage_per_tick: float = 8.0
var _tick_interval: float = 0.5
var _duration: float = 3.0
var _mask: int = Layers.MASK_HAND_SLAM

var _elapsed: float = 0.0
var _next_tick_at: float = 0.0
var _ticks_done: int = 0

## Свойство для FogOfWar.FOG_REVEAL_GROUP — рассеивание тумана в радиусе ×1.5
## пока зона горит. По окончании duration BurnPatch queue_free'ится → автоматически
## выходит из группы, область начинает зарастать туманом через CPU-decay.
var fog_reveal_radius: float = 1.5

@onready var _disk: MeshInstance3D = get_node_or_null("Disk") as MeshInstance3D


func setup(
	radius: float,
	damage_per_tick: float,
	tick_interval: float,
	duration: float,
	mask: int = Layers.MASK_HAND_SLAM,
) -> void:
	_radius = radius
	_damage_per_tick = damage_per_tick
	_tick_interval = tick_interval
	_duration = duration
	_mask = mask
	fog_reveal_radius = radius * 5.0
	# Первый тик через interval, а не сразу: основной взрыв уже нанёс
	# damage в этом же кадре, повторный мгновенный тик — явный double-hit.
	_next_tick_at = tick_interval


func _ready() -> void:
	# Подгоняем визуальный диск под фактический radius. Mesh в .tscn —
	# CylinderMesh с radius=0.5 (см. VISUAL_BASE_RADIUS), масштабируем.
	if _disk != null:
		_disk.scale = Vector3(_radius / 0.5, 1.0, _radius / 0.5)
	# Регистрируемся в FogOfWar — рассеиваем туман пока горим.
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= _duration:
		queue_free()
		return
	if _elapsed >= _next_tick_at:
		_apply_tick()
		_next_tick_at += _tick_interval
		_ticks_done += 1


func _apply_tick() -> void:
	var origin: Vector3 = global_position
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var shape := SphereShape3D.new()
	shape.radius = _radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), origin)
	query.collision_mask = _mask
	query.collide_with_bodies = true
	var results := space.intersect_shape(query, 32)

	var radius_sq: float = _radius * _radius
	# Per-target иммунитет в одном тике: цель из broad-phase не должна
	# повторно прийти из FAR-fallback'а (иначе double damage tick'а).
	var affected_set: Array[Node] = []
	var hits: int = 0
	for r in results:
		var collider = r.collider
		if not is_instance_valid(collider):
			continue
		if not Damageable.is_damageable(collider):
			continue
		if Layers.is_hand_immune(collider):
			continue
		# Horizontal-only distance: burn — это пятно на ground'е, центр капсулы
		# скелета на y≈0.9, 3D distance съедал бы ~0.9м эффективного радиуса.
		if _xz_distance_sq((collider as Node3D).global_position, origin) > radius_sq:
			continue
		Damageable.try_damage(collider, _damage_per_tick)
		affected_set.append(collider)
		hits += 1

	# FAR-fallback по группе скелетов — те же скелеты вне broad-phase, что
	# и в Fireball._explode / Slam._perform_slam.
	var far_hits: int = 0
	for n in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		var skel := n as Skeleton
		if skel == null:
			continue
		if skel in affected_set:
			continue
		if skel.get_lod_level() != Skeleton.LodLevel.FAR:
			continue
		if Layers.is_hand_immune(skel):
			continue
		if _xz_distance_sq(skel.global_position, origin) > radius_sq:
			continue
		Damageable.try_damage(skel, _damage_per_tick)
		far_hits += 1

	if debug_log and LogConfig.master_enabled:
		print("[BurnPatch] tick %d: damage %d (FAR %d)" % [_ticks_done, hits + far_hits, far_hits])


func _xz_distance_sq(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return dx * dx + dz * dz
