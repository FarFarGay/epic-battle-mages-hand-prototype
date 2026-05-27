class_name HandSpellMineScatter
extends Node
## Магическая мин-бомбардировка. Прямой залп из башни: N мин-снарядов
## с **Fireball-баллистикой** (boost → homing) вылетают серией со
## stagger'ом, каждый летит в свою точку приземления в круге scatter_radius.
## На impact'е снаряд "explодит" БЕЗ урона, на его месте появляется Mine.
## После arming-delay'я мины ждут жертв. Friendly-fire ON.
##
## Реюзает `Fireball` как доставочный снаряд (тот же `fireball.gd` script,
## тот же flight code что у Firestorm) с двумя отличиями:
##   1. Используется отдельная сцена `mine_projectile.tscn` — поменьше и
##      приглушеннее визуально, чтоб не путать с обычным фаерболом.
##   2. damage=0, explode_mask=0, knockback=0, burn_scene=null —
##      Fireball.gd на impact'е не наносит урона, только эмитит `hit`
##      сигнал и спавнит explosion-VFX. Слушатель (этот класс) на hit'е
##      ставит `Mine` в impact-точке.
##
## Stagger между запусками (`shot_interval` ~60мс) — серия «тра-та-та»,
## а не одновременный залп.
##
## Параметры читаются из SpellSystem.SPELL_CATALOG.mine_scatter с
## fallback'ом на @export.

signal spell_cast(spell_name: StringName, position: Vector3)

@export_group("Scatter")
## Сколько мин в залпе.
@export var mine_count: int = 5
## Радиус разброса landing-точек uniform-в-круге.
@export var scatter_radius: float = 5.0
@export var mine_damage: float = 30.0
@export var mine_aoe_radius: float = 1.8
@export var cooldown: float = 4.0
@export var mana_cost: float = 40.0

@export_group("Volley")
## Высота старта снаряда относительно Tower.
@export var launch_offset_y: float = 3.0
## Задержка между запусками в серии. 0.06с = «тра-та-та».
@export var shot_interval: float = 0.06

@export_group("Projectile flight (как у Firestorm — boost + homing)")
## Параметры boost-фазы (стартовая дуга).
@export var boost_duration: float = 0.18
@export var boost_velocity_up: float = 7.0
@export var boost_velocity_forward: float = 3.0
@export var boost_gravity: float = 14.0
@export var boost_drift_velocity: float = 2.8

## Параметры homing-фазы (полёт в landing-точку).
@export var homing_initial_speed: float = 8.0
@export var homing_acceleration: float = 100.0
@export var homing_max_speed: float = 55.0
@export_range(0.0, 80.0) var homing_drift_angle_deg: float = 45.0
@export_range(1.0, 30.0) var homing_turn_rate: float = 3.5

@export_group("Visual")
## Снаряд-доставщик. Должен быть Fireball-наследником (использует
## fireball.gd script). Дефолт — `mine_projectile.tscn` (поменьше и
## приглушеннее обычного фаербола, чтоб игрок отличал).
@export var projectile_scene: PackedScene
## Сцена мины, которая ставится на impact-точке.
@export var mine_scene: PackedScene

@export_group("Telegraph")
@export var warning_duration: float = 0.9
@export var warning_color: Color = Color(1.0, 0.55, 0.1, 0.7)

@export_group("")
@export var effects_root_path: NodePath
@export var debug_log: bool = true

var _hand: Hand
var _coord: HandSpell
var _effects_root: Node = null
var _cooldown_remaining: float = 0.0
## Зафиксированные параметры серии — серия летит со старыми параметрами
## даже если игрок прокачает заклинание во время неё.
var _series_mine_count: int
var _series_scatter_radius: float
var _series_mine_damage: float
var _series_mine_aoe_radius: float
## Очередь landing-точек: каждая — целевая позиция одного снаряда серии.
var _landing_queue: Array[Vector3] = []
## Время до следующего выстрела в серии.
var _next_shot_in: float = 0.0


func setup(hand: Hand, coord: HandSpell) -> void:
	_hand = hand
	_coord = coord
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = _hand.get_tree().current_scene


func is_active() -> bool:
	return _landing_queue.size() > 0


func can_trigger() -> bool:
	return _cooldown_remaining <= 0.0 and _landing_queue.is_empty()


func on_press() -> void:
	_cast()


func tick(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)
	if _landing_queue.size() > 0:
		_next_shot_in -= delta
		if _next_shot_in <= 0.0:
			var landing: Vector3 = _landing_queue.pop_front()
			_launch_one_projectile(landing)
			_next_shot_in = shot_interval


func _cast() -> void:
	if mine_scene == null:
		push_error("[Hand:Spell:MineScatter] mine_scene не задан")
		return
	if projectile_scene == null:
		push_error("[Hand:Spell:MineScatter] projectile_scene не задан")
		return
	if SpellSystem != null and not SpellSystem.is_unlocked(&"mine_scatter"):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Spell:MineScatter] заклинание не разблокировано")
		return
	var lvl: Dictionary = SpellSystem.get_current_level_data(&"mine_scatter") if SpellSystem != null else {}
	_series_mine_count = int(lvl.get("mine_count", mine_count))
	_series_scatter_radius = float(lvl.get("scatter_radius", scatter_radius))
	_series_mine_damage = float(lvl.get("mine_damage", mine_damage))
	_series_mine_aoe_radius = float(lvl.get("mine_aoe_radius", mine_aoe_radius))
	var p_cooldown: float = float(lvl.get("cooldown", cooldown))
	var p_mana_cost: float = float(lvl.get("mana_cost", mana_cost))

	if not _coord.try_consume_tower_mana(p_mana_cost):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Spell:MineScatter] не хватает маны (нужно %.0f)" % p_mana_cost)
		return

	var target_pos: Vector3 = _hand.cursor_world_position()
	target_pos.y -= _hand.hand_height
	_cooldown_remaining = p_cooldown

	if _effects_root != null:
		AoeVisual.spawn_ground_ring(_effects_root, target_pos, _series_scatter_radius, warning_duration, warning_color)

	# Заполняем очередь landing-точек uniform-в-круге.
	_landing_queue.clear()
	for i in range(_series_mine_count):
		var angle: float = randf() * TAU
		var r: float = sqrt(randf()) * _series_scatter_radius
		var landing: Vector3 = target_pos + Vector3(cos(angle) * r, 0.0, sin(angle) * r)
		_landing_queue.append(landing)
	_next_shot_in = 0.0

	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:MineScatter] залп × %d → центр (%.1f, %.1f), R=%.1fм" % [
			_series_mine_count, target_pos.x, target_pos.z, _series_scatter_radius,
		])
	spell_cast.emit(&"mine_scatter", target_pos)


## Стреляет один Fireball-снаряд из башни в landing-точку. Без damage'а —
## на impact'е будет спавн Mine'ы через hit-signal.
func _launch_one_projectile(landing: Vector3) -> void:
	if not is_instance_valid(_effects_root):
		return
	var launch_pos: Vector3 = _coord.tower_launch_position(launch_offset_y, _hand)
	var fireball := projectile_scene.instantiate() as Fireball
	if fireball == null:
		push_error("[Hand:Spell:MineScatter] projectile_scene не инстанцируется как Fireball")
		return
	_effects_root.add_child(fireball)
	fireball.setup(
		launch_pos,
		landing,
		boost_duration,
		boost_velocity_up,
		boost_velocity_forward,
		boost_gravity,
		boost_drift_velocity,
		homing_initial_speed,
		homing_acceleration,
		homing_max_speed,
		homing_drift_angle_deg,
		homing_turn_rate,
		0.0,    # damage = 0 — мы не наносим урон на impact'е (только Mine ставим)
		0.5,    # radius — небольшой для shape-query (всё равно damage=0, не важен)
		0,      # explode_mask = 0 — никого не сканируем при взрыве
		0.0,    # knockback_force
		0.0,    # knockback_lift
		0.0,    # knockback_duration
	)
	# Подключаем hit-сигнал — на impact'е спавним Mine.
	fireball.hit.connect(_on_projectile_hit, CONNECT_ONE_SHOT)


## Срабатывает в момент когда Fireball.gd достиг target'а и вызвал
## _explode. Сигнал эмитится ДО queue_free, координаты — точка взрыва.
## Спавним Mine ровно там — она моментально окажется на земле и пойдёт
## в ARMING.
func _on_projectile_hit(origin: Vector3, _radius: float) -> void:
	if not is_instance_valid(_effects_root):
		return
	var mine := mine_scene.instantiate() as Mine
	if mine == null:
		push_error("[Hand:Spell:MineScatter] mine_scene не инстанцируется как Mine")
		return
	_effects_root.add_child(mine)
	mine.damage = _series_mine_damage
	mine.aoe_radius = _series_mine_aoe_radius
	# Initial velocity = 0: мина появляется на земле и сразу идёт в FALLING-фазу,
	# которая моментально транзитится в ARMING (y уже ≤ ground_y).
	mine.setup(origin, Vector3.ZERO)


