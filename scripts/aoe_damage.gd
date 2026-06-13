class_name AoeDamage
extends RefCounted
## Утилита однородного sphere-AOE: PhysicsShapeQuery → radius²-filter →
## Damageable.try_damage + опциональный radial push. Покрывает простые
## случаи «равномерный AOE в зоне импакта» — [GiantStone], [Mine], будущие
## подобные снаряды.
##
## НЕ покрывает falloff-механики ([HandPhysicalSlam], [Fireball], [BurnPatch])
## — у них specific falloff-кривые + FAR-LOD fallback по SKELETON_GROUP.
## Если придётся унифицировать и их, расширим API: добавим параметр
## `falloff_fn: Callable` или enum {NONE, LINEAR, SQRT}. Пока fallback'и
## специфичны (skeleton FAR-LOD perf-оптимизация), их не выносим.
##
## Использование:
##     AoeDamage.apply_uniform(get_tree(), pos, 4.0, 868, 50.0, 4.0, 0.3)


## Применить sphere-AOE в `center` радиусом `radius`. Каждому Damageable
## в зоне — `damage` через `Damageable.try_damage`. Если `push_speed>0`,
## каждому Pushable — radial push от центра наружу через `Pushable.try_push`.
##
## Параметры:
## - tree: SceneTree (для get_world_3d → direct_space_state)
## - center: точка взрыва
## - radius: радиус AOE-зоны (м)
## - collision_mask: маска физ-слоёв (Layers.MASK_*)
## - damage: единый damage всем в зоне (без falloff)
## - push_speed: магнитуда radial push'а (м/с). 0 = без push
## - push_duration: длительность push'а (с)
## - max_results: cap на intersect_shape (default 64)
##
## Возвращает массив затронутых Damageable-нод — caller может использовать
## для исключения двойного hit'а из FAR-fallback'а или статистики.
static func apply_uniform(
	tree: SceneTree,
	center: Vector3,
	radius: float,
	collision_mask: int,
	damage: float,
	push_speed: float = 0.0,
	push_duration: float = 0.0,
	max_results: int = 64,
	hitstop: float = 0.0,
) -> Array[Node]:
	var hits: Array[Node] = []
	if tree == null:
		return hits
	if damage <= 0.0 and push_speed <= 0.0:
		return hits
	# Берём world из root viewport'а — RefCounted не Node, своего world нет.
	var root_viewport: Viewport = tree.root if tree.root != null else null
	var world: World3D = root_viewport.world_3d if root_viewport != null else null
	if world == null:
		return hits
	var space := world.direct_space_state
	if space == null:
		return hits
	var shape := SphereShape3D.new()
	shape.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = collision_mask
	query.transform = Transform3D(Basis(), center)
	var results: Array = space.intersect_shape(query, max_results)
	var r_sq: float = radius * radius
	for hit in results:
		var collider = hit.get("collider")
		if collider == null or not is_instance_valid(collider):
			continue
		# Godot 4.6 PhysicsShapeQuery подмешивает AABB-broadphase результаты
		# вне sphere — explicit radius² filter обязателен (паттерн из
		# DefenderGnome/OctagonTurret/Skeleton AoE).
		# КРУПНЫЕ цели (башня, харвистер-ядро): фильтр по дистанции до ЦЕНТРА
		# отсекал бы их — взрыв рвётся у их края, центр дальше radius, хотя
		# коллайдер реально перекрывает сферу (потому query их и нашёл). Цель
		# объявляет reach (`get_attack_reach_bonus` ≈ её радиус) — прибавляем к
		# radius, как Skeleton/Enemy.target_reach_bonus. 0 для обычных целей.
		if collider is Node3D:
			var reach: float = 0.0
			if collider.has_method(&"get_attack_reach_bonus"):
				reach = collider.get_attack_reach_bonus()
			var eff: float = r_sq if reach <= 0.0 else (radius + reach) * (radius + reach)
			var d_sq: float = (collider.global_position - center).length_squared()
			if d_sq > eff:
				continue
		var damaged := false
		if damage > 0.0 and Damageable.is_damageable(collider):
			Damageable.try_damage(collider, damage, hitstop)
			damaged = true
		if push_speed > 0.0 and Pushable.is_pushable(collider):
			var dir := Vector3.ZERO
			if collider is Node3D:
				dir = collider.global_position - center
			dir.y = 0.0
			if dir.length_squared() > 0.001:
				dir = dir.normalized()
				Pushable.try_push(collider, dir * push_speed, push_duration)
		if damaged:
			hits.append(collider)
	return hits
