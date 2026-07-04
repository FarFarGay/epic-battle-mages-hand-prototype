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
## `hitstop` — длительность заморозки времени (сек) на удачном попадании; 0 =
## без хитстопа. Передавать только с ИМПАКТ-сайтов игрока (см. HitStop), DoT и
## NPC-автоатаки оставляют 0, иначе слоу-мо тикает непрерывно.
static func try_damage(target: Object, amount: float, hitstop: float = 0.0, hit_dir: Vector3 = Vector3.ZERO) -> bool:
	if amount <= 0.0:
		return false
	if not is_damageable(target):
		return false
	# Направление удара кладём в meta ДО урона: если удар смертельный, death-FX
	# (направленный оверкилл-шаттер, см. Skeleton._on_destroyed) читает его оттуда.
	if hit_dir.length_squared() > 0.0001:
		(target as Node).set_meta(&"last_hit_dir", hit_dir)
	(target as Node).take_damage(amount)
	if hitstop > 0.0:
		# стоп только на «весомых» целях; hit_dir (travel снаряда) задаёт сторону тильта
		HitStop.fire_for(target, hitstop, hit_dir)
	return true
