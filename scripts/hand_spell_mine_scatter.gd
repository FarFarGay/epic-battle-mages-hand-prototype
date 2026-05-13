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

@export_group("Carrier (ballistic high-arc)")
## Высота старта carrier'а относительно Tower'а.
@export var carrier_launch_offset_y: float = 3.0
## Желаемая скорость carrier'а при старте. Влияет на дальность и крутизну
## арки: чем меньше — тем выше арка (high_arc-формула фиксирует угол через
## v²/g для нужного R). 14 м/с даёт читаемый лоб на 14-25м дистанций.
@export var carrier_launch_speed: float = 14.0
## Радиус визуальной вспышки в момент burst'а (AoeVisual.spawn_explosion).
@export var carrier_burst_visual_radius: float = 1.8

@export_group("Mine ejection (как разлетаются осколки от burst-точки)")
## Доля скорости carrier'а в момент burst'а, передаваемая каждой мине вперёд.
## 0.4 = осколки сохраняют ~40% инерции carrier'а и продолжают «лететь» в ту
## же сторону, разлёт получается продольный (читается как «вытряхнул из мешка»).
@export var inertia_factor: float = 0.4
## Базовая величина outward-разлёта (в плоскости XZ), м/с. Направление —
## случайное (TAU). Каждая мина уникальна.
@export var outward_speed_min: float = 2.5
@export var outward_speed_max: float = 5.5
## Боковой up-boost, м/с. Создаёт «вспух» осколков перед падением — видно
## что они летят, а не падают. Минимум >0, иначе мины сразу под действием
## carrier-vy.y < 0 рухнут.
@export var up_boost_min: float = 1.5
@export var up_boost_max: float = 3.5

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
	var carrier := carrier_scene.instantiate() as MineCarrier
	if carrier == null:
		push_error("[Hand:Spell:MineScatter] carrier_scene не инстанцируется как MineCarrier")
		return
	# add_child ДО setup — global_position требует ноду в SceneTree.
	_effects_root.add_child(carrier)
	carrier.setup(launch_pos, target_pos, carrier_launch_speed)
	carrier.burst.connect(_on_carrier_burst)


## Срабатывает в АПЕКСЕ carrier'а (vy переходит из + в −). Не над target'ом,
## а на пол-пути в воздухе. Осколки получают часть инерции carrier'а вперёд
## (`inertia_factor`) + случайный outward-разлёт в плоскости XZ + лёгкий
## up-boost. Дальше Mine.gravity сама опускает их на землю — каждая мина
## ложится своей точкой, без хардкода точек приземления.
func _on_carrier_burst(burst_position: Vector3, carrier_velocity: Vector3) -> void:
	if not is_instance_valid(_effects_root):
		return
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:MineScatter] burst @ (%.1f, %.1f, %.1f) v=(%.1f, %.1f, %.1f) → %d мин" % [
			burst_position.x, burst_position.y, burst_position.z,
			carrier_velocity.x, carrier_velocity.y, carrier_velocity.z,
			_series_mine_count,
		])
	AoeVisual.spawn_explosion(_effects_root, burst_position, carrier_burst_visual_radius)
	# Forward inertia всем минам одна и та же (часть carrier-скорости).
	# Это сохраняет «направленность» разлёта — осколки в ту же сторону что
	# летел carrier.
	var inertia: Vector3 = carrier_velocity * inertia_factor
	# Y-компонент carrier'а в момент апекса ≈ 0, так что inertia в основном
	# горизонтальная — отлично подходит для «броска».
	for i in range(_series_mine_count):
		var angle: float = randf() * TAU
		var outward_speed: float = randf_range(outward_speed_min, outward_speed_max)
		var outward: Vector3 = Vector3(cos(angle) * outward_speed, 0.0, sin(angle) * outward_speed)
		var up_boost: float = randf_range(up_boost_min, up_boost_max)
		var mine_velocity: Vector3 = inertia + outward + Vector3.UP * up_boost
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
