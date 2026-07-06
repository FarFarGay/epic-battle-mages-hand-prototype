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

@export_group("Boss-бой (подача / стан-матадор / призыв)")
## Стан после ПРОМАХА заряда — «матадор-окно»: гигант оглушён и светится синим,
## стоячая цель = безопасный гарантированный удар. 0 = выключено.
## 1.5с: впритык на супер-рывок (hold 0.3 + прицел в слоумо) — окно ощущается
## наградой за уворот, а не бесплатной паузой (3.0 было «очень длинно», фидбек 2026-07-06).
@export var miss_stun_duration: float = 1.5
## Множитель входящего урона, пока гигант НЕ оглушён. 1.0 = гигант уязвим ВСЕГДА
## (фидбек 2026-07-06: стан — удобное окно, не единственное); 3 супер-рывка (250)
## = смерть при hp 750. Ручка на будущее: <1.0 вернёт «броню активного».
@export var active_damage_factor: float = 1.0
## Кого призывать на порогах HP 2/3 и 1/3 (пачка = эскалация + мана-топливо
## для супер-рывков игрока). null = призыв выключен.
@export var summon_scene: PackedScene
@export var summon_count: int = 6
## Урон призванных: комнатные «раздражатели», не убийцы (как room_skeleton_filler).
@export var summon_attack_damage: float = 3.0
## Рёв-подача аггрит комнату: вся мелочь в границах комнаты получает
## forced-цель = башня (бой плотный сразу, мана-фарм ВНУТРИ боя).
@export var roar_aggro_room: bool = true
## Фаза-эскалация на каждом пороге HP (вместе с призывом): гигант быстрее
## ходит и чаще заряжает — бой разгоняется к финалу. Кулдаун-мульт смягчён
## 0.75→0.85 (фидбек 2026-07-07 «дико спамит атаками»; база тоже 1.2→2.0 в tscn):
## заряды 2.0 → 1.7 → 1.45с по фазам.
@export var phase_speed_mult: float = 1.3
@export var phase_cooldown_mult: float = 0.85
## Шоквейв на финише заряда (попал ИЛИ промазал): мелочь в радиусе разлетается.
## 0 = выключено. Башню не трогает — она наказана самим контактом заряда.
@export var charge_shockwave_radius: float = 4.5
@export var charge_shockwave_impulse: float = 9.0
## Заряд ДАВИТ свою же мелочь по пути (симметрия: сила бьёт всех того же класса,
## фидбек 2026-07-07). Каждый скелет — один раз за заряд. 0 = выключено.
@export var charge_trample_damage: float = 60.0
@export var charge_trample_radius: float = 1.8
## Смерть = взрыв (зеркало предсмертного взрыва башни): бьёт НЕЖИТЬ в радиусе,
## башню/гномов не трогает. 0 = выключено.
@export var death_explosion_radius: float = 6.0
@export var death_explosion_damage: float = 120.0

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
## Скелеты, уже задавленные ТЕКУЩИМ зарядом (instance_id) — по разу за заряд.
var _trampled: Array = []
## Остаток стана-матадора (промах заряда). >0 → гигант стоит, урон полный.
var _stun_t: float = 0.0
## Рёв-подача сыгран (баннер/шейк на первый аггр башни). Один раз за жизнь.
var _roared: bool = false
## HP на спавне — для порогов призыва (2/3, 1/3).
var _hp_max: float = 0.0

## Shared-материал стана (синее свечение «окно открыто») — как _shared_giant_material.
static var _shared_stun_material: StandardMaterial3D


## Босс: HP БЕЗ per-spawn вариации базы (±20% ломала бы обещание «3 оглушённых
## супер-рывка = смерть»). Вариация замаха/скорости/кулдауна остаётся.
func _apply_stat_variance() -> void:
	var fixed_hp: float = hp
	super._apply_stat_variance()
	hp = fixed_hp


func _ready() -> void:
	super._ready()
	_hp_max = hp
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
	_trampled.clear()
	_dash_vec = dir * charge_speed
	_dash_remaining = charge_duration
	_dash_ghost_t = 0.0


## Override Skeleton._ai_step: сверху — стан-матадор и общий dash (уворот/заряд),
## иначе обычный FSM (approach → windup → strike→заряд через _perform_strike).
func _ai_step(delta: float) -> void:
	# Стан (промах заряда): стоим столбом, ничего не решаем — безопасное окно
	# для удара (и полный урон, если active_damage_factor < 1).
	if _stun_t > 0.0:
		_stun_t -= delta
		velocity.x = 0.0
		velocity.z = 0.0
		if _stun_t <= 0.0:
			_end_stun()
		return
	# Активный рывок (уворот ИЛИ заряд) перекрывает всю обычную AI.
	if _dash_remaining > 0.0:
		_dash_remaining -= delta
		velocity.x = _dash_vec.x
		velocity.z = _dash_vec.z
		if _charging:
			_check_charge_contact()
			_trample_skeletons()
			if _dash_remaining <= 0.0:
				_charging = false
				_charge_shockwave()
				if not _charge_hit and miss_stun_duration > 0.0:
					_begin_stun()
		return
	# Рёв-подача: первый раз, когда башня стала целью (вход в комнату) —
	# баннер BossWarningOverlay + шейк. Статус «это босс» без слов.
	if not _roared and _cached_target != null and is_instance_valid(_cached_target) \
			and _cached_target.is_in_group(Tower.GROUP):
		_roar_intro()
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


## Урон с ручкой active_damage_factor (1.0 = уязвим всегда; <1.0 — «броня
## активного», урон вне стана режется). Пороги 2/3 и 1/3 HP пересечены
## ударом → рёв-призыв пачки скелетов (угроза + мана-топливо игроку).
func take_damage(amount: float) -> void:
	if _stun_t <= 0.0:
		amount *= active_damage_factor
	var hp_before: float = hp
	super.take_damage(amount)
	if _dying or summon_scene == null or _hp_max <= 0.0:
		return
	for threshold: float in [_hp_max * 2.0 / 3.0, _hp_max / 3.0]:
		if hp_before > threshold and hp <= threshold:
			_summon_pack()
			_escalate_phase()


## Рёв-подача первого аггра: баннер «гигант» (BossWarningOverlay уже слушает
## boss_wave_incoming), камера-шейк, пыль+разряд у ног, аггр всей комнаты.
func _roar_intro() -> void:
	_roared = true
	EventBus.boss_wave_incoming.emit(3.0)
	EventBus.camera_shake.emit(0.7, global_position)
	var scene_root := get_tree().current_scene
	if scene_root != null:
		AoeVisual.spawn_dust(scene_root, global_position)
		AoeVisual.spawn_pulse_sparks(scene_root, global_position + Vector3.UP * 1.2, 2.5, 8.0)
	if roar_aggro_room:
		_aggro_room_skeletons()


## Мелочь комнаты бросается на башню: forced-цель (fallback зрения — своей
## жертвы у них нет, идут на башню; вблизи vision-скан работает как обычно).
## Границы = room-гейт гиганта; без гейта — радиус вокруг гиганта.
func _aggro_room_skeletons() -> void:
	var tower := _resolve_tower()
	if tower == null:
		return
	for n in get_tree().get_nodes_in_group(SKELETON_GROUP):
		var sk := n as Skeleton
		if sk == null or sk == self or sk is SkeletonGiant or not is_instance_valid(sk):
			continue
		var p: Vector3 = sk.global_position
		if room_size.x > 0.0 and room_size.y > 0.0:
			if absf(p.x - room_center.x) > room_size.x * 0.5 + 2.0 \
					or absf(p.z - room_center.y) > room_size.y * 0.5 + 2.0:
				continue
		elif p.distance_to(global_position) > NO_ROOM_AGGRO_RADIUS * 0.5:
			continue
		sk.set_forced_target(tower)


## Фаза-эскалация (каждый порог HP): быстрее ходит, чаще заряжает. Дважды за
## бой: base → ×1.3/×0.75 → ×1.69/×0.56 — финал самый горячий.
func _escalate_phase() -> void:
	move_speed *= phase_speed_mult
	attack_cooldown *= phase_cooldown_mult


## Заряд давит свою мелочь по пути: скелеты в trample-радиусе получают урон
## (по разу за заряд) + отброс. Гигант — таран для всех, не только для башни.
func _trample_skeletons() -> void:
	if charge_trample_damage <= 0.0:
		return
	var r_sq: float = charge_trample_radius * charge_trample_radius
	for n in get_tree().get_nodes_in_group(SKELETON_GROUP):
		var sk := n as Skeleton
		if sk == null or sk == self or sk is SkeletonGiant or not is_instance_valid(sk):
			continue
		var id: int = sk.get_instance_id()
		if id in _trampled:
			continue
		var to_sk: Vector3 = sk.global_position - global_position
		to_sk.y = 0.0
		if to_sk.length_squared() > r_sq:
			continue
		_trampled.append(id)
		sk.apply_knockback(_dash_vec.normalized() * 7.0 + Vector3.UP * 2.5, 0.22)
		Damageable.try_damage(sk, charge_trample_damage)


## Смерть гиганта = взрыв (зеркало предсмертного взрыва башни): испепеляет
## нежить в радиусе — финальный аккорд расчищает призванную мелочь. Башня и
## гномы не задеваются (итерация только по SKELETON_GROUP).
func _on_destroyed() -> void:
	super._on_destroyed()
	if death_explosion_radius <= 0.0:
		return
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	AoeVisual.spawn_explosion(scene_root, global_position, death_explosion_radius)
	EventBus.camera_shake.emit(0.6, global_position)
	var r_sq: float = death_explosion_radius * death_explosion_radius
	for n in get_tree().get_nodes_in_group(SKELETON_GROUP):
		var sk := n as Skeleton
		if sk == null or sk == self or sk is SkeletonGiant or not is_instance_valid(sk):
			continue
		var to_sk: Vector3 = sk.global_position - global_position
		to_sk.y = 0.0
		if to_sk.length_squared() > r_sq:
			continue
		var dir: Vector3 = to_sk.normalized() if to_sk.length_squared() > 0.0001 \
				else Vector3(randf() - 0.5, 0.0, randf() - 0.5).normalized()
		sk.apply_knockback(dir * 10.0 + Vector3.UP * 3.0, 0.25)
		Damageable.try_damage(sk, death_explosion_damage)


## Ударная волна на финише заряда: кольцо+пыль+шейк, мелочь в радиусе
## расшвыривает (свои же — гигант неаккуратен). Башню не трогает.
func _charge_shockwave() -> void:
	if charge_shockwave_radius <= 0.0:
		return
	var scene_root := get_tree().current_scene
	if scene_root != null:
		AoeVisual.spawn_expanding_ring(scene_root, global_position,
			charge_shockwave_radius, 0.25, Color(0.95, 0.6, 0.3, 0.9))
		AoeVisual.spawn_dust(scene_root, global_position)
	EventBus.camera_shake.emit(0.25, global_position)
	var r_sq: float = charge_shockwave_radius * charge_shockwave_radius
	for n in get_tree().get_nodes_in_group(SKELETON_GROUP):
		var sk := n as Skeleton
		if sk == null or sk == self or sk is SkeletonGiant or not is_instance_valid(sk):
			continue
		var to_sk: Vector3 = sk.global_position - global_position
		to_sk.y = 0.0
		if to_sk.length_squared() > r_sq:
			continue
		var dir: Vector3 = to_sk.normalized() if to_sk.length_squared() > 0.0001 \
				else Vector3(randf() - 0.5, 0.0, randf() - 0.5).normalized()
		sk.apply_knockback(dir * charge_shockwave_impulse + Vector3.UP * 2.0, 0.25)


## Матадор-окно: заряд промазал → гигант оглушён, светится синим, урон полный.
func _begin_stun() -> void:
	_stun_t = miss_stun_duration
	_ensure_stun_material()
	if _mesh:
		_mesh.material_override = _shared_stun_material
	EventBus.camera_shake.emit(0.35, global_position)
	var scene_root := get_tree().current_scene
	if scene_root != null:
		AoeVisual.spawn_dust(scene_root, global_position)


func _end_stun() -> void:
	_stun_t = 0.0
	if _mesh:
		_mesh.material_override = _shared_giant_material


static func _ensure_stun_material() -> void:
	if _shared_stun_material == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.38, 0.42, 0.5, 1.0)
		m.roughness = 0.85
		m.emission_enabled = true
		m.emission = Color(0.3, 0.62, 1.0, 1.0)
		m.emission_energy_multiplier = 2.2
		_shared_stun_material = m


## Пачка скелетов кольцом вокруг гиганта. Каждый труп = орб = мана — призыв
## одновременно эскалирует бой и заправляет супер-рывки игрока.
func _summon_pack() -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	EventBus.camera_shake.emit(0.5, global_position)
	AoeVisual.spawn_pulse_sparks(scene_root, global_position + Vector3.UP * 1.5, 3.0, 10.0)
	var n: int = maxi(summon_count, 1)
	for i in range(n):
		var inst := summon_scene.instantiate() as Node3D
		if inst == null:
			continue
		scene_root.add_child(inst)
		var ang: float = TAU * float(i) / float(n)
		var pos: Vector3 = global_position + Vector3(cos(ang), 0.0, sin(ang)) * 4.0
		pos.y = 1.0
		inst.global_position = pos
		if summon_attack_damage > 0.0:
			inst.set(&"attack_damage", summon_attack_damage)
		AoeVisual.spawn_dust(scene_root, pos)


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
