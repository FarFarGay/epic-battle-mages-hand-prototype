class_name SuperCarrier
extends Node3D
## Носитель супер-удара. Один большой снаряд, вылетает из башни по
## баллистической дуге и в `burst_pos` (точка над _aim_target) разделяется
## на N маленьких снарядов (payload) — те уже сами падают на землю и взрываются.
##
## Движение: парабола от `_launch_pos` до `_burst_pos` за `flight_time` секунд.
## Вертикальная скорость подбирается аналитически: за t секунд при гравитации g
## y-компонента отрабатывает (burst.y - launch.y), стартовый vy = (Δy + 0.5 g t²) / t.
## Горизонтальная — линейная Δh / t.
##
## Не использует Fireball — там логика homing/AOE/burn-patch, не нужная здесь.
## Carrier не наносит damage, не реагирует на физику до burst'а.
##
## На burst'е emit'ит сигнал — координатор HandSuper подписан, спавнит payload'ы.

signal burst(position: Vector3)

const SAFETY_LIFETIME: float = 4.0  # на случай если что-то пошло не так

@export_group("Visual")
## Множитель размера mesh'а. Mesh radius=0.4 в .tscn, итоговый = 0.4×scale.
## По дизайнерскому решению (2026-05-10) carrier должен быть не больше чем в
## 2 раза больше обычного fireball'а (radius ≈ 0.26). 1.2 → 0.48 (~1.85×).
@export var visual_scale: float = 1.2
@export_group("")

var _launch_pos: Vector3 = Vector3.ZERO
var _burst_pos: Vector3 = Vector3.ZERO
var _velocity: Vector3 = Vector3.ZERO
var _gravity: float = 12.0
var _flight_time: float = 0.9
var _elapsed: float = 0.0
var _burst_done: bool = false

@onready var _mesh: MeshInstance3D = $MeshInstance3D if has_node("MeshInstance3D") else null
@onready var _light: OmniLight3D = $Light if has_node("Light") else null


## Инициализация перед `add_child`. burst.y > launch.y → парабола вверх с
## apex в районе burst.y или выше.
func setup(launch_pos: Vector3, burst_pos: Vector3, flight_time: float, gravity: float = 12.0) -> void:
	_launch_pos = launch_pos
	_burst_pos = burst_pos
	_flight_time = maxf(flight_time, 0.05)
	_gravity = gravity
	# Аналитика: y(t) = launch.y + vy*t - 0.5*g*t² → burst.y
	# vy = (Δy + 0.5*g*t²) / t
	var dy: float = burst_pos.y - launch_pos.y
	var vy: float = (dy + 0.5 * _gravity * _flight_time * _flight_time) / _flight_time
	var dh: Vector3 = Vector3(burst_pos.x - launch_pos.x, 0.0, burst_pos.z - launch_pos.z)
	var v_horizontal: Vector3 = dh / _flight_time
	_velocity = v_horizontal + Vector3.UP * vy
	global_position = launch_pos


func _ready() -> void:
	if _mesh != null:
		_mesh.scale = Vector3.ONE * visual_scale


func _physics_process(delta: float) -> void:
	if _burst_done:
		return
	_elapsed += delta
	# Линейная горизонтальная + аналитическая вертикальная (vy -= g*delta)
	_velocity.y -= _gravity * delta
	global_position += _velocity * delta

	# Условие burst'а: либо отработали запланированное время полёта, либо
	# уже близко к burst_pos (на случай численных ошибок). Safety —
	# абсолютный лимит 4 секунды.
	if _elapsed >= _flight_time:
		_do_burst()
		return
	if _elapsed >= SAFETY_LIFETIME:
		_do_burst()
		return


func _do_burst() -> void:
	if _burst_done:
		return
	_burst_done = true
	# Берём текущую позицию (не зафиксированный _burst_pos) — если численная
	# ошибка увела carrier чуть в сторону, payload'ы вылетают именно ОТТУДА,
	# где визуально завершился полёт.
	burst.emit(global_position)
	queue_free()
