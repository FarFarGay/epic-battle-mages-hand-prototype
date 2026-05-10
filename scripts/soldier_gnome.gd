class_name SoldierGnome
extends Gnome
## Гном-солдат — мобилизованный из gatherer'а через `Camp.recruit_squad`.
## Тип ближнего боя (копейщик): обнаруживает врага в `enemy_detect_radius`,
## догоняет, в `attack_range` бьёт на cooldown'е через
## `Damageable.try_damage`. Лучники как мобильный отряд НЕ призываются —
## только штатные DefenderGnome'ы у палаток. Параметры (hp, enemy_detect_radius,
## attack_range, damage, cooldown, speed) приходят из
## `SoldierSystem.SOLDIER_CATALOG[type].stats` через `setup_soldier`.
##
## Не привязан к палатке (в отличие от DefenderGnome): `_home_tent=null`.
## `_active_tick` переопределён под combat-логику + три squad-режима
## (HOLD / ESCORT / DEFEND).
##
## Группа SOLDIER_GROUP — для squad-сканов и общего учёта.

const SOLDIER_GROUP := &"soldier"

@export_group("Soldier combat (override через setup_soldier)")
## Радиус обнаружения противника. Юнит видит скелетов в этом радиусе и
## идёт на них. Не равен дистанции удара — копейщик подбегает в упор.
@export var enemy_detect_radius: float = 18.0
## Дистанция, с которой можно нанести удар копьём. С учётом capsule
## радиусов (skeleton ≈0.5, pikeman ≈0.28, минимум центр-к-центру ≈0.78м)
## значение 2.2 даёт ~1.4м реального «вылета копья» от тела — достаточно
## для попадания по движущейся цели на one-frame check'е.
@export var attack_range: float = 2.2
@export var attack_damage_min: float = 22.0
@export var attack_damage_max: float = 32.0
@export var attack_cooldown_min: float = 0.6
@export var attack_cooldown_max: float = 1.0
@export var soldier_color: Color = Color(0.85, 0.55, 0.25, 1.0)
@export_group("")

@export_group("Defend patrol (DEFENDING_CAMP state)")
## Радиус патрулирования вокруг центра лагеря. По образцу
## `DefenderGnome.patrol_radius=12`. Каждый солдат отряда независимо
## выбирает случайные точки на этой окружности — отряд распределяется по
## периметру, как штатные защитники.
@export var defend_patrol_radius: float = 12.0
@export var defend_patrol_arrival: float = 0.6
## Скорость патрульного шага. Меньше боевого move_speed — стража обходит
## периметр размеренно (как `DefenderGnome.patrol_speed=1.0`, +чуть-чуть для
## визуального отличия).
@export var defend_patrol_speed: float = 1.2
@export_group("")

@export_group("Soldier charge (атака с разбега и рывком)")
## Скорость движения в фазе разгона (бежит к цели, корректируя направление
## каждый кадр). Линейно нарастает с 0 до этого значения за
## `approach_accel_time` — даёт «нарастающий бег» без мгновенного rocket-старта.
@export var approach_max_speed: float = 4.5
## Время нарастания скорости разгона от 0 до approach_max_speed.
@export var approach_accel_time: float = 0.18
## Дистанция до цели, при которой копейщик переходит из разгона в lunge —
## молниеносный рывок насквозь. Чуть больше attack_range, чтобы lunge
## всегда захватывал цель в свой пролёт.
@export var lunge_trigger_range: float = 3.5
## Скорость молниеносного рывка. Сильно выше approach_max_speed — даёт
## импактный «вылет копьём». Направление фиксируется в момент перехода
## APPROACH → LUNGE и больше не меняется (skel может уклониться при
## удаче — это by-design).
@export var lunge_speed: float = 12.0
## Дистанция, которую копейщик пролетает после удара по инерции lunge'а —
## визуально «пробил насквозь и ещё несколько шагов».
@export var lunge_pass_distance: float = 2.2
## Длительность заноса/торможения после lunge'а. Velocity спадает от
## lunge_speed до 0 по слегка-skid-кривой (медленный начальный спад,
## быстрый в конце — «гасит инерцию»).
@export var drift_time: float = 0.55
## Пауза «отдышаться» после заноса. Юнит стоит, не ищет цели, не возвращается
## в строй. В этой фазе он максимально уязвим — это часть импакт-ритма.
@export var recovery_time: float = 0.35
## Лимит дистанции разгона: если цель не доступна в lunge-range за столько
## метров, копейщик отменяет атаку (drift+recovery, ищет новую цель).
@export var max_approach_distance: float = 9.0
## Радиус «охранной области» — копейщик не атакует цели, чей центр вне
## этого радиуса от центра текущего режима (HOLD = указанная точка,
## ESCORT = башня, DEFEND = anchor лагеря).
@export var combat_leash_radius: float = 12.0
## Knockback на скелета при попадании, если он выжил. Δv в направлении
## lunge'а — скелета отталкивает на пол-метра-метр, видно столкновение.
@export var strike_knockback_speed: float = 5.0
## Длительность knockback'а (AI цели заглушен это время).
@export var strike_knockback_duration: float = 0.18
@export_group("")

## Per-soldier combat state machine:
##   READY → APPROACH → LUNGE → DRIFT → RECOVERY → READY.
##  - APPROACH: бежит к цели, скорость линейно с 0 до approach_max_speed.
##    Direction обновляется каждый кадр — если цель сдвинется, повернёт.
##    Когда dist ≤ lunge_trigger_range или цель уже в attack_range —
##    переходит в LUNGE с фиксированным направлением.
##  - LUNGE: молниеносный рывок. Direction зафиксировано на момент входа.
##    Удар в первый кадр когда dist ≤ attack_range. Продолжает лететь
##    `lunge_pass_distance` метров после удара (пролетает насквозь).
##  - DRIFT: занос. Velocity скидывается с lunge_speed по slight ease-in
##    кривой — слабый начальный спад «в заносе», потом гасит до нуля.
##  - RECOVERY: стоит, отдыхает, уязвим. После — READY.
enum CombatState { READY, APPROACH, LUNGE, DRIFT, RECOVERY }

## Тип солдата из SOLDIER_CATALOG. Ставится в setup_soldier.
var soldier_type: StringName = &""
## Ссылка на squad. Назначается Squad.add_member(self). RefCounted —
## пока хотя бы один член держит ссылку или Camp хранит, объект жив.
var _squad: Squad = null
var _attack_cd: float = 0.0
## Текущая патрульная точка в DEFENDING_CAMP. INF = «нужно выбрать новую»
## (старт или дошли до прежней).
var _defend_patrol_target: Vector3 = Vector3.INF
## Per-soldier флаг: дошёл ли юнит хоть раз до strict-слота после
## последней команды HOLD. Сбрасывается на любое state_changed (новый
## command_hold с другой точкой = новый strict-march с нуля).
##
## Без этого strict-march re-fire'ил бы после каждого combat-displacement'а
## (lunge выбрасывает юнита из слота на 2-5м), и юнит дёргался бы между
## возвратом к слоту и боем — никогда не успевал нанести второй удар.
var _strict_arrived_at_slot: bool = false
var _combat_state: int = CombatState.READY
var _charge_target: Node3D = null
## Зафиксированное направление LUNGE'а — устанавливается на переходе из
## APPROACH'а, дальше не меняется (рывок прямой, цель может уклониться).
var _charge_dir: Vector3 = Vector3.FORWARD
## Стартовая позиция для подсчёта пробега (max_approach_distance в APPROACH'е,
## lunge_pass_distance в LUNGE'е).
var _charge_start_pos: Vector3 = Vector3.ZERO
var _has_struck_this_charge: bool = false
## Накопитель времени в APPROACH'е (для линейного нарастания скорости).
var _approach_elapsed: float = 0.0
## Остаток дистанции пролёта после удара (lunge_pass_distance).
var _post_strike_remaining: float = 0.0
var _drift_remaining: float = 0.0
var _recovery_remaining: float = 0.0
## Расстояние «прибытия» к squad-target'у. Меньше — стоим (squad-positioning
## не jitter'ит на под-метровых отклонениях).
const SQUAD_TARGET_ARRIVAL: float = 0.4


func _ready() -> void:
	# gnome_color для _apply_visual'а — выставляем ДО super._ready чтобы
	# базовый ready взял правильный цвет, если он туда смотрит. Сейчас в
	# Gnome._ready визуал не применяется (только в setup), но на будущее.
	gnome_color = soldier_color
	super._ready()
	add_to_group(SOLDIER_GROUP)


## Конфиг приходит от Camp.recruit_squad на основе SoldierSystem.SOLDIER_CATALOG.
## Stats — Dictionary с ключами hp / enemy_detect_radius / attack_range / damage_min /
## damage_max / cooldown_min / cooldown_max / move_speed. Отсутствующие ключи —
## оставляют @export-дефолты.
func setup_soldier(p_type: StringName, stats: Dictionary, p_camp: Camp, position: Vector3) -> void:
	soldier_type = p_type
	hp = float(stats.get("hp", hp))
	enemy_detect_radius = float(stats.get("enemy_detect_radius", enemy_detect_radius))
	attack_range = float(stats.get("attack_range", attack_range))
	attack_damage_min = float(stats.get("attack_damage_min", attack_damage_min))
	attack_damage_max = float(stats.get("attack_damage_max", attack_damage_max))
	attack_cooldown_min = float(stats.get("attack_cooldown_min", attack_cooldown_min))
	attack_cooldown_max = float(stats.get("attack_cooldown_max", attack_cooldown_max))
	if stats.has("move_speed"):
		move_speed = float(stats.move_speed)
	global_position = position
	# Базовая Gnome-инициализация. home_tent=null — солдат не привязан.
	# setup() вызывает _enter_in_tent внутри, поэтому ниже принудительно
	# выходим в outside-режим (visible, в группе skeleton_target, _state свой).
	setup(p_camp, null)
	_state = State.SEARCHING  # любой outdoor-state, AI в _active_tick переопределён
	visible = true
	add_to_group(SKELETON_TARGET_GROUP)
	# Стартовый cd = 0: первый удар после спавна / arrival должен быть
	# мгновенным. Залп из 5 копейщиков на charge-attack визуально импактен,
	# в отличие от стрельбы лучников где залп выглядит синхронным глюком.
	_attack_cd = 0.0


## Squad назначает себя на add_member. Двусторонняя ссылка нужна юниту
## чтобы запросить target_for_member и читать squad.state. На смерть юнита
## squad сам отлавливает destroyed-сигнал и убирает из members'а.
##
## Подписываемся на state_changed — на любое изменение команды (новый
## hold-pos, переход на escort/defend) сбрасываем _strict_arrived_at_slot,
## чтобы strict-march снова отработал «один раз до слота».
func set_squad(squad: Squad) -> void:
	_squad = squad
	if squad != null and not squad.state_changed.is_connected(_on_squad_state_changed):
		squad.state_changed.connect(_on_squad_state_changed)


func _on_squad_state_changed() -> void:
	_strict_arrived_at_slot = false


## Override базового AI. Combat — charge-attack state machine:
##   1. Cooldown удара тикает всегда.
##   2. **Strict-march** (HOLD после `command_hold`): идём к слоту,
##      игнорируя бой; любой активный charge сбрасываем — точное указание
##      места приоритетнее боевого ритма.
##   3. Если в CHARGING/DECEL — продолжаем state machine, не дёргаем squad.
##   4. READY: ищем цель в `combat_leash_radius`е от центра режима. Есть
##      цель и cooldown готов → стартуем charge. Нет — squad-positioning
##      (HOLD/ESCORT кольцо или DEFEND patrol).
func _active_tick(delta: float) -> void:
	if _attack_cd > 0.0:
		_attack_cd -= delta

	# Strict-march: ИНИЦИАЛЬНОЕ исполнение команды «Идти сюда» — идём
	# к слоту напролом. Combat-assist: если по дороге попался враг в
	# lunge-range — НЕ тормозим у слота, а вбегаем в lunge напрямую.
	# Игрок указал точку на врагов (красная подсветка zone-индикатора) —
	# отряд должен «вбежать в бой», а не тормозить и потом атаковать.
	# После первого прибытия (`_strict_arrived_at_slot`) переключаемся на
	# нормальное поведение: combat-приоритет, возврат в строй когда нет
	# цели. Иначе lunge выбрасывал бы из слота, strict снова марш back,
	# и юнит дёргался.
	if _squad != null and _camp != null \
			and _squad.state == Squad.State.HOLDING_POSITION \
			and _squad.is_strict_move() \
			and not _strict_arrived_at_slot:
		if _combat_state != CombatState.READY:
			_reset_combat_state()
		# Combat-assist на марше: ловим близкого врага и бьём с ходу.
		if _attack_cd <= 0.0:
			var assist_target: Node3D = _find_target_in_leash()
			if assist_target != null:
				var to_assist: float = global_position.distance_to(assist_target.global_position)
				if to_assist <= lunge_trigger_range:
					_strict_arrived_at_slot = true
					_start_charge(assist_target)
					return
		var goal_strict: Vector3 = _squad.target_for_member(self, _resolve_squad_center())
		var to_goal_strict := Vector3(goal_strict.x - global_position.x, 0.0, goal_strict.z - global_position.z)
		var dist_strict: float = to_goal_strict.length()
		if dist_strict > SQUAD_TARGET_ARRIVAL:
			_move_toward(to_goal_strict, dist_strict)
			return
		# Дошёл первый раз — фиксируем и больше strict не блокирует бой.
		_strict_arrived_at_slot = true

	# Внутри charge/decel — гонит state machine, squad-логика не вмешивается.
	if _combat_state != CombatState.READY:
		_tick_charge_state(delta)
		return

	# READY: пробуем стартовать новый charge, если cooldown готов и есть цель
	# в leash-области. Иначе — squad-движение.
	if _attack_cd <= 0.0:
		var target: Node3D = _find_target_in_leash()
		if target != null:
			_start_charge(target)
			return

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


## Шаг state machine во всех нон-READY стейтах. Velocity полностью
## управляется здесь — squad-positioning не вмешивается до возврата в READY.
func _tick_charge_state(delta: float) -> void:
	match _combat_state:
		CombatState.APPROACH:
			# Цель умерла во время разгона — отменяем без штрафа cd.
			if not is_instance_valid(_charge_target):
				_combat_state = CombatState.RECOVERY
				_recovery_remaining = recovery_time
				velocity = Vector3.ZERO
				return
			# Re-aim каждый кадр: если цель сдвинулась, корректируем курс.
			var to_t := Vector3(
				_charge_target.global_position.x - global_position.x,
				0.0,
				_charge_target.global_position.z - global_position.z,
			)
			var dist_t: float = to_t.length()
			if dist_t > 0.001:
				var dir := to_t / dist_t
				look_at(global_position + dir, Vector3.UP)
				_approach_elapsed += delta
				var spd_t: float = clampf(_approach_elapsed / maxf(approach_accel_time, 0.001), 0.0, 1.0)
				velocity = dir * (approach_max_speed * spd_t)
			# Триггер lunge: подбежали достаточно близко (или уже в attack_range —
			# тогда цель буквально перед носом, лunge нужен короткий).
			if dist_t <= lunge_trigger_range:
				_charge_dir = (to_t / dist_t) if dist_t > 0.001 else _charge_dir
				_charge_start_pos = global_position
				_post_strike_remaining = lunge_pass_distance
				_combat_state = CombatState.LUNGE
				velocity = _charge_dir * lunge_speed
				return
			# Превысили лимит разгона без сближения — отменяем атаку.
			var approach_run: float = global_position.distance_to(_charge_start_pos)
			if approach_run > max_approach_distance:
				_combat_state = CombatState.DRIFT
				_drift_remaining = drift_time * 0.5  # короткий drift на отмене
		CombatState.LUNGE:
			velocity = _charge_dir * lunge_speed
			if not _has_struck_this_charge:
				if is_instance_valid(_charge_target):
					var dist_lunge: float = global_position.distance_to(_charge_target.global_position)
					if dist_lunge <= attack_range:
						_strike_at(_charge_target)
						_has_struck_this_charge = true
						_attack_cd = randf_range(attack_cooldown_min, attack_cooldown_max)
				else:
					# Цель умерла в воздухе — продолжаем по инерции до конца pass.
					_has_struck_this_charge = true
			if _has_struck_this_charge:
				_post_strike_remaining -= lunge_speed * delta
				if _post_strike_remaining <= 0.0:
					_combat_state = CombatState.DRIFT
					_drift_remaining = drift_time
			else:
				# Промах в процессе lunge'а: лимит пробега.
				var lunge_run: float = global_position.distance_to(_charge_start_pos)
				if lunge_run > lunge_pass_distance + 1.5:
					_combat_state = CombatState.DRIFT
					_drift_remaining = drift_time
		CombatState.DRIFT:
			_drift_remaining -= delta
			if _drift_remaining <= 0.0:
				_combat_state = CombatState.RECOVERY
				_recovery_remaining = recovery_time
				velocity = Vector3.ZERO
				return
			# Skid-curve: pow(t, 0.6) — медленный начальный спад («занос держит
			# инерцию»), резкий в конце. t=1 → speed=lunge; t=0 → 0.
			var dt_t: float = clampf(_drift_remaining / maxf(drift_time, 0.001), 0.0, 1.0)
			var skid_speed: float = lunge_speed * pow(dt_t, 0.6)
			velocity = _charge_dir * skid_speed
		CombatState.RECOVERY:
			velocity = Vector3.ZERO
			_recovery_remaining -= delta
			if _recovery_remaining <= 0.0:
				_combat_state = CombatState.READY
				_charge_target = null


## Старт атаки: переход в APPROACH. Скорость стартует с 0 и нарастает
## линейно за approach_accel_time. Lunge запускается из APPROACH-тика
## когда дистанция до цели ≤ lunge_trigger_range.
func _start_charge(target: Node3D) -> void:
	_charge_target = target
	_charge_start_pos = global_position
	_has_struck_this_charge = false
	_post_strike_remaining = lunge_pass_distance
	_approach_elapsed = 0.0
	var to_target := Vector3(
		target.global_position.x - global_position.x,
		0.0,
		target.global_position.z - global_position.z,
	)
	var d: float = to_target.length()
	if d > 0.001:
		_charge_dir = to_target / d
		look_at(global_position + _charge_dir, Vector3.UP)
	# Если цель уже в lunge-range — пропускаем разгон, сразу lunge.
	if d <= lunge_trigger_range:
		_post_strike_remaining = lunge_pass_distance
		_combat_state = CombatState.LUNGE
		velocity = _charge_dir * lunge_speed
	else:
		_combat_state = CombatState.APPROACH
		velocity = Vector3.ZERO


## Принудительный сброс боевого state machine'а (для strict-march override
## когда игрок указал новую точку командой Hold).
func _reset_combat_state() -> void:
	_combat_state = CombatState.READY
	_charge_target = null
	_approach_elapsed = 0.0
	_post_strike_remaining = 0.0
	_drift_remaining = 0.0
	_recovery_remaining = 0.0


## Патрульный шаг для DEFENDING_CAMP: каждый юнит самостоятельно выбирает
## случайную точку на окружности `defend_patrol_radius` вокруг центра лагеря,
## идёт туда patrol_speed'ом, по прибытии выбирает следующую. На бой
## переключается из основного `_active_tick` (combat-проверка стоит ВЫШЕ
## этого блока). Без adaptive-speed `_move_toward` — патруль это walk,
## а не догон строя.
func _tick_defend_patrol() -> void:
	var center: Vector3 = _resolve_squad_center()
	if _defend_patrol_target == Vector3.INF:
		_defend_patrol_target = _pick_defend_patrol_point(center)
	var to_target := Vector3(
		_defend_patrol_target.x - global_position.x,
		0.0,
		_defend_patrol_target.z - global_position.z,
	)
	var dist: float = to_target.length()
	if dist < defend_patrol_arrival:
		_defend_patrol_target = _pick_defend_patrol_point(center)
		to_target = Vector3(
			_defend_patrol_target.x - global_position.x,
			0.0,
			_defend_patrol_target.z - global_position.z,
		)
		dist = to_target.length()
	if dist < 0.001:
		velocity = Vector3.ZERO
		return
	var dir: Vector3 = to_target / dist
	look_at(global_position + dir, Vector3.UP)
	velocity = dir * defend_patrol_speed


## Случайная точка на окружности `defend_patrol_radius` вокруг center'а.
## Угол uniform [0, TAU). Y центра — палатки/anchor лежат на полу, патруль
## той же высоты (CharacterBody3D + гравитация прижмут к terrain'у при
## расхождении).
func _pick_defend_patrol_point(center: Vector3) -> Vector3:
	var angle: float = randf() * TAU
	return Vector3(
		center.x + cos(angle) * defend_patrol_radius,
		center.y,
		center.z + sin(angle) * defend_patrol_radius,
	)


## Резолв центра кольца отряда исходя из squad.state. Squad — RefCounted
## без ссылки на Camp, поэтому контекст лагеря (anchor / tower) собираем
## здесь и пробрасываем готовым Vector3'ом.
##
## - HOLDING_POSITION → точка, которую указал игрок.
## - ESCORTING_TOWER → текущая позиция башни.
## - DEFENDING_CAMP → anchor развёрнутого лагеря; на свёртке (anchor stale) —
##   fallback на башню (мини-эскорт), чтобы юниты не «защищали» пустое
##   место после переезда. Когда лагерь снова развернут — auto-возврат к
##   anchor'у на следующем тике.
func _resolve_squad_center() -> Vector3:
	if _squad == null:
		return global_position
	match _squad.state:
		Squad.State.HOLDING_POSITION:
			return _squad.hold_position
		Squad.State.ESCORTING_TOWER:
			return _camp.get_tower_position() if _camp != null and _camp.has_method(&"get_tower_position") else global_position
		Squad.State.DEFENDING_CAMP:
			if _camp != null and _camp.is_deployed():
				return _camp.deploy_anchor
			if _camp != null and _camp.has_method(&"get_tower_position"):
				return _camp.get_tower_position()
			return global_position
	return global_position


## Адаптивная скорость по образцу DefenderGnome._tick_following_caravan:
## близко к слоту — walk на base move_speed; далеко — лerp к caravan_sprint_speed
## (унаследованные exports из Gnome). Это даёт «строй идёт спокойно, отстающие
## догоняют бегом» — критично для эскорта подвижной башни и для быстрого
## исполнения команды «Идти сюда» через всю карту.
func _move_toward(to_goal_xz: Vector3, dist: float) -> void:
	var dir: Vector3 = to_goal_xz / dist
	look_at(global_position + dir, Vector3.UP)
	var t: float = clampf(dist / maxf(caravan_full_sprint_distance, 0.001), 0.0, 1.0)
	var speed: float = lerpf(move_speed, caravan_sprint_speed, t)
	velocity = dir * speed


## Цель в `enemy_detect_radius`е + охранной зоне (`combat_leash_radius` от
## центра режима), ТОЛЬКО если её ещё никто из своих не атакует. Если все
## цели в зоне уже заняты — null, копейщик возвращается в строй (формация
## вокруг центра режима / patrol). Дизайн: каждый бьёт своего; целей
## меньше чем юнитов → лишние стоят и ждут.
##
## Claim считается per-tick через скан SOLDIER_GROUP. Дёшево: ~500 ops/сек
## на юнита (10 копейщиков × 5 кандидатов × ~10 сканов/сек между charge'ами).
##
## SKELETON_GROUP — и NEAR, и FAR-LOD скелеты (в отличие от broad-phase,
## которая FAR пропускает).
func _find_target_in_leash() -> Node3D:
	var leash_center: Vector3 = _resolve_squad_center()
	var leash_sq: float = combat_leash_radius * combat_leash_radius
	var detect_sq: float = enemy_detect_radius * enemy_detect_radius
	var nearest: Skeleton = null
	var nearest_d_sq: float = detect_sq
	for n in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		var skel := n as Skeleton
		if skel == null:
			continue
		if not is_instance_valid(skel):
			continue
		var dx_l: float = skel.global_position.x - leash_center.x
		var dz_l: float = skel.global_position.z - leash_center.z
		if dx_l * dx_l + dz_l * dz_l > leash_sq:
			continue
		var d_sq: float = (skel.global_position - global_position).length_squared()
		if d_sq >= detect_sq:
			continue
		if _is_target_claimed_by_other(skel):
			continue
		if d_sq < nearest_d_sq:
			nearest_d_sq = d_sq
			nearest = skel
	return nearest


## True если другой копейщик (НЕ self) уже выбрал эту цель в активной
## боевой фазе (APPROACH / LUNGE / DRIFT). RECOVERY-юниты освобождают
## claim — цель снова свободна для следующего.
##
## Дизайн: каждый бьёт своего. Целей меньше чем юнитов → лишние стоят
## в формации до RECOVERY первого, потом подхватывают.
func _is_target_claimed_by_other(target: Node3D) -> bool:
	for s in get_tree().get_nodes_in_group(SOLDIER_GROUP):
		if s == self or not is_instance_valid(s):
			continue
		var sg := s as SoldierGnome
		if sg == null:
			continue
		match sg._combat_state:
			CombatState.APPROACH, CombatState.LUNGE, CombatState.DRIFT:
				if sg._charge_target == target:
					return true
	return false


## Контактный удар: damage через `Damageable.try_damage`. Если цель выжила
## (не убита с первого удара) — лёгкий knockback в направлении lunge'а.
## Это даёт visual impact «врезался копьём, скелета отшатнуло», а не
## «прошёл насквозь без реакции».
##
## Knockback применяется ТОЛЬКО на survival, чтобы не толкать уже
## queue_free'нутый труп (бесполезно + лишняя физика на пачку умирающих).
func _strike_at(target: Node3D) -> void:
	var damage: float = randf_range(attack_damage_min, attack_damage_max)
	Damageable.try_damage(target, damage)
	# Survival-чек через hp: try_damage может вызвать queue_free, но
	# is_instance_valid останется true до конца кадра. hp поле есть у Enemy.
	var alive: bool = is_instance_valid(target) and "hp" in target and target.hp > 0.0
	if alive:
		Pushable.try_push(target, _charge_dir * strike_knockback_speed, strike_knockback_duration)
	if debug_log and LogConfig.master_enabled:
		print("[SoldierPikeman:%s] удар по %s (dmg=%.1f, alive=%s)" % [name, target.name, damage, str(alive)])
