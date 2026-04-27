class_name DefenderGnome
extends Gnome
## Гном-защитник. Подкласс Gnome, переопределяющий «активный» AI: вместо
## поиска куч ресурсов стоит у палатки и стреляет стрелами в скелетов в
## радиусе attack_radius. Урон рандомизирован — на skeleton.hp=30 даёт 1
## выстрел убивает в большинстве попаданий, иногда нужно 2.
##
## Базовая логика гнома (привязка к палатке через setup, IN_TENT-приклейка,
## RETURNING_TO_TENT при request_return от Camp, take_damage / apply_push,
## smith-эффект на смерть) наследуется как есть. Цвет красный задан в
## defender_gnome.tscn через override gnome_color.
##
## Не двигается «на цели» — стоит на той точке, где его поставил Camp при
## развёртке (_start_deploy сажает гнома в позицию палатки, далее enter_deployed
## не двигает; в обычном Gnome это позиция стартового SEARCHING-патруля,
## у защитника патруль выключен — стоит).

@export_group("Defender combat")
## Радиус сканирования скелетов через PhysicsShapeQuery. Маска включает
## ColdEnemy — иначе при отзумленной камере все скелеты (LOD=FAR) становятся
## фантомами и защитник перестаёт реагировать.
@export var attack_radius: float = 15.0
## Случайный интервал между выстрелами. Не строгий метроном — несколько
## защитников в одной палатке не залпуют синхронно.
@export var attack_cooldown_min: float = 0.6
@export var attack_cooldown_max: float = 1.2
## Урон рандомизирован: при skeleton.hp=30 диапазон 25..40 даёт 1-shot kill
## в ~66% случаев (damage > 30) и 2-shot в остальных. «Чаще за 1 выстрел».
@export var arrow_damage_min: float = 25.0
@export var arrow_damage_max: float = 40.0
@export var arrow_speed: float = 22.0
## Откуда вылетает стрела относительно центра гнома (поднимаем над головой,
## чтобы не задеть собственный корпус коллизией стрелы при выстреле).
@export var arrow_spawn_offset: Vector3 = Vector3(0, 0.6, 0)
@export var arrow_scene: PackedScene
## Куда складывать спавн стрел (чтобы они пережили смерть/уход самого гнома).
## Пусто → fallback на current_scene.
@export_node_path("Node") var projectiles_root_path: NodePath
@export_group("")

@export_group("Defender patrol")
## Радиус патруля от центра лагеря (`Camp.deploy_anchor`). Палатки стоят
## на `Camp.deploy_radius=4`, защитник на 6 — это «вне палаток», как
## стража на внешнем контуре. Если у Camp нет valid anchor'а, защитник
## стоит на стартовой позиции (палатке).
@export var patrol_radius: float = 6.0
## Скорость шага во время патруля. Меньше move_speed=1.6 — стража движется
## размеренно, не суетится.
@export var patrol_speed: float = 1.0
## Дистанция до patrol-точки, чтобы выбрать новую (или после прибытия).
@export var patrol_arrival: float = 0.6
@export_group("")

## ENEMIES + COLD_ENEMY = 144. Видим и горячих, и холодных скелетов.
## Используем литерал — `const` не может ссылаться на другой class const.
const TARGET_MASK: int = 16 | 128

## Период между сканами цели через PhysicsShapeQuery. Без throttle'а 54
## защитника на карте делали бы 54×60 = 3240 sphere-query/сек, и на 340+
## скелетах в радиусе 15м это убивало fps (3 FPS на стресс-тесте). С 0.25с
## — 216 query/сек, в 15 раз меньше. Кэшированная цель используется между
## сканами — если она валидна и в радиусе, не пересканируем.
const TARGET_SCAN_INTERVAL: float = 0.25

var _attack_timer: float = 0.0
var _projectiles_root: Node = null
var _patrol_target: Vector3 = Vector3.INF
var _cached_target: Node3D = null
var _target_scan_timer: float = 0.0


func _ready() -> void:
	# super регистрирует Damageable/Pushable, ставит цвет (наш красный override
	# из defender_gnome.tscn), подключает re-emit на EventBus, кэширует _effects_root.
	super._ready()
	if not projectiles_root_path.is_empty():
		_projectiles_root = get_node_or_null(projectiles_root_path)
	if _projectiles_root == null:
		_projectiles_root = get_tree().current_scene
	# Стартовая задержка случайна — 3 защитника в палатке не выстрелят залпом.
	_attack_timer = randf_range(attack_cooldown_min, attack_cooldown_max)
	# Фазовый сдвиг сканера: 54 защитника на карте не должны сканировать в
	# одном кадре — иначе кадровая нагрузка пойдёт волной каждые 0.25с.
	_target_scan_timer = randf() * TARGET_SCAN_INTERVAL


## Override виртуального hook'а Gnome — переопределяем только активную
## AI-логику. Базовый Gnome._physics_process сам решает: hot (move_and_slide)
## или cold (skip физики на FAR-LOD), включает гравитацию и knockback —
## defender автоматически получает всё это. RETURNING_TO_TENT идёт через
## базовый _tick_returning (защитник возвращается домой при свёртке лагеря).
func _active_tick(delta: float) -> void:
	match _state:
		State.RETURNING_TO_TENT:
			_tick_returning()
		_:
			# SEARCHING / COMMUTING_* / IDLE — для защитника всё это
			# означает «активен у лагеря», логика одна: стрелять или
			# патрулировать.
			_defender_combat_tick(delta)


## Скан цели через кэш + throttle (TARGET_SCAN_INTERVAL=0.25с). Сам скан —
## дорогой PhysicsShapeQuery; на 54 защитниках при 60fps без кэша было
## убийство fps. Между сканами используем _cached_target, если она валидна
## и в радиусе. Если цель есть — стоим и стреляем. Нет — охлаждаемся и
## патрулируем по контуру.
func _defender_combat_tick(delta: float) -> void:
	_target_scan_timer -= delta
	# Принудительный пересмотр кэша если цель умерла или вышла за зону —
	# это дешёвые проверки, ради них не стоит ждать таймер.
	var stale: bool = _cached_target == null \
		or not is_instance_valid(_cached_target) \
		or global_position.distance_to(_cached_target.global_position) > attack_radius
	if _target_scan_timer <= 0.0 or stale:
		_cached_target = _find_skeleton_target()
		_target_scan_timer = TARGET_SCAN_INTERVAL

	if _cached_target != null and is_instance_valid(_cached_target):
		# Стой и стреляй: пока есть цель в зоне — на месте.
		velocity.x = 0.0
		velocity.z = 0.0
		_attack_timer -= delta
		if _attack_timer <= 0.0:
			_fire_at(_cached_target)
			_attack_timer = randf_range(attack_cooldown_min, attack_cooldown_max)
	else:
		# Без цели — охлаждаемся и патрулируем.
		_attack_timer = maxf(_attack_timer - delta, 0.0)
		_patrol_tick()


## Патруль по окружности patrol_radius вокруг Camp.deploy_anchor (центра
## лагеря). При достижении точки выбирается новая случайная — лучник ходит
## по внешнему периметру, как стража. Если anchor невалиден (Camp ещё не
## развёрнут или пропал) — стоим на месте.
func _patrol_tick() -> void:
	if _camp == null:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var anchor: Vector3 = _camp.deploy_anchor
	if _patrol_target == Vector3.INF or _horizontal_distance(_patrol_target) < patrol_arrival:
		_patrol_target = _pick_patrol_point(anchor)
	_step_toward(_patrol_target, patrol_speed)


## Случайная точка на окружности patrol_radius вокруг центра лагеря.
## Y берём с anchor'а — палатки стоят на полу, патруль на той же высоте.
func _pick_patrol_point(anchor: Vector3) -> Vector3:
	var angle := randf() * TAU
	return Vector3(
		anchor.x + cos(angle) * patrol_radius,
		anchor.y,
		anchor.z + sin(angle) * patrol_radius,
	)


## Локальный аналог Gnome._move_toward_xz, но с произвольной скоростью:
## защитник патрулирует медленнее (patrol_speed), а Gnome.move_speed
## остаётся для возврата в палатку (через унаследованный _tick_returning).
func _step_toward(target: Vector3, speed: float) -> void:
	var to_target: Vector3 = target - global_position
	to_target.y = 0.0
	if to_target.length_squared() < VecUtil.EPSILON_SQ:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var dir := to_target.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed


## PhysicsShapeQuery со сферой attack_radius. Mask ловит и активных (ENEMIES),
## и LOD-холодных (COLD_ENEMY) скелетов — иначе при отзумленной камере дальние
## стаи становились бы невидимыми для защиты.
func _find_skeleton_target() -> Node3D:
	var space := get_world_3d().direct_space_state
	if space == null:
		return null
	var shape := SphereShape3D.new()
	shape.radius = attack_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), global_position)
	query.collision_mask = TARGET_MASK
	query.collide_with_bodies = true
	var results := space.intersect_shape(query, 32)
	var nearest: Node3D = null
	var nearest_dist := INF
	for r in results:
		var collider = r.collider
		if collider == null or not (collider is Node3D):
			continue
		if not Damageable.is_damageable(collider):
			continue
		var node := collider as Node3D
		var d: float = global_position.distance_to(node.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = node
	return nearest


func _fire_at(target: Node3D) -> void:
	if arrow_scene == null:
		push_warning("DefenderGnome: arrow_scene не задан")
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		push_warning("DefenderGnome: arrow_scene не инстанцируется как Arrow")
		return
	if not is_instance_valid(_projectiles_root):
		_projectiles_root = get_tree().current_scene
	_projectiles_root.add_child(arrow)
	var damage: float = randf_range(arrow_damage_min, arrow_damage_max)
	var spawn := global_position + arrow_spawn_offset
	arrow.damage = damage
	arrow.speed = arrow_speed
	arrow.setup(spawn, target.global_position)
