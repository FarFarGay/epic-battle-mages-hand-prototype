class_name WaveDirector
extends Node
## Режиссёр волн. Управляет фазами кампании врагов — `EnemySpawner` остаётся
## низкоуровневым «как» (инстанцируй сцену, поставь координату), а сюда уезжает
## «когда и сколько» (фазы, таймеры, целевая популяция).
##
## Фазы:
## - IDLE — до первого нажатия P. Ничего не делается.
## - RAMP — первичный набор. На старт — initial_count uniform по карте,
##   затем доспавн по 1 шт каждые ramp_interval с до ramp_target_count.
##   ramp_interval автоматически = ramp_duration / (target − initial), так что
##   полный ramp занимает ramp_duration. Длится фиксированное время — на
##   убийства игрока не реагирует, чтобы первичный набор был детерминирован.
## - MAINTAIN — параллельно: replenish + waves.
##   * replenish: если живых ≤ ramp_target_count − replenish_threshold,
##     доспавнивает по 1 шт каждые replenish_interval до возврата к target.
##     Hysteresis (threshold=20): после убийств не торопимся восстанавливать —
##     даём игроку «передышку», ramp возвращается только при значимой просадке.
##   * waves: каждые wave_interval с дирижёр выбирает SpawnZone с остатком
##     budget'а волн (uniform random) и спавнит из неё группу из
##     `zone.skeletons_per_wave` штук. Цель — ближайший живой лагерь от точки
##     спавна (когда Tower стоит на POI, Camp деплоится туда → wave с соседней
##     зоны идёт на этот POI). После выстрела `zone.consume_wave()` декрементит
##     budget; по исчерпанию зона перестаёт участвовать в волнах (но остаётся
##     в neutral-спавне).
##
## Рестарт по P (в любой фазе): kill_all_skeletons + reset_population на всех
## camp_paths + новый initial spawn → RAMP с нуля. «Воскрешение убитых гномов»
## делается через Camp.reset_population — снести оставшихся, заспавнить новых
## на уцелевших палатках.

enum Phase { IDLE, RAMP, MAINTAIN }

@export_group("Refs")
@export_node_path("EnemySpawner") var spawner_path: NodePath
## Лагеря: цели атаки (для каждой волны выбирается ближайший к точке спавна)
## и адресаты reset_population при P-рестарте.
@export var camp_paths: Array[NodePath] = []
## Корневой узел POI — все его прямые дети считаются точками интереса со
## своими safe-зонами (poi_safe_radius). POI на спавн скелетов влияют только
## геометрически (волны и фоновый wander к ним не прилетают), сам Quest-прогресс
## с этой логикой не связан.
@export_node_path("Node3D") var poi_root_path: NodePath
@export var skeleton_scene: PackedScene
@export_group("")

@export_group("Initial ramp")
## Сколько скелетов спавнится на нажатии P (мгновенно, uniform по карте).
@export var initial_count: int = 20
## Целевая популяция к концу ramp-фазы.
@export var ramp_target_count: int = 50
## За сколько секунд target_count набирается из initial_count. Темп ramp =
## (target − initial) / duration штук в секунду. При 30с / (50 − 20) = 1/с.
@export var ramp_duration: float = 30.0
@export_group("")

@export_group("Maintain — replenish (после ramp)")
## Гистерезис: replenish активен только когда живых ≤ target − threshold.
## При threshold=20 и target=50 — респавн запускается на 30 живых и ниже,
## не на каждое убийство. Это «небольшая задержка на 20 скелетов».
@export var replenish_threshold: int = 20
## Темп респавна в фазе MAINTAIN. Замедленный — раз в 2с против 1с в ramp.
@export var replenish_interval: float = 2.0
@export_group("")

@export_group("Maintain — waves")
## Каждые сколько секунд идёт волна на ближайший лагерь.
@export var wave_interval: float = 60.0
## Радиус разброса группы вокруг точки спавна. Группа должна выглядеть
## плотной (не одиночные скелеты по всей карте), но не накладываться телами.
## 10 скелетов в круге r=4 — плотность ~0.2 м² на скелет, без штабеля.
@export var wave_group_radius: float = 4.0
## Минимальная дистанция от точки спавна до ближайшего лагеря. Меньше —
## волна появляется в зоне видимости защитников/гномов, что ломает идею
## «ниоткуда». Больше — карта забита safe-зонами и точку трудно найти.
## 45м = за пределами patrol_radius=12 + attack_radius=22.5 защитника
## (зона огня = 34.5м) + 10.5м буфер.
@export var wave_safe_radius: float = 45.0
## Минимальная дистанция от точки спавна до любой POI. POI — сюжетные
## точки, спавн скелетов рядом ломает «безопасный подход» к актору. Зона
## та же по порядку что и у лагеря (40-50м), отдельный параметр чтобы
## крутить независимо.
@export var poi_safe_radius: float = 45.0
## Сколько раз пробуем рандомную точку до фоллбэка. На карте 400×400 с
## 6 лагерями вероятность попасть в safe-зону высокая — 30 попыток с большим
## запасом. Фоллбэк: берём точку с максимумом min-distance до лагерей.
@export var wave_position_attempts: int = 30
@export_group("")

@export var debug_log: bool = true

var _spawner: EnemySpawner
var _camps: Array[Camp] = []
var _pois: Array[Node3D] = []

var _phase: int = Phase.IDLE
## Время в RAMP-фазе. По достижении ramp_duration — переход в MAINTAIN.
var _ramp_elapsed: float = 0.0
## Кулдаун до следующего ramp-спавна (по 1 шт).
var _ramp_spawn_cd: float = 0.0
## Сколько ramp-доспавнов сделано (0..ramp_target_count − initial_count).
var _ramp_spawned: int = 0
var _replenish_cd: float = 0.0
var _wave_cd: float = 0.0
## Таймер периодического мониторинга skeleton-в-safe-зоне. Раз в секунду
## считаем сколько скелетов внутри wave_safe_radius каждого лагеря, лог по
## фронту изменения. Без этого логирование проникновений было бы либо спамом
## (на каждый кадр), либо требовало бы on-enter событий через Area3D на лагерях.
var _safe_zone_check_cd: float = 0.0
## Кол-во скелетов в safe-зоне на прошлой проверке (агрегат по всем лагерям).
## Меняется → лог. Стартовый -1 чтобы при первом 0 в фазах IDLE/RAMP не падал лог.
var _last_safe_zone_count: int = -1


func _ready() -> void:
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

	if not poi_root_path.is_empty():
		var poi_root := get_node_or_null(poi_root_path) as Node3D
		if poi_root != null:
			for child in poi_root.get_children():
				if child is Node3D:
					_pois.append(child as Node3D)
		else:
			push_warning("WaveDirector: poi_root_path %s не Node3D" % poi_root_path)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("spawn_enemies"):
		_start_campaign()
		return  # на этом кадре не тикаем — initial spawn уже идёт async

	# O — немедленная волна. Сбрасывает счётчик, чтобы следующая обычная волна
	# была через полный wave_interval, а не через секунды (иначе при O за
	# 5с до плановой волны игрок получил бы дабл-залп). Доступно в любой
	# фазе, включая RAMP — для тестов это удобнее, чем ждать конца ramp'а.
	if Input.is_action_just_pressed("force_wave"):
		if _phase == Phase.IDLE:
			if debug_log and LogConfig.master_enabled:
				print("[WaveDirector] O проигнорировано — кампания не запущена (нажми P)")
		else:
			_spawn_wave()
			_wave_cd = wave_interval

	# [ — debug: моментальный спавн 100 скелетов uniform по safe-зонам.
	# Не трогает фазу/таймеры кампании, может зваться и в IDLE — это просто
	# «накидать массовку для теста». Учитывает Camp/POI safe-зоны как обычный
	# spawn_safe_uniform (через _pick_safe_pos).
	if Input.is_action_just_pressed("debug_spawn_100"):
		_spawn_safe_uniform(100)
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] [-debug: спавн 100 скелетов (живых после: %d)" % _live_skeleton_count())

	# ] — stress-test: спавн 2000 скелетов uniform по всему квадрату карты
	# через async EnemySpawner.spawn_uniform (батчами по _SPAWNS_PER_FRAME=6).
	# Цель — упереться в перфоманс и измерить через PerfHud (F3): где боттлнек
	# — process_ms (CPU AI), physics_ms (CharacterBody3D-коллизии),
	# draw_calls (GPU/uniqueness MeshInstance), память. Игнорирует safe-зоны
	# и SpawnZone-границы — для перф-замера распределение неважно.
	# Fire-and-forget: сама spawn_uniform — coroutine, _process не ждёт.
	if Input.is_action_just_pressed("debug_stress_2000"):
		if _spawner != null and skeleton_scene != null:
			_spawner.spawn_uniform(skeleton_scene, 2000)
			if debug_log and LogConfig.master_enabled:
				print("[WaveDirector] ]-stress: запущен async-спавн 2000 скелетов")

	match _phase:
		Phase.IDLE:
			pass
		Phase.RAMP:
			_tick_ramp(delta)
		Phase.MAINTAIN:
			_tick_maintain(delta)

	_tick_safe_zone_monitor(delta)


# --- Старт кампании ---

func _start_campaign() -> void:
	if _spawner == null or skeleton_scene == null:
		push_error("WaveDirector: невозможно стартовать — spawner или skeleton_scene не заданы")
		return

	# Первое P (фаза IDLE) — это «старт», а не «рестарт». Гномов не трогаем —
	# они живые с _ready Camp'а и не должны заменяться на свежих. Скелетов
	# тоже нет, kill_all_skeletons был бы no-op. Только в RAMP/MAINTAIN
	# (повторное P) делаем чистку: убитые гномы воскресают, скелеты сносятся.
	var is_restart := _phase != Phase.IDLE

	if debug_log and LogConfig.master_enabled:
		if is_restart:
			var phase_name: String = ["IDLE", "RAMP", "MAINTAIN"][_phase]
			print("[WaveDirector] P-рестарт из фазы %s" % phase_name)
		else:
			print("[WaveDirector] P-старт (первый запуск)")

	if is_restart:
		_spawner.kill_all_skeletons()
		for camp in _camps:
			if is_instance_valid(camp):
				camp.reset_population()
	# Initial spawn — uniform по карте, но вне safe-радиуса лагеря, чтобы
	# защитники не открывали огонь сразу после P (раньше initial 20 uniform
	# по 400×400 случайно ронял часть скелетов в 15м зону защитников).
	_spawn_safe_uniform(initial_count)
	# 4. Сброс таймеров и фазы.
	_phase = Phase.RAMP
	_ramp_elapsed = 0.0
	_ramp_spawned = 0
	_ramp_spawn_cd = _ramp_interval()
	_replenish_cd = replenish_interval
	# Первая волна — через wave_interval после конца ramp.
	_wave_cd = ramp_duration + wave_interval


# --- RAMP ---

func _tick_ramp(delta: float) -> void:
	_ramp_elapsed += delta
	_ramp_spawn_cd -= delta

	var ramp_total := ramp_target_count - initial_count
	if _ramp_spawn_cd <= 0.0 and _ramp_spawned < ramp_total:
		_spawn_safe_uniform(1)
		_ramp_spawned += 1
		_ramp_spawn_cd += _ramp_interval()

	if _ramp_elapsed >= ramp_duration:
		_phase = Phase.MAINTAIN
		_replenish_cd = replenish_interval
		_wave_cd = wave_interval
		if debug_log and LogConfig.master_enabled:
			var live := _live_skeleton_count()
			print("[WaveDirector] RAMP завершён — переход в MAINTAIN (живых: %d)" % live)


func _ramp_interval() -> float:
	var ramp_total := ramp_target_count - initial_count
	if ramp_total <= 0:
		return 0.0
	return ramp_duration / float(ramp_total)


# --- MAINTAIN ---

func _tick_maintain(delta: float) -> void:
	# Replenish с гистерезисом.
	_replenish_cd -= delta
	if _replenish_cd <= 0.0:
		var live := _live_skeleton_count()
		var deficit_threshold := ramp_target_count - replenish_threshold
		if live <= deficit_threshold and live < ramp_target_count:
			_spawn_safe_uniform(1)
		# Таймер тикает всегда — иначе после долгой паузы (live=50) первый
		# просадочный спавн отложится на полный interval. С тиканьем —
		# реакция на просадку немедленная (но не чаще interval).
		_replenish_cd = replenish_interval

	# Waves.
	_wave_cd -= delta
	if _wave_cd <= 0.0:
		_spawn_wave()
		_wave_cd = wave_interval


# --- Wave: точка спавна + ближайший лагерь + forced_target ---

func _spawn_wave() -> void:
	# 1. Найти SpawnZone-ы с остатком budget'а волн. Дирижёр здесь и есть
	#    «решает в каком порядке атакуют» — uniform random pick из живых
	#    зон. Если все исчерпаны — тишина (волна пропущена).
	if _spawner == null:
		return
	var live_zones: Array[SpawnZone] = []
	for z in _spawner.get_zones():
		if is_instance_valid(z) and z.waves_left() > 0:
			live_zones.append(z)
	if live_zones.is_empty():
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] волна пропущена — нет SpawnZone-ов с остатком волн")
		return
	var zone: SpawnZone = live_zones[randi() % live_zones.size()]

	# 2. Origin — uniform-точка внутри выбранной зоны. Safe-фильтр Camp/POI
	#    не накладывается: дизайнер сам отвечает что зона стоит снаружи safe-зон
	#    (визуальный контроль через poi-маркер делать не стали — пока трастуем).
	var origin := _spawner.random_point_in_zone(zone)
	origin.y = _spawner.spawn_y

	# 3. Цель — ближайший живой лагерь от origin. Когда Tower стоит на POI,
	#    Camp деплоится туда же → волна из соседней зоны идёт на этот POI.
	var target_camp := _nearest_alive_camp(origin)
	if target_camp == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] волна пропущена — нет живых лагерей")
		return
	var target_part := target_camp.nearest_part_to(origin)
	if target_part == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] волна пропущена — у лагеря %s нет живых палаток" % target_camp.name)
		return

	# 4. Спавн группы из `zone.skeletons_per_wave` штук и назначение forced_target.
	var skeletons := _spawner.spawn_group(skeleton_scene, zone.skeletons_per_wave, origin, wave_group_radius)
	for enemy in skeletons:
		if enemy is Skeleton:
			(enemy as Skeleton).set_forced_target(target_part)
	zone.consume_wave()
	if debug_log and LogConfig.master_enabled:
		var dist := origin.distance_to(target_part.global_position)
		print("[WaveDirector] волна %d скелетов из зоны %s (%.0f, %.0f) → %s/%s (dist=%.0fм, осталось волн в зоне: %d)" % [skeletons.size(), zone.name, origin.x, origin.z, target_camp.name, target_part.name, dist, zone.waves_left()])


# --- Public API: рантайм-управление budget'ом зон ---

## Перезаписывает остаток волн всем зонам (Король Ночи: «всем разом по N»).
func set_waves_in_all_zones(n: int) -> void:
	if _spawner == null:
		return
	for z in _spawner.get_zones():
		if is_instance_valid(z):
			z.set_waves(n)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] всем зонам выставлено %d волн" % n)


## Прибавляет N волн ко всем зонам (накопительное пополнение).
func add_waves_to_all_zones(n: int) -> void:
	if _spawner == null:
		return
	for z in _spawner.get_zones():
		if is_instance_valid(z):
			z.add_waves(n)
	if debug_log and LogConfig.master_enabled:
		print("[WaveDirector] всем зонам добавлено +%d волн" % n)


## Спавнит count скелетов uniform по карте, но каждая точка — вне safe-радиуса
## всех лагерей. Используется для initial и ramp — иначе случайные uniform-точки
## попадают в attack-зону защитников и они начинают огонь сразу после P.
## После спавна скелет wander-ит и может зайти в зону огня сам (фоновый
## противник) — это и нужно. Без forced_target, поэтому к лагерю не идёт
## целеустремлённо (это работа waves).
func _spawn_safe_uniform(count: int) -> void:
	for i in range(count):
		var pos := _pick_safe_pos()
		pos.y = _spawner.spawn_y
		_spawner.spawn_at(skeleton_scene, pos)


## Рандомная точка на карте, удалённая от всех safe-источников (живых лагерей
## и POI) минимум на их радиус. Делает wave_position_attempts попыток; если ни
## одна не прошла фильтр — возвращает точку с максимальным `_safe_score`
## (наименее плохую). Это деградация, не failure: спавн всё равно произойдёт.
func _pick_safe_pos() -> Vector3:
	var best_pos := Vector3.ZERO
	var best_score := -INF

	for i in range(wave_position_attempts):
		# Кандидат — изнутри объединения SpawnZone-ов спавнера (или uniform по
		# карте, если зон нет). Фильтр safe-зон Camp/POI применяется поверх.
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


## Score точки = минимальный «избыток» (distance − safe_radius) до ближайшей
## запретной зоны: живой Camp (radius=wave_safe_radius) или POI (radius=
## poi_safe_radius). >=0 → точка снаружи всех зон.
## <0 → внутри какой-то зоны на |score| метров. Используется и для accept
## (≥0), и для фоллбэка (max). Если ни лагерей, ни POI нет — возвращает 0
## (любая точка ок).
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
		var d: float = poi.global_position.distance_to(pos)
		var excess := d - poi_safe_radius
		if excess < min_excess:
			min_excess = excess
	if min_excess == INF:
		return 0.0
	return min_excess


func _nearest_alive_camp(pos: Vector3) -> Camp:
	var nearest: Camp = null
	var nearest_dist_sq := INF
	for camp in _camps:
		if not is_instance_valid(camp) or not camp.has_alive_parts():
			continue
		var d_sq: float = (camp.current_center() - pos).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = camp
	return nearest


func _live_skeleton_count() -> int:
	return get_tree().get_nodes_in_group(&"skeleton").size()


## Раз в секунду считаем скелетов внутри wave_safe_radius каждого лагеря
## (зона из которой волны не спавнятся, но фоновые wander-скелеты могут
## зайти). Логируем по фронту изменения общего count — без спама на
## стационарном состоянии. Не учитывает пересечение зон лагерей; при
## единственном лагере это и не нужно.
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
				break  # один skel считается один раз даже если в зоне нескольких лагерей

	if count != _last_safe_zone_count:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] скелетов в safe-зоне (r=%.0fм): %d (было %d)" % [wave_safe_radius, count, _last_safe_zone_count if _last_safe_zone_count >= 0 else 0])
		_last_safe_zone_count = count
