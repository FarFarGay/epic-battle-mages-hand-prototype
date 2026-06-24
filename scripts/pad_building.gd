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


func is_gate() -> bool:
	return _role == &"gate"


func is_barracks() -> bool:
	return _role == &"barracks"


## Пересобрать все стены (защита) — зовётся при установке/сносе любой постройки, чтобы
## стены дотянулись до новых соседей (или отвязались от снесённых). Порядок не важен.
static func refresh_walls(tree: SceneTree) -> void:
	for b in tree.get_nodes_in_group(GROUP):
		if not is_instance_valid(b) or b.is_queued_for_deletion():
			continue
		# Стены И ворота зависят от соседей (рукава/нахлёст) → пересобираем оба.
		if (b.has_method(&"is_wall") and b.call(&"is_wall")) or (b.has_method(&"is_gate") and b.call(&"is_gate")):
			b.call(&"_build")


## Проходимые клетки боевого хода (стена/ворота/казарма) — по ним ходят лучники.
static func walkable_set(tree: SceneTree) -> Dictionary:
	var out: Dictionary = {}
	for b in tree.get_nodes_in_group(GROUP):
		if not is_instance_valid(b) or b.is_queued_for_deletion() or not b.has_method(&"occupied_cells"):
			continue
		var ok: bool = (b.has_method(&"is_wall") and b.call(&"is_wall")) \
			or (b.has_method(&"is_gate") and b.call(&"is_gate")) \
			or (b.has_method(&"is_barracks") and b.call(&"is_barracks"))
		if ok:
			for c in b.call(&"occupied_cells"):
				out[c] = true
	return out


## Мировая точка на ВЕРХУ боевого хода для клетки (туда встаёт/идёт лучник).
static func cell_top(cell: Vector2i, tree: SceneTree) -> Vector3:
	var w := OilGrid.cell_to_world(cell, tree)
	return Vector3(w.x, _WALL_H, w.z)


## Маршрут вдоль боевого хода от start в сторону first_dir (жадно: прямо, иначе поворот).
static func wall_route(tree: SceneTree, start: Vector2i, first_dir: Vector2i, maxn: int = 24) -> Array:
	var walk := walkable_set(tree)
	var route: Array = []
	var cur := start
	var prev := start - first_dir
	var visited: Dictionary = {}
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for _k in maxn:
		if not walk.has(cur) or visited.has(cur):
			break
		visited[cur] = true
		route.append(cell_top(cur, tree))
		var nxt := cur
		var found := false
		var sd: Vector2i = cur - prev  # прямое направление
		if walk.has(cur + sd) and not visited.has(cur + sd):
			nxt = cur + sd
			found = true
		else:
			for d in dirs:
				if walk.has(cur + d) and not visited.has(cur + d):
					nxt = cur + d
					found = true
					break
		if not found:
			break
		prev = cur
		cur = nxt
	return route


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
		&"gate":
			_build_gate()
		&"barracks":
			_build_barracks()
		_:
			var mat := _solid(_role_color(_role), 0.1, 0.7)
			var s: float = OilGrid.CELL
			for off in _mask:
				var o := off as Vector2i
				_box(Vector3(s * 0.96, 1.4, s * 0.96), Vector3(o.x * s, 0.7, o.y * s), mat, true)


const _WALL_STONE := Color(0.56, 0.55, 0.52)  # тёплый камень
const _WALL_TRIM := Color(0.4, 0.39, 0.38)
const _WALL_TH := 1.2    # ширина стены = ширине зданий (CELL − 2·_STREET), боевой ход
const _WALL_H := 1.6     # высота стены (верх = дорожка-walkway)
const _MERLON := 0.34    # зубец
const _MERLON_H := 0.5

# Общая палитра/метрики полировки визуала зданий.
const _STONE_DARK := Color(0.33, 0.31, 0.3)   # цоколь/фундамент
const _WOOD := Color(0.46, 0.3, 0.17)         # дерево (крыши/ящики)
const _WOOD_DARK := Color(0.28, 0.18, 0.1)    # тёмное дерево (балки/двери)
const _BASE_H := 0.28                          # высота цоколя-фундамента
## Отступ блочных зданий от края клетки (улица между зданиями = 2·_STREET). Чтобы гномы
## проходили. Клетки ОДНОГО здания сливаются (отступ только по ВНЕШНИМ граням).
const _STREET := 0.4


## Слитный инсет-слой по маске: на каждую клетку коробка, ужатая по ВНЕШНИМ граням на
## margin (где нет соседней клетки маски) → здание стоит с улицей вокруг, но цельным
## массивом внутри. y — центр по Y, h — высота.
func _solid_shape(y: float, h: float, mat: StandardMaterial3D, margin: float) -> void:
	var s: float = OilGrid.CELL
	var half: float = s * 0.5
	var ms: Dictionary = {}
	for off in _mask:
		ms[off as Vector2i] = true
	for off in _mask:
		var o := off as Vector2i
		var xn: float = half if ms.has(o + Vector2i(-1, 0)) else half - margin
		var xp: float = half if ms.has(o + Vector2i(1, 0)) else half - margin
		var zn: float = half if ms.has(o + Vector2i(0, -1)) else half - margin
		var zp: float = half if ms.has(o + Vector2i(0, 1)) else half - margin
		_box(Vector3(xn + xp, h, zn + zp),
			Vector3(float(o.x) * s + (xp - xn) * 0.5, y, float(o.y) * s + (zp - zn) * 0.5), mat, true)


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
		# Ворота — тоже «стеновой» сосед: пилоны доходят до границы, стена встаёт встык.
		if (b.has_method(&"is_wall") and b.call(&"is_wall")) or (b.has_method(&"is_gate") and b.call(&"is_gate")):
			for c in b.call(&"occupied_cells"):
				walls[c] = true
		elif (b.has_method(&"is_attack") and b.call(&"is_attack")) or (b.has_method(&"is_barracks") and b.call(&"is_barracks")):
			for c in b.call(&"occupied_cells"):
				towers[c] = true
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var eo: float = _WALL_TH * 0.5 - _MERLON * 0.5  # вынос зубца к краю дорожки
	var mtop: float = _WALL_H + _MERLON_H * 0.5
	for wc in mine:
		var cell := wc as Vector2i
		var ctr := OilGrid.cell_to_world(cell, tree)
		# Узел-площадка (плоский верх = дорожка боевого хода).
		_wb(ctr + Vector3(0, _WALL_H * 0.5, 0), Vector3(_WALL_TH, _WALL_H, _WALL_TH), stone)
		var arms := 0
		for d in dirs:
			var nb: Vector2i = cell + d
			var to_wall: bool = mineset.has(nb) or walls.has(nb)
			var to_tower: bool = towers.has(nb)
			if not (to_wall or to_tower):
				continue
			arms += 1
			var ln: float = half if to_wall else half + 0.5  # к башне — с нахлёстом
			var ac := ctr + Vector3(d.x * ln * 0.5, _WALL_H * 0.5, d.y * ln * 0.5)
			var size := Vector3(ln, _WALL_H, _WALL_TH) if d.x != 0 else Vector3(_WALL_TH, _WALL_H, ln)
			_wb(ac, size, stone)
			# Зубцы по ОБЕИМ кромкам рукава (перпендикулярно его оси), шаг 1м между клетками.
			var perp := Vector2i(d.y, d.x)
			for side in [-1.0, 1.0]:
				_wb(ctr + Vector3(d.x * 0.5 + float(perp.x) * side * eo, mtop, d.y * 0.5 + float(perp.y) * side * eo),
					Vector3(_MERLON, _MERLON_H, _MERLON), trim)
		# Одиночная стена без соседей — зубцы по 4 углам площадки.
		if arms == 0:
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					_wb(ctr + Vector3(sx * eo, mtop, sz * eo), Vector3(_MERLON, _MERLON_H, _MERLON), trim)


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
	var bw: float = OilGrid.CELL - 2.0 * _STREET  # ширина с отступом (улицы)
	_layer(_BASE_H * 0.5, bw, _BASE_H, dark)                                      # цоколь
	var bh := 2.6
	_box(Vector3(bw - 0.1, bh, bw - 0.1), Vector3(0, _BASE_H + bh * 0.5, 0), stone, true)  # ствол
	_box(Vector3(bw + 0.06, 0.22, bw + 0.06), Vector3(0, _BASE_H + bh, 0), stone, true)    # площадка
	_battlements(bw * 0.5, _BASE_H + bh + 0.11, trim)                            # зубцы


## Ворота: арка со створками в линии стены. Пилоны по локальным ±X доходят до границы
## клетки (стена стыкуется встык), проём по Z — для прохода. Поворот MMB. Локально, узел
## повёрнут трансформом. Проходимость гномов — Фаза 2 (с барьером стен).
func _build_gate() -> void:
	var stone := _solid(_WALL_STONE, 0.05, 0.9)
	var trim := _solid(_WALL_TRIM, 0.1, 0.9)
	var wood := _solid(_WOOD, 0.0, 0.95)
	var s: float = OilGrid.CELL
	var half: float = s * 0.5
	var minx := 999
	var maxx := -999
	for off in _mask:
		minx = mini(minx, (off as Vector2i).x)
		maxx = maxi(maxx, (off as Vector2i).x)
	var x0: float = float(minx) * s - half  # внешний левый край
	var x1: float = float(maxx) * s + half  # внешний правый край
	var cxc: float = float((minx + maxx) / 2) * s  # центр СРЕДНЕЙ клетки = центр арки
	var lp: float = cxc - half  # левая граница средней клетки (левый пилон)
	var rp: float = cxc + half  # правая граница
	var pt := 0.5
	var pd := _WALL_TH  # глубина = ширине стены (боевой ход единой ширины)
	var ph := 2.8
	var eo: float = _WALL_TH * 0.5 - _MERLON * 0.5
	# Концы ворот примыкают к зданиям как стены: к башне/казарме за краем — с нахлёстом.
	var tree := get_tree()
	var base := OilGrid.world_to_cell(global_position, tree)
	var over := _overlap_cells(tree)
	var ext_l := 0.5 if over.has(base + OilGrid.rotate_offset(Vector2i(minx - 1, 0), rotation.y)) else 0.0
	var ext_r := 0.5 if over.has(base + OilGrid.rotate_offset(Vector2i(maxx + 1, 0), rotation.y)) else 0.0
	# Боковые отростки стены (широкие, с двусторонними зубцами) — от краёв к пилонам.
	_gate_wall(x0 - ext_l, lp, _WALL_H, stone, trim)
	_gate_wall(rp, x1 + ext_r, _WALL_H, stone, trim)
	# Пилоны арки по краям СРЕДНЕЙ клетки.
	_box(Vector3(pt, ph, pd), Vector3(lp + pt * 0.5, ph * 0.5, 0), stone, true)
	_box(Vector3(pt, ph, pd), Vector3(rp - pt * 0.5, ph * 0.5, 0), stone, true)
	# Арка-перемычка над проёмом средней клетки + зубцы по обеим кромкам.
	_box(Vector3(s, 0.5, pd), Vector3(cxc, ph + 0.25, 0), stone, true)
	for mx in [-0.6, 0.0, 0.6]:
		for side in [-1.0, 1.0]:
			_box(Vector3(_MERLON, _MERLON_H, _MERLON), Vector3(cxc + mx, ph + 0.5 + _MERLON_H * 0.5, side * eo), trim, true)
	# Створки: проём в 1 клетку (две половинки), закрыты; проход — Фаза 2.
	var open_w: float = s - pt * 2.0
	for sx in [-1.0, 1.0]:
		_box(Vector3(open_w * 0.5 * 0.92, 2.0, 0.14), Vector3(cxc + sx * open_w * 0.25, 1.0, 0), wood, true)


## Мировые клетки построек, к которым стена/ворота примыкают С НАХЛЁСТОМ (башни, казармы).
func _overlap_cells(tree: SceneTree) -> Dictionary:
	var out: Dictionary = {}
	for b in tree.get_nodes_in_group(GROUP):
		if b == self or not is_instance_valid(b) or b.is_queued_for_deletion() or not b.has_method(&"occupied_cells"):
			continue
		if (b.has_method(&"is_attack") and b.call(&"is_attack")) or (b.has_method(&"is_barracks") and b.call(&"is_barracks")):
			for c in b.call(&"occupied_cells"):
				out[c] = true
	return out


## Отрезок боковой стены ворот [xa..xb] вдоль локального X: тонкий каменный блок + зубцы.
func _gate_wall(xa: float, xb: float, h: float, stone: StandardMaterial3D, trim: StandardMaterial3D) -> void:
	var w: float = xb - xa
	if w <= 0.01:
		return
	_box(Vector3(w, h, _WALL_TH), Vector3((xa + xb) * 0.5, h * 0.5, 0), stone, true)
	var eo: float = _WALL_TH * 0.5 - _MERLON * 0.5
	var n := int(round(w))
	for i in n:
		var mx: float = xa + 0.5 + float(i)
		for side in [-1.0, 1.0]:
			_box(Vector3(_MERLON, _MERLON_H, _MERLON), Vector3(mx, h + _MERLON_H * 0.5, side * eo), trim, true)


## Угловая казарма лучников: L-тело (слитное), боевой ход с зубцами по ВНЕШНЕМУ периметру
## и стяг на угловой клетке. Серый камень (фортификация) + синий стяг = лучники.
func _build_barracks() -> void:
	var stone := _solid(_WALL_STONE, 0.05, 0.9)
	var trim := _solid(_WALL_TRIM, 0.1, 0.9)  # зубцы в цвет стеновых — стена = продолжение
	var bc: Color = RoomBuildings.get_data(building_id).get("banner_color", Color(0.28, 0.46, 0.7))
	var banner := _solid(bc, 0.0, 0.8)  # цвет стяга = тип бойцов (лучники/копейщики)
	var s: float = OilGrid.CELL
	var half: float = s * 0.5
	var bh := _WALL_H  # высота как у стены → стена ровно продолжает казарму
	var top: float = bh
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var maskset: Dictionary = {}
	for off in _mask:
		maskset[off as Vector2i] = true
	# БЕЗ цоколя — основа от земли, как у стены (стена идёт продолжением казармы).
	_solid_shape(bh * 0.5, bh, stone, _STREET)
	# Зубцы боевого хода по ВНЕШНИМ граням: по 2 на грань, отступив от углов, + крышка на
	# выпуклом углу (две смежные внешние грани) — чтобы в углах не было свалки.
	var edge: float = half - _STREET - _MERLON * 0.5
	var my: float = top + _MERLON_H * 0.5
	for off in _mask:
		var o := off as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		for d in dirs:
			if maskset.has(o + d):
				continue
			var perp := Vector2i(d.y, d.x)
			for t in [-0.42, 0.42]:
				_box(Vector3(_MERLON, _MERLON_H, _MERLON),
					c + Vector3(float(d.x) * edge + float(perp.x) * t, my, float(d.y) * edge + float(perp.y) * t), trim, true)
		for cx in [-1.0, 1.0]:
			for cz in [-1.0, 1.0]:
				if not maskset.has(o + Vector2i(int(cx), 0)) and not maskset.has(o + Vector2i(0, int(cz))):
					_box(Vector3(_MERLON, _MERLON_H, _MERLON), c + Vector3(cx * edge, my, cz * edge), trim, true)
	# Угловая клетка (≥2 соседа в маске) — древко со стягом.
	var corner := _mask[0] as Vector2i
	for off in _mask:
		var o := off as Vector2i
		var nb := 0
		for d in dirs:
			if maskset.has(o + d):
				nb += 1
		if nb >= 2:
			corner = o
	var pole := _solid(_WOOD_DARK, 0.0, 0.9)
	var cc := Vector3(corner.x * s, 0.0, corner.y * s)
	var flag_base: float = top
	# Лучники: БАШНЯ венчает угол казармы (с неё лучники выходят на стены — Фаза 2).
	if RoomBuildings.get_data(building_id).get("corner_tower", false):
		var tw := 1.0
		var th := 1.9
		_box(Vector3(tw, th, tw), cc + Vector3(0, top + th * 0.5, 0), stone, true)            # ствол
		_box(Vector3(tw + 0.18, 0.2, tw + 0.18), cc + Vector3(0, top + th, 0), stone, true)   # площадка
		_battlements((tw + 0.18) * 0.5, top + th + 0.1, trim)                                 # зубцы
		flag_base = top + th + 0.2
	# Стяг (цвет = тип бойцов): на верхушке башни (лучники) или на основе (прочие).
	var px := Vector3(corner.x * s, flag_base, corner.y * s)
	_box(Vector3(0.09, 1.3, 0.09), px + Vector3(0, 0.65, 0), pole, true)       # древко
	_box(Vector3(0.5, 0.08, 0.08), px + Vector3(0, 1.2, 0), pole, true)        # поперечина
	_box(Vector3(0.45, 0.6, 0.05), px + Vector3(0, 0.85, 0), banner, true)     # полотнище
	# Казарма лучников (с башней) производит 3 лучников: 1 на башню, 2 на рукава-стены.
	if RoomBuildings.get_data(building_id).get("corner_tower", false):
		_spawn_archers(corner)


## Казарма лучников = источник НАСТОЯЩЕГО отряда: заказывает 3 ArcherSoldier у спавнера
## → командуемый отряд с HUD-карточкой, призывом F (берёшь с собой), полным AI/скоростью —
## всё из готовой системы. Меняется только модель (перекрашена в ArcherSoldier).
func _spawn_archers(corner_local: Vector2i) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var base := OilGrid.world_to_cell(global_position, tree)
	var corner_world := base + OilGrid.rotate_offset(corner_local, rotation.y)
	var pos := OilGrid.cell_to_world(corner_world, tree)  # наземная точка у казармы
	var spawner := tree.get_first_node_in_group(&"squad_spawner")
	if spawner != null and spawner.has_method(&"request_squad"):
		spawner.call(&"request_squad", &"archer_squad", 3, pos)


## СЛИТНЫЙ корпус по форме фигуры: на каждую клетку — корпус НА ВСЮ КЛЕТКУ (клетки
## смыкаются в одну массу) + крыша-плита с лёгким свесом (плиты сливаются в одну крышу).
## Так дом/склад выглядят единым зданием по полимино, а не набором модулей.
func _build_compound(body: StandardMaterial3D, roof: StandardMaterial3D, body_h: float, roof_h: float) -> void:
	var dark := _solid(_STONE_DARK, 0.1, 0.92)
	var m := _STREET  # инсет от краёв клетки → улицы между зданиями
	_solid_shape(_BASE_H * 0.5, _BASE_H, dark, m)                         # цоколь
	_solid_shape(_BASE_H + body_h * 0.5, body_h, body, m)                 # тело
	var top: float = _BASE_H + body_h
	_solid_shape(top + 0.04, 0.08, dark, m)                               # карниз-поясок
	_solid_shape(top + 0.08 + roof_h * 0.5, roof_h, roof, m)              # крыша-плита


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
	var face: float = s * 0.5 - _STREET  # внешняя грань (инсет)
	var bw: float = s - 2.0 * _STREET    # ширина здания в клетке
	var f := _mask[0] as Vector2i
	for off in _mask:
		var o := off as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		_box(Vector3(bw * 0.95, 0.12, 0.26), c + Vector3(0, roof_top, 0), dark, true)       # конёк по крыше
		if o != f:
			_box(Vector3(0.5, 0.5, 0.12), c + Vector3(0, _BASE_H + 0.95, face), dark, true)  # окно
	var fc := Vector3(f.x * s, 0.0, f.y * s)
	_box(Vector3(0.42, 0.9, 0.42), fc + Vector3(0.4, roof_top + 0.4, 0.4), dark, true)      # труба
	_box(Vector3(0.75, 1.0, 0.14), fc + Vector3(0, _BASE_H + 0.5, face), dark, true)        # дверь


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
	_box(Vector3(1.0, 1.1, 0.14), fc + Vector3(0, _BASE_H + 0.55, s * 0.5 - _STREET), dark, true)  # ворота склада
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
	var bw: float = OilGrid.CELL - 2.0 * _STREET  # ширина с отступом (улицы)
	_layer(_BASE_H * 0.5, bw + 0.06, _BASE_H, dark)                                   # цоколь
	var bh := 2.0
	_box(Vector3(bw, bh, bw), Vector3(0, _BASE_H + bh * 0.5, 0), body, true)          # короб
	_box(Vector3(bw + 0.12, 0.14, bw + 0.12), Vector3(0, _BASE_H + bh, 0), trim, true)  # карниз
	_battlements(bw * 0.5, _BASE_H + bh + 0.07, trim)                                # зубцы


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
