class_name ResourcePile
extends RigidBody3D
## Куча ресурсов: гномы забирают по 1 ед. через take_one(). Также — Damageable
## (рука может разнести), Pushable (рука/башня могут толкнуть), Grabbable
## (рука может схватить и кинуть).
##
## Гномы видят кучу, только если она не заморожена (freeze=false). Когда игрок
## схватил кучу рукой — freeze=true, гномы воспринимают её как «занятую» и
## идут искать другую (через _on_pile_lost).
##
## hp и units независимы:
##   - units → запас ресурсов; декрементируется при take_one().
##   - hp → урон от руки/slam'а; queue_free при hp ≤ 0 даже если units > 0.

signal damaged(amount: float)
signal destroyed

const GROUP := &"resource_pile"

@export var units: int = 5
@export var hp: float = 30.0
@export var pile_color: Color = Color(0.4, 0.75, 0.3)
@export var pile_size: Vector3 = Vector3(0.6, 0.6, 0.6)
@export var highlight_color: Color = Color(1.0, 0.95, 0.4)
@export_range(0.0, 5.0) var highlight_intensity: float = 0.6

var _material: StandardMaterial3D

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	add_to_group(GROUP)
	Damageable.register(self)
	Pushable.register(self)
	Grabbable.register(self)
	_apply_visual()
	_apply_shape()
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	damaged.connect(func(amount: float) -> void: EventBus.item_damaged.emit(self, amount))
	destroyed.connect(func() -> void: EventBus.item_destroyed.emit(self))


func _apply_visual() -> void:
	var box := BoxMesh.new()
	box.size = pile_size
	_mesh.mesh = box
	_material = StandardMaterial3D.new()
	_material.albedo_color = pile_color
	_mesh.material_override = _material


func _apply_shape() -> void:
	var shape := BoxShape3D.new()
	shape.size = pile_size
	_shape.shape = shape


# --- Damageable ---

func take_damage(amount: float) -> void:
	if is_queued_for_deletion() or amount <= 0.0:
		return
	hp -= amount
	damaged.emit(amount)
	if hp <= 0.0:
		destroyed.emit()
		queue_free()


# --- Pushable ---

func apply_push(velocity_change: Vector3, _duration: float) -> void:
	# freeze=true — кучу держит рука; импульс ушёл бы в никуда.
	if freeze:
		return
	apply_central_impulse(velocity_change * mass)


# --- Grabbable (рамка-кандидат) ---

func set_highlighted(value: bool) -> void:
	if not _material:
		return
	if value:
		_material.emission_enabled = true
		_material.emission = highlight_color
		_material.emission_energy_multiplier = highlight_intensity
	else:
		_material.emission_enabled = false


# --- Гномы ---

## Гном забирает 1 единицу. Возвращает true, если получилось.
## Не отдаёт, если кучу сейчас держит рука (freeze=true) — гном считает
## её «занятой» и ищет другую через _on_pile_lost.
func take_one() -> bool:
	if freeze or units <= 0 or is_queued_for_deletion():
		return false
	units -= 1
	if units == 0:
		destroyed.emit()
		queue_free()
	return true
