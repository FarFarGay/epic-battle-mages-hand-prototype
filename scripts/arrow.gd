class_name Arrow
extends Node3D
## Стрела — простой проджектайл. Не RigidBody3D — летит по прямой с фиксированной
## скоростью, обнаружение коллизий через дочерний Area3D. Так дешевле, чем
## RigidBody (≈50 одновременно стрел в худшем случае), и логика smart'нее:
## хочешь — сделаешь хоминг через смену `_direction` в `_physics_process`.
##
## Layer 0 (ничего на нас не сканирует), mask = TERRAIN | ENEMIES — стрела
## остановится в скелете или в полу. Items/Tower/гномов пропускает насквозь
## (ИИ-стрелы дружественны).

signal hit(target: Node, position: Vector3)

@export var damage: float = 35.0
@export var speed: float = 22.0
## Секунды до автоматического queue_free, если стрела ни во что не попала.
## На карте 200×200 при speed=22 → пролёт 9с, ставим запас.
@export var lifetime: float = 4.0

@onready var _hit_area: Area3D = $HitArea

var _direction: Vector3 = Vector3.FORWARD
var _life: float = 0.0
## Идемпотентность: если Area3D триггернулся дважды (terrain + enemy в одном
## кадре, или стрела пролетела через два enemy'я в один тик) — урон проходит
## ровно одной целью.
var _consumed: bool = false


## Вызывается стрелком сразу после instantiate + add_child. Задаёт направление
## и стартовую позицию. Поворачиваем меш по направлению полёта через look_at.
##
## Направление — полное 3D, не горизонтальное: турель на верхушке башни
## (y≈6.85) бьёт по скелету на земле (y≈1) — без вертикальной составляющей
## стрела пролетала бы над головой.
func setup(source_position: Vector3, target_position: Vector3) -> void:
	global_position = source_position
	var to_target := target_position - source_position
	if to_target.length_squared() < 0.0001:
		to_target = Vector3.FORWARD
	_direction = to_target.normalized()
	# look_at смотрит -Z. Up = world Y, кроме случая, когда стреляем строго
	# вертикально (тогда forward параллелен up — look_at падает с ассертом).
	# Для этой игры цель всегда на земле, значит forward не вертикален; но
	# гард на всякий случай.
	var up := Vector3.UP
	if absf(_direction.dot(up)) > 0.99:
		up = Vector3.FORWARD
	look_at(global_position + _direction, up)


func _ready() -> void:
	_hit_area.body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	if _consumed:
		return
	_life += delta
	if _life >= lifetime:
		queue_free()
		return
	global_position += _direction * speed * delta


func _on_body_entered(body: Node) -> void:
	if _consumed:
		return
	_consumed = true
	# Если попали в Damageable (скелет) — наносим урон. В terrain — просто
	# исчезаем (стрела втыкается в землю).
	if Damageable.is_damageable(body):
		Damageable.try_damage(body, damage)
		hit.emit(body, global_position)
	queue_free()
