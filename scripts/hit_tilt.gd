class_name HitTilt
## Процедурная импакт-реакция меша (наклон + squash + перехлёст) — визуальная
## подача удара/отдачи для объектов без скелетной анимации. Стиль зеркалит DashFx:
## возвращает Basis, вызывающий домножает на свою базу.
##
## Импакт = резкий снап на удар → один обратный перехлёст (whip) → возврат. Это
## читается «ударно», а не как мягкий клевок. Амплитуда задаётся envelope() по
## времени; tilt_basis допускает amount<0 (перехлёст кренит в обратную сторону).

const MAX_TILT_DEG := 22.0
# Возврат с перехлёстом: длительность и форма затухающей косинусоиды.
const RECOVER_DUR := 0.26
const _ENV_DAMP := 3.0
const _ENV_FREQ := 1.6
# Squash на ударе: вертикаль сжимается, горизонталь чуть раздаётся (∝ |amount|).
const _SQUASH := 0.16


## Огибающая удара по времени: age 0→RECOVER_DUR. 1 на ударе → резкий спад →
## один обратный перехлёст (<0) → 0. Кормит amount в tilt_basis/impact_basis.
static func envelope(age: float, dur: float = RECOVER_DUR) -> float:
	if age <= 0.0:
		return 1.0
	if age >= dur:
		return 0.0
	var p: float = age / dur
	return exp(-_ENV_DAMP * p) * cos(p * PI * _ENV_FREQ)


## Basis наклона: меш кренится в сторону, ПРОТИВОПОЛОЖНУЮ local_dir (отшатнулся
## от удара). amount в [-1..1]; <0 — наклон в обратную сторону (перехлёст-вобл).
static func tilt_basis(local_dir: Vector3, amount: float) -> Basis:
	if absf(amount) <= 0.001:
		return Basis.IDENTITY
	var d := Vector3(local_dir.x, 0.0, local_dir.z)
	if d.length_squared() < 0.0001:
		return Basis.IDENTITY
	d = d.normalized()
	var axis := d.cross(Vector3.UP)
	if axis.length_squared() < 0.0001:
		return Basis.IDENTITY
	# Знак отрицательный: кренимся ПРОТИВ направления удара («отшатнулся прочь»).
	return Basis(axis.normalized(), -deg_to_rad(MAX_TILT_DEG) * clampf(amount, -1.0, 1.0))


## Полный импакт-basis: наклон (tilt_basis) + squash-stretch по |amount|. Squash
## масштабирует МЕШ вокруг его origin — звать для .basis; для пивот-позиции брать
## отдельно чистый tilt_basis (squash не должен ехать в смещение пивота).
static func impact_basis(local_dir: Vector3, amount: float, squash: float = _SQUASH) -> Basis:
	var rot := tilt_basis(local_dir, amount)
	var a := absf(clampf(amount, -1.0, 1.0))
	if a <= 0.001:
		return rot
	return rot * Basis.from_scale(Vector3(1.0 + squash * 0.5 * a, 1.0 - squash * a, 1.0 + squash * 0.5 * a))
