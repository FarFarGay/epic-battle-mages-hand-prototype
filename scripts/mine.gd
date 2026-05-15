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
## Mine.tscn: StaticBody3D на слое ITEMS (видим для всех AOE-сил которые
## маскируют ITEMS — Slam, Fireball, Firestorm, Super, BurnPatch — это
## MASK_HAND_SLAM) + BodyShape (CylinderShape для damage-сканов) +
## MeshInstance3D + Area3D TriggerArea (proximity-trigger зона).

signal exploded(world_position: Vector3)

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
## Маска для триггера (что вызывает детонацию). По умолчанию люди — скелеты
## и гномы. Tower/палатки/палисад на земле обычно не стоят прямо на мине.
@export_flags_3d_physics var trigger_mask: int = Layers.ENEMIES | Layers.COLD_ENEMY | Layers.FRIENDLY_UNIT
## Маска для AoE damage в момент взрыва. Шире чем trigger — мина бьёт всё
## что рядом, не только то что её активировало. Включает Tower и постройки —
## friendly fire by design (дизайнерское решение 2026-05-13). С 2026-05-15
## добавлен ITEMS — взрыв одной мины повреждает соседние, цепная реакция
## (мины Damageable, ARMED-мина в радиусе взрыва сама детонирует).
@export_flags_3d_physics var aoe_damage_mask: int = Layers.ENEMIES | Layers.COLD_ENEMY | Layers.FRIENDLY_UNIT | Layers.ACTORS | Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE | Layers.ITEMS

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
	_trigger_area.monitoring = false  # включится после ARMING
	_trigger_area.body_entered.connect(_on_body_entered)
	# Per-instance дубликат материала для независимого мигания. Запоминаем
	# базовый emission_energy_multiplier — основа для пульсации в ARMED.
	if _mesh != null and _mesh.material_override is StandardMaterial3D:
		var src := _mesh.material_override as StandardMaterial3D
		_base_emission_energy = src.emission_energy_multiplier
		_material = src.duplicate() as StandardMaterial3D
		_mesh.material_override = _material


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
				_trigger_area.monitoring = true
				if debug_log and LogConfig.master_enabled:
					print("[Mine] вооружена @ (%.1f, %.1f)" % [global_position.x, global_position.z])
		Phase.ARMED:
			# Мигание emission'а — сигнал «я вооружена». sin(t) ∈ [-1,1] → pulse ∈ [0,1].
			# emission_energy = base × (1 + pulse × peak), от base до base × (1 + peak).
			_blink_timer += delta
			if _material != null:
				var pulse: float = sin(_blink_timer * armed_blink_rate) * 0.5 + 0.5
				_material.emission_energy_multiplier = _base_emission_energy * (1.0 + pulse * armed_blink_peak)


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


## AoE-взрыв: ShapeQuery радиусом aoe_radius, damage всем Damageable
## в области. Эмитит exploded + queue_free. Идемпотентно через _exploded —
## цепная реакция от соседних мин не вызывает повторного _explode.
func _explode() -> void:
	if _exploded:
		return
	_exploded = true
	var space := get_world_3d().direct_space_state
	var sphere := SphereShape3D.new()
	sphere.radius = aoe_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, global_position)
	query.collision_mask = aoe_damage_mask
	var results: Array = space.intersect_shape(query, 32)
	var hit_count: int = 0
	for hit in results:
		var b: Node = hit.collider
		if Damageable.is_damageable(b):
			Damageable.try_damage(b, damage)
			hit_count += 1
	if debug_log and LogConfig.master_enabled:
		print("[Mine:explode] @ (%.1f, %.1f, %.1f) hit=%d targets, damage=%.0f r=%.1f" % [
			global_position.x, global_position.y, global_position.z, hit_count, damage, aoe_radius,
		])
	# Взрыв-VFX: полный fire-explosion (отличается от приземления — мина именно
	# сдетонировала, не «прилетела с пылью»). Спавним в parent (current_scene),
	# чтоб эффект пережил queue_free сам ой мины.
	var fx_root: Node = get_parent()
	if fx_root != null:
		AoeVisual.spawn_explosion(fx_root, global_position, aoe_radius)
	exploded.emit(global_position)
	queue_free()
