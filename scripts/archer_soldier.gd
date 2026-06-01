class_name ArcherSoldier
extends SoldierGnome
## Гном-лучник: член Squad'а, как и копейщик, но дальний бой.
## Стоит, наводится на цель в [member attack_range], стреляет стрелами
## на cooldown'е. Подходит ближе если цель в [member enemy_detect_radius],
## но за пределами [member attack_range].
##
## Архитектурно — sibling класса pikeman'а (оба extends SoldierGnome).
## Squad-плумб'инг (set_squad, _strict_arrived_at_slot, _resolve_squad_center,
## _find_target_in_leash, _move_toward) наследуется как есть. Переопределён
## только `_active_tick` — вместо charge state machine'а stand-and-shoot.
##
## Прокачка точности — per-instance счётчик `_shots_fired`, теряется на
## смерти. Дизайн: «храни ветеранов».

@export_group("Archer combat")
## Скорость стрелы (м/с).
@export var arrow_speed: float = 22.0
## Откуда вылетает стрела относительно центра гнома (поднимаем над головой,
## чтобы не задеть собственный корпус коллизией стрелы при выстреле).
@export var arrow_spawn_offset: Vector3 = Vector3(0, 0.6, 0)
@export var arrow_scene: PackedScene
## Куда складывать спавн стрел (чтобы они пережили смерть/уход самого гнома).
## Пусто → fallback на current_scene.
@export_node_path("Node") var projectiles_root_path: NodePath
@export_group("")

## attack_range / attack_damage_min/max / attack_cooldown_min/max наследуются
## от SoldierGnome — у лучника просто другие значения (range=22.5 vs 2.2 у
## копейщика). Семантика поля «дистанция в которой бьём по цели» одна и та же,
## значения приходят из SOLDIER_CATALOG.stats через setup_soldier.

@export_group("Archer accuracy")
## Стартовый радиус разброса прицела (метры). Новички мажут, ветераны бьют
## точнее. Формула: inaccuracy = base / (1 + shots/half_shots).
@export var base_inaccuracy_radius: float = 0.4
@export var experience_half_shots: int = 100
@export_group("")

## Per-soldier счётчик выстрелов для расчёта точности. Теряется на смерть
## (новый ArcherSoldier стартует с 0).
var _shots_fired: int = 0
var _projectiles_root: Node = null
## Текущая цель для approach'а — если есть цель в leash но вне attack_range,
## идём к ней. Запоминаем на тик, чтобы не пересчитывать сканом каждый шаг.
var _approach_target: Node3D = null


func _ready() -> void:
	super._ready()
	if not projectiles_root_path.is_empty():
		_projectiles_root = get_node_or_null(projectiles_root_path)
	if _projectiles_root == null:
		_projectiles_root = get_tree().current_scene


## Override базового AI копейщика. Stand-and-shoot вместо charge.
## Приоритеты:
##   1. Strict-march HOLD: дойти до слота, по дороге combat-assist если враг
##      попал в attack_range (так же как pikeman lunge'ит проходящих скелетов).
##   2. Цель в attack_range + cd готов → выстрел, велocity=0.
##   3. Цель в leash но вне attack_range → подходим ближе.
##   4. Нет цели — squad-positioning (HOLD/ESCORT/DEFEND).
func _active_tick(delta: float) -> void:
	if _attack_cd > 0.0:
		_attack_cd -= delta

	# Strict-march: дойти до слота. Combat-assist по пути — стрельба в врага
	# в attack_range без остановки strict-марша (стоим стреляем, потом идём).
	if _squad != null and _camp != null \
			and _squad.state == Squad.State.HOLDING_POSITION \
			and _squad.is_strict_move() \
			and not _strict_arrived_at_slot:
		if _try_fire_at_target_in_range():
			return
		var goal_strict: Vector3 = _squad.target_for_member(self, _resolve_squad_center())
		var to_goal_strict := Vector3(goal_strict.x - global_position.x, 0.0, goal_strict.z - global_position.z)
		var dist_strict: float = to_goal_strict.length()
		if dist_strict > SQUAD_TARGET_ARRIVAL:
			_move_toward(to_goal_strict, dist_strict)
			return
		_strict_arrived_at_slot = true

	# Combat-приоритет: цель в attack_range + cd готов → выстрел.
	if _try_fire_at_target_in_range():
		return

	# Цель в leash но вне attack_range → подходим (но не дальше leash).
	# enemy_detect_radius используем как «вижу» (наследуется от SoldierGnome).
	var pursue_target: Node3D = _find_target_in_leash()
	if pursue_target != null:
		var to_pursue := Vector3(
			pursue_target.global_position.x - global_position.x,
			0.0,
			pursue_target.global_position.z - global_position.z,
		)
		var pursue_dist: float = to_pursue.length()
		if pursue_dist > attack_range:
			_move_toward(to_pursue, pursue_dist)
			return

	# Нет цели — squad-positioning (как у pikeman'а).
	if _squad == null or _camp == null:
		velocity = Vector3.ZERO
		return
	if _squad.state == Squad.State.DEFENDING_CAMP:
		_tick_defend_patrol()
		return
	var goal: Vector3 = _squad.target_for_member(self, _resolve_squad_center())
	var to_goal_xz := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	var dist: float = to_goal_xz.length()
	if dist <= SQUAD_TARGET_ARRIVAL:
		velocity = Vector3.ZERO
		return
	_move_toward(to_goal_xz, dist)


## True если есть цель в attack_range и cd готов — стреляет, ставит cd,
## возвращает true. Иначе false.
func _try_fire_at_target_in_range() -> bool:
	if _attack_cd > 0.0:
		return false
	var target: Node3D = _find_target_in_leash()
	if target == null:
		return false
	var to_t := Vector3(
		target.global_position.x - global_position.x,
		0.0,
		target.global_position.z - global_position.z,
	)
	var dist: float = to_t.length()
	if dist > attack_range:
		return false
	# Face target + fire.
	if dist > VecUtil.EPSILON_SQ:
		look_at(global_position + (to_t / dist), Vector3.UP)
	velocity = Vector3.ZERO
	_fire_at(target)
	_attack_cd = randf_range(attack_cooldown_min, attack_cooldown_max)
	return true


## Текущий радиус разброса с учётом опыта. Логарифмическая кривая.
func current_inaccuracy_radius() -> float:
	if base_inaccuracy_radius <= 0.0 or experience_half_shots <= 0:
		return base_inaccuracy_radius
	return base_inaccuracy_radius / (1.0 + float(_shots_fired) / float(experience_half_shots))


func get_shots_fired() -> int:
	return _shots_fired


## Публичный API для squad-ult'ы (volley): спавнит стрелу с прицелом на
## точку. Без inaccuracy-разброса (волей задаёт собственный scatter через
## разные aim_pos для каждой стрелы). Squad-charge НЕ добавляется (это
## расход charge'а, не накопление).
func volley_fire_at(aim_pos: Vector3, dmg: float) -> void:
	if arrow_scene == null:
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		return
	if not is_instance_valid(_projectiles_root):
		_projectiles_root = get_tree().current_scene
	_projectiles_root.add_child(arrow)
	arrow.damage = dmg
	arrow.speed = arrow_speed
	arrow.setup(global_position + arrow_spawn_offset, aim_pos)


## Спавнит стрелу с разбросом по uniform-в-круге. Опыт +1 на каждый выстрел.
## Squad-charge +1 за выстрел (вместо per-kill как у pikeman'а — у лучника
## kill-credit'а нет, Arrow не знает стрелка). Дизайн: charge_max лучника
## выше чем у pikeman'а, цикл выстрелов чаще.
func _fire_at(target: Node3D) -> void:
	if arrow_scene == null:
		push_warning("[ArcherSoldier:%s] arrow_scene не задан" % name)
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		push_warning("[ArcherSoldier:%s] arrow_scene не инстанцируется как Arrow" % name)
		return
	if not is_instance_valid(_projectiles_root):
		_projectiles_root = get_tree().current_scene
	_projectiles_root.add_child(arrow)
	var damage: float = randf_range(attack_damage_min, attack_damage_max)
	var spawn := global_position + arrow_spawn_offset
	var inaccuracy: float = current_inaccuracy_radius()
	var aim_pos: Vector3 = target.global_position
	if inaccuracy > 0.0:
		var angle: float = randf() * TAU
		var r: float = sqrt(randf()) * inaccuracy
		aim_pos.x += cos(angle) * r
		aim_pos.z += sin(angle) * r
	arrow.damage = damage
	arrow.speed = arrow_speed
	arrow.setup(spawn, aim_pos)
	_shots_fired += 1
	if _squad != null:
		_squad.add_charge(1.0)
	if debug_log and LogConfig.master_enabled:
		print("[ArcherSoldier:%s] выстрел в %s (dmg=%.1f, shots=%d)" % [name, target.name, damage, _shots_fired])
