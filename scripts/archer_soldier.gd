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

## Per-soldier счётчик выстрелов для расчёта точности. Теряется на смерть.
var _shots_fired: int = 0
var _projectiles_root: Node = null

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


func _exit_tree() -> void:
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

	# Strict-march: дойти до слота. Combat-assist по пути — стрельба в врага
	# в attack_range без остановки strict-марша (стоим стреляем, потом идём).
	if _squad != null and _camp != null \
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

	# Нет цели — squad-positioning (как у pikeman'а).
	if _squad == null or _camp == null:
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
		velocity = Vector3.ZERO
		_facing = _outward_facing()
		return
	_face_horizontal(to_goal_xz, dist)
	_move_toward(to_goal_xz, dist)


## True если есть resolved cone/alarm-цель в attack_range и cd готов —
## стреляет, ставит cd, возвращает true. Иначе false.
func _try_fire_at_resolved_target(delta: float) -> bool:
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
	velocity = Vector3.ZERO
	_fire_at(target)
	_attack_cd = randf_range(attack_cooldown_min, attack_cooldown_max)
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
	var damage: float = randf_range(attack_damage_min, attack_damage_max)
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
	arrow.setup(spawn, aim_pos)
	_shots_fired += 1
	if _squad != null:
		_squad.add_charge(1.0)
	if debug_log and LogConfig.master_enabled:
		print("[ArcherSoldier:%s] выстрел в %s (dmg=%.1f, shots=%d)" % [name, target.name, damage, _shots_fired])
