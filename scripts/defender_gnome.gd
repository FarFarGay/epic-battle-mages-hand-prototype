class_name DefenderGnome
extends Gnome
## Гном-защитник. Подкласс Gnome, переопределяющий «активный» AI: вместо
## поиска куч ресурсов стоит у палатки и стреляет стрелами в скелетов в
## радиусе attack_radius. Урон рандомизирован — на skeleton.hp=30 даёт 1
## выстрел убивает в большинстве попаданий, иногда нужно 2.
##
## Базовая логика гнома (привязка к палатке через setup, IN_TENT-приклейка,
## RETURNING_TO_TENT при request_return от Camp, take_damage / apply_push,
## smith-эффект на смерть) наследуется как есть. Цвет красный задан в
## defender_gnome.tscn через override gnome_color.
##
## Не двигается «на цели» — стоит на той точке, где его поставил Camp при
## развёртке (_start_deploy сажает гнома в позицию палатки, далее enter_deployed
## не двигает; в обычном Gnome это позиция стартового SEARCHING-патруля,
## у защитника патруль выключен — стоит).

@export_group("Defender vision")
## Радиус конуса зрения. Лучник видит угрозы только впереди, в этом радиусе
## и в этом конусе. Больше attack_radius — позволяет «заметить» далёкого
## скелета и отреагировать (пойти патрулировать сторону), но стрелять сможет
## только когда скелет войдёт в attack_radius.
@export var cone_vision_radius: float = 35.0
## Полу-угол конуса зрения в градусах. 45° = 90° FOV — лучник видит
## впереди-перед-собой, фланги пропускает. Сужено с 60° чтобы реакция
## ощущалась чуть медленнее (надо доворачиваться/патрулировать) и было
## где апгрейдить через сторожевую вышку.
@export_range(15.0, 90.0) var vision_half_angle_deg: float = 45.0
@export_group("")

@export_group("Defender combat")
## Дистанция, с которой стрела гарантированно долетает. Внутри vision-конуса:
## ≤ attack_radius → стой, стреляй; > attack_radius → дальняя зона (патруль
## в сторону цели). Маска включает ColdEnemy — иначе при отзумленной камере
## все скелеты (LOD=FAR) становятся фантомами и защитник перестаёт реагировать.
@export var attack_radius: float = 22.5
## Случайный интервал между выстрелами. Не строгий метроном — несколько
## защитников в одной палатке не залпуют синхронно. Поднял с 0.6/1.2 до
## 1.0/2.0: на 54 защитниках это снизило поток стрел с ~60 до ~36/сек,
## что уменьшает overlap-чеки Area3D на стрелах (главная нагрузка на 290+
## скелетах). Damage 25..40 всё равно даёт 1-shot kill в 66% попаданий —
## защита продолжает работать.
@export var attack_cooldown_min: float = 1.0
@export var attack_cooldown_max: float = 2.0
## Урон рандомизирован: при skeleton.hp=30 диапазон 25..40 даёт 1-shot kill
## в ~66% случаев (damage > 30) и 2-shot в остальных. «Чаще за 1 выстрел».
@export var arrow_damage_min: float = 25.0
@export var arrow_damage_max: float = 40.0
@export var arrow_speed: float = 22.0
## Откуда вылетает стрела относительно центра гнома (поднимаем над головой,
## чтобы не задеть собственный корпус коллизией стрелы при выстреле).
@export var arrow_spawn_offset: Vector3 = Vector3(0, 0.6, 0)
## Стартовый горизонтальный разброс прицела (в метрах). Применяется к
## новеньким защитникам (без опыта). С каждым выстрелом точность растёт —
## фактический радиус разброса считается через current_inaccuracy_radius()
## по логарифмической кривой от _shots_fired. Только горизонталь —
## вертикальный разброс ломал бы баллистику (стрела в небо или в траву).
##
## Прокачка через бой: чем дольше защитник стреляет, тем точнее. Смерть
## обнуляет опыт (новый инстанс через Camp.reset_population стартует с 0).
## Игроку выгодно держать защитников живыми и/или брать «ветеранов» в путь.
@export var base_inaccuracy_radius: float = 1.5
## Сколько выстрелов нужно сделать чтобы разброс упал вдвое от базового.
## Формула: inaccuracy = base / (1 + shots/half_shots). На interval=1.5с
## между выстрелами это ~150с боя (2.5 мин) — комфортная «середина опыта».
##  - 0 выстрелов: 1.5м (новичок)
##  - 100: 0.75м (середина — capsule_radius=0.4 уже стабильно цепляет)
##  - 500: 0.25м (ветеран)
##  - 1000: 0.14м (снайпер)
@export var experience_half_shots: int = 100
@export var arrow_scene: PackedScene
## Куда складывать спавн стрел (чтобы они пережили смерть/уход самого гнома).
## Пусто → fallback на current_scene.
@export_node_path("Node") var projectiles_root_path: NodePath
@export_group("")

@export_group("Defender patrol")
## Радиус патруля от центра лагеря (`Camp.deploy_anchor`). Палатки стоят
## на `Camp.deploy_radius=8`, защитник на 12 — внешнее кольцо обороны,
## за палатками. Если у Camp нет valid anchor'а, защитник стоит на
## стартовой позиции (палатке).
@export var patrol_radius: float = 12.0
## Скорость шага во время патруля. Меньше move_speed=1.6 — стража движется
## размеренно, не суетится.
@export var patrol_speed: float = 1.0
## Дистанция до patrol-точки, чтобы выбрать новую (или после прибытия).
@export var patrol_arrival: float = 0.6
@export_group("")

@export_group("Defender escort")
## Латеральное смещение защитника от палатки в каравн-режиме (метры). Защитник
## не сидит внутри палатки и не идёт в хвосте колонны — он шагает СБОКУ, на
## этом расстоянии перпендикулярно направлению каравана. Несколько защитников
## одной палатки распределяются по разным бортам через `_escort_lateral_sign`.
@export var escort_lateral_distance: float = 2.0
## Дистанция до escort-точки, при которой защитник «в строю» — стоит, не
## дёргается на каждый микро-сдвиг палатки. Меньше — защитник трясётся возле
## слота. Больше — заметные провалы строя на поворотах.
@export var escort_arrival: float = 0.4
@export_group("")

@export_group("Defender separation")
## Личное пространство: если другой защитник в этом радиусе — наш дрейфует
## вбок, чтобы не стояли «один на одном». Меньше capsule-радиуса × 4 = тесная
## группа кучкой; больше 3м = гипер-разреженный строй. 1.5м — две капсулы
## раздвинуты с зазором 1м.
@export var separation_radius: float = 1.5
## Сила сепарации как доля patrol_speed. 0.5 = гентл-дрейф (0.5 м/с при
## касании), не ломающий прицел. 1.0+ — суетливо и не читается. 0 = выкл.
@export_range(0.0, 2.0) var separation_strength: float = 0.5
## Штраф к «эффективной дистанции» цели за каждого уже-стреляющего по ней
## защитника (для распределения огня в _scan_cone). 0.5 = «целью в N метров
## с одним стрелком воспринимается как N×1.5 метра без стрелка». 0 = не
## распределять (все огонь на ближайшего). 1.0+ = почти строгое 1-к-1.
@export_range(0.0, 2.0) var target_share_penalty: float = 0.5
@export_group("")

@export_group("Defender alarm")
## Сколько секунд лучник держит alarm-цель после получения сигнала
## EventBus.skeleton_attacked_camp. Если за это время скелет не убит и не
## ушёл из радиуса — alarm перестает быть актуальным, лучник возвращается
## к своему конусу. 5с — достаточно чтобы скелет 1-2 раза подойти и
## получить ответный выстрел; не настолько долго, чтобы фантомно держать
## целеуказание после смерти/ухода.
@export var alarm_persist_sec: float = 5.0
@export_group("")

## ENEMIES + COLD_ENEMY = 144. Видим и горячих, и холодных скелетов.
## Используем литерал — `const` не может ссылаться на другой class const.
const TARGET_MASK: int = 16 | 128

## Группа всех живых DefenderGnome. Используется для:
##  - сепарации позиций (не стоять в одной точке);
##  - распределения целей (учитывать кто на кого уже стреляет).
## Регистрация в _ready, удаление автоматическое на queue_free.
const DEFENDER_GROUP := &"defender"

## Период между сканами цели через PhysicsShapeQuery. Без throttle'а 54
## защитника на карте делали бы 54×60 = 3240 sphere-query/сек, и на 340+
## скелетах в радиусе 15м это убивало fps (3 FPS на стресс-тесте). С 0.25с
## — 216 query/сек, в 15 раз меньше. Кэшированная цель используется между
## сканами — если она валидна и в радиусе, не пересканируем.
const TARGET_SCAN_INTERVAL: float = 0.25

var _attack_timer: float = 0.0
var _projectiles_root: Node = null
var _patrol_target: Vector3 = Vector3.INF
var _cached_target: Node3D = null
var _target_scan_timer: float = 0.0
## Опыт стрельбы — сколько выстрелов сделал этот защитник за свою жизнь.
## Per-инстанс, не разделяется и не сохраняется. Используется в
## current_inaccuracy_radius() для постепенного повышения точности.
var _shots_fired: int = 0
## Текущее направление взгляда (горизонтальный unit-vector). Конус зрения
## считается относительно него. Обновляется каждый тик: если есть цель —
## смотрит на неё, иначе на patrol_target, иначе наружу от лагеря.
## По этому же вектору вращается тело (rotation.y).
var _facing: Vector3 = Vector3.FORWARD
## Прекомпьют cos(vision_half_angle_deg) — на каждом скане конуса dot >= cos
## дешевле, чем acos+сравнение с радианами. Считается в _ready и при
## изменении угла (живых правок параметра в инспекторе после _ready нет —
## пересчитывать не нужно).
var _vision_cone_cos: float = 0.5
## Цель, поданная сигналом EventBus.skeleton_attacked_camp — скелет, который
## бьёт по нашему лагерю. Имеет приоритет над cone-сканом: лучник
## разворачивается на неё, даже если она за спиной. null = тревоги нет.
var _alarm_target: Node3D = null
## Time.get_ticks_msec() до которого alarm считается актуальным. По истечении
## без ре-триггера сигналом — _alarm_target сбрасывается в null. Хорошо
## защищает от «фантомного целеуказания» если скелет ушёл из зоны или умер
## не от лучника.
var _alarm_until_msec: int = 0
## Знак латерального смещения для escort-точки: -1 (левый борт) или +1
## (правый борт). Рандомизируется в _ready, фиксируется на жизнь инстанса —
## чтобы защитник не «прыгал» через палатку на каждом тике.
var _escort_lateral_sign: float = 1.0


func _ready() -> void:
	# super регистрирует Damageable/Pushable, ставит цвет (наш красный override
	# из defender_gnome.tscn), подключает re-emit на EventBus, кэширует _effects_root.
	super._ready()
	if not projectiles_root_path.is_empty():
		_projectiles_root = get_node_or_null(projectiles_root_path)
	if _projectiles_root == null:
		_projectiles_root = get_tree().current_scene
	# Стартовая задержка случайна — 3 защитника в палатке не выстрелят залпом.
	_attack_timer = randf_range(attack_cooldown_min, attack_cooldown_max)
	# Фазовый сдвиг сканера: 54 защитника на карте не должны сканировать в
	# одном кадре — иначе кадровая нагрузка пойдёт волной каждые 0.25с.
	_target_scan_timer = randf() * TARGET_SCAN_INTERVAL
	# Прекомпьют cos(half-angle) — на каждом cone-чеке dot >= cos дешевле, чем
	# acos+сравнение. Раз в life-cycle, экспорт не меняется в рантайме.
	_vision_cone_cos = cos(deg_to_rad(vision_half_angle_deg))
	# Подписка на alarm-канал. Сигнал летит всем DefenderGnome'ам глобально;
	# фильтр «это мой лагерь?» — внутри хендлера. Без этой подписки лучник
	# не отреагировал бы на скелета за спиной, который рвёт палатку.
	EventBus.skeleton_attacked_camp.connect(_on_skeleton_attacked_camp)
	# Бросок монетки: левый борт vs правый. Несколько защитников одной палатки
	# в среднем распределятся 50/50 (для 3 — может выйти 2:1, это OK).
	_escort_lateral_sign = -1.0 if randf() < 0.5 else 1.0
	# В группу для соседского-учёта: сепарация позиций + распределение целей.
	add_to_group(DEFENDER_GROUP)


## Лагерь развернулся — защитник выходит из палатки. Базовый enter_deployed
## переводит state в SEARCHING; здесь дополнительно ставим _facing наружу
## от центра лагеря, чтобы первый же физкадр не сканировал в Vector3.FORWARD
## (т.е. в глобальное -Z, независимо от ориентации лагеря). На следующем
## тике _defender_combat_tick перезапишет _facing если есть цель.
func enter_deployed() -> void:
	super.enter_deployed()
	_facing = _outward_facing()
	_apply_facing()


## Защитник никогда не сидит внутри палатки. На вызов _enter_in_tent —
## из setup() (спавн) или из _tick_returning() (по дефолту: пришёл домой) —
## переходим в escort-режим (FOLLOWING_CARAVAN рядом с палаткой). Это
## ломает базовую инвариантность Gnome «IN_TENT — спокойное состояние», но
## защитник по дизайну никогда не должен быть «спокоен» в палатке: его роль
## — наружу, шагать рядом и стрелять.
func _enter_in_tent() -> void:
	enter_following_caravan()


## Defender'ская версия caravan-режима. Не регистрируется в orphan-цепочке
## (`_caravan_followers`) — он не идёт в хвосте, он шагает СБОКУ от своей
## палатки. Слот рассчитывается каждый тик в `_tick_following_caravan`
## по позиции `_home_tent`.
##
## Если защитник стал бездомным (палатка уничтожена), home_tent невалиден —
## он fallback'ом идёт за башней (см. `_tick_following_caravan`). Регистрация
## в _caravan_followers всё равно не нужна: ему чужой chain-слот с шумом
## от других гномов не подходит.
func enter_following_caravan() -> void:
	if _dying:
		return
	if _state == State.FOLLOWING_CARAVAN:
		return
	visible = true
	_assigned_pile = null
	_wander_target = Vector3.INF
	add_to_group(SKELETON_TARGET_GROUP)
	_state = State.FOLLOWING_CARAVAN
	if debug_log and LogConfig.master_enabled:
		var home_label: String = _home_tent.name if is_instance_valid(_home_tent) else "<orphan>"
		print("[DefenderGnome:%s] caravan-mode (escort: %s)" % [name, home_label])


## Tick движения в caravan-режиме. Цель:
##   - home_tent жив → escort-точка (`_compute_escort_target`): сбоку от
##     палатки, на дистанции `escort_lateral_distance` × ±1 (борт).
##   - home_tent мёртв → за башней. Чисто fallback на «последний живой
##     ориентир»; обычно эта ветка короткая — Camp.reassign_orphan_gnomes
##     пытается дать новую палатку.
##
## Sprint catch-up как у обычного гнома: чем дальше отстал, тем быстрее идёт
## (lerp move_speed → caravan_sprint_speed). Без этого защитник в слоте
## ползёт на 1.6 m/s, а Tower бежит на 8 — отрыв компенсировать нечем.
func _tick_following_caravan() -> void:
	if _camp == null:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	var target: Vector3
	if is_instance_valid(_home_tent):
		target = _compute_escort_target()
	else:
		# Бездомный — идём к башне как к ближайшему ориентиру каравана.
		var tower: Node3D = _camp.get_tower()
		if tower == null or not is_instance_valid(tower):
			velocity.x = 0.0
			velocity.z = 0.0
			return
		target = tower.global_position

	var to_target: Vector3 = target - global_position
	to_target.y = 0.0
	var dist_sq: float = to_target.length_squared()
	if dist_sq < escort_arrival * escort_arrival:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var dist: float = sqrt(dist_sq)
	var dir: Vector3 = to_target / dist
	var t: float = clampf(dist / maxf(caravan_full_sprint_distance, 0.001), 0.0, 1.0)
	var speed: float = lerpf(move_speed, caravan_sprint_speed, t)
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed


## Escort-точка: сбоку от палатки, перпендикулярно направлению каравана.
## Forward-вектор каравана аппроксимируется направлением (tower − tent):
## палатка едет ЗА башней, значит forward = к башне. Perpendicular = поворот
## forward на 90° в плоскости XZ. Сторона выбирается через `_escort_lateral_sign`
## (стабильно на жизнь инстанса).
##
## Edge: если башни нет или forward вырожден (палатка в той же точке) —
## fallback на global +X (произвольный, но детерминированный). Защитник
## встанет «справа» от палатки в мировой системе — лучше, чем сваливаться
## в неё центром.
func _compute_escort_target() -> Vector3:
	var tent_pos: Vector3 = _home_tent.global_position
	var tower: Node3D = _camp.get_tower()
	var forward: Vector3 = Vector3.RIGHT
	if tower != null and is_instance_valid(tower):
		forward = tower.global_position - tent_pos
		forward.y = 0.0
	if forward.length_squared() < VecUtil.EPSILON_SQ:
		forward = Vector3.RIGHT
	forward = forward.normalized()
	# Perpendicular: 90° rotation вокруг Y. (z, 0, -x) — правая сторона
	# относительно forward (правая рука, если смотреть по forward).
	var perpendicular: Vector3 = Vector3(forward.z, 0.0, -forward.x)
	return tent_pos + perpendicular * (escort_lateral_distance * _escort_lateral_sign)


## Override виртуального hook'а Gnome — переопределяем активную AI-логику.
## Базовый Gnome._physics_process сам решает: hot (move_and_slide) или cold
## (skip физики на FAR-LOD), включает гравитацию и knockback — defender
## автоматически получает всё это.
##
## - RETURNING_TO_TENT: возврат домой при свёртке через унаследованный
##   `_tick_returning`. Без боя — гном sprint'ит к палатке.
## - FOLLOWING_CARAVAN: движение в общую цепочку каравана (унаследованный
##   `_tick_following_caravan`) + параллельная стрельба по cone/alarm-цели
##   на ходу. Sector-патруль здесь не имеет смысла — anchor лагеря stale
##   и колонна не ждёт; защитник просто отстреливается из строя.
## - Прочие (SEARCHING / COMMUTING_* / IDLE): обычный боевой тик у
##   развёрнутого лагеря — стой/стреляй или патрулируй.
func _active_tick(delta: float) -> void:
	match _state:
		State.RETURNING_TO_TENT:
			_tick_returning()
		State.FOLLOWING_CARAVAN:
			_tick_following_caravan()
			_caravan_combat_tick(delta)
		_:
			_defender_combat_tick(delta)


## Боевой тик защитника в развёрнутом лагере. Один путь решения:
##   1. Резолв цели через `_resolve_target` (alarm > cone-скан с throttle'ом).
##   2. По дистанции до цели: ≤ attack_radius → стой, стреляй; > attack_radius
##      → sector-патруль (точка на patrol-окружности в направлении цели от лагеря).
##   3. Без цели — случайный патруль по периметру.
##   4. `_facing` обновляется по результату (цель / patrol-точка / наружу).
func _defender_combat_tick(delta: float) -> void:
	var target: Node3D = _resolve_target(delta)

	if target != null and is_instance_valid(target):
		var dist: float = global_position.distance_to(target.global_position)
		# Поворачиваемся к цели — даже если она пришла по alarm'у из-за спины.
		_facing = _horizontal_dir_to(target.global_position)
		if dist <= effective_attack_radius():
			# Близкая зона — стреляем. По умолчанию стоим неподвижно;
			# с апгрейдом kiting и слишком близкой угрозой — пятимся спиной,
			# продолжая стрелять (лучник держит дистанцию).
			var kiting: bool = _camp != null and is_instance_valid(_camp) \
				and _camp.has_upgrade(Camp.UPGRADE_KITING) \
				and dist < _camp.kite_threshold_distance
			if kiting:
				# -_facing — вектор «от цели». patrol_speed как темп отступления:
				# медленнее обычного движения, не суматошный «убегает в панике».
				velocity.x = -_facing.x * patrol_speed
				velocity.z = -_facing.z * patrol_speed
			else:
				velocity.x = 0.0
				velocity.z = 0.0
			# Сепарация: дрейф вбок если соседний защитник прижался ближе
			# separation_radius. Прибавляется к base velocity (стой / kite),
			# чтобы лучники не стояли «один на одном». _facing на цели не
			# меняется — выстрелы идут в правильную сторону.
			var sep: Vector3 = _compute_separation_force()
			velocity.x += sep.x
			velocity.z += sep.z
			_attack_timer -= delta
			if _attack_timer <= 0.0:
				_fire_at(target)
				_attack_timer = randf_range(attack_cooldown_min, attack_cooldown_max)
		else:
			# Дальняя зона — патруль в сторону цели (со стороны лагеря).
			_patrol_toward_sector(target.global_position)
	else:
		# Цели нет — охлаждаемся, идём по случайному периметру.
		_attack_timer = maxf(_attack_timer - delta, 0.0)
		_patrol_random()
		# В рандом-патруле смотрим в сторону движения; если стоим — наружу
		# от лагеря. Это даёт читабельную «осматривает периметр» позу.
		var horizontal_speed_sq: float = velocity.x * velocity.x + velocity.z * velocity.z
		if horizontal_speed_sq > 0.01:
			_facing = Vector3(velocity.x, 0.0, velocity.z).normalized()
		else:
			_facing = _outward_facing()

	_apply_facing()


## Боевой тик защитника в караван-режиме. Параллелится с унаследованным
## `_tick_following_caravan` (тот двигает к chain-слоту). Здесь — стрельба
## на ходу:
##   - Та же модель восприятия (alarm > cone), что и в DEPLOYED — `_resolve_target`.
##   - Цель в attack_radius → стреляем НЕ обнуляя velocity (колонна не ждёт;
##     защитник идёт и стреляет одновременно).
##   - Цель видна, но дальше attack_radius → продолжаем идти, конус её ведёт.
##     Войдёт в attack — следующий тик откроет огонь.
##   - Без цели — `_facing` смотрит вперёд по движению (направление колонны).
##
## Sector-патруль здесь не вызывается: anchor лагеря в caravan-режиме stale
## (последний _deploy_anchor из прошлой развёртки), и колонна сама ведёт
## защитника, перенаправлять его патруль смысла нет.
func _caravan_combat_tick(delta: float) -> void:
	var target: Node3D = _resolve_target(delta)

	if target != null and is_instance_valid(target):
		_facing = _horizontal_dir_to(target.global_position)
		var dist: float = global_position.distance_to(target.global_position)
		if dist <= effective_attack_radius():
			# Стреляем НЕ останавливаясь: velocity управляется super
			# `_tick_following_caravan` (идём к chain-слоту), мы только
			# тикаем cooldown и спавним стрелу.
			_attack_timer -= delta
			if _attack_timer <= 0.0:
				_fire_at(target)
				_attack_timer = randf_range(attack_cooldown_min, attack_cooldown_max)
		# else: цель далеко — просто идём дальше, конус её ведёт.
	else:
		_attack_timer = maxf(_attack_timer - delta, 0.0)
		# Face — направление движения (вперёд по караван-чейну). Outward от
		# anchor'а в caravan-режиме невалиден: anchor — точка прошлой развёртки,
		# она stale, может быть далеко позади. Если совсем стоим (дошли до
		# слота, ждём leader'а) — сохраняем последний _facing.
		var horizontal_speed_sq: float = velocity.x * velocity.x + velocity.z * velocity.z
		if horizontal_speed_sq > 0.01:
			_facing = Vector3(velocity.x, 0.0, velocity.z).normalized()

	_apply_facing()


## Резолв текущей цели для боевого тика. alarm имеет приоритет (override
## конуса) — это «магический» канал координации. Иначе — cone-скан с
## throttle'ом TARGET_SCAN_INTERVAL.
##
## Используется и в DEPLOYED-, и в CARAVAN-комбате — единая модель восприятия.
## Логирует смену состояния «вижу/не вижу» через `_log_target_change`.
##
## Freed-safety: между физтиками `_cached_target` мог быть freed (скелет
## умер). В Godot 4.6 операторы `== null` / `!= null` на freed-ссылке
## возвращают непредсказуемо, и typed-параметр Node3D в `_log_target_change`
## строго отвергает «previously freed». Решение: в начале тика жёстко
## обнулить через `is_instance_valid` — дальше работаем только с (null|живой).
func _resolve_target(delta: float) -> Node3D:
	_target_scan_timer -= delta
	if not is_instance_valid(_cached_target):
		_cached_target = null
	var had_prev: bool = _cached_target != null

	var alarm: Node3D = _resolve_alarm_target()
	if alarm != null:
		_cached_target = alarm
		# Сброс throttle: при потере alarm'а сразу пересканируем cone, не ждём ещё 0.25с.
		_target_scan_timer = 0.0
	else:
		# Cheap-валидация cone-цели — если вышла из конуса/радиуса, инвалидируем
		# не дожидаясь throttle'а. _cached_target тут уже null или живой
		# (см. cleanup выше) — без is_instance_valid внутри.
		var stale: bool = false
		if _cached_target != null:
			if global_position.distance_to(_cached_target.global_position) > cone_vision_radius:
				stale = true
			elif not _is_in_cone(_cached_target.global_position):
				stale = true
		if stale:
			_cached_target = null
		# Скан раз в TARGET_SCAN_INTERVAL, плюс немедленный пересмотр когда
		# цель только что инвалидировалась (prev был — теперь нет).
		if _target_scan_timer <= 0.0 or (had_prev and _cached_target == null):
			_cached_target = _scan_cone()
			_target_scan_timer = TARGET_SCAN_INTERVAL

	_log_target_change(had_prev, _cached_target)
	return _cached_target


## Фронт-триггер лога смены состояния «вижу/не вижу». Без условия prev != curr
## лог спамил бы каждый кадр когда цель есть. Источник (alarm/vision)
## сообщается на появлении — для отладки откуда пришёл триггер.
##
## Принимает уже-провалидированный bool `had_prev` (а не сам Node), чтобы
## не зависеть от валидности freed-инстанса на стороне вызова.
func _log_target_change(had_prev: bool, curr: Node3D) -> void:
	if not (debug_log and LogConfig.master_enabled):
		return
	if not had_prev and curr != null:
		var d: float = global_position.distance_to(curr.global_position)
		var src: String = "alarm" if curr == _alarm_target else "vision"
		print("[DefenderGnome:%s] цель появилась: %s (dist=%.1fм, %s)" % [name, curr.name, d, src])
	elif had_prev and curr == null:
		print("[DefenderGnome:%s] цель потеряна" % name)


## Возвращает alarm-цель если она ещё валидна и не протух таймер. null
## означает «тревоги нет» — лучник работает по cone-скану. Сама очистка
## (_alarm_target = null) делается здесь, ленивая — не нужно тикать таймер
## отдельно вне комбата.
func _resolve_alarm_target() -> Node3D:
	if _alarm_target == null:
		return null
	if not is_instance_valid(_alarm_target):
		_alarm_target = null
		return null
	if Time.get_ticks_msec() > _alarm_until_msec:
		# Лог потери тревоги — для отладки кадра, когда «полыхнуло и стихло».
		if debug_log and LogConfig.master_enabled:
			print("[DefenderGnome:%s] тревога снята (таймер)" % name)
		_alarm_target = null
		return null
	return _alarm_target


## Случайный патруль по окружности patrol_radius вокруг Camp.deploy_anchor.
## Используется когда лучник никого не видит и тревоги нет — стража обходит
## периметр. Если anchor невалиден — стоим на месте.
func _patrol_random() -> void:
	if _camp == null:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var anchor: Vector3 = _camp.deploy_anchor
	if _patrol_target == Vector3.INF or _horizontal_distance(_patrol_target) < patrol_arrival:
		_patrol_target = _pick_patrol_point(anchor, randf() * TAU)
	_step_toward(_patrol_target, patrol_speed)


## Патруль в направлении угрозы: точка на окружности patrol_radius в той
## стороне лагеря, откуда видна цель. Лучник идёт туда, в пути конус
## смотрит на цель — если она войдёт в attack_radius, реакция автоматически
## переключится на «стой и стреляй» (см. _defender_combat_tick).
func _patrol_toward_sector(target_pos: Vector3) -> void:
	if _camp == null:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var anchor: Vector3 = _camp.deploy_anchor
	# Угол на цель относительно лагеря — направление, в котором стоит цель
	# по отношению к центру. Y игнорируем — патруль плоский.
	var dx: float = target_pos.x - anchor.x
	var dz: float = target_pos.z - anchor.z
	if dx * dx + dz * dz < VecUtil.EPSILON_SQ:
		# Цель ровно в центре лагеря — fallback на текущий patrol_target,
		# либо случайный угол.
		if _patrol_target == Vector3.INF:
			_patrol_target = _pick_patrol_point(anchor, randf() * TAU)
	else:
		var angle: float = atan2(dz, dx)
		_patrol_target = _pick_patrol_point(anchor, angle)
	_step_toward(_patrol_target, patrol_speed)


## Точка на окружности patrol_radius вокруг центра лагеря под заданным углом.
## Y берём с anchor'а — палатки стоят на полу, патруль на той же высоте.
## Принимает угол явно: вызывающий решает random/sector — единая формула.
func _pick_patrol_point(anchor: Vector3, angle: float) -> Vector3:
	return Vector3(
		anchor.x + cos(angle) * patrol_radius,
		anchor.y,
		anchor.z + sin(angle) * patrol_radius,
	)


## Локальный аналог Gnome._move_toward_xz, но с произвольной скоростью:
## защитник патрулирует медленнее (patrol_speed), а Gnome.move_speed
## остаётся для возврата в палатку (через унаследованный _tick_returning).
func _step_toward(target: Vector3, speed: float) -> void:
	var to_target: Vector3 = target - global_position
	to_target.y = 0.0
	if to_target.length_squared() < VecUtil.EPSILON_SQ:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var dir := to_target.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed


## Cone-скан: PhysicsShapeQuery со сферой cone_vision_radius (broadphase),
## потом фильтр по углу относительно _facing. Возвращает «лучшую» цель в
## конусе с учётом распределения огня между защитниками — цель, по которой
## уже стреляет N соседей, считается «дальше» на множитель
## target_share_penalty × N. Это раскидывает огонь между видимыми
## скелетами вместо «все на одного».
##
## Mask = ENEMIES + COLD_ENEMY: видим и активных скелетов, и LOD-холодных.
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
		# Explicit radius check: Godot 4.6 подмешивает broadphase AABB вне sphere.
		if d > cone_vision_radius:
			continue
		# Cone-фильтр: dot(forward, dir_to_target) >= cos(half_angle).
		if not _is_in_cone(node.global_position):
			continue
		# Score = dist × (1 + aimers × penalty). Penalty=0 → чистая дистанция
		# (старое поведение). Penalty=0.5 → каждый уже-стрелок на цели
		# делает её «дальше» на 50%: близкая цель с 1 стрелком сравняется по
		# приоритету с целью на 50% дальше без стрелков.
		var aimers: int = _count_aimers_on(node)
		var score: float = d * (1.0 + float(aimers) * target_share_penalty)
		if score < best_score:
			best_score = score
			best = node
	return best


## Сколько ДРУГИХ защитников из нашей группы уже целят в указанную цель.
## Используется в _scan_cone для распределения огня. Дёшево: 8 защитников ×
## ~5 кандидатов × 4 скана/сек = ~160 итераций/сек.
##
## Freed-safety: _cached_target другого защитника читаем untyped'ом, чтобы
## не упасть на freed-инстансе (между его scan'ом и нашим он мог умереть).
func _count_aimers_on(target: Node3D) -> int:
	var count: int = 0
	for d in get_tree().get_nodes_in_group(DEFENDER_GROUP):
		if d == self or not is_instance_valid(d):
			continue
		var dn := d as DefenderGnome
		if dn == null:
			continue
		var their_target = dn._cached_target
		if not is_instance_valid(their_target):
			continue
		if their_target == target:
			count += 1
	return count


## Сепарация: суммарный вектор отталкивания от ближайших защитников
## внутри separation_radius. Linear falloff (близкий = сильнее). Применяется
## к velocity в attack-ветке боевого тика — лучник стоит/пятится, но
## дрейфует вбок если сосед прижался. Не ломает _facing (выстрелы по цели
## идут как обычно).
func _compute_separation_force() -> Vector3:
	if separation_strength <= 0.0:
		return Vector3.ZERO
	var force: Vector3 = Vector3.ZERO
	var radius_sq: float = separation_radius * separation_radius
	var my_pos: Vector3 = global_position
	for d in get_tree().get_nodes_in_group(DEFENDER_GROUP):
		if d == self or not is_instance_valid(d):
			continue
		var other := d as Node3D
		if other == null:
			continue
		var to_self: Vector3 = my_pos - other.global_position
		to_self.y = 0.0
		var d_sq: float = to_self.length_squared()
		if d_sq > radius_sq or d_sq < 0.0001:
			continue
		var dist: float = sqrt(d_sq)
		# Linear falloff: на касании (dist→0) сила = 1.0; на radius — 0.
		var falloff: float = (separation_radius - dist) / separation_radius
		force += (to_self / dist) * falloff
	return force * (patrol_speed * separation_strength)


## Точка в конусе зрения? Сравниваем угол между _facing и направлением
## на цель с прекомпьютнутым cos(half-angle). Y-компонента игнорируется —
## конус только горизонтальный (стрельба в небо/в пол не нужна).
##
## Edge: цель ровно у ног (dist→0) — вернуть true (нет смысла считать угол).
func _is_in_cone(target_pos: Vector3) -> bool:
	var to: Vector3 = target_pos - global_position
	to.y = 0.0
	var dist_sq: float = to.length_squared()
	if dist_sq < VecUtil.EPSILON_SQ:
		return true
	var dir: Vector3 = to / sqrt(dist_sq)
	# _facing — горизонтальный unit-vector. dot >= cos означает угол <= half.
	return dir.dot(_facing) >= _vision_cone_cos


## Горизонтальный unit-vector от защитника к точке. Используется для
## поворота _facing на цель (атака, alarm, sector-патруль).
func _horizontal_dir_to(target_pos: Vector3) -> Vector3:
	var to: Vector3 = target_pos - global_position
	to.y = 0.0
	if to.length_squared() < VecUtil.EPSILON_SQ:
		return _facing  # сохраняем текущее направление
	return to.normalized()


## Дефолтное направление взгляда: наружу от центра лагеря. Используется
## когда нет цели и нет движения — стража смотрит «на горизонт» из своей
## позиции, спиной к костру. Если лагеря нет (orphan) — старое _facing.
func _outward_facing() -> Vector3:
	if _camp == null:
		return _facing
	var out: Vector3 = global_position - _camp.deploy_anchor
	out.y = 0.0
	if out.length_squared() < VecUtil.EPSILON_SQ:
		return _facing
	return out.normalized()


## Применяет _facing к rotation.y тела. Локальная -Z направляется на _facing
## (стандартная конвенция Godot: forward = -Z для камер и для меша-стрелки
## в defender_gnome.tscn). atan2(-x, -z) даёт угол поворота вокруг Y, при
## котором -Z локального базиса совпадает с _facing.
func _apply_facing() -> void:
	if _facing.length_squared() < VecUtil.EPSILON_SQ:
		return
	rotation.y = atan2(-_facing.x, -_facing.z)


## Хендлер EventBus.skeleton_attacked_camp. Скелет attacker только что
## ударил victim (CampPart или мирный гном). Триггерим тревогу только если
## victim — из НАШЕГО лагеря: иначе при двух Camp-инстансах на карте все
## защитники реагировали бы на любой инцидент.
##
## Идемпотентность: повторный удар того же скелета по тому же объекту
## просто продлевает _alarm_until_msec — тревога не «дёргается».
func _on_skeleton_attacked_camp(attacker: Node3D, victim: Node3D, _position: Vector3) -> void:
	if _camp == null or attacker == null or victim == null:
		return
	if not is_instance_valid(attacker) or not is_instance_valid(victim):
		return
	# Фильтр «наш лагерь»:
	#  - CampPart: parent == _camp (палатки лежат как прямые дети Camp-ноды).
	#  - Gnome: входит в _camp.get_gnomes() (Camp хранит всех своих).
	# Defender'ы по сигнатуре сигнала не приходят (см. Skeleton._perform_strike) —
	# отдельно отсеивать не нужно.
	var ours: bool = false
	if victim is CampPart:
		ours = victim.get_parent() == _camp
	elif victim is Gnome:
		ours = _camp.get_gnomes().has(victim)
	if not ours:
		return
	var prev: Node3D = _alarm_target
	_alarm_target = attacker
	_alarm_until_msec = Time.get_ticks_msec() + int(alarm_persist_sec * 1000.0)
	if debug_log and LogConfig.master_enabled and prev != attacker:
		var dist: float = global_position.distance_to(attacker.global_position)
		print("[DefenderGnome:%s] тревога: %s атакует %s (dist=%.1fм)" % [name, attacker.name, victim.name, dist])


## Текущий радиус разброса с учётом опыта. Логарифмическая кривая:
## новичок имеет base, ветеран — асимптотически 0. После experience_half_shots
## разброс падает вдвое, после 2× — на 2/3, после 9× — на 90%.
func current_inaccuracy_radius() -> float:
	if base_inaccuracy_radius <= 0.0 or experience_half_shots <= 0:
		return base_inaccuracy_radius
	return base_inaccuracy_radius / (1.0 + float(_shots_fired) / float(experience_half_shots))


## Сколько выстрелов сделал этот защитник — для HUD'а / прокачки / дебага.
func get_shots_fired() -> int:
	return _shots_fired


## Killing blow callback — Arrow вызывает после успешного летального попадания.
## Кредит за убийство уходит в squad XP лагеря (общий опыт отряда). Личный
## опыт стрельбы (точность через _shots_fired) накапливается отдельно в _fire_at.
##
## victim не используется здесь, но передаётся на случай если в будущем
## разные враги дают разный XP (элиты, боссы).
func on_kill_credit(victim: Node) -> void:
	if _camp == null or not is_instance_valid(_camp):
		return
	# Позиция жертвы — для popup'а «+10» над трупом. Если жертва уже
	# освобождена (queue_free на death) — fallback на собственную позицию
	# стрелка (popup появится у лучника, тоже читаемо).
	var pos: Vector3 = global_position
	if victim != null and is_instance_valid(victim) and victim is Node3D:
		pos = (victim as Node3D).global_position
	_camp.credit_kill(pos)


## Эффективный радиус стрельбы с учётом активных squad-апгрейдов. long_draw
## добавляет camp.upgrade_long_draw_bonus метров к базовому attack_radius.
## Используется и в боевом тике (DEPLOYED+CARAVAN), и в alarm-логике.
func effective_attack_radius() -> float:
	if _camp != null and is_instance_valid(_camp) and _camp.has_upgrade(Camp.UPGRADE_LONG_DRAW):
		return attack_radius + _camp.upgrade_long_draw_bonus
	return attack_radius


func _fire_at(target: Node3D) -> void:
	if arrow_scene == null:
		push_warning("DefenderGnome: arrow_scene не задан")
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		push_warning("DefenderGnome: arrow_scene не инстанцируется как Arrow")
		return
	if not is_instance_valid(_projectiles_root):
		_projectiles_root = get_tree().current_scene
	_projectiles_root.add_child(arrow)
	var damage: float = randf_range(arrow_damage_min, arrow_damage_max)
	var spawn := global_position + arrow_spawn_offset
	# Прицеливание со случайным смещением в круге текущего разброса. sqrt
	# для uniform-в-круге (иначе плотность к центру выше — «магнетизм»
	# к точному выстрелу, чего не хочется).
	var inaccuracy := current_inaccuracy_radius()
	var aim_pos := target.global_position
	if inaccuracy > 0.0:
		var angle := randf() * TAU
		var r := sqrt(randf()) * inaccuracy
		aim_pos.x += cos(angle) * r
		aim_pos.z += sin(angle) * r
	arrow.damage = damage
	arrow.speed = arrow_speed
	arrow.setup(spawn, aim_pos)
	# Привязка к стрелку для squad XP — на летальном попадании Arrow
	# вызовет on_kill_credit ниже.
	arrow.set_shooter(self)
	_shots_fired += 1
	if debug_log and LogConfig.master_enabled:
		var d: float = global_position.distance_to(target.global_position)
		var aim_offset: float = target.global_position.distance_to(aim_pos)
		print("[DefenderGnome:%s] выстрел в %s (dist=%.1fм, dmg=%.1f, aim_off=%.2fм)" % [name, target.name, d, damage, aim_offset])
		# Milestone-лог каждые 25 выстрелов — видно прогресс ветеранов.
		if _shots_fired % 25 == 0:
			print("[DefenderGnome:%s] опыт: %d выстрелов, точность=%.2fм" % [name, _shots_fired, current_inaccuracy_radius()])
