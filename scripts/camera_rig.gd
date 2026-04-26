extends Node3D
## Плавно следует за указанным узлом. Цель задаётся через @export.
## Колесо мыши приближает/отдаляет камеру: оффсет Camera3D (заданный в .tscn)
## масштабируется множителем `_zoom`. Направление обзора и угол сохраняются —
## меняется только дистанция от rig'а до камеры.

@export_node_path("Node3D") var target_path: NodePath
@export var follow_speed: float = 8.0

@export_group("Zoom")
## Множитель оффсета за один щелчок колеса. <1 → шаг приближения, дальше
## применяется обратный к нему (1/zoom_step) на отдаление. 0.9 = 10% за клик.
@export var zoom_step: float = 0.9
## Минимум/максимум множителя относительно базового оффсета из .tscn.
## 1.0 = «как в сцене»; 0.4 — близко, 2.5 — далеко.
@export var zoom_min: float = 0.4
@export var zoom_max: float = 2.5
## Скорость экспоненциального доезда к целевому зуму (1/c). Большое = резко.
@export var zoom_speed: float = 10.0

@onready var _camera: Camera3D = $Camera3D

var _target: Node3D
## Базовый оффсет Camera3D из .tscn — сохраняем при _ready, чтобы зум всегда
## масштабировал именно его, а не накапливал ошибки от предыдущих кадров.
var _base_offset: Vector3 = Vector3.ZERO
var _zoom: float = 1.0
var _zoom_target: float = 1.0


func _ready() -> void:
	if not target_path.is_empty():
		_target = get_node_or_null(target_path)
	if _target:
		global_position = _target.global_position
	if _camera:
		_base_offset = _camera.position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var b := event as InputEventMouseButton
		if b.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_target = clampf(_zoom_target * zoom_step, zoom_min, zoom_max)
		elif b.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_target = clampf(_zoom_target / zoom_step, zoom_min, zoom_max)


func _process(delta: float) -> void:
	if _target:
		global_position = global_position.lerp(_target.global_position, follow_speed * delta)
	_update_zoom(delta)


func _update_zoom(delta: float) -> void:
	if _camera == null:
		return
	if is_equal_approx(_zoom, _zoom_target):
		return
	_zoom = lerpf(_zoom, _zoom_target, clampf(zoom_speed * delta, 0.0, 1.0))
	# Snap к целевому, когда подъехали достаточно близко — иначе lerp asymp-
	# тотически приближается, и is_equal_approx долго не срабатывает.
	if absf(_zoom - _zoom_target) < 0.001:
		_zoom = _zoom_target
	_camera.position = _base_offset * _zoom
