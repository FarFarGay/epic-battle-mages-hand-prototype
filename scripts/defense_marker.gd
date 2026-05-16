class_name DefenseMarker
extends Node3D
## Маркер обороной позиции. Игрок ставит точку на земле + направление
## обстрела (через HandBuildAim drag-direction режим). `slot_count`
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
## Дефолтное количество слотов в линии обороны. Игрок может варьировать
## через UI-счётчик в defender card (HUD); per-instance значение в `slot_count`.
const DEFAULT_SLOT_COUNT: int = 3

## Сколько защитников ставится на эту линию. Игрок выбирает в HUD'е перед
## командой «На защиту». 1..N (N = defender_count лагеря). Defaults 3 —
## текущее историческое поведение (2 прикрывают, 1 тянет дальний фланг).
## Per-instance (а не const): разные линии могут иметь разный размер.
@export var slot_count: int = DEFAULT_SLOT_COUNT
## Радиус кольца слотов вокруг маркера. 1.5м даёт визуально читаемую линию,
## защитники не упираются друг в друга, при стрельбе не пересекают.
@export var slot_radius: float = 1.5
## Случайное смещение каждого слота для «небрежной» линии. Lateral — вдоль
## линии (right axis), depth — вперёд/назад от линии (facing axis). Малые
## значения — иначе формация распадается визуально и стрелы пересекаются.
@export var slot_jitter_lateral: float = 0.3
@export var slot_jitter_depth: float = 0.25
## Направление обстрела (XZ, world-space). На спавне приходит из HandBuildAim,
## .y занулена. Защитники в слотах поворачиваются в эту сторону.
@export var facing_dir: Vector3 = Vector3.FORWARD

## Детерминистичный per-slot шум — генерится в setup() после установки
## facing_dir. World-space offset (не пересчитывается при чтении), чтобы
## get_slot_position возвращал стабильное значение, а не дрожащее каждый
## кадр (иначе защитники бесконечно идут к слегка смещённой точке).
var _slot_offsets: Array[Vector3] = []

signal destroyed

@onready var _flag_mesh: MeshInstance3D = $FlagMesh
@onready var _arrow_mesh: MeshInstance3D = $ArrowMesh


func _ready() -> void:
	add_to_group(DEFENSE_MARKER_GROUP)
	# Ориентация визуального arrow'а — вдоль facing_dir. _ready может
	# случиться до setup'а из спавнера; setup перевызывает _orient.
	_orient_arrow()


## Вызывается спавнером (Camp.place_defense_formation) сразу после
## instantiate + add_child. Ставит позицию, направление и желаемое
## количество слотов (clamp ≥ 1, max не клампим — Camp сам передаёт
## clamped по defender_count). Генерит детерминистичный jitter для
## «небрежной» линии.
func setup(world_pos: Vector3, dir_xz: Vector3, count: int = DEFAULT_SLOT_COUNT) -> void:
	global_position = world_pos
	var horizontal := Vector3(dir_xz.x, 0.0, dir_xz.z)
	if horizontal.length_squared() > 0.0001:
		facing_dir = horizontal.normalized()
	else:
		facing_dir = Vector3.FORWARD
	slot_count = maxi(1, count)
	_generate_slot_offsets()
	if is_inside_tree():
		_orient_arrow()


## Возвращает позицию i-го слота в линии перпендикулярно facing_dir.
## i = 0 — левый край, slot_count-1 — правый край. Линия отцентрирована
## относительно маркера (центр массы слотов = global_position). К базовой
## позиции прибавляется детерминистичный jitter — линия выглядит живой.
func get_slot_position(i: int) -> Vector3:
	if i < 0 or i >= slot_count:
		return global_position
	# right = facing × UP (right-hand rule, Godot). Линия слотов перпендикулярна
	# facing_dir и параллельна земле.
	var right: Vector3 = facing_dir.cross(Vector3.UP).normalized()
	# Центрированное распределение: для N слотов offset = (i − (N−1)/2) × radius.
	# N=1 → [0]; N=2 → [−0.5r, +0.5r]; N=3 → [−r, 0, +r]; N=5 → [−2r, −r, 0, r, 2r].
	# Совместимо со старым SLOT_COUNT=3 case'ом (тот же лейаут).
	var lateral_offset: float = (float(i) - float(slot_count - 1) * 0.5) * slot_radius
	var base: Vector3 = global_position + right * lateral_offset
	if i < _slot_offsets.size():
		base += _slot_offsets[i]
	return base


## Генерит per-slot world-space jitter — раз на setup, в дальнейшем читается
## из get_slot_position. Без кэша защитники бы каждый кадр шли к слегка
## смещённой точке (RNG нестабильна между вызовами).
func _generate_slot_offsets() -> void:
	_slot_offsets.clear()
	var right: Vector3 = facing_dir.cross(Vector3.UP).normalized()
	for i in range(slot_count):
		var lat: float = randf_range(-slot_jitter_lateral, slot_jitter_lateral)
		var depth: float = randf_range(-slot_jitter_depth, slot_jitter_depth)
		_slot_offsets.append(right * lat + facing_dir * depth)


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
