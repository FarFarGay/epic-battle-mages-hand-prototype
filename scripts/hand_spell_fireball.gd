class_name HandSpellFireball
extends Node
## Фаербол — баллистический снаряд: вылетает из Tower'а по дуге, после apex
## ускоряется (g_dive > g_up), врезается в землю/target — AOE-урон по `MASK_HAND_SLAM`.
##
## Триггерится координатором HandSpell, когда `equipped == FIREBALL`,
## `Hand.active_category == MAGIC` и нажата ПКМ.
##
## Цель — текущая позиция руки (cursor world position). Запуск — Tower
## (через группу `&"tower"` или поиск по класс-имени, см. `_find_tower`).
## Если башня не найдена — фоллбэк на руку как launch_pos.
##
## Параметры дуги (flight_time, peak_height, peak_fraction) рассчитываются
## так, чтобы снаряд гарантированно прилетел в target.y за flight_time:
## g_up = 2 × peak_h / t_apex²; g_dive = 2 × (peak_h_world - target.y) / t_descent²;
## vh = horizontal_distance / flight_time; vy_initial = g_up × t_apex.

signal spell_cast(spell_name: StringName, position: Vector3)

## Параметры траектории — общие для Fireball/Firestorm/Frost. По умолчанию
## ссылается на [code]resources/ballistic_default.tres[/code]. Для per-spell
## override создай дубль .tres и подсунь сюда.
@export var ballistics: BallisticConfig = preload("res://resources/ballistic_default.tres")

@export_group("Balance")
## Базовый урон в эпицентре. Falloff линейный по расстоянию (как у Slam).
## 30 — «лёгкое оружие»: skeleton hp=30 умирает с одного попадания
## в эпицентр, на краю — выживает и догорает в BurnPatch'е.
@export var damage: float = 30.0
## Радиус AOE взрыва. 3.0 — компактный взрыв «пули», точный по таргетингу.
## Догоняющий damage по краю радиуса даёт `BurnPatch` (см. burn_*).
@export var radius: float = 3.0
## Cooldown между кастами. 0.4с — скорострельный режим, можно «очередью»;
## аналог легкой автоматической стрельбы. Ниже Slam (0.5с), за счёт меньшего
## damage и radius фаербол выходит сбалансированным «light → fast».
##
## NB: gameplay-балансовые параметры (damage, radius, cooldown, mana_cost,
## burn_*) override'ятся из `SpellSystem.get_current_level_data(&"fireball")`
## если заклинание разблокировано — @export'ы остаются как fallback для
## dev-сцен и как «edit-by-default» в инспекторе.
@export var cooldown: float = 0.4
## Стоимость каста в мане Tower'а — FALLBACK. Реальное значение берётся из
## SpellSystem.SPELL_CATALOG.fireball.levels[lvl].mana_cost (база 16, падает с
## прокачкой 16→13), этот @export используется только если в level-data нет ключа.
## Мана дорогая (реген 1.5/с), топливо — мана-орбы со скелетов (~3 орба на каст).
## Не хватает маны — каст отменяется (cooldown не запускается, попытка не «съедается»).
@export var mana_cost: float = 16.0
## Маска целей AOE. Та же что у Slam — все, кого «видит» рука как мишень,
## кроме MOUNTED_MODULE (модули не разрушаются магией). Per-target иммунитет
## через группу `hand_immune` (Layers.is_hand_immune).
@export_flags_3d_physics var explode_mask: int = Layers.MASK_HAND_SLAM
## Длительность knockback'а на kinematic-целях.
@export var knockback_duration: float = 0.4
## Сила knockback'а (разлёт от эпицентра). Симметрично slam_force.
@export var knockback_force: float = 35.0
## Доля силы вверх в направлении knockback (как у Slam). 0.4 — слегка
## подбрасывает целей. На фаерболе можно усилить до 0.6 — «магический подкид».
@export var knockback_lift: float = 0.5

@export_group("Burn")
## Сцена статичной зоны горения после взрыва. Спавнится в эпицентре,
## тикает damage по живым в радиусе. Если null — burn выключен (только
## мгновенный AOE-взрыв без остаточного эффекта).
@export var burn_patch_scene: PackedScene
## Радиус зоны горения. Меньше radius взрыва — «небольшая область».
@export var burn_radius: float = 1.5
## Урон за один тик. Skeleton hp=30: 8 dmg × 6 тиков = 48 dmg за 3с —
## догоняет тех, кто пережил основной взрыв (80 dmg) на краю радиуса.
@export var burn_damage_per_tick: float = 8.0
## Период между тиками урона. 0.5с × 6 тиков = 3с длительности.
@export var burn_tick_interval: float = 0.5
## Сколько секунд горит. Не распространяется и не сдвигается — статика.
@export var burn_duration: float = 3.0

@export_group("Visual")
## Сцена снаряда. Спавнится в effects_root (или current_scene).
@export var fireball_scene: PackedScene
## Вертикальный offset от Tower'а — фаербол вылетает «из вершины башни».
## Tower.height ≈ 4-5м, offset 3.0 ставит спавн выше центра, ближе к крыше.
@export var launch_offset_y: float = 3.0

@export_group("")
## Куда добавлять снаряд. Если NodePath пуст или не резолвится — current_scene.
@export var effects_root_path: NodePath
@export var debug_log: bool = true

@export_group("Telegraph")
## Длительность ground-warning'а под точкой удара (секунды). Должна быть
## ≥ времени полёта фаербола (homing на ~10м занимает ~0.4-0.6с при default
## speed). 1.0с — с запасом, кольцо угасает к импакту.
@export var warning_duration: float = 1.0
## Цвет warning-кольца. Огненно-оранжевый — единый «маг-предупреждающий»
## цвет; супер-удар отличается оттенком красного.
@export var warning_color: Color = Color(1.0, 0.5, 0.15, 0.85)
@export_group("")

var _hand: Hand
var _coord: HandSpell
var _cooldown_remaining: float = 0.0
var _effects_root: Node = null


func setup(hand: Hand, coord: HandSpell) -> void:
	_hand = hand
	_coord = coord
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = _hand.get_tree().current_scene


func is_active() -> bool:
	# Fireball — one-shot (как Slam), hold-state не имеет.
	return false


# --- Публичный API (вызывается координатором HandSpell) ---

func can_trigger() -> bool:
	return _cooldown_remaining <= 0.0


func on_press() -> void:
	_perform_cast()


func tick(delta: float) -> void:
	if _cooldown_remaining > 0.0:
		_cooldown_remaining = maxf(_cooldown_remaining - delta, 0.0)


# --- Каст ---

func _perform_cast() -> void:
	if fireball_scene == null:
		push_error("[Hand:Spell:Fireball] fireball_scene не задан")
		return
	# Spell-gate: если SpellSystem знает наш id и заклинание не unlocked —
	# каст блокируется. В dev-сценах без SpellSystem (autoload не зарегистрирован)
	# идём дальше с @export-параметрами.
	if SpellSystem != null and not SpellSystem.is_unlocked(&"fireball"):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Spell:Fireball] заклинание не разблокировано")
		return
	# Резолв gameplay-параметров: SpellSystem.levels — single source of truth,
	# @export'ы — fallback для dev-сцен. Если ключ не задан в level-data,
	# используем @export-значение.
	var lvl: Dictionary = SpellSystem.get_current_level_data(&"fireball") if SpellSystem != null else {}
	var p_damage: float = float(lvl.get("damage", damage))
	var p_radius: float = float(lvl.get("radius", radius))
	var p_cooldown: float = float(lvl.get("cooldown", cooldown))
	var p_mana_cost: float = float(lvl.get("mana_cost", mana_cost))
	var p_burn_dmg: float = float(lvl.get("burn_damage_per_tick", burn_damage_per_tick))
	var p_burn_radius: float = float(lvl.get("burn_radius", burn_radius))
	var p_burn_duration: float = float(lvl.get("burn_duration", burn_duration))
	var p_burn_tick_interval: float = float(lvl.get("burn_tick_interval", burn_tick_interval))

	# Сначала инстанцируем снаряд: если сцена битая или OOM — выйдем,
	# не списав ману и не запустив cooldown.
	var fireball := fireball_scene.instantiate() as Fireball
	if fireball == null:
		push_error("[Hand:Spell:Fireball] fireball_scene не инстанцируется как Fireball")
		return

	# Mana-gate: cooldown НЕ запускается на отказе (попытка не «съедается»).
	# Подробности контракта — см. [HandSpell.try_consume_tower_mana].
	if not _coord.try_consume_tower_mana(p_mana_cost):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Spell:Fireball] не хватает маны (нужно %.0f)" % p_mana_cost)
		fireball.queue_free()
		return
	var launch_pos: Vector3 = _coord.tower_launch_position(launch_offset_y, _hand)
	var target_pos: Vector3 = _hand.cursor_world_position()
	# Y цели — приземление: пол (`hand_height` снят, чтобы шар врезался в землю,
	# а не в воздух над курсором). Если из cursor_world_position нельзя достать
	# реальный ground_y без raycast'а — компенсируем `hand_height`.
	target_pos.y -= _hand.hand_height
	_cooldown_remaining = p_cooldown

	# Telegraph: ground-warning под точкой удара. Размер = AOE радиус взрыва,
	# игрок видит реальную зону поражения. Auto-fade за warning_duration.
	if _effects_root != null:
		AoeVisual.spawn_ground_ring(_effects_root, target_pos, p_radius, warning_duration, warning_color)

	_effects_root.add_child(fireball)
	# Метка «снаряд игрока» — EnemyMech сканит эту группу и уклоняется от
	# летящего фаербола (реактивный интеллект, скелеты так не умеют).
	fireball.add_to_group(&"player_projectile")
	fireball.setup(
		launch_pos,
		target_pos,
		ballistics.boost_duration,
		ballistics.boost_velocity_up,
		ballistics.boost_velocity_forward,
		ballistics.boost_gravity,
		ballistics.boost_drift_velocity,
		ballistics.homing_initial_speed,
		ballistics.homing_acceleration,
		ballistics.homing_max_speed,
		ballistics.homing_drift_angle_deg,
		ballistics.homing_turn_rate,
		p_damage,
		p_radius,
		explode_mask,
		knockback_force,
		knockback_lift,
		knockback_duration,
	)
	# Одиночный фаербол — крупный единичный бабах: ощутимый хитстоп. Firestorm/super
	# не зовут set_hitstop (оставляют 0), их серии детонаций иначе дёргали бы слоу-мо.
	fireball.set_hitstop(HitStop.HEAVY)
	fireball.shake_amount = 0.2  # одиночный фаербол — заметный impact-шейк (по дистанции)
	if burn_patch_scene != null:
		fireball.setup_burn(burn_patch_scene, p_burn_radius, p_burn_dmg, p_burn_tick_interval, p_burn_duration)
	# Большой одиночный файрбол: фиксированный 12м-pulse. Длительность
	# вычисляется в fireball._explode от FogOfWar.PULSE_SPREAD_SPEED (10м/с)
	# → ~1.2с плавного раскрытия. Огненный шквал НЕ зовёт setup_fog_pulse —
	# его шоты используют дефолт (_radius × 7 ≈ 10м), серия не сливается в
	# гигантскую засветку.
	fireball.setup_fog_pulse(12.0)
	# Столкновение в полёте: детонирует на первом враге/земле по пути
	# (MASK_FRIENDLY_PROJECTILE — НЕ на своих, иначе рванул бы в гуще гномов у
	# башни). AOE по взрыву по-прежнему задевает и своих (explode_mask).
	fireball.set_collide_in_flight(true, Layers.MASK_FRIENDLY_PROJECTILE)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:Fireball] каст @ target=(%.1f, %.1f, %.1f)" % [target_pos.x, target_pos.y, target_pos.z])
	spell_cast.emit(&"fireball", target_pos)
	EventBus.tower_fired.emit(target_pos)  # отдача башни (одиночный выстрел)


