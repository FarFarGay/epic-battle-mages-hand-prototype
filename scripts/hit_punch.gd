class_name HitPunch
extends RefCounted
## Shared scale-punch на damage'е — squash-and-stretch фидбек для всех врагов.
## Per-target, без аллокаций. Используется [Skeleton._on_self_damaged] и
## [SkeletonGiantThrower._on_self_damaged] (раньше были два почти-клона с
## тюнингом peak/timings, теперь — один вызов).
##
## Скелет тюнит peak/in/out параметрами; вызывающий хранит активный tween
## (через [punch]-возврат), чтобы убить предыдущий перед новым (быстрая серия
## damage-ов не должна стэкаться). Базовый класс [Enemy] держит slot
## `_hit_punch_tween`, наследники просто зовут [HitPunch.punch].

const PEAK_DEFAULT: float = 1.25
const IN_TIME_DEFAULT: float = 0.06
const OUT_TIME_DEFAULT: float = 0.14


## Запустить scale-punch на mesh'е. Если активный tween передан — убивается,
## новый возвращается. Caller хранит ссылку и передаёт сюда же на следующем
## ударе. Если mesh уже мёртв — no-op, возвращает null.
static func punch(
	mesh: Node3D,
	previous_tween: Tween = null,
	peak: float = PEAK_DEFAULT,
	in_time: float = IN_TIME_DEFAULT,
	out_time: float = OUT_TIME_DEFAULT,
) -> Tween:
	if mesh == null or not is_instance_valid(mesh):
		return null
	if previous_tween != null and previous_tween.is_valid():
		previous_tween.kill()
	var tween := mesh.create_tween()
	tween.set_trans(Tween.TRANS_QUAD)
	tween.tween_property(mesh, "scale", Vector3.ONE * peak, in_time).set_ease(Tween.EASE_OUT)
	tween.tween_property(mesh, "scale", Vector3.ONE, out_time).set_ease(Tween.EASE_IN)
	return tween
