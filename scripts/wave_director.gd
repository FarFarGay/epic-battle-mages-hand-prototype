class_name WaveDirector
extends Node
## Режиссёр кампании врагов — POI-driven архитектура (с K2/K3-итерации).
##
## Геймдизайн-петля:
## - Между POI: караван едет, активного лагеря нет. Фоновый «прилив» —
##   глобальная популяция wander-скелетов растёт по wall-clock минутам
##   (background_initial_count → background_cap), независимо от действий
##   игрока. Эти скелеты сами агрятся на караван и гномов через vision.
## - На POI: игрок жмёт R рядом с костром, лагерь развёртывается. Camp
##   эмитит camp_deployed → WaveDirector находит соответствующий
##   QuestActor по anchor'у, берёт его wave_schedule и проигрывает stage'ы
##   по порядку. Стадии увеличивают темп И/ИЛИ размер пачки во времени.
##   На camp_packed — POI-волны останавливаются. Фон продолжает идти.
## - Следующий POI игрок заходит в более грязный мир (фон вырос). Это и
##   даёт «постепенно тяжелее» без явного level-design'а сложности.
##
## Старая RAMP/MAINTAIN-фаза удалена. initial_count/ramp_*/replenish_*
## заменены на background_*. Wave-параметры (interval, per_wave) теперь
## per-POI в [WaveSchedule], а не глобальные.
##
## Рестарт по P: kill_all_skeletons + reset_population на всех camp_paths
## + сброс background-таргета + остановка активного POI. С нуля.

enum Phase { IDLE, RUNNING }
## Day/Night фаза. День — тихая фаза «отдыха» (короткая, ~12с), ночь —
## боевая «защити лагерь» (длинная, ~60с). Циклится бесконечно пока
## кампания идёт (Phase.RUNNING). Старт всегда с дня — игрок получает
## дыхание перед первой ночью.
enum DayNight { DAY, NIGHT }

@export_group("Refs")
@export_node_path("EnemySpawner") var spawner_path: NodePath
## Лагеря: для P-рестарта (reset_population) и для поиска активного Camp
## по anchor'у при camp_deployed. WaveDirector сам не знает, какой Camp
## развернулся — ищет ближайший к anchor в этом массиве.
@export var camp_paths: Array[NodePath] = []
@export var skeleton_scene: PackedScene
## Сцена скелета-гиганта (танк, фокус на Tower). Спавнится каждые
## [member giant_every_n_waves] волн как «боссовая» точка волны. Если null —
## гиганты не спавнятся.
@export var giant_scene: PackedScene
## Каждые N волн POI-осады дополнительно спавнится 1 гигант (расчёт идёт
## глобально по счётчику волн, не per-stage). 0 = выключено.
## Дизайн: «фокусная угроза Tower'у» — гигант идёт прямо на башню (override
## `_scan_target` в [SkeletonGiant]), форсит мобильность игрока. Каждая 3-я
## волна — нормальный темп: достаточно часто чтобы Tower не была безопасной
## точкой, не слишком чтобы карта не превращалась в зоопарк гигантов.
@export var giant_every_n_waves: int = 3
## Сцена гиганта-каменщика (ranged-танк, кидает камни в Tower с 25-35м).
## Спавнится каждые [member thrower_every_n_waves] волн (как Giant, но реже)
## + входит в состав боссовой волны. Без неё — Tower не имеет ranged-угрозы.
@export var giant_thrower_scene: PackedScene
## Каждые N волн POI-осады дополнительно спавнится 1 каменщик. Чуть реже
## Giant'а (4 vs 3) — у него ranged-AOE болевые камни, не должен быть
## фоновым явлением. Связка с Giant'ом: на одной волне может быть и тот,
## и другой (счётчики независимы, не блокируют друг друга). 0 = выключено.
@export var thrower_every_n_waves: int = 4

## Сцена вражеского меха ([EnemyMech]) — естественный враг башни (бой мехов):
## крупный, быстрый, бьёт тяжёлым прицельным снарядом по Tower с дистанции.
## Пока спавнится ТОЛЬКО читом cheat_spawn_mech; авто-спавн в волнах — позже.
@export var mech_scene: PackedScene

@export_group("Day/Night cycle")
## Длительность дня в секундах. День = «безопасное окно»: POI-волны выключены
## полностью (см. [day_poi_waves_enabled]), фон не растёт. Игрок может
## оставить лагерь без присмотра и идти на квест (искать ключ, разведывать
## ресурсы, тестить стены). 180с = 3 минуты — достаточно сходить туда-сюда.
@export var day_duration_seconds: float = 180.0
## Длительность ночи в секундах. Ночь = «защити лагерь»: POI-волны идут,
## фон растёт, Giant/Thrower/Boss-триггеры активны. 120с = 2 минуты —
## пик плотного геймплея.
@export var night_duration_seconds: float = 120.0
## POI-волны днём вообще не идут. False (default) — день полностью безопасный
## от POI-осады (фон и caravan-волны остаются по своим правилам — но caravan
## triggerit только если лагерь в caravan-стадии, не в DEPLOYED, так что
## развёрнутый лагерь днём НЕ получает waves at all). True — днём идут
## волны с множителем [day_wave_interval_multiplier]. Раньше day был «волны
## редкие», теперь — «волн вообще нет».
@export var day_poi_waves_enabled: bool = false
## Множитель wave_interval'а POI-стадии днём (актуально только если
## [day_poi_waves_enabled] = true). Используется как escape-hatch для
## A/B-тестинга «полностью безопасный день» vs «редкие дневные волны».
@export var day_wave_interval_multiplier: float = 2.5
## Растёт ли фоновая популяция днём. False (default) — фон стоит на текущем
## уровне до ночи. Скелеты которые УЖЕ на карте wander'ят и могут агриться
## на одинокого гнома, но новые не появляются. На ночь рост возобновляется
## (см. [_tick_background]).
@export var day_background_grows: bool = false
@export_group("")

@export_group("Boss wave")
## Каждые N волн POI-осады — «боссовая волна»: 1 Giant + N Throwers'ов
## одновременно с разных сторон, предупреждение в HUD за несколько секунд
## до спавна. Это пик нарратива, под который игрок планирует super/мины.
## 0 = выключено. Боссовая волна не дублируется обычными giant/thrower
## триггерами на той же _wave_count'е.
@export var boss_wave_every_n: int = 6
## Сколько секунд показывать предупреждение «Гигант приближается» до
## фактического спавна. 6с — успеть переориентировать squad, скастовать
## мины, отойти к Tower'у.
@export var boss_wave_warning_seconds: float = 6.0
## Сколько Thrower'ов спавнить в боссовой волне (вокруг Giant'а с разных
## сторон). 2 — комфортный минимум для ощущения «давления со всех сторон»,
## не превращает Tower в pinata.
@export var boss_wave_thrower_count: int = 2
@export_group("")
## Сцена ArcherGroup — координатор группы из 4 лучников. Спавнится через
## cheat_spawn_archer_group; в авто-волнах пока не используется.
@export var archer_group_scene: PackedScene
@export_group("")

@export_group("Background tide (фоновая угроза)")
## Сколько скелетов мгновенно спавнится на P (стартовое население карты).
## Они wander-ят и агрятся на караван/гномов по vision'у. 25 (было 50) —
## понижено для менее агрессивного старта: при дне=120с игрок успевает
## осмотреться без давления.
@export var background_initial_count: int = 25
## Темп роста таргет-популяции в **скелетах в минуту** wall-clock времени.
## Через 10 минут после P при growth=15 target = 25 + 150 = 175 скелетов
## (раньше было 350 на тех же минутах).
@export var background_growth_per_minute: float = 15.0
## Потолок таргет-популяции. Дальше фон не растёт. 300 (было 600) — фон
## всё ещё «живой», но не давит постоянной осадой; основной challenge
## переехал на POI/боссовые волны.
@export var background_cap: int = 300
## Период подспавна одного скелета при дефиците (live < target). 1.0с —
## плавный «прилив», не залп. Если просадка большая (например после
## зачистки POI игроком), подкачка идёт ровно по 1/сек до возврата к target.
@export var background_replenish_interval: float = 1.0
@export_group("")

@export_group("Warband siege (день/ночь, бродячие банды)")
## Мастер-тумблер: ON → старый непрерывный фоновый прилив ВЫКЛ, вместо него
## бродячие банды днём + штурм-банда с 1 фронта ночью (осмысленная осада).
@export var warband_siege_enabled: bool = true
## День: сколько бродячих банд держим на карте (роумят, нападают опортунистично).
@export var day_warband_count: int = 3
## День: размер бродячей банды — «файт-энкаунтер», не осада.
@export var day_warband_size: int = 25
## День: интервал досспавна банды, если их меньше day_warband_count.
@export var day_warband_spawn_interval: float = 12.0
## Ночь: размер штурм-банды (осада с 1 фронта).
@export var night_assault_size: int = 120
## Телеграф штурма: ТОНКАЯ мигающая дуга по КРАЮ зоны строительства (radius =
## Camp.build_radius), со стороны фронта. Появляется в момент штурма и мигает
## ВСЁ ВРЕМЯ, пока волна не войдёт в зону строительства (иначе можно пропустить).
## telegraph_thickness — радиальная толщина дуги, half_angle — её угловая ширина.
@export var telegraph_thickness: float = 0.6
@export var telegraph_half_angle_deg: float = 26.0
@export var telegraph_color: Color = Color(1.0, 0.12, 0.08, 0.75)
@export_group("")

## Активные банды (прунятся когда queue_free сами по гибели всех членов).
var _warbands: Array[SkeletonWarband] = []
var _warband_spawn_cd: float = 0.0
## Штурм-банда спавнится ОДИН раз за ночь. Сбрасывается на день.
var _night_assault_done: bool = false
## Дуги-телеграфы штурма: ПО ОДНОЙ на каждую штурм-банду (несколько фронтов →
## несколько дуг). Элемент — Dictionary {warband, mesh, mat}. Каждая мигает, пока
## ЕЁ банда не войдёт в зону строительства (или не будет выбита). Фаза мигания общая.
var _telegraphs: Array[Dictionary] = []
var _telegraph_pulse_t: float = 0.0

@export_group("Caravan waves (атаки на караван в дороге)")
## Период между caravan-волнами в секундах. Каждая волна спавнит группу
## скелетов в случайной точке вокруг каравана. Тикает пока есть живой
## Camp, который не развёрнут (CARAVAN_FOLLOWING-стадия). На camp_deployed
## таймер засыпает — POI-осада ведёт атаки сама. На camp_packed —
## возобновляется.
@export var caravan_wave_interval: float = 25.0
## Стартовый размер caravan-волны. 2 (было 3) — две слабых для аккуратного
## старта пока игрок ещё учится управлять караваном.
@export var caravan_wave_size_initial: int = 2
## Прирост размера caravan-волны в минуту wall-clock. Через 5 минут при
## initial=2, growth=0.3 → 2 + 0.3×5 = 3.5 скелетов на волну (≈4).
@export var caravan_wave_size_growth_per_minute: float = 0.3
## Потолок размера caravan-волны. 6 (было 12) — даже на длинной партии
## караван не сталкивается с осадным числом противников по дороге; этим
## занимается POI-осада, не caravan-тик.
@export var caravan_wave_size_cap: int = 6
## Дистанция от центра каравана до точки спавна caravan-волны. 28м =
## чуть за пределами tower-вижена (20м), скелеты появляются «из ниоткуда»,
## но физически близко чтобы успеть догнать караван.
@export var caravan_spawn_distance: float = 28.0
## Разброс кластера caravan-волны. Та же семантика что wave_group_radius
## для POI-волн.
@export var caravan_group_radius: float = 3.5
@export_group("")

@export_group("POI siege spawn")
## Радиус разброса группы вокруг точки спавна волны. Группа должна выглядеть
## плотной, но не штабелем. 10 скелетов в r=4 — комфортная плотность.
@export var wave_group_radius: float = 4.0
## Минимальная дистанция от точки спавна волны до ближайшего лагеря. Меньше —
## волна появляется в зоне видимости защитников, ломает идею «ниоткуда».
@export var wave_safe_radius: float = 32.0
## Буфер за wave_safe_radius для точки спавна волны (м): враги появляются чуть
## за безопасным радиусом, не на самой кромке. Общий для одиночных групп и осад.
const WAVE_SPAWN_BUFFER := 8.0
## Порог² совпадения POI с лагерем при поиске камеры (м²); 5м → 25.
const POI_CAMP_MATCH_DIST_SQ := 25.0
## Fallback safe-радиус POI, если QuestActor не предоставил собственный
## (через свойство safe_radius). Используется в [_safe_score] для фонового
## размещения. POI с QuestActor-скриптом дают свой safe_radius напрямую —
## это значение для совместимости со «странными» POI-нодами.
@export var poi_safe_radius_fallback: float = 32.0
## Сколько раз пробуем рандомную точку до фоллбэка для фонового спавна.
@export var wave_position_attempts: int = 30
@export_group("")

@export var debug_log: bool = true

var _spawner: EnemySpawner
var _camps: Array[Camp] = []
## POI-ноды — собираются через группу [QuestActor.POI_GROUP] лениво в
## _collect_pois_deferred. Раньше брались из poi_root_path-детей напрямую
## (Poi_*-маркеры без скрипта), но wave_schedule/safe_radius/API живут
## на их QuestActor-детях. Через группу мы гарантированно получаем нужные
## ноды независимо от иерархии в main.tscn.
var _pois: Array[Node3D] = []

var _phase: int = Phase.IDLE
## Текущая таргет-популяция фона. Float, чтобы плавно расти по delta.
## Растёт со старта кампании; на P-рестарте сбрасывается в background_initial_count.
var _background_target: float = 0.0
## Кулдаун до следующего ramp-доспавна одного фонового скелета. Тикает в
## _tick_background. Каждые background_replenish_interval секунд — попытка
## подкачать одного скелета если live < target.
var _background_replenish_cd: float = 0.0

## Активный POI и его Camp — заполняются на camp_deployed, чистятся на packed.
## Если null — POI-волны не идут (только фон).
var _active_camp: Camp = null
var _active_poi: Node3D = null
var _active_schedule: WaveSchedule = null
var _stage_index: int = 0
var _stage_elapsed: float = 0.0
## Кулдаун до следующей POI-волны. Берётся из stage.wave_interval, тикает
## пока активный POI не сменился/не остановился.
var _wave_cd: float = 0.0
## Глобальный счётчик POI-волн (incrementится каждый spawn). Используется для
## гигантов: спавнится дополнительно если `_wave_count % giant_every_n_waves == 0`.
## Сбрасывается на clear_active_poi (новая осада начинается с 1).
var _wave_count: int = 0
## Кулдаун до следующего «разведчика» (одиночного скелета). Тикает
## параллельно _wave_cd на активной стадии. Если stage.scout_interval=0 —
## канал выключен (не тикаем, не спавним). Не консумит SpawnZone.waves_left.
var _scout_cd: float = 0.0

## Таймер периодического мониторинга skeleton-в-safe-зоне (как раньше).
var _safe_zone_check_cd: float = 0.0
var _last_safe_zone_count: int = -1

## Таймер до следующей caravan-волны. Тикает пока есть живой Camp в
## CARAVAN_FOLLOWING (любой Camp с has_alive_parts() и not is_deployed()).
## Сбрасывается на caravan_wave_interval после каждого спавна.
var _caravan_wave_cd: float = 0.0
## Wall-clock метка старта кампании (ms, Time.get_ticks_msec). Используется
## для линейного роста размера caravan-волн. На рестарте обновляется.
var _campaign_started_at_ms: int = 0

## Текущая фаза day/night. Тикает только в Phase.RUNNING, сбрасывается на
## DAY при старте/рестарте кампании. Меняется в [_tick_day_night] когда
## [_day_night_remaining] доходит до нуля.
var _day_night: int = DayNight.DAY
## Сколько секунд осталось до смены фазы. Тикается в [_tick_day_night];
## на ≤0 → переключаем фазу, эмитим [signal EventBus.day_phase_changed],
## взводим обратно на новое значение из @export'ов.
var _day_night_remaining: float = 0.0

## Кулдаун до фактического спавна боссовой волны после предупреждения.
## -1 = нет pending волны. Взводится в [_tick_active_poi] когда счётчик
## волн попадает на [member boss_wave_every_n], в этот же момент летит
## [signal EventBus.boss_wave_incoming] для HUD'а. Тикает в [_process],
## при ≤0 → [_spawn_boss_wave]. Не сбрасывается рестартом активного POI:
## если игрок сменит POI пока волна летит — она просто спавнится на
## новом лагере (это редкий edge case, нормально).
var _pending_boss_wave_cd: float = -1.0


## Группа для discovery извне без явных NodePath. WaveDirector один на сцену;
## ResourceZone, Camp и другие потребители safe/POI-логики находят его
## через get_first_node_in_group, чтобы не требовать ручной NodePath-привязки.
const GROUP := &"wave_director"


func _ready() -> void:
	add_to_group(GROUP)
	if not spawner_path.is_empty():
		_spawner = get_node_or_null(spawner_path) as EnemySpawner
	if _spawner == null:
		push_error("WaveDirector: spawner_path не разрешился — кампания не сможет спавнить")
	for path in camp_paths:
		if path.is_empty():
			continue
		var camp := get_node_or_null(path) as Camp
		if camp != null:
			_camps.append(camp)
		else:
			push_warning("WaveDirector: camp_path %s не Camp" % path)

	# Подписка на лагерные сигналы — POI-driven осада активируется здесь.
	# camp_deployed/packed эмитит каждый Camp при смене состояния
	# CARAVAN ↔ DEPLOYED. WaveDirector один на сцену → один слушатель
	# обрабатывает все лагеря.
	EventBus.camp_deployed.connect(_on_camp_deployed)
	EventBus.camp_packed.connect(_on_camp_packed)

	# Собираем POI лениво — после первого process_frame все QuestActor._ready
	# отработали и зарегистрировались в группе POI_GROUP. Без await группа
	# может оказаться пустой если порядок _ready нашего узла раньше детей
	# Poi_*/Actor (на практике редко, но защита бесплатная).
	_collect_pois_deferred()

	# Автостарт кампании при «Начать игру» (StartMenu взвёл MatchConfig.
	# match_started=true перед reload). Без флага молчим — первый запуск
	# игры остаётся «спокойным» до клика на меню.
	# call_deferred: _ready ещё в фазе setup'а дерева — синхронный спавн врагов
	# через add_child тут падает («Parent node is busy setting up children»),
	# инстансы текут (RID-leak на выходе). Откладываем старт на конец кадра,
	# когда сцена полностью в дереве.
	if MatchConfig.match_started:
		_start_campaign.call_deferred()


## Лениво собирает POI через группу [QuestActor.POI_GROUP]. Группа содержит
## именно QuestActor-ноды (на которых safe_radius и wave_schedule), а не
## их родителей-маркеров Poi_*. Это решает баг «лагерь развёрнут — осады нет»:
## раньше _pois содержал Poi_*-без-скрипта, has_method('get_wave_schedule')
## возвращал false и WaveDirector считал POI «мирным».
func _collect_pois_deferred() -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	_pois.clear()
	for n in get_tree().get_nodes_in_group(QuestActor.POI_GROUP):
		if not is_instance_valid(n):
			continue
		if n is Node3D:
			_pois.append(n as Node3D)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] собрано POI-зон: %d" % _pois.size())


func _process(delta: float) -> void:
	if _phase == Phase.RUNNING:
		_tick_day_night(delta)
		# Warband-осада ВМЕСТО непрерывного фонового прилива: день=бродячие банды,
		# ночь=штурм с 1 фронта. Тумблер warband_siege_enabled.
		if warband_siege_enabled:
			_tick_warbands(delta)
		else:
			_tick_background(delta)
		if _active_camp != null and _active_schedule != null:
			_tick_active_poi(delta)
		# Caravan-волны идут параллельно фону пока есть Camp в пути к POI.
		# Если активная POI-осада запущена (_active_camp != null) — этот же
		# лагерь сидит в DEPLOYED, _find_caravan_camp() его пропустит. То есть
		# одновременно идут либо «caravan для лагеря-каравана + POI-осада для
		# другого лагеря», либо одно из двух — на нашей одной-Camp-сцене это
		# просто переключение.
		_tick_caravan_waves(delta)
		_tick_pending_boss_wave(delta)

	_tick_safe_zone_monitor(delta)


## Кампания активна? Используется DayNightOverlay'ем для sync'а состояния
## в `_ready` — если overlay подключился к сигналу позже эмита (порядок
## _ready сиблингов в main.tscn), он должен видеть что фаза уже идёт.
func is_running() -> bool:
	return _phase == Phase.RUNNING


## Сейчас ночь? Гейтит giant/thrower/boss-спавн в [_tick_active_poi] и
## используется HUD'ом через [get_day_night_state] / [get_day_night_remaining].
func is_night() -> bool:
	return _day_night == DayNight.NIGHT


## Public для HUD: текущая фаза и оставшееся время. HUD пуллит раз в кадр
## (дёшево) — на сигналы реагирует только на смену фазы (звук/тинт).
func get_day_night_state() -> int:
	return _day_night

func get_day_night_remaining() -> float:
	return maxf(_day_night_remaining, 0.0)


## Тик day/night-цикла. Уменьшает _day_night_remaining; при ≤0 меняет фазу
## и эмитит сигнал. Не пытаемся «дожать» волну до конца — если ночь
## закончилась, волны просто становятся редкими (день начинается, переключатель
## в `_tick_active_poi`).
func _tick_day_night(delta: float) -> void:
	_day_night_remaining -= delta
	if _day_night_remaining > 0.0:
		return
	# Переключаем фазу. Carryover отрицательного остатка в новую фазу —
	# чтобы цикл не «отставал» по wall-clock.
	var carryover: float = _day_night_remaining
	if _day_night == DayNight.DAY:
		_day_night = DayNight.NIGHT
		_day_night_remaining = night_duration_seconds + carryover
	else:
		_day_night = DayNight.DAY
		_day_night_remaining = day_duration_seconds + carryover
	EventBus.day_phase_changed.emit(is_night(), _phase_duration())
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] фаза → %s на %.0fс" % [
			"НОЧЬ" if is_night() else "ДЕНЬ", _phase_duration(),
		])


## Полная длительность текущей фазы (для сигнала / HUD-старта countdown'а).
func _phase_duration() -> float:
	return night_duration_seconds if is_night() else day_duration_seconds


## Тик отложенной боссовой волны. Если cd взведён (≥0) — тикает; на ≤0
## вызывает фактический спавн и сбрасывает в -1.


## Тик отложенной боссовой волны. Если cd взведён (≥0) — тикает; на ≤0
## вызывает фактический спавн и сбрасывает в -1.
func _tick_pending_boss_wave(delta: float) -> void:
	if _pending_boss_wave_cd < 0.0:
		return
	_pending_boss_wave_cd -= delta
	if _pending_boss_wave_cd > 0.0:
		return
	_pending_boss_wave_cd = -1.0
	_spawn_boss_wave()


# --- Public cheat API (вызывается из JournalPanel вкладки «Читы») ---
# Раньше каждый из этих хуков висел на keyboard-action (P/O/[/]), но дизайнер
# вынес дебаг-управление в отдельную UI-вкладку — клавиши освобождены под
# реальный геймплей, а читы лежат в журнале.

## Старт/рестарт кампании. На первом вызове из IDLE — initial spawn без чистки.
## На повторном — kill_all_skeletons + reset_population + сброс активного POI.
func cheat_start_campaign() -> void:
	_start_campaign()


## Немедленная волна на активный POI (сбрасывает _wave_cd). Без активного POI —
## no-op с предупреждением: волне некуда идти. Использует ту же ветку
## (groups / legacy), что и тик: если у стадии есть groups — спавнит
## многосоставную многофронтовую волну, иначе legacy single-front.
func cheat_force_wave() -> void:
	if _active_camp == null or _active_schedule == null or _active_schedule.is_empty():
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] cheat_force_wave проигнорировано — нет активного POI с осадой")
		return
	var stage := _active_schedule.get_stage(_stage_index)
	if stage == null:
		return
	if stage.has_groups():
		_spawn_groups_wave(_select_groups_for_wave(stage), stage.simultaneous_groups > 1)
	else:
		_spawn_legacy_poi_wave(stage.skeletons_per_wave)
	_wave_cd = stage.wave_interval


## Демо-многофронт: один кластер из каждой живой SpawnZone одновременно,
## фиксированный состав (5 скелетов на зону). Дизайнер видит как ведут
## себя defenders при атаке со всех сторон, без необходимости настраивать
## .tres для теста. Спавн идёт через тот же _spawn_groups_wave-pipeline,
## просто с автосгенерированным массивом CombatGroup'ов «по одному
## на зону».
func cheat_force_multifront_wave() -> void:
	if _active_camp == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] cheat_force_multifront_wave: нет активного лагеря")
		return
	if _spawner == null or skeleton_scene == null:
		push_warning("[WaveDirector] cheat_force_multifront_wave: spawner или skeleton_scene не заданы")
		return
	var zones: Array[SpawnZone] = _spawner.get_zones()
	var groups: Array[CombatGroup] = []
	for i in range(zones.size()):
		var z: SpawnZone = zones[i]
		if not is_instance_valid(z) or z.waves_left() <= 0:
			continue
		var entry := UnitEntry.new()
		entry.scene = skeleton_scene
		entry.count = 5
		var group := CombatGroup.new()
		group.composition = [entry]
		group.spawn_zone_index = i
		group.cluster_spread = 1.0
		groups.append(group)
	if groups.is_empty():
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] cheat_force_multifront_wave: нет живых spawn zone")
		return
	_spawn_groups_wave(groups)


## Моментальный спавн 100 скелетов uniform по safe-зонам. Не трогает фазу/таймеры —
## можно жать в IDLE.
func cheat_spawn_100() -> void:
	_spawn_safe_uniform(100)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] cheat: спавн 100 скелетов (живых после: %d)" % _live_skeleton_count())


## Спавн БРОДЯЧЕЙ БАНДЫ (SkeletonWarband) у случайной живой зоны: банда роумит
## когезивно по карте и нападает на лагерь только если увидит (опортунистично).
## Шаг 1 «осмысленной осады» — день/ночь-каденс придёт следом.
func cheat_spawn_warband() -> void:
	var wb := _spawn_warband(100, SkeletonWarband.Mode.ROAM, null)
	if wb != null and debug_log and LogConfig.master_enabled:
		print("[WaveDirector] cheat: бродячая банда (100)")


## Спавн банды у случайной живой зоны (точка у КРАЯ карты, как _cheat_spawn_enemy).
## mode — ROAM (бродит) или ASSAULT (штурм assault_target). Возвращает банду/null.
## Точка спавна банды у случайной живой зоны (safe-точка у края карты).
## INF — нет живой зоны/спавнера. Вынесено отдельно: ночной штурм спавнит банду
## из этой точки и от неё же строит дугу-телеграф.
func _roll_warband_origin() -> Vector3:
	if _spawner == null:
		return Vector3.INF
	# Несколько попыток с РАЗНЫМИ зонами. _safe_score уже отвергает точки в
	# подземелье (нет навмеш-выхода — банда застрянет), но если выбранная зона
	# целиком в данже — перевыбираем зону, чтоб не уронить сотню скелетов в яму.
	for _attempt in range(4):
		var zone: SpawnZone = _pick_random_live_zone()
		if zone == null:
			return Vector3.INF
		var origin := _pick_safe_point_in_zone(zone)
		if not _point_in_dungeon(origin):
			origin.y = _spawner.spawn_y
			return origin
	return Vector3.INF


func _spawn_warband(size: int, mode: int, assault_target: Node3D) -> SkeletonWarband:
	var origin := _roll_warband_origin()
	if origin == Vector3.INF:
		return null
	return _spawn_warband_at(origin, size, mode, assault_target)


## Спавн банды в КОНКРЕТНОЙ точке (ночной штурм из пре-ролленного origin'а).
func _spawn_warband_at(origin: Vector3, size: int, mode: int, assault_target: Node3D) -> SkeletonWarband:
	if skeleton_scene == null:
		return null
	var wb := SkeletonWarband.new()
	add_child(wb)
	wb.setup(skeleton_scene, origin, size, mode, assault_target)
	wb.set_dungeon_avoid(_get_dungeon_aabb())  # роум не лезет в подземелье
	_warbands.append(wb)
	return wb


## День/ночь каденс банд (вместо непрерывного прилива). ДЕНЬ: 0 направленного
## давления — держим day_warband_count бродячих банд (нападают лишь опортунистично
## по зрению). НОЧЬ: один раз спавним штурм-банду с 1 фронта (forced_target =
## башня) → осада. Бродячие банды дня остаются как ambient-угроза.
func _tick_warbands(delta: float) -> void:
	var alive: Array[SkeletonWarband] = []
	for w in _warbands:
		if is_instance_valid(w):
			alive.append(w)
	_warbands = alive
	_tick_assault_telegraph(delta)  # окно показа дуги при штурме; no-op когда дуги нет
	if is_night():
		if not _night_assault_done:
			_night_assault_done = true
			_launch_night_assault()
		return
	# ДЕНЬ — 0 направленного давления: поддерживаем пул бродячих банд.
	_night_assault_done = false
	_warband_spawn_cd = maxf(_warband_spawn_cd - delta, 0.0)
	if _warbands.size() < day_warband_count and _warband_spawn_cd <= 0.0:
		_warband_spawn_cd = day_warband_spawn_interval
		_spawn_warband(day_warband_size, SkeletonWarband.Mode.ROAM, null)


func _launch_night_assault() -> void:
	_do_assault(night_assault_size, "НОЧЬ")


## Ядро штурма (общее для ночи и чита): роллим точку спавна (вне подземелья),
## спавним банду и В ЭТОТ МОМЕНТ со стороны фронта зажигаем тонкую дугу-телеграф
## по краю зоны строительства. Дуга мигает, ПОКА волна не войдёт в зону (см.
## _tick_assault_telegraph) — её нельзя пропустить.
func _do_assault(size: int, label: String) -> void:
	var target := _resolve_assault_target()
	if target == null:
		return
	var origin := _roll_warband_origin()
	if origin == Vector3.INF:
		return
	var wb := _spawn_warband_at(origin, size, SkeletonWarband.Mode.ASSAULT, target)
	if wb == null:
		return
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] %s: штурм-банда (%d) с фронта" % [label, size])
	var camp := get_tree().get_first_node_in_group(&"camp") as Camp
	if camp == null:
		return
	var center: Vector3 = camp.build_zone_center()
	if center == Vector3.INF:
		return
	# Своя дуга на ЭТУ банду — не трогаем дуги других фронтов.
	var mesh := _spawn_assault_telegraph(center, camp.build_radius, origin)
	if mesh != null:
		_telegraphs.append({
			"warband": wb,
			"mesh": mesh,
			"mat": mesh.material_override as StandardMaterial3D,
		})


## Поднять ТОНКУЮ дугу-телеграф по краю зоны строительства (radius): сектор
## ±half_angle вокруг направления от центра зоны к точке спавна банды. Возвращает
## MeshInstance3D (caller кладёт в _telegraphs) или null.
func _spawn_assault_telegraph(center: Vector3, radius: float, origin: Vector3) -> MeshInstance3D:
	var root: Node = get_tree().current_scene
	if root == null:
		root = get_tree().root
	var dir := Vector3(origin.x - center.x, 0.0, origin.z - center.z)
	if dir.length_squared() < 0.001:
		return null
	var bearing := atan2(dir.x, dir.z)  # как build_block: d(t)=(sin,0,cos), 0=+Z
	var half_t: float = maxf(telegraph_thickness, 0.05) * 0.5
	return AoeVisual.spawn_ground_arc(
		root, center, bearing, deg_to_rad(telegraph_half_angle_deg),
		radius - half_t, radius + half_t, telegraph_color, 0.0,
	)


## Каждая дуга жёстко МИГАЕТ (≈2Гц) и держится, ПОКА ЕЁ волна не вошла в зону
## строительства. Снимаем дугу когда: лагеря/зоны нет, ЕЁ банда выбита по пути,
## или хоть один её член пересёк край зоны. Несколько фронтов → несколько дуг.
func _tick_assault_telegraph(delta: float) -> void:
	if _telegraphs.is_empty():
		return
	var camp := get_tree().get_first_node_in_group(&"camp") as Camp
	var center: Vector3 = camp.build_zone_center() if camp != null else Vector3.INF
	var radius: float = camp.build_radius if camp != null else 0.0
	_telegraph_pulse_t += delta
	var blink: float = 0.5 + 0.5 * sin(_telegraph_pulse_t * TAU * 2.0)
	var emission: float = lerpf(2.0, 6.0, blink)
	var alpha: float = lerpf(0.15, 0.9, blink)
	var kept: Array[Dictionary] = []
	for t in _telegraphs:
		# Variant + is_instance_valid ДО любого использования (банда/меш могли
		# быть freed — typed-assign на freed вылетел бы).
		var wb = t["warband"]
		var mesh_raw = t["mesh"]
		var arrived: bool = center == Vector3.INF \
				or not is_instance_valid(wb) \
				or wb.has_member_within(center, radius)
		if arrived:
			if is_instance_valid(mesh_raw):
				mesh_raw.queue_free()
			continue
		var mat = t["mat"]
		if mat != null and is_instance_valid(mesh_raw):
			mat.emission_energy_multiplier = emission
			mat.albedo_color.a = alpha
		kept.append(t)
	_telegraphs = kept


func _clear_assault_telegraph() -> void:
	for t in _telegraphs:
		var mesh_raw = t["mesh"]
		if is_instance_valid(mesh_raw):
			mesh_raw.queue_free()
	_telegraphs.clear()


## Чит: мгновенно переключить фазу день↔ночь (тест ночной осады без ожидания дня).
func cheat_toggle_phase() -> void:
	if _day_night == DayNight.DAY:
		_day_night = DayNight.NIGHT
		_day_night_remaining = night_duration_seconds
	else:
		_day_night = DayNight.DAY
		_day_night_remaining = day_duration_seconds
	EventBus.day_phase_changed.emit(is_night(), _phase_duration())
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] cheat: фаза → %s" % ("НОЧЬ" if is_night() else "ДЕНЬ"))


## Цель штурма: ближайшая к центру лагеря СТРУКТУРА из группы skeleton_target
## (ядро/палатка/здание). ВАЖНО: forced_target скелета обязан быть в этой группе
## (Skeleton._scan_target отвергает иначе) — поэтому башня (НЕ в группе) не годится,
## и её используем лишь как точку «центра». Гномов пропускаем (двигаются). К цели
## штурм марширует когезивно, стены по пути грызёт сам через vision-аггро.
func _resolve_assault_target() -> Node3D:
	var camp := get_tree().get_first_node_in_group(&"camp") as Camp
	if camp == null:
		return null
	var tower: Node3D = camp.get_tower()
	var center: Vector3 = tower.global_position if (tower != null and is_instance_valid(tower)) else Vector3.ZERO
	var best: Node3D = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group(Enemy.TARGET_GROUP):
		if not (n is Node3D) or not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node.is_in_group(Gnome.GNOME_GROUP):
			continue  # гном-якорь штурма не нужен (двигается); грызём структуры
		var d: float = (node.global_position - center).length_squared()
		if d < best_d:
			best_d = d
			best = node
	return best


## Чит: штурм-банда (100) с 1 фронта НА ЛАГЕРЬ прямо сейчас (тест атаки + дуги-
## телеграфа без ожидания ночи). Идёт через общее ядро — мигающая дуга вспыхнёт.
func cheat_spawn_assault() -> void:
	if _resolve_assault_target() == null:
		push_warning("[WaveDirector] cheat_spawn_assault: нет лагеря/башни для штурма")
		return
	_do_assault(100, "cheat")


## Stress-test: 2000 скелетов uniform по всему квадрату карты, async-батчем.
## Без safe-фильтра, без SpawnZone-фильтра. Для замеров перфоманса в PerfHud.
func cheat_stress_2000() -> void:
	if _spawner != null and skeleton_scene != null:
		_spawner.spawn_uniform(skeleton_scene, 2000)
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] cheat-stress: запущен async-спавн 2000 скелетов")


## Спавн одного скелета-гиганта на лету. Делегирует в _spawn_giant'е если есть
## активная осада (forced_target=Tower). Иначе — fallback через
## _cheat_spawn_enemy: гигант сам найдёт Tower через _scan_target override.
func cheat_spawn_giant() -> void:
	if giant_scene == null:
		push_warning("[WaveDirector] cheat_spawn_giant: giant_scene не задан в инспекторе")
		return
	if _active_camp != null:
		_spawn_giant()
		return
	_cheat_spawn_enemy(giant_scene, "гигант", false)


## Спавн одного гиганта-каменщика на лету. Случайная live SpawnZone,
## forced_target = Tower (если есть активный лагерь). Не зашит в авто-волны.
func cheat_spawn_giant_thrower() -> void:
	if giant_thrower_scene == null:
		push_warning("[WaveDirector] cheat_spawn_giant_thrower: giant_thrower_scene не задан в инспекторе")
		return
	_cheat_spawn_enemy(giant_thrower_scene, "каменщик", true)


## Спавн вражеского меха ([EnemyMech]) на лету. Случайная live SpawnZone,
## forced_target = Tower. Мех сам целит башню (override _resolve_target), но
## assign_tower_target=true даёт корректный forced_target на всякий случай.
func cheat_spawn_mech() -> void:
	if mech_scene == null:
		push_warning("[WaveDirector] cheat_spawn_mech: mech_scene не задан в инспекторе")
		return
	_cheat_spawn_enemy(mech_scene, "мех", true)


## Спавн группы лучников (ArcherGroup, default 4 шт.) в случайной SpawnZone.
## Координатор размещает их в квадратной формации, выровненные фазы → залп
## почти в один кадр. forced_target = ближайшая палатка лагеря (если есть).
func cheat_spawn_archer_group() -> void:
	if archer_group_scene == null:
		push_warning("[WaveDirector] cheat_spawn_archer_group: archer_group_scene не задан в инспекторе")
		return
	if _spawner == null:
		return
	var zone: SpawnZone = _pick_random_live_zone()
	if zone == null:
		push_warning("[WaveDirector] cheat_spawn_archer_group: нет живых SpawnZone")
		return
	var origin: Vector3 = _pick_safe_point_in_zone(zone)
	origin.y = _spawner.spawn_y
	var group := archer_group_scene.instantiate() as ArcherGroup
	if group == null:
		push_warning("[WaveDirector] cheat_spawn_archer_group: scene не инстанцируется как ArcherGroup")
		return
	# ВАЖНО: position ДО add_child. add_child триггерит _ready → _spawn_archers
	# использует global_position. Если ставить global_position после add_child,
	# лучники спавнятся в (0,0,0). position (local) до tree-вставки превращается
	# в global при add_child, т.к. parent (current_scene root) имеет identity-transform.
	group.position = origin
	get_tree().current_scene.add_child(group)
	# forced_target: ближайшая палатка активного лагеря (если есть). Иначе
	# Tower как fallback, иначе оставляем null — лучники найдут цель vision'ом.
	var tgt: Node3D = null
	if _active_camp != null:
		tgt = _active_camp.nearest_part_to(origin)
		if tgt == null:
			tgt = _active_camp.get_tower()
	if tgt != null:
		group.set_forced_target(tgt)
	if debug_log and LogConfig.master_enabled:
		var tgt_label: String = tgt.name if tgt != null else "no-target"
		print("[WaveDirector] cheat: группа лучников @ (%.0f, %.0f) → %s" % [
			origin.x, origin.z, tgt_label,
		])


## Helper для cheat-спавнов одного врага. Случайная live SpawnZone, safe-point,
## spawn_group(1). Опционально назначает forced_target=Tower через
## _assign_forced_targets (если есть _active_camp с Tower).
func _cheat_spawn_enemy(scene: PackedScene, label: String, assign_tower_target: bool) -> void:
	if _spawner == null:
		return
	var zone: SpawnZone = _pick_random_live_zone()
	if zone == null:
		push_warning("[WaveDirector] cheat_spawn (%s): нет живых SpawnZone" % label)
		return
	var origin := _pick_safe_point_in_zone(zone)
	origin.y = _spawner.spawn_y
	var spawned := _spawner.spawn_group(scene, 1, origin, 1.0)
	var tower: Node3D = _active_camp.get_tower() if _active_camp != null else null
	if assign_tower_target and tower != null:
		_assign_forced_targets(spawned, tower)
	if debug_log and LogConfig.master_enabled:
		var tower_label: String = tower.name if tower != null else "no-tower"
		print("[WaveDirector] cheat: %s спавн @ (%.0f, %.0f) → %s" % [
			label, origin.x, origin.z, tower_label,
		])


# --- Старт кампании ---

func _start_campaign() -> void:
	if _spawner == null or skeleton_scene == null:
		push_error("WaveDirector: невозможно стартовать — spawner или skeleton_scene не заданы")
		return

	# Первое P (фаза IDLE) — это «старт», а не «рестарт». Гномов не трогаем —
	# они живые с _ready Camp'а. Скелетов нет, kill_all_skeletons был бы no-op.
	# Только в RUNNING (повторное P) делаем чистку.
	var is_restart := _phase != Phase.IDLE

	if debug_log and LogConfig.master_enabled:
		if is_restart:
			print("[WaveDirector] P-рестарт")
		else:
			print("[WaveDirector] P-старт (первый запуск)")

	if is_restart:
		_spawner.kill_all_skeletons()
		for camp in _camps:
			if is_instance_valid(camp):
				camp.reset_population()
		# Сбрасываем активный POI — Camp на рестарте уже не развёрнут
		# (его reset_population/state не возвращает в DEPLOYED). На следующий
		# деплой осада запустится заново по camp_deployed.
		_clear_active_poi()

	# Initial фоновое население — стартовый «прилив».
	_spawn_safe_uniform(background_initial_count)
	_background_target = float(background_initial_count)
	_background_replenish_cd = background_replenish_interval
	_caravan_wave_cd = caravan_wave_interval
	_campaign_started_at_ms = Time.get_ticks_msec()
	# Стартуем с дня — игрок получает короткое окно дыхания до первой ночи.
	_day_night = DayNight.DAY
	_day_night_remaining = day_duration_seconds
	EventBus.day_phase_changed.emit(false, day_duration_seconds)
	# Сброс телеграфов осады.
	_clear_assault_telegraph()
	_night_assault_done = false
	_phase = Phase.RUNNING


# --- Фоновый прилив ---

## Тик фонового прилива:
## 1. _background_target плавно растёт со скоростью growth_per_minute (с cap'ом).
## 2. Если live < target и кулдаун истёк — спавним одного скелета (uniform safe).
## 3. Кулдаун перевзводится независимо от того, был ли спавн (иначе после долгой
##    стабильности первая просадка ждала бы полный interval).
func _tick_background(delta: float) -> void:
	# Рост target. growth_per_minute / 60 = скелетов в секунду target-увеличения.
	# Днём рост паузим (см. [day_background_grows]) — игроку нужно «безопасное
	# окно» исследования без накопления новых скелетов на карте. Уже-живые
	# скелеты остаются и могут wander'ить, но новые не подспавниваются.
	# Replenish (подкачка до текущего target после убийств) идёт всегда —
	# иначе игрок мог бы зачистить фон днём и встретить пустую ночь.
	if is_night() or day_background_grows:
		_background_target = minf(
			_background_target + (background_growth_per_minute / 60.0) * delta,
			float(background_cap),
		)

	_background_replenish_cd -= delta
	if _background_replenish_cd > 0.0:
		return
	_background_replenish_cd = background_replenish_interval

	var live: int = _live_skeleton_count()
	if float(live) < _background_target:
		_spawn_safe_uniform(1)


# --- Caravan-волны ---

## Тик caravan-волн: атаки на караван в пути к POI. Активен пока есть Camp
## в CARAVAN_FOLLOWING-стадии (any не-deployed Camp с has_alive_parts). Если
## такого Camp'а нет (все лагеря развёрнуты или мертвы) — тикаем cd, но
## не спавним: игроку не нужны caravan-атаки на пустом месте.
##
## Спавн идёт в случайной точке на кольце caravan_spawn_distance вокруг
## current_center() лагеря — это даёт «появление с рандомной стороны». Цель
## пачки — Tower (forced_target), скелеты идут на караван по прямой.
func _tick_caravan_waves(delta: float) -> void:
	_caravan_wave_cd -= delta
	if _caravan_wave_cd > 0.0:
		return
	var camp: Camp = _find_caravan_camp()
	if camp == null:
		# Cd «висит» в нуле — как только караван снова в пути, первая
		# волна срабатывает сразу. Чтобы избежать залпа после долгой
		# DEPLOYED-сессии (cd сильно ушёл в минус), удерживаем нулём.
		_caravan_wave_cd = 0.0
		return
	_caravan_wave_cd = caravan_wave_interval
	if _spawner == null or skeleton_scene == null:
		return
	var wave_size: int = _current_caravan_wave_size()
	var spawn_pos: Vector3 = _pick_caravan_spawn_pos(camp)
	var skeletons: Array[Enemy] = _spawner.spawn_group(
		skeleton_scene, wave_size, spawn_pos, caravan_group_radius,
	)
	var tower: Node3D = camp.get_tower()
	if tower != null:
		_assign_forced_targets(skeletons, tower)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] caravan-волна %d скелетов @ (%.0f, %.0f) → %s" % [
			skeletons.size(), spawn_pos.x, spawn_pos.z,
			tower.name if tower != null else "no-tower",
		])


## Первый живой Camp, который сейчас в caravan-стадии (не deployed). Если
## таких нет — null. На нашей одно-Camp-сцене это всегда возвращает либо
## этот Camp в пути, либо null если он развёрнут.
func _find_caravan_camp() -> Camp:
	for c in _camps:
		if not is_instance_valid(c):
			continue
		if not c.has_alive_parts():
			continue
		if c.is_deployed():
			continue
		return c
	return null


## Размер caravan-волны на момент сейчас: initial + linear-growth-per-minute,
## с потолком cap. Минута считается от _campaign_started_at_ms — wall-clock
## с момента «Начать игру» / cheat_start_campaign.
func _current_caravan_wave_size() -> int:
	var elapsed_ms: int = Time.get_ticks_msec() - _campaign_started_at_ms
	var minutes: float = float(elapsed_ms) / 60000.0
	var size_f: float = float(caravan_wave_size_initial) \
			+ caravan_wave_size_growth_per_minute * minutes
	return clampi(roundi(size_f), caravan_wave_size_initial, caravan_wave_size_cap)


## Точка спавна caravan-волны: случайный угол вокруг центра каравана на
## дистанции caravan_spawn_distance. Без safe-фильтра — наоборот, мы ИЩЕМ
## близкую к каравану точку (фильтр гонит от лагеря, а тут наоборот).
## Clamp в границы карты на случай, если караван у самого края.
func _pick_caravan_spawn_pos(camp: Camp) -> Vector3:
	var center: Vector3 = camp.current_center()
	var angle: float = randf() * TAU
	var pos := Vector3(
		center.x + cos(angle) * caravan_spawn_distance,
		_spawner.spawn_y,
		center.z + sin(angle) * caravan_spawn_distance,
	)
	var half: float = _spawner.map_half_extent
	pos.x = clampf(pos.x, -half, half)
	pos.z = clampf(pos.z, -half, half)
	return pos


# --- POI-волны ---

func _on_camp_deployed(anchor: Vector3) -> void:
	# Находим Camp, развернувшийся ровно сюда. anchor у нас защёлкнут на POI
	# (если require_poi=true) → он же = POI.global_position.
	var camp := _find_camp_at(anchor)
	if camp == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] camp_deployed: лагерь по anchor %s не найден" % str(anchor))
		return
	# Находим POI по тому же anchor'у. Если POI нет (deploy без require_poi —
	# дебаг-режим), осада не запускается. Camp всё равно нормально работает.
	var poi := _find_poi_at(anchor)
	if poi == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] camp_deployed без POI — фон без осады (anchor=%s)" % str(anchor))
		return
	# Берём расписание у POI. Если null/пустое — POI «мирный».
	var schedule: WaveSchedule = null
	if poi.has_method("get_wave_schedule"):
		schedule = poi.get_wave_schedule()
	if schedule == null or schedule.is_empty():
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] POI %s мирный (нет wave_schedule) — без осады" % poi.name)
		return

	# Автостарт кампании на первом деплое осадного POI. Раньше игрок должен
	# был отдельно жать «Старт кампании» в журнале — мало кто помнил. Теперь:
	# развернул лагерь у костра с расписанием → фон + осада сами запускаются.
	# Повторный камп_deployed после рестарта попадает в ветку RUNNING ниже —
	# кампанию повторно не стартуем.
	if _phase == Phase.IDLE:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] автостарт кампании по первому деплою лагеря")
		_start_campaign()

	_active_camp = camp
	_active_poi = poi
	_active_schedule = schedule
	_stage_index = 0
	_stage_elapsed = 0.0
	_wave_count = 0
	var first_stage := schedule.get_stage(0)
	_wave_cd = first_stage.wave_interval if first_stage != null else 0.0
	_scout_cd = first_stage.scout_interval if first_stage != null else 0.0
	if debug_log and LogConfig.master_enabled:
		var first_size: String
		if first_stage == null:
			first_size = "—"
		elif first_stage.has_groups():
			var total: int = 0
			for g in first_stage.groups:
				if g != null:
					total += g.total_count()
			first_size = "%d групп / %d юнитов" % [first_stage.groups.size(), total]
		else:
			first_size = "%d скел/волна" % first_stage.skeletons_per_wave
		print("[WaveDirector] осада старт: POI=%s camp=%s stage=0 (interval=%.0fс, %s)" % [
			poi.name, camp.name, _wave_cd, first_size,
		])


func _on_camp_packed() -> void:
	if _active_camp == null:
		return
	if debug_log and LogConfig.master_enabled:
		var stage_count: int = _active_schedule.stages.size() if _active_schedule != null else 0
		print("[WaveDirector] осада стоп: POI=%s (доиграл до stage %d/%d)" % [
			_active_poi.name if _active_poi != null else "?",
			_stage_index, stage_count,
		])
	_clear_active_poi()


func _clear_active_poi() -> void:
	_active_camp = null
	_active_poi = null
	_active_schedule = null
	_stage_index = 0
	_stage_elapsed = 0.0
	_wave_cd = 0.0
	_scout_cd = 0.0
	_wave_count = 0
	# Отменяем pending boss-wave: предупреждение игрок мог уже забыть, и
	# на новом POI оно непредсказуемо «дожило бы» спавна.
	_pending_boss_wave_cd = -1.0


## Тик активной осады. Stage advance + wave timer.
func _tick_active_poi(delta: float) -> void:
	if not is_instance_valid(_active_camp) or not _active_camp.has_alive_parts():
		# Лагерь разрушен — осада бессмысленна, выключаемся.
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] осада прервана: лагерь %s уничтожен" % (_active_camp.name if _active_camp else "?"))
		_clear_active_poi()
		return
	# Day-gate: днём POI-волны выключены через day_poi_waves_enabled. Stage
	# advance (_stage_elapsed) тоже паузим — иначе на длинных днях лагерь
	# проходил бы все стадии до первой ночной волны. Pending boss-таймер
	# тоже не страдает — он тикается в [_tick_pending_boss_wave] и запущен
	# только из ночного спавна, в дневной режим не попадает.
	if not is_night() and not day_poi_waves_enabled:
		return
	var stage := _active_schedule.get_stage(_stage_index)
	if stage == null:
		return

	_stage_elapsed += delta
	_wave_cd -= delta
	if _wave_cd <= 0.0:
		# Новая модель — массив CombatGroup'ов (поддерживает многофронт +
		# композицию). Legacy fallback — одиночный кластер скелетов.
		# random_groups=true — N preset'ов за волну (simultaneous_groups).
		# multi_directional=true заставляет _spawn_groups_wave размещать
		# группы под равно-распределёнными углами вокруг лагеря.
		if stage.has_groups():
			_spawn_groups_wave(_select_groups_for_wave(stage), stage.simultaneous_groups > 1)
		else:
			_spawn_legacy_poi_wave(stage.skeletons_per_wave)
		_wave_count += 1
		# Day/Night-gate для крупных угроз: Giant/Thrower/Boss спавнятся ТОЛЬКО
		# ночью. Днём идут только базовые волны — короткое «окно дыхания» для
		# починки/строительства. Счётчики (_wave_count % N) тикают независимо
		# от фазы: волна 6 ночью триггерит boss, дневная волна 6 просто
		# проходит без boss.
		if is_night():
			# Боссовая волна: каждые `boss_wave_every_n` волн. ЗАПЛАНИРОВАНА
			# (не спавнится сразу) — за `boss_wave_warning_seconds` секунд до
			# фактического спавна летит EventBus.boss_wave_incoming, HUD показывает
			# предупреждение. На боссовой волне обычные giant/thrower-триггеры
			# подавляются — их роль уже в боссовой связке (Giant + N Throwers).
			var is_boss_wave: bool = (
				boss_wave_every_n > 0
				and giant_scene != null
				and giant_thrower_scene != null
				and _wave_count % boss_wave_every_n == 0
			)
			if is_boss_wave:
				_pending_boss_wave_cd = boss_wave_warning_seconds
				EventBus.boss_wave_incoming.emit(boss_wave_warning_seconds)
				if debug_log and LogConfig.master_enabled:
					print("[WaveDirector] БОССОВАЯ ВОЛНА #%d запланирована, спавн через %.1fс" % [
						_wave_count, boss_wave_warning_seconds,
					])
			else:
				# Гигант: каждые `giant_every_n_waves` волн дополнительно к основной
				# волне. Отдельный спавн со своей spawn-zone, чтобы танк не сливался
				# с пачкой обычных скелетов визуально.
				if giant_every_n_waves > 0 and giant_scene != null and _wave_count % giant_every_n_waves == 0:
					_spawn_giant()
				# Каменщик: каждые `thrower_every_n_waves` волн дополнительно.
				# Параллельный канал с Giant'ом — на одной волне могут быть оба
				# (если счётчики сошлись), это «двойная угроза Tower'у», норм.
				if thrower_every_n_waves > 0 and giant_thrower_scene != null and _wave_count % thrower_every_n_waves == 0:
					_spawn_giant_thrower()
		# Wave_interval днём растягивается множителем — за короткий день обычно
		# успевает 0-1 волна. Ночью идёт по дефолту stage.wave_interval.
		var interval_multiplier: float = 1.0 if is_night() else day_wave_interval_multiplier
		_wave_cd = stage.wave_interval * interval_multiplier

	# Scout-канал: одиночные «разведчики» между основными волнами. Параллельно
	# _wave_cd, со своим интервалом. Если stage.scout_interval=0 — выключено.
	if stage.scout_interval > 0.0:
		_scout_cd -= delta
		if _scout_cd <= 0.0:
			_spawn_scout()
			_scout_cd = stage.scout_interval

	# Stage advance: только если есть следующая стадия. Последняя залипает.
	if _stage_elapsed >= stage.duration and _stage_index + 1 < _active_schedule.stages.size():
		_stage_index += 1
		_stage_elapsed = 0.0
		var next_stage := _active_schedule.get_stage(_stage_index)
		# Wave_cd сохраняем — следующая волна идёт в обычное время по новому
		# темпу. Без этого пользователь получал бы «бесплатную паузу» на
		# переходе стадий, что ломает ощущение нарастающей угрозы.
		_wave_cd = minf(_wave_cd, next_stage.wave_interval) if next_stage != null else _wave_cd
		# Scout_cd ресетим под новый темп — если новая стадия отключает scouts
		# (=0) тиканье прекратится; иначе следующий разведчик через новый интервал.
		_scout_cd = next_stage.scout_interval if next_stage != null else _scout_cd
		if debug_log and LogConfig.master_enabled and next_stage != null:
			# Для groups-driven стадий считаем сумму юнитов по всем группам;
			# для legacy показываем skeletons_per_wave как раньше.
			var stage_size: String
			if next_stage.has_groups():
				var total: int = 0
				for g in next_stage.groups:
					if g != null:
						total += g.total_count()
				stage_size = "%d групп / %d юнитов" % [next_stage.groups.size(), total]
			else:
				stage_size = "%d скел/волна" % next_stage.skeletons_per_wave
			print("[WaveDirector] stage advance %d→%d (interval=%.0fс, %s)" % [
				_stage_index - 1, _stage_index, next_stage.wave_interval, stage_size,
			])


## Спавн одного скелета-гиганта. Берёт случайную живую SpawnZone (на безопасной
## дистанции от лагеря), ставит на ней 1 гиганта. Forced_target — Tower
## активного POI: гигант идёт прямо к башне, игнорируя палатки/гномов
## (его override `_scan_target` тоже возвращает Tower). Не консумит
## SpawnZone.waves_left — гигант это бонус-юнит, не отнимает budget зоны.
##
## Дизайн: фокусная боссовая угроза каждые N волн (giant_every_n_waves).
## Хайвей-маркер «волна стала серьёзной» — игрок видит большого скелета,
## слышит звук, идёт защищать башню вручную (магией / руками).
func _spawn_giant() -> void:
	if _spawner == null or _active_camp == null or giant_scene == null:
		return
	var zone: SpawnZone = _pick_random_live_zone()
	if zone == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] giant пропущен — нет живых SpawnZone")
		return
	var origin := _pick_safe_point_in_zone(zone)
	origin.y = _spawner.spawn_y
	var giants := _spawner.spawn_group(giant_scene, 1, origin, 1.0)
	# Принудительный таргет — Tower. Гигант override'ит _scan_target и сам
	# найдёт башню, но forced_target дублирует это для случая когда vision
	# не успел просканировать (первые тики после спавна).
	var tower: Node3D = _active_camp.get_tower() if _active_camp != null else null
	if tower != null:
		_assign_forced_targets(giants, tower)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] ГИГАНТ #%d спавн @ (%.0f, %.0f) → %s" % [
			_wave_count, origin.x, origin.z,
			tower.name if tower != null else "no-tower",
		])


## Спавн одного каменщика-thrower'а. Аналог [_spawn_giant], но для ranged-
## танка. Берёт случайную живую SpawnZone, ставит одного thrower'а с
## forced_target = Tower. Не консумит SpawnZone.waves_left — как и Giant,
## это бонус-юнит сверх обычной волны.
##
## Дизайн: вторая ось давления на Tower'а в дополнение к Giant'у. Giant
## форсит мобильность (slam-AoE заставляет двигаться), Thrower форсит
## внимание (камень прилетает по point, телеграф на земле). Вместе =
## вилка: убегая от Giant'а, попадёшь под Thrower'а.
func _spawn_giant_thrower() -> void:
	if _spawner == null or _active_camp == null or giant_thrower_scene == null:
		return
	var zone: SpawnZone = _pick_random_live_zone()
	if zone == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] thrower пропущен — нет живых SpawnZone")
		return
	var origin := _pick_safe_point_in_zone(zone)
	origin.y = _spawner.spawn_y
	var throwers := _spawner.spawn_group(giant_thrower_scene, 1, origin, 1.0)
	var tower: Node3D = _active_camp.get_tower() if _active_camp != null else null
	if tower != null:
		_assign_forced_targets(throwers, tower)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] КАМЕНЩИК #%d спавн @ (%.0f, %.0f) → %s" % [
			_wave_count, origin.x, origin.z,
			tower.name if tower != null else "no-tower",
		])


## Боссовая волна: 1 Giant + N Thrower'ов одновременно, размещённые на
## равно-распределённых углах вокруг центра лагеря (как multi-front в
## [_spawn_groups_wave]). Это пик давления: Tower не может сосредоточиться
## на одной угрозе — Giant идёт прямо, Throwers бросают камни с разных
## сторон. Игрок планирует super/мины во время [boss_wave_warning_seconds]
## предупреждения.
##
## Не использует SpawnZone.waves_left и safe-фильтры — спавн строго по
## геометрии вокруг центра лагеря на дистанции wave_safe_radius+8 (как
## multi-front), чтобы стороны были честно противоположными. Если активного
## лагеря уже нет (игрок свернул) — silent skip.
func _spawn_boss_wave() -> void:
	if _spawner == null or _active_camp == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] boss-wave skip — нет активного лагеря")
		return
	if giant_scene == null or giant_thrower_scene == null:
		push_warning("[WaveDirector] boss-wave: giant_scene или giant_thrower_scene не заданы")
		return
	var center: Vector3 = _active_camp.current_center()
	var spawn_dist: float = wave_safe_radius + WAVE_SPAWN_BUFFER
	var tower: Node3D = _active_camp.get_tower()
	# Boss-wave всего N+1 фронт: Giant + boss_wave_thrower_count Throwers.
	# Распределяем по равным углам на окружности, base_angle случайный для
	# вариации.
	var total_fronts: int = 1 + boss_wave_thrower_count
	var base_angle: float = randf() * TAU
	var half: float = _spawner.map_half_extent
	for i in range(total_fronts):
		var angle: float = base_angle + TAU * float(i) / float(total_fronts)
		var origin := Vector3(
			center.x + cos(angle) * spawn_dist,
			_spawner.spawn_y,
			center.z + sin(angle) * spawn_dist,
		)
		origin.x = clampf(origin.x, -half, half)
		origin.z = clampf(origin.z, -half, half)
		# Первый фронт — Giant, остальные — Throwers.
		var scene: PackedScene = giant_scene if i == 0 else giant_thrower_scene
		var spawned := _spawner.spawn_group(scene, 1, origin, 1.0)
		if tower != null:
			_assign_forced_targets(spawned, tower)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] БОССОВАЯ ВОЛНА спавн: Giant + %d Throwers вокруг лагеря (r=%.0f)" % [
			boss_wave_thrower_count, spawn_dist,
		])


## Спавн одиночного «разведчика» — параллельный канал микро-угроз.
## Берёт случайную живую SpawnZone, ставит на нём 1 скелета, цель — ближайшая
## палатка активного лагеря. НЕ консумит SpawnZone.waves_left (scouts не
## расходуют budget зоны, иначе при scout_interval=15с зоны кончались бы
## за пару минут). Если зон нет — silent skip.
##
## Дизайн: одиночка достаточно медленный/слабый чтобы рука обработала его
## между сборкой ресурсов. На сложных стадиях добавляют темпа, но не
## заменяют собой большие волны.
func _spawn_scout() -> void:
	if _spawner == null or _active_camp == null:
		return
	var zone: SpawnZone = _pick_random_live_zone()
	if zone == null:
		return
	var origin := _pick_safe_point_in_zone(zone)
	origin.y = _spawner.spawn_y
	var target_part := _active_camp.nearest_part_to(origin)
	if target_part == null:
		return
	var scouts := _spawner.spawn_group(skeleton_scene, 1, origin, 1.0)
	_assign_forced_targets(scouts, target_part)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] scout @ (%.0f, %.0f) → %s" % [
			origin.x, origin.z, target_part.name,
		])


## Legacy single-front POI-волна: группа из `count` скелетов из случайной
## живой SpawnZone в сторону палаток активного лагеря. Используется для
## WaveStage без `groups` (старая модель).
func _spawn_legacy_poi_wave(count: int) -> void:
	if _spawner == null or _active_camp == null:
		return
	var zone: SpawnZone = _pick_random_live_zone()
	if zone == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] POI-волна пропущена — нет SpawnZone с остатком")
		return
	var origin := _pick_safe_point_in_zone(zone)
	origin.y = _spawner.spawn_y
	var target_part := _active_camp.nearest_part_to(origin)
	if target_part == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] POI-волна пропущена — у лагеря нет живых палаток")
		return
	var skeletons := _spawner.spawn_group(skeleton_scene, count, origin, wave_group_radius)
	_assign_forced_targets(skeletons, target_part)
	zone.consume_wave()
	if debug_log and LogConfig.master_enabled:
		var dist := origin.distance_to(target_part.global_position)
		print("[WaveDirector] POI-волна %d скелетов из %s (%.0f, %.0f) → %s/%s (dist=%.0fм)" % [
			skeletons.size(), zone.name, origin.x, origin.z,
			_active_camp.name, target_part.name, dist,
		])


## Выбирает массив групп для текущей волны.
## - random_groups=false → все группы (legacy, все «фронты» одновременно).
## - random_groups=true + simultaneous_groups=1 → одна случайная группа.
## - random_groups=true + simultaneous_groups=N → N УНИКАЛЬНЫХ случайных
##   групп (без повторов). На спавне они получают разные направления
##   через _spawn_groups_wave(multi_directional=true).
func _select_groups_for_wave(stage: WaveStage) -> Array[CombatGroup]:
	if not stage.random_groups or stage.groups.size() <= 1:
		return stage.groups
	var n: int = mini(stage.simultaneous_groups, stage.groups.size())
	if n <= 1:
		# Один preset на волну.
		var picked: CombatGroup = stage.groups[randi() % stage.groups.size()]
		if picked == null:
			return stage.groups
		var single: Array[CombatGroup] = [picked]
		return single
	# N уникальных: shuffle копию массива и взять первые n.
	var pool: Array[CombatGroup] = stage.groups.duplicate()
	pool.shuffle()
	var out: Array[CombatGroup] = []
	for i in range(n):
		if pool[i] != null:
			out.append(pool[i])
	return out


## Новая многосоставная волна: каждая [CombatGroup] спавнится отдельным
## кластером со своей spawn zone (если указана). Многофронт = несколько
## групп с разными `spawn_zone_index`. Композиция = массив [UnitEntry]'ев
## с своими scene'ами и количествами — позволяет смешивать типы юнитов
## в одной группе.
##
## Каждая группа консумит одну волну со своей zone'ы (один `consume_wave`
## на zone-резолв, не на UnitEntry). Это сохраняет старый budget: даже
## составная группа из 10 скелетов в 2 типах — всё ещё «одна волна»
## по budget'у zone'ы.
## multi_directional=true: группы получают равно-распределённые углы вокруг
## camp_center (для N=2 — противоположные стороны), origin вычисляется по
## этому углу на дистанции [_caravan_spawn_distance]-аналоге. Это даёт
## физический многофронт «слева И справа одновременно» — squad не закроет
## оба, рука обязана работать на втором фронте.
##
## multi_directional=false (legacy): каждая группа берёт случайную safe-точку
## в своей SpawnZone — стороны не гарантированы.
func _spawn_groups_wave(groups: Array[CombatGroup], multi_directional: bool = false) -> void:
	if _spawner == null or _active_camp == null:
		return
	if _active_camp.nearest_part_to(_active_camp.global_position) == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] groups-волна пропущена — у лагеря нет живых палаток")
		return
	var spawned_total: int = 0
	var fronts_fired: int = 0
	# Базовый угол volume-рандомизируем чтобы пары фронтов не падали в
	# одни и те же оси каждый раз; деление 360° на N даёт равно-распределённые
	# направления. Для N=2: 0° и 180° относительно base_angle.
	var base_angle: float = randf() * TAU
	var count: int = groups.size()
	for i in range(count):
		var group: CombatGroup = groups[i]
		if group == null or group.is_empty():
			continue
		var ok: bool
		if multi_directional and count > 1:
			var angle: float = base_angle + TAU * float(i) / float(count)
			ok = _spawn_single_group_at_angle(group, angle)
		else:
			ok = _spawn_single_group(group)
		if ok:
			spawned_total += group.total_count()
			fronts_fired += 1
	if debug_log and LogConfig.master_enabled:
		var mode: String = "multi-front" if multi_directional and count > 1 else "single/random"
		print("[WaveDirector] groups-волна (%s): %d фронтов, %d юнитов суммарно" % [
			mode, fronts_fired, spawned_total,
		])


## Спавн одной группы. Возвращает true если хоть что-то заспавнилось.
## Резолвит spawn zone по индексу из группы или random fallback, тянет
## origin из zone, ставит forced_target на ближайшую палатку, проходит
## по композиции и спавнит каждый UnitEntry кластером.
func _spawn_single_group(group: CombatGroup) -> bool:
	var zone: SpawnZone = _resolve_spawn_zone(group.spawn_zone_index)
	if zone == null:
		return false
	var origin := _pick_safe_point_in_zone(zone)
	origin.y = _spawner.spawn_y
	var target_part := _active_camp.nearest_part_to(origin)
	if target_part == null:
		return false
	var radius: float = wave_group_radius * group.cluster_spread
	var any_spawned: bool = false
	for entry in group.composition:
		if entry == null or entry.scene == null or entry.count <= 0:
			continue
		var enemies := _spawner.spawn_group(entry.scene, entry.count, origin, radius)
		_assign_forced_targets(enemies, target_part)
		any_spawned = true
	if any_spawned:
		zone.consume_wave()
	return any_spawned


## Спавн группы под конкретным углом от центра лагеря. Используется в
## multi_directional-режиме: точка origin = center + (cos(a), 0, sin(a))×dist,
## где dist = wave_safe_radius + buffer. Это гарантирует разные стороны
## периметра для каждого фронта. Zone берётся первой live (для consume_wave
## budget'а); если нет — fallback на random.
func _spawn_single_group_at_angle(group: CombatGroup, angle: float) -> bool:
	if _active_camp == null or _spawner == null:
		return false
	var center: Vector3 = _active_camp.current_center()
	# Дистанция спавна: чуть дальше safe-радиуса (volume имеет смысл «вне
	# зоны защитников»). +8м буфера — комфортная свобода для гнома
	# заметить пачку и среагировать.
	var spawn_dist: float = wave_safe_radius + WAVE_SPAWN_BUFFER
	var origin := Vector3(
		center.x + cos(angle) * spawn_dist,
		_spawner.spawn_y,
		center.z + sin(angle) * spawn_dist,
	)
	var half: float = _spawner.map_half_extent
	origin.x = clampf(origin.x, -half, half)
	origin.z = clampf(origin.z, -half, half)
	var target_part := _active_camp.nearest_part_to(origin)
	if target_part == null:
		return false
	# Zone-budget: расходуем одну live zone (как legacy). Если нет живых —
	# многофронт всё равно спавним (волна важнее budget'а), но без consume.
	var zone: SpawnZone = _pick_random_live_zone()
	var radius: float = wave_group_radius * group.cluster_spread
	var any_spawned: bool = false
	for entry in group.composition:
		if entry == null or entry.scene == null or entry.count <= 0:
			continue
		var enemies := _spawner.spawn_group(entry.scene, entry.count, origin, radius)
		_assign_forced_targets(enemies, target_part)
		any_spawned = true
	if any_spawned and zone != null:
		zone.consume_wave()
	return any_spawned


## Резолв spawn zone из индекса. Если индекс валиден И zone жива (waves_left
## > 0) — возвращаем её. Иначе fallback на random live zone (как legacy).
## Null если вообще нет живых зон.
func _resolve_spawn_zone(index: int) -> SpawnZone:
	if _spawner == null:
		return null
	var zones: Array[SpawnZone] = _spawner.get_zones()
	if index >= 0 and index < zones.size():
		var z: SpawnZone = zones[index]
		if is_instance_valid(z) and z.waves_left() > 0:
			return z
		# Запрошенная zone мёртвая — silent fallback на random
	return _pick_random_live_zone()


## Случайная zone из get_zones() с waves_left() > 0. Null если все мёртвые.
func _pick_random_live_zone() -> SpawnZone:
	if _spawner == null:
		return null
	var live_zones: Array[SpawnZone] = []
	for z in _spawner.get_zones():
		if is_instance_valid(z) and z.waves_left() > 0:
			live_zones.append(z)
	if live_zones.is_empty():
		return null
	return live_zones[randi() % live_zones.size()]


## Назначить forced_target на пачке свежеспавненных юнитов. Duck-typing
## по `set_forced_target` — любой Enemy-наследник, определивший этот метод,
## получит цель. Skeleton сейчас единственный, но добавление skeleton-archer
## или другого типа врага не требует правок здесь.
func _assign_forced_targets(enemies: Array, target: Node3D) -> void:
	for enemy in enemies:
		if enemy.has_method(&"set_forced_target"):
			enemy.set_forced_target(target)


# --- Public API: рантайм-управление budget'ом зон ---

func set_waves_in_all_zones(n: int) -> void:
	if _spawner == null:
		return
	for z in _spawner.get_zones():
		if is_instance_valid(z):
			z.set_waves(n)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] всем зонам выставлено %d волн" % n)


func add_waves_to_all_zones(n: int) -> void:
	if _spawner == null:
		return
	for z in _spawner.get_zones():
		if is_instance_valid(z):
			z.add_waves(n)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] всем зонам добавлено +%d волн" % n)


## Спавнит count скелетов uniform по карте, но каждая точка — вне safe-радиуса
## всех лагерей и POI. Используется для фонового прилива.
func _spawn_safe_uniform(count: int) -> void:
	for i in range(count):
		var pos := _pick_safe_pos()
		pos.y = _spawner.spawn_y
		_spawner.spawn_at(skeleton_scene, pos)


func _pick_safe_pos() -> Vector3:
	var best_pos := Vector3.ZERO
	var best_score := -INF

	for i in range(wave_position_attempts):
		var candidate := _spawner.pick_random_pos()
		var score := _safe_score(candidate)
		if score >= 0.0:
			return candidate
		if score > best_score:
			best_score = score
			best_pos = candidate

	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] safe-точка не найдена за %d попыток — фоллбэк (excess=%.1fм)" % [wave_position_attempts, best_score])
	return best_pos


## Safe-точка строго внутри одной зоны. Используется POI-волнами: точка
## кандидата выбирается uniform внутри прямоугольника zone, отбрасывается
## если попадает в wave_safe_radius от лагеря или safe_radius от POI. До
## wave_position_attempts попыток — иначе берётся «лучшая» (с максимальным
## excess'ом). Это страховка от спавна вплотную к палаткам, когда зона
## перекрывает лагерь (например, одна большая SpawnZone размером с карту).
func _pick_safe_point_in_zone(zone: SpawnZone) -> Vector3:
	if zone == null or _spawner == null:
		return Vector3.ZERO
	var best_pos := Vector3.ZERO
	var best_score := -INF
	for i in range(wave_position_attempts):
		var candidate := _spawner.random_point_in_zone(zone)
		var score := _safe_score(candidate)
		if score >= 0.0:
			return candidate
		if score > best_score:
			best_score = score
			best_pos = candidate
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] safe-точка в зоне %s не найдена за %d попыток — фоллбэк (excess=%.1fм)" % [
			zone.name, wave_position_attempts, best_score,
		])
	return best_pos


## Публичный safe-фильтр для внешних потребителей (ResourceZone WOOD).
func is_safe_pos(pos: Vector3) -> bool:
	return _safe_score(pos) >= 0.0


## Точки в подземелье отвергаются ВСЕМИ spawn-пикерами (банда, штурм, фоновый
## прилив, ResourceZone): дотуда нет навмеш-прохода наружу — заспавненные скелеты
## застревают. Источник границ — DungeonZone (группа &"dungeon_zone"), как в
## [StartMenu]; AABB (+margin) кэшируется на матч.
const DUNGEON_REJECT_SCORE: float = -1.0e6
const DUNGEON_SPAWN_MARGIN: float = 8.0
var _dungeon_aabb: AABB = AABB()
var _dungeon_aabb_ready: bool = false


func _get_dungeon_aabb() -> AABB:
	if _dungeon_aabb_ready:
		return _dungeon_aabb
	_dungeon_aabb_ready = true
	for d in get_tree().get_nodes_in_group(&"dungeon_zone"):
		if d is DungeonZone:
			var zone := d as DungeonZone
			# DungeonZone.size локальный; внешний transform может scale'ить — берём
			# итоговые полу-габариты по XZ через basis (как StartMenu._aabb_from_dungeon).
			var half_x: float = absf(zone.global_transform.basis.x.x * zone.size.x * 0.5) \
					+ absf(zone.global_transform.basis.z.x * zone.size.z * 0.5)
			var half_z: float = absf(zone.global_transform.basis.x.z * zone.size.x * 0.5) \
					+ absf(zone.global_transform.basis.z.z * zone.size.z * 0.5)
			var c: Vector3 = zone.global_position
			var m: float = DUNGEON_SPAWN_MARGIN
			_dungeon_aabb = AABB(
				Vector3(c.x - half_x - m, 0.0, c.z - half_z - m),
				Vector3((half_x + m) * 2.0, 1.0, (half_z + m) * 2.0),
			)
			if debug_log and LogConfig.master_enabled:
				print("[WaveDirector] подземелье найдено: спавн исключён в X[%.0f..%.0f] Z[%.0f..%.0f]" % [
					_dungeon_aabb.position.x, _dungeon_aabb.position.x + _dungeon_aabb.size.x,
					_dungeon_aabb.position.z, _dungeon_aabb.position.z + _dungeon_aabb.size.z,
				])
			return _dungeon_aabb
	_dungeon_aabb = AABB()  # данжа нет — size==0 → _point_in_dungeon всегда false
	if debug_log and LogConfig.master_enabled:
		push_warning("[WaveDirector] DungeonZone не найдена в группе &\"dungeon_zone\" — спавн в данже НЕ исключается")
	return _dungeon_aabb


func _point_in_dungeon(p: Vector3) -> bool:
	var a := _get_dungeon_aabb()
	if a.size.x <= 0.0:
		return false
	return p.x >= a.position.x and p.x <= a.position.x + a.size.x \
			and p.z >= a.position.z and p.z <= a.position.z + a.size.z


## Score точки = минимальный «избыток» (distance − safe_radius) до ближайшей
## запретной зоны: живой Camp (radius=wave_safe_radius) или POI (radius из
## QuestActor.safe_radius, fallback на poi_safe_radius_fallback). Если ни
## лагерей, ни POI нет — возвращает 0. Точки в подземелье — мгновенный reject.
func _safe_score(pos: Vector3) -> float:
	if _point_in_dungeon(pos):
		return DUNGEON_REJECT_SCORE
	var min_excess := INF
	for camp in _camps:
		if not is_instance_valid(camp) or not camp.has_alive_parts():
			continue
		var d: float = camp.current_center().distance_to(pos)
		var excess := d - wave_safe_radius
		if excess < min_excess:
			min_excess = excess
	for poi in _pois:
		if not is_instance_valid(poi):
			continue
		# Per-POI radius если QuestActor.safe_radius доступен. Иначе fallback.
		# Прямое чтение свойства через `in` дешевле, чем has_method-врапер.
		var poi_radius: float = poi_safe_radius_fallback
		if "safe_radius" in poi:
			poi_radius = poi.safe_radius
		var d: float = poi.global_position.distance_to(pos)
		var excess := d - poi_radius
		if excess < min_excess:
			min_excess = excess
	if min_excess == INF:
		return 0.0
	return min_excess


## Ищет Camp, у которого current_center совпадает с anchor (с эпсилоном).
## Используется в _on_camp_deployed: anchor в сигнале — это Camp._deploy_anchor,
## мы по нему находим обратно конкретный лагерь.
func _find_camp_at(anchor: Vector3) -> Camp:
	# Эпсилон по горизонтали: anchor захватывается на _start_deploy с точностью
	# до floating-point, current_center() считается по живым палаткам, может
	# отличаться (на свежем deploy палатки ещё едут к точкам кольца). Возьмём
	# просто ближайший лагерь.
	var nearest: Camp = null
	var nearest_dist_sq := INF
	for camp in _camps:
		if not is_instance_valid(camp):
			continue
		var d_sq: float = (camp.current_center() - anchor).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = camp
	return nearest


## Ищет POI с минимальной дистанцией до anchor. Если эпсилон-расстояние
## (≤ 1м) — это явно тот POI, на который Camp защёлкнул anchor.
func _find_poi_at(anchor: Vector3) -> Node3D:
	var nearest: Node3D = null
	var nearest_dist_sq := INF
	for poi in _pois:
		if not is_instance_valid(poi):
			continue
		var d_sq: float = (poi.global_position - anchor).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = poi
	# Sanity-чек: если ближайший POI всё равно дальше 5м — это уже не «тот POI»,
	# на котором стоит лагерь, а просто соседний. Возвращаем null — не привязываемся.
	if nearest_dist_sq > POI_CAMP_MATCH_DIST_SQ:
		return null
	return nearest


func _live_skeleton_count() -> int:
	return get_tree().get_nodes_in_group(&"skeleton").size()


## Раз в секунду считаем скелетов внутри wave_safe_radius каждого лагеря.
## Логируем по фронту изменения. Для отладки/баланса.
func _tick_safe_zone_monitor(delta: float) -> void:
	if _phase == Phase.IDLE:
		return
	_safe_zone_check_cd -= delta
	if _safe_zone_check_cd > 0.0:
		return
	_safe_zone_check_cd = 1.0

	var count := 0
	var safe_sq := wave_safe_radius * wave_safe_radius
	var skeletons := get_tree().get_nodes_in_group(&"skeleton")
	for s in skeletons:
		if not is_instance_valid(s):
			continue
		var skel := s as Node3D
		if skel == null:
			continue
		for camp in _camps:
			if not is_instance_valid(camp):
				continue
			var d_sq: float = (camp.current_center() - skel.global_position).length_squared()
			if d_sq <= safe_sq:
				count += 1
				break

	if count != _last_safe_zone_count:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] скелетов в safe-зоне (r=%.0fм): %d (было %d) target=%d/%d" % [
				wave_safe_radius, count, _last_safe_zone_count if _last_safe_zone_count >= 0 else 0,
				int(_background_target), background_cap,
			])
		_last_safe_zone_count = count
