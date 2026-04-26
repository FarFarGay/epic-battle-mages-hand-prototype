class_name Pushable
extends RefCounted
## Контракт «pushable» сущности + утилиты для применения толчка.
## RigidBody3D-цели (Item) и CharacterBody3D-цели (Enemy) толкаются по-разному
## (impulse vs velocity-assignment), но снаружи всё едино:
##     Pushable.try_push(collider, velocity_change, duration)
##
## Pushable-сущность ОБЯЗАНА:
##   - В _ready() позвать `Pushable.register(self)`.
##   - Иметь метод `apply_push(velocity_change: Vector3, duration: float) -> void`,
##     где `velocity_change` — желаемый прирост скорости (Δv).
##     RigidBody-реализации преобразуют через массу: apply_central_impulse(Δv * mass).
##     Kinematic-реализации применяют через свой knockback-механизм.
##     `duration` — для kinematic'ов (сколько AI заглушен); RigidBody игнорирует.
##
## Башня и враги используют это для пушей в физическом мире, не зная типа цели.

const GROUP := &"pushable"


## Зарегистрировать ноду как pushable-цель.
static func register(node: Node) -> void:
	node.add_to_group(GROUP)


## True, если объект — Node, входящий в pushable-группу.
static func is_pushable(target: Object) -> bool:
	return target is Node and (target as Node).is_in_group(GROUP)


## Универсальный пуш. Возвращает true, если толчок применён.
## velocity_change — желаемый Δv (без учёта массы, цель сама пересчитывает).
## duration — для kinematic-целей; RigidBody'ы игнорируют.
static func try_push(target: Object, velocity_change: Vector3, duration: float) -> bool:
	if not is_pushable(target):
		return false
	(target as Node).apply_push(velocity_change, duration)
	return true
