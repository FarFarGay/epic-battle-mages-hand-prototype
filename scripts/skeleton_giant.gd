class_name SkeletonGiant
extends Skeleton
## Скелет-гигант — танк, прицеленный на Tower. ~5-8× hp обычного скелета,
## медленный, крупный mesh, большой AoE-strike. Игнорирует палатки/гномов
## пока башня жива — идёт строго к ней. Спавнится WaveDirector'ом каждые N
## волн (см. WaveDirector.giant_every_n_waves) как «боссовая» угроза, дающая
## волне фокусную точку напряжения.
##
## Архитектура: extends Skeleton, не Enemy. Гиганту нужна вся melee-логика
## базового скелета (lunge, AoE-strike, pose-tween, boids, target-load),
## изменяются только параметры (hp/speed/damage/range) через @export defaults
## в скрипте + override scene'ы; override `_scan_target` (Tower имеет приоритет)
## и виртуала `_target_still_valid` (разрешаем Tower в кэше — она не в
## TARGET_GROUP, base иначе сбрасывала бы кэш каждый тик и рандомизировала
## `_approach_angle`, заставляя гиганта вертеться вокруг башни на месте).

const GIANT_GROUP := &"skeleton_giant"

## Радиус рассеивания тумана вокруг гиганта. Дизайнерское решение 2026-05-19:
## гигант — это видимая, наводящая страх угроза, его надо видеть издалека.
## Стандартные скелеты прячутся в туман, гигант — выжигает его собой и
## всегда виден: туман теперь чисто визуальный (врагов не скрывает), а гигант
## ещё и выжигает дымку вокруг себя fog-stamp'ом — силуэт читается издалека.
## Радиус 9м чуть больше радиуса коллизии (1.5м) — пятно вокруг него видно
## издалека как «он рядом, готовься».
var fog_reveal_radius: float = 9.0

## Shared material для всех гигантов — переключает body на тёмный/багряный
## оттенок (отличие от обычного скелетного beige). Static, чтобы один draw-call
## на всех гигантов на сцене.
static var _shared_giant_material: StandardMaterial3D

## Отладочный таймер-лог: раз в DEBUG_LOG_INTERVAL секунд пишет полный snapshot
## (state/cached_target/lod/dist/velocity/position). Цель — увидеть в логе,
## почему гигант не двигается: нет ли цели, скипает ли AI-tick по LOD, в каком
## он FSM-состоянии, и не нулевая ли velocity. Чтобы выключить — поставить
## debug_giant_log=false в инспекторе сцены или master_enabled=false в LogConfig.
@export var debug_giant_log: bool = true
const DEBUG_LOG_INTERVAL: float = 0.5
var _debug_log_timer: float = 0.0

@export_group("Dodge (уворот от снарядов игрока)")
## Радиус, в котором гигант замечает player_projectile и уходит рывком вбок.
@export var dodge_detect_radius: float = 8.0
## Кулдаун уворота (сек).
@export var dodge_cooldown: float = 0.7
## Скорость/длительность рывка-уворота. 16×0.18≈2.9м: мажет single-target Искру
## (impact 1.5м), но AoE-радиус фаербола/мин его перекрывает — это и есть контрплей.
@export var dodge_dash_speed: float = 16.0
@export var dodge_dash_duration: float = 0.18

@export_group("Charge (атака супер-рывком)")
## Скорость/длительность заряд-рывка на башню. 30×0.45=13.5м макс; attack_range
## (в .tscn) задаёт дистанцию начала заряда (откуда бросается).
@export var charge_speed: float = 30.0
@export var charge_duration: float = 0.45
## Дистанция контакта с башней во время заряда — бьём один раз и гасим рывок.
@export var charge_hit_range: float = 2.8

@export_group("Room-гейт (аггр только когда башня В комнате)")
## Центр прямоугольника комнаты (XZ). room_size > 0 включает гейт.
@export var room_center: Vector2 = Vector2.ZERO
## Размеры комнаты (ширина X, глубина Z). (0,0) = гейт ВЫКЛ — старое поведение
## (башня видна всегда, для камповых волн в main.tscn).
@export var room_size: Vector2 = Vector2.ZERO
## Буфер-гистерезис де-аггра: башня перестаёт быть целью, выйдя за комнату+запас.
@export var room_leash_margin: float = 4.0
@export_group("")

## Общий dash-механизм для уворота И заряда (reuse): вектор скорости + остаток фазы.
var _dash_vec: Vector3 = Vector3.ZERO
var _dash_remaining: float = 0.0
var _dash_ghost_t: float = 0.0
var _dodge_cd: float = 0.0
## True если текущий рывок — заряд-атака (бьёт башню на контакте), не уворот.
var _charging: bool = false
var _charge_hit: bool = false


func _ready() -> void:
	super._ready()
	add_to_group(GIANT_GROUP)
	# Тяжёлый: обычный таран башни его НЕ берёт — только СУПЕР-рывок (плюс AoE/магия).
	# Семантическая группа (как room_door для красной двери), а не хардкод-фильтр по типу.
	add_to_group(&"super_dash_only")
	# FOG_REVEAL_GROUP: гигант рассеивает туман собой (см. fog_reveal_radius
	# выше). Двойной эффект: (1) игрок видит силуэт гиганта в тумане
	# издалека, (2) дымка вокруг него разрежена собственным stamp'ом.
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)
	# Override material — super._ready() переключил mesh на shared skeleton material.
	# Для гиганта используем свой shared, отличающийся цветом/эмиссией.
	_ensure_giant_material()
	if _mesh:
		_mesh.material_override = _shared_giant_material
	if debug_giant_log and LogConfig.master_enabled:
		var tower: Node = get_tree().get_first_node_in_group(Tower.GROUP)
		var t_valid := tower != null and is_instance_valid(tower)
		var t_dmg := t_valid and Damageable.is_damageable(tower)
		var p := global_position
		print("[SkeletonGiant:%d] SPAWN @ (%.1f, %.1f, %.1f) tower=%s valid=%s damageable=%s" % [
			get_instance_id(), p.x, p.y, p.z,
			tower.name if t_valid else "null", t_valid, t_dmg,
		])


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not debug_giant_log or not LogConfig.master_enabled:
		return
	_debug_log_timer -= delta
	if _debug_log_timer > 0.0:
		return
	_debug_log_timer = DEBUG_LOG_INTERVAL
	var state_name: String = ["APPROACH", "WINDUP", "STRIKE", "COOLDOWN"][_state]
	var lod_name: String = ["NEAR", "MID", "FAR"][_lod_level]
	var ct := _cached_target
	var ct_name: String = "null"
	var ct_dist: float = -1.0
	var ct_pos := Vector3.ZERO
	if ct != null and is_instance_valid(ct):
		ct_name = ct.name
		ct_pos = ct.global_position
		ct_dist = (ct_pos - global_position).length()
	var v_h := Vector2(velocity.x, velocity.z).length()
	var p := global_position
	var nav_finished: String = "n/a"
	if _nav_agent != null:
		nav_finished = str(_nav_agent.is_navigation_finished())
	print(("[SkeletonGiant:%d] state=%s lod=%s vel_h=%.2f pos=(%.1f,%.1f) "
		+ "tgt=%s dist=%.1f tgt_pos=(%.1f,%.1f) path_around=%s nav_fin=%s "
		+ "kb=%s") % [
		get_instance_id(), state_name, lod_name, v_h, p.x, p.z,
		ct_name, ct_dist, ct_pos.x, ct_pos.z, _should_path_around, nav_finished,
		_knockback.is_active(),
	])


static func _ensure_giant_material() -> void:
	if _shared_giant_material == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.42, 0.38, 0.32, 1.0)
		m.roughness = 0.85
		m.emission_enabled = true
		m.emission = Color(0.9, 0.25, 0.18, 1.0)
		m.emission_energy_multiplier = 0.4
		_shared_giant_material = m


## Tower — приоритетная цель, НО только когда проходит room-гейт (башня внутри
## прямоугольника комнаты, см. _aggro_ok). Гигант замечает её при ВХОДЕ в комнату,
## не сквозь стену. Иначе — fallback на vision-scan (в level_rooms целей нет → wander).
func _scan_target() -> Node3D:
	var tower := get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	if tower != null and is_instance_valid(tower) and _target_still_valid(tower):
		if _aggro_ok(tower):
			return tower
	var scanned := super._scan_target()
	# Башня помечена TARGET_GROUP (level_rooms — чтобы рядовые скелеты её атаковали),
	# но гигант берёт её ТОЛЬКО через room-гейт выше. Vision-скан не должен подсунуть
	# башню вне комнаты — иначе гигант агрился бы на неё без гейта.
	if scanned != null and scanned.is_in_group(Tower.GROUP):
		return null
	return scanned


## Можно ли «проснуться» на башню. Room-гейт задан (room_size>0) → ТОЛЬКО когда
## башня внутри прямоугольника комнаты (по bounds, а не по дистанции — иначе
## агрился бы сквозь стену на близкую башню в соседней комнате). Без гейта —
## башня видна всегда (камповые волны).
## Радиус пробуждения, когда room-гейт не задан (чит-спавн в room / камповые волны) —
## вместо «видит через всю карту». Комнаты крупные, потому щедрый.
const NO_ROOM_AGGRO_RADIUS := 60.0

func _aggro_ok(tower: Node3D) -> bool:
	if room_size.x <= 0.0 or room_size.y <= 0.0:
		# Гейта комнаты нет → будим лишь если башня в радиусе, а не гоним через всю карту.
		return global_position.distance_to(tower.global_position) <= NO_ROOM_AGGRO_RADIUS
	return _tower_in_room(tower, 0.0)


## Башня в прямоугольнике комнаты (room_center/room_size в XZ) c запасом margin.
func _tower_in_room(tower: Node3D, margin: float) -> bool:
	var p: Vector3 = tower.global_position
	return absf(p.x - room_center.x) <= room_size.x * 0.5 + margin \
			and absf(p.z - room_center.y) <= room_size.y * 0.5 + margin


## Override Skeleton._target_still_valid: Tower не в TARGET_GROUP, но валидна как
## цель пока damageable И (если задан room-гейт) в пределах комнаты+буфер. Мёртвая
## башня снимает себя с Damageable.GROUP → фильтр её отшибает.
func _target_still_valid(target: Node3D) -> bool:
	# Башня ПЕРВОЙ: room-гейт доминирует, ДАЖЕ если она в TARGET_GROUP (в level_rooms
	# помечена им для рядовых скелетов). Иначе TARGET_GROUP-ветка вернула бы true и
	# сняла бы room-leash — гигант гнал бы башню через всю карту. Мёртвая башня
	# снимает себя с Damageable.GROUP → отшибётся.
	if target.is_in_group(Tower.GROUP):
		if not Damageable.is_damageable(target):
			return false
		# Room-гейт: держим башню целью пока она в комнате (+буфер-гистерезис). Вышла →
		# де-аггр → wander по комнате. Без гейта (волны) — всегда валидна пока damageable.
		if room_size.x <= 0.0 or room_size.y <= 0.0:
			return true
		return _tower_in_room(target, room_leash_margin)
	return target.is_in_group(TARGET_GROUP)


## Override Skeleton._recompute_path_decision: гигант никогда не обходит
## препятствия — он танк, ломает что встретит. Дополнительно фикс stuck'а
## у Tower: башня в группе `navmesh_source` → навмеш выгрызает hole вокруг
## неё, ring-point на 2.21м от Tower попадает в дыру меша, nav-agent
## строит путь до edge'а меша и встаёт там (~4-5м от Tower, вне attack_range).
## Прямой путь обходит проблему.
func _recompute_path_decision() -> void:
	_should_path_around = false


## Танк-семантика knockback резистанса теперь живёт на Enemy.knockback_resistance
## (@export), значение 0.2 выставлено в skeleton_giant.tscn. Без override —
## база сама умножает impulse×resistance в apply_knockback.


## Override: атака гиганта — СУПЕР-РЫВОК на башню, НЕ мгновенный AoE. STRIKE
## базового FSM (по достижении attack_range + windup-телеграф) запускает заряд:
## гигант бросается к башне на charge_speed и бьёт её на контакте (см.
## _check_charge_contact). Обычного melee/AoE-удара у гиганта больше нет.
func _perform_strike(_target: Node3D) -> void:
	var tower := _resolve_tower()
	if tower == null:
		return
	var dir := Vector3(tower.global_position.x - global_position.x, 0.0,
			tower.global_position.z - global_position.z)
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	_charging = true
	_charge_hit = false
	_dash_vec = dir * charge_speed
	_dash_remaining = charge_duration
	_dash_ghost_t = 0.0


## Override Skeleton._ai_step: сверху — общий dash (уворот/заряд) и скан угроз,
## иначе обычный FSM (approach → windup → strike→заряд через _perform_strike).
func _ai_step(delta: float) -> void:
	# Активный рывок (уворот ИЛИ заряд) перекрывает всю обычную AI.
	if _dash_remaining > 0.0:
		_dash_remaining -= delta
		velocity.x = _dash_vec.x
		velocity.z = _dash_vec.z
		if _charging:
			_check_charge_contact()
			if _dash_remaining <= 0.0:
				_charging = false
		return
	# Уворот от снарядов игрока. Single-target (Искра) промахивается, AoE и
	# супер-рывок башни ловят (их радиус/скорость перекрывают короткий уворот).
	_dodge_cd -= delta
	if _dodge_cd <= 0.0 and dodge_detect_radius > 0.0:
		var threat := _scan_threat()
		if threat != null:
			_start_evade(threat.global_position, _cached_target)
			_dodge_cd = dodge_cooldown
			return
	super._ai_step(delta)


## Контакт заряда с башней — один удар, затем гасим рывок.
func _check_charge_contact() -> void:
	if _charge_hit:
		return
	var tower := _resolve_tower()
	if tower == null:
		return
	var dx: float = tower.global_position.x - global_position.x
	var dz: float = tower.global_position.z - global_position.z
	if dx * dx + dz * dz <= charge_hit_range * charge_hit_range:
		_charge_hit = true
		Damageable.try_damage(tower, attack_damage, HitStop.HEAVY)
		_dash_remaining = minf(_dash_remaining, 0.06)


## Ближайший player_projectile в dodge_detect_radius (порт из EnemyMech._scan_threat).
func _scan_threat() -> Node3D:
	var here: Vector3 = global_position
	var best: Node3D = null
	var best_d_sq: float = dodge_detect_radius * dodge_detect_radius
	for n in get_tree().get_nodes_in_group(&"player_projectile"):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var dx: float = node.global_position.x - here.x
		var dz: float = node.global_position.z - here.z
		var d_sq: float = dx * dx + dz * dz
		if d_sq < best_d_sq:
			best_d_sq = d_sq
			best = node
	return best


## Рывок-уворот вбок от снаряда, прочь от башни (порт из EnemyMech._start_evade).
func _start_evade(threat_pos: Vector3, tower: Node3D) -> void:
	var away: Vector3 = global_position - threat_pos
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
	away = away.normalized()
	var perp: Vector3 = away.cross(Vector3.UP).normalized()
	if tower != null and is_instance_valid(tower):
		var to_tower: Vector3 = tower.global_position - global_position
		to_tower.y = 0.0
		if perp.dot(to_tower) > 0.0:
			perp = -perp  # не уклоняться под башню
	var dir: Vector3 = perp * 0.8 + away * 0.4
	if dir.length_squared() < 0.0001:
		dir = perp
	dir = dir.normalized()
	_charging = false
	_dash_vec = dir * dodge_dash_speed
	_dash_remaining = dodge_dash_duration
	_dash_ghost_t = 0.0


## Башня — постоянная цель гиганта. Из кэша FSM или из группы.
func _resolve_tower() -> Node3D:
	if _cached_target != null and is_instance_valid(_cached_target) \
			and _cached_target.is_in_group(Tower.GROUP):
		return _cached_target
	return get_tree().get_first_node_in_group(Tower.GROUP) as Node3D


## Dash-визуал (уворот И заряд) — after-image-трейл через общий DashFx (как у башни/меха).
func _process(delta: float) -> void:
	if _dash_remaining > 0.0 and _mesh != null:
		_dash_ghost_t -= delta
		if _dash_ghost_t <= 0.0:
			_dash_ghost_t = DashFx.GHOST_INTERVAL
			DashFx.spawn_ghost(get_tree().current_scene, _mesh, _dash_vec)
