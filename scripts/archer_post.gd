class_name ArcherPost
extends StaticBody3D
## Стационарный пост лучника — стрелковая точка, которую игрок строит за
## ресурсы + 1 гнома. Пост стоит на месте, медленно сканирует конусом ±
## [scan_amplitude] вокруг базового направления и стреляет по скелетам в
## зоне видимости. Конус рассеивания тумана — длиннее, чем у мобильного
## защитника, но узкий: пост «прожектор» в один сектор, а не круглый
## наблюдатель.
##
## Архитектурно — не CampPart (Camp не двигает его, он не часть кольца) и
## не Gnome. Самостоятельный Node3D, привязанный к лагерю через массив
## Camp._archer_posts.
##
## Жизненный цикл:
##  - Camp._build_archer_post (DEPLOYED): инстанс, setup(pos, dir),
##    регистрация в _archer_posts.
##  - Pack: Camp вычищает массив → каждый пост queue_free + spawn gatherer'а
##    на месте поста (гном возвращается в караван).
##  - Скелет/магия может разрушить — destroyed.emit() → Camp слышит,
##    освобождает гнома (spawn gatherer на месте) и erase из массива.
##
## Урон/контракт:
##  - Damageable.register в _ready (take_damage / damaged / destroyed signal).
##  - SKELETON_TARGET_GROUP — скелеты агрятся на пост как на палатку.
##  - FogOfWar.FOG_REVEAL_GROUP — пост светит круг + конус через duck-type
##    свойства fog_reveal_radius / fog_reveal_cone_*.

signal damaged(amount: float)
signal destroyed

@export_group("Combat")
@export var hp_max: float = 80.0
@export var arrow_scene: PackedScene
@export var arrow_damage_min: float = 10.0
@export var arrow_damage_max: float = 16.0
@export var arrow_speed: float = 28.0
## Радиус разброса прицеливания (метры). Точка прицела случайно смещается
## внутри круга этого радиуса вокруг цели — uniform по площади (sqrt(randf())
## для корректной плотности). 0 = снайперский точный выстрел; 2-3м = ленивый
## пост на горизонте, частые промахи мимо ног. По образцу DefenderGnome.
@export var inaccuracy_radius: float = 0.15
## Дистанция, в которой пост видит цели и стреляет. Значительно больше, чем у
## мобильного защитника (22.5м) — пост сильно дальнобойный, half'а от своей
## fog-cone-длины (=90м) даёт «бьёт примерно до середины своего луча».
@export var attack_radius: float = 30.0
@export var attack_cooldown_min: float = 1.2
@export var attack_cooldown_max: float = 2.0
## Половина угла активного поиска целей (рад). Чуть шире, чем визуальный
## fog-конус (15°), чтобы пост успевал «среагировать» на цель, шагнувшую
## краем в его сектор и снапнуть голову. Дефолт π/9 ≈ 20°.
@export var attack_cone_half_angle: float = 0.35
@export_group("")

@export_group("Scan / animation")
## Половина амплитуды сканирования (рад). Голова качается между
## base_yaw − scan_amplitude и base_yaw + scan_amplitude. Дефолт ~20°.
@export_range(0.0, 1.5) var scan_amplitude: float = 0.35
## Угловая скорость сканирования (рад/с). 0.4 ≈ 23°/с — голова проходит
## полный размах ~1.7с, дающее ощущение «осматривается».
@export var scan_speed: float = 0.4
## Скорость доворота головы к текущему target_yaw (рад/с эффективно через
## exp-decay). Высокий rate — быстрый «снап»; низкий — медленное смятение.
## 3.0 = ~0.8с на 80% дистанции — голова неспешно следует за целью и плавно
## возвращается к зоне патруля после её гибели. Без exp-decay'я после
## убийства цель «пропадала» и голова мгновенно телепортировалась в base_yaw.
@export var head_turn_rate: float = 3.0
@export_group("")

@export_group("Vision (fog)")
## Половина раствора fog-конуса в градусах. Узкий и длинный — луч прожектора,
## а не широкий сектор. 15° → сектор 30°. Уже attack_cone_half_angle, чтобы
## attack «реагировал» чуть раньше, чем игрок видит цель в конусе.
@export var vision_cone_half_angle_deg: float = 9.0
## Длина fog-конуса в метрах. Должна заметно превышать camp/tower fog-радиусы
## (200/120м), иначе конус целиком тонет в их свете и не виден игроку. 90м —
## пост на краю build_zone (≈30м от центра) светит до 120м от центра, что
## вышибает за хард-кор camp'а (≈130м) в туманную дальнюю зону. Это даёт
## пост-разведчику смысл: разглядеть угрозу за «пределами лагеря».
@export var vision_cone_length: float = 38.0
## Маленький круг вокруг поста — пост видит ближайшее окружение независимо
## от того, куда сейчас смотрит. Иначе спина была бы слепой пятном.
@export var vision_circle_radius: float = 14.0
@export_group("")

const GROUP := &"archer_post"
const SKELETON_TARGET_GROUP := &"skeleton_target"
## ENEMIES (16) + COLD_ENEMY (128) — литералом, т.к. const не может ссылаться
## на другой class const (см. DefenderGnome.TARGET_MASK).
const TARGET_MASK: int = 16 | 128

## Период между сканами цели через PhysicsShapeQuery. 0.2с = 5Гц — пост
## стационарный, скан не критичен по cpu, но и постоянно сканить незачем.
const TARGET_SCAN_INTERVAL: float = 0.2

## Свойства для FogOfWar.FOG_REVEAL_GROUP. Обновляются в _physics_process по
## текущему направлению головы. Документация — см. FogOfWar.FOG_REVEAL_GROUP.
var fog_reveal_radius: float = 10.0
var fog_reveal_cone_half_angle: float = 0.0
var fog_reveal_cone_length: float = 0.0
var fog_reveal_cone_direction: Vector3 = Vector3.FORWARD

## Сколько секунд после получения alarm-сигнала пост держит alarm-цель как
## приоритетную. Если за это время никто из лагеря не атакован повторно — alarm
## сбрасывается, возвращаемся к обычному cone-scan.
const ALARM_PERSIST_SECONDS: float = 4.0

var _hp: float
## Базовый yaw, выставленный игроком при placement'е (радианы). Сканирование
## оссилирует вокруг этой оси. Локальный -Z головы при rotation.y = _base_yaw
## смотрит в направлении facing'а.
var _base_yaw: float = 0.0
## Фаза синусоиды сканирования. Растёт со временем; sin(phase) × scan_amplitude
## даёт мгновенное отклонение от _base_yaw.
var _scan_phase: float = 0.0
## Текущий применённый yaw головы. Плавно лёрпится к target_yaw через
## head_turn_rate. Это поле используется и для визуального вращения, и как
## forward-направление для cone-scan'а (см. _scan_cone_for_target) — детект
## следует за головой, поэтому по пути доворота пост может заметить новых
## врагов в перенаправленном секторе.
var _head_yaw: float = 0.0
var _scan_timer: float = 0.0
var _attack_timer: float = 0.0
var _cached_target: Node3D = null
var _destroyed: bool = false
## Камп, к которому привязан пост (для spawn'а арроу под current_scene и для
## clean-up'а на pack). Передаётся через setup().
var _camp: Camp = null
## Цель из тревоги — скелет, атакующий наш лагерь (или нас самих). Имеет
## приоритет над обычным cone-scan'ом. Игнорирует cone-фильтр (alarm-target
## считается «нашим долгом», даже если он сзади); проверяется только дистанция.
## Источник сигнала — EventBus.skeleton_attacked_camp.
var _alarm_target: Node3D = null
## Время (Time.get_ticks_msec) до которого считаем _alarm_target актуальным.
## После — alarm сбрасывается, возвращаемся к cone-scan'у.
var _alarm_until_msec: int = 0

## ТУРЕЛЬ-режим: пост встроен в другое здание (Защитный блиндаж, BunkerBlock).
## Тогда таргет/урон/коллизию/жизненный цикл держит ХОЗЯИН-здание, а пост — лишь
## лучник: НЕ регистрируется как Damageable/skeleton_target и отключает свою
## коллизию (иначе двойная цель + двойной коллайдер в одной ячейке). Скан/стрельба/
## fog/конус работают как обычно. Ставить ДО add_child (читается в _ready).
@export var embedded: bool = false

@onready var _head: Node3D = $Head
@onready var _arrow_spawn: Node3D = $Head/ArrowSpawn


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)
	# Standalone-пост — самостоятельная цель/коллайдер. Турель (embedded) — нет:
	# хозяин-блиндаж сам Damageable/препятствие, пост лишь стреляет.
	if not embedded:
		add_to_group(SKELETON_TARGET_GROUP)
		Damageable.register(self)
	else:
		var body_shape := get_node_or_null("BodyShape") as CollisionShape3D
		if body_shape != null:
			body_shape.disabled = true
	_hp = hp_max
	fog_reveal_radius = vision_circle_radius
	fog_reveal_cone_half_angle = deg_to_rad(vision_cone_half_angle_deg)
	fog_reveal_cone_length = vision_cone_length
	_attack_timer = randf_range(attack_cooldown_min, attack_cooldown_max)
	# Стартовая фаза рандомизирована — два соседних поста не сканируют
	# синхронно, иначе их «прожекторы» движутся параллельно и сектора смотрят
	# в одну и ту же точку → визуально как один пост.
	_scan_phase = randf() * TAU
	_build_cone_visual()
	# Per-instance материалы: материалы в archer_post.tscn — SubResource'ы,
	# расшаренные между ВСЕМИ инстансами поста. Без локализации _flash_damage()
	# модифицирует общий ресурс → все посты на сцене мигают красным при одном
	# попадании. Дублируем на старте, чтобы каждый имел свои.
	_localize_materials()
	# Сигнал EventBus.skeleton_attacked_camp — переключение на alarm-цель когда
	# атакуют нас или объект нашего лагеря. См. _on_skeleton_attacked_camp.
	EventBus.skeleton_attacked_camp.connect(_on_skeleton_attacked_camp)


## Дублирует material_override на каждом меше, который flash'ится при уроне.
## Без этого все посты с одной shared-материалкой мигают синхронно при ударе
## по одному из них (баг shared-SubResource).
func _localize_materials() -> void:
	var node_paths: Array[String] = ["PostLeg", "Platform", "Head/ArcherMesh"]
	for path in node_paths:
		var mesh := get_node_or_null(path) as MeshInstance3D
		if mesh == null:
			continue
		if mesh.material_override != null:
			mesh.material_override = mesh.material_override.duplicate()


func _exit_tree() -> void:
	if EventBus.skeleton_attacked_camp.is_connected(_on_skeleton_attacked_camp):
		EventBus.skeleton_attacked_camp.disconnect(_on_skeleton_attacked_camp)


## Спавнит видимый веер «луча прожектора» на земле перед постом. Triangle fan
## от точки под постом до арки на расстоянии vision_cone_length в направлении
## взгляда Head. Прикреплён к Head, поэтому крутится с тем же rotation.y, что
## и голова. Translucent additive материал — луч проявляется на тёмном фоне
## (туман), бледнеет на светлом (свет лагеря). Это даёт игроку явный визуал
## «куда смотрит пост» даже если fog-stamp уже перекрыт каким-то другим
## источником света.
func _build_cone_visual() -> void:
	if not is_instance_valid(_head):
		return
	var half_angle_rad: float = deg_to_rad(vision_cone_half_angle_deg)
	var length: float = vision_cone_length
	var arc_steps: int = 24
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	# Альфы намеренно очень низкие (0.0-0.05) — мы НЕ хотим видимый «веер», а
	# хотим тонкий призрачный намёк на «луч», который чуть-чуть подсвечивает
	# воздух перед постом. Главное визуальное событие — рассеивание тумана
	# конусом (FogOfWar paint_cone), а меш — лишь подсказка направления.
	#
	# Vertex 0 — origin под постом (локальные координаты Head'а: y=0 → world
	# y=2.5 при Head.position.y=2.5; нам нужно на земле, поэтому Y компенсируем
	# через offset MeshInstance3D.position).
	verts.push_back(Vector3.ZERO)
	colors.push_back(Color(1.0, 0.95, 0.65, 0.04))
	for i in range(arc_steps + 1):
		var t: float = float(i) / float(arc_steps)
		var a: float = lerp(-half_angle_rad, half_angle_rad, t)
		# Локальный -Z — «вперёд» Head'а (look_at convention). Веер строится
		# в плоскости Y=0 локального Head'а.
		var x: float = sin(a) * length
		var z: float = -cos(a) * length
		verts.push_back(Vector3(x, 0.0, z))
		# Кромка арки полностью прозрачная — луч «растворяется» в дали.
		colors.push_back(Color(1.0, 0.95, 0.65, 0.0))
	# Среднее кольцо: чуть-чуть подсветить (0.05) ось луча, чтобы было понятно
	# что это «направленный пучок», не размытое пятно. Раньше было 0.18 —
	# читалось как плотный жёлтый веер; для эффекта «луч рассекает туман»
	# нужно почти ничего.
	for i in range(arc_steps + 1):
		var t: float = float(i) / float(arc_steps)
		var a: float = lerp(-half_angle_rad, half_angle_rad, t)
		var x: float = sin(a) * length * 0.5
		var z: float = -cos(a) * length * 0.5
		verts.push_back(Vector3(x, 0.0, z))
		colors.push_back(Color(1.0, 0.95, 0.65, 0.05))
	# Триангуляция — два кольца триангл-фаном:
	# Кольцо 1: индексы [1 .. arc_steps+1] (arc_steps+1 точек на дальней арке)
	# Кольцо 2: индексы [arc_steps+2 .. 2*arc_steps+2] (мид-кольцо)
	# Origin = 0.
	# Треугольники для дальнего кольца идут от origin до arc-кромки через мид.
	var indices := PackedInt32Array()
	var mid_start: int = arc_steps + 2  # index of first mid-ring vertex
	# Inner fan: origin → mid-ring (треугольники между origin и серединой)
	for i in range(arc_steps):
		indices.push_back(0)
		indices.push_back(mid_start + i)
		indices.push_back(mid_start + i + 1)
	# Outer strip: mid-ring → far-ring (квад на каждый шаг арки, разбит на 2 треуг)
	for i in range(arc_steps):
		var mid_a: int = mid_start + i
		var mid_b: int = mid_start + i + 1
		var far_a: int = 1 + i
		var far_b: int = 1 + i + 1
		indices.push_back(mid_a)
		indices.push_back(far_a)
		indices.push_back(mid_b)
		indices.push_back(mid_b)
		indices.push_back(far_a)
		indices.push_back(far_b)
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.no_depth_test = false
	var mi := MeshInstance3D.new()
	mi.name = "ConeVisual"
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Head в сцене на y=2.5; нам нужно положить меш на землю (y≈0.06 чтобы
	# не z-fight'иться с Ground'ом). Локальный offset от Head — (0, -2.44, 0).
	mi.position = Vector3(0.0, -2.44, 0.0)
	_head.add_child(mi)


## Размещение поста: позиция + направление (XZ). facing — единичный вектор
## (или ненормализованный, мы сами нормализуем). Вызывается Camp'ом сразу
## после instantiate().
func setup(world_pos: Vector3, facing: Vector3, camp: Camp) -> void:
	global_position = world_pos
	_camp = camp
	var dir := facing
	dir.y = 0.0
	if dir.length_squared() < VecUtil.EPSILON_SQ:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	# Локальный -Z головы при rotation.y = θ смотрит в (-sin θ, 0, -cos θ).
	# Решаем -sin θ = dir.x, -cos θ = dir.z → θ = atan2(-dir.x, -dir.z).
	_base_yaw = atan2(-dir.x, -dir.z)
	_head_yaw = _base_yaw  # стартуем с целевого направления, без доворота
	if is_instance_valid(_head):
		_head.rotation.y = _head_yaw
	_update_fog_cone_dir(_head_yaw)


func take_damage(amount: float) -> void:
	if _destroyed or amount <= 0.0:
		return
	_hp -= amount
	damaged.emit(amount)
	_flash_damage()
	if LogConfig.master_enabled:
		print("[ArcherPost:damage] amount=%.1f hp=%.1f/%.1f" % [amount, maxf(_hp, 0.0), hp_max])
	if _hp <= 0.0:
		_destroyed = true
		destroyed.emit()
		queue_free()


## Краткий красный flash на меше при получении урона. Берёт material_override
## у MeshInstance3D-детей (Platform, PostLeg, ArcherMesh, ArrowShaft) и
## tween-ом эмиссию +→0. Каждый сам владеет своим material_override, и
## flash работает на каждом параллельно.
func _flash_damage() -> void:
	# Список меш-нод, которые подсвечиваем. PostLeg + Platform — корпус
	# вышки; ArcherMesh — сам лучник.
	var node_paths: Array[String] = ["PostLeg", "Platform", "Head/ArcherMesh"]
	for path in node_paths:
		var mesh := get_node_or_null(path) as MeshInstance3D
		if mesh == null:
			continue
		var mat := mesh.material_override as StandardMaterial3D
		if mat == null:
			continue
		# Стартовое значение emission — что было до flash'а. Tween возвращает
		# к нему. Если у материала нет emission_enabled, форсим on.
		if not mat.emission_enabled:
			mat.emission_enabled = true
		var orig_emission: Color = mat.emission
		var orig_mult: float = mat.emission_energy_multiplier
		mat.emission = Color(1.0, 0.2, 0.2, 1.0)
		mat.emission_energy_multiplier = 2.5
		var tween := create_tween()
		tween.tween_property(mat, "emission", orig_emission, 0.18)
		tween.parallel().tween_property(mat, "emission_energy_multiplier", orig_mult, 0.18)


func _physics_process(delta: float) -> void:
	if _destroyed:
		return
	_tick_scan_animation(delta)
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = TARGET_SCAN_INTERVAL
		_refresh_target()
	_attack_timer -= delta
	if _cached_target != null and is_instance_valid(_cached_target) and _attack_timer <= 0.0:
		# Голова сама уже доворачивается к цели через _tick_scan_animation
		# (cached_target → target_yaw), отдельный _aim_head_at не нужен.
		_fire_at(_cached_target)
		_attack_timer = randf_range(attack_cooldown_min, attack_cooldown_max)


## Обновляет вращение головы. Сначала вычисляем target_yaw по приоритету
## (alarm / cached-target / scan), затем плавно лёрпим _head_yaw к нему
## через head_turn_rate. Никаких snap'ов — пост ВСЁ ВРЕМЯ пока цель жива
## смотрит на неё (не возвращается на патруль между выстрелами), и только
## когда цель умерла/ушла — плавно возвращается к sin-scan'у вокруг base_yaw.
##
## Приоритет target_yaw:
##   1. alarm — направление на alarm-цель (даже если за спиной).
##   2. cached_target — следим за текущей целью между выстрелами (так пост
##      не «дёргается» обратно на патруль в окне cooldown'а).
##   3. scan — sin-оссилирует _base_yaw ± scan_amplitude.
func _tick_scan_animation(delta: float) -> void:
	var target_yaw: float
	var alarm: Node3D = _resolve_alarm_target()
	if alarm != null:
		target_yaw = _yaw_to_node(alarm)
	elif _cached_target != null and is_instance_valid(_cached_target):
		# Цель жива — голова продолжает на неё смотреть весь cooldown.
		# Это убирает «вылет на патруль между выстрелами»: пост стоит
		# прицеленным до тех пор, пока не убьёт или цель не выйдет из конуса.
		target_yaw = _yaw_to_node(_cached_target)
	else:
		_scan_phase += scan_speed * delta
		target_yaw = _base_yaw + sin(_scan_phase) * scan_amplitude
	# Smooth lerp _head_yaw → target_yaw. exp-decay даёт frame-rate-independent
	# плавность. lerp_angle работает с круговой топологией yaw'а (короткий путь).
	var decay: float = 1.0 - exp(-head_turn_rate * delta)
	_head_yaw = lerp_angle(_head_yaw, target_yaw, decay)
	if is_instance_valid(_head):
		_head.rotation.y = _head_yaw
	_update_fog_cone_dir(_head_yaw)


## Yaw в радианах от поста к указанной ноде. Если node на нашей позиции
## (artifact) — возвращает _base_yaw как fallback.
func _yaw_to_node(node: Node3D) -> float:
	var to_t: Vector3 = node.global_position - global_position
	to_t.y = 0.0
	if to_t.length_squared() < VecUtil.EPSILON_SQ:
		return _base_yaw
	var dir: Vector3 = to_t.normalized()
	return atan2(-dir.x, -dir.z)


## Конвертирует текущий yaw в Vector3 направление и записывает в fog-свойство.
## FogOfWar читает раз в тик (10Гц), наш записываемый темп быстрее (60Гц) —
## это OK, лишняя запись копейки.
func _update_fog_cone_dir(yaw: float) -> void:
	fog_reveal_cone_direction = Vector3(-sin(yaw), 0.0, -cos(yaw))


## Выбирает цель по приоритету:
##  1. Alarm-цель (атакующий лагерь/нас самих) — игнорирует cone-фильтр, только
##     дистанция. Это позволяет посту «развернуться» в сторону тревоги.
##  2. Текущая цель, если ещё жива и в attack-зоне (конус + дистанция).
##     Пост залипает на одну цель — не «прыгает» между скелетами каждый скан.
##  3. Cone-scan: ближайший damageable в attack-конусе.
##
## Дизайнерское решение (2026-05-18): пост — не патрульный стрелок, а упрямый
## часовой; раз увидел — стреляет в неё пока не убьёт или не сменит alarm.
func _refresh_target() -> void:
	# Приоритет 1: alarm. Игнорирует cone-фильтр (alarm-target может быть
	# сзади — это и есть смысл тревоги), но требует в attack_radius.
	var alarm: Node3D = _resolve_alarm_target()
	if alarm != null and _is_target_in_attack_range(alarm):
		_cached_target = alarm
		return
	# Приоритет 2: keep current если ещё в зоне.
	if _cached_target != null and is_instance_valid(_cached_target):
		if _is_target_in_attack_zone(_cached_target):
			return
	# Приоритет 3: ищем нового через cone-scan.
	_cached_target = _scan_cone_for_target()


## True если cached/alarm-target в attack_radius и в attack-конусе вокруг
## ТЕКУЩЕГО _head_yaw (не _base_yaw — детект следует за головой). Используется
## для проверки, можно ли продолжать стрелять в цель (она могла выйти за
## конус или отбежать), а также для распознавания новых целей во время
## плавного доворота головы.
func _is_target_in_attack_zone(node: Node3D) -> bool:
	if not is_instance_valid(node):
		return false
	var to_t: Vector3 = node.global_position - global_position
	to_t.y = 0.0
	var d_sq: float = to_t.length_squared()
	if d_sq < VecUtil.EPSILON_SQ or d_sq > attack_radius * attack_radius:
		return false
	var d: float = sqrt(d_sq)
	var head_forward: Vector3 = Vector3(-sin(_head_yaw), 0.0, -cos(_head_yaw))
	var cos_theta: float = to_t.dot(head_forward) / d
	return cos_theta >= cos(attack_cone_half_angle)


## True если цель просто в attack_radius (без cone-фильтра). Используется для
## alarm-цели — пост готов стрелять в неё даже если она вне обычного сектора.
func _is_target_in_attack_range(node: Node3D) -> bool:
	if not is_instance_valid(node):
		return false
	var to_t: Vector3 = node.global_position - global_position
	to_t.y = 0.0
	var d_sq: float = to_t.length_squared()
	return d_sq > VecUtil.EPSILON_SQ and d_sq <= attack_radius * attack_radius


## Cone-scan: ищет ближайшую damageable-цель в attack-конусе вокруг ТЕКУЩЕГО
## _head_yaw (не _base_yaw). Это значит конус следует за головой — во время
## плавного доворота от alarm-цели обратно к зоне патруля пост сканирует
## промежуточные углы и может «подобрать» нового врага по пути.
func _scan_cone_for_target() -> Node3D:
	var space := get_world_3d().direct_space_state
	if space == null:
		return null
	var shape := SphereShape3D.new()
	shape.radius = attack_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), global_position)
	query.collision_mask = TARGET_MASK
	query.collide_with_bodies = true
	var results := space.intersect_shape(query, 32)
	var head_forward := Vector3(-sin(_head_yaw), 0.0, -cos(_head_yaw))
	var cos_half := cos(attack_cone_half_angle)
	var best: Node3D = null
	var best_dist_sq: float = INF
	for r in results:
		var collider = r.collider
		if collider == null or not (collider is Node3D):
			continue
		if not Damageable.is_damageable(collider):
			continue
		var node := collider as Node3D
		var to_t := node.global_position - global_position
		to_t.y = 0.0
		var d_sq := to_t.length_squared()
		if d_sq < VecUtil.EPSILON_SQ:
			continue
		var d := sqrt(d_sq)
		if d > attack_radius:
			continue
		var cos_theta: float = to_t.dot(head_forward) / d
		if cos_theta < cos_half:
			continue
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			best = node
	return best


## Возвращает текущую alarm-цель, если она ещё валидна и не истекла. Иначе
## сбрасывает _alarm_target в null и возвращает null. Lazy-cleanup —
## без таймера, проверка при каждом запросе.
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


## EventBus.skeleton_attacked_camp хендлер. Триггерит тревогу если скелет
## ударил кого-то из нашего лагеря (палатку, гнома, или нас самих).
func _on_skeleton_attacked_camp(attacker: Node3D, victim: Node3D, _position: Vector3) -> void:
	if attacker == null or victim == null:
		return
	if not is_instance_valid(attacker) or not is_instance_valid(victim):
		return
	if not _is_victim_ours(victim):
		return
	_alarm_target = attacker
	_alarm_until_msec = Time.get_ticks_msec() + int(ALARM_PERSIST_SECONDS * 1000.0)


## True если victim — часть нашего лагеря: сам пост, палатка нашего Camp'а,
## или гном нашего Camp'а. Симметрично фильтру DefenderGnome._on_skeleton_attacked_camp.
func _is_victim_ours(victim: Node3D) -> bool:
	if victim == self:
		return true
	if _camp == null or not is_instance_valid(_camp):
		return false
	if victim is CampPart and victim.get_parent() == _camp:
		return true
	if victim.is_in_group(Gnome.GNOME_GROUP) and victim in _camp.get_gnomes():
		return true
	return false


## Спавнит Arrow, ориентированную по баллистике на цель. С разбросом прицела
## inaccuracy_radius (метры) — пост не снайпер, он часто мажет вокруг цели.
## По образцу DefenderGnome._fire_at.
func _fire_at(target: Node3D) -> void:
	if arrow_scene == null:
		push_warning("ArcherPost: arrow_scene не задан")
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		push_warning("ArcherPost: arrow_scene не инстанцируется как Arrow")
		return
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_tree().root
	parent.add_child(arrow)
	var damage: float = randf_range(arrow_damage_min, arrow_damage_max)
	var spawn: Vector3 = _arrow_spawn.global_position if is_instance_valid(_arrow_spawn) else global_position + Vector3.UP * 2.0
	# Разброс прицела: случайная точка в круге inaccuracy_radius вокруг цели.
	# sqrt(randf()) — uniform по площади (без sqrt плотность к центру выше).
	var aim_pos: Vector3 = target.global_position
	if inaccuracy_radius > 0.0:
		var angle: float = randf() * TAU
		var r: float = sqrt(randf()) * inaccuracy_radius
		aim_pos.x += cos(angle) * r
		aim_pos.z += sin(angle) * r
	arrow.damage = damage
	arrow.speed = arrow_speed
	arrow.setup(spawn, aim_pos)
