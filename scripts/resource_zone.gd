@tool
class_name ResourceZone
extends Node3D
## Зона ресурсов — прямоугольник `size` (X×Z в метрах), который при старте сцены
## спавнит `count` инстансов `ResourcePile` в случайных точках внутри. Дизайнер
## работает по простому циклу: drag ноду → выставить resource_type/count/size →
## сохранить. На `_ready` зона разбрасывает кучи и удаляет визуальный индикатор.
##
## Поворот зоны вокруг Y учитывается (как у SpawnZone): локальные координаты
## прогоняются через `global_transform`, повёрнутые зоны работают корректно.
##
## Визуал — плоский box-индикатор, виден только в редакторе. Цвет зависит
## от `resource_type` для быстрого визуального отличия в редакторе.

## Полные размеры прямоугольника зоны по локальным X (size.x) и Z (size.y).
@export var size: Vector2 = Vector2(20.0, 20.0):
	set(value):
		size = Vector2(maxf(value.x, 0.0), maxf(value.y, 0.0))
		_refresh_visual()

## Тип ресурса. ResourcePile.ResourceType — enum; здесь дублируем как int,
## потому что @export'у enum нужен прямой type-reference, а cyclic-import
## между ResourceZone↔ResourcePile создаёт проблему. Маппинг:
## 0=GENERIC, 1=WOOD, 2=STONE, 3=IRON, 4=FOOD.
@export_enum("Generic", "Wood", "Stone", "Iron", "Food") var resource_type: int = 1:
	set(value):
		resource_type = value
		_refresh_visual()

## Сколько pile'ов спавнить в зоне на _ready. Случайное равномерное
## распределение в прямоугольнике, Y берётся с зоны.
@export_range(1, 100) var count: int = 8

## Сколько units на pile (= сколько раз гном с него возьмёт). Передаётся
## в spawned ResourcePile через прямое присваивание перед добавлением в дерево.
@export_range(1, 50) var units_per_pile: int = 5

## Минимальная дистанция между соседними кучами в зоне, чтобы они не
## наслаивались. 0 — без фильтра (uniform random). Полезно когда count
## большой и size маленький — без фильтра кучи могут перекрываться визуально.
@export var min_spacing: float = 1.5

## Сцена, инстансы которой спавнить. По дефолту — `res://scenes/resource_pile.tscn`.
## Задаётся через инспектор или через preload в коде.
@export var pile_scene: PackedScene

## Куда добавлять заспавненные pile'ы. Пусто → в `current_scene` (чтобы pile'ы
## пережили возможное удаление зоны или её родителя).
@export_node_path("Node") var spawn_root_path: NodePath


# Цвет визуального индикатора по resource_type — для удобства различия в редакторе.
const _TYPE_COLORS: Array = [
	Color(0.4, 0.75, 0.3, 0.4),    # GENERIC — зелёный
	Color(0.45, 0.28, 0.15, 0.45), # WOOD — коричневый
	Color(0.55, 0.55, 0.55, 0.45), # STONE — серый
	Color(0.35, 0.38, 0.42, 0.45), # IRON — стальной
	Color(0.85, 0.35, 0.25, 0.45), # FOOD — оранжево-красный
]


func _ready() -> void:
	_refresh_visual()
	# В рантайме (НЕ в редакторе): спавним инстансы и прячем визуал зоны.
	if Engine.is_editor_hint():
		return
	# Defer'им спавн до следующего кадра — _ready вызывается во время setup'а
	# родительской сцены, а Godot не даёт add_child пока parent "is busy
	# setting up children". К моменту deferred-вызова дерево полностью
	# собрано, get_global_transform валидно, add_child проходит.
	_spawn_instances.call_deferred()
	var mesh := get_node_or_null("Mesh") as Node3D
	if mesh != null:
		mesh.visible = false


func _refresh_visual() -> void:
	var mesh := get_node_or_null("Mesh") as MeshInstance3D
	if mesh == null:
		return
	mesh.scale = Vector3(maxf(size.x, 0.0), 1.0, maxf(size.y, 0.0))
	# Перекрашиваем материал в цвет типа — индикатор отличается визуально.
	var mat := mesh.material_override as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission_energy_multiplier = 0.3
		mesh.material_override = mat
	var idx := clampi(resource_type, 0, _TYPE_COLORS.size() - 1)
	var c: Color = _TYPE_COLORS[idx]
	mat.albedo_color = c
	mat.emission = Color(c.r, c.g, c.b)
	# В редакторе — видимый. В рантайме — скрыт после _ready.
	mesh.visible = true


## Спавнит count инстансов pile_scene внутри прямоугольника. Использует
## global_transform для поддержки поворота зоны вокруг Y. Соблюдает min_spacing
## где возможно (rejection sampling, до 10 попыток на pile; если не находит —
## всё равно ставит в случайную точку, но это редкость при разумных параметрах).
func _spawn_instances() -> void:
	if pile_scene == null:
		push_warning("ResourceZone (%s): pile_scene не задан — пропускаю спавн" % name)
		return
	var root: Node = null
	if not spawn_root_path.is_empty():
		root = get_node_or_null(spawn_root_path)
	if root == null:
		root = get_tree().current_scene
	var placed_positions: Array[Vector3] = []
	var spacing_sq := min_spacing * min_spacing
	for i in range(count):
		var pos: Vector3 = _pick_position(placed_positions, spacing_sq)
		var pile := pile_scene.instantiate()
		# Назначить тип и units ДО добавления в дерево, чтобы _ready применил
		# правильный визуал сразу. Позицию выставляем после add_child (иначе
		# transform может перезаписаться родителем).
		if pile is ResourcePile:
			(pile as ResourcePile).resource_type = resource_type
			(pile as ResourcePile).units = units_per_pile
		root.add_child(pile)
		(pile as Node3D).global_position = pos
		# Случайная Y-rotation для визуального разнообразия.
		(pile as Node3D).rotation.y = randf() * TAU
		placed_positions.append(pos)


## Случайная точка внутри прямоугольника зоны (с учётом поворота через
## global_transform). Если placed_positions содержит позиции ближе spacing_sq —
## делает до 10 попыток найти свободную; иначе возвращает последнюю.
func _pick_position(placed: Array[Vector3], spacing_sq: float) -> Vector3:
	for attempt in range(10):
		var local := Vector3(
			randf_range(-size.x * 0.5, size.x * 0.5),
			0.0,
			randf_range(-size.y * 0.5, size.y * 0.5),
		)
		var world := global_transform * local
		world.y = global_position.y
		if spacing_sq <= 0.0:
			return world
		var ok := true
		for p in placed:
			if p.distance_squared_to(world) < spacing_sq:
				ok = false
				break
		if ok:
			return world
	# Фоллбэк — берём последний кандидат (ставим внахлёст, но pile появится).
	var local_fb := Vector3(
		randf_range(-size.x * 0.5, size.x * 0.5),
		0.0,
		randf_range(-size.y * 0.5, size.y * 0.5),
	)
	var world_fb := global_transform * local_fb
	world_fb.y = global_position.y
	return world_fb
