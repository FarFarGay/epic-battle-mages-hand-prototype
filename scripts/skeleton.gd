class_name Skeleton
extends Enemy
## Простой враг.
## Жизненный цикл базового FSM Enemy: APPROACH → WINDUP → STRIKE → COOLDOWN → APPROACH.
## Skeleton override'ит только конкретику: телеграф замаха (свечение) и сам strike (lunge + damage).
##
## Замах телеграфируется красной подсветкой через смену material_override.
## Удар (`_perform_strike`) — это **физический выпад через apply_knockback самому себе**:
## скелет реально летит в сторону цели, врезается в неё (тело CharacterBody3D
## блокируется тем же CharacterBody3D башни), отскакивает (через
## Enemy._bounce_off_target), и по пути отбрасывает соседей-скелетов
## (через Enemy._push_neighbor).
## Если получает knockback во время замаха — замах отменяется (Enemy._on_knockback
## сбрасывает FSM в APPROACH).
##
## Визуал — общеклассовый: два разделяемых StandardMaterial3D (normal/windup)
## создаются один раз на класс и переиспользуются всеми инстансами скелетов.
## Это позволяет GPU батчить отрисовку (50 скелетов → ~1 draw call на состояние
## вместо 50 уникальных материалов). Цвет тела/замаха задан константами ниже,
## per-instance тонкая настройка не предусмотрена.
##
## Таргетинг: vision-based. Скелет НЕ ходит за фиксированной целью (башней) —
## вместо этого каждый кадр сканирует группу `skeleton_target` (палатки лагеря,
## вышедшие из палаток гномы) в радиусе vision_radius и выбирает ближайшего.
## Параметр `_targets` базового Enemy игнорируется — override get_active_target
## заменяет его на vision-скан.
##
## Без цели в зоне зрения скелет НЕ стоит. Override _ai_step переключает в
## фазу wander: WANDERING (шагает к случайной точке медленно) → RESTING
## (стоит rest_min..rest_max сек) → новая точка. Каждый скелет асинхронен:
## таймер RESTING стартует с randf_range(0, wander_rest_max) — желания
## идти разносятся во времени. Появилась цель → wander заглушается, FSM
## (super._ai_step) возобновляет APPROACH → WINDUP → STRIKE.
##
## LOD: на больших стаях (100+) каждый скелет на каждом физкадре делает
## distance-чек и потенциально vision-скан группы — это нагрузка O(N²) в
## худшем случае. Вместо честного «считаем всё» на дальних врагах:
##   - LOD NEAR (≤25м от камеры): полная частота AI и vision (как было).
##   - LOD MID (25..50м): AI каждый 2-й тик, vision_scan каждые 0.3с.
##   - LOD FAR (>50м): AI каждый 3-й тик, vision_scan каждые 0.6с.
## Уровень переоценивается раз в 0.5с (lod_check_interval), фазы рандомизированы
## между инстансами. Скип AI — только в APPROACH/wander (в WINDUP/STRIKE/COOLDOWN
## — всегда полный тик, чтобы FSM-таймеры не зависли в середине замаха).
## Knockback и гравитация работают на полной частоте всегда — иначе хлопок и
## отскоки сломаются.

const BODY_ALBEDO_COLOR := Color(0.88, 0.85, 0.78, 1.0)
const WINDUP_EMISSION_COLOR := Color(1.0, 0.2, 0.2, 1.0)
const WINDUP_EMISSION_INTENSITY := 1.5
## Группа целей: палатки лагеря и активные гномы. Скелет находит «глазами».
const TARGET_GROUP := &"skeleton_target"

enum WanderPhase { RESTING, WANDERING }

@export_group("Vision")
## Дальность зрения скелета. Цель в этом радиусе считается «увиденной» и
## выбирается как target. Без vision-цели скелет переходит в wander.
@export var vision_radius: float = 12.0
@export_group("")

@export_group("Vision scan throttle")
## Период между ре-сканами целей (с). Цель кэшируется и читается всеми вызовами
## get_active_target внутри одного физкадра — раньше скан group'ы проходил
## 2-3 раза за тик на каждом скелете (50 врагов × 3 скана × 60fps).
## С throttle'ом и кэшем — ~1/interval сканов в секунду на скелета.
## Если кэшированная цель умерла или вышла из группы — рескан принудительно.
@export var vision_scan_interval: float = 0.15
@export_group("")

@export_group("Wander (без цели)")
## Скорость патруля без цели — заметно медленнее боевой move_speed.
@export var wander_speed: float = 1.2
## Расстояние до следующей wander-точки выбирается randf_range из этого диапазона.
@export var wander_distance_min: float = 5.0
@export var wander_distance_max: float = 15.0
## Длительность RESTING-фазы — пауза между переходами.
@export var wander_rest_min: float = 1.0
@export var wander_rest_max: float = 3.0
## Половина стороны квадратной карты от центра (0,0). Wander-точка клампится
## в этих пределах, чтобы скелет не уходил за пределы пола.
@export var wander_map_half_extent: float = 95.0
## Дистанция до wander-точки, на которой считаем «дошёл» и начинаем отдыхать.
@export var wander_arrival: float = 0.8
@export_group("")

@export_group("Strike (физический выпад)")
@export var lunge_speed: float = 8.0  # m/s в момент удара
@export var lunge_duration: float = 0.2  # секунды knockback'а на сам выпад
@export_group("")

@export_group("Shatter (рассыпание на смерти)")
@export var shatter_fragment_count: int = 7
@export var shatter_lifetime: float = 2.0
@export var shatter_color: Color = BODY_ALBEDO_COLOR
@export_group("")

@export_group("LOD (масштабирование на 100+ скелетов)")
## Дистанция до камеры, ближе которой скелет работает на полной частоте.
## За пределами — снижаем нагрузку: реже сканируем цели и пропускаем AI-тики
## в спокойных состояниях. Значения зависят от размера карты и FOV камеры.
@export var lod_near_distance: float = 25.0
## Дистанция до камеры, дальше которой минимальная частота AI/vision.
## Между near и far — промежуточный уровень (~50% частоты).
@export var lod_far_distance: float = 50.0
## Период переоценки LOD-уровня (с). Дистанция меряется не каждый кадр —
## per-skeleton distance-чек на 100 врагов сам по себе нагрузка.
@export var lod_check_interval: float = 0.5
@export_group("")

static var _shared_normal_material: StandardMaterial3D
static var _shared_windup_material: StandardMaterial3D

enum LodLevel { NEAR, MID, FAR }

var _wander_phase: int = WanderPhase.RESTING
var _wander_target: Vector3 = Vector3.INF
var _rest_timer: float = 0.0
var _cached_target: Node3D = null
var _vision_scan_timer: float = 0.0
var _lod_level: int = LodLevel.NEAR
var _lod_check_timer: float = 0.0
## Счётчик AI-тиков для skip-логики (mid: каждый 2-й, far: каждый 3-й).
var _lod_ai_tick_counter: int = 0

@onready var _mesh: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	# Унаследованный _ready регистрирует Damageable/Pushable и подключает EventBus.
	# Без super._ready() всё это потерялось бы только для скелетов.
	super._ready()
	_ensure_shared_materials()
	if _mesh:
		# Все скелеты делят два материала на класс — никаких .duplicate() per-instance.
		# Переключение состояния = смена ссылки в material_override → GPU батчит.
		_mesh.material_override = _shared_normal_material
	# Async-старт: rest_timer случайный в [0, max] — спавн партии не выводит
	# всех в WANDERING одновременно, движение лагеря-вне-цели выглядит живым.
	_rest_timer = randf_range(0.0, wander_rest_max)
	_wander_phase = WanderPhase.RESTING
	# Фазовый сдвиг скана: 50 скелетов не должны рескан'ить группу в один кадр.
	_vision_scan_timer = randf() * vision_scan_interval
	# Фазовый сдвиг LOD-чека по той же причине: 100 distance.distance_to() в
	# одном кадре — само по себе нагрузка, размазываем по 0..lod_check_interval.
	_lod_check_timer = randf() * lod_check_interval
	# Стартовый AI-counter тоже рандомный — иначе все mid-LOD скелеты пропустят
	# один и тот же кадр, и в нём кадровая нагрузка просядет «волной».
	_lod_ai_tick_counter = randi() % 6


static func _ensure_shared_materials() -> void:
	if _shared_normal_material == null:
		var normal := StandardMaterial3D.new()
		normal.albedo_color = BODY_ALBEDO_COLOR
		_shared_normal_material = normal
	if _shared_windup_material == null:
		var windup := StandardMaterial3D.new()
		windup.albedo_color = BODY_ALBEDO_COLOR
		windup.emission_enabled = true
		windup.emission = WINDUP_EMISSION_COLOR
		windup.emission_energy_multiplier = WINDUP_EMISSION_INTENSITY
		_shared_windup_material = windup


func _on_state_enter(new_state: int) -> void:
	if new_state == AttackState.WINDUP:
		_set_glow(true)


func _on_state_exit(old_state: int) -> void:
	if old_state == AttackState.WINDUP:
		_set_glow(false)


## Override _ai_step: при наличии цели — обычный FSM (super), без цели — wander.
## Базовый _ai_step при null target обнуляет скорость и выходит — нам это не нужно.
##
## LOD-skip применяем ТОЛЬКО в APPROACH (и в wander, который тоже approach-фаза):
##   - WINDUP — таймер замаха декрементируется здесь же (enemy.gd:197), скип
##     заморозил бы скелета в анимации замаха;
##   - STRIKE — транзитное, один тик;
##   - COOLDOWN — таймер тикает в base _physics_process независимо, а сам
##     _ai_step здесь только зануляет velocity — пропуск ничего не меняет
##     (velocity всё равно близка к нулю после windup → strike), так что в
##     COOLDOWN тоже допустимо скипать. Но проще консервативно — скип только
##     в APPROACH, чтобы поведение в бою было идентично near-скелетам.
func _ai_step(delta: float) -> void:
	if _state == AttackState.APPROACH and _lod_should_skip_ai_tick():
		# Velocity сохраняется — скелет едет по инерции до следующего полного
		# тика. move_and_slide отработает коллизии нормально.
		return
	if get_active_target():
		super._ai_step(delta)
	else:
		_wander_tick(delta)


## Skip-предикат для текущего LOD. Близкие — каждый кадр (false). Средние —
## каждый 2-й (true в кадрах !% 2). Далёкие — каждый 3-й. Считаем по
## per-instance counter, увеличиваем здесь же.
func _lod_should_skip_ai_tick() -> bool:
	_lod_ai_tick_counter += 1
	match _lod_level:
		LodLevel.NEAR:
			return false
		LodLevel.MID:
			return (_lod_ai_tick_counter % 2) != 0
		LodLevel.FAR:
			return (_lod_ai_tick_counter % 3) != 0
	return false


## Множитель vision_scan_interval по LOD. Близкие сканируют каждые 0.15с,
## средние — 0.3с, далёкие — 0.6с. Reaction-time дальних чуть хуже, но они
## вне камеры и игрок этого не видит.
func _lod_vision_multiplier() -> float:
	match _lod_level:
		LodLevel.NEAR:
			return 1.0
		LodLevel.MID:
			return 2.0
		LodLevel.FAR:
			return 4.0
	return 1.0


## Расчёт LOD-уровня по дистанции до активной камеры. Камера всегда жива (в
## отличие от Tower, которая может queue_free), и распределение скелетов
## вокруг камеры лучше отражает «что видит игрок» — рендер-LOD пока не делаем,
## но вне-кадра скелеты всё равно нужны (идут к лагерю), просто реже.
func _update_lod_level() -> void:
	if not is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_lod_level = LodLevel.NEAR
		return
	var d: float = global_position.distance_to(camera.global_position)
	if d <= lod_near_distance:
		_lod_level = LodLevel.NEAR
	elif d <= lod_far_distance:
		_lod_level = LodLevel.MID
	else:
		_lod_level = LodLevel.FAR


func _wander_tick(delta: float) -> void:
	match _wander_phase:
		WanderPhase.RESTING:
			velocity.x = 0.0
			velocity.z = 0.0
			_rest_timer = maxf(_rest_timer - delta, 0.0)
			if _rest_timer <= 0.0:
				_wander_target = _pick_wander_target()
				_wander_phase = WanderPhase.WANDERING
		WanderPhase.WANDERING:
			var to_target := _wander_target - global_position
			to_target.y = 0.0
			if to_target.length() <= wander_arrival:
				velocity.x = 0.0
				velocity.z = 0.0
				_rest_timer = randf_range(wander_rest_min, wander_rest_max)
				_wander_phase = WanderPhase.RESTING
				return
			var dir := to_target.normalized()
			velocity.x = dir.x * wander_speed
			velocity.z = dir.z * wander_speed


func _pick_wander_target() -> Vector3:
	var angle := randf() * TAU
	var dist := randf_range(wander_distance_min, wander_distance_max)
	var target := global_position + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
	target.x = clampf(target.x, -wander_map_half_extent, wander_map_half_extent)
	target.z = clampf(target.z, -wander_map_half_extent, wander_map_half_extent)
	target.y = global_position.y
	return target


## Кэш + throttle сканера. _physics_process тикает таймер и при истечении
## (или порче кэша) запускает _scan_target. Все обращения get_active_target в
## пределах одного физкадра берут из кэша — даже base Enemy._ai_step и
## _resolve_knockback_contacts.
##
## LOD: каждые lod_check_interval секунд переоцениваем дистанцию до камеры и
## выставляем _lod_level. Множитель частоты сканирования и skip AI-тиков
## применяются дальше в _ai_step / vision-блоке.
func _physics_process(delta: float) -> void:
	_lod_check_timer -= delta
	if _lod_check_timer <= 0.0:
		_update_lod_level()
		_lod_check_timer = lod_check_interval

	_vision_scan_timer -= delta
	var stale := _cached_target == null \
		or not is_instance_valid(_cached_target) \
		or not _cached_target.is_in_group(TARGET_GROUP)
	if _vision_scan_timer <= 0.0 or stale:
		_cached_target = _scan_target()
		_vision_scan_timer = vision_scan_interval * _lod_vision_multiplier()
	super._physics_process(delta)


## Override базы Enemy.get_active_target: возвращаем кэшированную цель, если она
## ещё валидна и в группе skeleton_target. Иначе nil — _physics_process на
## следующем тике рескан'ит. Урон / wander сами отработают пустой target.
func get_active_target() -> Node3D:
	if _cached_target == null:
		return null
	if not is_instance_valid(_cached_target):
		return null
	if not _cached_target.is_in_group(TARGET_GROUP):
		return null
	return _cached_target


## Сам скан — ближайшая в vision_radius из группы skeleton_target. Раньше был
## бодиком get_active_target.
func _scan_target() -> Node3D:
	var nearest: Node3D = null
	var nearest_dist_sq := vision_radius * vision_radius
	for n in get_tree().get_nodes_in_group(TARGET_GROUP):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var d_sq: float = (node.global_position - global_position).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = node
	return nearest


func _perform_strike(_target: Node3D) -> void:
	# Перевыбираем цель — между _ai_step и _perform_strike та могла умереть.
	# Параметр _target тут не используем: он мог стать невалидным, и проверять
	# его freed-инстансом небезопасно. get_active_target сам пропускает мёртвых.
	var active := get_active_target()
	if not active:
		return
	# Урон — до выпада, чтобы логически «удар попал», даже если bounce-off
	# отбросит скелета на следующем кадре.
	Damageable.try_damage(active, attack_damage)
	_do_lunge(active)


func _do_lunge(target: Node3D) -> void:
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < VecUtil.EPSILON_SQ:
		return
	var dir := to_target.normalized()
	# Self-knockback ВНЕ публичного apply_knockback — иначе наш собственный
	# выпад вызвал бы _on_knockback хук, и подклассы, навешивающие на него
	# логику отмены состояний, словили бы свой же lunge.
	_apply_velocity_change(dir * lunge_speed, lunge_duration)


func _on_destroyed() -> void:
	# Прячем тело и спавним осколки. Осколки живут в _effects_root — переживают
	# queue_free самого скелета, который произойдёт в Enemy.take_damage сразу после.
	if _mesh:
		_mesh.visible = false
	if _effects_root:
		ShatterEffect.spawn(_effects_root, global_position, shatter_color,
			shatter_fragment_count, shatter_lifetime)


func _set_glow(active: bool) -> void:
	if not _mesh:
		return
	# Свап ссылки — никаких чтений/записей свойств материала. Материалы общие,
	# мутировать их per-state нельзя (поломались бы все остальные скелеты).
	_mesh.material_override = _shared_windup_material if active else _shared_normal_material
