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
## Enemy._bounce_off_target). Lunge-domino через `Enemy._push_neighbor`
## не работает: skel-skel коллизии отключены через `MASK_SKELETON` без
## бита ENEMIES (см. layers.gd), get_slide_collision не регистрирует
## другого скелета как collider. Сделано для перфоманса в плотных кластерах.
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
## Группа всех живых скелетов — для перфоманс-HUD (счётчик + LOD-распределение).
## Отдельная от Damageable.GROUP, чтобы HUD не фильтровал по `is Skeleton`.
const SKELETON_GROUP := &"skeleton"

## Запас по дистанции при валидации цели в `_perform_strike`. Замах длится
## attack_windup секунд; за это время цель (живой гном) может пройти
## move_speed × attack_windup ≈ 0.6м. Множитель 1.5 от attack_range покрывает
## этот сдвиг + капсулу скелета. Если цель ушла дальше — strike мажет
## (отмена в _perform_strike), вместо «удар на 11м без контакта».
const WINDUP_TARGET_RANGE_SLACK: float = 1.5

enum WanderPhase { RESTING, WANDERING }

@export_group("Vision")
## Дальность зрения скелета. Цель в этом радиусе считается «увиденной» и
## выбирается как target. Без vision-цели скелет переходит в wander.
@export var vision_radius: float = 12.0
@export_group("")

@export_group("Vision scan throttle")
## Период между ре-сканами целей (с). Цель кэшируется и читается всеми вызовами
## get_active_target внутри одного физкадра — раньше скан group'ы проходил
## 2-3 раза за тик на каждом скелете. С throttle'ом и кэшем — ~1/interval
## сканов в секунду на скелета. Если кэшированная цель умерла или вышла из
## группы — рескан принудительно (NB: null — НЕ stale, см. _physics_process,
## fix этап 43).
##
## История: 0.15 → 0.3 → 0.4. На 2000 скелетах при 0.3с было 0.30ms self
## per physics-frame на _scan_target (после fix throttle'а). 0.4 даёт
## дополнительные 25% экономии — заметно при background_cap=600.
@export var vision_scan_interval: float = 0.4
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
## в этих пределах, чтобы скелет не уходил за пределы пола. Для карты
## 400×400 — 195 (200 − 5м буфер от края). Должно совпадать с Gnome.
@export var wander_map_half_extent: float = 195.0
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
## Кратность пропуска физтика для FAR-скелетов. 1 = каждый физкадр,
## 4 = каждый 4-й (60→15Гц). На 1900 FAR-скелетах _far_step (knockback.tick,
## vision-валидность, AI, position-write) — основной пожиратель physics_ms
## после того как broad-phase отключён через CollisionShape3D.disabled.
## Кратность 4 даёт пропорциональное падение нагрузки. Визуально незаметно
## (FAR > 50м от камеры). Slam-knockback по FAR задерживается максимум на
## divisor × 16.6мс = 67мс — игрок не успевает заметить, отзумленная камера
## смазывает движение.
##
## История: 3 → 4 (этап 43, 2000 скелетов на профайлере: _far_step 2.80ms /
## 557 calls. С divisor=4 ожидаю ~2.1ms / 418 calls).
@export_range(1, 6) var lod_far_tick_divisor: int = 4
## Кратность пропуска физтика для MID-скелетов (между lod_near_distance и
## lod_far_distance). 4 = каждый 4-й физкадр (60→15Гц). MID — это «средняя»
## зона, видна игроку, но менее детально. На 300+ MID скелетах в кластере
## вокруг башни move_and_slide со slide-iterations об палатки/башню — ещё
## один пожиратель physics_ms. Скорость движения сохраняется компенсацией
## `velocity *= divisor` в _ai_step (один move_and_slide на N тиков
## переносит N-кратное движение). Tunneling-риск: skel.move_speed=2.7 × 4 ×
## 0.0167 = 0.18м/тик при радиусе 0.4м — запас ×2, безопасно.
##
## История: 3 → 4 (этап 43, та же причина что и FAR).
@export_range(1, 6) var lod_mid_tick_divisor: int = 4
## Угол полу-cone'а «впереди камеры». Скелет вне этого конуса (то есть строго
## позади камеры или сильно сбоку) форсируется в FAR независимо от расстояния:
## его не видно игроку, симулировать его дешёво безопасно. 60° = 120° полный
## cone, что с запасом покрывает горизонтальный FOV ~95° (FOV=70 + 16:9).
## Если задрать до 90° — frustum-override выключится (всё что в полуcфере перед
## камерой считается «видимым»).
@export_range(30.0, 90.0) var lod_offscreen_half_angle_deg: float = 60.0
@export_group("")

@export_group("Neighbor avoidance (boids-style)")
## Радиус «personal space» — на этом расстоянии скелеты начинают мягко
## отталкиваться. Должно быть ≥ capsule_radius × 2 = 0.8м с запасом для
## визуально-комфортного зазора между скелетами в плотной толпе.
## Замена physics-парам (skel-skel коллизии отключены ради перфоманса).
@export var neighbor_avoidance_radius: float = 1.5
## Сила отталкивания, выраженная как доля от move_speed. 0.5 = avoidance
## может прибавить к velocity до 0.5 × move_speed = 1.35 м/с (при move_speed
## 2.7). Меньше — толпа собирается плотнее, больше — скелеты сильнее
## расступаются. 0 — avoidance выключен (вернётся «толпа фантомов»).
@export_range(0.0, 2.0) var neighbor_avoidance_strength: float = 0.5
@export_group("")

static var _shared_normal_material: StandardMaterial3D
static var _shared_windup_material: StandardMaterial3D

## Размер cell'а в spatial-grid'е целей. Оптимально ~vision_radius=12м,
## округлено до 12 для совпадения по решётке. Скелет на vision-скане
## смотрит только 9 cell'ов (3×3 вокруг себя), не всю группу из 144 целей.
const TARGET_GRID_CELL_SIZE: float = 12.0
## Период обновления spatial-grid'а целей (с). Все скелеты смотрят один
## глобальный snapshot. Stale-границы: гнома двигается ≤1.6м/с × 0.4с = 0.64м,
## палатки и большинство гномов в зоне атаки стоят на месте — тоже
## неотличимо. На быстро-движущихся целях (защитники-патрулеры на 1.0м/с)
## позиция в snapshot'е может отставать на полметра — ок для вижн-фильтра.
const TARGET_GRID_REFRESH_INTERVAL: float = 0.4

## Spatial grid: { Vector2i(cell_x, cell_z) -> Array of [Vector3 pos, Node3D node] }.
## Глобальный для всех скелетов, обновляется лениво при первом скане после
## TARGET_GRID_REFRESH_INTERVAL. Заменяет полный обход group skeleton_target
## (144 элементов × 5000 сканов/сек = 720k distance-checks/сек) на 9-cell
## lookup (~10-50 элементов на скан в зоне Camp, 0 в пустой зоне).
static var _target_grid: Dictionary = {}
static var _target_grid_time: float = -1000.0


## Возвращает координаты cell'а для произвольной мировой позиции по плоскости XZ.
static func _grid_cell(pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(pos.x / TARGET_GRID_CELL_SIZE)),
		int(floor(pos.z / TARGET_GRID_CELL_SIZE)),
	)


## Лениво пересоздаёт _target_grid из group skeleton_target. Зовётся в
## начале _scan_target. Один pass по группе раз в TARGET_GRID_REFRESH_INTERVAL
## секунд глобально (вместо одного pass'а на каждый скан каждого скелета).
static func _maybe_refresh_target_grid(tree: SceneTree) -> void:
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if now - _target_grid_time < TARGET_GRID_REFRESH_INTERVAL:
		return
	_target_grid_time = now
	_target_grid.clear()
	for n in tree.get_nodes_in_group(TARGET_GROUP):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var cell := _grid_cell(node.global_position)
		if not _target_grid.has(cell):
			_target_grid[cell] = []
		var entries: Array = _target_grid[cell]
		entries.append([node.global_position, node])

## Размер cell'а в spatial-grid'е скелетов для boids-avoidance. 4м — компромисс
## между плотностью cell'ов и cost'ом запросов. 3×3 cell'ов = 12м, что больше
## чем typical neighbor_avoidance_radius=1.5м с запасом.
const SKEL_GRID_CELL_SIZE: float = 4.0
## Период обновления skel-grid'а (с). Скелет двигается ≤2.7м/с × 0.3с = 0.81м,
## drift в snapshot'е меньше cell-size'а — позиция в grid'е достаточно свежая
## для avoidance (мягкое отталкивание не требует pixel-perfect позиций).
const SKEL_GRID_REFRESH_INTERVAL: float = 0.3

## Spatial grid позиций скелетов: { Vector2i(cell_x, cell_z) → Array of
## [Vector3 pos, Node3D node] }. Аналогично _target_grid, но с группой
## SKELETON_GROUP. Используется в _apply_neighbor_avoidance для boids-style
## раздвигания — заменяет physics-пары skel-skel (отключены через
## MASK_SKELETON без бита ENEMIES, см. layers.gd).
static var _skel_grid: Dictionary = {}
static var _skel_grid_time: float = -1000.0


## Лениво пересоздаёт _skel_grid из группы skeleton. Зовётся в начале
## _apply_neighbor_avoidance. Так же как target-grid: ленивая refresh'ка
## раз в SKEL_GRID_REFRESH_INTERVAL глобально, все скелеты читают snapshot.
static func _maybe_refresh_skel_grid(tree: SceneTree) -> void:
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if now - _skel_grid_time < SKEL_GRID_REFRESH_INTERVAL:
		return
	_skel_grid_time = now
	_skel_grid.clear()
	for n in tree.get_nodes_in_group(SKELETON_GROUP):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var cell := Vector2i(
			int(floor(node.global_position.x / SKEL_GRID_CELL_SIZE)),
			int(floor(node.global_position.z / SKEL_GRID_CELL_SIZE)),
		)
		if not _skel_grid.has(cell):
			_skel_grid[cell] = []
		var entries: Array = _skel_grid[cell]
		entries.append([node.global_position, node])

enum LodLevel { NEAR, MID, FAR }

var _wander_phase: int = WanderPhase.RESTING
var _wander_target: Vector3 = Vector3.INF
var _rest_timer: float = 0.0
var _cached_target: Node3D = null
var _vision_scan_timer: float = 0.0
## Цель, на которую сейчас идёт замах. Защёлкивается в `_on_state_enter(WINDUP)`,
## используется в `_perform_strike` вместо текущего `_cached_target` —
## иначе рескан зрения внутри 0.4с замаха мог подменить цель на ближайшего
## гнома, и удар наносился по нему **без contact-чека**: Damageable.try_damage
## не проверяет дистанцию, и при vision_radius=12 это давало мгновенный урон
## по цели за 11м. Теперь правила такие:
##   - WINDUP запоминает того, на кого замахнулся.
##   - STRIKE бьёт его, если жив + в группе + не дальше attack_range × WINDUP_TARGET_RANGE_SLACK.
##   - Если протух — strike отменяется, COOLDOWN тикает как обычно, на следующем
##     APPROACH FSM выберет новую цель естественным образом.
var _windup_target: Node3D = null
## Принудительная цель — wave-скелеты получают её на спавне и идут к ней
## независимо от vision_radius (палатка лагеря в 100м от спавн-точки тоже
## считается видимой). Если умирает или выходит из skeleton_target — fallback
## на обычный vision-scan: скелет к этому моменту уже подошёл к лагерю и
## найдёт другие цели в радиусе.
var _forced_target: Node3D = null
var _lod_level: int = LodLevel.NEAR
var _lod_check_timer: float = 0.0
## Счётчик AI-тиков для skip-логики (mid: каждый 2-й, far: каждый 3-й).
var _lod_ai_tick_counter: int = 0
## Счётчик физкадров для FAR-divisor: пропускаем _far_step для всех тиков,
## кроме каждого N-го (N = lod_far_tick_divisor). На пропускаемых тиках
## возврат сразу — никаких таймеров, vision'а, position-write'ов.
var _far_phys_tick_counter: int = 0
## Аналогичный счётчик для MID-divisor: пропускаем super._physics_process для
## всех тиков, кроме каждого N-го (N = lod_mid_tick_divisor). На пропускаемых
## тиках возврат до vision-таймера — никаких m_a_s/AI/scan'ов.
var _mid_phys_tick_counter: int = 0
## Кэшированный cos(half-angle) для frustum-override в _update_lod_level —
## пересчитывается в _ready после применения экспорта. Дешевле, чем гонять
## deg_to_rad+cos на каждом LOD-чеке (раз в 0.5с × 2000 скелетов).
var _lod_offscreen_cos: float = 0.5
## Гистерезисный cos: чтобы войти обратно в NEAR/MID после frustum-FAR,
## нужно зайти в cone глубже на ~5° от границы. Без этого скелет на самой
## границе угла дёргается NEAR↔FAR каждые lod_check_interval (0.5с) с
## пересчётом collision_layer и broad-phase. _lod_offscreen_cos_exit < _lod_offscreen_cos
## (cos монотонно убывает на [0..π], меньше cos = больше угол).
var _lod_offscreen_cos_exit: float = 0.4

@onready var _mesh: MeshInstance3D = $MeshInstance3D
## Ссылка на коллайдер — нужна, чтобы в FAR-режиме отключать его через
## `disabled = true`. Это убирает скелета из broad-phase BVH целиком, а не
## просто из active-pair тестов (как делал раньше mask=0). На 2000 скелетах
## broad-phase индексировал 2000 движущихся AABB каждый кадр — давало 25+мс
## TIME_PHYSICS_PROCESS, при том что собственно move_and_slide почти не вызывался.
@onready var _collision_shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	# Унаследованный _ready регистрирует Damageable/Pushable и подключает EventBus.
	# Без super._ready() всё это потерялось бы только для скелетов.
	super._ready()
	add_to_group(SKELETON_GROUP)
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
	# Фазовый сдвиг FAR-divisor counter'а — иначе все FAR-скелеты бегут _far_step
	# в одном и том же физкадре каждые divisor тиков (волна нагрузки).
	_far_phys_tick_counter = randi() % 6
	# То же для MID-divisor — иначе 300 MID-скелетов одновременно делают
	# super._physics_process в одном кадре, кадровая нагрузка всплеском.
	_mid_phys_tick_counter = randi() % 4
	# Прекомпьют cos(half-angle) для frustum-override LOD'а. Hysteresis: 5°
	# шире на выходе — чтобы скелет на границе cone'а не флипал FAR↔NEAR/MID
	# каждые 0.5с (каждый flip = collision_layer write + broad-phase rebuild).
	_lod_offscreen_cos = cos(deg_to_rad(lod_offscreen_half_angle_deg))
	_lod_offscreen_cos_exit = cos(deg_to_rad(lod_offscreen_half_angle_deg + 5.0))
	# Применяем физ-режим под стартовый _lod_level (по дефолту NEAR). Без этого
	# initial mask/layer/disabled полагались бы на значения в skeleton.tscn (16/39).
	# Сейчас они совпадают, но любая правка маски в .tscn тихо ломала бы первый
	# кадр всех NEAR-скелетов до первого LOD-перехода (через lod_check_interval).
	_apply_lod_physics_mode()


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
		# Защёлкиваем цель замаха — strike будет бить её, не текущий cached_target.
		# get_active_target() возвращает _cached_target (override skeleton'a), а
		# тот свежий: WINDUP запускается из _approach_target в том же тике, когда
		# дистанция упала ≤ attack_range, т.е. рескан был только что.
		_windup_target = get_active_target()


func _on_state_exit(old_state: int) -> void:
	if old_state == AttackState.WINDUP:
		_set_glow(false)
		# _windup_target НЕ обнуляется здесь: STRIKE → _perform_strike читает
		# его, дальше сам очищает. Если выйти из WINDUP в APPROACH через
		# _on_knockback (Enemy.gd) — то же самое: следующий WINDUP перезапишет.


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
	# Boids-style avoidance: только NEAR. MID и FAR пропускаем — на расстоянии
	# 25м+ от камеры мелкие накладки тимы не читаются, а boids стоит
	# ~18мкс/call. На 2000 скелетах при divisor=4 в среднем 50-100 NEAR в
	# кадре — экономия ~1ms vs прежнее «NEAR+MID». Если плотные кучи на MID
	# станут визуально мешать, можно вернуть `_lod_level != LodLevel.FAR`.
	# История: NEAR+MID → NEAR-only (этап 43, профайлер: 1.95ms / 105 calls).
	if _lod_level == LodLevel.NEAR and _state == AttackState.APPROACH:
		_apply_neighbor_avoidance()
	# MID-divisor компенсация: super._physics_process вызывает нас раз в N
	# физкадров (на пропускаемых _physics_process делает early return). Один
	# move_and_slide() в этом тике должен покрыть N кадров пути → множим
	# velocity на divisor. Knockback не трогаем — _ai_step сюда не попадает,
	# когда _knockback.is_active (super._physics_process в base Enemy.gd
	# делит ветку: knockback → friction, иначе → _ai_step).
	if _lod_level == LodLevel.MID and lod_mid_tick_divisor > 1:
		var mult := float(lod_mid_tick_divisor)
		velocity.x *= mult
		velocity.z *= mult


## Boids-style раздвигание соседей через _skel_grid. Заменяет физическое
## skel-skel столкновение (отключено через MASK_SKELETON без ENEMIES).
##
## Алгоритм: суммируем векторы от каждого соседа в neighbor_avoidance_radius,
## взвешенные linear-falloff (1 в эпицентре, 0 на границе радиуса). Каждый
## вектор — нормированное направление от соседа × falloff. Итоговый push
## ограничивается max_avoid = move_speed × neighbor_avoidance_strength,
## чтобы avoidance не доминировал над тягой к цели.
##
## Цена: 9-cell scan × ~3-5 entries/cell × ~10 ops = ~200 ops/scan. На
## 100 NEAR + 300 MID скелетов с разной частотой тиков = ~12k вызовов/сек ×
## 200 ops × 5ns = ~12мс/сек ~ 0.2мс/кадр.
func _apply_neighbor_avoidance() -> void:
	if neighbor_avoidance_strength <= 0.0:
		return
	Skeleton._maybe_refresh_skel_grid(get_tree())
	var skel_pos := global_position
	var skel_cell := Vector2i(
		int(floor(skel_pos.x / SKEL_GRID_CELL_SIZE)),
		int(floor(skel_pos.z / SKEL_GRID_CELL_SIZE)),
	)
	var r: float = neighbor_avoidance_radius
	var r_sq: float = r * r
	var push_x := 0.0
	var push_z := 0.0
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var cell := Vector2i(skel_cell.x + dx, skel_cell.y + dz)
			if not Skeleton._skel_grid.has(cell):
				continue
			var entries: Array = Skeleton._skel_grid[cell]
			for entry in entries:
				# Self-фильтр через идентичность ноды, НЕ через d_sq < epsilon.
				# Снимок позиции в grid'е stale (refresh раз в 0.3с), а скелет
				# успевает уйти на ~0.81м за это время — d_sq против собственной
				# stale-копии может быть 0.5+ м². Эпсилон-чек этот случай
				# пропускал бы как чужого соседа, давая фантомный push в ту
				# точку, откуда мы только что пришли. Сравнение по reference
				# не зависит от движения.
				if entry[1] == self:
					continue
				var npos: Vector3 = entry[0]
				var dx_l := skel_pos.x - npos.x
				var dz_l := skel_pos.z - npos.z
				var d_sq := dx_l * dx_l + dz_l * dz_l
				# Доп. защита от d≈0 (двойной спавн на одной точке) — без
				# деления на 0 в нормализации ниже.
				if d_sq < 0.0001:
					continue
				if d_sq > r_sq:
					continue
				var d := sqrt(d_sq)
				var falloff: float = 1.0 - d / r
				push_x += (dx_l / d) * falloff
				push_z += (dz_l / d) * falloff
	if push_x == 0.0 and push_z == 0.0:
		return
	# Кап по магнитуде — avoidance не должен доминировать. max = move_speed × strength.
	var max_avoid: float = move_speed * neighbor_avoidance_strength
	var mag: float = sqrt(push_x * push_x + push_z * push_z)
	if mag > max_avoid:
		var scale: float = max_avoid / mag
		push_x *= scale
		push_z *= scale
	velocity.x += push_x
	velocity.z += push_z


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


## Публичный геттер LOD-уровня — читает PerfHUD для отображения распределения
## NEAR/MID/FAR. Обращаться напрямую к `_lod_level` снаружи нельзя (приватка).
func get_lod_level() -> int:
	return _lod_level


## Расчёт LOD-уровня по дистанции до **точки интереса камеры**, а не до самой
## Camera3D. Точка интереса = `Camera3D.get_parent()` если он Node3D — это наш
## CameraRig, который lerp'ом следует за Tower. Зум камеры (через Camera3D.position
## × _zoom) меняет реальную позицию Camera3D в мире, но НЕ меняет CameraRig'a.
##
## Почему важно: при отзумленной камере (zoom=2.5, Camera3D на ~111м от Tower)
## все скелеты возле башни оказывались FAR от Camera3D — slam терял по ним
## цели через collision_layer. С привязкой к CameraRig границы LOD стабильны
## независимо от зума.
##
## **Frustum-override:** если скелет вне cone'а вокруг forward-направления
## Camera3D (угол > lod_offscreen_half_angle_deg), он форсируется в FAR
## независимо от расстояния. Это съедает 50-65% NEAR/MID-скелетов в плотных
## кластерах: те, что строго позади камеры или сильно сбоку, не нужны для
## визуальной точности. Cone проверяется от позиции **Camera3D** (а не
## CameraRig'a) — это реальная точка наблюдения; вектор-вперёд берётся из
## basis Camera3D. Симуляция продолжается дёшево (через FAR-режим), волна
## не «замерзает» когда отвернёшься — но physics-нагрузка падает резко.
##
## Fallback: если нет parent-Node3D (странная сцена) — берём global_position
## самой Camera3D, лучше что-то чем пустой LOD-расчёт.
##
## При смене уровня вызывается _apply_lod_physics_mode — переключает
## collision_layer/mask и CollisionShape3D.disabled, что убирает скелета из
## broad-phase BVH в FAR. На 1000+ скелетах это главный win по перфомансу.
func _update_lod_level() -> void:
	if not is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_set_lod_level(LodLevel.NEAR)
		return

	# Frustum-cone override: если скелет вне обзора (угол к forward камеры
	# больше half-angle), форсируем FAR. Делаем ДО distance-проверки, чтобы
	# скелеты «строго за камерой» сразу шли в FAR-режим — без lavish NEAR/MID
	# физики. Маленький epsilon на dist чтоб избежать NaN от division.
	#
	# Hysteresis: вход в frustum-FAR по основному cos'у, выход (возврат в
	# NEAR/MID) — только когда заходим заметно глубже в cone (cos_exit, +5°
	# уже). Скелет на границе cone'а уже ничего не дёргает.
	var to_skel: Vector3 = global_position - camera.global_position
	var dist_to_camera: float = to_skel.length()
	if dist_to_camera > 0.001:
		var forward: Vector3 = -camera.global_transform.basis.z
		var cos_angle: float = forward.dot(to_skel) / dist_to_camera
		var threshold: float = _lod_offscreen_cos_exit if _lod_level == LodLevel.FAR else _lod_offscreen_cos
		if cos_angle < threshold:
			_set_lod_level(LodLevel.FAR)
			return

	var anchor: Node3D = camera.get_parent() as Node3D
	var anchor_pos: Vector3 = anchor.global_position if anchor != null else camera.global_position
	var d: float = global_position.distance_to(anchor_pos)
	if d <= lod_near_distance:
		_set_lod_level(LodLevel.NEAR)
	elif d <= lod_far_distance:
		_set_lod_level(LodLevel.MID)
	else:
		_set_lod_level(LodLevel.FAR)


## Атомарная смена LOD-уровня + переключение физического режима. Вынесено,
## чтобы _apply_lod_physics_mode не дёргалось каждые 0.5с впустую если
## уровень не изменился (collision_layer write — мутация, broad-phase
## потенциально перестраивается).
func _set_lod_level(new_level: int) -> void:
	if new_level == _lod_level:
		return
	_lod_level = new_level
	_apply_lod_physics_mode()


## Переключение collision и физического режима по LOD.
## - NEAR/MID: «горячий» режим — collision_layer=ENEMIES, mask=MASK_SKELETON,
##   CollisionShape3D.disabled=false, move_and_slide в _physics_process.
## - FAR: «полностью холодный» режим — collision_layer/mask=0 И
##   CollisionShape3D.disabled=true. Это убирает скелета из broad-phase BVH
##   физсервера полностью: 2000 движущихся FAR-скелетов больше не индексируются
##   и не ребилдят BVH каждый кадр.
##
## Slam доставал FAR-скелетов раньше через layer=COLD_ENEMY +
## MASK_HAND_SLAM-включение. Теперь форма отключена, PhysicsShapeQuery их не
## найдёт — поэтому HandPhysicalSlam._perform_slam делает второй проход по
## группе SKELETON_GROUP с distance²-фильтром, отдельно для FAR-уровня.
##
## Двигается FAR-скелет через global_position += velocity * delta в _far_step
## (без move_and_slide). Когда подходит ближе к камере (MID) — shape включается
## обратно, broad-phase снова видит скелета, и физика работает как обычно.
func _apply_lod_physics_mode() -> void:
	match _lod_level:
		LodLevel.NEAR, LodLevel.MID:
			collision_layer = Layers.ENEMIES
			collision_mask = Layers.MASK_SKELETON
			if _collision_shape:
				_collision_shape.disabled = false
		LodLevel.FAR:
			collision_layer = 0
			collision_mask = 0
			if _collision_shape:
				_collision_shape.disabled = true


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
##
## Для FAR-скелетов вместо super._physics_process (CharacterBody3D + физика)
## вызываем _far_step — «холодный» режим без move_and_slide и без коллизий.
## Дополнительно для FAR применяется divisor: _far_step тикает раз в
## lod_far_tick_divisor физкадров. Это срезает CPU-стоимость 1900 FAR ×
## 60Гц = 114k _far_step вызовов/сек до ~38k при divisor=3. lod_check_timer
## тикает каждый физкадр в wall-clock — иначе FAR-скелеты «застревали» бы
## в FAR на divisor× дольше после того как камера приблизилась.
func _physics_process(delta: float) -> void:
	_lod_check_timer -= delta
	if _lod_check_timer <= 0.0:
		_update_lod_level()
		_lod_check_timer = lod_check_interval

	# Per-LOD divisor: пропускаем основную работу на N-1 из N физкадров.
	# delta на пропускаемых тиках теряется — на «полном» тике компенсируется:
	# - vision-таймер работает в work_delta (×divisor), сохраняя wall-clock частоту;
	# - FAR: _far_step(work_delta) умножает движение/таймеры на divisor;
	# - MID: super._physics_process(delta) тикает обычно, а _ai_step (override
	#   ниже) множит velocity на divisor — один move_and_slide на N тиков
	#   переносит N-кратное движение.
	# NEAR — без divisor'а (полная частота).
	var work_delta: float = delta
	match _lod_level:
		LodLevel.FAR:
			_far_phys_tick_counter += 1
			if (_far_phys_tick_counter % lod_far_tick_divisor) != 0:
				return
			work_delta = delta * float(lod_far_tick_divisor)
		LodLevel.MID:
			_mid_phys_tick_counter += 1
			if (_mid_phys_tick_counter % lod_mid_tick_divisor) != 0:
				return
			work_delta = delta * float(lod_mid_tick_divisor)

	_vision_scan_timer -= work_delta
	# Stale-чек: пересканировать **только** если кэшированная цель умерла или
	# вышла из группы. `_cached_target == null` НЕ stale — это легитимное
	# «целей в зоне нет» (типичное состояние FAR-скелета в поле). Раньше
	# тут было `stale := _cached_target == null or ...`, и бесцельный скелет
	# рескан'ил каждый physics-tick (60Гц), вместо одного раза в 0.3с/0.6с/1.2с
	# по LOD. На 452 скелетах это давало 27k _scan_target/сек вместо ~1.5k —
	# главный пожиратель Physics_Frame. См. профайлер этап 43.
	var stale := false
	if _cached_target != null:
		if not is_instance_valid(_cached_target) or not _cached_target.is_in_group(TARGET_GROUP):
			stale = true
			_cached_target = null
	if _vision_scan_timer <= 0.0 or stale:
		_cached_target = _scan_target()
		_vision_scan_timer = vision_scan_interval * _lod_vision_multiplier()

	# Запоминаем knockback-состояние ДО физ-шага. Тик knockback'а живёт внутри
	# super._physics_process (NEAR/MID) и _far_step (FAR) — после них сравниваем,
	# чтобы детектировать knockback exit и сбросить divisor-counter'ы. Иначе
	# counter может остановиться на «skip-фазе» во время knockback'а и сразу
	# после восстановления первый AI-кадр будет skipped — скелет «глюк-замораживается»
	# на ~16мс (для MID) / ~50мс (для FAR) даже хотя AI хочет двигаться.
	var was_knockback_active := _knockback.is_active()

	if _lod_level == LodLevel.FAR:
		_far_step(work_delta)
	else:
		# NEAR/MID: super тикает с обычным delta. Внутри super → _ai_step (наш
		# override), который для MID множит velocity на divisor.
		super._physics_process(delta)

	# Knockback закончился в этом тике — выравниваем counter'ы в 0, чтобы
	# следующий физкадр был полным AI-тиком (counter % divisor == 0).
	if was_knockback_active and not _knockback.is_active():
		_mid_phys_tick_counter = 0
		_far_phys_tick_counter = 0


## «Холодный» физический шаг для FAR-скелетов: AI считает velocity (через те
## же _ai_step / _wander_tick), но позиция обновляется напрямую через
## global_position += velocity * delta, без move_and_slide. Никаких
## broad-phase коллизий через physics-сервер.
##
## Что теряем:
## - Скелеты сквозят друг друга и палатки вне камеры — но игрок этого не видит.
## - Гравитация не считается. На текущей плоской карте (y=0) это ок: скелет
##   уже стоит на полу с момента спавна, Y не меняется. Если появятся холмы
##   или ямы — FAR-скелеты будут «парить» — нужно будет добавить grounding.
## - `is_on_floor()` всегда false (move_and_slide не вызывался) — но AI на FAR
##   эту инфу не читает.
##
## Что сохраняем:
## - AI-логика (включая LOD-skip в APPROACH).
## - Vision-скан (с LOD-throttle'ом частоты).
## - Knockback-таймер — иначе lunge через `_apply_velocity_change` (Skeleton
##   стартует knockback сам себе как импульс выпада) никогда не затухнет, и
##   FAR-скелет улетит навечно. `_knockback.tick(delta)` обязателен.
## - COOLDOWN-таймер — в base _physics_process он декрементится явно для тика
##   во время knockback'а; здесь повторяем тот же блок.
## - Strike: при наличии цели super._ai_step запустит полный FSM, включая
##   _perform_strike → Damageable.try_damage(target) + _do_lunge — урон по
##   палатке/гному пройдёт независимо от collision-layer'ов.
func _far_step(delta: float) -> void:
	# COOLDOWN-таймер тикает всегда (как в Enemy._physics_process).
	if _state == AttackState.COOLDOWN and _state_timer > 0.0:
		_state_timer = maxf(_state_timer - delta, 0.0)

	_knockback.tick(delta)
	if _knockback.is_active():
		# Под knockback'ом AI заглушен; скорость затухает trение-coeff'ом.
		velocity = _knockback.apply_friction(velocity, delta)
	else:
		if not (_state == AttackState.APPROACH and _lod_should_skip_ai_tick()):
			if get_active_target():
				super._ai_step(delta)
			else:
				_wander_tick(delta)

	# No move_and_slide → position update напрямую. Y не трогаем — пол плоский.
	global_position.x += velocity.x * delta
	global_position.z += velocity.z * delta


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


## Сам скан — ближайшая в vision_radius из группы skeleton_target.
##
## **Spatial grid** ([Skeleton._target_grid]): вместо полного обхода группы
## (144 целей × 5000 сканов/сек = 720k distance-checks) скелет смотрит только
## 9 cell'ов (3×3 вокруг себя). На карте 400×400 при vision_radius=12 и
## cell_size=12 в 9 cell'ах суммарно ~10-50 целей в плотной Camp-зоне и 0 в
## пустой. Снижение в ~5-15× при тех же vision-семантиках. Grid обновляется
## раз в 0.4с глобально — все скелеты читают один snapshot.
##
## Приоритет: гномы > палатки. Скелеты «голодные», охотятся на существа, а не
## на строения — если в радиусе хоть один живой гном (любого типа), идём к
## ближайшему гному, палатки игнорируются. Палатки берутся целью только когда
## гномов в зоне нет (например, все попрятались в палатки на свёртке лагеря).
##
## forced_target теперь — fallback, не приоритет: используется только если
## весь vision пуст. Wave-скелет, заспавненный в 50м от лагеря, идёт по
## forced_target (назначенной палатке) пока никого не видит. Когда подходит
## ближе чем 12м к лагерю — vision захватывает гномов на периметре, и
## приоритет переключает скелета на ближайшего гнома (агро-перехват
## защитниками — естественное поведение).
func _scan_target() -> Node3D:
	Skeleton._maybe_refresh_target_grid(get_tree())
	var skel_pos := global_position
	var skel_cell := Skeleton._grid_cell(skel_pos)
	var vr_sq: float = vision_radius * vision_radius
	var nearest_gnome: Node3D = null
	var nearest_gnome_dist_sq := vr_sq
	var nearest_other: Node3D = null
	var nearest_other_dist_sq := vr_sq

	# 3×3 cell'ов вокруг текущей позиции скелета. cell_size=12 = vision_radius,
	# поэтому 3×3 cell'ов гарантированно покрывает диск vision_radius. Тонкость:
	# если скелет на углу cell'а, цель в углу противоположного cell'а (3 cell'а
	# по диагонали) может быть за пределами vision_radius — отсекается dist²-чеком.
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var cell := Vector2i(skel_cell.x + dx, skel_cell.y + dz)
			if not Skeleton._target_grid.has(cell):
				continue
			var entries: Array = Skeleton._target_grid[cell]
			for entry in entries:
				var pos: Vector3 = entry[0]
				var d_sq: float = skel_pos.distance_squared_to(pos)
				if d_sq >= vr_sq:
					continue
				# ВАЖНО: читаем через Variant и проверяем is_instance_valid ДО typed-cast.
				# Если цель умерла между refresh'ами grid'а (гномы дохнут от скелов
				# в секунду), entry[1] указывает на freed-инстанс. Typed-assignment
				# `var node: Node3D = entry[1]` вылетает с "Trying to assign invalid
				# previously freed instance" — нужен untyped read.
				var raw = entry[1]
				if not is_instance_valid(raw):
					continue
				var node := raw as Node3D
				if node == null:
					continue
				if not node.is_in_group(TARGET_GROUP):
					continue
				if node is Gnome:
					if d_sq < nearest_gnome_dist_sq:
						nearest_gnome_dist_sq = d_sq
						nearest_gnome = node
				else:
					if d_sq < nearest_other_dist_sq:
						nearest_other_dist_sq = d_sq
						nearest_other = node
	if nearest_gnome != null:
		return nearest_gnome
	if nearest_other != null:
		return nearest_other
	# Vision пуст — на forced_target (палатка-якорь для wave-скелетов вне
	# vision_radius). Гномы в 12м зоне всегда отбирают приоритет.
	if is_instance_valid(_forced_target) and _forced_target.is_in_group(TARGET_GROUP):
		return _forced_target
	return null


## Назначает форсированную цель (палатку лагеря). Используется WaveDirector'ом
## на спавне волны: ставит ближайшую к точке спавна палатку как aggro-точку.
func set_forced_target(target: Node3D) -> void:
	_forced_target = target


func _perform_strike(_target: Node3D) -> void:
	# Используем _windup_target (защёлкнут в _on_state_enter(WINDUP)), а не
	# текущий _cached_target: рескан зрения мог подменить cached на ближайшего
	# гнома за время замаха, и без этой защиты strike бил бы его на любой
	# дистанции (Damageable.try_damage без contact-чека). Параметр `_target`,
	# приходящий из Enemy._ai_step:208, тоже игнорируем — он = текущий
	# get_active_target(), та же подмена.
	var active: Node3D = _windup_target
	_windup_target = null
	if active == null or not is_instance_valid(active):
		return  # Цель сдохла или freed во время замаха — strike мажет.
	if not active.is_in_group(TARGET_GROUP):
		return  # Перестала быть целью (палатка torn_off, гном вернулся в IN_TENT).
	# Distance-валидация: цель не должна была убежать дальше attack_range × slack.
	# Skeleton'у запрещено бить «в космос» — без этого внезапный спавн волны
	# гномов в 11м от windup-скелета мог получить мгновенный урон.
	var d_sq: float = (active.global_position - global_position).length_squared()
	var max_strike_range: float = attack_range * WINDUP_TARGET_RANGE_SLACK
	if d_sq > max_strike_range * max_strike_range:
		return
	# Урон — до выпада, чтобы логически «удар попал», даже если bounce-off
	# отбросит скелета на следующем кадре.
	var hit: bool = Damageable.try_damage(active, attack_damage)
	# Alarm-сигнал: только если удар реально прошёл (не по freed/не damageable),
	# и жертва — палатка или мирный гном. Defender'ы по альму не триггерят
	# (см. сигнатуру в EventBus). Фильтр по типу здесь дёшев и упрощает
	# подписчиков — им не нужно отсеивать «бьют скелета об скелета» и пр.
	if hit and (active is CampPart or (active is Gnome and not active is DefenderGnome)):
		EventBus.skeleton_attacked_camp.emit(self, active, active.global_position)
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
