class_name KnockbackState
extends RefCounted
## Состояние knockback'а для kinematic-тел (CharacterBody3D).
## Раньше дублировалось между Enemy и Gnome: таймер, lerp-затухание горизонтали,
## слияние impulse в velocity. Вынесено в один объект-помощник.
##
## Использование:
##     var _knockback := KnockbackState.new()
##     _knockback.friction = knockback_friction  # в _ready
##
##     # На приём импульса:
##     velocity = KnockbackState.compose(velocity, impulse)
##     _knockback.start(duration)
##
##     # Каждый физкадр:
##     _knockback.tick(delta)
##     if _knockback.is_active():
##         velocity = _knockback.apply_friction(velocity, delta)
##         # AI заглушен
##     else:
##         _ai_step(delta)

## Скорость затухания горизонтали (1/c). Выставляется владельцем в _ready.
var friction: float = 5.0

var _timer: float = 0.0


func is_active() -> bool:
	return _timer > 0.0


## Стартовать knockback на указанную длительность. Сам impulse не пишется —
## velocity-композиция делается через compose() (см. ниже), чтобы вызывающий
## контролировал, что именно слить с текущей velocity (например, преcerve
## вертикали при падении).
func start(duration: float) -> void:
	_timer = duration


## Тик таймера. Не двигает velocity сам — это работа apply_friction().
func tick(delta: float) -> void:
	if _timer > 0.0:
		_timer = maxf(_timer - delta, 0.0)


## Покадровое затухание горизонтали к нулю по friction. Вертикаль не трогаем —
## гравитация / прыжок остаются за владельцем.
func apply_friction(velocity: Vector3, delta: float) -> Vector3:
	velocity.x = lerpf(velocity.x, 0.0, friction * delta)
	velocity.z = lerpf(velocity.z, 0.0, friction * delta)
	return velocity


## Слить impulse с current velocity по конвенции:
##   x/z — заменяются (knockback диктует горизонталь),
##   y — max(current_y, impulse_y) — gravity-fall не затирается, но прыжок-наверх
##        от удара суммируется поверх.
static func compose(current_velocity: Vector3, impulse: Vector3) -> Vector3:
	var out := current_velocity
	out.x = impulse.x
	out.z = impulse.z
	out.y = maxf(out.y, impulse.y)
	return out
