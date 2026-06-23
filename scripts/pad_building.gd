class_name PadBuilding
extends Node3D
## Полимино-постройка на площадке вокруг качалки (тетрис-фигура из клеток сетки). ОДНА
## модель для всех ролей: защита / атака / добыча — пока различаются только цветом
## (функции = Фаза 2: контур-стена + навмеш, радиус стрельбы, буст соседством). Снап и
## занятость клеток — через [OilGrid]. group pad_building. Ставится мгновенно рукой
## ([HandPlaceAim]); ПКМ сносит.

const GROUP := &"pad_building"

var building_id: StringName = &""
var _mask: Array = []        # Array[Vector2i] — клетки фигуры (локальные offset'ы)
var _role: StringName = &"defend"


## Задаётся ДО add_child (как RoomBuildSite) — _ready строит по маске.
func setup(id: StringName) -> void:
	building_id = id
	var d: Dictionary = RoomBuildings.get_data(id)
	_mask = d.get("cells", [])
	_role = d.get("role", &"defend")


func _ready() -> void:
	add_to_group(GROUP)
	# Отложенно: HandPlaceAim ставит global-трансформ ПОСЛЕ add_child (нужен стене для
	# мировых клеток и поиска соседей).
	call_deferred(&"_build")


func is_wall() -> bool:
	return _role == &"defend"


func is_attack() -> bool:
	return _role == &"attack"


## Пересобрать все стены (защита) — зовётся при установке/сносе любой постройки, чтобы
## стены дотянулись до новых соседей (или отвязались от снесённых). Порядок не важен.
static func refresh_walls(tree: SceneTree) -> void:
	for b in tree.get_nodes_in_group(GROUP):
		if is_instance_valid(b) and not b.is_queued_for_deletion() and b.has_method(&"is_wall") and b.call(&"is_wall"):
			b.call(&"_build")


## Визуал по роли: добытчик — квадратная башенка-замок; защита — серая каменная стена
## с зубцами; атака — серая сторожевая башня. Коллайдера нет (Фаза 2).
func _build() -> void:
	for ch in get_children():
		ch.free()  # перестройка: чистим прежний визуал
	match _role:
		&"mine":
			_build_tower()
		&"defend":
			_build_wall()
		&"attack":
			_build_watchtower()
		&"housing":
			_build_house()
		&"storage":
			_build_store()
		_:
			var mat := _solid(_role_color(_role), 0.1, 0.7)
			var s: float = OilGrid.CELL
			for off in _mask:
				var o := off as Vector2i
				_box(Vector3(s * 0.96, 1.4, s * 0.96), Vector3(o.x * s, 0.7, o.y * s), mat, true)


const _WALL_STONE := Color(0.52, 0.52, 0.55)
const _WALL_TRIM := Color(0.42, 0.42, 0.46)
const _WALL_TH := 0.5    # толщина тонкой стены
const _WALL_H := 1.6     # высота стены


## Крепостная стена (защита): ТОНКИЙ ряд по центру клетки. Каждая клетка = столб-узел +
## рукава к соседним клеткам маски (как трубы) → прямая и угол выходят тонкими и
## стыкуются. Зубцы шагом 1м (центр клетки + «свои» границы к соседям) — единый узор.
func _build_wall() -> void:
	var tree := get_tree()
	var stone := _solid(_WALL_STONE, 0.05, 0.95)
	var trim := _solid(_WALL_TRIM, 0.05, 0.95)
	var half: float = OilGrid.CELL * 0.5
	# Мои мировые клетки + клетки соседей. Рукав тянем к ЛЮБОЙ занятой соседней клетке:
	# своя маска / другая стена → стык на границе; здание/ядро-замок → с нахлёстом внутрь.
	var mine := OilGrid.building_cells(global_position, _mask, rotation.y, tree)
	var mineset: Dictionary = {}
	for c in mine:
		mineset[c] = true
	# Соединяемся со стенами (стык встык) и со сторожевыми башнями (нахлёст — башня = угол
	# стены). К добытчику и замку НЕ тянемся (примыкаем лишь краем).
	var walls: Dictionary = {}
	var towers: Dictionary = {}
	for b in tree.get_nodes_in_group(GROUP):
		if b == self or not is_instance_valid(b) or b.is_queued_for_deletion() or not b.has_method(&"occupied_cells"):
			continue
		if b.has_method(&"is_wall") and b.call(&"is_wall"):
			for c in b.call(&"occupied_cells"):
				walls[c] = true
		elif b.has_method(&"is_attack") and b.call(&"is_attack"):
			for c in b.call(&"occupied_cells"):
				towers[c] = true
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for wc in mine:
		var cell := wc as Vector2i
		var ctr := OilGrid.cell_to_world(cell, tree)
		_wb(ctr + Vector3(0, _WALL_H * 0.5, 0), Vector3(_WALL_TH, _WALL_H, _WALL_TH), stone)  # узел
		_wb(ctr + Vector3(0, _WALL_H + 0.25, 0), Vector3(0.45, 0.5, 0.45), trim)              # зубец-центр
		for d in dirs:
			var nb: Vector2i = cell + d
			var to_wall: bool = mineset.has(nb) or walls.has(nb)
			var to_tower: bool = towers.has(nb)
			if not (to_wall or to_tower):
				continue
			# К стене — рукав до границы (встык); к башне — с нахлёстом (стена входит в башню).
			var ln: float = half if to_wall else half + 0.5
			var ac := ctr + Vector3(d.x * ln * 0.5, _WALL_H * 0.5, d.y * ln * 0.5)
			var size := Vector3(ln, _WALL_H, _WALL_TH) if d.x != 0 else Vector3(_WALL_TH, _WALL_H, ln)
			_wb(ac, size, stone)
			if d == Vector2i(1, 0) or d == Vector2i(0, 1):  # «свой» зубец-граница → шаг 1м
				_wb(ctr + Vector3(d.x * half, _WALL_H + 0.25, d.y * half), Vector3(0.45, 0.5, 0.45), trim)


## Куб В МИРОВЫХ координатах (top_level — не зависит от трансформа узла-стены). Стена
## строится по мировым клеткам, поэтому фиксируем меши абсолютно.
func _wb(world_pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.top_level = true
	add_child(mi)
	mi.global_position = world_pos


## Сторожевая башня (атака, 1 клетка): узкая СЕРАЯ каменная башня + площадка-парапет с
## зубцами наверху (туда «сядет» лучник в Фазе 2). Цвет как у стены.
func _build_watchtower() -> void:
	var stone := _solid(_WALL_STONE, 0.05, 0.9)
	var trim := _solid(_WALL_TRIM, 0.1, 0.9)
	_box(Vector3(1.3, 2.8, 1.3), Vector3(0, 1.4, 0), stone, true)    # ствол башни
	_box(Vector3(1.7, 0.25, 1.7), Vector3(0, 2.8, 0), stone, true)   # площадка наверху
	_battlements(0.82, 2.9, trim)                                    # зубцы вокруг площадки


## Дом гномов (население): на каждую клетку — каменный домик с КОРИЧНЕВОЙ скатной
## крышей-пирамидой и дверью (деревянные акценты = гражданское, не серая фортификация).
func _build_house() -> void:
	var stone := _solid(Color(0.55, 0.55, 0.58), 0.05, 0.9)
	var roof := _solid(Color(0.45, 0.28, 0.16), 0.0, 0.95)
	var dark := _solid(Color(0.2, 0.15, 0.1), 0.0, 0.9)
	var s: float = OilGrid.CELL
	for off in _mask:
		var o := off as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		_box(Vector3(1.5, 1.2, 1.5), c + Vector3(0, 0.6, 0), stone, true)     # стены
		_pyramid(0.95, 0.9, c + Vector3(0, 1.65, 0), roof)                    # крыша
		_box(Vector3(0.5, 0.7, 0.12), c + Vector3(0, 0.35, 0.75), dark, true) # дверь (+Z)


## Склад (хранилище): на каждую клетку — каменный короб с дощатой крышкой и ящиками
## сверху (деревянные акценты).
func _build_store() -> void:
	var stone := _solid(Color(0.5, 0.5, 0.54), 0.05, 0.9)
	var wood := _solid(Color(0.5, 0.34, 0.18), 0.0, 0.95)
	var s: float = OilGrid.CELL
	for off in _mask:
		var o := off as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		_box(Vector3(1.7, 1.4, 1.7), c + Vector3(0, 0.7, 0), stone, true)     # короб склада
		_box(Vector3(1.8, 0.2, 1.8), c + Vector3(0, 1.5, 0), wood, true)      # дощатая крышка
		_box(Vector3(0.6, 0.6, 0.6), c + Vector3(-0.4, 1.9, -0.3), wood, true)  # ящик
		_box(Vector3(0.5, 0.5, 0.5), c + Vector3(0.45, 1.85, 0.35), wood, true) # ящик


## Квадратная пирамида (скатная крыша): CylinderMesh 4 сегмента, повёрнут на 45° (грани
## вдоль осей). half — полуширина квадрата основания.
func _pyramid(half: float, height: float, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = 0.0
	c.bottom_radius = half * 1.4142
	c.height = height
	c.radial_segments = 4
	mi.mesh = c
	mi.material_override = mat
	mi.position = pos
	mi.rotation.y = PI / 4.0
	add_child(mi)


## Квадратная башенка-замок (добытчик): каменный короб в цвет роли + зубцы по верху —
## стилистически как угловые башни качалки. Без коллайдера (Фаза 2).
func _build_tower() -> void:
	var body := _solid(_role_color(_role), 0.15, 0.8)
	var trim := _solid(Color(0.32, 0.3, 0.34), 0.2, 0.85)
	_box(Vector3(1.7, 2.2, 1.7), Vector3(0, 1.1, 0), body, true)  # короб башни
	_battlements(0.85, 2.2, trim)                                  # зубцы по верху


## Мировые клетки, занятые постройкой (для проверки наложения при размещении).
func occupied_cells() -> Array:
	return OilGrid.building_cells(global_position, _mask, rotation.y, get_tree())


func _solid(c: Color, metallic: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metallic
	m.roughness = rough
	return m


func _box(size: Vector3, pos: Vector3, mat: StandardMaterial3D, shadow: bool) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Зубцы (мерлоны) по периметру верха башни — как у угловых башен качалки.
func _battlements(half: float, top_y: float, mat: StandardMaterial3D) -> void:
	var n := 3
	var mw := 0.34
	var mh := 0.45
	var step := (half * 2.0) / float(n)
	for i in n:
		var o: float = -half + step * (float(i) + 0.5)
		var y: float = top_y + mh * 0.5
		_box(Vector3(mw, mh, mw), Vector3(o, y, half), mat, true)
		_box(Vector3(mw, mh, mw), Vector3(o, y, -half), mat, true)
		_box(Vector3(mw, mh, mw), Vector3(half, y, o), mat, true)
		_box(Vector3(mw, mh, mw), Vector3(-half, y, o), mat, true)


func _role_color(r: StringName) -> Color:
	match r:
		&"attack":
			return Color(0.82, 0.4, 0.34)   # атака — красноватый
		&"mine":
			return Color(0.88, 0.68, 0.26)  # добыча — охра
	return Color(0.5, 0.58, 0.72)           # защита — серо-синий
