class_name Skeleton
extends Enemy
## Простой враг.
## Жизненный цикл базового FSM Enemy: APPROACH → WINDUP → STRIKE → COOLDOWN → APPROACH.
## Skeleton override'ит только конкретику: телеграф замаха (squash & stretch
## позой через _mesh.scale) и сам strike (lunge + damage).
##
## Замах телеграфируется squash-позой (coiled — скелет «припадает перед
## прыжком»). Раньше был красный emission через material-swap, но игроком
## читался как «получил урон»; pose-телеграф однозначнее. См. константы
## POSE_WINDUP_SKEL / POSE_STRIKE_SKEL и _tween_pose_to ниже. Во время WINDUP
## скелет также медленно ползёт вперёд (`windup_creep_speed`) — чтобы цель,
## слегка отошедшая в сторону, не выбегала из зоны удара.
##
## Удар (`_perform_strike`) — это **физический выпад через apply_knockback самому себе**:
## скелет реально летит в сторону цели, врезается в неё (тело CharacterBody3D
## блокируется тем же CharacterBody3D башни), отскакивает (через
## Enemy._bounce_off_target). Lunge-domino через `Enemy._push_neighbor`
## не работает: skel-skel коллизии отключены через `MASK_SKELETON` без
## бита ENEMIES (см. layers.gd), get_slide_collision не регистрирует
## другого скелета как collider. Сделано для перфоманса в плотных кластерах.
## Если получает knockback во время замаха — замах отменяется (Enemy._on_knockback
## сбрасывает FSM в APPROACH; override в Skeleton также возвращает позу к нейтрали).
##
## Визуал — общеклассовый: один разделяемый StandardMaterial3D (normal),
## создаётся один раз на класс и переиспользуется всеми инстансами скелетов.
## Это позволяет GPU батчить отрисовку (50 скелетов → ~1 draw call). Цвет
## тела задан BODY_ALBEDO_COLOR, per-instance тонкая настройка не предусмотрена.
##
## Per-spawn variance: в _ready ровно один раз умножаются hp/damage/windup/
## move_speed/cooldown на randf_range — defenders не должны автопилотить волну
## по запомненному ритму. См. `_apply_stat_variance`.
##
## Aggro-on-hit: на damaged-сигнал немедленный _scan_target (минуя 0.4с-тайминг),
## переключение _cached_target на ближайшего видимого гнома. Pikeman после
## lunge'а оказывается ближайшим — следующий AI tick идёт на него в RECOVERY.
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
## Группа целей: палатки лагеря и активные гномы. Скелет находит «глазами».
## TARGET_GROUP перенесён в Enemy.gd (общий для всех Enemy-наследников). Bare
## ссылки `TARGET_GROUP` ниже резолвятся в Enemy.TARGET_GROUP через наследование.
## Группа всех живых скелетов — для перфоманс-HUD (счётчик + LOD-распределение).
## Отдельная от Damageable.GROUP, чтобы HUD не фильтровал по `is Skeleton`.
const SKELETON_GROUP := &"skeleton"

## Радиус AoE удара: `attack_range × STRIKE_RADIUS_FACTOR`. Strike — это
## размах конечностью, физически покрывает дугу вокруг скелета, а не
## точечную линию. Старая single-target логика (бить только `_windup_target`
## с slack-валидацией) мазала по движущимся целям: pikeman после lunge'а
## дрейфит из slack'а к моменту STRIKE'а. AoE покрывает кластер целей
## вокруг скелета — кто стоит рядом, тот и получает.
##
## 1.3 = ~1.95м на attack_range=1.5. Покрывает «прямо перед носом» +
## небольшой запас на дрифт цели. Если цель убежала дальше 1.95м — strike
## мажет, заслужили дистанцию. Если кластер защитников жмётся к скелету —
## один STRIKE damage'ит 2-3 одновременно (цена за clustering).
const STRIKE_RADIUS_FACTOR: float = 1.3

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
## 300×300 — 145 (150 − 5м буфер от края). Должно совпадать с Gnome.
@export var wander_map_half_extent: float = 145.0
## Дистанция до wander-точки, на которой считаем «дошёл» и начинаем отдыхать.
@export var wander_arrival: float = 0.8
@export_group("")

@export_group("Strike (физический выпад)")
@export var lunge_speed: float = 8.0  # m/s в момент удара
@export var lunge_duration: float = 0.2  # секунды knockback'а на сам выпад
## Скорость медленного движения вперёд во время WINDUP. Базовый Enemy._ai_step
## зануляет velocity в WINDUP-ветке, скелет «замирает» на расстоянии удара —
## цели достаточно слегка отойти, чтобы атака мазала. С creep'ом скелет
## продолжает «вползать» в цель во время замаха, отслеживает её перемещение
## и снижает шанс промаха. ≈55% от move_speed=2.7 — заметное движение, но
## медленнее обычного approach'а (бой читается как замах, не как преследование).
@export var windup_creep_speed: float = 1.5
@export_group("")

@export_group("Approach alarm (превентивный сигнал защитникам)")
## На какой дистанции до camp-цели (CampPart / Gnome) скелет эмитит
## [signal EventBus.skeleton_targeting_camp]. 10м (было 6м) даёт ~2-3с
## предупреждения — лучник успевает выстрелить пока скелет ещё в подходе,
## не давая ему дойти до палатки. Гиганты переопределяют через скрипт/
## сцену — им нужен ещё больший радиус (идут медленнее, заметны издалека).
## 0 → выключено (alarm срабатывает только на первом ударе).
@export var approach_alarm_distance: float = 10.0
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
## С 2026-05-15 расширено 50→80м: ловушки/мины, поставленные на расстоянии
## > 50м от башни, не срабатывали — окружающие скелеты были FAR-LOD
## (collision_layer=0, вне broad-phase, Area3D их не видит). Связано с
## cap'ом zoom_max в camera_rig — игрок не может отзумиться дальше зоны,
## где гарантированно работает физика. См. mine.gd FAR-fallback.
@export var lod_far_distance: float = 80.0
## Дополнительные биты collision_mask ПОВЕРХ штатной MASK_SKELETON —
## _apply_lod_physics_mode перезаписывает маску на LOD-переходах, поэтому
## per-instance `collision_mask |= X` не живёт. 0 = штатное поведение
## (основная игра). Данж-песочница ставит FRIENDLY_UNIT — скелет телесно
## упирается в гномов, а не проходит сквозь.
var extra_collision_mask: int = 0
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

## Размер cell'а в spatial-grid'е целей. Оптимально ~vision_radius=12м,
## округлено до 12 для совпадения по решётке. Скелет на vision-скане
## Spatial grid целей и его refresh — в Enemy.gd ([Enemy._target_grid],
## [Enemy._maybe_refresh_target_grid]). Skeleton параллельно поддерживает
## per-target load (см. ниже).

## Soft-cap «не больше TARGET_CAP скелетов на одну цель». Дизайнерский: 5
## скелетов на одного гнома мгновенно его перебивают — не интересно.
## Распределение приоритета в _scan_target: сначала ищем гнома с
## load < cap; если все capped — берём палатку (если есть); если палаток
## тоже нет — берём capped'ого гнома (4-й/5-й скелет всё равно бьёт).
## Палатки лимиту не подчиняются — здание, может ломаться многими.
const TARGET_CAP: int = 2

## Snapshot: instance_id цели → сколько скелетов её таргетят (`_cached_target`
## == эта цель). Обновляется параллельно с [Enemy._target_grid] — на тех же
## TARGET_GRID_REFRESH_INTERVAL тиках (см. [_refresh_target_load]). Между
## refresh'ами не обновляется — допускается drift на интервал. Race condition
## «5 скелетов в один кадр выбрали одного» возможен, но рассасывается за 0.4с.
static var _target_load: Dictionary = {}


## Обновляет _target_load одним проходом по SKELETON_GROUP. Зовётся когда
## [Enemy._maybe_refresh_target_grid] обновил grid — синхронно, чтобы load
## не отставал от grid'а. load Skeleton-specific (по `_cached_target`),
## поэтому остаётся в Skeleton, а не в Enemy.
static func _refresh_target_load(tree: SceneTree) -> void:
	_target_load.clear()
	for n in tree.get_nodes_in_group(SKELETON_GROUP):
		if not is_instance_valid(n):
			continue
		var skel := n as Skeleton
		if skel == null or not is_instance_valid(skel._cached_target):
			continue
		var id: int = skel._cached_target.get_instance_id()
		_target_load[id] = int(_target_load.get(id, 0)) + 1

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
## Флаг «уже эмитнул EventBus.skeleton_targeting_camp по текущей цели». One-shot
## per-target: сбрасывается в [_set_cached_target] на смене цели. Без флага
## скелет спамил бы сигнал каждый тик пока в радиусе [approach_alarm_distance],
## и handler'ы (ArcherSoldier alarm-lock / Gnome flee) перезаряжались бы в
## непрерывный пинг — пропадал смысл «один раз предупредил, можно расслабиться».
var _targeting_alarm_signaled: bool = false
## Персональный угол approach-кольца вокруг цели. Каждый скелет идёт не в
## саму точку цели, а в `target_pos + cos/sin × ring_radius`. Разные углы
## → скелеты окружают цель, не выстраиваются «в линию» по биссектрисе
## между спавн-точкой и гномом. Обновляется на смене `_cached_target` через
## [_set_cached_target] — для новой цели свой расклад.
var _approach_angle: float = 0.0
## Доля от `attack_range`, на которой скелет «стоит» в кольце атаки. 0.85 =
## внутри attack_range → достижение angle-goal'а гарантированно даёт
## WINDUP-чек по дистанции до самой цели. Меньше — плотнее впритык; больше —
## вылет за attack_range и зависание в approach.
const APPROACH_RING_FACTOR: float = 0.85
## Последняя известная позиция цели, исчезнувшей из TARGET_GROUP (без смерти).
## Скелет идёт к ней, пока не дойдёт ARRIVAL_LAST_KNOWN или не найдёт новую
## vision-цель. INF = нет точки (обычный wander). Записывается в stale-чеке,
## сбрасывается на arrival или на смерть цели (queue_free).
var _last_known_target_pos: Vector3 = Vector3.INF
## Дистанция «прибыл к последней известной точке». 1.5м — комфортно: скелет
## визуально дошёл, не дёргается на месте.
const ARRIVAL_LAST_KNOWN: float = 1.5
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
	_apply_stat_variance()
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
	# Стартовый угол на approach-кольце — рандом. На первой смене цели
	# (_set_cached_target из _scan_target) обновится; до этого скелет в wander.
	_approach_angle = randf() * TAU
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
	# Hit-feedback: на каждый damaged-сигнал — короткий scale-punch меша
	# («подпрыгивает» на удар). Сам сигнал унаследован из Enemy.
	damaged.connect(_on_self_damaged)
	# Aggro-on-hit: получили урон → немедленный rescan зрения, минуя
	# `vision_scan_interval`-тайминг. Без этого pikeman делал бы весь lunge
	# цикл и улетал в RECOVERY, прежде чем скелет рескан'ит зрение и заметит
	# атакующего. Скан стоит дёшево (3×3 cell'а из target_grid), и для рескан'а
	# на каждый удар это никакая нагрузка (≪ 60Гц).
	damaged.connect(_on_damage_react_aggro)
	# NavMesh re-bake → пересчёт path-decision для текущей цели.
	# Без этого _should_path_around остаётся stale: стена появилась, но
	# скелет всё ещё думает что обходит/ломает по старому состоянию карты.
	EventBus.navmesh_baked.connect(_on_navmesh_baked)
	tree_exiting.connect(_disconnect_skeleton_eventbus)


func _on_navmesh_baked() -> void:
	# Пересчёт hybrid-decision на следующем тике (через _set_cached_target),
	# а пока — синхронно по текущей цели если она есть.
	if is_instance_valid(_cached_target):
		_recompute_path_decision()


func _disconnect_skeleton_eventbus() -> void:
	if EventBus.navmesh_baked.is_connected(_on_navmesh_baked):
		EventBus.navmesh_baked.disconnect(_on_navmesh_baked)


## Scale-punch на _mesh — визуальная индикация попадания. Tween создаётся
## Per-spawn variance: ±X% к hp/damage/windup/speed/cooldown. Применяется
## к загруженным значениям (.tscn override или @export default) ровно один
## раз на _ready. Дизайнерская цель — defenders не должны автопилот'ить волну
## по запомненному ритму «windup ровно 0.4с, hp ровно 30». На пачке 200+
## скелетов разброс параметров создаёт волатильность: какие-то умирают с
## первого удара, какие-то наносят больший урон, кто-то windup'ит на 0.32с
## (быстрее чем ожидалось), кто-то на 0.48с.
##
## Move_speed разброс меньше (15%) — большее значение «ломало» бы пакетное
## движение цепочкой (одни далеко обгоняют, других накрывает шлейф). 15%
## даёт лёгкое расслоение, форма волны остаётся читаемой.
const VARIANCE_HP: float = 0.20
const VARIANCE_DAMAGE: float = 0.20
const VARIANCE_WINDUP: float = 0.20
const VARIANCE_SPEED: float = 0.15
const VARIANCE_COOLDOWN: float = 0.15


func _apply_stat_variance() -> void:
	hp *= randf_range(1.0 - VARIANCE_HP, 1.0 + VARIANCE_HP)
	attack_damage *= randf_range(1.0 - VARIANCE_DAMAGE, 1.0 + VARIANCE_DAMAGE)
	attack_windup *= randf_range(1.0 - VARIANCE_WINDUP, 1.0 + VARIANCE_WINDUP)
	attack_windup_point_blank *= randf_range(1.0 - VARIANCE_WINDUP, 1.0 + VARIANCE_WINDUP)
	move_speed *= randf_range(1.0 - VARIANCE_SPEED, 1.0 + VARIANCE_SPEED)
	attack_cooldown *= randf_range(1.0 - VARIANCE_COOLDOWN, 1.0 + VARIANCE_COOLDOWN)


## Aggro-on-hit: на любой полученный урон рескан'им зрение немедленно и
## переключаем `_cached_target` на ближайшего видимого гнома. Без этого
## хука vision-сkан тикал бы по `vision_scan_interval=0.4с`, и pikeman
## мог сделать lunge → удар → drift → recovery полностью внутри одного
## scan-интервала, не получив ни секунды внимания скелета.
##
## После рескана: следующий AI-tick перепланирует direction на нового
## target'а (через `_approach_target`). Если скелет был в WINDUP — тот
## продолжается до strike по `_windup_target` (защёлкнут отдельно), затем
## COOLDOWN → APPROACH уже к новой цели. Если был knocknock'нут самим
## ударом — _on_knockback в базе сбросит WINDUP в APPROACH, и переход
## на нового target'а произойдёт сразу.
##
## Vision_scan_timer сбрасываем, чтобы плановый scan не наложился сразу же
## (например через 50мс) и не подменил нового target'а на «других гномов
## просто оказавшихся ближе» — даём скелету пол-интервала жить с aggro'м.
func _on_damage_react_aggro(_amount: float) -> void:
	if hp <= 0.0:
		return
	var new_target := _scan_target()
	if new_target != null:
		_set_cached_target(new_target)
		_vision_scan_timer = vision_scan_interval * _lod_vision_multiplier()


## Централизованная смена `_cached_target`. На новой цели — новый
## `_approach_angle`, чтобы скелет занял другую точку в кольце вокруг неё.
## Если новая цель == старая (рескан вернул то же) — angle не трогаем,
## не дёргать строй.
##
## Также: пересчитываем hybrid-pathfinding decision (`_should_path_around`).
## Скелет обходит стены если путь вокруг них ≤ DETOUR_THRESHOLD × прямой
## дистанции; иначе идёт прямо и ломает (стена = отвлечение по дизайну).
## Превентивный сигнал защитникам: эмитит [signal EventBus.skeleton_targeting_camp]
## когда скелет подошёл к camp-цели на [approach_alarm_distance], но ещё не
## ударил. Один раз per-цель — флаг [_targeting_alarm_signaled] взводится
## и сбрасывается только в [_set_cached_target].
##
## Цель должна быть CampPart (палатка) или Gnome (включая subclass'ов:
## SoldierGnome / ArcherSoldier). Tower не считается — для неё своя цепочка
## (Tower-tank Giant подаёт другие сигналы), и она не «мирная цель».
##
## State-фильтр: эмитим только в APPROACH. В WINDUP/STRIKE/COOLDOWN сигнал
## уже бесполезен — удар идёт или прошёл. После STRIKE'а handler'ы и так
## ловят EventBus.skeleton_attacked_camp.
func _tick_targeting_alarm() -> void:
	if _targeting_alarm_signaled or approach_alarm_distance <= 0.0:
		return
	if _state != AttackState.APPROACH:
		return
	if not is_instance_valid(_cached_target):
		return
	var is_camp_target: bool = (
		_cached_target is CampPart
		or _cached_target.is_in_group(Gnome.GNOME_GROUP)
	)
	if not is_camp_target:
		return
	var dx: float = _cached_target.global_position.x - global_position.x
	var dz: float = _cached_target.global_position.z - global_position.z
	if dx * dx + dz * dz > approach_alarm_distance * approach_alarm_distance:
		return
	_targeting_alarm_signaled = true
	EventBus.skeleton_targeting_camp.emit(self, _cached_target, _cached_target.global_position)


func _set_cached_target(new_target: Node3D) -> void:
	if new_target == _cached_target:
		return
	_cached_target = new_target
	_approach_angle = randf() * TAU
	_recompute_path_decision()
	# Сбрасываем флаг targeting-alarm: новая цель → можно эмитить сигнал
	# приближения снова один раз (см. [_tick_targeting_alarm]).
	_targeting_alarm_signaled = false
	# Цель найдена → выходим из local-wander (если были в нём). Следующий
	# _ai_step увидит cached_target и пойдёт в APPROACH, _wander_tick не
	# вызовется. Сбрасываем явно — иначе если позже цель снова потеряется,
	# скелет останется в local-режиме «вокруг старой стены».
	if new_target != null and _local_wander_mode:
		_local_wander_mode = false
		_blocked_target_dir = Vector3.ZERO
		_local_wander_side = 0


## Множитель «обходить если путь ≤ X × прямой дистанции». 2.0 = готов
## пройти вдвое дальше ради обхода. Длинная закрытая стена (path → ∞)
## не проходит порог → скелет ломает. Короткий заборчик у ресурса —
## проходит → скелет обходит.
const DETOUR_THRESHOLD: float = 2.0
## True если скелет на текущей цели решил обходить стены через path,
## false — идёт прямо. Пересчитывается на смене цели через [_recompute_path_decision].
var _should_path_around: bool = false
@onready var _nav_agent: NavigationAgent3D = get_node_or_null("NavigationAgent3D") as NavigationAgent3D

## Stuck-detector для приоритизации препятствия. Если скелет идёт к гному и
## упирается в стену (физически не движется ≥STUCK_DURATION секунд) — он
## переключает цель на ближайшую `skeleton_target` ноду в радиусе
## STUCK_OBSTACLE_RADIUS (обычно это и есть стена, в которую упёрся).
## Атакует её, ломает, проходит. На следующем _scan_target throttle'е
## снова видит гнома, идёт к нему. «Пробирается внутрь» по сценарию.
const STUCK_DISPLACEMENT_THRESHOLD: float = 0.03
const STUCK_DURATION: float = 0.6
const STUCK_OBSTACLE_RADIUS: float = 2.0
var _stuck_last_pos: Vector3 = Vector3.INF
var _stuck_timer: float = 0.0

## Якорь роуминга банды (SkeletonWarband): задан → когда нет боевой vision-цели,
## скелет идёт к нему вместо случайного wander'а (когезивный роум группы). Vision-
## scan перебивает → аггро по зрению (опортунистичная атака при подходе к лагерю).
## INF = не в банде (обычный wander). Координатор зовёт set_roam_anchor.
var _roam_anchor: Vector3 = Vector3.INF
## Внутри этого радиуса от ЛИЧНОЙ точки в блобе скелет стоит (банда держит строй
## не сбиваясь в одного). Маленький — иначе члены наезжают на точки соседей.
const ROAM_ARRIVAL_RADIUS: float = 1.0

## Local-wander режим: упёрся в стену (stuck-handler не нашёл реальной цели
## вокруг), теперь бродим небольшими шагами вокруг точки столкновения, пока
## не получим валидную цель из vision-scan. Сбрасывается в [_set_cached_target]
## когда цель найдена → следующий _ai_step падает в APPROACH, не в _wander_tick.
var _local_wander_mode: bool = false
const LOCAL_WANDER_DISTANCE_MIN: float = 4.0
const LOCAL_WANDER_DISTANCE_MAX: float = 9.0
## Направление к заблокированной цели (XZ-нормализованное), запомненное при
## _enter_local_wander. Используется для bias'а wander-точек: выбираем
## перпендикулярно — скелет движется ВДОЛЬ стены, ищет обход, а не топчется
## в той же точке. ZERO = ещё не выбрано / сбросилось.
var _blocked_target_dir: Vector3 = Vector3.ZERO
## Сторона обхода стены, выбирается случайно при первом _enter_local_wander
## (±1). Разные скелеты пойдут в разные стороны → толпа расходится вдоль
## забора. Сбрасывается вместе с _local_wander_mode.
var _local_wander_side: int = 0
## Максимум попыток подобрать wander-точку с валидным LOS (raycast не
## упирается в палисад). Если все попытки за стеной — fallback на любую
## точку (скелет может застрять, но следующий stuck-цикл попробует снова).
const LOCAL_WANDER_LOS_RETRIES: int = 6


## Решение «обходить или ломать»: считаем длину NavMesh-пути и сравниваем
## с прямой дистанцией. Если NavMesh ещё не bake'нут (пустой path) или
## цель invalid — fallback на прямое движение.
func _recompute_path_decision() -> void:
	if _nav_agent == null or not is_instance_valid(_cached_target):
		_should_path_around = false
		return
	var map_rid: RID = _nav_agent.get_navigation_map()
	if map_rid == RID():
		_should_path_around = false
		return
	var from_pos: Vector3 = global_position
	var to_pos: Vector3 = _cached_target.global_position
	var direct: float = Vector2(to_pos.x - from_pos.x, to_pos.z - from_pos.z).length()
	if direct < 0.01:
		_should_path_around = false
		return
	var path: PackedVector3Array = NavigationServer3D.map_get_path(map_rid, from_pos, to_pos, true)
	if path.size() < 2:
		# NavMesh не нашёл путь (цель в obstacle / map не bake'нут) — идём прямо.
		_should_path_around = false
		return
	var path_length: float = 0.0
	for i in range(path.size() - 1):
		path_length += (path[i + 1] - path[i]).length()
	_should_path_around = path_length <= direct * DETOUR_THRESHOLD


## Валидность ТЕКУЩЕЙ цели. Стены/здания (MELEE_ONLY) валидны — скелет, упёршийся
## в постройку по пути к гному, ломает её (осада). Само переключение НА стену —
## только когда застрял (см. [_tick_stuck_detection] → [_find_nearest_obstacle]);
## обычный vision-скан стены НЕ выбирает (фильтр в [_scan_target]), поэтому скелет
## нормально гонится за гномами, а постройку бьёт лишь когда она реально блокирует.
## (2026-06-09: вернули «ломают» из задуманного melee-гибрида; до этого пехота
## уходила в local-wander и только тыкалась.)
func _target_still_valid(target: Node3D) -> bool:
	return super._target_still_valid(target)


## на меше; если скелет умрёт сразу после, mesh queue_free'нется вместе с
## ним и tween тихо отвалится. Не трогаем shared material (он один на класс)
## — иначе вспышка цвета затронула бы все 200+ скелетов.
##
## Пропускаем feedback во время WINDUP — там pose-tween держит coiled-позу
## телеграфа удара. Без этой защиты scale-punch (тянет к Vector3.ONE × 1.25 →
## ONE) перетёр бы coiled-позу и оставил бы скелета в нейтрале до конца
## замаха — телеграф терялся бы при попадании.
func _on_self_damaged(_amount: float) -> void:
	if _state == AttackState.WINDUP:
		return
	HitPunch.punch(_mesh)


## Squash & stretch как у копейщика — pose-телеграф для WINDUP/STRIKE.
## Красный emission glow читался как «получил урон»; coiled-поза («припал
## перед прыжком») — однозначный сигнал «замахивается, ща ударит».
##
## POSE_WINDUP_SKEL — скелет приседает и расширяется поперёк (Y=0.75, X=1.2),
## слегка прижимается по Z (0.85). Вид сверху: широкий приплюснутый овал.
## POSE_STRIKE_SKEL — вытягивается вперёд (Z=1.45) и вверх (Y=1.1), сужается
## по X (0.7). Стрелка вдоль удара. Z-контраст windup→strike: 0.85 → 1.45 ≈
## 1.7× — заметный визуальный «выстрел копьём».
##
## Y-разница больше чем у копейщика (0.75 → 1.1) — скелет высокий и тонкий
## (capsule h=2.0, у копейщика 0.8), вертикальная компонента видна лучше.
const POSE_NEUTRAL: Vector3 = Vector3.ONE
const POSE_WINDUP_SKEL: Vector3 = Vector3(1.2, 0.75, 0.85)
const POSE_STRIKE_SKEL: Vector3 = Vector3(0.7, 1.1, 1.45)

## Тайминги переходов между позами. WINDUP-ramp медленнее чем у копейщика
## (0.12 vs 0.06) — у скелета вся фаза 0.32-0.48с после variance, есть
## запас. STRIKE-snap такой же быстрый (0.04с — «выстрел»). Restore идёт в
## COOLDOWN параллельно self-lunge'у; к середине cooldown'а (1.0с) скелет в
## нейтрале.
const POSE_WINDUP_TIME: float = 0.12
const POSE_STRIKE_TIME: float = 0.04
const POSE_RESTORE_TIME: float = 0.25

## Активный pose-tween — kill'ается при следующем переходе чтобы не
## перекрываться (windup→strike не должен ждать завершения windup-ramp'а).
var _pose_tween: Tween = null


## Tween-переход меша к указанной позе за `duration`. Старый pose-tween
## убивается чтобы новый стартовал с текущего interpolated-значения, а не
## ждал завершения предыдущего.
func _tween_pose_to(target: Vector3, duration: float) -> void:
	if _mesh == null or not is_instance_valid(_mesh):
		return
	if _pose_tween != null and _pose_tween.is_valid():
		_pose_tween.kill()
	_pose_tween = create_tween()
	_pose_tween.tween_property(_mesh, "scale", target, duration).set_ease(Tween.EASE_OUT)


## Снап в strike-позу + chain restore в нейтраль. Один tween-цепочкой, чтобы
## restore стартовал сразу после snap'а независимо от того, что происходит с
## state machine (cooldown тикает в base, STRIKE-state транзитное).
func _tween_pose_strike() -> void:
	if _mesh == null or not is_instance_valid(_mesh):
		return
	if _pose_tween != null and _pose_tween.is_valid():
		_pose_tween.kill()
	_pose_tween = create_tween()
	_pose_tween.tween_property(_mesh, "scale", POSE_STRIKE_SKEL, POSE_STRIKE_TIME).set_ease(Tween.EASE_OUT)
	_pose_tween.chain()
	_pose_tween.tween_property(_mesh, "scale", POSE_NEUTRAL, POSE_RESTORE_TIME).set_ease(Tween.EASE_IN)


static func _ensure_shared_materials() -> void:
	if _shared_normal_material == null:
		var normal := StandardMaterial3D.new()
		normal.albedo_color = BODY_ALBEDO_COLOR
		_shared_normal_material = normal


func _on_state_enter(new_state: int) -> void:
	if new_state == AttackState.WINDUP:
		# Squash & stretch вместо color-glow: красный emission читался как
		# «получил урон». Coiled-поза (как у копейщика) — однозначный сигнал
		# «замахивается». Поза держится attack_windup секунд (0.32-0.48с после
		# variance), до перехода в STRIKE.
		_tween_pose_to(POSE_WINDUP_SKEL, POSE_WINDUP_TIME)
		# Защёлкиваем цель замаха — strike будет бить её, не текущий cached_target.
		# get_active_target() возвращает _cached_target (override skeleton'a), а
		# тот свежий: WINDUP запускается из _approach_target в том же тике, когда
		# дистанция упала ≤ attack_range, т.е. рескан был только что.
		_windup_target = get_active_target()
	elif new_state == AttackState.STRIKE:
		# Снап в extended-позу (тело вытянуто копьём вперёд) + chain restore.
		# STRIKE-state транзитное (один тик), но self-lunge через
		# `_apply_velocity_change` несёт скелета по инерции ~0.2с (lunge_duration),
		# и extended-pose как раз эту фазу визуализирует. Restore идёт в
		# COOLDOWN — к середине кулдауна (1.0с) скелет уже в нейтральной позе.
		_tween_pose_strike()


func _on_state_exit(_old_state: int) -> void:
	# Поза управляется через enter-хуки (WINDUP → coiled, STRIKE → extended
	# с chain'ом restore). Knockback-сброс WINDUP→APPROACH ловится отдельно
	# в `_on_knockback` override'е, иначе coiled-поза бы зависла.
	pass


## Override базы Enemy._on_knockback: помимо state-сброса (WINDUP→APPROACH)
## возвращаем нейтральную позу. Без этого скелет, сбитый из coiled-позы,
## ходил бы криво до следующей атаки.
func _on_knockback() -> void:
	var was_windup: bool = _state == AttackState.WINDUP
	super._on_knockback()
	if was_windup:
		_tween_pose_to(POSE_NEUTRAL, POSE_RESTORE_TIME)


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
		_tick_targeting_alarm()
		super._ai_step(delta)
	elif _last_known_target_pos != Vector3.INF:
		_persist_toward_last_known(delta)
	else:
		_wander_tick(delta)
	# WINDUP-creep: после super (который зануляет velocity в WINDUP-ветке)
	# даём слабое движение к цели. Без него скелет «замирает» на attack_range,
	# и движущаяся цель легко уходит из зоны удара. См. `_apply_windup_creep`.
	_apply_windup_creep()
	# Boids-style avoidance: только NEAR. MID и FAR пропускаем — на расстоянии
	# 25м+ от камеры мелкие накладки тимы не читаются, а boids стоит
	# ~18мкс/call. На 2000 скелетах при divisor=4 в среднем 50-100 NEAR в
	# кадре — экономия ~1ms vs прежнее «NEAR+MID». Если плотные кучи на MID
	# станут визуально мешать, можно вернуть `_lod_level != LodLevel.FAR`.
	# История: NEAR+MID → NEAR-only (этап 43, профайлер: 1.95ms / 105 calls).
	# 2026-05-17: убрал `_state == APPROACH` гейт — скелеты в WINDUP/STRIKE/
	# COOLDOWN тоже расталкиваются. Иначе при атаке цели стоят в пирамидальной
	# куче «5 замахов по одному гному вплотную», после avoidance — расходятся
	# в полукольцо. Слабая просадка перфа (×~2 на calls) терпима на NEAR'е.
	if _lod_level == LodLevel.NEAR:
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


## MID-LOD компенсация FSM-таймеров: super._physics_process (где тикают
## WINDUP/COOLDOWN таймеры) вызывается раз в lod_mid_tick_divisor кадров с сырым
## delta — без масштаба замах/кулдаун шли бы в divisor× раз дольше по wall-clock,
## чем у NEAR-скелетов. Множим, как движение компенсируется velocity*divisor.
## NEAR → 1.0; FAR этим путём не идёт (_far_step тикает таймеры на work_delta сам).
func _fsm_time_scale() -> float:
	if _lod_level == LodLevel.MID and lod_mid_tick_divisor > 1:
		return float(lod_mid_tick_divisor)
	return 1.0


## Медленное движение к цели во время WINDUP. Перетирает velocity=0 от
## базового Enemy._ai_step (его WINDUP-ветка зануляет XZ). Скелет «вползает»
## в цель за 0.32-0.48с замаха ≈ 0.5-0.7м, отслеживая её перемещение —
## цель уже не может «постоять рядом и отойти» в момент удара.
##
## Direction берётся к `_windup_target` (не к текущему `_cached_target`) —
## strike будет бить именно его, направление creep'а должно совпадать.
## Override базового `_approach_target`: вместо движения в саму точку цели
## идём в `target_pos + offset(_approach_angle, ring_radius)` — каждый
## скелет занимает свой сектор кольца. Без этого 5 скелетов на одной цели
## стояли бы по прямой линии (биссектриса спавн-точка ↔ цель), все
## вплотную; теперь — нерегулярный полукруг/круг вокруг гнома.
##
## WINDUP-чек по дистанции до **самой цели** (не до offset point'а): когда
## скелет доходит до своего сектора (внутри attack_range), сразу замах.
## Если скелет ещё не дошёл, но цель сама шагнула близко (мирный гном
## мчит обратно к палатке через скелета) — WINDUP всё равно срабатывает
## по дистанции к target, не по dist до offset.
##
## Point-blank shortcut перенесён 1:1 из базового — короткий windup когда
## цель глубоко в attack_range.
func _approach_target(target: Node3D) -> void:
	var target_pos: Vector3 = target.global_position
	var to_target := Vector3(
		target_pos.x - global_position.x,
		0.0,
		target_pos.z - global_position.z,
	)
	var dist_sq: float = to_target.x * to_target.x + to_target.z * to_target.z
	# Крупная цель (ядро) — порог и кольцо атаки расширяем на её reach-бонус,
	# иначе скелет упирается в широкую коллизию вне attack_range и не замахивается.
	var reach: float = attack_range + target_reach_bonus(target)
	var attack_range_sq: float = reach * reach
	if dist_sq > attack_range_sq:
		# Идём в свой сектор кольца, а не в саму цель. ring_radius чуть
		# меньше reach → когда добежали — точно в зоне удара (для ядра кольцо
		# ложится сразу за его коллизией).
		var ring_radius: float = reach * APPROACH_RING_FACTOR
		var goal_x: float = target_pos.x + cos(_approach_angle) * ring_radius
		var goal_z: float = target_pos.z + sin(_approach_angle) * ring_radius
		var goal: Vector3 = Vector3(goal_x, target_pos.y, goal_z)
		# Hybrid pathfinding: если на смене цели было решено обходить
		# (_should_path_around), идём по next waypoint NavAgent'а. Иначе
		# напрямую в ring-точку — упрёмся в стену и будем её ломать
		# (стена в skeleton_target → STRIKE damage'нет её на следующем тике).
		var step_target: Vector3 = goal
		if _should_path_around and _nav_agent != null:
			_nav_agent.target_position = goal
			if not _nav_agent.is_navigation_finished():
				step_target = _nav_agent.get_next_path_position()
		var to_goal := Vector3(
			step_target.x - global_position.x,
			0.0,
			step_target.z - global_position.z,
		)
		var to_goal_len: float = to_goal.length()
		if to_goal_len > 0.001:
			velocity.x = (to_goal.x / to_goal_len) * move_speed
			velocity.z = (to_goal.z / to_goal_len) * move_speed
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		_enter_state(AttackState.WINDUP)
		# Point-blank: цель глубоко в зоне атаки — сокращённый windup.
		var dist: float = sqrt(dist_sq)
		if dist <= reach * point_blank_distance_factor:
			_state_timer = attack_windup_point_blank


## Re-aim каждый тик: цель сдвинулась → поза разворачивается на новое
## направление (squash & stretch локальные оси автоматически следуют).
##
## MID-divisor multiplier ниже умножит и creep-velocity → net distance на
## skip'аемых кадрах сохраняется (так же, как для super-ai velocity).
func _apply_windup_creep() -> void:
	if _state != AttackState.WINDUP:
		return
	if not is_instance_valid(_windup_target):
		return
	var target_pos: Vector3 = _windup_target.global_position
	var to_target := Vector3(
		target_pos.x - global_position.x,
		0.0,
		target_pos.z - global_position.z,
	)
	var dist: float = to_target.length()
	if dist <= 0.1:
		return  # уже в эпицентре, не creep
	var dir := to_target / dist
	velocity.x = dir.x * windup_creep_speed
	velocity.z = dir.z * windup_creep_speed
	look_at(global_position + dir, Vector3.UP)


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
		var clamp_scale: float = max_avoid / mag
		push_x *= clamp_scale
		push_z *= clamp_scale
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
			collision_mask = Layers.MASK_SKELETON | extra_collision_mask
			if _collision_shape:
				_collision_shape.disabled = false
		LodLevel.FAR:
			collision_layer = 0
			collision_mask = 0
			if _collision_shape:
				_collision_shape.disabled = true


## Anti-exploit: цель пропала из TARGET_GROUP без смерти (постройку подняли,
## гном вошёл в палатку...). Скелет продолжает идти к её последней позиции,
## не «забывает» мгновенно. По прибытии — сбрасывает и переходит в wander.
## Новая vision-цель (через scan) перебивает этот режим.
func _persist_toward_last_known(_delta: float) -> void:
	var to_pos := Vector3(
		_last_known_target_pos.x - global_position.x,
		0.0,
		_last_known_target_pos.z - global_position.z,
	)
	var dist: float = to_pos.length()
	if dist <= ARRIVAL_LAST_KNOWN:
		_last_known_target_pos = Vector3.INF
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var dir := to_pos / dist
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed


## Координатор банды ставит/двигает якорь роуминга. INF = снять (обычный wander).
func set_roam_anchor(pos: Vector3) -> void:
	_roam_anchor = pos


## Роум-шаг банды: марш к якорю группы (move_speed), у якоря — стоп (толпимся).
## Заменяет случайный wander для членов SkeletonWarband. Боевая аггро-цель из
## vision-scan перебивает (при _cached_target скелет вообще не в _wander_tick).
func _roam_tick(_delta: float) -> void:
	var to_anchor := Vector3(_roam_anchor.x - global_position.x, 0.0, _roam_anchor.z - global_position.z)
	var d: float = to_anchor.length()
	if d <= ROAM_ARRIVAL_RADIUS:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var dir := to_anchor / d
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed


func _wander_tick(delta: float) -> void:
	# Член бродячей банды (SkeletonWarband): идём к общему якорю, не случайно.
	if _roam_anchor != Vector3.INF:
		_roam_tick(delta)
		return
	match _wander_phase:
		WanderPhase.RESTING:
			velocity.x = 0.0
			velocity.z = 0.0
			_rest_timer = maxf(_rest_timer - delta, 0.0)
			if _rest_timer <= 0.0:
				_wander_target = _pick_local_wander_target() if _local_wander_mode else _pick_wander_target()
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


## Сколько направлений пробуем в _pick_wander_target, ища точку с чистым прямым путём.
const WANDER_REACH_RETRIES := 8
## На сколько метров путь может «не дойти» до точки и она ещё считается достижимой.
const WANDER_REACH_TOLERANCE := 1.0
## Во сколько раз навмеш-путь может быть длиннее прямой дистанции и ещё считаться
## «прямым выстрелом». Больше = путь огибает стену → wander (прямая линия) упёрся бы.
const WANDER_STRAIGHT_FACTOR := 1.2


## Случайная wander-точка в радиусе — достижимая И с ЧИСТЫМ ПРЯМЫМ путём по навмешу.
## Wander движется прямой линией к точке (не по навмеш-пути). Поэтому мало, чтобы
## точка была достижима: если путь к ней огибает стену (через дверь/угол), скелет
## пошёл бы прямо и упёрся в стену. Берём точку только если навмеш-путь до неё ≈
## прямой дистанции (path_len ≤ direct × STRAIGHT_FACTOR) — значит между скелетом и
## точкой стен нет. Несколько попыток в разные стороны; если все упираются — стоим
## (отдохнём, попробуем снова). «Нет чистого направления → не лезет в стену».
## Минимальная дистанция фолбэк-прохода. В тесной комнате (14×14) кандидаты на
## штатных 5-15м почти все за стеной — без короткого прохода скелет «стоял бы»
## у стены и копил толпу. Короткие хопы 2-5м держат его в движении внутри комнаты.
const WANDER_SHORT_MIN := 2.0


func _pick_wander_target() -> Vector3:
	var map_rid: RID = _nav_agent.get_navigation_map() if _nav_agent != null else RID()
	if map_rid == RID():
		# навмеш недоступен — старое поведение (прямой wander на штатной дистанции)
		var a := randf() * TAU
		var d := randf_range(wander_distance_min, wander_distance_max)
		return global_position + Vector3(cos(a) * d, 0.0, sin(a) * d)
	# Штатный диапазон; если все кандидаты упёрлись в стены (тесная комната) —
	# повторяем коротко (2..min), чтобы найти ближнюю точку и не застрять у стены.
	var p: Vector3 = _try_wander_range(map_rid, wander_distance_min, wander_distance_max)
	if p != Vector3.INF:
		return p
	p = _try_wander_range(map_rid, WANDER_SHORT_MIN, wander_distance_min)
	if p != Vector3.INF:
		return p
	return global_position  # совсем нет чистого направления — стоим, попробуем снова


## Несколько попыток подобрать wander-точку в радиусе [dmin..dmax] с достижимым И
## прямым (без огибания стен) навмеш-путём. INF = не нашли в этом диапазоне.
func _try_wander_range(map_rid: RID, dmin: float, dmax: float) -> Vector3:
	for attempt in range(WANDER_REACH_RETRIES):
		var angle := randf() * TAU
		var dist := randf_range(dmin, dmax)
		var cand := global_position + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
		cand.x = clampf(cand.x, -wander_map_half_extent, wander_map_half_extent)
		cand.z = clampf(cand.z, -wander_map_half_extent, wander_map_half_extent)
		cand.y = global_position.y
		var path: PackedVector3Array = NavigationServer3D.map_get_path(map_rid, global_position, cand, true)
		if path.size() < 2:
			continue
		var endp: Vector3 = path[path.size() - 1]
		if Vector2(endp.x - cand.x, endp.z - cand.z).length() > WANDER_REACH_TOLERANCE:
			continue  # путь не дошёл до точки (за стеной) → другой отсек
		var path_len: float = 0.0
		for i in range(path.size() - 1):
			path_len += Vector2(path[i + 1].x - path[i].x, path[i + 1].z - path[i].z).length()
		var direct: float = Vector2(cand.x - global_position.x, cand.z - global_position.z).length()
		if path_len <= direct * WANDER_STRAIGHT_FACTOR:
			return cand  # прямой путь свободен — wander дойдёт по прямой без стен
	return Vector3.INF


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
		if is_instance_valid(_cached_target):
			if not _target_still_valid(_cached_target):
				# Цель «исчезла» из под удара (постройка поднята в руку, гном
				# вошёл в палатку и т.п.), но физически жива — запоминаем её
				# **последнюю позицию** и продолжаем бежать туда. Без этого
				# игрок мог бы «эксплойтить» подъёмом колокола: скелеты
				# мгновенно теряли цель и шли в wander.
				stale = true
				_last_known_target_pos = _cached_target.global_position
				_cached_target = null
		else:
			# Цель queue_free'нулась (умерла). Сбрасываем «последнюю позицию» —
			# нет смысла идти к месту мёртвой цели, обычный wander уместнее.
			stale = true
			_last_known_target_pos = Vector3.INF
			_cached_target = null
	if _vision_scan_timer <= 0.0 or stale:
		var scanned := _scan_target()
		# Не сдёргивать с ломки постройки: если скан ничего ВИДИМОГО не дал
		# (реальная цель за стеной — нет LOS), но текущая цель — живая постройка
		# (BuildBlock: стена/здание/ворота), которую ломаем по пути → держим её,
		# пока не пробьём. Иначе throttled-скан каждые ~0.4с ронял бы цель в null
		# и скелет уходил в wander вместо осады. Видимую реальную цель — берём.
		if scanned != null or not (is_instance_valid(_cached_target) and _cached_target is BuildBlock):
			_set_cached_target(scanned)
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

	# Stuck-detection: если скелет в APPROACH с активной целью, но физически
	# не движется ≥STUCK_DURATION — упёрся в стену по пути к гному (стена
	# не его текущий target). Переключаемся на ближайшее препятствие в
	# skeleton_target-радиусе — атакуем стену, пробьём, пойдём дальше.
	_tick_stuck_detection(work_delta)


## Stuck-проверка: накапливаем время «стоит на месте» в APPROACH, на
## превышении порога находим ближайший skeleton_target в радиусе и
## переключаемся на него. Сбрасываемся как только реально двигаемся /
## не в APPROACH / в knockback'е.
func _tick_stuck_detection(work_delta: float) -> void:
	# Только в APPROACH с реальной целью. WINDUP/STRIKE/COOLDOWN не считают —
	# скелет намеренно стоит. Knockback не считаем — не наша воля.
	if _state != AttackState.APPROACH or _cached_target == null or _knockback.is_active():
		_stuck_timer = 0.0
		_stuck_last_pos = global_position
		return
	if _stuck_last_pos == Vector3.INF:
		_stuck_last_pos = global_position
		return
	var displacement: float = Vector2(
		global_position.x - _stuck_last_pos.x,
		global_position.z - _stuck_last_pos.z,
	).length()
	_stuck_last_pos = global_position
	if displacement >= STUCK_DISPLACEMENT_THRESHOLD:
		_stuck_timer = 0.0
		return
	_stuck_timer += work_delta
	if _stuck_timer < STUCK_DURATION:
		return
	# Превышение — ищем ближайшее препятствие (Enemy._target_grid, 3×3 cell'а).
	# Стены/здания ТЕПЕРЬ включены (2026-06-09) — упёрся в постройку → берём её
	# целью и ломаем (осада). _target_still_valid её принимает, LOS-стена не даёт
	# скану сдёрнуть на гнома за ней до пробоя.
	var obstacle: Node3D = _find_nearest_obstacle(STUCK_OBSTACLE_RADIUS)
	if obstacle != null and obstacle != _cached_target:
		_set_cached_target(obstacle)
		if LogConfig.master_enabled:
			print("[Skeleton] упёрся → ломаю %s" % obstacle.name)
	elif obstacle == null:
		# Рядом вообще ничего (упёрся в terrain/край без построек) — local wander,
		# пока vision не подберёт цель или slide не вынесет на обход.
		_enter_local_wander()
	_stuck_timer = 0.0


## Переход в локальный wander около точки столкновения со стеной. Сбрасывает
## текущую цель и last-known-pos — _ai_step упадёт в [_wander_tick]. Флаг
## [_local_wander_mode] переключает _pick_*_wander_target на близкие точки
## (2-4.5м), чтобы скелет не уходил далеко от стены. Выход — в
## [_set_cached_target] когда _scan_target подберёт реальную цель.
##
## Запоминает направление к заблокированной цели (XZ) и выбирает сторону
## обхода (±1, рандом) — wander-точки будут смещаться вдоль стены, а не
## топтаться в случайной точке.
func _enter_local_wander() -> void:
	# Направление к стене запоминаем ДО сброса cached_target / last_known_pos.
	# Приоритет: cached_target (актуальная цель), потом last_known_pos.
	var blocked_pos: Vector3 = Vector3.INF
	if _cached_target != null and is_instance_valid(_cached_target):
		blocked_pos = _cached_target.global_position
	elif _last_known_target_pos != Vector3.INF:
		blocked_pos = _last_known_target_pos
	if blocked_pos != Vector3.INF:
		var to_blocked := Vector3(blocked_pos.x - global_position.x, 0.0, blocked_pos.z - global_position.z)
		if to_blocked.length_squared() > VecUtil.EPSILON_SQ:
			_blocked_target_dir = to_blocked.normalized()
	if _local_wander_mode:
		# Уже в режиме, повторное срабатывание stuck — просто перевыбираем
		# точку (предыдущая wander-цель видимо упёрлась в ту же стену).
		_wander_target = _pick_local_wander_target()
		_wander_phase = WanderPhase.WANDERING
		return
	_local_wander_mode = true
	# Сторона обхода — раз и навсегда per stuck-сессию. Разные скелеты ↔
	# разные стороны → толпа расходится по обе стороны забора.
	_local_wander_side = 1 if randf() < 0.5 else -1
	_cached_target = null
	_last_known_target_pos = Vector3.INF
	_wander_target = _pick_local_wander_target()
	_wander_phase = WanderPhase.WANDERING
	if LogConfig.master_enabled:
		print("[Skeleton] упёрся в стену → local wander (side=%d)" % _local_wander_side)


## Точка локального wander'а с bias'ом «вдоль стены». Если blocked_target_dir
## задан, выбираем точку в полуплоскости _local_wander_side от направления
## на стену (±30° от перпендикуляра) — скелет движется параллельно забору.
## Делаем LOCAL_WANDER_LOS_RETRIES попыток с LOS-чеком: точка за тем же
## палисадом отбрасывается. Если все попытки в стену — fallback на любую
## (скелет пытается снова через следующий stuck-цикл).
func _pick_local_wander_target() -> Vector3:
	var has_dir: bool = _blocked_target_dir.length_squared() > VecUtil.EPSILON_SQ
	# Перпендикуляр к direction-on-wall в горизонтальной плоскости. Для
	# Vector3(x, 0, z) перпендикуляры: (z, 0, -x) и (-z, 0, x).
	# Берём ту, что соответствует _local_wander_side.
	var perp: Vector3 = Vector3.ZERO
	if has_dir:
		perp = Vector3(_blocked_target_dir.z, 0.0, -_blocked_target_dir.x) * float(_local_wander_side)
	var fallback_candidate: Vector3 = global_position
	for attempt in range(LOCAL_WANDER_LOS_RETRIES):
		var dir: Vector3
		if has_dir:
			# ±30° tilt от перпендикуляра. randf_range(-1, 1) × 0.5 рад ≈ ±28°.
			var tilt: float = randf_range(-0.5, 0.5)
			dir = perp.rotated(Vector3.UP, tilt).normalized()
		else:
			# Нет направления (например, _enter_local_wander без cached_target) —
			# полный random угол как в старой логике.
			var angle: float = randf() * TAU
			dir = Vector3(cos(angle), 0.0, sin(angle))
		var dist: float = randf_range(LOCAL_WANDER_DISTANCE_MIN, LOCAL_WANDER_DISTANCE_MAX)
		var t: Vector3 = global_position + dir * dist
		t.x = clampf(t.x, -wander_map_half_extent, wander_map_half_extent)
		t.z = clampf(t.z, -wander_map_half_extent, wander_map_half_extent)
		t.y = global_position.y
		if attempt == 0:
			fallback_candidate = t
		# LOS-чек: луч от себя+1м к target+1м на маске PALISADE. Если попал —
		# точка за стеной, перевыбираем.
		if _is_segment_clear_of_palisade(global_position, t):
			return t
	return fallback_candidate


## Проверка «отрезок не пересекает палисад». Аналог _has_line_of_sight_to,
## но между произвольными точками (а не от self к ноде). Та же низкая
## фиксированная высота LOS_RAY_HEIGHT, чтобы луч не перепрыгивал стену.
func _is_segment_clear_of_palisade(from_pos: Vector3, to_pos: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var from := Vector3(from_pos.x, from_pos.y + LOS_RAY_HEIGHT, from_pos.z)
	var to := Vector3(to_pos.x, to_pos.y + LOS_RAY_HEIGHT, to_pos.z)
	var q := PhysicsRayQueryParameters3D.create(from, to, Layers.PALISADE_OBSTACLE)
	q.exclude = [self.get_rid()]
	return space.intersect_ray(q).is_empty()


## Ищет ближайший skeleton_target в горизонтальном радиусе вокруг скелета.
## Использует [Enemy._target_grid] — нет лишних group-сканов. Возвращает
## null если в радиусе ничего нет (тогда stuck остаётся, на следующем
## кадре попробуем снова — может разойдёмся со стеной через slide).
func _find_nearest_obstacle(radius: float) -> Node3D:
	Enemy._maybe_refresh_target_grid(get_tree())
	var pos: Vector3 = global_position
	var skel_cell := Enemy._grid_cell(pos)
	var r_sq: float = radius * radius
	var nearest: Node3D = null
	var nearest_sq: float = r_sq
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var cell := Vector2i(skel_cell.x + dx, skel_cell.y + dz)
			if not Enemy._target_grid.has(cell):
				continue
			var entries: Array = Enemy._target_grid[cell]
			for entry in entries:
				var raw = entry[1]
				if not is_instance_valid(raw):
					continue
				var node := raw as Node3D
				if node == null:
					continue
				if not node.is_in_group(TARGET_GROUP):
					continue
				# Стены/здания (MELEE_ONLY) ВКЛЮЧАЕМ: упёрся → это и есть та
				# постройка, что блокирует путь к гному; берём её целью и ломаем.
				# Цикла нет — _target_still_valid теперь её принимает, а LOS-стена
				# не даёт скану сдёрнуть нас на гнома за ней (он не виден), пока
				# не пробьём. (2026-06-09: было `if MELEE_ONLY: continue` → wander.)
				var d_sq: float = Vector2(
					node.global_position.x - pos.x,
					node.global_position.z - pos.z,
				).length_squared()
				if d_sq < nearest_sq:
					nearest_sq = d_sq
					nearest = node
	return nearest


## Raycast «глаза скелета → центр цели» на маске PALISADE_OBSTACLE. Если
## попадание — между нами стена, цель не видна. Вызывается из [_scan_target]
## throttled (vision_scan_interval × LOD-mult ≈ 0.3-1.2с), так что общая
## нагрузка ~1-2k ray/сек на 200 скелетах — терпимо.
##
## ВАЖНО про высоту: оба конца луча на ФИКСИРОВАННОЙ skel.y + LOS_RAY_HEIGHT.
## Раньше брал target.global_position.y + 1.0 — но Tower имеет origin на y≈3
## (центр большого меша), и луч уходил по диагонали высоко, перепрыгивая
## палисад (~1.5м высоты). Сейчас оба конца на y≈0.7 — строго горизонтальный
## низкий луч, гарантированно режется стеной.
##
## Маска ТОЛЬКО PALISADE_OBSTACLE: Tower / палатки / гномы / земля не блокируют
## зрение (Tower на ACTORS, палатки на CAMP_OBSTACLE, гномы на FRIENDLY_UNIT).
## Иначе скелет «слеп» через каждую палатку, чего мы не хотим.
const LOS_RAY_HEIGHT: float = 0.7
func _has_line_of_sight_to(target: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return true  # no physics space yet — fail-open, без LOS не блокируем
	var y: float = global_position.y + LOS_RAY_HEIGHT
	var from := Vector3(global_position.x, y, global_position.z)
	var to := Vector3(target.global_position.x, y, target.global_position.z)
	var q := PhysicsRayQueryParameters3D.create(from, to, Layers.PALISADE_OBSTACLE)
	# САМА цель — не преграда. Замок стоит на PALISADE_OBSTACLE (блокирует башню
	# физикой) — луч к его центру бился в его ЖЕ коллайдер → «за стеной», vision
	# слеп, скелеты его не атаковали (фикс 2026-07-07).
	if target is CollisionObject3D:
		q.exclude = [self.get_rid(), (target as CollisionObject3D).get_rid()]
	else:
		q.exclude = [self.get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	return hit.is_empty()


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
			elif _last_known_target_pos != Vector3.INF:
				_persist_toward_last_known(delta)
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
	if not _target_still_valid(_cached_target):
		return null
	return _cached_target


## Сам скан — ближайшая в vision_radius из группы skeleton_target.
##
## **Spatial grid** ([Enemy._target_grid]): вместо полного обхода группы
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
	# Grid и load обновляются синхронно: load Skeleton-specific, поэтому
	# вызывается только когда Enemy реально пересобрал grid.
	if Enemy._maybe_refresh_target_grid(get_tree()):
		Skeleton._refresh_target_load(get_tree())
	var skel_pos := global_position
	var skel_cell := Enemy._grid_cell(skel_pos)
	var vr_sq: float = vision_radius * vision_radius
	# Два кандидата гнома: «свободный» (load < TARGET_CAP) и любой ближайший
	# как fallback. Палатки кэшируем отдельно — они без cap'а.
	var nearest_free_gnome: Node3D = null
	var nearest_free_gnome_dist_sq := vr_sq
	var nearest_any_gnome: Node3D = null
	var nearest_any_gnome_dist_sq := vr_sq
	var nearest_other: Node3D = null
	var nearest_other_dist_sq := vr_sq
	# self не должен считать свою старую цель в load — будем готовиться её
	# сменить. На случай если других кандидатов нет и swap не должен лишить
	# нас текущей цели.
	var self_target_id: int = -1
	if is_instance_valid(_cached_target):
		self_target_id = _cached_target.get_instance_id()

	# 3×3 cell'ов вокруг текущей позиции скелета. cell_size=12 = vision_radius,
	# поэтому 3×3 cell'ов гарантированно покрывает диск vision_radius. Тонкость:
	# если скелет на углу cell'а, цель в углу противоположного cell'а (3 cell'а
	# по диагонали) может быть за пределами vision_radius — отсекается dist²-чеком.
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var cell := Vector2i(skel_cell.x + dx, skel_cell.y + dz)
			if not Enemy._target_grid.has(cell):
				continue
			var entries: Array = Enemy._target_grid[cell]
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
				# Стены/палисад не цель для базового melee — он переходит в
				# local-wander вокруг них (см. [_enter_local_wander]).
				if node.is_in_group(MELEE_ONLY_TARGET_GROUP):
					continue
				# Line-of-sight: палисад блокирует зрение. Гном за стеной — не
				# цель; иначе скелет видит сквозь забор, идёт, упирается, входит
				# в local wander, vision снова даёт ту же цель — дёрганый цикл.
				# Делается ПОСЛЕ дешёвых group-чеков — raycast только для прошедших.
				if not _has_line_of_sight_to(node):
					continue
				# Приоритет «гном vs прочее» (палатки) — через group, не через
				# `is Gnome`. Контракт: GNOME_GROUP содержит все гномы (мирных
				# и Defender'ов). Палатки в TARGET_GROUP, но не в GNOME_GROUP.
				if node.is_in_group(Gnome.GNOME_GROUP):
					# Любой гном — кандидат «без cap'а» (fallback если все
					# свободные слоты гномов заняты).
					if d_sq < nearest_any_gnome_dist_sq:
						nearest_any_gnome_dist_sq = d_sq
						nearest_any_gnome = node
					# Гном со свободным слотом — основной кандидат. Self-load
					# вычитаем: если эта цель уже наша, не считаем себя — иначе
					# swap-loop'ы (отдал бы цель ради «свободной», и снова взял).
					var gnome_id: int = node.get_instance_id()
					var gnome_load: int = int(Skeleton._target_load.get(gnome_id, 0))
					if gnome_id == self_target_id:
						gnome_load -= 1
					if gnome_load < TARGET_CAP and d_sq < nearest_free_gnome_dist_sq:
						nearest_free_gnome_dist_sq = d_sq
						nearest_free_gnome = node
				else:
					if d_sq < nearest_other_dist_sq:
						nearest_other_dist_sq = d_sq
						nearest_other = node
	# Приоритет: свободный гном → палатка → capped'ый гном → forced.
	# 4-й/5-й скелет на одного гнома не зависают в idle, но идут на палатки
	# если они в зоне видимости — это распределяет волну по объектам обороны.
	if nearest_free_gnome != null:
		return nearest_free_gnome
	if nearest_other != null:
		return nearest_other
	if nearest_any_gnome != null:
		return nearest_any_gnome
	# Vision пуст — на forced_target (палатка-якорь для wave-скелетов вне
	# vision_radius). Гномы в 12м зоне всегда отбирают приоритет.
	# LOS-фильтр ТОЛЬКО в _local_wander_mode: иначе wave-скелет на спавне
	# в 50м от палисада сразу отверг бы forced (raycast 50м проходит сквозь
	# стену) и ушёл бы в wander, не дойдя до лагеря. Когда скелет уже
	# упёрся (local mode) — фильтр предотвращает цикл APPROACH→stuck→wander.
	# Открытие LOS (нашёл обход) автоматически выводит из local-wander через
	# _set_cached_target.
	if is_instance_valid(_forced_target) and _forced_target.is_in_group(TARGET_GROUP):
		if not _local_wander_mode or _has_line_of_sight_to(_forced_target):
			return _forced_target
	return null


## Назначает форсированную цель (палатку лагеря). Используется WaveDirector'ом
## на спавне волны: ставит ближайшую к точке спавна палатку как aggro-точку.
func set_forced_target(target: Node3D) -> void:
	_forced_target = target


func _perform_strike(_target: Node3D) -> void:
	# AoE strike: damage'им всех в TARGET_GROUP в радиусе attack_range ×
	# STRIKE_RADIUS_FACTOR вокруг скелета. _windup_target используем только
	# для направления self-lunge'а — кого скелет «целил», туда и пройдёт
	# выпад. Damage применяется ко всем в зоне независимо от lock'а.
	#
	# Почему не single-target по _windup_target: его лок задумывался против
	# «strike по гному за 11м» (без contact-чека через Damageable.try_damage),
	# но slack-валидация (×1.5) всё равно требовала чтобы цель не уходила
	# из радиуса. Pikeman после lunge'а драфтит из этого радиуса за 0.4с
	# замаха, и strike мажет полностью — даже если pikeman всё ещё в melee'е
	# на 1.8м. AoE решает это физически: размах конечностью, кто рядом, тот
	# и получил.
	var locked: Node3D = _windup_target
	_windup_target = null
	var strike_radius: float = attack_range * STRIKE_RADIUS_FACTOR
	var hits: int = 0
	var alarm_victim: Node3D = null  # первая палатка/мирный гном среди жертв
	# AOE-strike через spatial grid (Enemy._target_grid) вместо полного
	# get_nodes_in_group(TARGET_GROUP): при 200 скелетах × 1Гц атак полный
	# обход ~28k ops/с впустую (целей в радиусе ≤attack_range×1.3 — единицы,
	# в 3×3 cells of SKEL_GRID_CELL_SIZE=4м их всегда хватает).
	Enemy._maybe_refresh_target_grid(get_tree())
	var skel_cell: Vector2i = Enemy._grid_cell(global_position)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var cell := Vector2i(skel_cell.x + dx, skel_cell.y + dz)
			if not Enemy._target_grid.has(cell):
				continue
			var entries: Array = Enemy._target_grid[cell]
			for entry in entries:
				var raw = entry[1]
				if not is_instance_valid(raw):
					continue
				var node := raw as Node3D
				if node == null:
					continue
				var d_sq: float = (node.global_position - global_position).length_squared()
				# Крупная цель (ядро) шире — её центр дальше strike-радиуса, хотя
				# скелет вплотную к коллизии. Расширяем радиус на её reach-бонус.
				var eff: float = strike_radius + target_reach_bonus(node)
				if d_sq > eff * eff:
					continue
				if Damageable.try_damage(node, attack_damage):
					hits += 1
					# Alarm-сигнал триггерим только на палатке/мирном гноме —
					# боевые юниты себя не «зовут». Берём первого, чтобы не
					# спамить EventBus.
					if alarm_victim == null and not node.is_in_group(SoldierGnome.SOLDIER_GROUP):
						alarm_victim = node
	if hits > 0 and alarm_victim != null:
		EventBus.skeleton_attacked_camp.emit(self, alarm_victim, alarm_victim.global_position)
	# Self-lunge: направление к locked-target'у если он ещё валиден, иначе
	# вперёд по текущему look_at. Lunge не зависит от попадания — это движение
	# тела вперёд после взмаха, даже на промахе.
	if is_instance_valid(locked):
		_do_lunge(locked)
	else:
		var forward := -transform.basis.z  # local -Z = forward
		_apply_velocity_change(
			Vector3(forward.x * lunge_speed, 0.0, forward.z * lunge_speed),
			lunge_duration,
		)


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
	# ОВЕРКИЛЛ (_overkill, Enemy.take_damage): чем сильнее удар перекрыл HP, тем
	# больше осколков и мощнее разлёт — В СТОРОНУ удара (meta last_hit_dir).
	if _mesh:
		_mesh.visible = false
	if _effects_root:
		var extra: int = int(ceil(_overkill * 3.0))  # до +9 осколков на жирном оверкилле
		var dir: Vector3 = get_meta(&"last_hit_dir", Vector3.ZERO) if _overkill > 0.2 else Vector3.ZERO
		ShatterEffect.spawn(_effects_root, global_position, shatter_color,
			shatter_fragment_count + extra, shatter_lifetime, dir, 1.0 + _overkill * 0.6)
