class_name SkeletonWarband
extends Node3D
## Бродячая банда скелетов. Спавнит N скелетов и гоняет их КОГЕЗИВНО по карте
## через общий якорь + ЛИЧНОЕ смещение каждого в блобе (anchor + offset), а ночью
## переключает в ШТУРМ лагеря (set_forced_target). Члены — самостоятельные
## Skeleton: их vision-аггро собственная, поэтому банда, прошедшая мимо лагеря,
## сама нападает (опортунистично), а ушедшая — продолжает роуминг. Координатор не
## лезет в FSM скелетов — только ставит личный якорь / forced_target. Шаблон —
## [ArcherGroup]: члены живут в current_scene, банда queue_free когда все мертвы.
##
## КЛЮЧЕВОЕ: у каждого члена СВОЯ точка в блобе (anchor + персональный offset).
## Без этого все шли бы в одну точку и сбивались в «одного скелета» (boids-
## расступание работает только вблизи). Блоб радиусом ∝ √count — горда, не стопка.
##
## Режимы:
##  - ROAM (день): якорь бродит по вейпойнтам, блоб переезжает целиком. Лагерь не
##    цель — нападают только если увидят.
##  - ASSAULT (ночь): forced_target = ядро/башня → штурм напрямую.

enum Mode { ROAM, ASSAULT }

@export var skeleton_scene: PackedScene = null
@export var member_count: int = 100
## Плотность блоба: радиус = √count × это. 0.6 → 100 скелетов в блобе ~6м радиуса
## (плотная горда, не «разбрелась по площади»). Больше — реже, меньше — плотнее.
@export var formation_spacing: float = 0.6
## Сколько якорь стоит на вейпойнте (банда толпится), прежде чем уйти к новому.
@export var loiter_seconds: float = 6.0
## Дальность следующего вейпойнта роуминга от текущего якоря.
@export var roam_step_min: float = 14.0
@export var roam_step_max: float = 30.0
## Клампим вейпойнты в полукарту, чтобы банда не ушла за край.
@export var map_half_extent: float = 60.0
## Членов за кадр на спавне — стаггер (без хитча на 100 инстансах; визуально
## «банда вытекает из зоны»).
@export var spawn_batch_per_frame: int = 8

var _mode: int = Mode.ROAM
## Цель штурма (ядро/башня) в режиме ASSAULT — члены спавнятся сразу с forced_target.
var _assault_target: Node3D = null
var _origin: Vector3 = Vector3.ZERO
var _anchor: Vector3 = Vector3.ZERO
var _formation_radius: float = 4.0
var _members: Array[Skeleton] = []
## Параллельно _members: персональное смещение каждого в блобе (anchor + offset).
var _member_offsets: Array[Vector3] = []
var _spawned: int = 0
var _loiter_timer: float = 0.0
## XZ-AABB подземелья (задаёт координатор-WaveDirector): роум-вейпойнты не
## выбираются внутри неё — туда нет навмеша, банда застрянет о стены. AABB()
## (size 0) = не задано.
var _dungeon_avoid: AABB = AABB()

const ALIVE_CHECK_INTERVAL: float = 1.0
var _alive_timer: float = 0.0


## Инициализация ПОСЛЕ add_child. origin — центр спавна банды (точка зоны).
func setup(scene: PackedScene, origin: Vector3, count: int = -1, mode: int = Mode.ROAM, assault_target: Node3D = null) -> void:
	skeleton_scene = scene
	_origin = origin
	_anchor = origin
	global_position = origin
	if count > 0:
		member_count = count
	_mode = mode
	_assault_target = assault_target
	_formation_radius = sqrt(float(maxi(member_count, 1))) * formation_spacing
	_loiter_timer = loiter_seconds


func _process(delta: float) -> void:
	# Стаггер-спавн: льём батчами, пока не наберём member_count (без хитча).
	if _spawned < member_count:
		_spawn_batch()
		return
	# Полностью заспавнено: alive-check + роуминг.
	_alive_timer -= delta
	if _alive_timer <= 0.0:
		_alive_timer = ALIVE_CHECK_INTERVAL
		var any_alive: bool = false
		for s in _members:
			if is_instance_valid(s):
				any_alive = true
				break
		if not any_alive:
			queue_free()
			return
	if _mode != Mode.ROAM:
		return
	# Роуминг: якорь стоит loiter_seconds, потом уходит к новому вейпойнту;
	# раздаём каждому его ЛИЧНУЮ точку (anchor + offset) — блоб переезжает строем.
	_loiter_timer -= delta
	if _loiter_timer <= 0.0:
		_loiter_timer = loiter_seconds
		_anchor = _pick_roam_waypoint()
		for i in range(_members.size()):
			var s: Skeleton = _members[i]
			if is_instance_valid(s):
				s.set_roam_anchor(_anchor + _member_offsets[i])


func _spawn_batch() -> void:
	if skeleton_scene == null:
		_spawned = member_count  # стоп
		push_warning("SkeletonWarband: skeleton_scene не задан")
		return
	var root: Node = get_tree().current_scene
	if root == null:
		root = get_tree().root
	var n: int = mini(spawn_batch_per_frame, member_count - _spawned)
	for _k in range(n):
		_spawned += 1
		var s := skeleton_scene.instantiate() as Skeleton
		if s == null:
			continue
		root.add_child(s)
		# Личное смещение в блобе (равномерно по диску). Спавним УЖЕ в строю и сразу
		# даём личный якорь — банда стоит блобом, не стопкой.
		var off: Vector3 = _random_disk_offset(_formation_radius)
		s.global_position = _origin + off
		# Член спавнится сразу в режиме банды: ASSAULT → штурм цели, ROAM → личный
		# якорь в блобе. (Стаггер-спавн: set_mode позже застал бы не всех.)
		if _mode == Mode.ASSAULT and _assault_target != null and is_instance_valid(_assault_target):
			s.set_forced_target(_assault_target)
			# + якорь у цели (точка штурма + личное смещение). СТРАХОВКА: forced
			# отваливается в _scan_target, если скелет упёрся (local-wander) и
			# потерял LOS к цели — в плотном блобе давка постоянно роняет его в
			# local-wander. Без якоря target-less скелет уходит в СЛУЧАЙНЫЙ wander
			# («бродит по карте»). С якорём _wander_tick гонит его _roam_tick'ом
			# обратно к лагерю; стоп-радиус мал → встаёт у цели, где LOS/vision
			# снова поднимут forced и он начнёт ломать стену / бить ядро.
			s.set_roam_anchor(_assault_target.global_position + off)
		else:
			s.set_roam_anchor(_anchor + off)
		_members.append(s)
		_member_offsets.append(off)


## Случайная точка в диске радиуса r (равномерно по площади: sqrt(randf())).
func _random_disk_offset(r: float) -> Vector3:
	var a: float = randf() * TAU
	var d: float = sqrt(randf()) * r
	return Vector3(cos(a) * d, 0.0, sin(a) * d)


## True если хоть один живой член в радиусе r (XZ) от center. Штурм-координатор
## (WaveDirector) использует для дуги-телеграфа: мигает, пока волна не вошла в
## зону строительства лагеря. Early-out на первом вошедшем.
func has_member_within(center: Vector3, radius: float) -> bool:
	var r_sq: float = radius * radius
	for s in _members:
		if not is_instance_valid(s):
			continue
		var dx: float = s.global_position.x - center.x
		var dz: float = s.global_position.z - center.z
		if dx * dx + dz * dz <= r_sq:
			return true
	return false


## Переключить режим. ASSAULT: forced_target (ядро/башня) + якорь у цели (та же
## страховка от потери цели, что и на спавне — см. _spawn_batch). ROAM: личные
## якоря в блобе.
func set_mode(m: int, assault_target: Node3D = null) -> void:
	_mode = m
	if m == Mode.ASSAULT and assault_target != null and is_instance_valid(assault_target):
		_assault_target = assault_target
	for i in range(_members.size()):
		var s: Skeleton = _members[i]
		if not is_instance_valid(s):
			continue
		if m == Mode.ASSAULT and assault_target != null and is_instance_valid(assault_target):
			s.set_forced_target(assault_target)
			s.set_roam_anchor(assault_target.global_position + _member_offsets[i])
		else:
			s.set_roam_anchor(_anchor + _member_offsets[i])


## XZ-AABB подземелья от координатора — роум туда не ходит (нет навмеша → стены).
func set_dungeon_avoid(aabb: AABB) -> void:
	_dungeon_avoid = aabb


func _in_dungeon(p: Vector3) -> bool:
	if _dungeon_avoid.size.x <= 0.0:
		return false
	return p.x >= _dungeon_avoid.position.x and p.x <= _dungeon_avoid.position.x + _dungeon_avoid.size.x \
			and p.z >= _dungeon_avoid.position.z and p.z <= _dungeon_avoid.position.z + _dungeon_avoid.size.z


func _pick_roam_waypoint() -> Vector3:
	# До 6 попыток подобрать вейпойнт ВНЕ подземелья (туда нет навмеша — банда
	# застрянет о стены). Все попытки в данже → стоим (лучше, чем лезть в стену).
	for _i in range(6):
		var ang: float = randf() * TAU
		var dist: float = randf_range(roam_step_min, roam_step_max)
		var p := _anchor + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		p.x = clampf(p.x, -map_half_extent, map_half_extent)
		p.z = clampf(p.z, -map_half_extent, map_half_extent)
		p.y = _anchor.y
		if not _in_dungeon(p):
			return p
	return _anchor
