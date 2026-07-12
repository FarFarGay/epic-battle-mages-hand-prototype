class_name UnitGrabHandle
extends RigidBody3D
## Невидимая «ручка»-захват при ЖИВОМ юните: даёт руке штатный Grabbable-контракт
## (RigidBody3D + set_highlighted), не превращая самого юнита (CharacterBody3D)
## в RigidBody. Рука хватает ручку — юнит несётся под ней; отпустили — ручка
## решает судьбу юнита (монтаж на башню / просто поставить) и возвращается в
## режим слежения. hand_physical не правился ни на строку: для него это обычный
## grabbable-предмет (носимые оружия 2026-07-12, первый клиент — лучник).
##
## Контракт юнита-владельца (duck-typing, как Grabbable):
##   set_highlighted(bool)          — рамка-кандидат руки (подсветка гнома)
##   begin_hand_carry()             — юнита подняли (AI/физика юнита замирают)
##   carry_follow(pos: Vector3)     — юнит следует за ручкой пока несём
##   end_hand_carry()               — отпустили в мир (юнит оживает на месте)
##   try_mount_on_tower(tower) -> bool — отпустили НАД башней; true = смонтировался
##   is_carry_available() -> bool   — можно ли сейчас хватать (жив/не спрятан)
##
## Слой: на земле FRIENDLY_UNIT — GrabArea руки (маска 502) видит, курсор-raycast
## (67) нет (рука не «взбирается» на каждого гнома). НА КРЫШЕ БАШНИ —
## MOUNTED_MODULE (как у гарпуна): курсор поднимает руку НА крышу, иначе
## GrabArea (r=2) с земли до юнита на высоте ~8 не дотягивается и снять его
## рукой невозможно (баг первого плейтеста 2026-07-12). Там же ручка крупнее —
## в маленькую сферу луч курсора не попадал бы. collision_mask = 0 + freeze —
## ручка ни с чем не сталкивается, позиция ведётся телепортом за юнитом.

## Радиус защёлка на башню при отпускании (XZ) — как у HarpoonModule.
const MOUNT_RADIUS := 3.5
## Смещение ручки от origin юнита (центр груди — там же ловится GrabArea).
const FOLLOW_OFFSET := Vector3(0.0, 0.45, 0.0)
## Радиус сферы-ручки: на земле маленькая (внутри силуэта гнома, не ловит
## чужие лучи), на крыше башни крупная — цель для курсор-raycast'а руки.
const RADIUS_GROUND := 0.28
const RADIUS_MOUNTED := 0.7
## Юнит висит под рукой чуть ниже ручки (рука и так держит с hold_offset -1).
const CARRY_OFFSET := Vector3(0.0, -0.35, 0.0)

var _unit_ref: WeakRef = null
var _held: bool = false
var _shape: SphereShape3D = null


## Фабрика: создаёт ручку для юнита и кладёт её В СЦЕНУ (не ребёнком юнита —
## иначе телепорт руки двигал бы ручку относительно самого несомого юнита).
static func attach_to(unit: Node3D) -> UnitGrabHandle:
	var handle := UnitGrabHandle.new()
	handle._unit_ref = weakref(unit)
	unit.get_tree().current_scene.add_child(handle)
	handle.global_position = unit.global_position + FOLLOW_OFFSET
	return handle


func _ready() -> void:
	freeze = true
	mass = 5.0
	collision_layer = Layers.FRIENDLY_UNIT
	collision_mask = 0
	var col := CollisionShape3D.new()
	_shape = SphereShape3D.new()
	_shape.radius = RADIUS_GROUND
	col.shape = _shape
	add_child(col)
	Grabbable.register(self)
	EventBus.hand_grabbed.connect(_on_hand_grabbed)
	EventBus.hand_released.connect(_on_hand_released)


func _unit() -> Node3D:
	if _unit_ref == null:
		return null
	var u: Node = _unit_ref.get_ref()
	if u == null or not is_instance_valid(u) or u.is_queued_for_deletion():
		return null
	return u as Node3D


func _physics_process(_delta: float) -> void:
	var unit := _unit()
	if unit == null:
		queue_free()  # юнит умер/удалён — ручка не переживает владельца
		return
	if _held:
		# Несём: рука телепортирует ручку, юнит висит под ней.
		unit.carry_follow(global_position + CARRY_OFFSET)
		return
	# Слежение за юнитом. Спрятанный в башню/недоступный юнит не хватается —
	# гасим слой (GrabArea перестаёт видеть), не двигая ручку из мира.
	# НА КРЫШЕ — слой MOUNTED_MODULE + крупная сфера: курсор-raycast руки (67)
	# видит ручку и поднимает руку на крышу, GrabArea дотягивается → снятие
	# тем же хватом (в точности механика съёма гарпунной турели).
	var mounted: bool = unit.has_method(&"is_tower_weapon") and unit.call(&"is_tower_weapon")
	if not unit.is_carry_available():
		collision_layer = 0
	elif mounted:
		collision_layer = Layers.MOUNTED_MODULE
	else:
		collision_layer = Layers.FRIENDLY_UNIT
	if _shape != null:
		_shape.radius = RADIUS_MOUNTED if mounted else RADIUS_GROUND
	global_position = unit.global_position + FOLLOW_OFFSET


## Контракт Grabbable: подсветка кандидата — транслируем юниту.
func set_highlighted(value: bool) -> void:
	var unit := _unit()
	if unit != null:
		unit.set_highlighted(value)


func _on_hand_grabbed(item: Node3D) -> void:
	if item != self:
		return
	var unit := _unit()
	if unit == null:
		return
	_held = true
	unit.begin_hand_carry()


func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item != self or not _held:
		return
	_held = false
	# Рука на release разморозила ручку и дала ей скорость броска — гасим:
	# ручка не летает, она мгновенно возвращается в режим слежения.
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	var unit := _unit()
	if unit == null:
		return
	# Отпустили над башней → юнит монтируется (сам решает занятость слота).
	var tower := get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	if tower != null and is_instance_valid(tower):
		var dx: float = tower.global_position.x - global_position.x
		var dz: float = tower.global_position.z - global_position.z
		if dx * dx + dz * dz <= MOUNT_RADIUS * MOUNT_RADIUS:
			if unit.try_mount_on_tower(tower):
				return
	unit.end_hand_carry()
