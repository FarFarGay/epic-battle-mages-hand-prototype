class_name ArcherGroup
extends Node3D
## Группа из N скелетов-лучников, действующих как формация. Координатор не
## управляет FSM лучников напрямую — он синхронизирует:
##  - стартовый scan_timer (фазы выровнены → все одновременно перейдут в WINDUP)
##  - forced_target (одна цель на всех)
##  - стартовые позиции в квадратной формации вокруг центра группы
##
## Это даёт visual «залп 4 стрел почти в один кадр» через естественную
## синхронность одинаковых FSM-таймеров. inaccuracy каждого даёт рассев →
## 4 стрелы покрывают зону вместо точечного огня.
##
## Лучники после спавна — самостоятельные SkeletonArcher, kite-логика их
## собственная. Если один умрёт — остальные продолжают как индивиды (группа
## не пересобирается). Если все 4 мертвы — ArcherGroup queue_free.

@export var archer_scene: PackedScene = null
@export var archer_count: int = 4
## Расстояние между лучниками в формации (квадрат N=2 на сторону = 2×2). Не
## слишком близко иначе они «жмутся», не слишком далеко иначе залп размазан.
@export var formation_spacing: float = 1.6
## Радиус ОБЩЕЙ зоны выстрела группы — большой ground-ring, который рисует
## группа (не отдельные лучники). 4 стрелы падают рандомно ВНУТРИ этого
## радиуса. Визуально читается как «обстрел зоны».
@export var group_ring_radius: float = 4.0
## Цвет общего ring'а.
@export var group_ring_color: Color = Color(0.7, 0.3, 0.95, 0.85)

## Общая цель для группы. Назначается извне (cheat / spawn-логика) через
## set_forced_target. Передаётся каждому лучнику.
var _forced_target: Node3D = null

var _archers: Array[SkeletonArcher] = []


func _ready() -> void:
	_spawn_archers()


## Cheat / wave-логика зовёт после spawn, чтобы задать цель залпа. Дублирует
## контракт SkeletonArcher.set_forced_target — caller может писать в группу
## или в отдельного лучника одинаково (duck-type через has_method).
func set_forced_target(target: Node3D) -> void:
	_forced_target = target
	for a in _archers:
		if is_instance_valid(a):
			a.set_forced_target(target)


func _spawn_archers() -> void:
	if archer_scene == null:
		push_warning("ArcherGroup: archer_scene не задан")
		return
	# Квадратная формация: 2×2 для archer_count=4, иначе линия.
	var grid_n: int = int(round(sqrt(float(archer_count))))
	if grid_n * grid_n != archer_count:
		grid_n = 1  # fallback на линию
	for i in range(archer_count):
		var offset: Vector3 = _grid_offset(i, grid_n)
		var archer := archer_scene.instantiate() as SkeletonArcher
		if archer == null:
			push_warning("ArcherGroup: archer_scene не инстанцируется как SkeletonArcher")
			continue
		# Парент в текущую сцену, не в саму группу — иначе при queue_free
		# группы лучники уйдут с ней. Они должны жить независимо.
		get_tree().current_scene.add_child(archer)
		archer.global_position = global_position + offset
		# Синхронизация phase: scan_timer всех в 0 → следующий vision-rescan
		# одновременный → переходы APPROACH→WINDUP синхронные. Также
		# attack_cooldown один на всех — после первого strike все 4 ждут
		# одинаково, следующий strike тоже синхронный.
		archer._scan_timer = 0.0
		# has_telegraph=false: индивидуальные ring'и отключены, общий рисует
		# группа в _coordinate_volley. inaccuracy не используется (group
		# подменяет _telegraphed_aim перед strike).
		archer.has_telegraph = false
		# Personal offset формации, чтобы они не кучковались при подходе к цели.
		# Тот же квадрат что и spawn (4 разные точки вокруг target.position).
		archer.formation_offset = offset
		if _forced_target != null and is_instance_valid(_forced_target):
			archer.set_forced_target(_forced_target)
		_archers.append(archer)


## Smoothed grid offset для квадрата grid_n×grid_n. Center of group = (0,0).
## Для grid_n=2 даёт 4 точки: (-d, -d), (+d, -d), (-d, +d), (+d, +d).
func _grid_offset(idx: int, grid_n: int) -> Vector3:
	var row: int = idx / grid_n
	var col: int = idx % grid_n
	var center_offset: float = (float(grid_n) - 1.0) * 0.5
	var dx: float = (float(col) - center_offset) * formation_spacing
	var dz: float = (float(row) - center_offset) * formation_spacing
	return Vector3(dx, 0.0, dz)


## Состояния координации залпа группы:
##  - READY: лучники в APPROACH/COOLDOWN, ring погашен.
##  - WINDUP: спавнен общий ring, лучники в WINDUP-фазе, ждут strike.
##  - STRIKE_DONE: лучники отстреляли, ждём их COOLDOWN перед следующим залпом.
enum GroupPhase { READY, WINDUP, STRIKE_DONE }
var _group_phase: int = GroupPhase.READY


const ALIVE_CHECK_INTERVAL: float = 1.0
var _alive_check_timer: float = 0.0


func _process(delta: float) -> void:
	_coordinate_volley()
	_alive_check_timer -= delta
	if _alive_check_timer > 0.0:
		return
	_alive_check_timer = ALIVE_CHECK_INTERVAL
	var any_alive: bool = false
	for a in _archers:
		if is_instance_valid(a):
			any_alive = true
			break
	if not any_alive:
		queue_free()


## FSM координации залпа. Проверяет state лучников каждый кадр (дёшево —
## 4 цикла). Спавнит общий ring когда первый archer вошёл в WINDUP, ставит
## каждому _telegraphed_aim внутри ring'а (личный рассев) — на STRIKE стрелы
## летят в свои точки, но визуально в одну общую зону.
func _coordinate_volley() -> void:
	var any_windup: bool = false
	var any_strike_or_cd: bool = false
	var target: Node3D = null
	for a in _archers:
		if not is_instance_valid(a):
			continue
		match a._state:
			Enemy.AttackState.WINDUP:
				any_windup = true
				if target == null:
					target = a._cached_target if is_instance_valid(a._cached_target) else (a._forced_target if is_instance_valid(a._forced_target) else null)
			Enemy.AttackState.STRIKE, Enemy.AttackState.COOLDOWN:
				any_strike_or_cd = true

	match _group_phase:
		GroupPhase.READY:
			if any_windup and target != null:
				_begin_group_volley(target)
		GroupPhase.WINDUP:
			# Перешли в STRIKE/COOLDOWN — стрелы выпущены, ring уже умирает
			# по своему таймеру (extended на flight time).
			if any_strike_or_cd and not any_windup:
				_group_phase = GroupPhase.STRIKE_DONE
		GroupPhase.STRIKE_DONE:
			# Все вернулись в APPROACH/READY — готовы к следующему циклу.
			if not any_strike_or_cd and not any_windup:
				_group_phase = GroupPhase.READY


## Спавн общего ring + раздача персональных aim точек по 4 лучникам.
## Aim каждого = центр_зоны + случайная точка в радиусе group_ring_radius.
## Длительность ring'а = первый_archer.attack_windup + полётное время (запас).
func _begin_group_volley(target: Node3D) -> void:
	if not is_instance_valid(target):
		return
	var first_archer: SkeletonArcher = null
	for a in _archers:
		if is_instance_valid(a):
			first_archer = a
			break
	if first_archer == null:
		return
	var center: Vector3 = target.global_position
	center.y = 0.0
	# Длительность ring'а: windup + ожидание полёта. Полёт = grossly
	# attack_radius_max / arrow_speed + safety. Это удлиняет ring так чтобы
	# он жил до момента импакта (запрос пользователя: не убирать ДО столкновения).
	var flight_time_estimate: float = first_archer.attack_radius_max / max(first_archer.arrow_speed, 1.0) + 0.6
	var ring_duration: float = first_archer.attack_windup + flight_time_estimate
	var root: Node = get_tree().current_scene
	if is_instance_valid(root):
		AoeVisual.spawn_ground_ring(root, center, group_ring_radius, ring_duration, group_ring_color)
	# Раздаём каждому archer'у его персональную точку внутри ring'а.
	for a in _archers:
		if not is_instance_valid(a):
			continue
		var aim: Vector3 = center
		var angle: float = randf() * TAU
		var r: float = sqrt(randf()) * group_ring_radius
		aim.x += cos(angle) * r
		aim.z += sin(angle) * r
		a._telegraphed_aim = aim
	_group_phase = GroupPhase.WINDUP
