class_name CampPart
extends StaticBody3D
## Палатка лагеря. Препятствие для скелетов (CAMP_OBSTACLE) и одновременно
## цель их атаки — регистрируется в Damageable и в группе skeleton_target.
## При hp <= 0 → destroyed signal + queue_free; владелец-Camp вычищает себя
## из массива _parts по этому же сигналу.

signal damaged(amount: float)
signal destroyed

const SKELETON_TARGET_GROUP := &"skeleton_target"

@export var hp: float = 60.0

var _dying: bool = false


func _ready() -> void:
	Damageable.register(self)
	add_to_group(SKELETON_TARGET_GROUP)
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	damaged.connect(func(amount: float) -> void: EventBus.camp_part_damaged.emit(self, amount))
	destroyed.connect(func() -> void: EventBus.camp_part_destroyed.emit(self))


func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	hp -= amount
	damaged.emit(amount)
	if hp <= 0.0:
		_dying = true
		# queue_free отрабатывает только в конце кадра — без снятия флага скелет
		# ещё успел бы зацелиться в умирающую палатку в текущем тике.
		remove_from_group(SKELETON_TARGET_GROUP)
		destroyed.emit()
		queue_free()
