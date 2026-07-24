class_name ArcherSoldier
extends SoldierGnome
## Гном-лучник: член Squad'а, как и копейщик, но дальний бой. По дизайну
## лучник = «защитник в squad'е»: его можно поставить охранять лагерь или
## взять с собой как копейщика. Тот же управляемый юнит, только с богатой
## AI восприятия (унаследовано из удалённого DefenderGnome, этап 55):
##  - **Конус зрения** [vision_half_angle_deg] вокруг [_facing] до
##    [cone_vision_radius]м: видит цели впереди, фланги/тыл пропускает
##    кроме PROXIMITY_OVERRIDE_RADIUS-bypass'а (враг в упор).
##  - **Throttled scan** через PhysicsShapeQuery раз в
##    [TARGET_SCAN_INTERVAL]с — N лучников не сканируют каждый кадр.
##  - **Alarm-реакция** на EventBus.skeleton_attacked_camp: лучник
##    разворачивается на скелета, бьющего наш лагерь, даже если он за
##    спиной. Тревога держится [alarm_persist_sec]с.
##  - **Распределение огня**: цель, по которой уже стреляют N соседей,
##    «штрафуется» через [target_share_penalty] — близкая с 1 стрелком
##    может уступить более дальней свободной.
##
## Стационарная защита (2026-06-03): pursue cone-цели УБРАН. Раньше archer
## видел врага в cone_vision_radius (35м), бежал к нему пока не войдёт в
## attack_range (22.5м), потом стрелял. Игрок описал это как «как только
## враг в зоне базы — лучник СРАЗУ к нему, не по конусу». Теперь логика:
##   - враг в cone + attack_range → выстрел, archer стоит/patrol'ит на месте
##   - враг в cone, но дальше attack_range → archer игнорирует, продолжает
##     patrol/holding (cone сам подметает периметр движением)
##   - враг попадает в attack_range через patrol-движение или сам подойдя —
##     archer фиксирует и стреляет.
## DEFENDING_CAMP-patrol уже даёт cone-sweep по периметру; HOLDING — cone
## смотрит наружу от лагеря. Этого достаточно для point-defense.
##
## Прокачка точности — per-instance счётчик `_shots_fired`, теряется на
## смерти. Дизайн: «храни ветеранов».
##
## НОСИМОЕ ОРУЖИЕ (2026-07-12): любого живого лучника можно ВЗЯТЬ РУКОЙ
## (невидимая [UnitGrabHandle] при гноме) и поставить на крышу башни — он
## автострелятет на 360° (VS-режим, тот же боевой цикл, что у гарнизона).
## Слот на крыше ОДИН (заменяет экипаж-3 «В башню»): установленный лучник
## питает и арбалетные окна ([TowerUpgrades.crew_count]). Прокачка — XP за
## СВОИ убийства (kill-credit через Arrow.shooter_ref), уровень даёт
## +урон/+темп. XP личный и работает везде (стена/поле/крыша) — «храни
## ветеранов» теперь буквально: ветеран на крыше ценнее новичка.

@export_group("Archer combat")
## Скорость стрелы (м/с).
@export var arrow_speed: float = 22.0
## Откуда вылетает стрела относительно центра гнома (поднимаем над головой,
## чтобы не задеть собственный корпус коллизией стрелы при выстреле).
@export var arrow_spawn_offset: Vector3 = Vector3(0, 0.6, 0)
@export var arrow_scene: PackedScene
## Куда складывать спавн стрел (чтобы они пережили смерть/уход самого гнома).
## Пусто → fallback на current_scene.
@export_node_path("Node") var projectiles_root_path: NodePath
@export_group("")

## attack_range / attack_damage_min/max / attack_cooldown_min/max наследуются
## от SoldierGnome — у лучника просто другие значения (range=22.5 vs 2.2 у
## копейщика). Семантика поля «дистанция в которой бьём по цели» одна и та же,
## значения приходят из SOLDIER_CATALOG.stats через setup_soldier.

@export_group("Archer vision")
## Радиус конуса зрения. Лучник видит угрозы только впереди в этом радиусе
## и в этом конусе. Больше attack_range — позволяет «заметить» далёкого
## скелета и пойти к нему, но стрелять сможет только когда тот войдёт в
## attack_range.
@export var cone_vision_radius: float = 35.0
## Полу-угол конуса зрения в градусах. 45° = 90° FOV — лучник видит
## впереди, фланги пропускает. Конус направлен по [_facing] (направление
## движения / последняя цель / наружу от лагеря).
@export_range(15.0, 90.0) var vision_half_angle_deg: float = 45.0
## Штраф к «эффективной дистанции» цели за каждого уже-стреляющего по ней
## союзного лучника (для распределения огня). 0.5 = «цель в N метров с
## одним стрелком воспринимается как N×1.5 метра без стрелка». 0 = не
## распределять (все огонь на ближайшего). 1.0+ = почти строгое 1-к-1.
@export_range(0.0, 2.0) var target_share_penalty: float = 0.5
## Сколько секунд лучник держит alarm-цель после получения сигнала
## EventBus.skeleton_attacked_camp. Уменьшено с 5 → 1.5: при потоке волн
## (атак на лагерь много) alarm постоянно перезаписывался — лучник «вертелся»
## на каждого атакующего, конус не успевал работать. Короткая тревога даёт
## развернуться на ближайшую атаку и тут же вернуться к cone-обзору.
@export var alarm_persist_sec: float = 1.5

## Дистанционный фильтр alarm: не реагируем на скелетов, бьющих лагерь
## дальше этого радиуса от нас. Старая логика принимала любой alarm на наш
## лагерь — лучник на другой стороне периметра разворачивался к атаке за
## 40м, бесполезно (всё равно стрелять не сможет, attack_range=22.5м).
## Сейчас alarm бьёт только по «близким» атакам, остальные обрабатывают
## ближайшие к атаке лучники.
@export var alarm_max_distance: float = 25.0
@export_group("")

@export_group("Archer accuracy")
## Стартовый радиус разброса прицела (метры). Новички мажут, ветераны бьют
## точнее. Формула: inaccuracy = base / (1 + shots/half_shots).
@export var base_inaccuracy_radius: float = 0.4
@export var experience_half_shots: int = 100
@export_group("")

## Период между cone-сканами (с). Без throttle'а N лучников × 60fps дают
## кратно физ-query — на стресс-тесте это убивало fps. С 0.25с — 4 query/сек
## на лучника, кэш цели между сканами; немедленный re-scan на потере цели.
const TARGET_SCAN_INTERVAL: float = 0.25

## Радиус «личного пространства»: враги ближе этой дистанции игнорируют
## cone-фильтр и считаются видимыми независимо от [_facing]. Уменьшено
## с 4 → 1.8м — иначе в плотной свалке лучник видел вообще всё в радиусе
## 4м, конус читался как «нет конуса». Сейчас bypass работает только
## когда скелет вплотную (≈один шаг от лучника).
const PROXIMITY_OVERRIDE_RADIUS: float = 1.8

## Маска ENEMIES | COLD_ENEMY. Видим и активных скелетов, и LOD-холодных
## (при отзумленной камере). Литерал — `const` не может ссылаться на
## другой class const.
const TARGET_MASK: int = 16 | 128

## Группа-маркер «лучник стоит на крыше башни» — слот один; гейт занятости
## и экипаж арбалетных окон (TowerUpgrades) читают её.
const TOWER_WEAPON_GROUP := &"tower_archer_mounted"
## Позиция на крыше ОТНОСИТЕЛЬНО origin башни (крыша = +3 как у HarpoonModule;
## чуть в сторону от оси — не сливаться с турелью/грузом по центру).
const TOWER_MOUNT_OFFSET := Vector3(0.55, 3.0, 0.0)

## XP за убийство и пороги уровней — легаси-числа отрядного опыта
## (Camp.squad_xp_per_kill=10 и squad_level_xp_curve), теперь per-instance.
const XP_PER_KILL := 10
const XP_LEVEL_CURVE: Array[int] = [50, 120, 250, 500, 1000]
## Бонусы уровня: урон ×(1+0.15·lvl), кулдаун ×1/(1+0.12·lvl). Кривая на
## плейтест (юзер 2026-07-12: «простая ось темп+урон»).
const LEVEL_DAMAGE_BONUS := 0.15
const LEVEL_RATE_BONUS := 0.12

## Per-soldier счётчик выстрелов для расчёта точности. Теряется на смерть.
var _shots_fired: int = 0
var _projectiles_root: Node = null

## XP/уровень за убийства (kill-credit от своих стрел). Теряется на смерть.
var _xp: int = 0
var _level: int = 0

## Носимое оружие: нас несёт рука / стоим на крыше башни.
var _hand_carried: bool = false
var _weapon_mounted: bool = false
var _mount_tower: Node3D = null
var _grab_handle: UnitGrabHandle = null

## Материалы визуала + шест значков уровня (для подсветки руки и звёзд).
var _visual_mats: Array[StandardMaterial3D] = []
var _visual_holder: Node3D = null
var _badge_root: Node3D = null

## Текущее горизонтальное направление взгляда. Конус зрения считается
## относительно него. Обновляется на каждом тике: при движении → на цель/
## цель преследования/слот; стоя — outward от центра лагеря.
var _facing: Vector3 = Vector3.FORWARD
## Прекомпьют cos(vision_half_angle_deg) — на cone-чеке dot ≥ cos дешевле
## acos+сравнения. Считается в _ready, экспорт в рантайме не меняется.
var _vision_cone_cos: float = 0.5

## Кэш cone-цели между сканами. Между _resolve_target вызовами не
## пересканируем, пока кэш валиден (в радиусе + в конусе или закадровый).
var _cached_target: Node3D = null
var _target_scan_timer: float = 0.0

## Alarm-цель: скелет, ударивший наш лагерь. Override'ит cone (берётся
## даже если за спиной). Очищается лениво в [_resolve_alarm_target].
var _alarm_target: Node3D = null
var _alarm_until_msec: int = 0


func _ready() -> void:
	super._ready()
	if not projectiles_root_path.is_empty():
		_projectiles_root = get_node_or_null(projectiles_root_path)
	if _projectiles_root == null:
		_projectiles_root = get_tree().current_scene
	_vision_cone_cos = cos(deg_to_rad(vision_half_angle_deg))
	# Фазовый сдвиг — N лучников не сканируют в одном кадре.
	_target_scan_timer = randf() * TARGET_SCAN_INTERVAL
	# Реактивный alarm (по первому удару) и превентивный (по подходу к жертве).
	# Handler фильтрует victim — лучник реагирует только на атаки палаток
	# (CampPart), не на атаки гномов: за гномов отвечают они сами (FLEE
	# в лагерь, см. Gnome._on_skeleton_targeting_camp). Подписка на оба
	# сигнала с одним handler'ом — поведение одинаковое, отличается только
	# timing (targeting → ~1с раньше).
	EventBus.skeleton_attacked_camp.connect(_on_skeleton_attacked_camp)
	EventBus.skeleton_targeting_camp.connect(_on_skeleton_attacked_camp)
	# Ручка-захват живёт В СЦЕНЕ (не ребёнком) — deferred: на буте current_scene
	# ещё может собираться.
	call_deferred(&"_spawn_grab_handle")


func _spawn_grab_handle() -> void:
	if _grab_handle == null and is_inside_tree():
		_grab_handle = UnitGrabHandle.attach_to(self)


func _exit_tree() -> void:
	# Смерть/удаление: слот крыши освобождаем сразу, ручка не переживает юнита.
	if is_in_group(TOWER_WEAPON_GROUP):
		remove_from_group(TOWER_WEAPON_GROUP)
	if _grab_handle != null and is_instance_valid(_grab_handle):
		_grab_handle.queue_free()
		_grab_handle = null
	if EventBus.skeleton_attacked_camp.is_connected(_on_skeleton_attacked_camp):
		EventBus.skeleton_attacked_camp.disconnect(_on_skeleton_attacked_camp)
	if EventBus.skeleton_targeting_camp.is_connected(_on_skeleton_attacked_camp):
		EventBus.skeleton_targeting_camp.disconnect(_on_skeleton_attacked_camp)


## Override базового AI копейщика. Stand-and-shoot с cone-зрением + alarm.
## Приоритеты:
##   1. Strict-march HOLD: дойти до слота, по дороге combat-assist если враг
##      попал в attack_range (так же как pikeman lunge'ит проходящих скелетов).
##   2. Cone/alarm-цель в attack_range + cd готов → выстрел, velocity=0.
##   3. Нет цели в attack_range — squad-positioning (HOLD/ESCORT/DEFEND).
##      Pursuit вне attack_range НЕ делаем — archer point-defense, не бежит
##      на видимого, но далёкого врага (см. doc-блок класса выше).
func _active_tick(delta: float) -> void:
	if _attack_cd > 0.0:
		_attack_cd -= delta

	# «В башню» (hide_in_tower): прячемся ВНУТРЬ башни, как копейщики. ArcherSoldier
	# переопределяет _active_tick целиком, поэтому ветку пряток дублируем явно (иначе
	# лучник эскортит, но не заходит внутрь — см. SoldierGnome._active_tick).
	if _squad != null and _squad.state == Squad.State.ESCORTING_TOWER and _squad.hide_in_tower:
		_tick_hide_in_tower()
		return
	if _hidden_in_tower:
		_exit_hidden()  # сменили команду на бой/эскорт → выходим из башни

	# Strict-march: дойти до слота. Combat-assist по пути — стрельба в врага
	# в attack_range без остановки strict-марша (стоим стреляем, потом идём).
	if _squad != null and _has_squad_context() \
			and _squad.state == Squad.State.HOLDING_POSITION \
			and _squad.is_strict_move() \
			and not _strict_arrived_at_slot:
		if _try_fire_at_resolved_target(delta):
			return
		var goal_strict: Vector3 = _squad.target_for_member(self, _resolve_squad_center())
		var to_goal_strict := Vector3(goal_strict.x - global_position.x, 0.0, goal_strict.z - global_position.z)
		var dist_strict: float = to_goal_strict.length()
		if dist_strict > SQUAD_TARGET_ARRIVAL:
			_face_horizontal(to_goal_strict, dist_strict)
			_move_toward(to_goal_strict, dist_strict)
			return
		_strict_arrived_at_slot = true

	# Combat-приоритет: cone/alarm-цель в attack_range + cd готов → выстрел.
	if _try_fire_at_resolved_target(delta):
		return

	# ПКМ-пин «микромашинки» (данж-песочница): полёт по инерции на натянутом
	# поводке вместо позиционирования. Стрельба выше — поливает всю дугу.
	if _tick_swing(delta):
		if velocity.length_squared() > 0.01:
			_facing = Vector3(velocity.x, 0.0, velocity.z).normalized()
		return

	# Юз после отпускания ЛКМ (данж-песочница): докатываемся по инерции,
	# стрельба на юзе жива (ветка выстрела выше по приоритету).
	if _tick_coast(delta):
		if velocity.length_squared() > 0.01:
			_facing = Vector3(velocity.x, 0.0, velocity.z).normalized()
		return

	# Нет цели — squad-positioning (как у pikeman'а). Гейт по _has_squad_context
	# (camp ИЛИ escort_target=башня) — иначе в комнатах (без Camp) лучник не слушал
	# бы команды «Идти сюда»/«В башню».
	if _squad == null or not _has_squad_context():
		velocity = Vector3.ZERO
		_facing = _outward_facing()
		return
	if _squad.state == Squad.State.DEFENDING_CAMP:
		_tick_defend_patrol()
		# Patrol_tick двигает velocity — обновляем _facing на направление
		# движения, чтобы cone смотрел вперёд по обходу периметра.
		if velocity.length_squared() > 0.01:
			_facing = Vector3(velocity.x, 0.0, velocity.z).normalized()
		else:
			_facing = _outward_facing()
		return
	var goal: Vector3 = _squad.target_for_member(self, _resolve_squad_center())
	var to_goal_xz := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	var dist: float = to_goal_xz.length()
	if dist <= SQUAD_TARGET_ARRIVAL:
		# Дрифт на полном разгоне НЕ паркуется — проносится мимо слота и
		# рулит обратно в него: вокруг зажатой точки выходит орбита-«пятак».
		if drift_carries_through():
			_move_toward(to_goal_xz, maxf(dist, 0.1))
			return
		velocity = Vector3.ZERO
		rotation.x = 0.0
		_facing = _outward_facing()
		return
	_face_horizontal(to_goal_xz, dist)
	_move_toward(to_goal_xz, dist)


## True если есть resolved cone/alarm-цель в attack_range и cd готов —
## стреляет, ставит cd, возвращает true. Иначе false.
func _try_fire_at_resolved_target(delta: float) -> bool:
	if hauling:
		return false  # несёт командный груз — руки заняты, лук за спиной
	if _attack_cd > 0.0:
		return false
	var target: Node3D = _resolve_target(delta)
	if target == null:
		return false
	var to_t := Vector3(
		target.global_position.x - global_position.x,
		0.0,
		target.global_position.z - global_position.z,
	)
	var dist: float = to_t.length()
	if dist > attack_range:
		return false
	# Face target + fire. _facing синхронизируется с look_at — cone в
	# следующем скане будет ориентирован на цель.
	_face_horizontal(to_t, dist)
	# Дрифт-эксперимент (steer_inertia > 0, данж-песочница): выстрел НЕ
	# останавливает — лучник стреляет на ходу, кружа вокруг цели, и не
	# теряет разгон. Штатный режим — стоп-кадр на выстреле, как всегда.
	if steer_inertia <= 0.0:
		velocity = Vector3.ZERO
	_fire_at(target)
	# Уровень ускоряет темп: cd масштабируется cooldown_scale (см. XP-блок).
	_attack_cd = randf_range(attack_cooldown_min, attack_cooldown_max) * cooldown_scale()
	return true


## Helper: ставит _facing на горизонтальный unit-vector направления и
## визуально поворачивает тело через look_at. dist — длина to (вызывающий
## уже посчитал, не делаем повторного sqrt). Защита от нулевого вектора.
func _face_horizontal(to_xz: Vector3, dist: float) -> void:
	if dist <= 0.001:
		return
	var dir: Vector3 = to_xz / dist
	_facing = dir
	look_at(global_position + dir, Vector3.UP)


## Дефолтное направление взгляда: наружу от центра лагеря. Используется
## когда нет цели и нет движения — лучник смотрит на горизонт спиной к
## костру. Если лагеря нет (orphan / dev-сцена) — старое _facing.
func _outward_facing() -> Vector3:
	if _camp == null:
		return _facing
	var anchor: Vector3 = _camp.deploy_anchor
	var out: Vector3 = global_position - anchor
	out.y = 0.0
	if out.length_squared() < 0.0001:
		return _facing
	return out.normalized()


# --- Восприятие: cone + alarm + throttled scan ---


## Резолв текущей цели. Alarm имеет приоритет (override конуса) — это
## «магический» канал координации. Иначе — cone-скан с throttle'ом
## TARGET_SCAN_INTERVAL и кэшем _cached_target.
##
## Freed-safety: между физтиками _cached_target мог быть freed (скелет
## умер). Жёстко обнуляем через is_instance_valid в начале — далее
## работаем только с (null|живой).
func _resolve_target(delta: float) -> Node3D:
	_target_scan_timer -= delta
	if not is_instance_valid(_cached_target):
		_cached_target = null
	var had_prev: bool = _cached_target != null

	var alarm: Node3D = _resolve_alarm_target()
	if alarm != null:
		_cached_target = alarm
		# Сброс throttle: при потере alarm'а сразу пересканируем cone.
		_target_scan_timer = 0.0
		return _cached_target

	# Cheap-валидация cone-цели: вышла из радиуса/конуса — инвалидируем
	# не дожидаясь throttle'а. Proximity-bypass: цель ближе
	# PROXIMITY_OVERRIDE_RADIUS остаётся актуальной даже вне конуса.
	var stale: bool = false
	if _cached_target != null:
		var cached_dist: float = global_position.distance_to(_cached_target.global_position)
		if cached_dist > cone_vision_radius:
			stale = true
		elif steer_inertia > 0.0 and cached_dist <= attack_range:
			# Дрифт-эксперимент: ЗАХВАТ цели. Зацепил конусом по курсу —
			# держишь на 360°, пока в attack_range (кружить вокруг врага,
			# поливая его). Вне дальности — обычные cone-правила.
			pass
		elif cached_dist > PROXIMITY_OVERRIDE_RADIUS and not _is_in_cone(_cached_target.global_position):
			stale = true
	if stale:
		_cached_target = null
	# Скан раз в TARGET_SCAN_INTERVAL + немедленный пересмотр когда цель
	# только что инвалидировалась (prev был — теперь нет).
	if _target_scan_timer <= 0.0 or (had_prev and _cached_target == null):
		_cached_target = _scan_cone()
		_target_scan_timer = TARGET_SCAN_INTERVAL
	return _cached_target


## Возвращает alarm-цель если она ещё валидна и не протух таймер. null —
## «тревоги нет», работаем по cone-скану. Очистка ленивая — таймер не
## тикается отдельно вне комбата.
func _resolve_alarm_target() -> Node3D:
	if _alarm_target == null:
		return null
	if not is_instance_valid(_alarm_target):
		_alarm_target = null
		return null
	if Time.get_ticks_msec() > _alarm_until_msec:
		_alarm_target = null
		return null
	return _alarm_target


## Cone-скан: PhysicsShapeQuery со сферой cone_vision_radius (broadphase),
## потом фильтр по углу относительно _facing. Возвращает «лучшую» цель в
## конусе с учётом распределения огня — цель, по которой уже стреляет N
## союзных лучников, штрафуется множителем target_share_penalty × N. Это
## раскидывает огонь между видимыми скелетами вместо «все на одного».
func _scan_cone() -> Node3D:
	var space := get_world_3d().direct_space_state
	if space == null:
		return null
	var shape := SphereShape3D.new()
	shape.radius = cone_vision_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), global_position)
	query.collision_mask = TARGET_MASK
	query.collide_with_bodies = true
	var results := space.intersect_shape(query, 32)
	var best: Node3D = null
	var best_score: float = INF
	for r in results:
		var collider = r.collider
		if collider == null or not (collider is Node3D):
			continue
		if not Damageable.is_damageable(collider):
			continue
		var node := collider as Node3D
		var d: float = global_position.distance_to(node.global_position)
		# Godot 4.6 подмешивает broadphase AABB вне sphere — явный radius.
		if d > cone_vision_radius:
			continue
		# Cone-фильтр с PROXIMITY_OVERRIDE_RADIUS-bypass'ом.
		if d > PROXIMITY_OVERRIDE_RADIUS and not _is_in_cone(node.global_position):
			continue
		# Score = dist × (1 + aimers × penalty). Penalty=0 → чистая
		# дистанция. Penalty=0.5 → каждый уже-стрелок делает цель «дальше»
		# на 50%: близкая цель с 1 стрелком сравнится с целью в 1.5× дальше
		# без стрелков.
		var aimers: int = _count_aimers_on(node)
		var score: float = d * (1.0 + float(aimers) * target_share_penalty)
		if score < best_score:
			best_score = score
			best = node
	return best


## Сколько ДРУГИХ ArcherSoldier из SOLDIER_GROUP уже целят в указанную цель.
## Дёшево: N лучников × ~5 кандидатов × 4 скана/сек = ~20×N итераций/сек.
##
## Freed-safety: чужой _cached_target читаем через is_instance_valid — между
## его и нашим сканом он мог умереть.
func _count_aimers_on(target: Node3D) -> int:
	var count: int = 0
	for s in get_tree().get_nodes_in_group(SoldierGnome.SOLDIER_GROUP):
		if s == self or not is_instance_valid(s):
			continue
		var archer := s as ArcherSoldier
		if archer == null:
			continue
		var their_target: Node3D = archer._cached_target
		if not is_instance_valid(their_target):
			continue
		if their_target == target:
			count += 1
	return count


## Точка в конусе зрения? Сравниваем угол между _facing и направлением на
## цель с прекомпьютнутым cos(half-angle). Y-компонента игнорируется —
## конус только горизонтальный (стрельба в небо/в пол не нужна).
func _is_in_cone(target_pos: Vector3) -> bool:
	var to: Vector3 = target_pos - global_position
	to.y = 0.0
	var dist_sq: float = to.length_squared()
	if dist_sq < 0.0001:
		return true
	var dir: Vector3 = to / sqrt(dist_sq)
	return dir.dot(_facing) >= _vision_cone_cos


## Хендлер EventBus.skeleton_attacked_camp. Скелет attacker только что
## ударил victim (CampPart или мирный гном). Триггерим тревогу только если
## victim — из НАШЕГО лагеря, иначе на сцене с двумя Camp'ами все archers
## реагировали бы на любой инцидент.
##
## Идемпотентность: повторный удар того же скелета продлевает
## _alarm_until_msec — тревога не «дёргается».
func _on_skeleton_attacked_camp(attacker: Node3D, victim: Node3D, _position: Vector3) -> void:
	if _camp == null or attacker == null or victim == null:
		return
	if not is_instance_valid(attacker) or not is_instance_valid(victim):
		return
	# Фильтр «наш лагерь + это CampPart»: алярм лучника = «по палатке бьют».
	# Атаки на гномов archer'а НЕ интересуют — гном сам убежит в лагерь
	# (см. Gnome._on_skeleton_targeting_camp). Защищать гномов точечными
	# выстрелами малопродуктивно: они мелкие, разбросаны, перекрывают друг
	# друга — лучше дать им сбежать в зону archer'ов, где общий cone-обзор
	# уже работает.
	var ours: bool = false
	if victim is CampPart:
		ours = victim.get_parent() == _camp
	if not ours:
		return
	# Дистанционный фильтр: если атакующий далеко от нас, alarm не наш —
	# пусть реагируют ближайшие к атаке лучники. Иначе все archers по карте
	# разворачиваются на каждый удар (Skeleton постоянно тыкает лагерь).
	var dx: float = attacker.global_position.x - global_position.x
	var dz: float = attacker.global_position.z - global_position.z
	if dx * dx + dz * dz > alarm_max_distance * alarm_max_distance:
		return
	_alarm_target = attacker
	_alarm_until_msec = Time.get_ticks_msec() + int(alarm_persist_sec * 1000.0)


# --- Точность / стрельба ---


## Текущий радиус разброса с учётом опыта. Логарифмическая кривая.
func current_inaccuracy_radius() -> float:
	if base_inaccuracy_radius <= 0.0 or experience_half_shots <= 0:
		return base_inaccuracy_radius
	return base_inaccuracy_radius / (1.0 + float(_shots_fired) / float(experience_half_shots))


func get_shots_fired() -> int:
	return _shots_fired


## Публичный API для squad-ult'ы (volley): спавнит стрелу с прицелом на
## точку. Без inaccuracy-разброса (волей задаёт собственный scatter через
## разные aim_pos для каждой стрелы). Squad-charge НЕ добавляется (это
## расход charge'а, не накопление).
func volley_fire_at(aim_pos: Vector3, dmg: float) -> void:
	if arrow_scene == null:
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		return
	if not is_instance_valid(_projectiles_root):
		_projectiles_root = get_tree().current_scene
	_projectiles_root.add_child(arrow)
	arrow.damage = dmg
	arrow.speed = arrow_speed
	arrow.shooter_ref = weakref(self)  # kill-credit → XP (см. credit_kill)
	arrow.setup(global_position + arrow_spawn_offset, aim_pos)


## Спавнит стрелу с разбросом по uniform-в-круге. Опыт +1 на каждый выстрел.
## Squad-charge +1 за выстрел (вместо per-kill как у pikeman'а — у лучника
## kill-credit'а нет, Arrow не знает стрелка).
func _fire_at(target: Node3D) -> void:
	if arrow_scene == null:
		push_warning("[ArcherSoldier:%s] arrow_scene не задан" % name)
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		push_warning("[ArcherSoldier:%s] arrow_scene не инстанцируется как Arrow" % name)
		return
	if not is_instance_valid(_projectiles_root):
		_projectiles_root = get_tree().current_scene
	_projectiles_root.add_child(arrow)
	var damage: float = randf_range(attack_damage_min, attack_damage_max) * damage_multiplier()
	var spawn := global_position + arrow_spawn_offset
	var inaccuracy: float = current_inaccuracy_radius()
	var aim_pos: Vector3 = target.global_position
	if inaccuracy > 0.0:
		var angle: float = randf() * TAU
		var r: float = sqrt(randf()) * inaccuracy
		aim_pos.x += cos(angle) * r
		aim_pos.z += sin(angle) * r
	arrow.damage = damage
	arrow.speed = arrow_speed
	arrow.shooter_ref = weakref(self)  # kill-credit → XP (см. credit_kill)
	arrow.setup(spawn, aim_pos)
	_shots_fired += 1
	if _squad != null:
		_squad.add_charge(1.0)
	if debug_log and LogConfig.master_enabled:
		print("[ArcherSoldier:%s] выстрел в %s (dmg=%.1f, shots=%d)" % [name, target.name, damage, _shots_fired])


# --- Новая модель лучника (Фаза A): коробочный лучник вместо капсулы. Перекрашивает
# ВСЕХ ArcherSoldier (наёмных и из казармы) — единый вид. Капсулу прячем (поза/флеш
# анимируют её невидимо — безвредно), модель строим от ног со сдвигом под центр капсулы.
var _archer_skinned := false


func _apply_visual() -> void:
	if _archer_skinned:
		return
	_archer_skinned = true
	if _mesh != null:
		_mesh.visible = false
	var holder := Node3D.new()
	holder.position = Vector3(0, -0.4, 0)  # капсула центрирована в origin — опускаем «ноги»
	add_child(holder)
	_visual_holder = holder
	var cloth := _arch_mat(Color(0.28, 0.46, 0.7))  # синий — лучники
	var skin := _arch_mat(Color(0.85, 0.7, 0.55))
	var wood := _arch_mat(Color(0.3, 0.2, 0.12))
	# Типизированная локальная вместо литерала-присваивания (см. SPEC §7.3 #4).
	var mats: Array[StandardMaterial3D] = []
	mats.append(cloth)
	mats.append(skin)
	mats.append(wood)
	_visual_mats = mats
	_arch_box(holder, Vector3(0.34, 0.5, 0.26), Vector3(0, 0.45, 0), cloth)   # тело
	_arch_box(holder, Vector3(0.26, 0.26, 0.24), Vector3(0, 0.82, 0), skin)   # голова
	_arch_box(holder, Vector3(0.06, 0.62, 0.06), Vector3(0.22, 0.55, 0), wood)  # лук
	if _level > 0:
		_refresh_level_badges()


## Контракт подсветки руки (транслирует UnitGrabHandle): любой grab'аемый
## объект подсвечивается при наведении — [[feedback_grabbable_highlight]].
func set_highlighted(value: bool) -> void:
	for m in _visual_mats:
		if m == null:
			continue
		m.emission_enabled = true
		m.emission = Color(1.0, 0.95, 0.4)
		m.emission_energy_multiplier = 0.9 if value else 0.0


func _arch_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m


func _arch_box(parent: Node3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


# --- ГАРНИЗОН СТЕН (барачные лучники) ---------------------------------------------
# Барачный лучник — НАСТОЯЩИЙ член отряда (карточка/hp/смерть/точность/команды даром).
# Доп. режим: пока отряд в МЯГКОМ hold (дефолт казармы и возврат по F) и есть назначение
# от казармы — лучник ходит по БОЕВОМУ ХОДУ (логика бывшего PadArcher, дословно):
# башенный стоит на башне, патрульные пинг-понгом по рукаву-стене, тянешь стену → идёт
# дальше. Координаты маршрута АБСОЛЮТНЫЕ → ставим global_position напрямую, минуя навмеш/
# гравитацию (стены вне навмеша). «За башней» (escort) = снять и вести; F-возврат (мягкий
# hold) = обратно на стены. Бой — тот же _try_fire_at_resolved_target (конус/точность/стрела).
const GARRISON_REPATH := 0.6  # пересчёт маршрута (стены меняются на ходу)
## Горизонтальный радиус «вошёл на пост»: пока дальше — лучник идёт по ЗЕМЛЕ к
## основанию башни/стены (Y держим на земле), внутри — поднимается вертикально на
## высоту поста. Две фазы вместо диагонального всплытия («заходит, потом встаёт»).
const GARRISON_ASCENT_RADIUS := 1.4
## Скорость возврата на стену (м/с): пока лучник дальше [GARRISON_ASCENT_RADIUS] от
## точки поста — бежит этой скоростью (быстрее обычного шага, «не ползёт обратно»);
## вблизи поста переходит на move_speed (спокойный патруль по боевому ходу).
## Радиус наземного кольца вокруг центрального замка: куда отступают гарнизонные лучники,
## когда их КАЗАРМА снесена (опоры нет → падают и бегут оборонять замок). Угол на кольце
## стабилен по instance_id — три лучника не сваливаются в одну точку.
const CASTLE_GARRISON_RADIUS := 5.0

@export var wall_return_speed: float = 6.0  # бег к посту (см. GARRISON_ASCENT_RADIUS)
var _grn_assigned: bool = false       # казарма назначила пост
var _grn_home_cell: Vector2i = Vector2i.ZERO  # мировая клетка угла казармы
var _grn_branch: Vector2i = Vector2i.ZERO     # направление рукава (ZERO = башенный)
var _grn_tower: Vector3 = Vector3.ZERO        # пост на верху башни (абсолютный)
var _grn_ground_y: float = 0.0        # уровень земли у казармы (спуск при снятии)
var _grn_route: Array = []            # Array[Vector3] точки боевого хода (абсолютные)
var _grn_i: int = 0
var _grn_dir: int = 1
var _grn_t: float = 0.0
var _grn_active: bool = false         # сейчас на стене/идём по ней (для плавного спуска)
var _grn_walk: Dictionary = {}        # кэш walkable-клеток (опора под ногами) — снимок на recompute
var _grn_falling: bool = false        # опору снесли под ногами → отвесно падаем на землю (one-shot)


## Казарма назначает пост: home_cell — угол казармы, branch — рукав (ZERO=башня),
## tower_pos — верх башни (абсолют), ground_y — земля у казармы (куда спускаемся).
func assign_garrison(home_cell: Vector2i, branch: Vector2i, tower_pos: Vector3, ground_y: float) -> void:
	_grn_assigned = true
	_grn_home_cell = home_cell
	_grn_branch = branch
	_grn_tower = tower_pos
	_grn_ground_y = ground_y
	_grn_recompute()


## Гарнизонить сейчас? Назначен казармой + отряд в МЯГКОМ hold (не strict «Идти сюда»,
## не escort, не defend). escort = веду за башней; strict-hold = точечный приказ — оба
## уводят со стен.
func _grn_should_garrison() -> bool:
	return _grn_assigned and _squad != null \
		and _squad.state == Squad.State.HOLDING_POSITION and not _squad.is_strict_move()


func _physics_process(delta: float) -> void:
	# Носимое оружие — приоритет над всем (squad-команды/гарнизон не трогают
	# несомого и установленного лучника; позицией владеет рука/башня).
	if _hand_carried:
		velocity = Vector3.ZERO
		return
	if _weapon_mounted:
		_weapon_tick(delta)
		return
	if _grn_should_garrison():
		_grn_active = true
		_garrison_move(delta)
		return
	# Не гарнизоним (escort/strict-hold/defend). Если только что сошли со стены —
	# плавно спускаемся к земле ПРЯМЫМ управлением (без физики, не зависаем в воздухе),
	# и лишь на земле передаём ход штатной физике (навмеш-эскорт и т.п.).
	if _grn_active:
		if global_position.y > _grn_ground_y + 0.15:
			global_position.y = lerp(global_position.y, _grn_ground_y, 1.0 - exp(-10.0 * delta))
			velocity = Vector3.ZERO
			return
		_grn_active = false
	super._physics_process(delta)


## Движение по боевому ходу (бывший PadArcher._process). Абсолютные координаты, прямой
## global_position. Стреляем тем же путём, что отряд; ориентируем конус на ближайшего врага.
func _garrison_move(delta: float) -> void:
	# Прятались в башне? Выходим (иначе остаёмся visible=false на посту — «закис в башне»).
	_exit_hidden()
	velocity = Vector3.ZERO
	if _attack_cd > 0.0:
		_attack_cd -= delta
	# Ориентируем конус на ближайшего врага → штатный fire-путь (точность/стрела/cd).
	var foe: Node3D = _grn_nearest_enemy()
	if foe != null:
		var tf := Vector3(foe.global_position.x - global_position.x, 0.0, foe.global_position.z - global_position.z)
		_face_horizontal(tf, tf.length())
		if _try_fire_at_resolved_target(delta):
			return  # стоим стреляем
	# Патруль боевого хода.
	_grn_t -= delta
	if _grn_t <= 0.0:
		_grn_t = GARRISON_REPATH
		_grn_recompute()
	if _grn_route.is_empty():
		return
	var n: int = _grn_route.size()
	_grn_i = clampi(_grn_i, 0, n - 1)
	var target: Vector3 = _grn_route[_grn_i]
	# Опору снесли под ногами (флаг из garrison_world_changed) → отвесно роняем на землю,
	# горизонталь замираем. Приземлился — сброс флага, дальше штатный путь к новому посту.
	if _grn_falling:
		global_position.y = lerp(global_position.y, _grn_ground_y, 1.0 - exp(-12.0 * delta))
		if global_position.y <= _grn_ground_y + 0.2:
			global_position.y = _grn_ground_y
			_grn_falling = false
		return
	var flat := Vector3(target.x - global_position.x, 0.0, target.z - global_position.z)
	var flat_dist: float = flat.length()
	if flat_dist <= 0.12:
		if n > 1:
			_grn_i += _grn_dir
			if _grn_i >= n:
				_grn_i = n - 2
				_grn_dir = -1
			elif _grn_i < 0:
				_grn_i = 1
				_grn_dir = 1
			_grn_i = clampi(_grn_i, 0, n - 1)
	else:
		var dir := flat / flat_dist
		# Возврат к посту: ниже высоты поста (с земли/подъём) — быстрый wall_return_speed
		# («не ползём»); на боевом ходу (Y ≈ поста) — ровный move_speed (без рывков).
		var climbing: bool = global_position.y < target.y - 0.3
		var speed: float = wall_return_speed if climbing else move_speed
		global_position += dir * speed * delta
		if foe == null:
			_face_horizontal(dir, 1.0)
	# Высота — две фазы: ДАЛЕКО по XZ держим текущий уровень (идём к основанию, не всплываем
	# диагональю); у основания (≤ GARRISON_ASCENT_RADIUS) встаём на высоту поста.
	if flat_dist <= GARRISON_ASCENT_RADIUS:
		global_position.y = lerp(global_position.y, target.y, 1.0 - exp(-8.0 * delta))


## Маршрут поста: башенный (branch ZERO) → одна точка на башне; патрульный → ветка стены
## от казармы (если стен нет — топчемся у казармы). Бывший PadArcher._recompute.
func _grn_recompute() -> void:
	var tree := get_tree()
	if tree == null:
		return
	# Казарма снесена → отступаем гарнизонить ЦЕНТРАЛЬНЫЙ замок. Опоры нет (_grn_walk пуст):
	# лучник падает с поста и бежит по земле к наземному кольцу вокруг замка.
	if not _grn_barracks_alive(tree):
		_grn_walk = {}
		_grn_route = [_grn_castle_post(tree)]
		return
	# Казарма цела — кэш walkable-клеток для детекта падения (опора под ногами).
	_grn_walk = PadBuilding.walkable_set(tree)
	if _grn_branch == Vector2i.ZERO:
		_grn_route = [_grn_tower]
		return
	var r: Array = PadBuilding.wall_route(tree, _grn_home_cell + _grn_branch, _grn_branch)
	if r.is_empty():
		r = [PadBuilding.cell_top(_grn_home_cell, tree)]
	# Одна клетка-плечо (стена ещё не пристроена) → патруль ВНУТРИ плеча вдоль его оси,
	# чтобы лучник ходил по плечу, а не стоял. С пристроенной стеной точек уже >1.
	if r.size() == 1:
		var here: Vector3 = r[0]
		var ahead: Vector3 = PadBuilding.cell_top(_grn_home_cell + _grn_branch + _grn_branch, tree)
		var wdir := Vector3(ahead.x - here.x, 0.0, ahead.z - here.z)
		if wdir.length() > 0.01:
			wdir = wdir.normalized()
			var half: float = CityGrid.CELL * 0.32
			r = [here - wdir * half, here + wdir * half]
	_grn_route = r


## Жив ли ДОМ этого лучника — казарма, накрывающая [_grn_home_cell]. Снос казармы (ПКМ →
## queue_free) убирает её из группы → возвращаем false → гарнизон отступает к замку.
func _grn_barracks_alive(tree: SceneTree) -> bool:
	for b in tree.get_nodes_in_group(PadBuilding.GROUP):
		if not is_instance_valid(b) or b.is_queued_for_deletion():
			continue
		if not (b.has_method(&"is_barracks") and b.call(&"is_barracks")):
			continue
		if not b.has_method(&"occupied_cells"):
			continue
		for c in b.call(&"occupied_cells"):
			if (c as Vector2i) == _grn_home_cell:
				return true
	return false


## Наземная точка на кольце вокруг центрального замка (group "tower") — пост отступления
## при снесённой казарме. Угол стабилен по instance_id: 3 лучника не сходятся в одну точку.
func _grn_castle_post(tree: SceneTree) -> Vector3:
	var center := Vector3.ZERO
	var castle := tree.get_first_node_in_group(Tower.GROUP)
	if castle != null and castle is Node3D:
		center = (castle as Node3D).global_position
	var ang: float = float(get_instance_id() % 628) * 0.01
	var post := center + Vector3(cos(ang), 0.0, sin(ang)) * CASTLE_GARRISON_RADIUS
	post.y = _grn_ground_y
	return post


## Broad-phase «структура города изменилась» (стройка/снос → PadBuilding.refresh_walls).
## Форсим немедленный пересчёт поста: лучник тут же падает со снесённой опоры / лезет на
## достроенную стену, не дожидаясь GARRISON_REPATH-тика.
func garrison_world_changed() -> void:
	if not _grn_assigned:
		return
	_grn_recompute()
	# Если стояли наверху, а под ногами клетка больше НЕ walkable (стену/казарму снесли) —
	# роняем на землю one-shot'ом. Не поллим каждый кадр: иначе мерцание клетки на патруле/
	# подъёме морозит лучника в воздухе (был баг с зависанием на казарме).
	if global_position.y > _grn_ground_y + 0.3:
		var cell := CityGrid.world_to_cell(global_position, get_tree())
		if not _grn_walk.has(cell):
			_grn_falling = true


# --- НОСИМОЕ ОРУЖИЕ: рука несёт лучника / лучник стоит на крыше башни -------------
# Контракт UnitGrabHandle (см. unit_grab_handle.gd). Крыша = VS-автострельба:
# тот же цикл, что у гарнизона (360° ближайший враг → ориентация конуса →
# штатный _try_fire_at_resolved_target: точность/стрела/cd/XP — всё общее).


## Можно ли сейчас хватать рукой: жив, не спрятан в башню (невидимого не хватаем).
func is_carry_available() -> bool:
	return not _hidden_in_tower and visible


## Рука подняла: AI замирает, скелеты нас не целят (мы в воздухе), гарнизонный
## спуск (_grn_active) гасим — иначе после дропа в другом месте лучник «плыл» бы
## к старому ground_y.
func begin_hand_carry() -> void:
	if _weapon_mounted:
		_dismount_from_tower()
	_exit_hidden()
	_hand_carried = true
	_grn_active = false
	velocity = Vector3.ZERO
	if is_in_group(SKELETON_TARGET_GROUP):
		remove_from_group(SKELETON_TARGET_GROUP)


## Пока несут — висим под ручкой (позицию ведёт UnitGrabHandle каждый физкадр).
func carry_follow(pos: Vector3) -> void:
	global_position = pos


## Отпустили в мир: оживаем на месте (гравитация штатной физики сама уронит).
func end_hand_carry() -> void:
	_hand_carried = false
	if not is_in_group(SKELETON_TARGET_GROUP):
		add_to_group(SKELETON_TARGET_GROUP)


## Отпустили над башней: занять слот крыши. Слот ОДИН — занят другим лучником →
## false (ручка вернёт юнита в мир обычным дропом). Вне целей скелетов, как
## бывший экипаж «В башню» (melee всё равно не достаёт до крыши).
func try_mount_on_tower(tower: Node3D) -> bool:
	for other in get_tree().get_nodes_in_group(TOWER_WEAPON_GROUP):
		if other != self and is_instance_valid(other) and not other.is_queued_for_deletion():
			EventBus.tutorial_hint.emit("⚠ На башне уже стоит лучник — сними его рукой", 4.0)
			return false
	_hand_carried = false
	_weapon_mounted = true
	_mount_tower = tower
	add_to_group(TOWER_WEAPON_GROUP)
	global_position = tower.global_position + TOWER_MOUNT_OFFSET
	AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position, 0.9, 8.0)
	EventBus.tutorial_hint.emit("🏹 Лучник встал на башню — стреляет сам; арбалетные окна ожили", 4.0)
	if debug_log and LogConfig.master_enabled:
		print("[ArcherSoldier:%s] смонтирован на башню (lvl=%d)" % [name, _level])
	return true


## Снятие с крыши (рука схватила / башня погибла).
func _dismount_from_tower() -> void:
	_weapon_mounted = false
	_mount_tower = null
	if is_in_group(TOWER_WEAPON_GROUP):
		remove_from_group(TOWER_WEAPON_GROUP)


func is_tower_weapon() -> bool:
	return _weapon_mounted


## VS-тик на крыше: пин к башне (едем на корпусе, как груз MountSlot) + боевой
## цикл гарнизона (360°-ближайший → конус → штатный выстрел).
func _weapon_tick(delta: float) -> void:
	if _mount_tower == null or not is_instance_valid(_mount_tower):
		# Башня погибла под нами — слезаем, дальше штатная жизнь (падение/отряд).
		_dismount_from_tower()
		if not is_in_group(SKELETON_TARGET_GROUP):
			add_to_group(SKELETON_TARGET_GROUP)
		return
	global_position = _mount_tower.global_position + TOWER_MOUNT_OFFSET
	velocity = Vector3.ZERO
	if _attack_cd > 0.0:
		_attack_cd -= delta
	var foe: Node3D = _grn_nearest_enemy()
	if foe != null:
		var tf := Vector3(foe.global_position.x - global_position.x, 0.0, foe.global_position.z - global_position.z)
		_face_horizontal(tf, tf.length())
		_try_fire_at_resolved_target(delta)


# --- XP за убийства → уровни → +урон/+темп ----------------------------------------


## Kill-credit от своей стрелы (Arrow.shooter_ref). Работает везде: поле, стена,
## крыша башни, залп арбалетных окон (болт приписан лучнику на крыше).
func credit_kill() -> void:
	_xp += XP_PER_KILL
	while _level < XP_LEVEL_CURVE.size() and _xp >= XP_LEVEL_CURVE[_level]:
		_level += 1
		_on_level_up()


func get_level() -> int:
	return _level


## Множитель урона стрелы от уровня.
func damage_multiplier() -> float:
	return 1.0 + LEVEL_DAMAGE_BONUS * float(_level)


## Множитель кулдауна от уровня (меньше = чаще стреляет).
func cooldown_scale() -> float:
	return 1.0 / (1.0 + LEVEL_RATE_BONUS * float(_level))


func _on_level_up() -> void:
	_refresh_level_badges()
	AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position, 0.7, 6.0)
	EventBus.tutorial_hint.emit("🏹 Лучник — уровень %d: урон и темп выросли" % _level, 3.0)
	if debug_log and LogConfig.master_enabled:
		print("[ArcherSoldier:%s] уровень %d (xp=%d)" % [name, _level, _xp])


## Значки уровня — золотые кубики-звёзды столбиком над головой (дёшево и видно
## издалека, какой лучник ветеран).
func _refresh_level_badges() -> void:
	if _visual_holder == null:
		return
	if _badge_root != null:
		_badge_root.queue_free()
	_badge_root = Node3D.new()
	_visual_holder.add_child(_badge_root)
	var gold := _arch_mat(Color(1.0, 0.85, 0.25))
	gold.emission_enabled = true
	gold.emission = Color(1.0, 0.85, 0.25)
	gold.emission_energy_multiplier = 0.6
	for i in range(_level):
		_arch_box(_badge_root, Vector3(0.1, 0.1, 0.1), Vector3(0, 1.08 + 0.16 * float(i), 0), gold)


## Ближайший враг в attack_range (XZ) — только для ОРИЕНТАЦИИ конуса на стене (выстрел
## делает штатный _try_fire_at_resolved_target). Группа врагов — общая.
func _grn_nearest_enemy() -> Node3D:
	var best: Node3D = null
	var bd: float = attack_range * attack_range
	for e in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(e) or not (e is Node3D):
			continue
		var n := e as Node3D
		var dx: float = n.global_position.x - global_position.x
		var dz: float = n.global_position.z - global_position.z
		var d: float = dx * dx + dz * dz
		if d < bd:
			bd = d
			best = n
	return best
