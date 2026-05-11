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
@export_range(1, 1000) var count: int = 8

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
	var mesh := get_node_or_null("Mesh") as Node3D
	if mesh != null:
		mesh.visible = false
	# Откладываем спавн до следующего process-кадра, чтобы _ready всех
	# сиблингов уже отработал — в т.ч. WaveDirector._ready, который добавляет
	# себя в группу `wave_director`. С call_deferred (idle-фрейм) формально
	# тоже после _ready, но _spawn_one_pile внутри использует add_child, и
	# safer вариант — явно дождаться process_frame.
	_deferred_spawn()


func _deferred_spawn() -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		# Зона удалена за этот кадр — спавнить кучи бессмысленно.
		return
	_spawn_instances()


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
##
## **POI-фильтр:** точки внутри круга палаток вокруг костра (radius =
## `QuestActor.safe_radius`) отбрасываются — кучи там перекрывались бы с
## палатками. Camp safe-зона и WaveDirector `wave_safe_radius` НЕ фильтруют:
## дизайнер сам решает на каком расстоянии от лагеря разместить ресурсы,
## кроме самой плотной зоны костра.
func _spawn_instances() -> void:
	if pile_scene == null:
		push_warning("ResourceZone (%s): pile_scene не задан — пропускаю спавн" % name)
		return
	var root: Node = null
	if not spawn_root_path.is_empty():
		root = get_node_or_null(spawn_root_path)
	if root == null:
		root = get_tree().current_scene
	# Снимок POI на момент спавна. Каждый QuestActor добавляется в группу
	# POI_GROUP в своём _ready (см. quest_actor.gd). К моменту нашего
	# deferred-спавна все POI на сцене уже зарегистрированы. Хранимая
	# структура — (position, radius²) на каждый POI: один проход на старте,
	# на каждый pick — N кучных распознаваний без get_tree() и без allocate.
	var poi_circles: Array = []
	for poi in get_tree().get_nodes_in_group(QuestActor.POI_GROUP):
		if not is_instance_valid(poi):
			continue
		var r: float = 12.0
		if "safe_radius" in poi:
			r = poi.safe_radius
		poi_circles.append({
			"pos": (poi as Node3D).global_position,
			"r_sq": r * r,
		})
	var placed_positions: Array[Vector3] = []
	var spacing_sq := min_spacing * min_spacing
	for i in range(count):
		var pos: Vector3 = _pick_position(placed_positions, spacing_sq, poi_circles)
		var pile := pile_scene.instantiate()
		# Жёсткий контракт: pile_scene должна давать ResourcePile. Если дизайнер
		# подменил сцену на другую (Item, ноду без скрипта и т.п.), мы НЕ хотим
		# молча добавить её — она не получит resource_type/units, в инспекторе
		# будет «зелёный generic с дефолтными units=5» и причина не очевидна.
		if not pile is ResourcePile:
			var got: String = pile.get_class() if pile != null else "null"
			push_error("ResourceZone (%s): pile_scene не extends ResourcePile (получили %s) — пропускаю спавн" % [name, got])
			# instantiate теоретически может вернуть Object без Node-предка
			# (нестандартные сцены/скрипты) — queue_free есть только у Node.
			# Без guard'а получили бы «Invalid call. Nonexistent function
			# 'queue_free'» вместо чистого пропуска.
			if pile is Node:
				(pile as Node).queue_free()
			continue
		# Назначить тип и units ДО добавления в дерево, чтобы _ready применил
		# правильный визуал сразу. Позицию выставляем после add_child (иначе
		# transform может перезаписаться родителем).
		(pile as ResourcePile).resource_type = resource_type
		(pile as ResourcePile).units = units_per_pile
		root.add_child(pile)
		(pile as Node3D).global_position = pos
		# Случайная Y-rotation для визуального разнообразия.
		(pile as Node3D).rotation.y = randf() * TAU
		placed_positions.append(pos)


## Случайная точка внутри прямоугольника зоны (с учётом поворота через
## global_transform). До 10 попыток соблюсти min_spacing И не попасть в
## круг палаток POI. Если за 10 попыток не нашлось — возвращает последнюю
## случайную точку (визуальный нахлёст лучше пропуска кучи). На пустом
## poi_circles POI-чек скипается.
func _pick_position(placed: Array[Vector3], spacing_sq: float, poi_circles: Array) -> Vector3:
	var last_world := Vector3.ZERO
	for attempt in range(10):
		var local := Vector3(
			randf_range(-size.x * 0.5, size.x * 0.5),
			0.0,
			randf_range(-size.y * 0.5, size.y * 0.5),
		)
		var world := global_transform * local
		# +1м над зоной: pile стартует выше земли и нормально на неё падает.
		# При world.y = global_position.y (=0) центр pile'а оказывается ровно
		# на поверхности → его geometry ниже surface на половину высоты shape
		# (0.7м для wood-cylinder, 0.35м для food-sphere) → physics выталкивает
		# в случайную сторону, иногда вниз сквозь terrain. С +1м гарантированно
		# приземляется сверху.
		world.y = global_position.y + 1.0
		last_world = world
		# POI-фильтр: точка в круге костра/палаток — пропускаем. Чек по XZ
		# (Y игнорируем), сравнение квадратов дистанций — без sqrt.
		var in_poi_circle := false
		for circle in poi_circles:
			var dx: float = world.x - (circle["pos"] as Vector3).x
			var dz: float = world.z - (circle["pos"] as Vector3).z
			if dx * dx + dz * dz < (circle["r_sq"] as float):
				in_poi_circle = true
				break
		if in_poi_circle:
			continue
		if spacing_sq <= 0.0:
			return world
		var ok := true
		for p in placed:
			if p.distance_squared_to(world) < spacing_sq:
				ok = false
				break
		if ok:
			return world
	return last_world
