class_name SegmentMotionFx
extends RefCounted
## Helper для motion-feedback анимации движущегося сегмента каравана.
## Считает velocity из diff'а позиций и возвращает offset/наклон/scale,
## которые сегмент применяет к своему visual-root (mesh или Node3D-обёртке).
##
## Объединяет 3 эффекта:
##   - **Bobbing** — вертикальная синусоида во время движения. Чем быстрее —
##     тем выше амплитуда и частота. Даёт «шаги» тяжёлого тела.
##   - **Tilt forward** — наклон в сторону движения по горизонтальной оси
##     перпендикулярной direction'у. Сегмент «склоняется вперёд» как
##     бегущий человек.
##   - **Squash-stretch** — растяжение по оси движения и сжатие по Y при
##     старте, обратное возврату к нейтрали при остановке. Чувство веса
##     и инерции на старт/стоп.
##
## Все три фейда плавные через exp-decay (response-параметры), не tween —
## не требует анимационного плана, реактивно реагирует на изменение
## velocity каждый кадр.

## Амплитуда вертикального bob'а на максимальной скорости (м). 0.06 ≈
## 6см — заметно, но не лезет глаза. На стопе → 0.
var bob_amplitude: float = 0.06
## Частота bob'а в Гц на максимальной скорости. 3 Гц = ~3 шага/сек,
## близко к темпу пешего шага.
var bob_frequency: float = 3.0

## Максимальный угол наклона forward (рад). По умолчанию 0 — наклон
## выключен (игрок решил что он плохо читается на квадратных palatka/
## tower'е). Если хочется лёгкого «leaning forward» — выставить
## per-сегмент через _motion_fx.tilt_max_rad в их _ready'е.
var tilt_max_rad: float = 0.0
## Скорость подгона текущего наклона к target'у (1/с). Выше — резче,
## ниже — плавнее. 8 ≈ 125мс настройка до 63% target'а.
var tilt_response: float = 8.0

## Степень растяжения по оси движения (+) и сжатия по Y (-) на старте.
## 0.08 = +8% length / -8% height — заметно, не уродливо.
var stretch_factor: float = 0.08
## Скорость подгона scale к target'у. Меньше tilt_response — squash идёт
## плавнее, читается как «инерция».
var ss_response: float = 6.0

## Эталонная скорость для нормализации эффектов (м/с). Сегменты быстрее
## неё не получают усиленные эффекты — clamp в 1.0. Совпадает с обычной
## caravan-скоростью (~ tower.move_speed).
var speed_reference: float = 6.0
## Ниже этой скорости считаем что сегмент стоит (м/с) — bob/tilt/stretch
## плавно гасятся к нейтрали. Не 0 — иначе микро-jitter тригерил эффекты.
var speed_threshold: float = 0.15

var _last_pos: Vector3 = Vector3.INF
var _bob_phase: float = 0.0
var _current_tilt: float = 0.0
var _current_scale: Vector3 = Vector3.ONE
var _smoothed_dir: Vector3 = Vector3.FORWARD


## Сбрасывает state'ы — нужно после телепорта сегмента (deploy/pack),
## иначе следующий tick посчитает огромную «velocity».
func reset(at_pos: Vector3) -> void:
	_last_pos = at_pos
	_bob_phase = 0.0
	_current_tilt = 0.0
	_current_scale = Vector3.ONE


## Тик. Возвращает Dictionary со state'ом, который сегмент применяет к
## своему visual-root. Ключи:
##  - `bob_y: float` — добавочный Y offset для mesh'а
##  - `basis: Basis` — полная basis (включая tilt + scale)
func tick(body_pos: Vector3, delta: float) -> Dictionary:
	if delta <= 0.0:
		return {"bob_y": 0.0, "basis": Basis()}
	if _last_pos == Vector3.INF:
		_last_pos = body_pos
	var motion: Vector3 = body_pos - _last_pos
	motion.y = 0.0
	var motion_len: float = motion.length()
	var speed: float = motion_len / delta
	var speed_norm: float = clampf(speed / speed_reference, 0.0, 1.0)
	var moving: bool = speed > speed_threshold

	# Bobbing: phase растёт только когда movement активен; на стопе фаза
	# замирает, амплитуда плавно к 0.
	if moving:
		_bob_phase += delta * bob_frequency * TAU * speed_norm
		_smoothed_dir = (motion / motion_len)
	var bob_y: float = sin(_bob_phase) * bob_amplitude * speed_norm

	# Tilt: target — tilt_max в направлении движения, exp-decay к нему.
	var target_tilt: float = tilt_max_rad * speed_norm
	var t_lerp: float = 1.0 - exp(-tilt_response * delta)
	_current_tilt = lerpf(_current_tilt, target_tilt, t_lerp)

	# Squash-stretch: при движении растяжение по dir + sжатие по Y.
	# При остановке — обратное возвращение к Vector3.ONE.
	var target_scale: Vector3
	if moving:
		var s: float = stretch_factor * speed_norm
		target_scale = Vector3(1.0 + s, 1.0 - s, 1.0 + s)
	else:
		target_scale = Vector3.ONE
	var s_lerp: float = 1.0 - exp(-ss_response * delta)
	_current_scale = _current_scale.lerp(target_scale, s_lerp)

	# Сборка basis: scale × tilt-rotation. Tilt — вращение вокруг
	# горизонтальной оси perpendicular to direction (UP × dir).
	var tilt_axis: Vector3 = Vector3.UP.cross(_smoothed_dir)
	var basis: Basis
	if tilt_axis.length_squared() > 0.0001:
		tilt_axis = tilt_axis.normalized()
		basis = Basis(tilt_axis, _current_tilt).scaled(_current_scale)
	else:
		basis = Basis().scaled(_current_scale)

	_last_pos = body_pos
	return {"bob_y": bob_y, "basis": basis}
