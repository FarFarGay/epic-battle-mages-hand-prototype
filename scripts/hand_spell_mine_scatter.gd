class_name HandSpellMineScatter
extends Node
## Магическая мин-бомбардировка. Прямой залп из башни: N мин-ракет
## вылетают серией со stagger'ом, каждая по своей баллистической дуге
## в свою точку приземления в круге scatter_radius. После приземления
## и arming-delay'я мины ждут жертв. Friendly-fire ON.
##
## Без промежуточного carrier'а — каждая мина сама является ракетой со
## своим trail'ом и собственной баллистикой. Дизайнерское решение 2026-05-14:
## carrier-сумка стала посредником без геймплейной ценности, прямой залп
## визуально динамичнее (multi-rocket-launcher feel) и архитектурно проще.
##
## Stagger между запусками (`shot_interval` ~60мс) — серия «тра-та-та»,
## а не одновременное «пуф». Landing-точки выбираются в `_cast` заранее
## (массив `_landing_points`), на каждом tick'е стреляется следующая.
##
## Параметры читаются из SpellSystem.SPELL_CATALOG.mine_scatter с
## fallback'ом на @export.

signal spell_cast(spell_name: StringName, position: Vector3)

@export_group("Scatter")
## Сколько мин в залпе. ~5 — покрывает кластер, не превращает заклинание
## в кнопку «уничтожить всё».
@export var mine_count: int = 5
## Радиус разброса landing-точек uniform-в-круге (через sqrt(rand)).
@export var scatter_radius: float = 5.0
@export var mine_damage: float = 30.0
@export var mine_aoe_radius: float = 1.8
@export var cooldown: float = 4.0
@export var mana_cost: float = 40.0

@export_group("Volley")
## Высота старта мины относительно Tower (точка запуска). Над Tower'ом,
## чтоб ракета визуально вылетала с верхушки.
@export var launch_offset_y: float = 3.0
## Задержка между запусками мин в серии. 0.06с = «тра-та-та» 5 ракет
## за 0.3с — слышная серия. 0 = одновременный залп.
@export var shot_interval: float = 0.06

@export_group("Ballistic")
## Угол старта в градусах. 55° = читаемая высокая дуга, мина видимо
## арки́рует. Скорость подбирается под landing-точку.
@export_range(20.0, 80.0) var launch_angle_deg: float = 55.0
## Up-boost — мелкий компонент vy поверх ballistic-решения. Создаёт
## разнообразие арок: одинаковые landing-точки + разный up_boost = разные
## пики и времена полёта. 0 = одинаковые арки.
@export var up_boost_min: float = 0.0
@export var up_boost_max: float = 1.5

## Должны совпадать с Mine.gd-дефолтами — для расчёта баллистики.
@export var mine_gravity: float = 22.0
@export var mine_ground_y: float = 0.05

@export_group("Visual")
@export var mine_scene: PackedScene

@export_group("Telegraph")
## Длительность жёлтого warning-кольца на земле в зоне scatter'а.
@export var warning_duration: float = 0.9
@export var warning_color: Color = Color(1.0, 0.55, 0.1, 0.7)

@export_group("")
@export var effects_root_path: NodePath
@export var debug_log: bool = true

var _hand: Hand
var _coord: HandSpell
var _effects_root: Node = null
var _cooldown_remaining: float = 0.0
## Зафиксированные параметры серии (читаем из SpellSystem на press'е,
## используем до конца серии — апгрейд во время залпа не меняет уже
## стартовавший каст).
var _series_mine_count: int
var _series_scatter_radius: float
var _series_mine_damage: float
var _series_mine_aoe_radius: float
## Очередь landing-точек на текущую серию. Каждый shot вытаскивает одну,
## считает velocity и спавнит мину.
var _landing_queue: Array[Vector3] = []
## Время до следующего выстрела в серии (sec). На press ставится 0 —
## первый выстрел сразу на ближайшем tick'е.
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
	# Нельзя дозаказать серию, пока текущая не отстрелялась И пока cooldown идёт.
	return _cooldown_remaining <= 0.0 and _landing_queue.is_empty()


func on_press() -> void:
	_cast()


func tick(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)
	# Серия активна? Стреляем следующую мину когда таймер ≤ 0.
	if _landing_queue.size() > 0:
		_next_shot_in -= delta
		if _next_shot_in <= 0.0:
			var landing: Vector3 = _landing_queue.pop_front()
			_launch_one_mine(landing)
			_next_shot_in = shot_interval


func _cast() -> void:
	if mine_scene == null:
		push_error("[Hand:Spell:MineScatter] mine_scene не задан")
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

	var tower := _find_tower()
	if tower != null and tower.has_method(&"try_consume_mana"):
		if not tower.try_consume_mana(p_mana_cost):
			if debug_log and LogConfig.master_enabled:
				print("[Hand:Spell:MineScatter] не хватает маны (нужно %.0f)" % p_mana_cost)
			return

	var target_pos: Vector3 = _hand.cursor_world_position()
	target_pos.y -= _hand.hand_height
	_cooldown_remaining = p_cooldown

	# Telegraph — кольцо на земле в зоне scatter'а. Длительность ≈ время
	# полёта самой дальней ракеты + arming_delay (~1с).
	if _effects_root != null:
		AoeVisual.spawn_ground_ring(_effects_root, target_pos, _series_scatter_radius, warning_duration, warning_color)

	# Заполняем очередь landing-точек uniform-в-круге.
	_landing_queue.clear()
	for i in range(_series_mine_count):
		var angle: float = randf() * TAU
		var r: float = sqrt(randf()) * _series_scatter_radius
		var landing: Vector3 = Vector3(
			target_pos.x + cos(angle) * r,
			mine_ground_y,
			target_pos.z + sin(angle) * r,
		)
		_landing_queue.append(landing)
	_next_shot_in = 0.0  # первая ракета на ближайшем tick'е

	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:MineScatter] залп × %d → центр (%.1f, %.1f), R=%.1fм" % [
			_series_mine_count, target_pos.x, target_pos.z, _series_scatter_radius,
		])
	spell_cast.emit(&"mine_scatter", target_pos)


## Стреляет одну мину из башни в конкретную landing-точку. Считает
## баллистику под фиксированный launch_angle, скорость подгоняется
## под расстояние. Up_boost даёт лёгкое разнообразие траекторий.
func _launch_one_mine(landing: Vector3) -> void:
	if not is_instance_valid(_effects_root):
		return
	var launch_pos: Vector3
	var tower := _find_tower()
	if tower != null:
		launch_pos = tower.global_position + Vector3.UP * launch_offset_y
	else:
		launch_pos = _hand.global_position
	var up_boost: float = randf_range(up_boost_min, up_boost_max)
	var velocity: Vector3 = _compute_arc_velocity(launch_pos, landing, up_boost)
	_spawn_mine_at(launch_pos, velocity)


## Обратная баллистика при фиксированном launch_angle + up_boost.
## Решает для скорости v так, чтобы из source с initial velocity
## (v·cos(α)·dir_h + (v·sin(α) + up_boost)·UP) попасть в target.
##
## Уравнения:
##   y(t) = source.y + (v·sin(α) + up_boost)·t − ½·g·t²
##   x(t), z(t): source + v·cos(α)·dir_h·t
## Из x_target = source.x + v·cos(α)·dir_h.x·t  →  t = d / (v·cos(α))
## Подставляя в y:
##   target.y = source.y + (v·sin(α) + up_boost)·d/(v·cos(α)) − ½·g·(d/(v·cos(α)))²
##   target.y = source.y + d·tan(α) + (up_boost·d)/(v·cos(α)) − g·d² / (2·v²·cos²(α))
##
## Это квадратное уравнение относительно (1/v). Решение:
##   Пусть u = 1/v. Тогда:
##   g·d²/(2·cos²(α))·u² − (up_boost·d/cos(α))·u − (source.y + d·tan(α) − target.y) = 0
##   Если up_boost = 0, упрощается до v² = g·d² / (2·cos²(α)·(d·tan(α) − dy)).
func _compute_arc_velocity(source: Vector3, target: Vector3, up_boost: float) -> Vector3:
	var to_target := target - source
	var horizontal := Vector3(to_target.x, 0.0, to_target.z)
	var d := horizontal.length()
	var dy := to_target.y
	var angle: float = deg_to_rad(launch_angle_deg)
	var cos_a: float = cos(angle)
	var sin_a: float = sin(angle)
	var dir_h: Vector3 = Vector3.RIGHT if d < 0.0001 else horizontal / d
	if d < 0.0001:
		# Цель прямо под source — стреляем тупо вниз. Не должно случаться.
		return Vector3.DOWN * 14.0
	# Решаем квадратное уравнение для u = 1/v:
	#   A·u² + B·u + C = 0
	# где A = g·d²/(2·cos²(α)), B = -up_boost·d/cos(α), C = -(source.y + d·tan(α) - target.y).
	# Реальные корни → берём положительный, v = 1/u.
	var tan_a: float = sin_a / cos_a if cos_a > 0.0001 else 1000.0
	var A: float = mine_gravity * d * d / (2.0 * cos_a * cos_a)
	var B: float = -up_boost * d / cos_a
	var C: float = -(source.y + d * tan_a - target.y)
	# C > 0 ⇔ target ниже линии запуска под углом α (нормальный случай).
	# Если C ≤ 0, target выше «потолка» — фоллбэк: фиксированная v=20.
	if C <= 0.0:
		return dir_h * 20.0 * cos_a + Vector3.UP * (20.0 * sin_a + up_boost)
	var disc: float = B * B - 4.0 * A * (-C)  # формула с C на правой стороне: A·u² + B·u = C
	# (= B² + 4·A·C — учётом знака C при переносе)
	# Проще явно: A·u² + B·u + C = 0, discriminant = B² − 4·A·C. Тут C перенесён, переписываю:
	# A·u² + B·u + C = 0 (стандарт), disc = B² − 4·A·C.
	disc = B * B - 4.0 * A * C
	if disc < 0.0:
		return dir_h * 20.0 * cos_a + Vector3.UP * (20.0 * sin_a + up_boost)
	var sqrt_disc: float = sqrt(disc)
	# Положительный корень u (положительная v нужна).
	var u1: float = (-B + sqrt_disc) / (2.0 * A)
	var u2: float = (-B - sqrt_disc) / (2.0 * A)
	var u: float = max(u1, u2)
	if u <= 0.0001:
		return dir_h * 20.0 * cos_a + Vector3.UP * (20.0 * sin_a + up_boost)
	var v: float = 1.0 / u
	return dir_h * v * cos_a + Vector3.UP * (v * sin_a + up_boost)


func _spawn_mine_at(spawn_pos: Vector3, initial_velocity: Vector3) -> void:
	if not is_instance_valid(_effects_root):
		return
	var mine := mine_scene.instantiate() as Mine
	if mine == null:
		push_error("[Hand:Spell:MineScatter] mine_scene не инстанцируется как Mine")
		return
	_effects_root.add_child(mine)
	mine.damage = _series_mine_damage
	mine.aoe_radius = _series_mine_aoe_radius
	# Передаём gravity тоже (на случай если spell настроен под повышенную).
	mine.gravity = mine_gravity
	mine.setup(spawn_pos, initial_velocity)


func _find_tower() -> Node3D:
	var t := _hand.get_tree().get_first_node_in_group(Tower.GROUP)
	return t as Node3D
