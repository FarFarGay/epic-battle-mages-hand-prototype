class_name BallisticUtil
extends RefCounted
## Утилита баллистики снарядов: решение задачи «попасть в target_position из
## source_position при фиксированной |v|=speed и константной gravity по -Y».
## Возвращает начальную velocity Vector3.
##
## Использование: и [Arrow], и [GiantStone] (и любой будущий баллистический
## снаряд) делят одну формулу. Раньше формула жила копией в обоих файлах —
## вынесена сюда после code review (2 копии — пороговое значение для extract).
##
## Семантика fallback'а: если задача неразрешима с заданной speed (цель за
## пределами максимальной дальности при данной gravity), discriminant<0 →
## возвращаем прямой выстрел в направлении цели × speed. Caller увидит что
## снаряд не долетит (упадёт раньше под действием gravity) — это сигнал
## что параметры (speed / attack_radius_max / gravity) разошлись.

## Низкая дуга решения. tan(α) = (v² − √disc) / (g·d), где
## disc = v⁴ − g·(g·d² + 2·dy·v²). При нескольких решениях баллистики берём
## меньший угол — он «настильнее», менее зрелищный полёт, но цель быстрее
## (важно для геймплея: чем дольше летит снаряд, тем легче от него уйти).
##
## Параметры:
## - source: точка выпуска
## - target: точка прицеливания
## - speed: модуль начальной скорости (|v|)
## - gravity: ускорение свободного падения для этого снаряда (м/с²)
##
## Возвращает Vector3 velocity. Y-компонента положительна для дуги вверх,
## отрицательна для настильного выстрела вниз.
static func compute_launch_velocity(source: Vector3, target: Vector3, speed: float, gravity: float) -> Vector3:
	var to_target := target - source
	var horizontal := Vector3(to_target.x, 0.0, to_target.z)
	var d := horizontal.length()
	var dy := to_target.y
	if d < 0.0001:
		# Вертикальный выстрел: всё |v| идёт по Y в направлении цели.
		var dir_y: float = signf(dy) if absf(dy) > 0.0 else 1.0
		return Vector3(0.0, dir_y * speed, 0.0)
	var v2 := speed * speed
	var v4 := v2 * v2
	var disc := v4 - gravity * (gravity * d * d + 2.0 * dy * v2)
	if disc < 0.0:
		# Цель физически недостижима с заданной speed/gravity. Fallback —
		# прямой выстрел: caller увидит что снаряд упадёт раньше (гравитация
		# тянет вниз сразу) — сигнал что параметры разошлись.
		return to_target.normalized() * speed
	var sqrt_disc := sqrt(disc)
	var tan_low := (v2 - sqrt_disc) / (gravity * d)
	var angle := atan(tan_low)
	var dir_h := horizontal / d
	return dir_h * speed * cos(angle) + Vector3.UP * speed * sin(angle)
