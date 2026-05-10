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

@export_group("Boost (стартовая дуга)")
## Длительность boost-фазы, секунд. Снаряд короткое время движется по
## баллистике (vy_initial вверх + slight forward, тянет boost_gravity).
## После boost_duration переходит в HOMING — летит прямо в target.
@export var boost_duration: float = 0.18
## Стартовая вертикальная скорость boost'а, м/с. Чем больше — тем выше
## взлетает в первых кадрах.
@export var boost_velocity_up: float = 7.0
## Стартовая горизонтальная скорость boost'а в направлении цели, м/с.
## Маленькое значение — почти вертикальный «выстрел вверх».
@export var boost_velocity_forward: float = 3.0
## Гравитация в boost-фазе, м/с². В HOMING-фазе не применяется — там
## velocity полностью определяется direction-to-target × current_speed.
@export var boost_gravity: float = 14.0
## Амплитуда случайного бокового sway'я в boost'e, м/с. Каждый каст
## фаербол уходит вбок на ±[0; этого значения] с random знаком.
## Создаёт «дрожь» при выстреле — каждый кастит немного по-своему.
@export var boost_drift_velocity: float = 2.8

@export_group("Homing (полёт в цель)")
## Стартовая скорость homing-фазы, м/с. Почти всегда меньше скорости
## набранной в boost — фаербол «замедляется», прежде чем разогнаться к цели.
@export var homing_initial_speed: float = 8.0
## Линейное ускорение в homing-фазе, м/с². Чем больше — тем стремительнее
## разгон. С 100м/с² скорость 8→60 за 0.52с — нормальный «ракетный» feel.
@export var homing_acceleration: float = 100.0
## Cap скорости. Когда current_speed его достигает — перестаёт расти.
## 50м/с — быстрая, но читаемая; не «телепорт».
@export var homing_max_speed: float = 55.0
## Drift-угол на старте homing'а, градусы. Velocity отклоняется от
## desired-direction на random ±[0; это значение] вокруг UP. Slerp ниже
## плавно докручивает к цели — фаербол летит «крюком», очень импактно.
## 0 = без drift'а (прямой полёт), 30+ = выраженный изогнутый трасса.
@export_range(0.0, 80.0) var homing_drift_angle_deg: float = 45.0
## Скорость возврата к target-direction в homing-фазе (exp-decay rate).
## Меньше → длиннее drift; больше → быстрый коррекшен. 3.5 — drift
## заметнее, фаербол дольше «летит мимо» прежде чем повернуть.
@export_range(1.0, 30.0) var homing_turn_rate: float = 3.5

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
## Стоимость каста в мане Tower'а. При max_mana=100 и mana_regen=10 — это
## 4 каста подряд, потом ждём ~10с реген. Если маны не хватает — каст
## отменяется (cooldown не запускается, скорострел не «съедает» попытку).
@export var mana_cost: float = 25.0
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

	# Сначала инстанцируем снаряд: если сцена битая или OOM — выйдем,
	# не списав ману и не запустив cooldown.
	var fireball := fireball_scene.instantiate() as Fireball
	if fireball == null:
		push_error("[Hand:Spell:Fireball] fireball_scene не инстанцируется как Fireball")
		return

	var tower := _find_tower()
	# Mana-gate: если есть Tower и в нём не хватает маны — отказ. Cooldown
	# не запускается (попытка не «съедается»). Если Tower'а нет (dev-сцена) —
	# каст всё равно проходит без mana-чека. Контракт по `try_consume_mana`
	# вместо `is Tower` — потенциально мана-провайдером может быть и не Tower.
	if tower != null and tower.has_method(&"try_consume_mana"):
		if not tower.try_consume_mana(p_mana_cost):
			if debug_log and LogConfig.master_enabled:
				print("[Hand:Spell:Fireball] не хватает маны (нужно %.0f)" % p_mana_cost)
			fireball.queue_free()
			return
	# Launch: вершина башни (если есть), иначе позиция руки. На сцене Tower
	# всегда есть, fallback — для дев-сцен и для случая «башня уничтожена».
	var launch_pos: Vector3
	if tower != null:
		launch_pos = tower.global_position + Vector3.UP * launch_offset_y
	else:
		launch_pos = _hand.global_position
	var target_pos: Vector3 = _hand.cursor_world_position()
	# Y цели — приземление: пол (`hand_height` снят, чтобы шар врезался в землю,
	# а не в воздух над курсором). Если из cursor_world_position нельзя достать
	# реальный ground_y без raycast'а — компенсируем `hand_height`.
	target_pos.y -= _hand.hand_height
	_cooldown_remaining = p_cooldown

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
		p_damage,
		p_radius,
		explode_mask,
		knockback_force,
		knockback_lift,
		knockback_duration,
	)
	if burn_patch_scene != null:
		fireball.setup_burn(burn_patch_scene, p_burn_radius, p_burn_dmg, burn_tick_interval, p_burn_duration)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Spell:Fireball] каст @ target=(%.1f, %.1f, %.1f)" % [target_pos.x, target_pos.y, target_pos.z])
	spell_cast.emit(&"fireball", target_pos)


## Ищем Tower на сцене через group. Если в проекте появится несколько
## Tower'ов (мультибашня — пока нет в SPEC), вернём первый — это OK,
## фаербол стартует из ближайшей по логике игрока башни.
func _find_tower() -> Node3D:
	var t := _hand.get_tree().get_first_node_in_group(Tower.GROUP)
	return t as Node3D
