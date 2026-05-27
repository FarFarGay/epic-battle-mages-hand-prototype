class_name HandSpellFirestorm
extends Node
## Огненный шквал — серия из N малых фаерболов, вылетают из башни по очереди
## с задержкой `shot_interval` и ложатся в небольшую зону `scatter_radius`
## вокруг прицела.
##
## Реюзает `fireball.tscn` как снаряд (та же баллистика, drift, homing,
## визуал) — отличия только в gameplay-параметрах: меньший damage/radius
## per-shot и рассеяние target_pos.
##
## Mana — общий cost списывается один раз при старте серии. Если мана не
## хватает — каст отменяется целиком, ни одна ракета не вылетает.
## Cooldown — общий, начинается сразу с press'а; can_trigger возвращает
## false пока серия идёт И пока cooldown не завершён.
##
## Параметры серии (shot_count, shot_interval, shot_damage, ...) читаются
## из `SpellSystem.get_current_level_data(&"firestorm")` с fallback на
## @export'ы. Параметры визуала (boost/homing/knockback) — local @export'ы,
## копия дефолтов из HandSpellFireball.

signal spell_cast(spell_name: StringName, position: Vector3)

@export_group("Volley")
## Сколько ракет в серии. Каждая = отдельный fireball-инстанс.
@export var shot_count: int = 4
## Задержка между шотами, секунды. 0.15с даёт быстрый «барабанный» дробящий
## ритм; больше — серия растягивается заметно.
@export var shot_interval: float = 0.15
## Урон одного шота (центр AOE, с linear falloff). Меньше fireball'а
## (30 dmg) — серия добирает количеством.
@export var shot_damage: float = 15.0
## Радиус AOE одного шота. Маленький (1.5) — точечные взрывы; рассеяние
## по `scatter_radius` создаёт «ковёр» из небольших попаданий.
@export var shot_radius: float = 1.5
## Радиус разброса target-точек вокруг прицела. Каждый шот таргетит точку
## внутри круга `scatter_radius` от исходной позиции курсора.
@export var scatter_radius: float = 2.0
## Cooldown между сериями, секунды. На время серии тоже учитывается —
## дополнительная попытка press'а игнорируется до завершения текущей серии.
@export var cooldown: float = 2.0
## Mana, требуемая для запуска серии. Списывается атомарно перед первым
## шотом. На моментах когда серия уже идёт, дополнительной маны не нужно.
@export var mana_cost: float = 50.0

@export_group("Boost (стартовая дуга)")
@export var boost_duration: float = 0.18
@export var boost_velocity_up: float = 7.0
@export var boost_velocity_forward: float = 3.0
@export var boost_gravity: float = 14.0
@export var boost_drift_velocity: float = 2.8

@export_group("Homing (полёт в цель)")
@export var homing_initial_speed: float = 8.0
@export var homing_acceleration: float = 100.0
@export var homing_max_speed: float = 55.0
@export_range(0.0, 80.0) var homing_drift_angle_deg: float = 45.0
@export_range(1.0, 30.0) var homing_turn_rate: float = 3.5

@export_group("AOE / Knockback")
@export_flags_3d_physics var explode_mask: int = Layers.MASK_HAND_SLAM
@export var knockback_force: float = 18.0
@export var knockback_lift: float = 0.4
@export var knockback_duration: float = 0.3

@export_group("Visual")
@export var fireball_scene: PackedScene
## Если задано — каждый шот оставляет небольшой burn. null — без burn.
## Радиус burn'а равен shot_radius — зона горения совпадает с зоной взрыва,
## кто попал под удар продолжает гореть на том же месте.
@export var burn_patch_scene: PackedScene
@export var burn_radius: float = 2.0
@export var burn_damage_per_tick: float = 8.0
@export var burn_tick_interval: float = 0.5
@export var burn_duration: float = 2.5
## Вертикальный offset launch'а от Tower'а. То же значение что у fireball'а.
@export var launch_offset_y: float = 3.0

@export_group("")

@export_group("Telegraph")
## Длительность ground-warning'а под каждым шотом серии (секунды). ≈ flight
## fireball'а с запасом — кольцо угасает к импакту. Per-shot, не общий
## scatter-ring (общий перекрывал бы реальные AOE-зоны взрывов).
@export var warning_duration: float = 0.9
## Цвет warning-кольца. Огненно-оранжевый — единый с Fireball'ом.
@export var warning_color: Color = Color(1.0, 0.5, 0.15, 0.85)
@export_group("")

@export_group("")
@export var effects_root_path: NodePath
@export var debug_log: bool = true

var _hand: Hand
var _coord: HandSpell
var _effects_root: Node = null
var _cooldown_remaining: float = 0.0
## Сколько шотов осталось выпустить в текущей серии (0 = серия завершена).
var _shots_remaining: int = 0
## Время до следующего шота (sec). На press ставится 0 — первый шот сразу.
var _next_shot_in: float = 0.0
## Зафиксированная цель серии (cursor world в момент press'а). Каждый шот
## таргетит эту позицию + случайный jitter в `scatter_radius`.
var _volley_target: Vector3 = Vector3.ZERO
## Резолвенные параметры для текущей серии — читаем из SpellSystem на press'е,
## используем для всех шотов серии (если игрок прокачает заклинание во время
## серии — серия завершится со старыми параметрами; правильное поведение,
## избегаем середины-серии-смены-балансов).
var _series_shot_damage: float
var _series_shot_radius: float
var _series_scatter_radius: float
## Burn-параметры серии — раньше были хардкодом @export'а (не масштабировались
## по уровню). Теперь читаются из SpellSystem.SPELL_CATALOG.firestorm.levels[*]
## с fallback'ом на @export. Фиксируем на press'е по той же причине.
var _series_burn_radius: float
var _series_burn_damage_per_tick: float
var _series_burn_tick_interval: float
var _series_burn_duration: float


func setup(hand: Hand, coord: HandSpell) -> void:
	_hand = hand
	_coord = coord
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = _hand.get_tree().current_scene


func is_active() -> bool:
	# Серия не имеет hold-state. Активность отражается через can_trigger.
	return false


# --- Публичный API (вызывается координатором HandSpell) ---

func can_trigger() -> bool:
	return _cooldown_remaining <= 0.0 and _shots_remaining <= 0


func on_press() -> void:
	_start_volley()


func tick(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)
	if _shots_remaining > 0:
		_next_shot_in -= delta
		if _next_shot_in <= 0.0:
			_launch_one()
			_shots_remaining -= 1
			_next_shot_in = shot_interval


# --- Запуск серии ---

func _start_volley() -> void:
	if fireball_scene == null:
		push_error("[Hand:Spell:Firestorm] fireball_scene не задан")
		return
	# Spell-gate.
	if SpellSystem != null and not SpellSystem.is_unlocked(&"firestorm"):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Spell:Firestorm] заклинание не разблокировано")
		return
	# Резолв параметров серии. Зафиксируем все значения, чтобы серия летела
	# с консистентным балансом (даже если внешнее состояние изменится).
	var lvl: Dictionary = SpellSystem.get_current_level_data(&"firestorm") if SpellSystem != null else {}
	var p_shot_count: int = int(lvl.get("shot_count", shot_count))
	var p_shot_interval: float = float(lvl.get("shot_interval", shot_interval))
	var p_cooldown: float = float(lvl.get("cooldown", cooldown))
	var p_mana_cost: float = float(lvl.get("mana_cost", mana_cost))
	_series_shot_damage = float(lvl.get("shot_damage", shot_damage))
	_series_shot_radius = float(lvl.get("shot_radius", shot_radius))
	_series_scatter_radius = float(lvl.get("scatter_radius", scatter_radius))
	_series_burn_radius = float(lvl.get("burn_radius", burn_radius))
	_series_burn_damage_per_tick = float(lvl.get("burn_damage_per_tick", burn_damage_per_tick))
	_series_burn_tick_interval = float(lvl.get("burn_tick_interval", burn_tick_interval))
	_series_burn_duration = float(lvl.get("burn_duration", burn_duration))

	if not _coord.try_consume_tower_mana(p_mana_cost):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Spell:Firestorm] не хватает маны (нужно %.0f)" % p_mana_cost)
		return

	# Зафиксировали target в момент press'а — игрок может водить курсор во
	# время серии, но шквал ложится туда, где было нажатие.
	_volley_target = _hand.cursor_world_position()
	_volley_target.y -= _hand.hand_height
	_shots_remaining = p_shot_count
	_next_shot_in = 0.0  # первый шот в ближайшем tick()
	_cooldown_remaining = p_cooldown
	# shot_interval запоминаем в @export — tick() читает его. Если игрок
	# прокачает заклинание во время серии — interval применится к следующим
	# шотам. Не критично для feel.
	shot_interval = p_shot_interval
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:Firestorm] шквал × %d @ target=(%.1f, %.1f, %.1f)" % [p_shot_count, _volley_target.x, _volley_target.y, _volley_target.z])
	spell_cast.emit(&"firestorm", _volley_target)


func _launch_one() -> void:
	var launch_pos: Vector3 = _coord.tower_launch_position(launch_offset_y, _hand)
	# Jitter target в круге scatter_radius — каждый шот в свою точку «ковра».
	var angle: float = randf() * TAU
	var dist: float = sqrt(randf()) * _series_scatter_radius  # uniform по площади
	var target_pos: Vector3 = _volley_target + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)

	# Telegraph: ground-warning под точкой удара одного шота. Размер = AOE
	# радиус взрыва шота. Ring живёт warning_duration (~ flight + buffer),
	# auto-fade сам.
	if _effects_root != null:
		AoeVisual.spawn_ground_ring(_effects_root, target_pos, _series_shot_radius, warning_duration, warning_color)

	var fireball := fireball_scene.instantiate() as Fireball
	if fireball == null:
		push_error("[Hand:Spell:Firestorm] fireball_scene не инстанцируется как Fireball")
		return
	_effects_root.add_child(fireball)
	fireball.setup(
		launch_pos,
		target_pos,
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
		_series_shot_damage,
		_series_shot_radius,
		explode_mask,
		knockback_force,
		knockback_lift,
		knockback_duration,
	)
	if burn_patch_scene != null:
		fireball.setup_burn(burn_patch_scene, _series_burn_radius, _series_burn_damage_per_tick, _series_burn_tick_interval, _series_burn_duration)


