class_name SuperCarrier
extends Node3D
## Носитель супер-удара. Один большой снаряд из tower'а в точку разделения
## (burst_pos над _aim_target). На burst'е разлетается на маленькие фаерболы.
##
## Двухфазная траектория «как ракета», по образцу Fireball:
##   1. **Boost** — короткий «оттяг» из башни вверх + slight forward + sway
##      (perp-сторона). Gravity тянет вниз. Создаёт стартовую дугу выпуска.
##   2. **Homing** — поворот на target с плавным набором скорости.
##      `homing_drift_angle_deg` поворачивает стартовый вектор от
##      target-направления на random ± угол вокруг UP, дальше slerp
##      возвращает на цель — характерный «крюк», читается как «ракета шатается».
##
## На arrival к burst_pos (proximity check) — emit `burst(position)` и self-free.
## Carrier не наносит damage, AOE/коллизий нет.

signal burst(position: Vector3)

## Радиус-сред захвата burst-точки: при distance² <= этого — burst.
## 4.0 (= 2м radius) с запасом — на homing_max_speed=48 шаг ~0.8м/тик,
## 0.6м-захват пропускал мимо и carrier зацикливался вокруг точки.
const HIT_PROXIMITY_SQ: float = 4.0
## Если был ближе чем это — но удалился (overshoot detection ниже),
## сработает burst немедленно. Комплиментарный к HIT_PROXIMITY_SQ для
## случаев «прошёл насквозь между кадрами».
const OVERSHOOT_TRIP_DISTANCE: float = 3.5
const SAFETY_LIFETIME: float = 6.0

enum Phase { BOOST, HOMING }

@export_group("Visual")
## Множитель размера mesh'а. Mesh radius=0.4 в .tscn, итоговый = 0.4×scale.
## По дизайнерскому решению (2026-05-10) carrier должен быть не больше чем в
## 2 раза больше обычного fireball'а (radius ≈ 0.26). 1.2 → 0.48 (~1.85×).
@export var visual_scale: float = 1.2
@export_group("")

var _target_pos: Vector3
var _velocity: Vector3
var _phase: int = Phase.BOOST
var _current_speed: float = 0.0  # для HOMING-фазы
var _age: float = 0.0
var _bursted: bool = false
## Минимальная дистанция до burst_pos за всю жизнь carrier'а. Используется
## для overshoot detection: если carrier был близко (< OVERSHOOT_TRIP) и
## начал удаляться — он точно проскочил, burst немедленно.
var _min_distance_to_target: float = INF

# Параметры — задаются HandSuper в setup(). Не @export'ы здесь — координатор
# держит их на своей стороне (один источник правды + per-cast tweak).
var _boost_duration: float
var _boost_gravity: float
var _homing_acceleration: float
var _homing_max_speed: float
var _homing_drift_angle: float = 0.0
var _homing_turn_rate: float

@onready var _mesh: MeshInstance3D = get_node_or_null("MeshInstance3D") as MeshInstance3D


func _ready() -> void:
	if _mesh != null:
		_mesh.scale = Vector3.ONE * visual_scale


## Конфиг ракеты. Сигнатура — копия Fireball.setup без AOE-параметров (нет
## damage/radius/explode_mask/knockback). Carrier на arrival только emit'ит
## сигнал, AOE делают payload-фаерболы которые HandSuper спавнит.
func setup(
	launch_pos: Vector3,
	target_pos: Vector3,
	boost_duration: float,
	boost_velocity_up: float,
	boost_velocity_forward: float,
	boost_gravity: float,
	boost_drift_velocity: float,
	homing_initial_speed: float,
	homing_acceleration: float,
	homing_max_speed: float,
	homing_drift_angle_deg: float,
	homing_turn_rate: float,
) -> void:
	global_position = launch_pos
	_target_pos = target_pos
	_boost_duration = boost_duration
	_boost_gravity = boost_gravity
	_homing_acceleration = homing_acceleration
	_homing_max_speed = homing_max_speed
	_homing_turn_rate = homing_turn_rate

	_homing_drift_angle = deg_to_rad(randf_range(-homing_drift_angle_deg, homing_drift_angle_deg))

	var dx: float = target_pos.x - launch_pos.x
	var dz: float = target_pos.z - launch_pos.z
	var horizontal_dist_sq: float = dx * dx + dz * dz
	var dir_xz: Vector3 = Vector3(dx, 0.0, dz).normalized() if horizontal_dist_sq > 0.01 else Vector3.ZERO
	# Боковой sway (perpendicular к forward через cross UP) даёт «дрожь» при
	# взлёте — каждый каст уходит чуть в свою сторону.
	var perp_xz: Vector3 = dir_xz.cross(Vector3.UP).normalized() if dir_xz.length_squared() > 0.01 else Vector3(1.0, 0.0, 0.0)
	var sway: float = randf_range(-1.0, 1.0) * boost_drift_velocity
	_velocity = Vector3.UP * boost_velocity_up + dir_xz * boost_velocity_forward + perp_xz * sway
	_phase = Phase.BOOST
	_current_speed = homing_initial_speed


func _physics_process(delta: float) -> void:
	if _bursted:
		return
	_age += delta
	if _age > SAFETY_LIFETIME:
		# Аварийная очистка: что-то пошло не так — снаряд не дошёл. Без burst'а.
		queue_free()
		return

	if _phase == Phase.BOOST:
		# Стартовая дуга: gravity пригибает velocity.y. По истечении
		# boost_duration — переход в HOMING с initial drift-angle.
		_velocity.y -= _boost_gravity * delta
		global_position += _velocity * delta
		if _age >= _boost_duration:
			_phase = Phase.HOMING
			# Стартовое направление homing'а: target-dir повёрнутая на
			# random drift-angle вокруг UP — характерный «крюк».
			var to_target_init: Vector3 = _target_pos - global_position
			if to_target_init.length_squared() > 0.001:
				var desired_init: Vector3 = to_target_init.normalized()
				var drift_basis := Basis(Vector3.UP, _homing_drift_angle)
				_velocity = (drift_basis * desired_init) * _current_speed
	else:
		# Homing: speed растёт линейно (acceleration), direction плавно
		# slerp'ится к burst_pos. Decay = 1-exp(-rate*dt) — frame-rate independent.
		_current_speed = minf(_current_speed + _homing_acceleration * delta, _homing_max_speed)
		var to_target: Vector3 = _target_pos - global_position
		var dist: float = to_target.length()
		if dist < 0.001:
			_do_burst()
			return
		var desired_dir: Vector3 = to_target / dist
		var current_dir: Vector3 = _velocity.normalized() if _velocity.length_squared() > 0.001 else desired_dir
		var decay: float = 1.0 - exp(-_homing_turn_rate * delta)
		var new_dir: Vector3 = current_dir.slerp(desired_dir, decay).normalized()
		_velocity = new_dir * _current_speed
		global_position += _velocity * delta

	_orient_along_velocity()

	# Триггер burst'а — два механизма:
	#   1. Proximity: distance² ≤ HIT_PROXIMITY_SQ. Радиус ~2м с запасом
	#      под высокую homing-скорость и физический шаг.
	#   2. Overshoot: carrier был ближе OVERSHOOT_TRIP_DISTANCE, потом
	#      начал удаляться. Без этой проверки на больших скоростях carrier
	#      проскакивал burst-точку между кадрами и зацикливался вокруг неё
	#      по homing-slerp'у.
	var to_target_3d: Vector3 = _target_pos - global_position
	var distance: float = to_target_3d.length()
	if distance * distance <= HIT_PROXIMITY_SQ:
		_do_burst()
		return
	if _phase == Phase.HOMING:
		if distance < _min_distance_to_target:
			_min_distance_to_target = distance
		elif _min_distance_to_target < OVERSHOOT_TRIP_DISTANCE:
			_do_burst()


func _orient_along_velocity() -> void:
	var dir_xz: Vector3 = Vector3(_velocity.x, 0.0, _velocity.z)
	if dir_xz.length_squared() < 0.01:
		return
	dir_xz = dir_xz.normalized()
	var up: Vector3 = Vector3.UP
	var right: Vector3 = dir_xz.cross(up).normalized()
	var tx_basis := Basis()
	tx_basis.x = dir_xz
	tx_basis.y = up
	tx_basis.z = right
	global_transform.basis = tx_basis


func _do_burst() -> void:
	if _bursted:
		return
	_bursted = true
	# Берём текущую позицию (не зафиксированный _target_pos) — если carrier
	# чуть проскочил мимо из-за homing-overshoot'а, payload'ы вылетают
	# именно ОТТУДА, где carrier визуально завершился.
	burst.emit(global_position)
	queue_free()
