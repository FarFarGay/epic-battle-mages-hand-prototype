class_name Reflectable
extends RefCounted
## Контракт «отражаемый снаряд» — вражеский проджектайл, который тайминг-парирование
## башни (см. Tower._tick_parry) может развернуть обратно в стрелка. Снаряды живут на
## РАЗНЫХ базах (AoeArrow/GiantStone — баллистика, Fireball меха — homing) и не делят
## наследование, поэтому принадлежность — через GROUP, а сам разворот — через метод
## `reflect(by_pos) -> bool` на каждом снаряде (своя баллистика/homing).
##
## Снаряд ОБЯЗАН:
##   - В _ready() (или при спавне врагом) позвать `Reflectable.register(self)`.
##   - Иметь `func reflect(reflector_pos: Vector3) -> bool` — развернуть себя в
##     ближайшего врага, стать дружественным (бить ENEMIES), вернуть true если удалось.
##   - После успешного reflect снять себя с GROUP (нельзя отразить дважды) и встать
##     в `player_projectile` (мех будет уворачиваться от собственного отражённого шота).
##
## Игрок отражает через единую точку: `Reflectable.try_reflect(node, tower_pos)`.

const GROUP := &"hostile_projectile"


## Пометить снаряд как отражаемый. Врага-снаряд зовёт в _ready / при спавне.
static func register(node: Node) -> void:
	node.add_to_group(GROUP)


## True, если объект — отражаемый снаряд (в группе и умеет reflect).
static func is_reflectable(target: Object) -> bool:
	return target is Node and (target as Node).is_in_group(GROUP) and (target as Node).has_method("reflect")


## Отразить снаряд обратно. by_pos — позиция отражающего (башни). Возвращает true,
## если снаряд развернулся (был отражаем и нашёлся враг для самонаведения).
static func try_reflect(target: Object, by_pos: Vector3) -> bool:
	if not is_reflectable(target):
		return false
	return (target as Node).reflect(by_pos)


## Куда отражать снаряд: предпочтительно — В СТРЕЛКА (летит «обратно», как и
## задумано), если он ещё жив и враг; иначе ближайший враг (стрелок погиб). Так
## отражённый шот меха не уходит в случайного скелета, что ближе. null если врагов нет.
static func resolve_reflect_target(tree: SceneTree, from_pos: Vector3, shooter: Node) -> Node3D:
	if shooter != null and is_instance_valid(shooter) and shooter is Node3D \
			and shooter.is_in_group(Enemy.ENEMY_GROUP) and Damageable.is_damageable(shooter):
		return shooter as Node3D
	return nearest_enemy(tree, from_pos)


## Ближайший враг к точке (fallback самонаведения, если стрелок погиб).
## Сканирует Enemy.ENEMY_GROUP (скелеты/мех/гиганты). null если врагов нет.
static func nearest_enemy(tree: SceneTree, from_pos: Vector3, max_dist: float = 300.0) -> Node3D:
	if tree == null:
		return null
	var best: Node3D = null
	var best_sq: float = max_dist * max_dist
	for n in tree.get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var d_sq: float = node.global_position.distance_squared_to(from_pos)
		if d_sq < best_sq:
			best_sq = d_sq
			best = node
	return best
