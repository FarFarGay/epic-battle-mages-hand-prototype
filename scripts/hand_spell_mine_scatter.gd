class_name HandSpellMineScatter
extends Node
## Магическая мин-бомбардировка. Tower кидает carrier-«сумку с минами»
## по дуге, тот лопается в апексе ПО ПУТИ (не над целью), и осколки-мины
## разлетаются дальше — с инерцией carrier'а вперёд + outward-разлётом
## + индивидуальной аркой до земли. После приземления и arming-delay'я
## мины ждут жертв. Friendly-fire ON.
##
## Принципиально не повторяет Super: у Super carrier → boost-up → homing-to-target,
## осколки сыпятся ВЕРТИКАЛЬНО над target'ом (удар сверху). Здесь — high-arc
## ballistic, burst в АПЕКСЕ, осколки получают часть инерции и разлетаются
## ШИРЕ цели. Ощущение «бросил жменю» вместо «точечная бомбардировка».
##
## Параметры читаются из SpellSystem.SPELL_CATALOG.mine_scatter с
## fallback'ом на @export.

signal spell_cast(spell_name: StringName, position: Vector3)

@export_group("Scatter")
## Сколько мин рассыпать за один каст. По дизайну ~5: хватает чтобы покрыть
## небольшой кластер, но не настолько много чтобы превратить заклинание
## в кнопку «уничтожить всё».
@export var mine_count: int = 5
## Радиус разброса мин вокруг точки прицела. На деле итоговый разлёт зависит
## от inertia carrier'а + outward + случайных арок — этот параметр сейчас
## используется как ориентир для telegraph-кольца, не как hard-cap.
@export var scatter_radius: float = 5.0
@export var mine_damage: float = 30.0
@export var mine_aoe_radius: float = 1.8
@export var cooldown: float = 4.0
@export var mana_cost: float = 40.0

@export_group("Carrier (ballistic fixed-angle)")
## Высота старта carrier'а относительно Tower'а.
@export var carrier_launch_offset_y: float = 3.0
## Радиус визуальной вспышки в момент burst'а (AoeVisual.spawn_explosion).
@export var carrier_burst_visual_radius: float = 1.8

@export_group("Mine ejection (как разлетаются осколки от burst-точки)")
## Up-boost, м/с — начальная вертикальная скорость каждой мины при выбросе
## из burst-точки. Создаёт визуальный «вспух»: мины сначала чуть подлетают,
## потом падают. Без этого мины из burst'а просто рушатся под carrier-vy=0.
@export var up_boost_min: float = 1.0
@export var up_boost_max: float = 2.5

## ВАЖНО: должны совпадать с Mine.gd-дефолтами. Используются для
## баллистического расчёта (откуда падать, чтобы попасть в landing-точку).
## Если игрок переопределит Mine.gravity per-instance — координация
## приземления съедет.
@export var mine_gravity: float = 14.0
@export var mine_ground_y: float = 0.05

@export_group("Visual")
@export var carrier_scene: PackedScene
@export var mine_scene: PackedScene

@export_group("Telegraph")
## Длительность жёлтого warning-кольца на земле в зоне scatter'а.
@export var warning_duration: float = 1.2
@export var warning_color: Color = Color(1.0, 0.55, 0.1, 0.7)

@export_group("")
@export var effects_root_path: NodePath
@export var debug_log: bool = true

var _hand: Hand
var _coord: HandSpell
var _effects_root: Node = null
var _cooldown_remaining: float = 0.0
## Зафиксированные параметры серии (читаем из SpellSystem на press'е,
## используем до конца — апгрейд во время полёта carrier'а не меняет
## уже-стартовавший каст).
var _series_mine_count: int
var _series_scatter_radius: float
var _series_mine_damage: float
var _series_mine_aoe_radius: float
## Точка прицела на земле в момент press'а. Зафиксирована — даже если игрок
## уводит курсор во время полёта carrier'а, scatter ложится туда где было
## нажатие. Используется в _on_carrier_burst для расчёта landing-точек мин.
var _series_ground_target: Vector3 = Vector3.ZERO


func setup(hand: Hand, coord: HandSpell) -> void:
	_hand = hand
	_coord = coord
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = _hand.get_tree().current_scene


func is_active() -> bool:
	return false


func can_trigger() -> bool:
	return _cooldown_remaining <= 0.0


func on_press() -> void:
	_cast()


func tick(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)


func _cast() -> void:
	if carrier_scene == null:
		push_error("[Hand:Spell:MineScatter] carrier_scene не задан")
		return
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
	_series_ground_target = target_pos
	_cooldown_remaining = p_cooldown

	# Telegraph — кольцо на земле в зоне scatter'а. Дольше чем у фаербола —
	# carrier-flight + arming-delay мин = ~2с до полной готовности.
	if _effects_root != null:
		AoeVisual.spawn_ground_ring(_effects_root, target_pos, _series_scatter_radius, warning_duration, warning_color)

	_spawn_carrier(target_pos)
	spell_cast.emit(&"mine_scatter", target_pos)


func _spawn_carrier(target_pos: Vector3) -> void:
	var launch_pos: Vector3
	var tower := _find_tower()
	if tower != null:
		launch_pos = tower.global_position + Vector3.UP * carrier_launch_offset_y
	else:
		launch_pos = _hand.global_position
	var carrier := carrier_scene.instantiate() as MineCarrier
	if carrier == null:
		push_error("[Hand:Spell:MineScatter] carrier_scene не инстанцируется как MineCarrier")
		return
	# add_child ДО setup — global_position требует ноду в SceneTree.
	_effects_root.add_child(carrier)
	carrier.setup(launch_pos, target_pos)
	carrier.burst.connect(_on_carrier_burst)


## Срабатывает в АПЕКСЕ carrier'а (vy переходит из + в −). Для каждой мины
## выбираем точку приземления (uniform в круге scatter_radius вокруг
## ground_target) и считаем initial velocity которая туда довезёт за
## время свободного падения с up_boost'ом.
##
## Time-of-flight выводится из вертикальной баллистики:
##   y_landing = y_burst + vy·t − ½·g·t²  →  t = (vy + √(vy² + 2g·(y_burst − y_landing))) / g
## Горизонтальная скорость: vx = (x_landing − x_burst) / t, vz аналогично.
## Up_boost маленький — даёт «выскок из жмени», не сильно меняет t.
func _on_carrier_burst(burst_position: Vector3, _carrier_velocity: Vector3) -> void:
	if not is_instance_valid(_effects_root):
		return
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:MineScatter] burst @ (%.1f, %.1f, %.1f) → %d мин" % [
			burst_position.x, burst_position.y, burst_position.z, _series_mine_count,
		])
	AoeVisual.spawn_explosion(_effects_root, burst_position, carrier_burst_visual_radius)
	# ground_target = середина scatter-круга (где центр приземления). Берём
	# его из приcrieда (он у нас уже зафиксирован в _series_*, но также
	# равен burst_position.xz сдвинутому на оставшееся горизонтальное
	# расстояние). Прост вариант: используем _last_target_pos, который
	# зафиксирован в _cast'е. (Зафиксируем явно.)
	var ground_target: Vector3 = _series_ground_target
	for i in range(_series_mine_count):
		var angle: float = randf() * TAU
		var r: float = sqrt(randf()) * _series_scatter_radius
		var landing: Vector3 = Vector3(
			ground_target.x + cos(angle) * r,
			mine_ground_y,
			ground_target.z + sin(angle) * r,
		)
		var up_boost: float = randf_range(up_boost_min, up_boost_max)
		# Решаем time-of-flight: положение по y от burst.y с initial vy=up_boost
		# и гравитацией mine_gravity, до landing.y (=mine_ground_y).
		var dy_b_to_l: float = burst_position.y - landing.y  # положительно — burst выше landing
		var disc: float = up_boost * up_boost + 2.0 * mine_gravity * dy_b_to_l
		if disc < 0.0:
			# Не должно случаться (burst выше landing всегда), но защита.
			disc = 0.0
		var t: float = (up_boost + sqrt(disc)) / mine_gravity
		if t < 0.01:
			t = 0.01  # защита от деления на 0 при вырожденных случаях
		var vx: float = (landing.x - burst_position.x) / t
		var vz: float = (landing.z - burst_position.z) / t
		var mine_velocity: Vector3 = Vector3(vx, up_boost, vz)
		_spawn_one_mine(burst_position, mine_velocity)


func _spawn_one_mine(spawn_pos: Vector3, initial_velocity: Vector3) -> void:
	if not is_instance_valid(_effects_root):
		return
	var mine := mine_scene.instantiate() as Mine
	if mine == null:
		push_error("[Hand:Spell:MineScatter] mine_scene не инстанцируется как Mine")
		return
	_effects_root.add_child(mine)
	# Прокидываем series-параметры в инстанс (override @export-дефолтов
	# из mine.tscn). Mine.setup ставит позицию + начальную velocity.
	mine.damage = _series_mine_damage
	mine.aoe_radius = _series_mine_aoe_radius
	mine.setup(spawn_pos, initial_velocity)


func _find_tower() -> Node3D:
	var t := _hand.get_tree().get_first_node_in_group(Tower.GROUP)
	return t as Node3D
