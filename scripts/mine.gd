class_name Mine
extends Node3D
## Мина-ловушка. Спавнится в воздухе от burst'а carrier'а (см. HandSpellMineScatter),
## падает на землю, после arming-задержки превращается в триггер.
##
## Жизненный цикл (FSM):
##   FALLING — летит с начальной velocity + gravity, пока не достигнет y ≈ 0.
##             Area3D отключена — чтоб не сдетонировать на воздушные коллизии
##             (соседняя мина, прохожий гном).
##   ARMING — приземлилась. arming_delay секунд защищает от само-цепной
##            реакции и от уже стоящих врагов в момент установки.
##   ARMED — Area3D активна. На body_entered (любой в trigger_mask) — взрыв:
##           ShapeQuery радиусом aoe_radius, damage всем Damageable.
##
## Friendly-fire ON по дизайну: trigger_mask включает и ENEMIES и FRIENDLY_UNIT.
## Стратегический вес — игрок думает куда кидает.
##
## Mine.tscn: Node3D + MeshInstance3D (визуал) + Area3D `TriggerArea` с
## SphereShape3D (триггер-зона, обычно меньше aoe_radius — «педаль»).

signal exploded(world_position: Vector3)

enum Phase { FALLING, ARMING, ARMED }

@export var damage: float = 30.0
@export var aoe_radius: float = 1.8
## Задержка между приземлением и активацией триггера. Защищает от ситуаций
## когда мина детонирует на собственное падение / соседнюю мину в одной
## волне burst'а / врага уже стоящего в точке падения.
@export var arming_delay: float = 0.5
## Гравитация во время FALLING. Больше мировой 9.8 — падают быстро,
## геймплейная пауза «летит-падает» короткая.
@export var gravity: float = 14.0
## Скорость падения, начиная с которой считаем что приземлились (порог
## для «коснулась земли»). Без этого мины с малой y-velocity вечно
## дрейфуют над y=0.
@export var ground_y: float = 0.05
## Маска для триггера (что вызывает детонацию). По умолчанию люди — скелеты
## и гномы. Tower/палатки/палисад на земле обычно не стоят прямо на мине.
@export_flags_3d_physics var trigger_mask: int = Layers.ENEMIES | Layers.COLD_ENEMY | Layers.FRIENDLY_UNIT
## Маска для AoE damage в момент взрыва. Шире чем trigger — мина бьёт всё
## что рядом, не только то что её активировало. Включает Tower и постройки —
## friendly fire by design (дизайнерское решение 2026-05-13).
@export_flags_3d_physics var aoe_damage_mask: int = Layers.ENEMIES | Layers.COLD_ENEMY | Layers.FRIENDLY_UNIT | Layers.ACTORS | Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE
@export var debug_log: bool = false

@onready var _trigger_area: Area3D = $TriggerArea

var _phase: int = Phase.FALLING
var _velocity: Vector3 = Vector3.ZERO
var _arming_timer: float = 0.0


## Зовётся спавнером сразу после instantiate+add_child. Задаёт стартовую
## позицию в воздухе и initial velocity (от burst-разлёта).
func setup(spawn_pos: Vector3, initial_velocity: Vector3) -> void:
	global_position = spawn_pos
	_velocity = initial_velocity


func _ready() -> void:
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = trigger_mask
	_trigger_area.monitoring = false  # включится после ARMING
	_trigger_area.body_entered.connect(_on_body_entered)


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
			pass


func _on_body_entered(_body: Node) -> void:
	if _phase != Phase.ARMED:
		return
	_explode()


## AoE-взрыв: ShapeQuery радиусом aoe_radius, damage всем Damageable
## в области. Эмитит exploded + queue_free.
func _explode() -> void:
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
	exploded.emit(global_position)
	queue_free()
