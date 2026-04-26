class_name Damageable
extends RefCounted
## Контракт «damageable» сущности + утилиты для каста урона.
## Item / Enemy / Tower живут на разных физических базах (RigidBody3D /
## CharacterBody3D × 2) и не могут разделять одно наследование, поэтому
## принадлежность определяется через GROUP (Damageable.GROUP).
##
## Damageable-сущность ОБЯЗАНА:
##   - В _ready() позвать `Damageable.register(self)`.
##   - Иметь метод `take_damage(amount: float) -> void` (амоунт в HP).
##   - Эмитить сигнал `damaged(amount: float)` каждый раз при ненулевом приёме урона.
##   - Эмитить сигнал `destroyed` ровно один раз при переходе hp ≤ 0.
##   - Гарантировать идемпотентность: повторные take_damage после destroyed — no-op.
##
## Внешний код наносит урон через единую точку:
##     Damageable.try_damage(collider, amount)
## Возвращает true, если цель приняла удар (была damageable и amount > 0).

const GROUP := &"damageable"


## Зарегистрировать ноду как damageable-цель. Вызывается в `_ready()` каждой
## damageable-сущности.
static func register(node: Node) -> void:
	node.add_to_group(GROUP)


## True, если объект — Node, входящий в damageable-группу.
static func is_damageable(target: Object) -> bool:
	return target is Node and (target as Node).is_in_group(GROUP)


## Универсальный нанос урона. Возвращает true, если удар прошёл.
## Гейтит amount > 0 (на случай dt-производных значений) и проверяет группу.
static func try_damage(target: Object, amount: float) -> bool:
	if amount <= 0.0:
		return false
	if not is_damageable(target):
		return false
	(target as Node).take_damage(amount)
	return true
