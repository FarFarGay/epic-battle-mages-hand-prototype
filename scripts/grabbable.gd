class_name Grabbable
extends RefCounted
## Контракт «grabbable»: рука может схватить (LMB), удерживать и бросить.
##
## Реализующая нода ОБЯЗАНА:
##   - Быть RigidBody3D (рука использует freeze / linear_velocity /
##     angular_velocity / apply_central_force / mass).
##   - Иметь метод `set_highlighted(value: bool) -> void` для рамки-кандидата.
##   - Иметь поле `mass: float` (есть у RigidBody3D).
##   - В _ready() позвать `Grabbable.register(self)`.
##
## Внешний код проверяет принадлежность через `Grabbable.is_grabbable(node)` —
## это снимает жёсткую зависимость руки от конкретного `class_name Item`.
## Любой RigidBody3D с нужными методами, зарегистрированный в группе, может
## быть схвачен.

const GROUP := &"grabbable"


## Зарегистрировать ноду как grabbable-цель.
static func register(node: Node) -> void:
	node.add_to_group(GROUP)


## True, если объект — Node, входящий в grabbable-группу.
static func is_grabbable(target: Object) -> bool:
	return target is Node and (target as Node).is_in_group(GROUP)
