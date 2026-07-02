class_name Arrow
extends Node3D
## Стрела — баллистический проджектайл. Не RigidBody3D — Node3D с ручным
## интегрированием velocity по гравитации, обнаружение коллизий через дочерний
## Area3D. Так дешевле, чем RigidBody (≈50 одновременно стрел в худшем случае),
## и логика smart'нее: хочешь — сделаешь хоминг через коррекцию `_velocity`
## в `_physics_process`.
##
## Layer 0 (ничего на нас не сканирует), mask = TERRAIN | ENEMIES — стрела
## остановится в скелете или в полу. Items/Tower/гномов пропускает насквозь
## (ИИ-стрелы дружественны).
##
## Баллистика: setup получает source/target и вычисляет начальную velocity
## с учётом гравитации (низкая дуга — меньший угол из двух решений). Если
## цель вне досягаемости с заданной speed — фоллбэк на прямой выстрел в
## направлении цели.
##
## На любой коллизии — queue_free. Урон только Damageable (скелетам); земля
## или иные тела просто гасят стрелу.

signal hit(target: Node, position: Vector3)

@export var damage: float = 35.0
@export var speed: float = 22.0
## Гравитация для стрелы. Меньше мировой 9.8 — стрелы летят более «настильно».
@export var gravity: float = 6.0
## Секунды до автоматического queue_free, если стрела не попала.
@export var lifetime: float = 4.0
## Логирует трассу стрелы (setup-параметры + что и где зацепилось). Дефолт
## false — включается на конкретной сцене для диагностики проблем с попаданием.
@export var debug_log: bool = false

@onready var _hit_area: Area3D = $HitArea

var _velocity: Vector3 = Vector3.ZERO
var _life: float = 0.0
## Идемпотентность: если Area3D триггернулся дважды (terrain + enemy в одном
## кадре, или стрела пролетела через два enemy'я в один тик) — урон проходит
## ровно одной целью.
var _consumed: bool = false


## Вызывается стрелком сразу после instantiate + add_child. Задаёт стартовую
## позицию и баллистическую velocity для попадания в target_position при
## заданной `speed` и `gravity`. Если решение баллистики невозможно (цель
## слишком далеко) — фоллбэк на прямой выстрел.
func setup(source_position: Vector3, target_position: Vector3) -> void:
	global_position = source_position
	_velocity = BallisticUtil.compute_launch_velocity(source_position, target_position, speed, gravity)
	_orient_along_velocity()
	if debug_log and LogConfig.master_enabled:
		var d_h: float = Vector2(target_position.x - source_position.x, target_position.z - source_position.z).length()
		print("[Arrow:setup] src=(%.1f,%.2f,%.1f) tgt=(%.1f,%.2f,%.1f) d_h=%.1fм dy=%.2fм v=%.1fм/с initV=(%.1f,%.2f,%.1f)" % [
			source_position.x, source_position.y, source_position.z,
			target_position.x, target_position.y, target_position.z,
			d_h, target_position.y - source_position.y, speed,
			_velocity.x, _velocity.y, _velocity.z,
		])


## Поворачивает меш носом вдоль текущей _velocity.
func _orient_along_velocity() -> void:
	if _velocity.length_squared() < 0.0001:
		return
	var fwd := _velocity.normalized()
	var up := Vector3.UP
	if absf(fwd.dot(up)) > 0.99:
		up = Vector3.FORWARD
	look_at(global_position + fwd, up)


## Свойство для FogOfWar.FOG_REVEAL_GROUP — стрела тащит маленький круг
## света вдоль траектории. Дружественные стрелы (defender/turret) дают
## трассу видимости; вражеские (archer-скелет) — выдают своё местоположение
## оборонщику через wisps на тропе. На queue_free группа очищается.
## Тонкий трейл вдоль траектории стрелы. История: 18→5м. 18м было до общего
## пересмотра пропорций (2026-05-18) — стрела «открывала» площадку как
## стационарный защитник. Тонкие 5м читаются как «росчерк стрелы», без
## ложного впечатления что стрела сама — фонарь.
var fog_reveal_radius: float = 5.0


func _ready() -> void:
	_hit_area.body_entered.connect(_on_body_entered)
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)


func _physics_process(delta: float) -> void:
	if _consumed:
		return
	_life += delta
	if _life >= lifetime:
		if debug_log and LogConfig.master_enabled:
			print("[Arrow:timeout] life=%.2fс pos=(%.1f,%.2f,%.1f)" % [_life, global_position.x, global_position.y, global_position.z])
		queue_free()
		return
	_velocity.y -= gravity * delta
	global_position += _velocity * delta
	_orient_along_velocity()


func _on_body_entered(body: Node) -> void:
	if _consumed:
		return
	_consumed = true
	# Если попали в Damageable (скелет) — наносим урон. В terrain — просто
	# исчезаем. Kill credit идёт через EventBus.enemy_destroyed → XpOrbSpawner
	# (autoload), поэтому стрела сама про XP ничего не знает (этап 49).
	if debug_log and LogConfig.master_enabled:
		var groups: Array = body.get_groups()
		print("[Arrow:hit] body=%s layer=%d groups=%s damageable=%s pos=(%.1f,%.2f,%.1f)" % [
			body.name, body.collision_layer if body is CollisionObject3D else -1,
			str(groups), Damageable.is_damageable(body),
			global_position.x, global_position.y, global_position.z,
		])
	if Damageable.is_damageable(body):
		Damageable.try_damage(body, damage)
		hit.emit(body, global_position)
	queue_free()
