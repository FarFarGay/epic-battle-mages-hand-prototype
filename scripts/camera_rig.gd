class_name CameraRig
extends Node3D
## Плавно следует за указанным узлом. Цель задаётся через @export.
## Колесо мыши приближает/отдаляет камеру: оффсет Camera3D (заданный в .tscn)
## масштабируется множителем `_zoom`. Направление обзора и угол сохраняются —
## меняется только дистанция от rig'а до камеры.
##
## Focus override: внешние системы (DungeonZone) могут временно подменять
## цель — `set_focus_override(node)` переключает камеру на переданный Node3D,
## `clear_focus_override()` возвращает на дефолтную (`target_path`). Если
## override-узел вдруг стал freed — фоллбэк на дефолт автоматически.

const CAMERA_RIG_GROUP := &"camera_rig"

@export_node_path("Node3D") var target_path: NodePath
@export var follow_speed: float = 8.0

@export_group("Zoom")
## Множитель оффсета за один щелчок колеса. <1 → шаг приближения, дальше
## применяется обратный к нему (1/zoom_step) на отдаление. 0.9 = 10% за клик.
@export var zoom_step: float = 0.9
## Минимум/максимум множителя относительно базового оффсета из .tscn.
## 1.0 = «как в сцене»; 0.4 — близко, 3.0 — далеко.
## С 2026-05-15 zoom_max урезан 5.0→3.0: на zoom>3 видимая область выходит
## за Skeleton.lod_far_distance (80м) — скелеты там FAR-LOD, мины/ловушки
## в этой зоне не триггерятся (Area3D не видит layer=0 тела). Cap'аем зум
## до радиуса гарантированной работы физики. Скоординировано с
## Skeleton.lod_far_distance — если бампать одно, бампать и другое.
@export var zoom_min: float = 0.4
@export var zoom_max: float = 3.0
## Скорость экспоненциального доезда к целевому зуму (1/c). Большое = резко.
@export var zoom_speed: float = 10.0

@export_group("Shake")
## Trauma-based тряска: травма копится через add_trauma / EventBus.camera_shake,
## спадает со временем, смещение/крен ∝ травма² (резкий falloff — бьёт и быстро
## гаснет). Звать ТОЛЬКО на сильных событиях, не на каждый выстрел.
@export var shake_decay: float = 1.4          # 1/сек — спад травмы
@export var shake_max_offset: float = 0.3     # макс смещение камеры (м) при травме=1
@export var shake_max_roll_deg: float = 1.6   # макс крен (°) при травме=1
## Затухание по дистанции от центра обзора: ближе full_radius — полная сила,
## дальше zero_radius — ноль, между — smoothstep. Дальние взрывы не трясут.
@export var shake_full_radius: float = 18.0
@export var shake_zero_radius: float = 65.0

@export_group("Orbit")
## Поворот камеры вокруг оси Y при зажатом колесе (MMB) + движении мыши.
## Rig — Node3D, камера сидит дочкой на оффсете; вращая rotation.y rig'а,
## камера орбитит вокруг точки-цели. Чувствительность — радиан на пиксель
## движения мыши. 0.005 ≈ 0.28°/px (полный оборот за ~1280px драга).
@export var orbit_sensitivity: float = 0.005
## Инвертировать направление поворота (драг вправо → по/против часовой).
@export var orbit_invert: bool = false

@onready var _camera: Camera3D = $Camera3D

## Идёт ли сейчас орбита (зажат MMB). Драг мыши в этом состоянии крутит rig.
var _orbiting: bool = false

var _default_target: Node3D
## Временная подмена цели через [method set_focus_override]. Если задан и
## жив — камера следит за ним. Иначе — за [member _default_target]. Без
## стэка: один override за раз (для прототипа достаточно — один данж).
var _focus_override: Node3D = null
## Базовый оффсет Camera3D из .tscn — сохраняем при _ready, чтобы зум всегда
## масштабировал именно его, а не накапливал ошибки от предыдущих кадров.
var _base_offset: Vector3 = Vector3.ZERO
var _zoom: float = 1.0
var _zoom_target: float = 1.0
## Тряска: текущая травма 0..1 и базовый поворот камеры (крен накладываем поверх).
var _trauma: float = 0.0
var _base_cam_rotation: Vector3 = Vector3.ZERO


func _ready() -> void:
	add_to_group(CAMERA_RIG_GROUP)
	if not target_path.is_empty():
		_default_target = get_node_or_null(target_path)
	if _default_target:
		global_position = _default_target.global_position
	if _camera:
		_base_offset = _camera.position
		_base_cam_rotation = _camera.rotation
	EventBus.camera_shake.connect(_on_camera_shake)


## Эффективная цель этого кадра. Override — если задан и жив; иначе дефолт.
## is_instance_valid защищает от случая, когда override-узел queue_free'нулся,
## а внешний код не успел/забыл вызвать [method clear_focus_override].
func _current_target() -> Node3D:
	if is_instance_valid(_focus_override):
		return _focus_override
	return _default_target


## Подмена цели камеры (зовётся DungeonZone когда первый солдат вошёл
## в данж). Без эффекта если node == null — для очистки используйте
## [method clear_focus_override].
func set_focus_override(node: Node3D) -> void:
	if node == null:
		return
	_focus_override = node


## Возврат на дефолтную цель из инспектора.
func clear_focus_override() -> void:
	_focus_override = null


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		if b.button_index == MOUSE_BUTTON_WHEEL_UP and b.pressed:
			_zoom_target = clampf(_zoom_target * zoom_step, zoom_min, zoom_max)
		elif b.button_index == MOUSE_BUTTON_WHEEL_DOWN and b.pressed:
			_zoom_target = clampf(_zoom_target / zoom_step, zoom_min, zoom_max)
		elif b.button_index == MOUSE_BUTTON_MIDDLE:
			# Зажатие колеса включает орбиту; отпускание — выключает.
			_orbiting = b.pressed
	elif event is InputEventMouseMotion and _orbiting:
		# Драг при зажатом MMB крутит rig вокруг Y → орбита камеры вокруг цели.
		var dir := -1.0 if orbit_invert else 1.0
		rotation.y -= (event as InputEventMouseMotion).relative.x * orbit_sensitivity * dir


func _process(delta: float) -> void:
	var t := _current_target()
	if t:
		global_position = global_position.lerp(t.global_position, follow_speed * delta)
	_update_zoom(delta)
	_apply_shake(delta)


func _update_zoom(delta: float) -> void:
	# Только ведём _zoom к цели; саму позицию камеры пишет _apply_shake каждый кадр
	# (зум + тряска вместе), иначе тряска и зум дрались бы за _camera.position.
	if is_equal_approx(_zoom, _zoom_target):
		return
	_zoom = lerpf(_zoom, _zoom_target, clampf(zoom_speed * delta, 0.0, 1.0))
	# Snap к целевому, когда подъехали достаточно близко — иначе lerp asymp-
	# тотически приближается, и is_equal_approx долго не срабатывает.
	if absf(_zoom - _zoom_target) < 0.001:
		_zoom = _zoom_target


## Добавить травму камере (через EventBus.camera_shake). Амплитуда ослабляется по
## расстоянию от центра обзора (global_position rig'а ≈ точка, на которую смотрим):
## ближе full_radius — полно, дальше zero_radius — ноль. Дальние события не трясут.
func _on_camera_shake(amount: float, position: Vector3) -> void:
	var dist: float = global_position.distance_to(position)
	var falloff: float = 1.0 - smoothstep(shake_full_radius, shake_zero_radius, dist)
	if falloff <= 0.0:
		return
	_trauma = clampf(_trauma + amount * falloff, 0.0, 1.0)


## Каждый кадр: позиция камеры = базовый оффсет×зум + экранное смещение, поворот =
## базовый + крен. Смещение/крен ∝ травма² (резкий спад — бьёт и быстро гаснет).
## Травма=0 → ровно зум-позиция, без эффекта (нет регрессии статичной камеры).
func _apply_shake(delta: float) -> void:
	if _camera == null:
		return
	if _trauma > 0.0:
		_trauma = maxf(_trauma - shake_decay * delta, 0.0)
	var s: float = _trauma * _trauma
	var pos: Vector3 = _base_offset * _zoom
	var rot: Vector3 = _base_cam_rotation
	if s > 0.0:
		# Смещение масштабируем на _zoom: при отзуме Camera3D физически дальше от
		# сцены (base_offset×zoom), и фикс. сдвиг давал бы микроскопическую тряску
		# на экране. ×_zoom держит экранную амплитуду одинаковой на любом зуме.
		# Крен (rot.z) — угловой, зум-инвариантен, его не трогаем.
		pos += Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * (shake_max_offset * s * _zoom)
		rot.z += randf_range(-1.0, 1.0) * deg_to_rad(shake_max_roll_deg) * s
	_camera.position = pos
	_camera.rotation = rot
