class_name MineCarrier
extends Node3D
## Носитель мин для Mine Scatter заклинания. Ballistic-снаряд: вылетает
## из башни по заданной дуге (фиксированный угол), скорость считается так,
## чтобы попасть в target_pos. В апексе (vy переходит из + в −) лопается
## на осколки.
##
## Не похож на [SuperCarrier]: у того boost-up → homing-to-target (целевой
## удар сверху). Здесь — броски «жмени», как handful of seeds. Burst НЕ
## над целью, а на пол-пути в воздухе. От burst осколки летят дальше по
## инерции carrier'а + outward-разлёт + индивидуальные арки до земли.
##
## Угол фиксированный (60°), скорость подбирается под расстояние и dy —
## арка всегда визуально читается одинаково «навесной», независимо от
## дистанции прицела. Если target вне физически возможной зоны (например,
## слишком близко на одной высоте) — фоллбэк на безопасную скорость + угол.
##
## Эмитит `burst(position, velocity)` — слушатель видит И где взорвалось,
## И с какой инерцией летел носитель (нужно чтоб осколки получили часть
## его скорости вперёд).

signal burst(world_position: Vector3, carrier_velocity: Vector3)

## Гравитация carrier'а в полёте. Меньше Mine.gravity (14) — арка выше,
## ощущение «лоб», а не «прямой бросок».
@export var gravity: float = 12.0
## Угол старта в градусах. 60° = классический «лоб», узнаваемая высокая дуга.
## Скорость считается так, чтобы цель оказалась на траектории.
@export_range(20.0, 80.0) var launch_angle_deg: float = 60.0
## Failsafe-таймаут. Если по каким-то причинам апекс не сработал (мелкая
## арка, низкая горизонтальная компонента) — burst через эти секунды.
@export var lifetime: float = 3.0
## Минимальное время до возможного burst'а. Защита от моментального burst'а
## если апекс ловится на первый кадр.
@export var min_flight_time: float = 0.2
## Дефолтная скорость на случай вырожденного target'а (d=0 или target выше
## arc-возможностей). Среднее значение — carrier полетит вверх-вперёд по
## launch_angle и через failsafe lifetime разорвётся.
@export var fallback_speed: float = 14.0

var _velocity: Vector3 = Vector3.ZERO
var _life: float = 0.0
var _prev_vy: float = 0.0
var _bursted: bool = false


## Вызывается спавнером после add_child. source — точка старта (Tower+UP),
## target — точка прицела на земле. Скорость подбирается под фиксированный
## launch_angle_deg, чтобы попасть из source в target по баллистической
## дуге. Если target вне досягаемости при этом угле — фоллбэк на 60° +
## fallback_speed (carrier улетит в обозначенную сторону, burst через
## lifetime).
func setup(source: Vector3, target: Vector3) -> void:
	global_position = source
	_velocity = _compute_arc_velocity(source, target)


## Решает обратную баллистическую задачу при фиксированном угле:
##   y(t) = source.y + v·sin(α)·t − ½·g·t²
##   x(t) = source.y + v·cos(α)·t
## Подставляем t = d / (v·cos(α)), получаем
##   v² = g·d² / (2·cos²(α)·(d·tan(α) − dy))
## где dy = target.y − source.y. Знаменатель > 0 ⇔ target лежит ниже
## трактории, проходящей через source под углом α. Если знаменатель ≤ 0
## (target выше угла-броска или прямо над source) — фоллбэк.
func _compute_arc_velocity(source: Vector3, target: Vector3) -> Vector3:
	var to_target := target - source
	var horizontal := Vector3(to_target.x, 0.0, to_target.z)
	var d := horizontal.length()
	var dy := to_target.y
	var angle: float = deg_to_rad(launch_angle_deg)
	var cos_a: float = cos(angle)
	var sin_a: float = sin(angle)
	# Дефолтное направление для фоллбэков — в сторону target'а, если
	# горизонталь определена, иначе просто +X.
	var dir_h: Vector3 = Vector3.RIGHT
	if d > 0.0001:
		dir_h = horizontal / d
	# Edge case: target прямо над/под source (нет горизонтали).
	if d < 0.0001:
		return Vector3.UP * fallback_speed
	# Решаем v² = g·d² / (2·cos²(α)·(d·tan(α) − dy)).
	var tan_a: float = sin_a / cos_a if cos_a > 0.0001 else 1000.0
	var denom: float = 2.0 * cos_a * cos_a * (d * tan_a - dy)
	if denom <= 0.0:
		# Target выше «потолка» арки — лоб не дотянется. Фоллбэк: launch
		# по углу в сторону target'а с fallback_speed, апекс/lifetime
		# самостоятельно разорвут.
		return dir_h * fallback_speed * cos_a + Vector3.UP * fallback_speed * sin_a
	var v_squared: float = gravity * d * d / denom
	if v_squared <= 0.0:
		return dir_h * fallback_speed * cos_a + Vector3.UP * fallback_speed * sin_a
	var v: float = sqrt(v_squared)
	return dir_h * v * cos_a + Vector3.UP * v * sin_a


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
