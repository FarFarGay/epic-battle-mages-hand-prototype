class_name MineCarrier
extends Node3D
## Носитель мин для Mine Scatter заклинания. Ballistic-снаряд: вылетает
## из башни с просчитанной начальной velocity (high-arc, видимая дуга),
## под действием гравитации арку проходит, на апексе (vy переходит из + в −)
## лопается на осколки.
##
## Не похож на [SuperCarrier]: у того boost-up → homing-to-target (целевой
## удар сверху). Здесь — броски «жмени», как handful of seeds. Burst НЕ
## над целью, а на пол-пути в воздухе. От burst осколки летят дальше по
## инерции carrier'а + outward-разлёт + индивидуальные арки до земли.
##
## Эмитит `burst(position, velocity)` — слушатель видит И где взорвалось,
## И с какой инерцией летел носитель (нужно чтоб осколки получили половину
## его скорости вперёд).

signal burst(world_position: Vector3, carrier_velocity: Vector3)

## Гравитация carrier'а в полёте. Меньше Mine.gravity (14) — арка выше,
## ощущение «лоб», а не «прямой бросок».
@export var gravity: float = 12.0
## Failsafe-таймаут. Если по каким-то причинам апекс не сработал (например,
## цель оказалась ниже launch'а и арка пологая), всё равно бахнем.
@export var lifetime: float = 3.0
## Минимальное время до возможного burst'а. Защита от моментального burst'а
## если игрок стреляет на короткой дистанции и апекс ловится на первый кадр.
@export var min_flight_time: float = 0.2

var _velocity: Vector3 = Vector3.ZERO
var _life: float = 0.0
var _prev_vy: float = 0.0
var _bursted: bool = false


## Вызывается спавнером после add_child. source — точка старта (Tower+UP),
## target — точка прицела на земле, launch_speed — желаемая |v| при старте.
## Из target + launch_speed считается high-arc баллистика (большой угол,
## видимая дуга). Если target недостижим за launch_speed — фоллбэк на
## прямой выстрел.
func setup(source: Vector3, target: Vector3, launch_speed: float) -> void:
	global_position = source
	_velocity = _compute_high_arc(source, target, launch_speed)


## High-arc баллистика: `tan(α) = (v² + √disc) / (g·d)` — высокий угол
## (противоположное решение от low-arc у Arrow.gd). Даёт лоб с заметной
## аркой и медленным горизонтальным движением — визуально читается как
## «бросок», не «выстрел». Если discriminant < 0 (цель вне досягаемости) —
## прямой выстрел.
func _compute_high_arc(source: Vector3, target: Vector3, speed: float) -> Vector3:
	var to_target := target - source
	var horizontal := Vector3(to_target.x, 0.0, to_target.z)
	var d := horizontal.length()
	var dy := to_target.y
	if d < 0.0001:
		return Vector3.UP * speed
	var v2 := speed * speed
	var v4 := v2 * v2
	var disc := v4 - gravity * (gravity * d * d + 2.0 * dy * v2)
	if disc < 0.0:
		return to_target.normalized() * speed
	var sqrt_disc := sqrt(disc)
	var tan_high := (v2 + sqrt_disc) / (gravity * d)
	var angle := atan(tan_high)
	var dir_h := horizontal / d
	return dir_h * speed * cos(angle) + Vector3.UP * speed * sin(angle)


func _physics_process(delta: float) -> void:
	if _bursted:
		return
	_life += delta
	if _life >= lifetime:
		_do_burst()
		return
	_prev_vy = _velocity.y
	_velocity.y -= gravity * delta
	global_position += _velocity * delta
	_orient_along_velocity()
	# Apex detection: vy была положительной (взлёт), стала ≤ 0 (вершина пройдена).
	# В этой точке — burst. min_flight_time защищает от первого кадра.
	if _life >= min_flight_time and _prev_vy > 0.0 and _velocity.y <= 0.0:
		_do_burst()


## Поворот носа carrier'а вдоль velocity — визуальный feedback дуги
## (мещ ориентируется как стрела по траектории).
func _orient_along_velocity() -> void:
	if _velocity.length_squared() < 0.0001:
		return
	var fwd := _velocity.normalized()
	var up := Vector3.UP
	if absf(fwd.dot(up)) > 0.99:
		up = Vector3.FORWARD
	look_at(global_position + fwd, up)


func _do_burst() -> void:
	if _bursted:
		return
	_bursted = true
	burst.emit(global_position, _velocity)
	queue_free()
