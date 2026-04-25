class_name Hand
extends Node3D
## Гигантская рука — координатор. Курсор мыши = позиция руки в мире.
## Действия делятся на две категории, каждая в собственном подузле:
##   - PhysicalActions (Node, hand_physical.gd) — физика: захват, бросок, магнит, подсветка.
##   - SpellActions (Node, hand_spell.gd) — заклинания (заглушка).
##
## Сама Hand отвечает только за:
##   - позиционирование под курсором с учётом высоты поверхности (raycast по физике),
##   - сглаженный трекинг скорости,
##   - проксирование сигналов категорий наружу для совместимости.

signal grabbed(item: Item)
signal released(item: Item, velocity: Vector3)

@export var hand_height: float = 2.5
## По каким слоям raycast поднимает руку (Terrain + Items по умолчанию).
## Actors и Projectiles исключены — иначе рука прыгала бы на врагов и снаряды.
@export_flags_3d_physics var terrain_mask: int = 3
@export var debug_log: bool = true

const VELOCITY_HISTORY_FRAMES := 6

@onready var grab_area: Area3D = $GrabArea
@onready var magnet_area: Area3D = $MagnetArea
@onready var physical_actions: Node = $PhysicalActions
@onready var spell_actions: Node = $SpellActions

var _velocity_history: Array[Vector3] = []
var _previous_pos: Vector3
var _initialized: bool = false
var _last_surface_label: String = ""
# Если true — Hand не перетаскивает позицию под курсор. Используется
# подмодулями, когда им нужно временно держать руку в собственном месте
# (например, PhysicalActions при щелбане крутит руку вокруг цели).
# Cursor world-position продолжает обновляться независимо от lock'а,
# чтобы подмодуль мог им рулить (например, читать угол через cursor_world_position()).
var _position_locked: bool = false
var _last_cursor_world: Vector3 = Vector3.ZERO
# Подмодули регистрируют здесь Callable, которые возвращают Array[RID] —
# объекты, исключаемые из террейн-raycast'а. Так Hand не лезет в кишки
# подмодулей через has_method/duck-typing.
var _raycast_excluders: Array[Callable] = []


func _ready() -> void:
	_last_cursor_world = global_position
	# Прокидываем сигналы физического подмодуля наверх — внешние слушатели
	# могут подключаться к hand.grabbed / hand.released как раньше.
	if physical_actions and physical_actions.has_signal("grabbed"):
		physical_actions.grabbed.connect(grabbed.emit)
	if physical_actions and physical_actions.has_signal("released"):
		physical_actions.released.connect(released.emit)
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	# Локальные сигналы остаются для тесно-связанных слушателей.
	grabbed.connect(func(item: Item) -> void: EventBus.hand_grabbed.emit(item))
	released.connect(func(item: Item, velocity: Vector3) -> void: EventBus.hand_released.emit(item, velocity))


func _process(delta: float) -> void:
	_update_cursor_world()
	if not _position_locked:
		global_position = _last_cursor_world
	_track_velocity(delta)


# --- Публичный API для подмодулей ---

func lock_position(locked: bool) -> void:
	_position_locked = locked


func cursor_world_position() -> Vector3:
	return _last_cursor_world


func register_raycast_excluder(provider: Callable) -> void:
	## provider должен возвращать Array[RID] — кого ИСКЛЮЧИТЬ из raycast террейна.
	_raycast_excluders.append(provider)


func smoothed_velocity() -> Vector3:
	if _velocity_history.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for v in _velocity_history:
		sum += v
	return sum / _velocity_history.size()


# --- Реализация позиционирования ---

func _update_cursor_world() -> void:
	# Считается каждый кадр, ВКЛЮЧАЯ моменты, когда _position_locked = true.
	# Подмодули (PhysicalActions при щелбане) читают результат через
	# cursor_world_position() — например, чтобы крутить руку вокруг цели по курсору.
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	# Этап 1: raycast'ом узнаём Y поверхности под курсором.
	# Удерживаемый предмет (если PhysicalActions что-то держит) исключаем —
	# иначе рука бесконечно «уезжает» от собственного захваченного ящика.
	var result := _raycast_terrain(ray_origin, ray_dir)
	var surface_y: float = 0.0
	if not result.is_empty():
		surface_y = (result.position as Vector3).y

	# Этап 2: точка на луче камеры на высоте surface_y + hand_height.
	# Только это даёт визуальное соответствие пиксельного курсора и руки.
	var plane := Plane(Vector3.UP, surface_y + hand_height)
	var plane_hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
	if plane_hit != null:
		_last_cursor_world = plane_hit

	if debug_log and LogConfig.master_enabled:
		_log_surface(result, surface_y)


func _raycast_terrain(origin: Vector3, dir: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * 1000.0)
	query.collision_mask = terrain_mask
	var excluded: Array[RID] = []
	for provider in _raycast_excluders:
		var rids = provider.call()
		if rids is Array:
			for rid in rids:
				excluded.append(rid)
	if not excluded.is_empty():
		query.exclude = excluded
	return space.intersect_ray(query)


func _track_velocity(delta: float) -> void:
	if not _initialized:
		_previous_pos = global_position
		_initialized = true
		return
	if delta <= 0.0:
		return
	var instant_v: Vector3 = (global_position - _previous_pos) / delta
	_velocity_history.append(instant_v)
	if _velocity_history.size() > VELOCITY_HISTORY_FRAMES:
		_velocity_history.pop_front()
	_previous_pos = global_position


# --- Логирование ---

func _log_surface(result: Dictionary, surface_y: float) -> void:
	var label: String
	if result.is_empty():
		label = "(none)"
	else:
		var collider = result.collider
		var n := str(collider.name) if collider else "?"
		var layer_bits: int = 0
		if collider and "collision_layer" in collider:
			layer_bits = collider.collision_layer
		label = "%s [%s]" % [n, _layer_name(layer_bits)]
	if label != _last_surface_label:
		print("[Hand] поверхность: %s, y=%.2f" % [label, surface_y])
		_last_surface_label = label


func _layer_name(bits: int) -> String:
	if bits == 0:
		return "—"
	var names: Array[String] = []
	for i in range(32):
		if (bits & (1 << i)) != 0:
			var key := "layer_names/3d_physics/layer_%d" % (i + 1)
			var raw = ProjectSettings.get_setting(key, "")
			var n: String = str(raw) if raw else ""
			if n.is_empty():
				n = "layer_%d" % (i + 1)
			names.append(n)
	return ",".join(names)
