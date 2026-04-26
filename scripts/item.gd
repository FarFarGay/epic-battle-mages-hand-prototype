class_name Item
extends RigidBody3D
## Подбираемый предмет. Цвет, размер и масса настраиваются на инстансе.
## Размер применяется к мешу и форме коллизии в _ready
## (создаются уникальные ресурсы — общие из item.tscn остаются только для превью в редакторе).
## Масса задаётся встроенным свойством RigidBody3D.mass.
##
## Публичный API:
## - set_highlighted(value: bool) — включает/выключает emission на материале
##   (рука дёргает этот метод, когда предмет становится текущим кандидатом захвата).
## - take_damage(amount: float) — наносит урон, эмитит damaged/destroyed.

signal damaged(amount: float)
signal destroyed

@export var item_color: Color = Color(0.7, 0.7, 0.7)
@export var item_size: Vector3 = Vector3(1, 1, 1)
@export var highlight_color: Color = Color(1.0, 0.95, 0.4, 1.0)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6
@export var hp: float = 100.0

var _material: StandardMaterial3D

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	_apply_visual()
	_apply_shape()
	Damageable.register(self)
	Pushable.register(self)
	Grabbable.register(self)
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	# Локальные сигналы остаются для тесно-связанных слушателей.
	damaged.connect(func(amount: float) -> void: EventBus.item_damaged.emit(self, amount))
	destroyed.connect(func() -> void: EventBus.item_destroyed.emit(self))


func _apply_visual() -> void:
	var box_mesh := BoxMesh.new()
	box_mesh.size = item_size
	_mesh.mesh = box_mesh
	_material = StandardMaterial3D.new()
	_material.albedo_color = item_color
	_mesh.material_override = _material


func _apply_shape() -> void:
	var box_shape := BoxShape3D.new()
	box_shape.size = item_size
	_shape.shape = box_shape


func set_highlighted(value: bool) -> void:
	if not _material:
		return
	if value:
		_material.emission_enabled = true
		_material.emission = highlight_color
		_material.emission_energy_multiplier = highlight_intensity
	else:
		_material.emission_enabled = false


func take_damage(amount: float) -> void:
	if is_queued_for_deletion() or amount <= 0.0:
		return
	hp -= amount
	damaged.emit(amount)
	if hp <= 0.0:
		destroyed.emit()
		queue_free()


func apply_push(velocity_change: Vector3, _duration: float) -> void:
	# freeze=true: интегратор RigidBody отключён, импульс уходил бы в никуда —
	# контракт Pushable обещает применённый push, поэтому ранний выход.
	# Самый частый случай: предмет в руке игрока (Hand держит через freeze).
	if freeze:
		return
	apply_central_impulse(velocity_change * mass)
