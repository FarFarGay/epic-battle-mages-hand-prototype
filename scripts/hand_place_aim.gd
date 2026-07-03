class_name HandPlaceAim
extends Node
## Координатор СВОБОДНОГО размещения зданий рукой — ОДНА модель для всех точечных
## построек комнатного режима ([RoomBuildings]). Рука тащит силуэт за курсором;
## ЛКМ-зажим фиксирует точку, драг = поворот, отпускание ставит [RoomBuildSite].
## Без грида/колец/секторов. Sticky: после установки aim остаётся — ставь ещё
## (стены кирпичиками). Esc / повторный вызов того же id — выход.
##
## По образцу [HandSquadAim]: на время aim'а Hand-категория = BUILD_AIM (остальной
## ввод гасится ранним return). НЕ завязан на Camp. UI (gameplay_hud, меню «Стройка»)
## запускает start_aim(building_id).

const ACTION_COMMIT := &"hand_grab"  # ЛКМ — зажать (точка) → отпустить (поставить)
const ACTION_CANCEL := &"ui_cancel"  # Esc — отмена
const ROOM_BUILD_SITE := preload("res://scripts/room_build_site.gd")

## Группа snap-целей стен (площадки + достроенные стены, см. [RoomBuildSite]).
const WALL_SNAP_GROUP := &"wall_snap"

## Шаг поворота силуэта на КЛИК средней кнопки мыши (градусы). 90° = ортогональные
## ориентации — прямые углы лабиринта.
@export var rotate_step_deg: float = 90.0
@export var ghost_color_valid: Color = Color(0.55, 0.85, 1.0, 0.5)
## Цвет силуэта, когда сработал магнит к соседней стене — игрок видит «прилипло».
@export var ghost_color_snap: Color = Color(0.4, 1.0, 0.5, 0.6)
## Цвет силуэта-ОШИБКИ: труба не пристыкована к порту (ставить в воздух нельзя).
@export var ghost_color_invalid: Color = Color(1.0, 0.35, 0.3, 0.55)
## Радиус магнита (м): ближайшая snap-точка силуэта (центр/край) притягивается к
## ближайшей snap-точке соседней стены в пределах этого радиуса. 0 → магнит выкл.
@export var snap_radius: float = 1.6
## Шаг нефте-РЕШЁТКИ (м). Труба-тайл = ровно одна клетка (порты на ±GRID*0.5 от
## центра). Якорь решётки — центр коллектора; буры и трубы притягивают сюда свои
## порты, поэтому петля коллектор↔бур ВСЕГДА замыкается (концы на одной решётке).
@export var oil_grid: float = 2.0
@export var debug_log: bool = true
@export var effects_root_path: NodePath

var _hand: Hand
var _effects_root: Node = null
var _aiming: bool = false
var _building: StringName = &""
var _data: Dictionary = {}
var _footprint: Vector3 = Vector3(2.0, 1.5, 0.3)
var _ghost: Node3D = null
var _ghost_mat: StandardMaterial3D = null
## Сетка строительства на полу (только для нефте-построек) — игрок видит клетки.
var _grid: MeshInstance3D = null
## Заливка занимаемой КЛЕТКИ под силуэтом нефте-постройки — игрок видит «куб» сетки.
var _cell: MeshInstance3D = null
var _cell_mat: StandardMaterial3D = null
## Подсветка площадки застройки (квадрат вокруг качалки) при укладке полимино-фигур.
var _pad_floor: MeshInstance3D = null
## Соседние здания, подсвеченные превью-стыковки (зелёный=соединится/красный=нет). Чистим
## при сдвиге силуэта и выходе из aim. См. _update_connection_hints / PadBuilding.connects.
var _conn_hinted: Array = []
## Текущий поворот силуэта (рад). Крутится кликом средней кнопки мыши, сохраняется
## между установками (sticky) — следующая стена встаёт под тем же углом.
var _rot_y: float = 0.0
## Сработал ли магнит в этом кадре (для подсветки силуэта). Ставится в _snap_center.
var _snapped: bool = false
## Хватает ли монет на составную цену текущей постройки (см. _can_afford). Красит силуэт
## и гейтит установку. Постройки без "cost" (трубы/мост/стройплощадка-на-дереве) — всегда true.
var _affordable: bool = true
## Замок уже есть/строится → ставить второй нельзя (красный силуэт + гейт). См. _pump_blocked.
var _blocked: bool = false


func _ready() -> void:
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene


func setup(hand: Hand) -> void:
	_hand = hand


func is_aiming_any() -> bool:
	return _aiming


## Toggle для UI: тот же id при активном aim'е → отмена; иначе старт (сменив здание).
func toggle_aim(building_id: StringName) -> void:
	if _aiming and _building == building_id:
		cancel_aim()
	else:
		start_aim(building_id)


func start_aim(building_id: StringName) -> void:
	if not is_instance_valid(_hand):
		push_warning("[Hand:PlaceAim] start_aim — _hand не задан")
		return
	var data: Dictionary = RoomBuildings.get_data(building_id)
	if data.is_empty():
		push_warning("[Hand:PlaceAim] неизвестное здание: %s" % building_id)
		return
	if _aiming:
		_clear_ghost()  # переключение здания без полного выхода категории
	_building = building_id
	_data = data
	_footprint = data.get("footprint", _footprint)
	if not _aiming:
		_aiming = true
		_hand.push_category(Hand.Category.BUILD_AIM)
	_spawn_ghost()
	_update_grid()  # сетка пола — только для труб/бура (нефте-решётка)
	_set_build_zones_visible(true)  # показать зоны-индикаторы (напр. кольцо бура)
	_set_producer_slots_visible(true)  # маркеры buff-слотов продюсеров (что занять для макс. баффа)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:PlaceAim] старт размещения: %s" % String(_data.get("name", building_id)))


func cancel_aim() -> void:
	if not _aiming:
		return
	_finish()
	if debug_log and LogConfig.master_enabled:
		print("[Hand:PlaceAim] отмена")


func _process(_delta: float) -> void:
	if not _aiming:
		return
	var ground: Vector3 = _hand.cursor_world_position()
	ground.y -= _hand.hand_height
	if Input.is_action_just_pressed(ACTION_CANCEL):
		cancel_aim()
		return
	# Силуэт следует за курсором. ЛКМ — поставить (sticky, ставим следующую). Поворот —
	# клик средней кнопки (см. _input). Нефте-постройки (трубы И бур) притягивают порты
	# к ЕДИНОЙ решётке (якорь — коллектор) → концы всегда совпадают; прочее — по стенам.
	var is_pad: bool = _data.has("cells")
	var is_pipe: bool = _data.has("pipe_kind")
	var is_oil: bool = is_pipe or _building == RoomBuildings.OIL_DRILL
	var place: Vector3
	if is_pad:
		# Полимино: снап центра в клетку; _snapped = все клетки фигуры в площадке, не на
		# качалке и не внахлёст (гейт + подсветка).
		place = _snap_oil_grid(ground)
		_snapped = _pad_valid(place)
	elif is_oil:
		place = _snap_oil_grid(ground)
		# _snapped = порт примагниченной постройки совпал с портом существующего хоста
		# (коллектор/бур/труба). Для труб это ГЕЙТ (в воздух нельзя), буру — лишь подсветка.
		_snapped = _touches_host(_oil_ports_world(place, _rot_y))
	elif _building == RoomBuildings.PUMP:
		place = _snap_oil_grid(ground)  # замок ставится ПО единому гриду (как всё прочее)
	else:
		place = _snap_center(ground)
	# Хватает ли монет на составную цену (постройки с "cost"; без неё — бесплатно).
	_affordable = _can_afford()
	# Замок — ОДИН на уровень: если уже есть/строится — ставить нельзя (силуэт красный).
	_blocked = _pump_blocked()
	_update_ghost(place)
	# Зелёная зона стройки 9×9: при установке замка — вокруг силуэта (видно будущую зону);
	# при укладке прочего — вокруг существующего замка. Ездит за силуэтом (per-frame).
	_update_pad_floor(place)
	# Превью стыковки: соседние здания зелёным (соединится) / красным (касается, но нет).
	if is_pad:
		_update_connection_hints(place)
	# МАСКА-затухание (окно видимых клеток) едет за силуэтом — плоскость статична, двигаем
	# только центр маски в шейдере. Клетки выровнены к фикс-лоттису (grid_anchor), не плывут.
	if is_instance_valid(_grid):
		var gm := _grid.material_override as ShaderMaterial
		if gm != null:
			gm.set_shader_parameter(&"fade_center", Vector2(place.x, place.z))
	if Input.is_action_just_pressed(ACTION_COMMIT) and not _hand.is_pointer_over_ui():
		# Нельзя невалидно: труба не у порта / фигура за площадкой / внахлёст.
		if (is_pipe or is_pad) and not _snapped:
			if debug_log and LogConfig.master_enabled:
				print("[Hand:PlaceAim] нельзя сюда — стыкуй к порту либо держи фигуру в площадке без наложений")
			return
		# Замок уже есть/строится — второй нельзя.
		if _blocked:
			if debug_log and LogConfig.master_enabled:
				print("[Hand:PlaceAim] замок уже есть — второй нельзя")
			return
		# Не хватает монет → не ставим (силуэт уже красный — см. _update_ghost).
		if not _affordable:
			if debug_log and LogConfig.master_enabled:
				print("[Hand:PlaceAim] не хватает монет на %s" % String(_data.get("name", _building)))
			return
		_commit(place)


## Поворот силуэта кликом СРЕДНЕЙ кнопки мыши (шаг rotate_step_deg). Ловим в _input
## (до _unhandled_input камеры) и ГАСИМ событие — иначе CameraRig включил бы орбиту
## на зажатие колеса (camera_rig.gd MOUSE_BUTTON_MIDDLE). Только пока активен aim.
func _input(event: InputEvent) -> void:
	if not _aiming:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_MIDDLE:
		if mb.pressed:
			_rot_y = wrapf(_rot_y + deg_to_rad(rotate_step_deg), -PI, PI)
		get_viewport().set_input_as_handled()  # и press, и release — камера не орбитит
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		# ПКМ — снести трубу под курсором («построил не так»). Только трубы (instant,
		# бесплатны → сносить тоже бесплатно); бур/коллектор не трогаем. Гасим событие,
		# чтобы камера не реагировала на ПКМ во время стройки.
		if mb.pressed and not _hand.is_pointer_over_ui():
			_delete_pipe_under_cursor()
		get_viewport().set_input_as_handled()


## Замок (PUMP) — ОДИН на уровень: уже построен (группа Castle) ИЛИ строится (стройплощадка
## с building_id=PUMP). Для прочих построек всегда false. Зеркалит гейт меню в gameplay_hud.
func _pump_blocked() -> bool:
	if _building != RoomBuildings.PUMP:
		return false
	var tree := get_tree()
	if tree.get_first_node_in_group(Castle.GROUP) != null:
		return true
	for s in tree.get_nodes_in_group(Layers.BUILD_SITE_GROUP):
		if is_instance_valid(s) and s.get(&"building_id") == RoomBuildings.PUMP:
			return true
	return false


## Хватает ли в казне монет на составную цену текущей постройки. Нет "cost" → бесплатно.
func _can_afford() -> bool:
	var cost: Dictionary = _data.get("cost", {})
	if cost.is_empty():
		return true
	var bank := get_tree().get_first_node_in_group(&"gold_bank")
	if bank == null or not bank.has_method(&"can_afford"):
		return true
	return bank.call(&"can_afford", cost)


## Ставит RoomBuildSite на точке pos с текущим поворотом. Площадку строят рабочие
## командой «Идти сюда» (area-клик по ней → BUILD).
func _commit(pos: Vector3) -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	# Оплата составной цены из казны (только постройки с "cost" — полимино; стройплощадка
	# на дереве "cost" не имеет → бесплатна по монетам, держит свою wood-модель). Атомарно.
	var cost: Dictionary = _data.get("cost", {})
	if not cost.is_empty():
		var bank := get_tree().get_first_node_in_group(&"gold_bank")
		if bank != null and bank.has_method(&"spend_cost"):
			if not bank.call(&"spend_cost", cost):
				return  # не хватило (двойная защита — process уже гейтит _affordable)
	# Полимино-фигура: ЕДИНЫЙ путь стройки через площадку (2026-07-03) — самостройка
	# за build_time, призрак-кубы по маске; free_build достраивает мгновенно.
	# PadBuilding собирает RoomBuildSite._finish (там же линк-пульс и «печать»).
	if _data.has("cells"):
		# Ворота заменяют стену: снести стены под их клетками СРАЗУ (не ждать
		# достройки — иначе призрак ворот стоит внутри стены).
		if _data.get("role", &"") == &"gate":
			_remove_walls_under(CityGrid.building_cells(pos, _data.get("cells", []), _rot_y, get_tree()))
			call_deferred(&"_refresh_walls")  # соседние стены пересоберут рукава у дыры
		var psite := StaticBody3D.new()
		psite.set_script(ROOM_BUILD_SITE)
		psite.building_id = _building
		scene.add_child(psite)
		psite.global_position = pos
		psite.rotation.y = _rot_y
		# Маркеры buff-слотов: у задетых продюсеров перекрасится филл. Сам недострой
		# гранью квартала НЕ считается — закроет её только достроенное здание.
		_set_producer_slots_visible(true)
		if debug_log and LogConfig.master_enabled:
			print("[Hand:PlaceAim] площадка-фигура %s @ клетка %s, yaw %.0f°" % [
				_building, CityGrid.world_to_cell(pos, get_tree()), rad_to_deg(_rot_y)])
		return
	# Мгновенная постройка (трубы): ставим готовую сцену сразу, без стройплощадки и
	# рабочих — длинную трассу не хочется хаулить. Снап/связь у труб — по портам
	# (PORT_HOST_GROUP, добавляется в их _ready), wall_snap им не нужен.
	if _data.get("instant", false):
		var ps := load(String(_data.get("scene", ""))) as PackedScene
		if ps != null:
			var b := ps.instantiate()
			scene.add_child(b)
			if b is Node3D:
				var bn := b as Node3D
				bn.global_position = pos
				bn.rotation.y = _rot_y
		if debug_log and LogConfig.master_enabled:
			print("[Hand:PlaceAim] %s @ (%.1f, %.1f) yaw %.0f° (мгновенно)" % [
				_building, pos.x, pos.z, rad_to_deg(_rot_y)])
		return
	var site := StaticBody3D.new()
	site.set_script(ROOM_BUILD_SITE)
	site.building_id = _building
	scene.add_child(site)
	site.global_position = pos
	site.rotation.y = _rot_y
	if debug_log and LogConfig.master_enabled:
		print("[Hand:PlaceAim] площадка %s @ (%.1f, %.1f), yaw %.0f°" % [
			_building, pos.x, pos.z, rad_to_deg(_rot_y)])


## Якорь нефте-решётки — центр коллектора (порты коллектора у inlet_dist=3.0 ложатся
## на решётку шага 2 → нечётное кратное полуклетки). Нет коллектора → мир-ноль (трубы
## всё равно лягут на общую решётку и сойдутся между собой).
func _oil_anchor() -> Vector3:
	return CityGrid.anchor(get_tree())  # единый фикс-якорь грида (нода-маркер), не замок


## Мировые порты нефте-постройки в точке center при повороте rot: труба — концы тайла
## ([PipeSegment]); бур — единственный выходной патрубок ([OilRig.OUTLET_LOCAL]).
func _oil_ports_world(center: Vector3, rot: float) -> Array:
	var b := Basis(Vector3.UP, rot)
	var out: Array = []
	if _data.has("pipe_kind"):
		for lp in PipeSegment.local_ports(int(_data.get("pipe_kind", 0))):
			out.append(center + b * (lp as Vector3))
	elif _building == RoomBuildings.OIL_DRILL:
		out.append(center + b * OilRig.OUTLET_LOCAL)
	return out


## ЕДИНЫЙ снап нефте-построек: притягиваем ЦЕНТР здания к ЦЕНТРУ КЛЕТКИ (якорь —
## коллектор, шаг oil_grid). Здание занимает клетку(и) ровно. Порты при этом ложатся
## на узлы автоматически: труба — концы на границах клетки; бур/коллектор — патрубок
## кратен клетке (OUTLET/inlet=3.0) → конец на узле. Один путь для труб И бура.
func _snap_oil_grid(raw: Vector3) -> Vector3:
	var a: Vector3 = _oil_anchor()
	var s: float = oil_grid
	return Vector3(
		a.x + roundf((raw.x - a.x) / s) * s,
		raw.y,
		a.z + roundf((raw.z - a.z) / s) * s)


## Совпал ли хоть один порт постройки (ports) с портом существующего хоста — для гейта
## труб (в воздух нельзя) и подсветки силуэта. Допуск — [Castle.PORT_TOL].
func _touches_host(ports: Array) -> bool:
	var tol2: float = Castle.PORT_TOL * Castle.PORT_TOL
	for host in get_tree().get_nodes_in_group(PipeSegment.PORT_HOST_GROUP):
		if not is_instance_valid(host) or not host.has_method(&"pipe_ports"):
			continue
		for hp in host.call(&"pipe_ports"):
			for mp in ports:
				var dx: float = (mp as Vector3).x - (hp as Vector3).x
				var dz: float = (mp as Vector3).z - (hp as Vector3).z
				if dx * dx + dz * dz <= tol2:
					return true
	return false


## Все клетки полимино-фигуры (центр center, поворот _rot_y) лежат в площадке, НЕ на
## ядре-качалке и НЕ заняты другой фигурой — иначе ставить нельзя.
func _pad_valid(center: Vector3) -> bool:
	# Ворота можно ставить ПОВЕРХ стен (заменяют участок) → стены не считаем занятыми.
	var over_walls: bool = _data.get("role", &"") == &"gate"
	# Шахта (role mine) ставится ТОЛЬКО на клетку жилы ([OilDeposit]); прочее — НЕ на жилу
	# (на жиле можно лишь шахту).
	var is_mine: bool = _data.get("role", &"") == &"mine"
	var cells: Array = CityGrid.building_cells(center, _data.get("cells", []), _rot_y, get_tree())
	var occ: Dictionary = _occupied_cells(over_walls)
	var veins: Dictionary = OilDeposit.cell_map(get_tree())
	for c in cells:
		var cell := c as Vector2i
		if not CityGrid.in_pad(cell, get_tree()) or CityGrid.is_pump(cell, get_tree()) or occ.has(cell):
			return false
		var on_vein: bool = veins.has(cell)
		if is_mine and not on_vein:
			return false  # шахту — только на жилу
		if not is_mine and on_vein:
			return false  # на жилу — только шахту
	# ЗОНУ квартала под застройку НЕ требуем свободной (раньше блок `_mine_plot_clear`): пад растёт
	# с апгрейдом замка, а занятая клетка и так не закроется филлером → нет полного бонуса. Запрет
	# был избыточен (самонаказание встроено). Превью зоны остаётся — красные клетки лишь инфо.
	return true


## Множество занятых клеток (все поставленные фигуры). allow_over_walls — НЕ считать стены
## занятыми (для ворот, которые их заменяют). Дёшево — фигур немного.
func _occupied_cells(allow_over_walls: bool) -> Dictionary:
	var out: Dictionary = {}
	for b in get_tree().get_nodes_in_group(PadBuilding.GROUP):
		if not is_instance_valid(b) or not b.has_method(&"occupied_cells"):
			continue
		if allow_over_walls and b.has_method(&"is_wall") and b.call(&"is_wall"):
			continue
		for c in b.call(&"occupied_cells"):
			out[c] = true
	# Строящиеся полимино ТОЖЕ резервируют клетки (RoomBuildSite.occupied_cells) —
	# второй силуэт нельзя наложить на недострой.
	for s in get_tree().get_nodes_in_group(Layers.BUILD_SITE_GROUP):
		if not is_instance_valid(s) or not s.has_method(&"occupied_cells"):
			continue
		for c in s.call(&"occupied_cells"):
			out[c] = true
	return out


## Снести стены, попавшие под клетки cells (ворота заменяют участок стены).
func _remove_walls_under(cells: Array) -> void:
	var cs: Dictionary = {}
	for c in cells:
		cs[c] = true
	for b in get_tree().get_nodes_in_group(PadBuilding.GROUP):
		if not is_instance_valid(b) or not b.has_method(&"is_wall") or not b.call(&"is_wall"):
			continue
		for c in b.call(&"occupied_cells"):
			if cs.has(c):
				_refund_building(b)
				b.queue_free()
				break


## Возврат составной цены постройки в казну при сносе (монеты — единственный ресурс, снос
## не должен быть чистой потерей). Полный рефанд. Постройки без "cost" (трубы) — ноль.
func _refund_building(b: Node) -> void:
	if not (b is PadBuilding):
		return
	var cost: Dictionary = RoomBuildings.get_data((b as PadBuilding).building_id).get("cost", {})
	if cost.is_empty():
		return
	var bank := get_tree().get_first_node_in_group(&"gold_bank")
	if bank == null or not bank.has_method(&"add_coin"):
		return
	for type in cost:
		bank.call(&"add_coin", type, int(cost[type]))


## Магнит: притягивает ближайшую snap-точку силуэта (центр + два края по локальному X)
## к ближайшей snap-точке соседней стены в пределах snap_radius. Чистая трансляция
## (поворот не трогаем). raw — желаемый центр; возвращает примагниченный центр.
func _snap_center(raw: Vector3) -> Vector3:
	_snapped = false
	if snap_radius <= 0.0:
		return raw
	var half: float = _footprint.x * 0.5
	var ax: Vector3 = Basis(Vector3.UP, _rot_y).x
	var mine := [raw, raw + ax * half, raw - ax * half]
	var best_d: float = snap_radius
	var best_delta: Vector3 = Vector3.ZERO
	for n in get_tree().get_nodes_in_group(WALL_SNAP_GROUP):
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		var t: Transform3D = (n as Node3D).global_transform
		var nhalf: float = float(n.get_meta(&"wall_half_len", half))
		var nax: Vector3 = t.basis.x.normalized()
		var c: Vector3 = t.origin
		var theirs := [c, c + nax * nhalf, c - nax * nhalf]
		for mp in mine:
			for tp in theirs:
				var dx: float = mp.x - tp.x
				var dz: float = mp.z - tp.z
				var d: float = sqrt(dx * dx + dz * dz)
				if d < best_d:
					best_d = d
					best_delta = Vector3(tp.x - mp.x, 0.0, tp.z - mp.z)
					_snapped = true
	return raw + best_delta


func _update_ghost(pos: Vector3) -> void:
	if not is_instance_valid(_ghost):
		return
	# Трубы: корень на земле (тюбы строятся на своей высоте PIPE_Y). Бокс: поднимаем
	# на пол-высоты футпринта.
	# Трубы/полимино несут свою высоту в локальной геометрии → y_off=0; бокс поднимаем.
	var y_off: float = 0.0 if (_data.has("pipe_kind") or _data.has("cells")) else _footprint.y * 0.5
	_ghost.global_position = pos + Vector3.UP * y_off
	_ghost.rotation.y = _rot_y  # поворот силуэта — игрок видит ориентацию (угол/крест)
	if _ghost_mat != null:
		var c: Color
		if _blocked:
			c = ghost_color_invalid  # замок уже есть — второй нельзя (красный)
		elif _data.has("cells"):
			# Фигура: красный, если геометрия невалидна ИЛИ не хватает монет.
			c = ghost_color_snap if (_snapped and _affordable) else ghost_color_invalid
		elif _data.has("pipe_kind") and not _snapped:
			c = ghost_color_invalid  # труба не у порта — красный «нельзя»
		elif _snapped:
			c = ghost_color_snap
		else:
			c = Color(_data.get("ghost_color", ghost_color_valid))
		_ghost_mat.albedo_color = c
		_ghost_mat.emission = Color(c.r, c.g, c.b, 1.0)
	# Занимаемая клетка под силуэтом: красная для трубы не у порта, иначе зелёная.
	if is_instance_valid(_cell) and _cell_mat != null:
		_cell.global_position = Vector3(pos.x, 0.07, pos.z)
		var bad: bool = _data.has("pipe_kind") and not _snapped
		_cell_mat.albedo_color = Color(1.0, 0.35, 0.3, 0.3) if bad else Color(0.4, 1.0, 0.5, 0.28)


## Силуэт-призрак. Для труб — РЕАЛЬНАЯ форма (тюбы крест/угол/прямая, видно поворот);
## для прочего — бокс по футпринту. Общий полупрозрачный материал перекрашиваем в
## _update_ghost (валид/снап/ошибка).
func _spawn_ghost() -> void:
	_clear_ghost()
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	_ghost = Node3D.new()
	var color: Color = _data.get("ghost_color", ghost_color_valid)
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.albedo_color = color
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.emission_enabled = true
	_ghost_mat.emission = Color(color.r, color.g, color.b, 1.0)
	_ghost_mat.emission_energy_multiplier = 0.4
	if _data.has("cells"):
		# Полимино: куб-призрак на каждую клетку маски (узел повернём в _update_ghost).
		var s: float = CityGrid.CELL
		for off in _data.get("cells", []):
			var o := off as Vector2i
			var mc := MeshInstance3D.new()
			var bx := BoxMesh.new()
			bx.size = Vector3(s * 0.96, 1.4, s * 0.96)
			mc.mesh = bx
			mc.material_override = _ghost_mat
			mc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mc.position = Vector3(o.x * s, 0.7, o.y * s)
			_ghost.add_child(mc)
	elif _data.has("pipe_kind"):
		PipeSegment.build_ghost(_ghost, int(_data.get("pipe_kind", 0)), _ghost_mat)
	else:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = _footprint
		mi.mesh = box
		mi.material_override = _ghost_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ghost.add_child(mi)
	if _effects_root != null:
		_effects_root.add_child(_ghost)
	# Заливка занимаемой клетки (нефте-постройки) — игрок видит «куб» сетки под силуэтом.
	if _data.has("pipe_kind") or _building == RoomBuildings.OIL_DRILL:
		_cell = MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(oil_grid - 0.12, oil_grid - 0.12)  # тонкий зазор по краям клетки
		_cell.mesh = pm
		_cell_mat = StandardMaterial3D.new()
		_cell_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_cell_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_cell_mat.albedo_color = Color(0.4, 1.0, 0.5, 0.28)
		_cell.material_override = _cell_mat
		_cell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _effects_root != null:
			_effects_root.add_child(_cell)


func _clear_ghost() -> void:
	if is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	if is_instance_valid(_cell):
		_cell.queue_free()
	_cell = null
	_clear_connection_hints()


## Превью стыковки: подсветить соседей силуэта зелёным (роль соединится по PadBuilding.connects)
## или красным (касается, но не соединится — напр. стена↔замок). Соседи — здания на клетках,
## смежных с силуэтом. Замок (ядро is_pump) — отдельный сосед-несоединимый для structural.
func _update_connection_hints(place: Vector3) -> void:
	var tree := get_tree()
	var my_role: StringName = _data.get("role", &"")
	# Силуэт-контур убран — стыковка по СОСЕДСТВУ работает для ВСЕХ, включая филлеры: рука с
	# плавильней/двором/домом у грани шахты подсветит её зелёным (connects, одна категория/SOCIAL).
	var cells: Array = CityGrid.building_cells(place, _data.get("cells", []), _rot_y, tree)
	var cellset: Dictionary = {}
	for c in cells:
		cellset[c] = true
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var nbset: Dictionary = {}
	for c in cells:
		for d in dirs:
			var nb: Vector2i = (c as Vector2i) + d
			if not cellset.has(nb):
				nbset[nb] = true
	var new_hinted: Array = []
	# Пад-постройки на смежных клетках.
	for b in tree.get_nodes_in_group(PadBuilding.GROUP):
		if not is_instance_valid(b) or not b.has_method(&"occupied_cells") or not b.has_method(&"set_connection_hint"):
			continue
		var adj := false
		for oc in b.call(&"occupied_cells"):
			if nbset.has(oc):
				adj = true
				break
		if not adj:
			continue
		var their_role: StringName = b.call(&"get_role") if b.has_method(&"get_role") else &""
		b.call(&"set_connection_hint", 1 if PadBuilding.connects(my_role, their_role) else 2)
		new_hinted.append(b)
	# Замок (ядро is_pump) — сосед без сочетаемости (его клетки не в pad_building).
	var castle_adj := false
	for nb in nbset:
		if CityGrid.is_pump(nb as Vector2i, tree):
			castle_adj = true
			break
	if castle_adj:
		var castle := tree.get_first_node_in_group(&"castle")
		if castle != null and is_instance_valid(castle) and castle.has_method(&"set_connection_hint"):
			castle.call(&"set_connection_hint", 1 if PadBuilding.connects(my_role, &"pump") else 2)
			new_hinted.append(castle)
	# Снять подсветку с тех, кто перестал быть соседом.
	for b in _conn_hinted:
		if is_instance_valid(b) and not new_hinted.has(b) and b.has_method(&"set_connection_hint"):
			b.call(&"set_connection_hint", 0)
	_conn_hinted = new_hinted


func _clear_connection_hints() -> void:
	for b in _conn_hinted:
		if is_instance_valid(b) and b.has_method(&"set_connection_hint"):
			b.call(&"set_connection_hint", 0)
	_conn_hinted = []


## Сетка пола для нефте-построек (труба/бур) и полимино-фигур: полупрозрачные клетки
## шага oil_grid, фаза — центр коллектора (та же решётка, что у снапа). Для полимино
## дополнительно подсвечиваем КВАДРАТ площадки застройки. Для прочих зданий скрыта.
func _update_grid() -> void:
	# Сетка видна при укладке полимино, труб, бура И самого замка (его тоже ставим по гриду).
	var is_grid: bool = _data.has("pipe_kind") or _data.has("cells") \
		or _building == RoomBuildings.OIL_DRILL or _building == RoomBuildings.PUMP
	if not is_grid:
		_clear_grid()
		return
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	var anchor: Vector3 = _oil_anchor()
	if not is_instance_valid(_grid):
		_grid = MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(320.0, 320.0)  # БОЛЬШАЯ статичная плоскость (вся карта); видимость
		_grid.mesh = pm                  # ограничивает МАСКА-затухание (fade_center в _process)
		_grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_grid.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		var mat := ShaderMaterial.new()
		mat.shader = load("res://shaders/build_grid.gdshader")
		mat.set_shader_parameter(&"cell", oil_grid)
		_grid.material_override = mat  # затухание — дефолт шейдера (fade 16→38), центр — в _process
		_effects_root.add_child(_grid)
	# Фаза линий = ФИКС-якорь лоттиса (клетки не плывут). Плоскость статична у якоря; за
	# силуэтом ездит МАСКА-затухание (fade_center, см. _process) — окно видимых клеток.
	var m := _grid.material_override as ShaderMaterial
	if m != null:
		m.set_shader_parameter(&"grid_anchor", Vector2(anchor.x, anchor.z))
	_grid.global_position = Vector3(anchor.x, 0.06, anchor.z)
	# зелёную зону позиционируем per-frame в _process (ездит за силуэтом при установке замка)


## Зелёная зона застройки 13×13 (сторона (2·PAD_RADIUS+1)·клетка). Центр зоны:
##  • ставим САМ ЗАМОК (PUMP) → вокруг СИЛУЭТА (place) — видно будущую зону, ездит за рукой;
##  • прочее (замок уже есть) → вокруг КЛЕТКИ ЗАМКА.
## Нет ни того ни другого → прячем. Зовётся per-frame из _process.
func _update_pad_floor(place: Vector3) -> void:
	var tree := get_tree()
	var is_pump: bool = _building == RoomBuildings.PUMP
	var cc = CityGrid.castle_cell(tree)
	var center_cell: Vector2i
	if is_pump:
		center_cell = CityGrid.world_to_cell(place, tree)  # вокруг силуэта замка
	elif _data.has("cells") and cc != null:
		center_cell = cc  # вокруг существующего замка
	else:
		if is_instance_valid(_pad_floor):
			_pad_floor.queue_free()
		_pad_floor = null
		return
	if not is_instance_valid(_pad_floor):
		_pad_floor = MeshInstance3D.new()
		var pm := PlaneMesh.new()
		var side: float = (2.0 * CityGrid.PAD_RADIUS + 1.0) * CityGrid.CELL
		pm.size = Vector2(side, side)
		_pad_floor.mesh = pm
		_pad_floor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_pad_floor.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.35, 0.9, 0.6, 0.12)  # лёгкая зелёная подложка площадки
		_pad_floor.material_override = mat
		_effects_root.add_child(_pad_floor)
	var center: Vector3 = CityGrid.cell_to_world(center_cell, tree)
	_pad_floor.global_position = Vector3(center.x, 0.05, center.z)


func _clear_grid() -> void:
	if is_instance_valid(_grid):
		_grid.queue_free()
	_grid = null
	if is_instance_valid(_pad_floor):
		_pad_floor.queue_free()
	_pad_floor = null


## Снести ближайшую трубу ИЛИ полимино-фигуру к точке курсора (ПКМ) — поправить
## ошибочную постройку. Радиус — чуть меньше клетки, чтобы целить однозначно. Связность
## нефтесети пересчитает Castle следующим тиком; занятость клеток — по факту групп.
func _delete_pipe_under_cursor() -> void:
	var g: Vector3 = _hand.cursor_world_position()
	g.y -= _hand.hand_height
	var best: Node3D = null
	var best_d: float = (oil_grid * 0.7) * (oil_grid * 0.7)
	for grp in [PipeSegment.GROUP, PadBuilding.GROUP]:
		for n in get_tree().get_nodes_in_group(grp):
			if not is_instance_valid(n) or not (n is Node3D):
				continue
			var node := n as Node3D
			# Полимино: меряем до ближайшей ЗАНЯТОЙ клетки (origin может быть в углу
			# большой фигуры). Труба: до центра узла.
			var d: float = best_d + 1.0
			if node.has_method(&"occupied_cells"):
				for c in node.call(&"occupied_cells"):
					var w: Vector3 = CityGrid.cell_to_world(c as Vector2i, get_tree())
					d = minf(d, (w.x - g.x) * (w.x - g.x) + (w.z - g.z) * (w.z - g.z))
			else:
				d = (node.global_position.x - g.x) * (node.global_position.x - g.x) + (node.global_position.z - g.z) * (node.global_position.z - g.z)
			if d < best_d:
				best_d = d
				best = node
	if best != null:
		AoeVisual.spawn_dust(get_tree().current_scene, best.global_position)
		_refund_building(best)  # снос полимино возвращает монеты (трубы бесплатны → ноль)
		best.queue_free()
		call_deferred(&"_refresh_walls")  # стены отвяжутся от снесённой постройки
		if debug_log and LogConfig.master_enabled:
			print("[Hand:PlaceAim] постройка снесена (ПКМ)")


## Пересобрать все стены — дотянуть до новых соседей / отвязать от снесённых.
func _refresh_walls() -> void:
	PadBuilding.refresh_walls(get_tree())


func _finish() -> void:
	_aiming = false
	_clear_ghost()
	_clear_grid()
	_set_build_zones_visible(false)  # спрятать зоны-индикаторы (вне режима стройки)
	_set_producer_slots_visible(false)  # спрятать маркеры buff-слотов (вышли из стройки)
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.pop_category()


## Показать/спрятать наземные зоны-индикаторы стройки (группа build_zone_indicator).
## Сейчас это кольцо зоны бура ([OilRig]); видно только пока активен режим стройки.
func _set_build_zones_visible(v: bool) -> void:
	for n in get_tree().get_nodes_in_group(&"build_zone_indicator"):
		if n is Node3D:
			(n as Node3D).visible = v


## Показать/спрятать маркеры buff-слотов у ВСЕХ продюсеров (шахты/казармы) — в режиме стройки игрок
## видит, какие грани занять для макс. баффа. Делегирует PadBuilding.set_quarter_slots_visible (гард
## внутри: не продюсер → no-op).
func _set_producer_slots_visible(v: bool) -> void:
	for b in get_tree().get_nodes_in_group(PadBuilding.GROUP):
		if b is PadBuilding and b.has_method(&"set_quarter_slots_visible"):
			(b as PadBuilding).set_quarter_slots_visible(v)
