class_name PadBuilding
extends Node3D
## Полимино-постройка на площадке вокруг качалки (тетрис-фигура из клеток сетки). ОДНА
## модель для всех ролей: защита / атака / добыча — пока различаются только цветом
## (функции = Фаза 2: контур-стена + навмеш, радиус стрельбы, буст соседством). Снап и
## занятость клеток — через [CityGrid]. group pad_building. Ставится мгновенно рукой
## ([HandPlaceAim]); ПКМ сносит.

const GROUP := &"pad_building"
## ЛКМ-захват рукой (то же действие, что у домика гномов) — клик по казарме = найм,
## клик по плавильне = ручная чеканка.
const ACTION_GRAB := &"hand_grab"
## Курс чеканки: столько монет младшего номинала = 1 старшего (100🥉→1🥈, 100🥈→1🥇).
const MINT_RATIO := 100

var building_id: StringName = &""
var _mask: Array = []        # Array[Vector2i] — клетки фигуры (локальные offset'ы)
var _role: StringName = &"defend"
## КОНВЕЙЕР БУФЕРОВ. Каждая стадия — буфер на MINE_CAP единиц; каждая ТЯНЕТ из предыдущей по
## цепочке линий (find_via_lines), пока есть место. Сток — гномий банк (в казну, без лимита).
## Цепочка: жила → ШАХТА(mine) → ПЛАВИЛЬНЯ(smelter) → ЧЕКАННЫЙ ДВОР(mint) → ГНОМИЙ БАНК(bank).
## Так каждая стадия наполняется и видна «движуха», даже если дальше ещё не достроено.
const MINE_RATE := 2.0   # добыча из жилы, ед/сек (шахта)
const FLOW_RATE := 4.0   # перекачка между стадиями, ед/сек (быстрее добычи → не бутылочное горло)
const MINE_CAP := 20     # ёмкость буфера любой стадии
var _vein: OilDeposit = null      # жила под шахтой (источник металла)
var _metal: int = 0               # буфер ШАХТЫ (тип = _vein.coin_type())
var _mine_accum: float = 0.0      # дробный накопитель добычи (единицы целые)
var _metal_fill: MeshInstance3D = null  # индикатор буфера шахты
## Промежуточный буфер стадий (плавильня/двор): сколько накоплено + тир + дробный накопитель.
var _buf: int = 0
var _buf_tier: int = -1
var _flow_accum: float = 0.0
var _buf_fill: MeshInstance3D = null    # индикатор буфера: столб металла (плавильня) / стопка монет (двор)
## Плавильня: дым из шпиля, пока недавно переплавляла (_smelt_cd>0).
const SMOKE_LINGER := 0.7
var _smoke: GPUParticles3D = null
var _smelt_cd: float = 0.0
## Эндпоинты (двор/банк): _work_cd>0 → индикатор светится ярче («работает»).
var _work_glow: MeshInstance3D = null
var _work_cd: float = 0.0
## Гномий банк: накапливает поступившую прибыль и всплывает «+N» с иконкой номинала над
## крышей не чаще POPUP_INTERVAL (иначе по монете в тик = спам). Реюз [SquadXpPopup].
const POPUP_INTERVAL := 0.7   # шаг между всплывашками (меньше времени жизни → видно 3-4 разом)
const POPUP_LIFETIME := 2.8   # сколько живёт «+N» (дольше → столбик из нескольких сразу)
const FIREWORK_EVERY := 100   # каждые N зачисленных монет — небольшой фейерверк над банком
var _recv_amount: int = 0
var _recv_tier: int = -1
var _popup_cd: float = 0.0
var _firework_accum: int = 0  # счётчик монет до следующего фейерверка


## Задаётся ДО add_child (как RoomBuildSite) — _ready строит по маске.
func setup(id: StringName) -> void:
	building_id = id
	var d: Dictionary = RoomBuildings.get_data(id)
	_mask = d.get("cells", [])
	_role = d.get("role", &"defend")


func _ready() -> void:
	add_to_group(GROUP)
	set_process(false)  # тикает только добытчик (нефть) и казарма (клик найма)
	# Казарма = кнопка найма за золото: hover-подсветка руки + ЛКМ-клик → стол торга.
	if is_barracks():
		add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)
		set_process(true)
	# Плавильня — цель доставки руды гномами; тикает ради дыма во время работы.
	if is_smelter():
		add_to_group(&"smelter")
		set_process(true)
	# Чеканный двор — кликабелен для ручной чеканки 100→1 + тикает (свечение).
	if is_mint():
		add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)
		set_process(true)
	# Гномий банк — финальный эндпоинт: тикает ради свечения, пока принимает монеты.
	if is_bank():
		set_process(true)
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


func is_smelter() -> bool:
	return _role == &"smelter"


func is_line() -> bool:
	return _role == &"line"


func is_mint() -> bool:
	return _role == &"mint"


func is_bank() -> bool:
	return _role == &"bank"


## Роль постройки — для обобщённого поиска по цепочке линий (find_via_lines).
func get_role() -> StringName:
	return _role


## Пересобрать все стены (защита) — зовётся при установке/сносе любой постройки, чтобы
## стены дотянулись до новых соседей (или отвязались от снесённых). Порядок не важен.
static func refresh_walls(tree: SceneTree) -> void:
	for b in tree.get_nodes_in_group(GROUP):
		if not is_instance_valid(b) or b.is_queued_for_deletion():
			continue
		# Стены И ворота зависят от соседей (рукава/нахлёст) → пересобираем оба.
		if (b.has_method(&"is_wall") and b.call(&"is_wall")) or (b.has_method(&"is_gate") and b.call(&"is_gate")):
			b.call(&"_build")
	# Структура изменилась (стройка/снос) → гарнизонные лучники пересчитывают пост сразу:
	# падают со снесённой стены/казармы (→ плечо / замок) или лезут на достроенную стену.
	for s in tree.get_nodes_in_group(&"soldier"):
		if is_instance_valid(s) and s.has_method(&"garrison_world_changed"):
			s.call(&"garrison_world_changed")


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
	var w := CityGrid.cell_to_world(cell, tree)
	return Vector3(w.x, _WALL_H, w.z)


## Маршрут вдоль боевого хода СТРОГО ПО ПРЯМОЙ от start в сторону first_dir. Без поворотов
## на углах: лучник плеча ходит только по своей линии (плечо + соосная стена), не заворачивая
## в кольцо стен и не пересекая башню/чужое плечо. Кончилась прямая walkable — стоп.
static func wall_route(tree: SceneTree, start: Vector2i, first_dir: Vector2i, maxn: int = 24) -> Array:
	var walk := walkable_set(tree)
	var route: Array = []
	var cur := start
	for _k in maxn:
		if not walk.has(cur):
			break
		route.append(cell_top(cur, tree))
		cur += first_dir  # только прямо, никаких поворотов
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
		&"smelter":
			_build_smelter()
		&"line":
			_build_line()
		&"mint":
			_build_mint()
		&"bank":
			_build_bank()
		_:
			var mat := _solid(_role_color(_role), 0.1, 0.7)
			var s: float = CityGrid.CELL
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
	var s: float = CityGrid.CELL
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
	var half: float = CityGrid.CELL * 0.5
	var mine := CityGrid.building_cells(global_position, _mask, rotation.y, tree)
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
		var ctr := CityGrid.cell_to_world(cell, tree)
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
	var bw: float = CityGrid.CELL - 2.0 * _STREET  # ширина с отступом (улицы)
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
	var s: float = CityGrid.CELL
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
	var base := CityGrid.world_to_cell(global_position, tree)
	var over := _overlap_cells(tree)
	var ext_l := 0.5 if over.has(base + CityGrid.rotate_offset(Vector2i(minx - 1, 0), rotation.y)) else 0.0
	var ext_r := 0.5 if over.has(base + CityGrid.rotate_offset(Vector2i(maxx + 1, 0), rotation.y)) else 0.0
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
	var s: float = CityGrid.CELL
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
	var corner := _corner_local()
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


## Плавильня: каменная печь с раскалённым устьем (emission) + труба-дымоход. Клетка[0] —
## корпус печи со светящимся зевом; клетка[1] — труба. Гном несёт сюда руду → монеты в
## казну (см. SoldierGnome._tick_smelt_at). Анимация заброса/монет — косметика позже.
func _build_smelter() -> void:
	# ЕДИНОЕ жёлтое здание (под цвет шахты/линии): сплошной массив по всей фигуре + один
	# остроконечный шпиль по центру, раскалённое устье у земли, дым из вершины при работе.
	var yellow := _solid(Color(0.86, 0.66, 0.26), 0.2, 0.6)   # охра — как шахта/линия
	var dark := _solid(Color(0.5, 0.38, 0.16), 0.2, 0.7)      # тёмный карниз/острие
	var glow := _solid(Color(1.0, 0.55, 0.15), 0.0, 0.6)
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.5, 0.12)
	glow.emission_energy_multiplier = 2.0
	var s: float = CityGrid.CELL
	var bw: float = s - 2.0 * _STREET
	# Центр фигуры — над ним шпиль/дым (плита тела сливает все клетки в один массив).
	var ctr := Vector3.ZERO
	for off in _mask:
		ctr += Vector3((off as Vector2i).x * s, 0.0, (off as Vector2i).y * s)
	ctr /= float(_mask.size())
	var bh := 2.6
	_solid_shape(bh * 0.5, bh, yellow, _STREET)                          # единое тело
	_solid_shape(bh + 0.08, 0.16, dark, _STREET)                         # карниз по верху
	var spire_h := 1.5
	_cone(bw * 0.5, spire_h, ctr + Vector3(0, bh + spire_h * 0.5 + 0.16, 0), dark)  # шпиль
	_box(Vector3(bw * 0.45, 0.7, 0.22), ctr + Vector3(0, 0.6, bw * 0.4), glow, true)  # зев
	# Дым из вершины шпиля — включается, пока плавильня недавно переплавляла (_smelt_cd). Реюз
	# эффекта костра POI (smoke_material/smoke_mesh). Стоит выключенным, пока буфер не пошёл.
	_smoke = _build_smoke()
	_smoke.position = ctr + Vector3(0, bh + spire_h + 0.36, 0)
	add_child(_smoke)
	_build_buf_fill()                                                # столб раскалённого металла (буфер)


## Конус (остриё шпиля) — CylinderMesh с нулевым верхом.
func _cone(radius: float, height: float, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = radius
	cm.height = height
	mi.mesh = cm
	mi.material_override = mat
	mi.position = pos
	add_child(mi)


## Дым плавильни — GPUParticles3D на тех же ресурсах, что костёр POI (smoke_material/mesh).
## Возвращается ВЫКЛЮЧЕННЫМ (emitting=false); включается в _process по _smelt_cd (note_smelt).
func _build_smoke() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 12
	p.lifetime = 2.95
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh := load("res://resources/smoke_mesh.tres")
	if mesh != null:
		p.draw_pass_1 = mesh
	var mat = load("res://resources/smoke_material.tres")
	if mat != null:
		p.material_override = mat
	var pm := ParticleProcessMaterial.new()
	pm.particle_flag_rotate_y = true
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.18
	pm.angle_min = -90.0
	pm.angle_max = 90.0
	pm.gravity = Vector3(0.05, 2.0, 0.0)
	pm.scale_min = 0.4
	pm.scale_max = 0.4
	pm.lifetime_randomness = 0.09
	pm.hue_variation_min = 0.0
	pm.hue_variation_max = 0.02
	p.process_material = pm
	p.emitting = false
	return p


## Чеканный двор: единое здание-двор + РАСТУЩАЯ СТОПКА МОНЕТ на крыше (буфер _buf до 20).
func _build_mint() -> void:
	var stone := _solid(Color(0.55, 0.5, 0.42), 0.1, 0.8)     # каменный двор
	var gold := _solid(Color(0.95, 0.78, 0.25), 0.5, 0.35)    # золото карниза
	gold.emission_enabled = true
	gold.emission = Color(1.0, 0.82, 0.3)
	gold.emission_energy_multiplier = 0.6
	var bh := 1.7
	_solid_shape(bh * 0.5, bh, stone, _STREET)               # тело-двор (единый массив)
	_solid_shape(bh + 0.08, 0.16, gold, _STREET)             # золотой карниз
	_build_buf_fill()                                        # стопка монет на крыше


## Центр фигуры в локальных координатах (над ним ставим шпиль/купол/индикатор).
func _mask_center() -> Vector3:
	var s: float = CityGrid.CELL
	var c := Vector3.ZERO
	for off in _mask:
		c += Vector3((off as Vector2i).x * s, 0.0, (off as Vector2i).y * s)
	return c / float(_mask.size())


## Гномий банк: ПОМПЕЗНАЯ крепость — массивный донжон + 4 угловые башенки с золотыми
## остриями + золотой купол по центру (индикатор: светится ярче, пока банк принимает монеты).
func _build_bank() -> void:
	var stone := _solid(Color(0.5, 0.49, 0.5), 0.1, 0.8)      # светлый парадный камень
	var trim := _solid(Color(0.36, 0.35, 0.36), 0.1, 0.85)    # тёмный цоколь/карниз
	var gold := _solid(Color(1.0, 0.82, 0.3), 0.6, 0.3)       # золото купола/остриёв
	gold.emission_enabled = true
	gold.emission = Color(1.0, 0.85, 0.35)
	gold.emission_energy_multiplier = 0.6
	var s: float = CityGrid.CELL
	var bw: float = s - 2.0 * _STREET
	var ctr := _mask_center()
	# Цоколь + массивное тело + карниз — единый парадный массив по всей фигуре.
	_solid_shape(_BASE_H * 0.5, _BASE_H, trim, _STREET * 0.5)
	var bh := 2.4
	_solid_shape(_BASE_H + bh * 0.5, bh, stone, _STREET)
	_solid_shape(_BASE_H + bh + 0.1, 0.2, trim, _STREET * 0.7)
	# Угловые башенки по габаритам фигуры с золотыми остриями (помпезность).
	var minx := 9999.0; var maxx := -9999.0; var minz := 9999.0; var maxz := -9999.0
	for off in _mask:
		var o := off as Vector2i
		minx = minf(minx, o.x * s); maxx = maxf(maxx, o.x * s)
		minz = minf(minz, o.y * s); maxz = maxf(maxz, o.y * s)
	var q: float = s * 0.5 - _STREET
	var th := bh + 0.9
	for cx in [minx - q, maxx + q]:
		for cz in [minz - q, maxz + q]:
			_box(Vector3(0.5, th, 0.5), Vector3(cx, _BASE_H + th * 0.5, cz), stone, true)
			_cone(0.34, 0.7, Vector3(cx, _BASE_H + th + 0.35, cz), gold)
	# Золотой купол по центру — индикатор работы (ярче, пока банк принимает монеты).
	var dome := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = bw * 0.32
	sm.height = bw * 0.5
	dome.mesh = sm
	dome.material_override = gold
	dome.position = ctr + Vector3(0, _BASE_H + bh + 0.2 + bw * 0.16, 0)
	add_child(dome)
	_work_glow = dome


## Линия переработки: плоская «труба»-конвейер по форме фигуры — низкая металлическая плита
## (клетки сливаются) + тёмный жёлоб по центру. Лежит на полу, по ней «течёт» металл.
func _build_line() -> void:
	# Конвейер переработки = просто СПЛОШНАЯ ЖЁЛТАЯ СТЕНА (под цвет шахты). По ней металл
	# течёт к плавильне. Тёмная канавка поверху читается как «поток».
	var yellow := _solid(Color(0.86, 0.66, 0.26), 0.2, 0.6)   # охра — как шахта
	var groove := _solid(Color(0.5, 0.38, 0.16), 0.2, 0.7)    # тёмная канавка-поток
	var trim := _solid(Color(0.7, 0.52, 0.2), 0.2, 0.65)      # зубцы (темнее охры)
	_solid_shape(_WALL_H * 0.5, _WALL_H, yellow, _STREET)     # тело стены
	_solid_shape(_WALL_H + 0.04, 0.1, groove, _STREET + 0.18) # канавка по верху
	# Зубцы по верху — крепостной парапет по краям каждой клетки фигуры.
	var s: float = CityGrid.CELL
	var edge: float = s * 0.5 - _STREET - _MERLON * 0.5
	var mtop: float = _WALL_H + _MERLON_H * 0.5
	for off in _mask:
		var o := off as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				_box(Vector3(_MERLON, _MERLON_H, _MERLON), c + Vector3(sx * edge, mtop, sz * edge), trim, true)


## Угловая клетка фигуры (≥2 соседа в маске → изгиб L) — на ней стяг/башня + узел гарнизона.
func _corner_local() -> Vector2i:
	var maskset: Dictionary = {}
	for off in _mask:
		maskset[off as Vector2i] = true
	var corner := _mask[0] as Vector2i
	for off in _mask:
		var o := off as Vector2i
		var nb := 0
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if maskset.has(o + d):
				nb += 1
		if nb >= 2:
			corner = o
	return corner


## Геометрия постов гарнизона: мировой угол, наземная точка у казармы, верх башни и
## мировые направления рукавов (плечи L). Один источник для спавна и раздачи постов.
func _garrison_posts() -> Dictionary:
	var tree := get_tree()
	var corner_local := _corner_local()
	var maskset: Dictionary = {}
	for off in _mask:
		maskset[off as Vector2i] = true
	var base := CityGrid.world_to_cell(global_position, tree)
	var corner_world := base + CityGrid.rotate_offset(corner_local, rotation.y)
	var ground := CityGrid.cell_to_world(corner_world, tree)  # наземная точка у казармы
	var tower_pos := ground
	tower_pos.y = _WALL_H + 1.9 + 0.22  # верх башни (площадка)
	var arms: Array = []
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if maskset.has(corner_local + d):
			arms.append(CityGrid.rotate_offset(d, rotation.y))
	return {&"corner_world": corner_world, &"ground": ground, &"tower_pos": tower_pos, &"arms": arms}


## Клик по казарме → стол торга под её тип отряда (НАЙМ ЗА ЗОЛОТО). Колбэк адресный:
## на оплату казарма САМА спавнит/доливает отряд (а не broadcast спавнеру), чтобы тут же
## раздать посты гарнизона лучникам. Тип — из каталога (archer_squad / pikeman).
func _open_hire() -> void:
	var tree := get_tree()
	var trade := tree.get_first_node_in_group(&"trade_ui")
	if trade == null or not trade.has_method(&"open"):
		return
	var stype: StringName = RoomBuildings.get_data(building_id).get("squad_type", &"archer_squad")
	trade.call(&"open", stype, Callable(self, &"_on_hired"))


## Оплата прошла: заказываем у спавнера want юнитов типа у казармы. Лучники (corner_tower)
## → раздаём посты гарнизона стен; копейщики → мобильный отряд за башней (спавнер сам escort).
## Спавнер держит ОДИН отряд на тип → повторный найм доливает павших (cap гасит перебор).
func _on_hired(unit_type: StringName, want: int) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var spawner := tree.get_first_node_in_group(&"squad_spawner")
	if spawner == null or not spawner.has_method(&"request_squad"):
		return
	# Добор до капа клампит сам request_squad (единый путь). Стол торга и так гасит
	# «Купить» на full → сюда обычно приходим лишь при недоборе.
	var posts: Dictionary = _garrison_posts()
	var ground: Vector3 = posts[&"ground"]
	var members: Array = spawner.call(&"request_squad", unit_type, want, ground)
	if members.is_empty():
		return
	# Лучники с башней → гарнизон стен. Прочие (копейщики) остаются мобильным отрядом.
	if RoomBuildings.get_data(building_id).get("corner_tower", false):
		# Раздаём посты ВСЕМУ отряду (не только новичкам-добору) — иначе при доливе павших
		# новичок дублирует пост башни, а уцелевшие держат старые. Берём полный members отряда.
		var sq = members[0].get(&"_squad")
		var all: Array = sq.members if sq != null else members
		_assign_garrison(all, posts)


## Раздаём ВСЕМ живым лучникам отряда посты по индексу: 0 → башня (branch ZERO), 1/2 →
## рукава-стены; отряд в МЯГКИЙ hold → гарнизон (ArcherSoldier._grn_should_garrison),
## перебивая escort спавнера. «За башней» (escort) снимает; F-возврат ставит обратно.
func _assign_garrison(members: Array, posts: Dictionary) -> void:
	var corner_world: Vector2i = posts[&"corner_world"]
	var ground: Vector3 = posts[&"ground"]
	var tower_pos: Vector3 = posts[&"tower_pos"]
	var arms: Array = posts[&"arms"]
	# Чистый список живых — индекс поста = позиция в отряде (стабильно при доборе).
	var living: Array = []
	for a in members:
		if is_instance_valid(a) and a.has_method(&"assign_garrison"):
			living.append(a)
	for i in living.size():
		# 0 → башня (branch ZERO); 1/2 → рукава (если есть; иначе тоже башня).
		var branch: Vector2i = Vector2i.ZERO
		if i > 0 and arms.size() > 0:
			branch = arms[(i - 1) % arms.size()]
		living[i].call(&"assign_garrison", corner_world, branch, tower_pos, ground.y)
	# Дефолт казармы — мягкий hold → гарнизон стен (перебивает escort спавнера).
	if living.size() > 0:
		var sq = living[0].get(&"_squad")
		if sq != null:
			sq.command_hold(ground, false)


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
	var s: float = CityGrid.CELL
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
	var s: float = CityGrid.CELL
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
	var bw: float = CityGrid.CELL - 2.0 * _STREET  # ширина с отступом (улицы)
	_layer(_BASE_H * 0.5, bw + 0.06, _BASE_H, dark)                                   # цоколь
	var bh := 2.0
	_box(Vector3(bw, bh, bw), Vector3(0, _BASE_H + bh * 0.5, 0), body, true)          # короб
	_box(Vector3(bw + 0.12, 0.14, bw + 0.12), Vector3(0, _BASE_H + bh, 0), trim, true)  # карниз
	_battlements(bw * 0.5, _BASE_H + bh + 0.07, trim)                                # зубцы


## Добыча: находим замок и ставим темп нефти (×2 при примыкании к ядру-замку).
func _setup_mine() -> void:
	var tree := get_tree()
	# Привязка к жиле под шахтой (гейт размещения уже гарантирует, что шахта на жиле).
	var veins := OilDeposit.cell_map(tree)
	for wc in occupied_cells():
		if veins.has(wc as Vector2i):
			_vein = veins[wc as Vector2i]
			break
	_build_metal_fill()
	set_process(true)


## Шаг добычи: качаем металл из жилы в буфер шахты до MINE_CAP. Дальше по конвейеру буфер
## ТЯНЕТ плавильня (см. _pull). Полный буфер (плавильни нет/она полна) → шахта стоит на капе.
func _tick_mine(delta: float) -> void:
	if _vein == null or not is_instance_valid(_vein):
		return
	if _metal >= MINE_CAP:
		return
	_mine_accum += MINE_RATE * delta
	var whole := int(_mine_accum)
	if whole < 1:
		return
	_mine_accum -= float(whole)
	_metal = mini(_metal + whole, MINE_CAP)
	_update_metal_fill()


## --- Интерфейс конвейера (одна стадия) ---
## Сколько единиц можно ОТДАТЬ вниз по конвейеру (выходной буфер стадии).
func _out_amount() -> int:
	if _role == &"mine":
		return _metal
	if _role == &"smelter" or _role == &"mint":
		return _buf
	return 0


## Тир выдаваемых единиц (для зачисления монет нужного номинала в казну).
func _out_tier() -> int:
	if _role == &"mine":
		return _vein.coin_type() if _vein != null and is_instance_valid(_vein) else -1
	return _buf_tier


## Забрать n единиц из выходного буфера стадии (зовёт нижняя стадия при перекачке).
func _out_remove(n: int) -> void:
	if _role == &"mine":
		_metal = maxi(0, _metal - n)
		_update_metal_fill()
	elif _role == &"smelter" or _role == &"mint":
		_buf = maxi(0, _buf - n)
		_update_buf_fill()


## Свободное место во входном буфере стадии. Банк — бездонный сток (в казну).
func _in_room() -> int:
	if _role == &"smelter" or _role == &"mint":
		return MINE_CAP - _buf
	if _role == &"bank":
		return 1 << 30
	return 0


## Принять n единиц тира tier. Плавильня/двор копят в _buf; банк зачисляет в казну игрока.
func _in_add(n: int, tier: int) -> void:
	if _role == &"smelter" or _role == &"mint":
		if _buf == 0:
			_buf_tier = tier
		_buf = mini(MINE_CAP, _buf + n)
		_update_buf_fill()
	elif _role == &"bank":
		var bank := get_tree().get_first_node_in_group(&"gold_bank")
		if bank != null and bank.has_method(&"add_coin") and tier >= 0:
			bank.call(&"add_coin", tier, n)  # 1 единица = 1 монета тира жилы
			_recv_amount += n                # копим для всплывашки «+N»
			_recv_tier = tier
			_firework_accum += n             # каждые FIREWORK_EVERY монет — фейерверк
			while _firework_accum >= FIREWORK_EVERY:
				_firework_accum -= FIREWORK_EVERY
				_spawn_firework(tier)


## Тянем единицы из верхней стадии (роль upstream_role, по цепочке линий) в свой буфер, пока
## есть место. Симметрично для всех стадий: плавильня←шахта, двор←плавильня, банк←двор.
func _pull(delta: float, upstream_role: StringName) -> void:
	var room := _in_room()
	if room <= 0:
		return
	var up := find_via_lines(upstream_role)
	if up == null or not up.has_method(&"_out_amount"):
		return
	var avail: int = up.call(&"_out_amount")
	if avail <= 0:
		return
	_flow_accum += FLOW_RATE * delta
	var n: int = mini(mini(int(_flow_accum), room), avail)
	if n < 1:
		return
	_flow_accum -= float(n)
	var tier: int = up.call(&"_out_tier")
	up.call(&"_out_remove", n)
	_in_add(n, tier)
	# Индикатор работы: плавильня дымит, двор/банк светятся.
	if is_smelter():
		_smelt_cd = SMOKE_LINGER
	else:
		_work_cd = SMOKE_LINGER


## Ближайшая постройка роли `role`, до которой ЭТО здание дотягивается цепочкой смежных
## клеток-линий (или стоит прямо рядом). BFS по клеткам линий от своих клеток. null = не
## подключена. Дёшево (построек немного). Общий движок для шахта→плавильня и плавильня→двор.
func find_via_lines(role: StringName) -> Node:
	var tree := get_tree()
	var line_cells: Dictionary = {}
	var target_cells: Dictionary = {}  # клетка → постройка роли role
	for b in tree.get_nodes_in_group(GROUP):
		if b == self or not is_instance_valid(b) or b.is_queued_for_deletion() or not b.has_method(&"occupied_cells"):
			continue
		if b.has_method(&"is_line") and b.call(&"is_line"):
			for c in b.call(&"occupied_cells"):
				line_cells[c] = true
		elif b.has_method(&"get_role") and b.call(&"get_role") == role:
			for c in b.call(&"occupied_cells"):
				target_cells[c] = b
	if target_cells.is_empty():
		return null
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var visited: Dictionary = {}
	var queue: Array = []
	# Старт — от собственных клеток: прямо у цели ИЛИ на смежную линию.
	for sc in occupied_cells():
		for d in dirs:
			var nb: Vector2i = (sc as Vector2i) + d
			if target_cells.has(nb):
				return target_cells[nb]
			if line_cells.has(nb) and not visited.has(nb):
				visited[nb] = true
				queue.append(nb)
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		for d in dirs:
			var nb: Vector2i = c + d
			if target_cells.has(nb):
				return target_cells[nb]
			if line_cells.has(nb) and not visited.has(nb):
				visited[nb] = true
				queue.append(nb)
	return null


func _process(delta: float) -> void:
	if _role == &"mine":
		_tick_mine(delta)
	if is_barracks():
		_tick_hire_click()
	if is_smelter():
		_pull(delta, &"mine")    # тянет металл из шахты по линии в свой буфер
		# Дым, пока плавильня недавно переплавляла (_smelt_cd, ставится в _pull).
		if _smelt_cd > 0.0:
			_smelt_cd -= delta
		if _smoke != null and is_instance_valid(_smoke):
			_smoke.emitting = _smelt_cd > 0.0
	if is_mint():
		_pull(delta, &"smelter")  # тянет металл из плавильни → стопка монет растёт
		_tick_mint_click()        # ЛКМ по двору → ручная перечеканка 100→1
	if is_bank():
		_pull(delta, &"mint")     # тянет монеты из двора → в казну игрока
		# Всплывашка «+прибыль» с иконкой номинала над крышей (агрегируем, не чаще интервала).
		if _popup_cd > 0.0:
			_popup_cd -= delta
		if _recv_amount > 0 and _popup_cd <= 0.0:
			_spawn_profit_popup(_recv_tier, _recv_amount)
			_recv_amount = 0
			_popup_cd = POPUP_INTERVAL
	# Эндпоинт (двор/банк): индикатор светится ярче, пока недавно работал (_work_cd).
	if is_mint() or is_bank():
		if _work_cd > 0.0:
			_work_cd -= delta
		if _work_glow != null and is_instance_valid(_work_glow):
			var gm := _work_glow.material_override as StandardMaterial3D
			if gm != null:
				gm.emission_energy_multiplier = 2.4 if _work_cd > 0.0 else 0.6


## Индикатор заполнения буфера: столбик металла на верхушке шахты, растёт с _metal. Цвет —
## по тиру жилы (видно, что и сколько накопано).
func _build_metal_fill() -> void:
	_metal_fill = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.5, 1.0, 0.5)
	_metal_fill.mesh = bm
	var mat := StandardMaterial3D.new()
	var col := Color(0.74, 0.46, 0.22)  # бронза по умолчанию
	if _vein != null and is_instance_valid(_vein):
		match _vein.coin_type():
			ResourcePile.ResourceType.SILVER:
				col = Color(0.82, 0.84, 0.9)
			ResourcePile.ResourceType.GOLD:
				col = Color(0.95, 0.78, 0.28)
	mat.albedo_color = col
	mat.metallic = 0.7
	mat.roughness = 0.35
	_metal_fill.material_override = mat
	add_child(_metal_fill)
	_update_metal_fill()


## Высота столбика = доля заполнения буфера; пусто → скрыт.
func _update_metal_fill() -> void:
	if _metal_fill == null or not is_instance_valid(_metal_fill):
		return
	var frac: float = clampf(float(_metal) / float(MINE_CAP), 0.0, 1.0)
	_metal_fill.visible = _metal > 0
	var h: float = lerpf(0.05, 1.4, frac)
	_metal_fill.scale = Vector3(1.0, h, 1.0)
	# Верхушка шахты ~2.3 (см. _build_tower: цоколь+короб). Столбик стоит сверху, растёт вверх.
	_metal_fill.position = Vector3(0.0, 2.4 + h * 0.5, 0.0)


## Индикатор буфера стадии (_buf): плавильня — раскалённый столб металла у зева; чеканный
## двор — растущая стопка золотых монет на крыше. Высота = доля заполнения (_buf/MINE_CAP).
func _build_buf_fill() -> void:
	var bw: float = CityGrid.CELL - 2.0 * _STREET
	_buf_fill = MeshInstance3D.new()
	if is_smelter():
		var bm := BoxMesh.new()
		bm.size = Vector3(0.5, 1.0, 0.5)
		_buf_fill.mesh = bm
		var mat := _solid(Color(1.0, 0.5, 0.15), 0.2, 0.4)  # раскалённый металл
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.45, 0.1)
		mat.emission_energy_multiplier = 1.6
		_buf_fill.material_override = mat
	else:  # чеканный двор — золотая стопка монет
		var cm := CylinderMesh.new()
		cm.top_radius = bw * 0.3
		cm.bottom_radius = bw * 0.3
		cm.height = 1.0
		_buf_fill.mesh = cm
		var mat := _solid(Color(0.95, 0.78, 0.25), 0.6, 0.3)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.82, 0.3)
		mat.emission_energy_multiplier = 0.6
		_buf_fill.material_override = mat
		_work_glow = _buf_fill  # та же стопка пульсирует, пока двор чеканит
	add_child(_buf_fill)
	_update_buf_fill()


## Высота индикатора буфера = доля заполнения; пусто → скрыт. Сидит на верхушке стадии.
func _update_buf_fill() -> void:
	if _buf_fill == null or not is_instance_valid(_buf_fill):
		return
	var frac: float = clampf(float(_buf) / float(MINE_CAP), 0.0, 1.0)
	_buf_fill.visible = _buf > 0
	var c := _mask_center()
	var bw: float = CityGrid.CELL - 2.0 * _STREET
	if is_smelter():
		var h: float = lerpf(0.1, 1.6, frac)
		_buf_fill.scale = Vector3(1.0, h, 1.0)
		# У зева печи (перед телом), растёт вверх от земли.
		_buf_fill.position = Vector3(c.x, 0.1 + h * 0.5, c.z + bw * 0.4)
	else:  # двор — стопка на крыше (тело bh=1.7 + карниз)
		var h: float = lerpf(0.06, 1.3, frac)
		_buf_fill.scale = Vector3(1.0, h, 1.0)
		_buf_fill.position = Vector3(c.x, 1.78 + h * 0.5, c.z)


## Цвет номинала монеты (бронза/серебро/золото) — единый для индикаторов и всплывашек.
func _coin_color(coin_type: int) -> Color:
	match coin_type:
		ResourcePile.ResourceType.SILVER:
			return Color(0.85, 0.87, 0.92)
		ResourcePile.ResourceType.GOLD:
			return Color(0.98, 0.80, 0.25)
		_:
			return Color(0.80, 0.50, 0.22)  # бронза


## Всплывашка прибыли над банком: «+N» (реюз [SquadXpPopup], поднимается+тает) + плоская
## монета-иконка цвета номинала рядом с числом. Показывает, что и сколько зачислено в казну.
func _spawn_profit_popup(coin_type: int, amount: int) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null or not is_instance_valid(scene):
		return
	var col := _coin_color(coin_type)
	var popup := SquadXpPopup.new()
	popup.text = "+%d" % amount
	popup.lifetime = POPUP_LIFETIME  # дольше живёт → одновременно видно несколько в столбик
	popup.drift = 0.5                # вихляет вбок как дымок, а не строго вверх
	scene.add_child(popup)
	popup.global_position = to_global(_mask_center()) + Vector3(0, 2.2, 0)
	popup.modulate = col  # цвет числа = номинал (fade в _process двигает только альфу)
	# Плоская монетка-иконка цвета номинала слева от числа (едет вместе со всплывашкой).
	var icon := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.18
	cm.bottom_radius = 0.18
	cm.height = 0.05
	icon.mesh = cm
	var mat := _solid(col, 0.6, 0.3)
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 0.9
	icon.material_override = mat
	icon.position = Vector3(-0.5, 0.0, 0.0)
	popup.add_child(icon)


## Небольшой фейерверк над банком: одноразовый GPUParticles3D-залп — мелкие РАЗНОЦВЕТНЫЕ
## искры (радуга по hue) с ТРЕЙЛАМИ разлетаются шаром и опадают. Зовётся каждые
## FIREWORK_EVERY монет; сам себя освобождает по таймеру. Параметр coin_type не используем
## (фейерверк нарочно радужный — праздник, не номинал).
func _spawn_firework(_coin_type: int) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null or not is_instance_valid(scene):
		return
	var life := 1.3
	var fw := GPUParticles3D.new()
	fw.amount = 28
	fw.lifetime = life
	fw.one_shot = true
	fw.explosiveness = 1.0           # все искры разом → хлопок
	fw.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fw.trail_enabled = true          # нативные трейлы за искрами
	fw.trail_lifetime = 0.35
	# Мелкая искра (≈вдвое меньше прежних осколков 0.25), цвет — из частицы, без освещения.
	var bm := BoxMesh.new()
	bm.size = Vector3(0.12, 0.12, 0.12)
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.vertex_color_use_as_albedo = true
	dmat.emission_enabled = true
	dmat.emission = Color(1, 1, 1)
	dmat.emission_energy_multiplier = 1.2
	bm.material = dmat
	fw.draw_pass_1 = bm
	# Шаровой разлёт + гравитация (арка вниз); радуга через широкую вариацию оттенка.
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0                # во все стороны
	pm.initial_velocity_min = 4.0
	pm.initial_velocity_max = 8.0
	pm.gravity = Vector3(0, -7.0, 0)
	pm.scale_min = 0.7
	pm.scale_max = 1.2
	pm.color = Color(1.0, 0.25, 0.25)  # насыщенная база → hue-вариация даёт полный спектр
	pm.hue_variation_min = -1.0
	pm.hue_variation_max = 1.0
	# Затухание альфы к концу жизни.
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var gtex := GradientTexture1D.new()
	gtex.gradient = grad
	pm.color_ramp = gtex
	fw.process_material = pm
	scene.add_child(fw)
	fw.global_position = to_global(_mask_center()) + Vector3(0, 3.2, 0)  # над крышей/куполом
	fw.restart()
	# Самоочистка после залпа+трейлов (WeakRef — без «Lambda capture freed» на смене сцены).
	var ref: WeakRef = weakref(fw)
	tree.create_timer(life + 0.6).timeout.connect(func() -> void:
		var n: Node = ref.get_ref()
		if n != null and n.is_inside_tree():
			n.queue_free())


## Валидный ЛКМ-клик по футпринту ЭТОГО здания. Единый гейт для найма/чеканки:
## модалка закрыта, нажат hand_grab, рука НЕ в aim-режиме (команда/стройка/супер), НЕ над
## HUD и ничего не держит, и курсорная клетка в occupied_cells. Иначе клик-команды aim'ов
## и клики по HUD рядом со зданием паразитно дёргали бы стол. Точность по клеткам.
func _clicked_on_self() -> bool:
	var tree := get_tree()
	var trade := tree.get_first_node_in_group(&"trade_ui")
	if trade != null and trade.has_method(&"is_open") and trade.call(&"is_open"):
		return false
	if not Input.is_action_just_pressed(ACTION_GRAB):
		return false
	var hand := tree.get_first_node_in_group(Hand.HAND_GROUP) as Hand
	if hand == null:
		return false
	if hand.is_in_aim_mode() or hand.is_pointer_over_ui() or hand.is_holding():
		return false
	var cell := CityGrid.world_to_cell(hand.cursor_world_position(), tree)
	return cell in occupied_cells()


## ЛКМ по футпринту казармы → открыть стол найма.
func _tick_hire_click() -> void:
	if _clicked_on_self():
		_open_hire()


## ЛКМ по футпринту чеканного двора → РУЧНАЯ ЧЕКАНКА на ступень вверх (100→1).
func _tick_mint_click() -> void:
	if _clicked_on_self():
		_mint_one_step()


## Одна перечеканка 100→1: приоритет серебро→золото (если набралось 100🥈), иначе
## бронза→серебро. Атомарно через казну. Выбор-попап (что чеканить) — можно позже.
func _mint_one_step() -> void:
	var bank := get_tree().get_first_node_in_group(&"gold_bank")
	if bank == null or not bank.has_method(&"spend_cost"):
		return
	var RT := ResourcePile.ResourceType
	if int(bank.call(&"get_coin", RT.SILVER)) >= MINT_RATIO:
		if bank.call(&"spend_cost", {RT.SILVER: MINT_RATIO}):
			bank.call(&"add_coin", RT.GOLD, 1)
	elif int(bank.call(&"get_coin", RT.BRONZE)) >= MINT_RATIO:
		if bank.call(&"spend_cost", {RT.BRONZE: MINT_RATIO}):
			bank.call(&"add_coin", RT.SILVER, 1)


## Контракт hover-подсветки (Hand._update_pickup_highlight): наводим руку → казарма
## светится emission'ом. Тоггл по всем мешам фигуры (материалы per-instance из _build).
func set_highlighted(value: bool) -> void:
	for ch in get_children():
		var mi := ch as MeshInstance3D
		if mi == null:
			continue
		var mat := mi.material_override as StandardMaterial3D
		if mat == null:
			continue
		mat.emission_enabled = value
		mat.emission = Color(0.55, 0.7, 1.0)
		mat.emission_energy_multiplier = 0.5 if value else 0.0


## Мировые клетки, занятые постройкой (для проверки наложения при размещении).
func occupied_cells() -> Array:
	return CityGrid.building_cells(global_position, _mask, rotation.y, get_tree())


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
	var s: float = CityGrid.CELL
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
