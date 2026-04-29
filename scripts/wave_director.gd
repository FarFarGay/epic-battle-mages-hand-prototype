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
##   * waves: каждые wave_interval с спавнит wave_count скелетов **группой** в
##     случайной точке карты вне зоны видимости лагерей (radius ≥ wave_safe_radius
##     до любого Camp). Группа целеустремлённо идёт на ближайший лагерь —
##     каждому скелету ставится forced_target = ближайшая палатка лагеря.
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
@export var wave_count: int = 10
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
## Сколько раз пробуем рандомную точку до фоллбэка. На карте 400×400 с
## 6 лагерями вероятность попасть в safe-зону высокая — 30 попыток с большим
## запасом. Фоллбэк: берём точку с максимумом min-distance до лагерей.
@export var wave_position_attempts: int = 30
@export_group("")

@export var debug_log: bool = true

var _spawner: EnemySpawner
var _camps: Array[Camp] = []

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
	# 1. Выбрать точку спавна вне зоны видимости лагерей.
	var origin := _pick_safe_pos()
	# 2. Ближайший живой лагерь к этой точке.
	var target_camp := _nearest_alive_camp(origin)
	if target_camp == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] волна пропущена — нет живых лагерей")
		return
	# 3. Ближайшая палатка этого лагеря — она и будет aggro-целью группы.
	var target_part := target_camp.nearest_part_to(origin)
	if target_part == null:
		if debug_log and LogConfig.master_enabled:
			print("[WaveDirector] волна пропущена — у лагеря %s нет живых палаток" % target_camp.name)
		return
	# 4. Спавн группы и назначение forced_target каждому скелету.
	var skeletons := _spawner.spawn_group(skeleton_scene, wave_count, origin, wave_group_radius)
	for enemy in skeletons:
		if enemy is Skeleton:
			(enemy as Skeleton).set_forced_target(target_part)
	if debug_log and LogConfig.master_enabled:
		var dist := origin.distance_to(target_part.global_position)
		print("[WaveDirector] волна %d скелетов в (%.0f, %.0f) → %s/%s (dist=%.0fм)" % [skeletons.size(), origin.x, origin.z, target_camp.name, target_part.name, dist])


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


## Рандомная точка на карте, удалённая от всех лагерей минимум на wave_safe_radius.
## Делает wave_position_attempts попыток; если ни одна не прошла фильтр —
## возвращает точку с максимумом min-distance до лагерей (наиболее изолированную
## из попыток). Это деградация, не failure: спавн всё равно произойдёт.
func _pick_safe_pos() -> Vector3:
	var extent := _spawner.map_half_extent
	var safe_sq := wave_safe_radius * wave_safe_radius
	var best_pos := Vector3.ZERO
	var best_min_dist_sq := -1.0

	for i in range(wave_position_attempts):
		var candidate := Vector3(
			randf_range(-extent, extent),
			0.0,
			randf_range(-extent, extent),
		)
		var min_dist_sq := _min_dist_sq_to_camps(candidate)
		if min_dist_sq >= safe_sq:
			return candidate
		# Запоминаем лучшую (наиболее изолированную) на случай фоллбэка.
		if min_dist_sq > best_min_dist_sq:
			best_min_dist_sq = min_dist_sq
			best_pos = candidate

	if debug_log and LogConfig.master_enabled:
		var actual_dist := sqrt(best_min_dist_sq) if best_min_dist_sq > 0.0 else 0.0
		print("[WaveDirector] safe-точка не найдена за %d попыток — фоллбэк на dist=%.1f" % [wave_position_attempts, actual_dist])
	return best_pos


func _min_dist_sq_to_camps(pos: Vector3) -> float:
	var min_sq := INF
	for camp in _camps:
		if not is_instance_valid(camp) or not camp.has_alive_parts():
			continue
		var d_sq: float = (camp.current_center() - pos).length_squared()
		if d_sq < min_sq:
			min_sq = d_sq
	# Если живых лагерей нет — возвращаем INF (любая точка «безопасна», но
	# волна потом всё равно скипнется в _spawn_wave из-за target_camp == null).
	return min_sq


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
