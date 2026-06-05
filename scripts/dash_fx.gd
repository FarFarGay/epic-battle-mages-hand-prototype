class_name DashFx
extends RefCounted
## Общий визуал рывка — ОДИН источник для башни (игрок) и врага-меха, чтобы
## эффект был буквально идентичным: наклон корпуса вперёд + вытягивание вдоль
## рывка + after-image-трейл. Тюнинг в консте́нтах ниже (меняешь тут — меняется у
## обоих сразу). Caller держит свою сглаженную интенсивность `amount` (0↔1) и
## таймер спавна призраков, а саму геометрию/материалы считает этот хелпер.

const TILT_MAX: float = 0.22       # наклон корпуса вперёд (рад)
const STRETCH: float = 0.20        # растяжение вдоль рывка (доля)
const SQUASH: float = 0.10         # сжатие поперёк/по вертикали (доля)
const FX_RATE: float = 14.0        # скорость нарастания/спада интенсивности (exp-decay)

const GHOST_INTERVAL: float = 0.03 # интервал спавна призраков трейла (сек) — чаще = плавнее
const GHOST_LIFE: float = 0.22     # время угасания призрака (сек) — короче = чище
const GHOST_ALPHA: float = 0.28    # стартовая прозрачность (мягкий смер, не «дубли»)
const GHOST_EMISSION: float = 0.25 # энергия эмиссии призрака (не вспыхивает)
const GHOST_SHRINK: float = 0.9    # призрак чуть меньше меша — нестится внутрь силуэта, аккуратнее
const GHOST_BACK: float = 1.6      # сдвиг призрака назад (против рывка), м — не лезет на корпус
const GHOST_COLOR: Color = Color(0.45, 0.65, 1.0, 1.0)


## Базис-модификатор рывка (наклон вперёд + стретч вдоль dir). Композится СЛЕВА:
##   visual.basis = DashFx.dash_basis(dir, amount) * base_basis
## amount<=0 → IDENTITY (без эффекта). dir — мировое направление рывка (XZ).
static func dash_basis(dir_world: Vector3, amount: float) -> Basis:
	if amount <= 0.005:
		return Basis.IDENTITY
	var f: Vector3 = dir_world
	f.y = 0.0
	if f.length_squared() < 0.0001:
		return Basis.IDENTITY
	f = f.normalized()
	var axis: Vector3 = Vector3.UP.cross(f)  # горизонтальная ось наклона (перпендикуляр к dir)
	if axis.length() < 0.001:
		return Basis.IDENTITY
	axis = axis.normalized()
	# Наклон верха корпуса в сторону рывка.
	var lean := Basis(axis, TILT_MAX * amount)
	# Стретч вдоль рывка + squash поперёк, в кадре (right=axis, up, forward=f).
	var frame := Basis(axis, Vector3.UP, f)
	var s: float = 1.0 + STRETCH * amount
	var sq: float = 1.0 - SQUASH * amount
	var scale_b: Basis = frame * Basis.from_scale(Vector3(sq, sq, s)) * frame.transposed()
	return lean * scale_b


## Спавнит один угасающий after-image меша mesh_inst — позади (против dir), чуть
## меньше, мягкий. Caller вызывает с интервалом GHOST_INTERVAL. Призрак сам
## чистится через tween.
static func spawn_ghost(root: Node, mesh_inst: MeshInstance3D, dir_world: Vector3) -> void:
	if root == null or mesh_inst == null or mesh_inst.mesh == null:
		return
	var ghost := MeshInstance3D.new()
	ghost.mesh = mesh_inst.mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(GHOST_COLOR.r, GHOST_COLOR.g, GHOST_COLOR.b, GHOST_ALPHA)
	mat.emission_enabled = true
	mat.emission = GHOST_COLOR
	mat.emission_energy_multiplier = GHOST_EMISSION
	ghost.material_override = mat
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ghost)
	var gt: Transform3D = mesh_inst.global_transform
	var f: Vector3 = dir_world
	f.y = 0.0
	if f.length_squared() > 0.0001:
		gt.origin -= f.normalized() * GHOST_BACK
	ghost.global_transform = gt
	ghost.scale = ghost.scale * GHOST_SHRINK
	var tw := ghost.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, GHOST_LIFE)
	tw.tween_callback(ghost.queue_free)
