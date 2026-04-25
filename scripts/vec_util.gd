class_name VecUtil
## Utility функции для работы с Vector3 в горизонтальной XZ-плоскости.
## Часто нужны для AI/физики, когда вертикальная компонента игнорируется.

## Эпсилон для проверки `length_squared` — используется во всём проекте
## вместо литерального 0.0001 (читай: «вектор фактически нулевой»).
const EPSILON_SQ := 0.0001

## Возвращает копию `v` с обнулённой Y-компонентой.
static func horizontal(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)

## True, если горизонтальная проекция `v` фактически нулевая.
static func is_horizontal_zero(v: Vector3) -> bool:
	return v.x * v.x + v.z * v.z < EPSILON_SQ
