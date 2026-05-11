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

@export_group("Refs")
@export_node_path("EnemySpawner") var spawner_path: NodePath
## Лагеря: для P-рестарта (reset_population) и для поиска активного Camp
## по anchor'у при camp_deployed. WaveDirector сам не знает, какой Camp
## развернулся — ищет ближайший к anchor в этом массиве.
@export var camp_paths: Array[NodePath] = []
## DEPRECATED (этап 42, фикс «POI без скрипта»): больше не используется.
## POI собираются через группу [QuestActor.POI_GROUP], потому что
## wave_schedule/safe_radius/API сидят на QuestActor-нодах (детях Poi_*),
## а не на самих Poi_*-маркерах. Поле оставлено только чтоб main.tscn с
## NodePath-override не валился на загрузке.
@export_node_path("Node3D") var poi_root_path: NodePath
@export var skeleton_scene: PackedScene
@export_group("")

@export_group("Background tide (фоновая угроза)")
## Сколько скелетов мгновенно спавнится на P (стартовое население карты).
## Они wander-ят и агрятся на караван/гномов по vision'у.
@export var background_initial_count: int = 50
## Темп роста таргет-популяции в **скелетах в минуту** wall-clock времени.
## Через 10 минут после P при growth=30 target = 50 + 300 = 350 скелетов.
@export var background_growth_per_minute: float = 30.0
## Потолок таргет-популяции. Дальше фон не растёт. Подбирается по PerfHUD —
## на нашей оптимизированной симуляции 600 держит 60fps; за порог не лезем.
@export var background_cap: int = 600
## Период подспавна одного скелета при дефиците (live < target). 1.0с —
## плавный «прилив», не залп. Если просадка большая (например после
## зачистки POI игроком), подкачка идёт ровно по 1/сек до возврата к target.
@export var background_replenish_interval: float = 1.0
@export_group("")

@export_group("POI siege spawn")
## Радиус разброса группы вокруг точки спавна волны. Группа должна выглядеть
## плотной, но не штабелем. 10 скелетов в r=4 — комфортная плотность.
@export var wave_group_radius: float = 4.0
## Минимальная дистанция от точки спавна волны до ближайшего лагеря. Меньше —
## волна появляется в зоне видимости защитников, ломает идею «ниоткуда».
@export var wave_safe_radius: float = 32.0
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

## Таймер периодического мониторинга skeleton-в-safe-зоне (как раньше).
var _safe_zone_check_cd: float = 0.0
var _last_safe_zone_count: int = -1


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
		_tick_background(delta)
		if _active_camp != null and _active_schedule != null:
			_tick_active_poi(delta)

	_tick_safe_zone_monitor(delta)


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
		_spawn_groups_wave(stage.groups)
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


## Stress-test: 2000 скелетов uniform по всему квадрату карты, async-батчем.
## Без safe-фильтра, без SpawnZone-фильтра. Для замеров перфоманса в PerfHud.
func cheat_stress_2000() -> void:
	if _spawner != null and skeleton_scene != null:
		_spawner.spawn_uniform(skeleton_scene, 2000)
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] cheat-stress: запущен async-спавн 2000 скелетов")


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
	_phase = Phase.RUNNING


# --- Фоновый прилив ---

## Тик фонового прилива:
## 1. _background_target плавно растёт со скоростью growth_per_minute (с cap'ом).
## 2. Если live < target и кулдаун истёк — спавним одного скелета (uniform safe).
## 3. Кулдаун перевзводится независимо от того, был ли спавн (иначе после долгой
##    стабильности первая просадка ждала бы полный interval).
func _tick_background(delta: float) -> void:
	# Рост target. growth_per_minute / 60 = скелетов в секунду target-увеличения.
	# float-точность не теряется: после 10 минут roughly +300, в float это OK.
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

	_active_camp = camp
	_active_poi = poi
	_active_schedule = schedule
	_stage_index = 0
	_stage_elapsed = 0.0
	var first_stage := schedule.get_stage(0)
	_wave_cd = first_stage.wave_interval if first_stage != null else 0.0
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] осада старт: POI=%s camp=%s stage=0 (interval=%.0fс, %d скел/волна)" % [
			poi.name, camp.name, _wave_cd, first_stage.skeletons_per_wave if first_stage else 0,
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


## Тик активной осады. Stage advance + wave timer.
func _tick_active_poi(delta: float) -> void:
	if not is_instance_valid(_active_camp) or not _active_camp.has_alive_parts():
		# Лагерь разрушен — осада бессмысленна, выключаемся.
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] осада прервана: лагерь %s уничтожен" % (_active_camp.name if _active_camp else "?"))
		_clear_active_poi()
		return
	var stage := _active_schedule.get_stage(_stage_index)
	if stage == null:
		return

	_stage_elapsed += delta
	_wave_cd -= delta
	if _wave_cd <= 0.0:
		# Новая модель — массив CombatGroup'ов (поддерживает многофронт +
		# композицию). Legacy fallback — одиночный кластер скелетов.
		if stage.has_groups():
			_spawn_groups_wave(stage.groups)
		else:
			_spawn_legacy_poi_wave(stage.skeletons_per_wave)
		_wave_cd = stage.wave_interval

	# Stage advance: только если есть следующая стадия. Последняя залипает.
	if _stage_elapsed >= stage.duration and _stage_index + 1 < _active_schedule.stages.size():
		_stage_index += 1
		_stage_elapsed = 0.0
		var next_stage := _active_schedule.get_stage(_stage_index)
		# Wave_cd сохраняем — следующая волна идёт в обычное время по новому
		# темпу. Без этого пользователь получал бы «бесплатную паузу» на
		# переходе стадий, что ломает ощущение нарастающей угрозы.
		_wave_cd = minf(_wave_cd, next_stage.wave_interval) if next_stage != null else _wave_cd
		if debug_log and LogConfig.master_enabled and next_stage != null:
			print("[WaveDirector] stage advance %d→%d (interval=%.0fс, %d скел/волна)" % [
				_stage_index - 1, _stage_index, next_stage.wave_interval, next_stage.skeletons_per_wave,
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
	var origin := _spawner.random_point_in_zone(zone)
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
func _spawn_groups_wave(groups: Array[CombatGroup]) -> void:
	if _spawner == null or _active_camp == null:
		return
	if _active_camp.nearest_part_to(_active_camp.global_position) == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] groups-волна пропущена — у лагеря нет живых палаток")
		return
	var spawned_total: int = 0
	var fronts_fired: int = 0
	for group in groups:
		if group == null or group.is_empty():
			continue
		if _spawn_single_group(group):
			spawned_total += group.total_count()
			fronts_fired += 1
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] groups-волна: %d фронтов, %d юнитов суммарно" % [
			fronts_fired, spawned_total,
		])


## Спавн одной группы. Возвращает true если хоть что-то заспавнилось.
## Резолвит spawn zone по индексу из группы или random fallback, тянет
## origin из zone, ставит forced_target на ближайшую палатку, проходит
## по композиции и спавнит каждый UnitEntry кластером.
func _spawn_single_group(group: CombatGroup) -> bool:
	var zone: SpawnZone = _resolve_spawn_zone(group.spawn_zone_index)
	if zone == null:
		return false
	var origin := _spawner.random_point_in_zone(zone)
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


## Назначить forced_target на пачке свежеспавненных юнитов. Сейчас
## поддерживаем только Skeleton (единственный Enemy-наследник со
## `set_forced_target`). Будущие типы добавляются здесь же.
func _assign_forced_targets(enemies: Array, target: Node3D) -> void:
	for enemy in enemies:
		if enemy is Skeleton:
			(enemy as Skeleton).set_forced_target(target)


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


## Публичный safe-фильтр для внешних потребителей (ResourceZone WOOD).
func is_safe_pos(pos: Vector3) -> bool:
	return _safe_score(pos) >= 0.0


## Score точки = минимальный «избыток» (distance − safe_radius) до ближайшей
## запретной зоны: живой Camp (radius=wave_safe_radius) или POI (radius из
## QuestActor.safe_radius, fallback на poi_safe_radius_fallback). Если ни
## лагерей, ни POI нет — возвращает 0.
func _safe_score(pos: Vector3) -> float:
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
	if nearest_dist_sq > 25.0:
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
