class_name DefenseMarker
extends Node3D
## Маркер обороной позиции. Игрок ставит точку на земле + направление
## обстрела (через HandBuildAim drag-direction режим). [SLOT_COUNT]
## ближайших защитников назначаются на маркер, идут на слоты в линию
## перпендикулярно `facing_dir`, лицом в указанное направление.
##
## В формации защитник работает с baseline-статами. Вне формации (свободный
## патруль, не на тревоге) — debuff (см. DefenderGnome.is_in_formation).
##
## Не Damageable, не входит в skeleton_target — скелеты игнорируют маркер,
## это тактическое решение игрока, а не цель.

## Все маркеры в группе для быстрого lookup'а (Camp на спавне ищет ближайших
## защитников, journal может отображать список).
const DEFENSE_MARKER_GROUP := &"defense_marker"
## Защитников на одну линию обороны. Фиксированное 3 — дизайнерское решение
## (2026-05-14): два прикрывают, один тянет дальний фланг.
const SLOT_COUNT: int = 3

## Радиус кольца слотов вокруг маркера. 1.5м даёт визуально читаемую линию,
## защитники не упираются друг в друга, при стрельбе не пересекают.
@export var slot_radius: float = 1.5
## Направление обстрела (XZ, world-space). На спавне приходит из HandBuildAim,
## .y занулена. Защитники в слотах поворачиваются в эту сторону.
@export var facing_dir: Vector3 = Vector3.FORWARD

signal destroyed

@onready var _flag_mesh: MeshInstance3D = $FlagMesh
@onready var _arrow_mesh: MeshInstance3D = $ArrowMesh


func _ready() -> void:
	add_to_group(DEFENSE_MARKER_GROUP)
	# Ориентация визуального arrow'а — вдоль facing_dir. _ready может
	# случиться до setup'а из спавнера; setup перевызывает _orient.
	_orient_arrow()


## Вызывается спавнером (Camp.try_build_defense_marker) сразу после
## instantiate + add_child. Ставит позицию и направление.
func setup(world_pos: Vector3, dir_xz: Vector3) -> void:
	global_position = world_pos
	var horizontal := Vector3(dir_xz.x, 0.0, dir_xz.z)
	if horizontal.length_squared() > 0.0001:
		facing_dir = horizontal.normalized()
	else:
		facing_dir = Vector3.FORWARD
	if is_inside_tree():
		_orient_arrow()


## Возвращает позицию i-го слота в линии перпендикулярно facing_dir.
## i = 0 — левый край линии, 1 — центр, 2 — правый край. «Лево/право»
## относительно направления обстрела.
func get_slot_position(i: int) -> Vector3:
	if i < 0 or i >= SLOT_COUNT:
		return global_position
	# right = facing × UP (right-hand rule, Godot). Линия слотов перпендикулярна
	# facing_dir и параллельна земле.
	var right: Vector3 = facing_dir.cross(Vector3.UP).normalized()
	# Распределение по линии: −radius, 0, +radius. Центр — у самого маркера.
	var lateral_offset: float = (float(i) - 1.0) * slot_radius
	return global_position + right * lateral_offset


## Удаляет маркер. Camp слушает destroyed-сигнал и снимает defender'ов
## с маркера. Используется при отмене формации игроком.
func destroy() -> void:
	destroyed.emit()
	queue_free()


## Перевыставляет визуальный arrow вдоль facing_dir. Mesh-arrow в .tscn
## смотрит локальным −Z (look_at convention в Godot).
func _orient_arrow() -> void:
	if _arrow_mesh == null:
		return
	var forward: Vector3 = facing_dir
	if forward.length_squared() < 0.0001:
		return
	var look_target: Vector3 = global_position + forward
	# look_at смотрит на цель локальным −Z. Up = Y, не FORWARD (parent uses Y).
	_arrow_mesh.look_at(look_target, Vector3.UP)
