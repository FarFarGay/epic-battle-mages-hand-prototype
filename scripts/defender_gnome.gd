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

## ENEMIES + COLD_ENEMY = 144. Видим и горячих, и холодных скелетов.
## Используем литерал — `const` не может ссылаться на другой class const.
const TARGET_MASK: int = 16 | 128

var _attack_timer: float = 0.0
var _projectiles_root: Node = null


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


## Override базы: тот же скелет _physics_process, но в активной фазе вместо
## _tick_searching/_tick_commuting вызываем _defender_combat_tick — стой и стреляй.
## RETURNING_TO_TENT идёт через _tick_returning базы (домой при свёртке лагеря).
## Дублирование с Gnome._physics_process намеренное — пока подклассов один,
## вынос «structural skeleton» в виртуальный hook был бы преждевременной
## абстракцией; при появлении третьего типа гнома — рефакторим.
func _physics_process(delta: float) -> void:
	if _camp == null:
		return

	if _state == State.IN_TENT:
		if is_instance_valid(_home_tent):
			global_position = _home_tent.global_position
		return

	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	_knockback.tick(delta)
	if _knockback.is_active():
		velocity = _knockback.apply_friction(velocity, delta)
	else:
		match _state:
			State.RETURNING_TO_TENT:
				_tick_returning()
			_:
				# SEARCHING / COMMUTING_* / IDLE — для защитника всё это
				# означает «активен у лагеря», логика одна: стрелять.
				_defender_combat_tick(delta)

	move_and_slide()


## Стой на месте (velocity.x/z = 0), тикай таймер, при его истечении ищи цель
## и стреляй. После выстрела — новый случайный интервал.
func _defender_combat_tick(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_attack_timer -= delta
	if _attack_timer > 0.0:
		return
	var target := _find_skeleton_target()
	if target != null:
		_fire_at(target)
		_attack_timer = randf_range(attack_cooldown_min, attack_cooldown_max)
	else:
		# Цели нет — проверяем чаще, чтобы реагировать на появившегося скелета
		# быстрее минимального cooldown'а.
		_attack_timer = 0.2


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
