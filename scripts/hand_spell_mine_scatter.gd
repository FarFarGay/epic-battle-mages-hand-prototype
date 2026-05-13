class_name HandSpellMineScatter
extends Node
## Магическая мин-бомбардировка. Tower выстреливает carrier в небо, тот
## burst'ит над целью, оттуда россыпью падают мины. После приземления и
## arming-delay'я мины ждут жертв (любых — friendly-fire ON).
##
## Реюзает [SuperCarrier] как доставочный снаряд (carrier→burst→payload).
## Отличия от супер-удара: нет QTE, тратит ману (не super-charge), меньшие
## масштабы (5 мин против 6 фаерболов, ниже carrier-altitude).
##
## Payload не падает «по диагонали с burst-точки», а спавнится прямо НАД
## точкой приземления (одна точка на каждую мину, выбирается uniform в круге
## scatter_radius). Initial velocity = 0, гравитация Mine сама опускает
## её на землю. Проще математики, мины ложатся точно куда задумано.
##
## Параметры читаются из SpellSystem.SPELL_CATALOG.mine_scatter с
## fallback'ом на @export.

signal spell_cast(spell_name: StringName, position: Vector3)

@export_group("Scatter")
## Сколько мин рассыпать за один каст. По дизайну ~5: хватает чтобы покрыть
## небольшой кластер, но не настолько много чтобы превратить заклинание
## в кнопку «уничтожить всё».
@export var mine_count: int = 5
## Радиус разброса мин вокруг точки прицела (uniform в круге через sqrt(rand)).
@export var scatter_radius: float = 5.0
@export var mine_damage: float = 30.0
@export var mine_aoe_radius: float = 1.8
@export var cooldown: float = 4.0
@export var mana_cost: float = 40.0

@export_group("Carrier delivery (tuned-down vs Super)")
## Высота старта carrier'а относительно Tower'а.
@export var carrier_launch_offset_y: float = 3.0
## Высота burst-точки над землёй (где carrier лопается и рассыпает мины).
## Меньше чем у Super (там 18-25м) — мины падают быстрее, заклинание
## ощутимее как «точечная атака».
@export var carrier_burst_height: float = 9.0
@export var carrier_boost_duration: float = 0.15
@export var carrier_boost_velocity_up: float = 9.0
@export var carrier_boost_velocity_forward: float = 4.0
@export var carrier_boost_gravity: float = 12.0
@export var carrier_boost_drift_velocity: float = 2.0
@export var carrier_homing_initial_speed: float = 14.0
@export var carrier_homing_acceleration: float = 40.0
@export var carrier_homing_max_speed: float = 28.0
@export var carrier_homing_drift_angle_deg: float = 25.0
@export var carrier_homing_turn_rate: float = 4.0
@export var carrier_burst_visual_radius: float = 2.5

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
	var burst_pos: Vector3 = target_pos + Vector3.UP * carrier_burst_height
	var carrier := carrier_scene.instantiate() as SuperCarrier
	if carrier == null:
		push_error("[Hand:Spell:MineScatter] carrier_scene не инстанцируется как SuperCarrier")
		return
	# add_child ДО setup — see hand_super.gd для контекста (global_position
	# требует ноду в SceneTree).
	_effects_root.add_child(carrier)
	carrier.setup(
		launch_pos,
		burst_pos,
		carrier_boost_duration,
		carrier_boost_velocity_up,
		carrier_boost_velocity_forward,
		carrier_boost_gravity,
		carrier_boost_drift_velocity,
		carrier_homing_initial_speed,
		carrier_homing_acceleration,
		carrier_homing_max_speed,
		carrier_homing_drift_angle_deg,
		carrier_homing_turn_rate,
	)
	carrier.burst.connect(_on_carrier_burst.bind(target_pos))


func _on_carrier_burst(burst_position: Vector3, ground_target: Vector3) -> void:
	if not is_instance_valid(_effects_root):
		return
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:MineScatter] burst @ (%.1f, %.1f, %.1f) → %d мин" % [
			burst_position.x, burst_position.y, burst_position.z, _series_mine_count,
		])
	# Воздушный взрыв в точке разделения — визуальный feedback что carrier
	# отыграл. Размер скромнее чем у Super.
	AoeVisual.spawn_explosion(_effects_root, burst_position, carrier_burst_visual_radius)
	for i in range(_series_mine_count):
		# Каждая мина — отдельная точка приземления в круге scatter_radius.
		# uniform-в-круге через sqrt(rand) (иначе центр перенасыщен).
		var angle: float = randf() * TAU
		var r: float = sqrt(randf()) * _series_scatter_radius
		var landing_xz: Vector3 = ground_target + Vector3(cos(angle) * r, 0.0, sin(angle) * r)
		# Спавн ПРЯМО НАД landing-точкой на высоте burst'а. Initial velocity = 0,
		# Mine.gravity опустит её ровно вниз. Проще чем рассчитывать траекторию
		# от burst-центра наружу — нет недолётов/перелётов.
		var spawn: Vector3 = Vector3(landing_xz.x, burst_position.y, landing_xz.z)
		_spawn_one_mine(spawn)


func _spawn_one_mine(spawn_pos: Vector3) -> void:
	if not is_instance_valid(_effects_root):
		return
	var mine := mine_scene.instantiate() as Mine
	if mine == null:
		push_error("[Hand:Spell:MineScatter] mine_scene не инстанцируется как Mine")
		return
	_effects_root.add_child(mine)
	# Прокидываем series-параметры в инстанс (override @export-дефолтов
	# из mine.tscn). Mine.setup ставит позицию + velocity (нулевая).
	mine.damage = _series_mine_damage
	mine.aoe_radius = _series_mine_aoe_radius
	mine.setup(spawn_pos, Vector3.ZERO)


func _find_tower() -> Node3D:
	var t := _hand.get_tree().get_first_node_in_group(Tower.GROUP)
	return t as Node3D
