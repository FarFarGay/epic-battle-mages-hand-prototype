class_name CampModule
extends RigidBody3D
## База для модулей лагеря/башни — апгрейдов, которые можно носить рукой и
## ставить в слот (`MountSlot`) на башню или в центр развёрнутого лагеря.
## Конкретные модули (OctagonTurret и будущие — алтарь, кузница, …) наследуют
## этот класс и переопределяют `_on_mounted/_on_unmounted/_module_tick`.
##
## Поток состояния:
##   1. Свободный — RigidBody3D с гравитацией, лежит на земле. Grabbable.
##   2. Захвачен рукой (Hand устанавливает freeze=true и таскает) — base-логика
##      отключена, _module_tick не вызывается.
##   3. Mounted в слоте — freeze=true, позиция управляется слотом, _module_tick
##      работает (стрельба, ауры и т. п.).
##
## Управление состоянием — снаружи через `MountSlot`. Сам модуль не сканирует
## слоты, не «угадывает», куда монтироваться. Слот ловит `EventBus.hand_released`,
## проверяет дистанцию до своей точки и вызывает `attach_to_slot(self)`.

signal mounted(slot: Node)
signal unmounted(slot: Node)

const HIGHLIGHT_INTENSITY := 0.6

@export_group("Visual")
@export var module_color: Color = Color(0.7, 0.7, 0.75, 1.0)
@export var highlight_color: Color = Color(1.0, 0.95, 0.4, 1.0)

@export_group("")

## Текущий слот (или null если свободен / в руке).
var _slot: Node = null
## Кэш материала для подсветки. Подкласс может использовать или игнорировать.
var _material: StandardMaterial3D = null
## Запоминаем стартовый collision_layer (обычно ITEMS=2). На время монтажа
## переключаемся на MOUNTED_MODULE (64): тауэр на ACTORS с mask=31 не видит
## этот бит — touching-контакт «башня снизу, турель сверху» больше не
## триггерит wall-collision. Hand.GrabArea (mask включает MOUNTED_MODULE)
## всё равно ловит модуль для повторного захвата.
var _layer_when_free: int = 0


func _ready() -> void:
	# Базовая регистрация — рука может захватить любой CampModule.
	# Конкретные модули могут добавить Damageable.register, если их можно бить.
	Grabbable.register(self)
	_layer_when_free = collision_layer


func is_mounted() -> bool:
	return _slot != null


func get_slot() -> Node:
	return _slot


## Вызывается MountSlot при успешном монтаже. Не вызывать вручную.
func attach_to_slot(slot: Node) -> void:
	if _slot == slot:
		return
	if _slot != null:
		# Странный случай — слот переопределили без detach. Логируем и продолжаем.
		var old := _slot
		_slot = null
		unmounted.emit(old)
		_on_unmounted(old)
	_slot = slot
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# Переключаемся на «mounted»-слой, чтобы тауэр перестал видеть нас как стену.
	collision_layer = Layers.MOUNTED_MODULE
	mounted.emit(slot)
	_on_mounted(slot)


## Вызывается MountSlot при размонтаже (рука сорвала, слот выключился).
## Не вызывать вручную. Freeze не сбрасываем — рука управляет им сама при grab/release.
func detach_from_slot() -> void:
	if _slot == null:
		return
	var old := _slot
	_slot = null
	# Возвращаем стартовый collision_layer (обычно ITEMS): свободный модуль или
	# модуль в руке — обычный Grabbable RigidBody, по нему все физсканы пройдут.
	collision_layer = _layer_when_free
	unmounted.emit(old)
	_on_unmounted(old)


# --- Виртуалы для подклассов ---

## Подкласс начинает свою работу (стрельба, аура и т. д.).
func _on_mounted(_slot: Node) -> void:
	pass


## Подкласс останавливает работу (снимаем стрельбу, гасим ауру).
func _on_unmounted(_old_slot: Node) -> void:
	pass


# --- Grabbable contract ---

## Контракт Grabbable. Подкласс может переопределить, если есть свой материал.
func set_highlighted(value: bool) -> void:
	if _material == null:
		return
	if value:
		_material.emission_enabled = true
		_material.emission = highlight_color
		_material.emission_energy_multiplier = HIGHLIGHT_INTENSITY
	else:
		_material.emission_enabled = false
