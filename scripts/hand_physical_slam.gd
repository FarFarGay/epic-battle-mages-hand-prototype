class_name HandPhysicalSlam
extends Node
## Slam (хлопок по земле) — physical-категория, AOE-разлёт через PhysicsShapeQueryParameters3D.
## Триггерится координатором PhysicalActions, когда `equipped == SLAM` и нажата ПКМ.
##
## Связь с Hand устанавливается через setup(hand, coord) от координатора —
## никаких get_parent()-цепочек.

signal slammed(position: Vector3, radius: float)

const SLAM_VISUAL_POOL_CAP: int = 3
## SDF-noise dissolve в slam_distortion.gdshader работает с предположением,
## что mesh — sphere unit-radius'а 0.5 в локальных координатах:
## `sphere_dist = length(object_position) - 0.5`. Если SphereMesh имеет
## другой radius (например 0.2), `length(object_position)` ≤ 0.2, sphere_dist
## всегда отрицательная и далеко от нуля → `dissolve_alpha = 0` → весь
## шейдер прозрачный. Поэтому держим 0.5/1.0 (radius/height) и компенсируем
## размер через mesh.scale (target_scale = slam_radius / 0.5 = 10 при slam_radius=5).
const SLAM_VISUAL_BASE_RADIUS: float = 0.5
const SLAM_VISUAL_BASE_HEIGHT: float = 1.0
const SLAM_VISUAL_TWEEN_DURATION: float = 0.45
const SLAM_DISTORTION_MATERIAL_PATH: String = "res://resources/slam_distortion_material.tres"
## Пыль при ударе: GPUParticles3D one-shot, разлёт радиально вверх.
## Дефолтные ассеты — общие для всех slam'ов (process_material детерминирован
## без параметров от инстанса), не нужно дублировать на каждый шлепок.
const SLAM_DUST_MATERIAL_PATH: String = "res://resources/slam_dust_material.tres"
const SLAM_DUST_PROCESS_PATH: String = "res://resources/slam_dust_process.tres"
const SLAM_DUST_AMOUNT: int = 72
const SLAM_DUST_LIFETIME: float = 0.9
const SLAM_DUST_QUAD_SIZE: float = 0.22

class SlamHit:
	extends RefCounted
	var direction: Vector3
	var falloff: float

	func _init(d: Vector3, f: float) -> void:
		direction = d
		falloff = f


@export_group("Balance")
## Slam — физическая utility-способность («сбить с ног»), не основной
## damage-инструмент. Магия (Fireball/Firestorm) должна давать больше
## урона, иначе бесплатный slam с коротким cd обесценивает заклинания.
## Баланс 2026-05-10: radius 5→3.5 (как Fireball L0), damage 60→25
## (≤Fireball L0=35, но slam без mana и с сильным knockback'ом),
## cooldown 0.5→0.7. Knockback не трогаем — это основная роль slam'а.
@export var slam_radius: float = 3.5
@export var slam_force: float = 30.0
@export var slam_lift_factor: float = 0.4
## Базовый урон в эпицентре. С линейным falloff'ом fall(d) = 1 − d/radius
## фактический урон = slam_damage × fall. На skeleton hp=30:
##   - d=0 → 25 dmg, не убивает с одного шлепка (даже в эпицентре);
##   - 2 шлепка по упавшему врагу = 50 dmg → kill.
## Slam теперь «оглушил + добил» вместо «прибил с одного раза».
@export var slam_damage: float = 25.0
@export var slam_cooldown: float = 0.7
## По каким слоям бьёт хлопок (`Layers.MASK_HAND_SLAM = 438` = Items + Actors +
## Enemies + CampObstacle + ColdEnemy + FriendlyUnit). Бьёт всех, кого рука
## вообще «видит» как мишень: и врагов, и дружественных гномов, и палатки.
## Per-target иммунитет — через группу `hand_immune` (см. `Layers.is_hand_immune`).
## MOUNTED_MODULE сюда НЕ входит — снять модуль со слота можно только хватом
## руки, не AOE-хлопком.
@export_flags_3d_physics var slam_mask: int = Layers.MASK_HAND_SLAM
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
	# Shared radius² для обоих циклов: основного (broad-phase results) и
	# FAR-fallback'а (group SKELETON_GROUP) ниже.
	var slam_radius_sq: float = slam_radius * slam_radius
	for r in results:
		var collider = r.collider
		if not Damageable.is_damageable(collider):
			continue
		# Per-target иммунитет: дизайнер помечает конкретный инстанс группой
		# `hand_immune` (через editor'а или add_to_group), и slam/flick/grab
		# его не трогают — даже если он по слою попал в shape-query.
		if Layers.is_hand_immune(collider):
			continue
		# Только пойманный рукой собственный Item исключаем — чтобы хлопок не
		# толкал свой же ящик. Прочие freeze=true RigidBody (декорации/динамика)
		# теперь нормально получают damage; push на них всё равно будет no-op
		# (Item.apply_push вернёт ранний return при freeze).
		if collider == held:
			continue
		# Explicit radius check: Godot 4.6 PhysicsShapeQuery подмешивает результаты
		# AABB-broadphase вне самой sphere-формы. Тот же паттерн что и в
		# OctagonTurret._find_target и DefenderGnome._scan_cone — единая защита
		# для всех sphere-query во всём проекте. Falloff-чек ниже всё равно
		# отсёк бы такой результат (linear falloff = 0 на radius), но явный
		# guard понятнее и совпадает с конвенцией.
		if (collider.global_position - origin).length_squared() > slam_radius_sq:
			continue
		var hit := _slam_direction_and_falloff(collider.global_position, origin)
		if hit.falloff <= 0.0:
			continue
		var velocity_change: Vector3 = hit.direction * slam_force * hit.falloff
		Pushable.try_push(collider, velocity_change, slam_knockback_duration)
		Damageable.try_damage(collider, slam_damage * hit.falloff)
		affected_count += 1

	# FAR-LOD скелеты отключены от broad-phase (CollisionShape3D.disabled=true,
	# нужно для перфоманса на 2000+ скелетах) и не попадают в `results` выше.
	# Догоняем их отдельным проходом по группе SKELETON_GROUP с дистанционным
	# фильтром. NEAR/MID-скелетов в группе тоже много, но они уже обработаны
	# через PhysicsShapeQuery — пропускаем по `_lod_level`. На 2000 скелетах
	# проход — 2000 distance_squared-операций, ~0.05мс, на фоне slam-cooldown 0.5с.
	var far_hits := 0
	for n in _hand.get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		var skel := n as Skeleton
		if skel == null:
			continue
		if skel.get_lod_level() != Skeleton.LodLevel.FAR:
			continue
		# Per-target иммунитет также применяется к FAR-fallback: на всякий случай,
		# если дизайнер пометит конкретный скелет (босс? сюжетный NPC?) `hand_immune`.
		if Layers.is_hand_immune(skel):
			continue
		var d_sq: float = (skel.global_position - origin).length_squared()
		if d_sq > slam_radius_sq:
			continue
		var hit := _slam_direction_and_falloff(skel.global_position, origin)
		if hit.falloff <= 0.0:
			continue
		var vc: Vector3 = hit.direction * slam_force * hit.falloff
		Pushable.try_push(skel, vc, slam_knockback_duration)
		Damageable.try_damage(skel, slam_damage * hit.falloff)
		far_hits += 1
	affected_count += far_hits

	if debug_log and LogConfig.master_enabled:
		print("[Hand:Physical:Slam] хлопок @ (%.1f, %.1f, %.1f), задело: %d (из них FAR: %d)" % [origin.x, origin.y, origin.z, affected_count, far_hits])

	_spawn_slam_visual(origin)
	_spawn_slam_dust(origin)
	slammed.emit(origin, slam_radius)


func _slam_direction_and_falloff(target_pos: Vector3, origin: Vector3) -> SlamHit:
	var to_target: Vector3 = target_pos - origin
	var horizontal_dist := Vector2(to_target.x, to_target.z).length()
	# Falloff sqrt-curve: тот же что у fireball'а — единый «маг-feel». На 50%
	# радиуса остаётся 71% damage'а вместо 50% (linear).
	var falloff_linear: float = clampf(1.0 - horizontal_dist / slam_radius, 0.0, 1.0)
	var falloff: float = sqrt(falloff_linear)
	if falloff <= 0.0:
		return SlamHit.new(Vector3.UP, 0.0)
	var horizontal_dir := VecUtil.horizontal(to_target)
	if horizontal_dir.length_squared() < VecUtil.EPSILON_SQ:
		horizontal_dir = Vector3.UP
	else:
		horizontal_dir = horizontal_dir.normalized() + Vector3.UP * slam_lift_factor
		horizontal_dir = horizontal_dir.normalized()
	return SlamHit.new(horizontal_dir, falloff)


## Спавнит сферу с distortion-шейдером (resources/slam_distortion.gdshader) в
## точке шлепка. Материал — per-instance копия base'ового, чтобы tween'ить
## shader_parameter'ы независимо у параллельных slam'ов из пула. Tween'им три
## параметра одновременно через SLAM_VISUAL_TWEEN_DURATION:
##   - mesh.scale: 1 → slam_radius/sphere.radius (расширение пузыря)
##   - shader.intensity: 1 → 0 (общая прозрачность + сила blur'а / chromatic /
##     accretion / fresnel — все эти эффекты в шейдере умножены на intensity)
##   - shader.ripple_time: 0 → 1 (волна разбегается изнутри: dist*frequency -
##     ripple_time*speed → бегущий sin; затухание exp(-dist*fade)*(1-time))
## Также передаём ripple_center=pos в WORLD-координатах — шейдер считает дистанцию
## от world_position фрагмента до этой точки, поэтому центр волны не смещается
## вместе с растущей сферой.
func _spawn_slam_visual(pos: Vector3) -> void:
	var mesh: MeshInstance3D
	var sphere: SphereMesh
	var mat: ShaderMaterial

	# Чистим пул от freed-меш'ей до reuse — могли исчезнуть вместе со сценой.
	while not _slam_visual_pool.is_empty() and not is_instance_valid(_slam_visual_pool.back()):
		_slam_visual_pool.pop_back()
	if not _slam_visual_pool.is_empty():
		mesh = _slam_visual_pool.pop_back()
		sphere = mesh.mesh as SphereMesh
		mat = mesh.material_override as ShaderMaterial
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

		# Per-instance копия — иначе tween'ы из пула затопчут друг друга.
		var base_mat := load(SLAM_DISTORTION_MATERIAL_PATH) as ShaderMaterial
		if base_mat == null:
			push_error("[Slam] не загрузился slam_distortion_material.tres — fallback на StandardMaterial3D невозможен")
			return
		mat = base_mat.duplicate() as ShaderMaterial
		mesh.material_override = mat
		_effects_root.add_child(mesh)

	mesh.global_position = pos

	# Сбрасываем shader_parameter'ы к стартовым: пузырь только-только появился.
	mat.set_shader_parameter("intensity", 1.0)
	mat.set_shader_parameter("ripple_time", 0.0)
	mat.set_shader_parameter("ripple_center", pos)

	var target_scale: float = slam_radius / sphere.radius
	var tween := mesh.create_tween()
	tween.set_parallel(true)
	tween.tween_property(mesh, "scale", Vector3.ONE * target_scale, SLAM_VISUAL_TWEEN_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# intensity 1→0: master-control шейдера. Затухает плавно (CUBIC), чтобы
	# blur/chromatic/accretion не отрубались резко в последний кадр.
	tween.tween_method(_set_slam_param.bind(mat, "intensity"), 1.0, 0.0, SLAM_VISUAL_TWEEN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	# ripple_time 0→1: волна разбегается линейно, на 1.0 шейдер сам гасит
	# (умножение на (1-ripple_time)).
	tween.tween_method(_set_slam_param.bind(mat, "ripple_time"), 0.0, 1.0, SLAM_VISUAL_TWEEN_DURATION).set_trans(Tween.TRANS_LINEAR)
	tween.finished.connect(_recycle_slam_visual.bind(mesh))


## Сеттер shader_parameter'а через Tween.tween_method — нужен потому что
## tween_property не умеет в shader_parameter'ы (их пишут через set_shader_parameter,
## не через property path). bind(mat, name) фиксирует материал и имя параметра.
##
## Tween создаётся mesh.create_tween() — он привязан к mesh'у и автоматически
## останавливается, когда mesh выходит из дерева. Но если HandPhysicalSlam
## (self) уйдёт из сцены до конца tween'а (рестарт сцены, владелец freed) —
## bind(self.method) указывает на освобождённый объект. is_instance_valid(mat)
## ловит и этот случай, и обычное «материал освобождён» — тогда тихо выходим.
func _set_slam_param(value: float, mat: ShaderMaterial, param_name: String) -> void:
	if mat == null or not is_instance_valid(mat):
		return
	mat.set_shader_parameter(param_name, value)


func _recycle_slam_visual(mesh: MeshInstance3D) -> void:
	# Если HandPhysicalSlam уже free'нут (рестарт сцены mid-tween), Callable
	# на этот метод тихо проигнорируется самой Godot. Если жив — обычная
	# обработка с гардом на mesh.
	if not is_instance_valid(mesh):
		return
	if _slam_visual_pool.size() < SLAM_VISUAL_POOL_CAP:
		mesh.visible = false
		_slam_visual_pool.append(mesh)
	else:
		mesh.queue_free()


func _exit_tree() -> void:
	# Чистим пул: meshes были добавлены в _effects_root (current_scene), а не
	# в self — они переживут наш free и осядут до конца сцены. queue_free на
	# выходе чтобы не держать invisible-инстансы вечно (на рестарте сцены
	# current_scene всё равно сбросится, но в случае ручного reload — поможет).
	for mesh in _slam_visual_pool:
		if is_instance_valid(mesh):
			mesh.queue_free()
	_slam_visual_pool.clear()


## Пыль при ударе — fire-and-forget GPUParticles3D one-shot. Без пула:
## slam_cooldown=0.5с, lifetime пыли=0.7с — максимум 2 одновременно живых
## партикл-узла, новый создаётся реже чем старый завершается. Overhead на
## создание GPUParticles3D в разы меньше чем смысла усложнять пулом.
##
## Mesh — простой QuadMesh, billboard через material (StandardMaterial3D
## billboard_mode=ENABLED). Частицы летят радиально (spread=80° от
## direction Y) с быстрой стартовой скоростью (3.5..6.5 м/с) и затухают
## damping'ом + гравитацией — выглядит как разлетевшаяся пыль от удара.
func _spawn_slam_dust(pos: Vector3) -> void:
	if _effects_root == null:
		return
	var process_mat := load(SLAM_DUST_PROCESS_PATH) as ParticleProcessMaterial
	var dust_mat := load(SLAM_DUST_MATERIAL_PATH) as StandardMaterial3D
	if process_mat == null or dust_mat == null:
		push_error("[Slam] dust assets не загрузились")
		return

	var quad := QuadMesh.new()
	quad.size = Vector2(SLAM_DUST_QUAD_SIZE, SLAM_DUST_QUAD_SIZE)

	var particles := GPUParticles3D.new()
	particles.process_material = process_mat
	particles.draw_pass_1 = quad
	particles.material_override = dust_mat
	particles.amount = SLAM_DUST_AMOUNT
	particles.lifetime = SLAM_DUST_LIFETIME
	particles.one_shot = true
	# explosiveness=1.0 — все частицы спавнятся в первом кадре (один взрыв
	# пыли), а не размазываются по lifetime'у как у непрерывного эмиттера.
	particles.explosiveness = 1.0
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_effects_root.add_child(particles)
	particles.global_position = pos
	particles.emitting = true

	# Чистим через таймер. lifetime + небольшой запас на anim'у scale_curve до 0.
	# WeakRef обходит Godot 4.6 «Lambda capture at index 0 was freed» — при
	# смене сцены / manual free particles до timeout'а engine печатает warning
	# до входа в лямбду, гард is_instance_valid не успевает.
	var cleanup_delay: float = SLAM_DUST_LIFETIME + 0.2
	var particles_ref: WeakRef = weakref(particles)
	_hand.get_tree().create_timer(cleanup_delay).timeout.connect(func() -> void:
		var p: Node = particles_ref.get_ref()
		if p != null:
			p.queue_free()
	)
