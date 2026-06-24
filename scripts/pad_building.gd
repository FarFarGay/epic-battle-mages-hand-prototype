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
## Добыча: нефть/сек в замок (база). ×2, если добытчик примыкает к ядру-замку (модель
## «добыча бустит замок соседством»). Высокий для теста — крутить балансом позже.
const MINE_OIL_PER_SEC := 4.0
var _oil_rate: float = 0.0
var _collector: Node = null


## Задаётся ДО add_child (как RoomBuildSite) — _ready строит по маске.
func setup(id: StringName) -> void:
	building_id = id
	var d: Dictionary = RoomBuildings.get_data(id)
	_mask = d.get("cells", [])
	_role = d.get("role", &"defend")


func _ready() -> void:
	add_to_group(GROUP)
	set_process(false)  # тикает только добытчик (нефть в замок), см. _setup_mine
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
			_setup_mine()
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


const _WALL_STONE := Color(0.56, 0.55, 0.52)  # тёплый камень
const _WALL_TRIM := Color(0.4, 0.39, 0.38)
const _WALL_TH := 0.5    # толщина тонкой стены
const _WALL_H := 1.6     # высота стены

# Общая палитра/метрики полировки визуала зданий.
const _STONE_DARK := Color(0.33, 0.31, 0.3)   # цоколь/фундамент
const _WOOD := Color(0.46, 0.3, 0.17)         # дерево (крыши/ящики)
const _WOOD_DARK := Color(0.28, 0.18, 0.1)    # тёмное дерево (балки/двери)
const _BASE_H := 0.28                          # высота цоколя-фундамента


## Крепостная стена (защита): ТОНКИЙ ряд по центру клетки. Каждая клетка = столб-узел +
## рукава к соседним клеткам маски (как трубы) → прямая и угол выходят тонкими и
## стыкуются. Зубцы шагом 1м (центр клетки + «свои» границы к соседям) — единый узор.
func _build_wall() -> void:
	var tree := get_tree()
	var stone := _solid(_WALL_STONE, 0.05, 0.95)
	var trim := _solid(_WALL_TRIM, 0.05, 0.95)
	var half: float = OilGrid.CELL * 0.5
	var mine := OilGrid.building_cells(global_position, _mask, rotation.y, tree)
	var mineset: Dictionary = {}
	for c in mine:
		mineset[c] = true
	# Соединяемся со стенами (встык) и со сторожевыми башнями (нахлёст). К добыче/дому/
	# складу/замку НЕ тянемся (примыкаем лишь краем).
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
			var ln: float = half if to_wall else half + 0.5  # к башне — с нахлёстом
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
	var dark := _solid(_STONE_DARK, 0.1, 0.9)
	var trim := _solid(_WALL_TRIM, 0.1, 0.9)
	_layer(_BASE_H * 0.5, OilGrid.CELL * 0.72, _BASE_H, dark)          # цоколь
	var bh := 2.6
	_box(Vector3(1.3, bh, 1.3), Vector3(0, _BASE_H + bh * 0.5, 0), stone, true)   # ствол
	_box(Vector3(1.72, 0.22, 1.72), Vector3(0, _BASE_H + bh, 0), stone, true)     # площадка
	_battlements(0.82, _BASE_H + bh + 0.11, trim)                                 # зубцы


## СЛИТНЫЙ корпус по форме фигуры: на каждую клетку — корпус НА ВСЮ КЛЕТКУ (клетки
## смыкаются в одну массу) + крыша-плита с лёгким свесом (плиты сливаются в одну крышу).
## Так дом/склад выглядят единым зданием по полимино, а не набором модулей.
func _build_compound(body: StandardMaterial3D, roof: StandardMaterial3D, body_h: float, roof_h: float) -> void:
	var s: float = OilGrid.CELL
	var dark := _solid(_STONE_DARK, 0.1, 0.92)
	_layer(_BASE_H * 0.5, s + 0.18, _BASE_H, dark)                         # цоколь-фундамент
	for off in _mask:
		var o := off as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		_box(Vector3(s, body_h, s), c + Vector3(0, _BASE_H + body_h * 0.5, 0), body, true)
	var top: float = _BASE_H + body_h
	_layer(top + 0.04, s + 0.04, 0.08, dark)                              # карниз-поясок
	_layer(top + 0.08 + roof_h * 0.5, s + 0.18, roof_h, roof)             # крыша-плита (свес)


## Дом гномов (население): слитный каменный корпус + коричневая крыша; труба и дверь —
## единичный декор на крайней клетке (не на каждую).
func _build_house() -> void:
	var stone := _solid(Color(0.6, 0.58, 0.55), 0.05, 0.9)
	var roof := _solid(_WOOD, 0.0, 0.95)
	var dark := _solid(_WOOD_DARK, 0.0, 0.9)
	var body_h := 1.5
	_build_compound(stone, roof, body_h, 0.4)
	var s: float = OilGrid.CELL
	var top: float = _BASE_H + body_h
	var roof_top: float = top + 0.08 + 0.4
	var f := _mask[0] as Vector2i
	for off in _mask:
		var o := off as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		_box(Vector3(s * 0.92, 0.12, 0.26), c + Vector3(0, roof_top, 0), dark, true)        # конёк по крыше
		if o != f:
			_box(Vector3(0.5, 0.5, 0.14), c + Vector3(0, _BASE_H + 0.95, s * 0.5), dark, true)  # окно (+Z)
	var fc := Vector3(f.x * s, 0.0, f.y * s)
	_box(Vector3(0.42, 0.9, 0.42), fc + Vector3(0.45, roof_top + 0.4, 0.45), dark, true)    # труба
	_box(Vector3(0.75, 1.0, 0.16), fc + Vector3(0, _BASE_H + 0.5, s * 0.5), dark, true)     # дверь


## Склад (хранилище): слитный каменный корпус + дощатая крыша + ящики поверх.
func _build_store() -> void:
	var stone := _solid(Color(0.55, 0.54, 0.52), 0.05, 0.9)
	var wood := _solid(_WOOD, 0.0, 0.95)
	var dark := _solid(_WOOD_DARK, 0.0, 0.9)
	var body_h := 1.4
	_build_compound(stone, wood, body_h, 0.3)
	var s: float = OilGrid.CELL
	var top: float = _BASE_H + body_h + 0.08 + 0.3  # верх крыши
	var f := _mask[0] as Vector2i
	var fc := Vector3(f.x * s, 0.0, f.y * s)
	_box(Vector3(1.0, 1.1, 0.16), fc + Vector3(0, _BASE_H + 0.55, s * 0.5), dark, true)  # ворота склада
	for i in _mask.size():
		var o := _mask[i] as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		# По ящику на клетку, со смещением — читается как разбросанный груз, не модули.
		var off := Vector3(0.35 if i % 2 == 0 else -0.35, 0.3, -0.3 if i % 2 == 0 else 0.35)
		_box(Vector3(0.6, 0.6, 0.6), c + off + Vector3(0, top, 0), wood, true)


## Квадратная башенка-замок (добытчик): каменный короб в цвет роли + зубцы по верху —
## стилистически как угловые башни качалки. Без коллайдера (Фаза 2).
func _build_tower() -> void:
	var body := _solid(_role_color(_role), 0.12, 0.82)
	var dark := _solid(_STONE_DARK, 0.1, 0.9)
	var trim := _solid(Color(0.4, 0.38, 0.4), 0.2, 0.85)
	_layer(_BASE_H * 0.5, OilGrid.CELL + 0.16, _BASE_H, dark)             # цоколь
	var bh := 2.0
	_box(Vector3(1.7, bh, 1.7), Vector3(0, _BASE_H + bh * 0.5, 0), body, true)        # короб
	_box(Vector3(1.86, 0.14, 1.86), Vector3(0, _BASE_H + bh, 0), trim, true)          # карниз
	_battlements(0.85, _BASE_H + bh + 0.07, trim)                                     # зубцы


## Добыча: находим замок и ставим темп нефти (×2 при примыкании к ядру-замку).
func _setup_mine() -> void:
	var tree := get_tree()
	_collector = tree.get_first_node_in_group(OilCollector.GROUP)
	var adj := false
	for wc in OilGrid.building_cells(global_position, _mask, rotation.y, tree):
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if OilGrid.is_pump((wc as Vector2i) + d):
				adj = true
	_oil_rate = MINE_OIL_PER_SEC * (2.0 if adj else 1.0)
	set_process(true)


func _process(delta: float) -> void:
	if _oil_rate > 0.0 and is_instance_valid(_collector) and _collector.has_method(&"add_oil"):
		_collector.call(&"add_oil", _oil_rate * delta)


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


## Горизонтальный СЛОЙ по всем клеткам фигуры (цоколь / карниз): на каждую клетку плита
## стороной side, высотой h, центром по Y = y. Плиты смыкаются в единый поясок здания.
func _layer(y: float, side: float, h: float, mat: StandardMaterial3D) -> void:
	var s: float = OilGrid.CELL
	for off in _mask:
		var o := off as Vector2i
		_box(Vector3(side, h, side), Vector3(o.x * s, y, o.y * s), mat, true)


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
