class_name Mine
extends StaticBody3D
## Мина-ловушка. Спавнится в воздухе от burst'а carrier'а (см. HandSpellMineScatter),
## падает на землю, после arming-задержки превращается в триггер.
##
## Жизненный цикл (FSM):
##   FALLING — летит с начальной velocity + gravity, пока не достигнет y ≈ 0.
##             Area3D отключена — чтоб не сдетонировать на воздушные коллизии
##             (соседняя мина, прохожий гном).
##   ARMING — приземлилась. arming_delay секунд защищает от само-цепной
##            реакции и от уже стоящих врагов в момент установки.
##   ARMED — Area3D активна. На body_entered (любой в trigger_mask) — взрыв.
##           Также Damageable: любой урон в ARMED-фазе детонирует (Slam,
##           Fireball AOE, Firestorm, Super, BurnPatch tick) — принцип
##           симметрии взаимодействий 2026-05-15.
##
## Friendly-fire ON по дизайну: trigger_mask включает и ENEMIES и FRIENDLY_UNIT.
## Стратегический вес — игрок думает куда кидает.
##
## Mine.tscn: StaticBody3D на собственном слое MINE_HAZARD (видим для всех
## AOE-сил которые маскируют этот слой — Slam, Fireball, Firestorm, Super,
## BurnPatch — все через MASK_HAND_SLAM, в которую с 2026-05-15 включён
## MINE_HAZARD) + BodyShape (CylinderShape для damage-сканов) +
## MeshInstance3D + Area3D TriggerArea (proximity-trigger зона).
##
## Почему отдельный слой, а не ITEMS: Tower (mask=575) сканирует ITEMS чтобы
## физически толкать ящики/кучи — но тогда же врезается и в мины как в стены.
## MINE_HAZARD не в маске Tower (и не в Skeleton.mask) → башня и скелеты
## физически проходят сквозь мины, триггер срабатывает только через Area3D
## (или AOE shape-query от огневых сил).

enum Phase { FALLING, ARMING, ARMED }

@export var damage: float = 30.0
@export var aoe_radius: float = 1.8
## Задержка между приземлением и активацией триггера. Защищает от ситуаций
## когда мина детонирует на собственное падение / соседнюю мину в одной
## волне burst'а / врага уже стоящего в точке падения.
@export var arming_delay: float = 0.5
## Гравитация во время FALLING. Сильно больше мировой 9.8 — мины падают
## агрессивно, чтоб геймплейная пауза «летит-падает» была короткая и
## ракеты ощущались мощно. HandSpellMineScatter передаёт совпадающее
## значение через .gravity при спавне; если меняешь дефолт здесь —
## синхронизируй с HandSpellMineScatter.mine_gravity.
@export var gravity: float = 22.0
## Скорость падения, начиная с которой считаем что приземлились (порог
## для «коснулась земли»). Без этого мины с малой y-velocity вечно
## дрейфуют над y=0.
@export var ground_y: float = 0.05
## Маска для триггера (что вызывает детонацию, войдя в proximity-Area). Скелеты,
## гномы И башня/постройки/палисад: башня ездит и может наехать на мину, а
## scatter-мины падают где угодно (в т.ч. на здание) — всё физическое реагирует
## на мину, без хардкод-исключений (принцип симметрии взаимодействий). Урон от
## взрыва эти же цели и так получают (см. aoe_damage_mask). = 948.
@export_flags_3d_physics var trigger_mask: int = Layers.ENEMIES | Layers.COLD_ENEMY | Layers.FRIENDLY_UNIT | Layers.ACTORS | Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE
## Маска для AoE damage в момент взрыва. Шире чем trigger — мина бьёт всё
## что рядом, не только то что её активировало. Включает Tower и постройки —
## friendly fire by design (дизайнерское решение 2026-05-13). С 2026-05-15
## добавлен MINE_HAZARD — взрыв одной мины повреждает соседние, цепная
## реакция (мины Damageable, ARMED-мина в радиусе взрыва сама детонирует).
## ITEMS оставлен чтобы взрыв задевал ResourcePile/Item-боксы рядом.
@export_flags_3d_physics var aoe_damage_mask: int = Layers.ENEMIES | Layers.COLD_ENEMY | Layers.FRIENDLY_UNIT | Layers.ACTORS | Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE | Layers.ITEMS | Layers.MINE_HAZARD

@export_group("Visual")
## Скорость мигания в ARMED-фазе (циклы в секунду × 2π → радиан/сек).
## 8.0 ≈ 1.27 циклов/сек — заметно но не агрессивно. Только в ARMED:
## в FALLING/ARMING мина не мигает (не сбивает игрока).
@export var armed_blink_rate: float = 8.0
## Множитель пика emission во время мигания: emission_energy = base × (1 + pulse × peak).
## pulse колеблется 0..1, поэтому на пике emission = base × (1 + peak), в минимуме = base.
@export var armed_blink_peak: float = 3.0

@export_group("")
@export var debug_log: bool = false

@onready var _trigger_area: Area3D = $TriggerArea
@onready var _mesh: MeshInstance3D = $MeshInstance3D

var _phase: int = Phase.FALLING
var _velocity: Vector3 = Vector3.ZERO
var _arming_timer: float = 0.0
## Idempotency guard для _explode. Без него цепная реакция мин могла бы
## дважды детонировать одну мину в одном кадре (chain через aoe_damage_mask
## между перекрывающимися минами).
var _exploded: bool = false
## Per-instance дубликат материала. Без duplicate'а мигание у одной мины
## мигало бы у всех (StandardMaterial3D шарится между инстансами сцены).
var _material: StandardMaterial3D = null
var _base_emission_energy: float = 0.6
var _blink_timer: float = 0.0
## Радиус² triggerArea sphere (кэшированный) для FAR-LOD скелет fallback'а
## в ARMED-фазе. FAR-скелеты имеют collision_layer=0 и CollisionShape3D.disabled
## (см. SPEC §5.5.2 LOD), Area3D их не видит — догоняем group-scan'ом каждые
## FAR_SCAN_INTERVAL секунд. Кэшируется в _ready из CollisionShape3D.shape.
var _trigger_radius_sq: float = 0.36  # дефолт 0.6² на случай отсутствия shape
const FAR_SCAN_INTERVAL: float = 0.2
var _far_scan_timer: float = 0.0


## Зовётся спавнером сразу после instantiate+add_child. Задаёт стартовую
## позицию в воздухе и initial velocity (от burst-разлёта).
func setup(spawn_pos: Vector3, initial_velocity: Vector3) -> void:
	global_position = spawn_pos
	_velocity = initial_velocity


func _ready() -> void:
	# Damageable: ARMED-мина детонирует от любого источника урона
	# (Slam, Fireball AOE, Firestorm shot, Super payload, BurnPatch tick).
	# Принцип симметрии — урон по мине = триггер взрыва, без специальных
	# случаев per-source. См. take_damage.
	Damageable.register(self)
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = trigger_mask
	# monitoring=true с самого начала. Гейт по _phase в _on_body_entered
	# отсекает срабатывания в FALLING/ARMING. Раньше monitoring стартовал
	# в false и включался при ARMED — но Area3D.body_entered не fire'ится
	# для уже-перекрывающихся тел на момент включения мониторинга. Скелет,
	# вошедший в зону за время ARMING (≤0.5с), оставался «невидимым» для
	# триггера до тех пор, пока не выйдет и не вернётся. На переходе в
	# ARMED делаем явный sweep по get_overlapping_bodies (см. _physics_process).
	_trigger_area.monitoring = true
	_trigger_area.body_entered.connect(_on_body_entered)
	# Per-instance дубликат материала для независимого мигания. Запоминаем
	# базовый emission_energy_multiplier — основа для пульсации в ARMED.
	if _mesh != null and _mesh.material_override is StandardMaterial3D:
		var src := _mesh.material_override as StandardMaterial3D
		_base_emission_energy = src.emission_energy_multiplier
		_material = src.duplicate() as StandardMaterial3D
		_mesh.material_override = _material
	# Кэшируем радиус² триггер-сферы для FAR-LOD скелет fallback'а.
	var trigger_shape_node := _trigger_area.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if trigger_shape_node != null:
		var sphere := trigger_shape_node.shape as SphereShape3D
		if sphere != null:
			_trigger_radius_sq = sphere.radius * sphere.radius


func _physics_process(delta: float) -> void:
	match _phase:
		Phase.FALLING:
			_velocity.y -= gravity * delta
			global_position += _velocity * delta
			if global_position.y <= ground_y:
				global_position.y = ground_y
				_velocity = Vector3.ZERO
				_phase = Phase.ARMING
				_arming_timer = arming_delay
				if debug_log and LogConfig.master_enabled:
					print("[Mine] приземлилась @ (%.1f, %.1f), arming %.1fс" % [
						global_position.x, global_position.z, arming_delay,
					])
		Phase.ARMING:
			_arming_timer -= delta
			if _arming_timer <= 0.0:
				_phase = Phase.ARMED
				if debug_log and LogConfig.master_enabled:
					print("[Mine] вооружена @ (%.1f, %.1f)" % [global_position.x, global_position.z])
				# Body_entered не fire'ится для тел, уже стоящих в зоне на
				# момент перехода в ARMED. Явно сканируем текущие overlaps —
				# если кто-то уже внутри (например, скелет, прошедший через
				# точку приземления за время ARMING), детонируем сразу.
				for b in _trigger_area.get_overlapping_bodies():
					if is_instance_valid(b):
						_explode()
						return
		Phase.ARMED:
			# Мигание emission'а — сигнал «я вооружена». sin(t) ∈ [-1,1] → pulse ∈ [0,1].
			# emission_energy = base × (1 + pulse × peak), от base до base × (1 + peak).
			_blink_timer += delta
			if _material != null:
				var pulse: float = sin(_blink_timer * armed_blink_rate) * 0.5 + 0.5
				_material.emission_energy_multiplier = _base_emission_energy * (1.0 + pulse * armed_blink_peak)
			# FAR-LOD скелеты вне broad-phase — Area3D их не ловит. Догоняем
			# group-scan'ом каждые FAR_SCAN_INTERVAL секунд (см. поле выше).
			# Параллельный паттерн со Slam.FAR-fallback'ом (hand_physical_slam.gd).
			_far_scan_timer -= delta
			if _far_scan_timer <= 0.0:
				_far_scan_timer = FAR_SCAN_INTERVAL
				_check_far_skeleton_trigger()


func _on_body_entered(_body: Node) -> void:
	if _phase != Phase.ARMED:
		return
	_explode()


## Damageable-контракт. Любой источник урона (Slam, Fireball, Firestorm, Super,
## BurnPatch tick, цепной взрыв соседней мины) в ARMED-фазе детонирует мину.
## В FALLING/ARMING — no-op (мина ещё «не активна», иначе burst-волна сама
## могла бы сдетонировать соседок mid-fall'е, ломая весь паттерн раскидывания).
func take_damage(amount: float) -> void:
	if amount <= 0.0:
		return
	if _phase == Phase.ARMED:
		_explode()


## Group-scan FAR-LOD скелетов в радиусе триггера. Параллельно с body_entered'ом
## (NEAR/MID скелеты ловятся им через Area3D). На любом hit'е — детонация.
## Per-mine raз в FAR_SCAN_INTERVAL (0.2с) → дешёво даже на 2000 скелетов
## (всё та же 0.05мс распределённая на 5Hz).
func _check_far_skeleton_trigger() -> void:
	var origin: Vector3 = global_position
	for n in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		var skel := n as Skeleton
		if skel == null:
			continue
		if skel.get_lod_level() != Skeleton.LodLevel.FAR:
			continue
		var d_sq: float = (skel.global_position - origin).length_squared()
		if d_sq <= _trigger_radius_sq:
			_explode()
			return


## AoE-взрыв: ShapeQuery радиусом aoe_radius, damage всем Damageable
## в области. Эмитит exploded + queue_free. Идемпотентно через _exploded —
## цепная реакция от соседних мин не вызывает повторного _explode.
func _explode() -> void:
	if _exploded:
		return
	_exploded = true
	# Основной AOE через shared util (sphere-query + radius²-filter +
	# Damageable.try_damage). Раньше логика жила локально без radius²-filter'а —
	# теперь AOE строго в радиусе, AABB-broadphase подмешивание отсекается.
	var hits: Array[Node] = AoeDamage.apply_uniform(get_tree(), global_position,
		aoe_radius, aoe_damage_mask, damage, 0.0, 0.0, 32)
	var hit_count: int = hits.size()
	# FAR-LOD скелеты вне broad-phase, shape-query их не находит. Группа +
	# distance²-фильтр — тот же паттерн, что в HandPhysicalSlam.FAR-fallback.
	var aoe_radius_sq: float = aoe_radius * aoe_radius
	var far_hits: int = 0
	for n in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		var skel := n as Skeleton
		if skel == null:
			continue
		if skel.get_lod_level() != Skeleton.LodLevel.FAR:
			continue
		var d_sq: float = (skel.global_position - global_position).length_squared()
		if d_sq > aoe_radius_sq:
			continue
		Damageable.try_damage(skel, damage)
		hit_count += 1
		far_hits += 1
	if debug_log and LogConfig.master_enabled:
		print("[Mine:explode] @ (%.1f, %.1f, %.1f) hit=%d targets (FAR: %d), damage=%.0f r=%.1f" % [
			global_position.x, global_position.y, global_position.z, hit_count, far_hits, damage, aoe_radius,
		])
	# Взрыв-VFX: полный fire-explosion (отличается от приземления — мина именно
	# сдетонировала, не «прилетела с пылью»). Спавним в parent (current_scene),
	# чтоб эффект пережил queue_free сам ой мины.
	var fx_root: Node = get_parent()
	if fx_root != null:
		AoeVisual.spawn_explosion(fx_root, global_position, aoe_radius)
	# Fog reveal: радиус ×7 от aoe (≈13м при aoe=1.8). Длительность раскрытия
	# вычисляется от FogOfWar.PULSE_SPREAD_SPEED — фронт тумана движется со
	# скоростью м/с, той же что у spark-частиц. Симметрично fireball._explode.
	var mine_pulse_radius: float = aoe_radius * 7.0
	var speed: float = FogOfWar.PULSE_SPREAD_SPEED
	var grow_ticks: int = maxi(1, int(ceil(mine_pulse_radius / speed / 0.1)))
	var total_ticks: int = grow_ticks + 1
	FogOfWar.pulse_reveal(global_position, mine_pulse_radius, total_ticks, grow_ticks)
	# Искры-разлёт «горения» только до aoe_radius (damage-зона). Скорость
	# совпадает с фронтом тумана — оба фронта движутся синхронно.
	if fx_root != null:
		AoeVisual.spawn_pulse_sparks(fx_root, global_position, aoe_radius, speed)
	queue_free()
