class_name BuildGrid
extends Node3D
## Полярный грид строительства вокруг ядра-харвестера. Концентрические кольца,
## каждое поделено на угловые сегменты-ячейки. Число сегментов растёт наружу
## удвоением (4 → 8 → 16) — внешние ячейки не разрастаются, 1 внутренняя ячейка
## ровно над 2 внешними (чистая радиальная стыковка).
##
## Установка: игрок хватает блок рукой и отпускает над гридом — блок защёлкивается
## в ближайшую ПУСТУЮ и СВЯЗНУЮ ячейку и принимает её форму (BuildBlock сектор-меш
## конформится под кольцо/сегмент). Связность (корень — харвестер в центре):
## ячейку можно занять, если она в кольце 0 (примыкает к ядру) ИЛИ у неё занят
## сосед. Соседи: ±1 сегмент в своём кольце, внутрь (r-1, s/2), наружу (r+1, 2s/2s+1).
## Висящие в воздухе блоки поставить нельзя.
##
## Пока: 1 блок = 1 ячейка (через кольца не тянется, 1D-футпринт). Здания разного
## размера/формы (мульти-сегмент, 2D) — следующий шаг. Снятие блока освобождает
## ячейку; каскадную ре-проверку связности оставшихся пока не делаем.
##
## Геометрия ячеек локальна относительно ядра; на deploy грид встаёт global_position
## = центр лагеря (= харвестер), на pack — гасит пады и роняет стоявшие блоки.

# Дефолты формы ячейки — из общего GridGeometry (его же читает офлайн-бейк
# генератора, чтобы тело-модель не разъехалась с реальной ячейкой). preload-
# const, а не global class — не зависим от регистрации class_name.
const GridGeo = preload("res://scripts/grid_geometry.gd")

## Сегментов на кольцо, изнутри наружу. Кольцо 0 — генераторное (4 больших
## ячейки). Остальные кольца — единый мелкий грид (много ячеек ≈ длины мелкого
## блока), на них здания занимают N ячеек по размеру. Связь по углу (соседи
## считаются перекрытием углов — кратность колец не обязана быть удвоением).
@export var segment_counts: PackedInt32Array = PackedInt32Array([GridGeo.SEGMENTS_RING0, 12, 16])
## Радиус дворика-ядра (внутренний радиус кольца 0, дыра под харвестер).
@export var core_radius: float = GridGeo.CORE_RADIUS
## Радиальная толщина одного кольца (глубина здания).
@export var ring_band: float = GridGeo.RING_BAND
## Радиальный проход-«улица» между кольцами (м) — юниты ходят между рядами.
@export var ring_gap: float = GridGeo.RING_GAP
## Угловой проход между ячейками, МЕТРИЧЕСКИЙ (м, на внутреннем радиусе кольца).
@export var cell_gap_m: float = GridGeo.CELL_GAP_M
## Макс. расстояние от блока до центра ячейки, при котором релиз = установка.
@export var snap_distance: float = 2.6
## Время стройки здания (секунды): форма поднимается по гриду, на финише — пуфф.
@export var build_time: float = 2.0
## Высота пад-маркеров ячеек над землёй.
@export var pad_y: float = 0.06
## Цвет ячейки, валидной для установки (зелёная заливка при удержании блока).
@export var valid_color: Color = Color(0.4, 1.0, 0.5, 0.5)
## Цвет линий сетки (границы колец + радиальные разделители).
@export var line_color: Color = Color(0.6, 0.85, 1.0, 0.85)
## Толщина линий сетки (метры, рисуются плоскими лентами по земле).
@export var line_width: float = 0.12
@export var debug_log: bool = true

## Эмитится при изменении набора установленных зданий (поставили/сняли). Camp
## слушает, чтобы пересчитать генераторы и гейтить харвестер.
signal buildings_changed

var _rings: Array = []      # _rings[r] = Array ячеек кольца r
var _cells: Array = []      # плоский список всех ячеек
var _line_grid: MeshInstance3D = null   # чёткие линии сетки (статичны)
var _active: bool = false
var _placing: CampModule = null   # блок, который сейчас держит рука (подсветка)
## Сколько ячеек кольца занимает СТЕНА в руке (1..cnt). Колесо мыши при зажатой
## ЛКМ тянет стену по дуге — за одно нажатие можно замкнуть весь круг. Только для
## wall_thin; обычные здания держат свой footprint.
var _wall_span: int = 1
var _pulse_t: float = 0.0         # фаза пульса строящихся ячеек

## Скорость пульса строящихся ячеек (рад/с).
const PULSE_SPEED := 4.5
var _camp = null            # ссылка на Camp (экономика для оплаты построек; нетипизировано — динамический .economy)


## Camp привязывает себя — грид берёт economy для списания стоимости зданий.
func bind_camp(camp) -> void:
	_camp = camp


func _ready() -> void:
	_build_cells()
	_build_line_grid()
	EventBus.hand_grabbed.connect(_on_hand_grabbed)
	EventBus.hand_released.connect(_on_hand_released)


# --- Геометрия колец (единая формула с «улицами» между зданиями) ---

## Внутренний радиус кольца r. Радиальная «улица» ring_gap между кольцами:
## кольцо r начинается на core_radius + r·(ring_band + ring_gap).
func _ring_inner(r: int) -> float:
	return core_radius + float(r) * (ring_band + ring_gap)


## Угловой размер ячейки (град) для footprint fp в кольце на cnt сегментов.
## cell_gap_m — МЕТРИЧЕСКИЙ зазор-«улица»; переводим в угол по ВНУТРЕННЕМУ радиусу
## кольца (там проход у́же всего), чтобы минимальная ширина улицы = cell_gap_m.
## gapless=true (СТЕНЫ) — полный угол сегмента, без зазора: соседние стены
## смыкаются край-в-край в сплошной барьер (иначе враг пройдёт в щель).
func _seg_deg(inner: float, cnt: int, footprint: int = 1, gapless: bool = false) -> float:
	if gapless:
		return float(footprint) * 360.0 / float(cnt)
	var gap_deg: float = rad_to_deg(cell_gap_m / maxf(inner, 0.01))
	return float(footprint) * 360.0 / float(cnt) - gap_deg


# --- Построение ячеек + пад-маркеров ---

func _build_cells() -> void:
	for r in range(segment_counts.size()):
		var cnt: int = maxi(segment_counts[r], 1)
		var inner: float = _ring_inner(r)
		var outer: float = inner + ring_band
		var seg_deg: float = _seg_deg(inner, cnt, 1)
		var mid: float = (inner + outer) * 0.5
		var ring_cells: Array = []
		for s in range(cnt):
			var ang: float = (float(s) + 0.5) * TAU / float(cnt)
			var pad := _make_pad(inner, outer, ang, deg_to_rad(seg_deg) * 0.5)
			add_child(pad)
			pad.visible = false
			var cell := {
				"r": r, "s": s,
				"inner": inner, "outer": outer, "seg_deg": seg_deg,
				"center": Vector3(cos(ang) * mid, 0.0, sin(ang) * mid),
				"block": null,
				"pad": pad,
				"mat": pad.material_override,
			}
			ring_cells.append(cell)
			_cells.append(cell)
		_rings.append(ring_cells)
	if debug_log and LogConfig.master_enabled:
		print("[BuildGrid] построен: %d колец, %d ячеек" % [_rings.size(), _cells.size()])


func _make_pad(inner: float, outer: float, ang: float, ang_half: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _build_pad_mesh(inner, outer, ang, ang_half)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = valid_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(valid_color.r, valid_color.g, valid_color.b)
	mat.emission_energy_multiplier = 0.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	return mi


## Плоский сектор-пад в локале грида (центр грида = ядро), на высоте pad_y.
func _build_pad_mesh(inner: float, outer: float, ac: float, ah: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := Vector3(0.0, pad_y, 0.0)
	var segs := 5
	for i in range(segs):
		var t0 := ac - ah + (float(i) / float(segs)) * (2.0 * ah)
		var t1 := ac - ah + (float(i + 1) / float(segs)) * (2.0 * ah)
		var d0 := Vector3(cos(t0), 0.0, sin(t0))
		var d1 := Vector3(cos(t1), 0.0, sin(t1))
		st.add_vertex(d0 * inner + y)
		st.add_vertex(d0 * outer + y)
		st.add_vertex(d1 * outer + y)
		st.add_vertex(d0 * inner + y)
		st.add_vertex(d1 * outer + y)
		st.add_vertex(d1 * inner + y)
	st.generate_normals()
	return st.commit()


## Чёткая сетка линиями: КОНТУР каждой ячейки (две дуги + два радиальных торца)
## на её инсет-размерах. Между ячейками — пустые «улицы» (ring_gap/cell_gap_m),
## сетка совпадает с зелёными пад-маркерами и читается как отдельные участки,
## а не сплошная «мишень». Плоские ленты по земле.
func _build_line_grid() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := pad_y + 0.01
	var hw := line_width * 0.5
	for cell in _cells:
		var inner: float = cell["inner"]
		var outer: float = cell["outer"]
		var c: Vector3 = cell["center"]
		var ang: float = atan2(c.z, c.x)
		var ah: float = deg_to_rad(float(cell["seg_deg"])) * 0.5
		_add_arc(st, inner, ang - ah, ang + ah, hw, y)        # внутренняя дуга
		_add_arc(st, outer, ang - ah, ang + ah, hw, y)        # внешняя дуга
		_add_spoke(st, ang - ah, inner, outer, hw, y)         # торец A
		_add_spoke(st, ang + ah, inner, outer, hw, y)         # торец B
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = line_color
	mat.emission_enabled = true
	mat.emission = Color(line_color.r, line_color.g, line_color.b)
	mat.emission_energy_multiplier = 0.9
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.visible = false
	add_child(mi)
	_line_grid = mi


## Дуговая лента на радиусе radius от угла a0 до a1, ширины 2*hw (контур ячейки).
func _add_arc(st: SurfaceTool, radius: float, a0: float, a1: float, hw: float, y: float) -> void:
	var yo := Vector3(0.0, y, 0.0)
	var ri: float = maxf(radius - hw, 0.0)
	var ro: float = radius + hw
	var segs: int = maxi(2, int(ceil((a1 - a0) / deg_to_rad(6.0))))
	for i in range(segs):
		var t0 := lerpf(a0, a1, float(i) / float(segs))
		var t1 := lerpf(a0, a1, float(i + 1) / float(segs))
		var d0 := Vector3(cos(t0), 0.0, sin(t0))
		var d1 := Vector3(cos(t1), 0.0, sin(t1))
		st.add_vertex(d0 * ri + yo)
		st.add_vertex(d0 * ro + yo)
		st.add_vertex(d1 * ro + yo)
		st.add_vertex(d0 * ri + yo)
		st.add_vertex(d1 * ro + yo)
		st.add_vertex(d1 * ri + yo)


## Радиальная лента-разделитель на угле a от r0 до r1, ширины 2*hw.
func _add_spoke(st: SurfaceTool, a: float, r0: float, r1: float, hw: float, y: float) -> void:
	var yo := Vector3(0.0, y, 0.0)
	var d := Vector3(cos(a), 0.0, sin(a))
	var t := Vector3(-sin(a), 0.0, cos(a)) * hw
	var p0a := d * r0 + t + yo
	var p0b := d * r0 - t + yo
	var p1a := d * r1 + t + yo
	var p1b := d * r1 - t + yo
	st.add_vertex(p0b)
	st.add_vertex(p0a)
	st.add_vertex(p1a)
	st.add_vertex(p0b)
	st.add_vertex(p1a)
	st.add_vertex(p1b)


# --- Жизненный цикл (deploy/pack из Camp) ---

func deploy(center: Vector3) -> void:
	global_position = center
	_active = true
	# Сетка скрыта по умолчанию — показывается только когда в руке постройка
	# (см. _on_hand_grabbed). Грид при этом активен (установка работает).
	if _line_grid != null:
		_line_grid.visible = false
	_refresh_pads()
	if debug_log and LogConfig.master_enabled:
		print("[BuildGrid] грид развёрнут @ (%.1f, %.1f)" % [center.x, center.z])


func pack() -> void:
	_active = false
	_placing = null
	if _line_grid != null:
		_line_grid.visible = false
	var had_blocks := false
	for cell in _cells:
		var b = cell["block"]
		if b != null and is_instance_valid(b):
			cell["block"] = null
			# Падающий блок снимаем с боевого состояния (как при захвате рукой):
			# иначе скелеты бьют упавший на землю генератор, и он остаётся
			# препятствием/целью. Combat вернётся при переустановке.
			if b is BuildBlock:
				(b as BuildBlock).on_picked_up()
			(b as CampModule).detach_from_slot()
			b.freeze = false
			had_blocks = true
		cell["pad"].visible = false
	# Генераторы исчезли из грида → харвестер должен пересчитать темп добычи
	# (иначе держит старый scale при нуле генераторов).
	if had_blocks:
		buildings_changed.emit()


# --- Рука: захват / отпускание ---

func _on_hand_grabbed(item: Node3D) -> void:
	if not _active:
		return
	# Схватили наш установленный блок — освобождаем ВСЕ его ячейки (здание может
	# занимать footprint>1: стена ×2). detach_from_slot один раз после.
	var was_placed := false
	for cell in _cells:
		if cell["block"] == item:
			cell["block"] = null
			cell["pad"].visible = false
			was_placed = true
	if was_placed:
		(item as CampModule).detach_from_slot()
	if item is BuildBlock:
		# Снимаем боевое состояние на время переноса (скелеты не бьют в руке, не
		# препятствие). Вернётся при завершении переустановки.
		(item as BuildBlock).on_picked_up()
		_placing = item
		# Стена: span стартует с её текущего footprint (1 у свежей, N у переносимой).
		_wall_span = maxi(1, (item as BuildBlock).footprint)
		# Освободили ячейки (возможно генераторные) → пересчёт добычи харвестера.
		if was_placed:
			buildings_changed.emit()
	# Видимость сетки и пульс строящихся ячеек ведёт _process.


## Колесо мыши при ЗАЖАТОЙ ЛКМ и стене в руке тянет её по дуге кольца: span
## растёт/убывает (1..cnt), за раз можно замкнуть весь круг. Перехватываем в
## _input (раньше камеры) и гасим событие, чтобы не зумило. Для обычных зданий
## (не wall_thin) колесо не трогаем — пусть зумит камера.
func _input(event: InputEvent) -> void:
	if not _active or _placing == null or not (_placing is BuildBlock):
		return
	var bb := _placing as BuildBlock
	if not bb.wall_thin or bb.is_gate():  # ворота — всегда 1 ячейка, span не тянем
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	if not Input.is_action_pressed(&"hand_grab"):  # «зажать ЛКМ»
		return
	var dir := 0
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		dir = 1
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		dir = -1
	else:
		return
	var t: int = clampi(bb.ring_tier, 0, segment_counts.size() - 1)
	var max_span: int = maxi(segment_counts[t], 1)
	var new_span: int = clampi(_wall_span + dir, 1, max_span)
	get_viewport().set_input_as_handled()  # не зумить камеру
	if new_span == _wall_span:
		return
	# Прокрутка ВВЕРХ упирается в ресурсный лимит: дальше, чем можешь оплатить,
	# не тянем — стена мигает красным «не хватает». Вниз — всегда свободно.
	if new_span > _wall_span and not _can_afford_span(bb, new_span):
		bb.flash_reject()
		return
	_wall_span = new_span
	_apply_wall_span()


## Хватит ли ресурсов на стену из span ячеек (цена ×span). Перенос уже купленной
## стены (purchased) — бесплатно. Без экономики/цены — всегда true.
func _can_afford_span(bb: BuildBlock, span: int) -> bool:
	if bb.purchased or _camp == null or _camp.economy == null:
		return true
	var cost: Dictionary = CampBuildings.get_data(bb.building_id).get("cost", {})
	if cost.is_empty():
		return true
	var scaled: Dictionary = {}
	for k in cost:
		scaled[k] = int(cost[k]) * span
	return _camp.economy.can_afford(scaled)


## Перестроить стену в руке под текущий _wall_span: меш на span ячеек (без зазора)
## + footprint, чтобы установка заняла столько же ячеек подряд.
func _apply_wall_span() -> void:
	if _placing == null or not (_placing is BuildBlock):
		return
	var bb := _placing as BuildBlock
	var dims: Dictionary = tier_cell_dims(bb.ring_tier, _wall_span, true)
	bb.conform_to_cell(dims["inner"], dims["outer"], dims["seg_deg"])
	bb.footprint = _wall_span


func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if not _active or _placing != item:
		return
	_placing = null
	var placed := _try_place(item as CampModule)
	if not placed and item is BuildBlock:
		var bb := item as BuildBlock
		# Свежее здание из меню (building_id задан, ещё НЕ оплачено), не вставшее
		# в ячейку — отменяем: убираем болванку, чтобы не валялась в поле.
		# Уже оплаченное (перенос существующего здания) НЕ удаляем — падает
		# свободным блоком, игрок подберёт и поставит заново.
		if bb.building_id != &"" and not bb.purchased:
			item.queue_free()
	_refresh_pads()


# --- Установка ---

func _try_place(block: CampModule) -> bool:
	if block == null:
		return false
	# Ворота — особый путь: 1 ячейка, ставятся в пустую ИЛИ заменяют сегмент стены.
	if block is BuildBlock and (block as BuildBlock).is_gate():
		return _try_place_gate(block as BuildBlock)
	# Здание встаёт только в своё кольцо (ring_tier) и занимает footprint сегментов
	# подряд (1 = обычное, 2 = двойная стена).
	var tier := 0
	var fp := 1
	if block is BuildBlock:
		tier = (block as BuildBlock).ring_tier
		fp = maxi(1, (block as BuildBlock).footprint)
	# tier 0 → только генераторное кольцо (0); иначе → любое мелкое кольцо (1..).
	var rings_to_search: Array = []
	if tier == 0:
		rings_to_search = [0]
	else:
		for r in range(1, _rings.size()):
			rings_to_search.append(r)
	# Ищем ряд из fp соседних пустых+связных ячеек (в любом из доступных колец),
	# ближайший к блоку.
	var best_r := -1
	var best_s := -1
	var best_d := snap_distance
	for r in rings_to_search:
		var cnt: int = segment_counts[r]
		if fp > cnt:
			continue
		for s in range(cnt):
			var segs := _run_segments(r, s, fp)
			if not _run_free(r, segs):
				continue
			if not _run_placeable(r, segs):
				continue
			var d := _horizontal_dist(block.global_position, to_global(_run_center_local(r, s, fp)))
			if d < best_d:
				best_d = d
				best_r = r
				best_s = s
	if best_r < 0:
		if debug_log and LogConfig.master_enabled:
			print("[BuildGrid] нет места под здание ×%d (зона tier %d)" % [fp, tier])
		return false
	# Стена: per-cell — span отдельных 1-клеточных стен (рушатся по одной, можно
	# заменить сегмент воротами). Оплата span×цена разом, остальные — purchased.
	if block is BuildBlock and (block as BuildBlock).wall_thin:
		if not _charge_wall_span(block as BuildBlock, fp):
			if debug_log and LogConfig.master_enabled:
				print("[BuildGrid] не хватает ресурсов на стену ×%d" % fp)
			return false
		_place_wall_run(block as BuildBlock, best_r, best_s, fp)
		return true
	if not _charge_building(block):
		if debug_log and LogConfig.master_enabled:
			print("[BuildGrid] не хватает ресурсов на здание")
		return false
	_place_run(block, best_r, best_s, fp)
	return true


## Установка стены пролётом span: held-блок в 1-ю ячейку (footprint 1), остальные
## span−1 — отдельными 1-клеточными стенами (спавн через build_block_scene Camp'а).
## Каждая — самостоятельный блок: рушится по одной, заменяется воротами.
func _place_wall_run(held: BuildBlock, r: int, s: int, span: int) -> void:
	var cnt: int = segment_counts[r]
	_place_run(held, r, s, 1)
	for k in range(1, span):
		var w := _spawn_wall_block(held.building_id)
		if w == null:
			break
		w.purchased = true  # оплачено через _charge_wall_span
		_place_run(w, r, (s + k) % cnt, 1)


## Спавн ещё одной стены того же типа (build_block_scene Camp'а), configure под id.
func _spawn_wall_block(id: StringName) -> BuildBlock:
	if _camp == null or _camp.build_block_scene == null:
		return null
	var w := (_camp.build_block_scene as PackedScene).instantiate() as BuildBlock
	if w == null:
		return null
	var root: Node = get_tree().current_scene
	if root == null:
		root = self
	root.add_child(w)
	w.configure(id)
	return w


## Оплата стены-пролёта: span×цена разом. Перенос (purchased) — бесплатно.
func _charge_wall_span(block: BuildBlock, span: int) -> bool:
	if block.purchased or _camp == null or _camp.economy == null:
		return true
	var cost: Dictionary = CampBuildings.get_data(block.building_id).get("cost", {})
	if cost.is_empty():
		block.purchased = true
		return true
	var scaled: Dictionary = {}
	for k in cost:
		scaled[k] = int(cost[k]) * span
	if _camp.economy.try_spend(scaled):
		block.purchased = true
		return true
	return false


## Ворота: ставятся в ближайшую пустую+связную ячейку (standalone) ИЛИ заменяют
## готовую стену в ближайшей занятой ячейке (сегмент стены → проход с дверьми).
func _try_place_gate(gate: BuildBlock) -> bool:
	var best_r := -1
	var best_s := -1
	var best_d := snap_distance
	var best_replace := false
	for r in range(1, _rings.size()):
		var cnt: int = segment_counts[r]
		for s in range(cnt):
			var occ = _rings[r][s]["block"]
			var is_wall: bool = occ != null and is_instance_valid(occ) and occ is BuildBlock \
				and (occ as BuildBlock).wall_thin and not (occ as BuildBlock).is_gate() \
				and (occ as BuildBlock).is_built
			var free_ok: bool = occ == null and _run_placeable(r, [s])
			if not (is_wall or free_ok):
				continue
			var d := _horizontal_dist(gate.global_position, to_global(_run_center_local(r, s, 1)))
			if d < best_d:
				best_d = d
				best_r = r
				best_s = s
				best_replace = is_wall
	if best_r < 0:
		if debug_log and LogConfig.master_enabled:
			print("[BuildGrid] нет места под ворота")
		return false
	if not _charge_building(gate):
		if debug_log and LogConfig.master_enabled:
			print("[BuildGrid] не хватает ресурсов на ворота")
		return false
	if best_replace:
		_remove_wall_cell(_rings[best_r][best_s]["block"], best_r, best_s)
	_place_run(gate, best_r, best_s, 1)
	return true


## Снять стену из ячейки (под замену воротами): без death-FX — чистим ячейку,
## снимаем боевое состояние (группы/навмеш) и удаляем блок.
func _remove_wall_cell(w, r: int, s: int) -> void:
	_rings[r][s]["block"] = null
	_rings[r][s]["pad"].visible = false
	if w is BuildBlock:
		(w as BuildBlock).on_picked_up()
	if w != null and is_instance_valid(w):
		w.queue_free()


## Списать стоимость здания из экономики. true если оплачено (или цена не нужна).
## Перенос уже стоявшего здания (purchased) — бесплатно: оплата только за первую
## установку. На успешной оплате помечаем purchased, чтобы дальше двигать даром.
func _charge_building(block: CampModule) -> bool:
	if not (block is BuildBlock):
		return true
	var bb := block as BuildBlock
	if bb.purchased:
		return true
	var id: StringName = bb.building_id
	if id == &"":
		return true
	var cost: Dictionary = CampBuildings.get_data(id).get("cost", {})
	if cost.is_empty() or _camp == null or _camp.economy == null:
		bb.purchased = true
		return true
	if _camp.economy.try_spend(cost):
		bb.purchased = true
		return true
	return false


func _place_run(block: CampModule, r: int, s: int, fp: int) -> void:
	# Стены (wall_thin) — без зазора, на всю ячейку: смыкаются в сплошной барьер.
	var gapless: bool = block is BuildBlock and (block as BuildBlock).wall_thin
	var dims: Dictionary = tier_cell_dims(r, fp, gapless)
	if block is BuildBlock:
		(block as BuildBlock).conform_to_cell(dims["inner"], dims["outer"], dims["seg_deg"])
	block.attach_to_slot(self)
	var world_center := to_global(_run_center_local(r, s, fp))
	block.global_position = world_center + Vector3(0.0, block.mount_lift, 0.0)
	# Лицом к ядру (горизонтально, без наклона — цель на высоте блока).
	var face := Vector3(global_position.x, block.global_position.y, global_position.z)
	block.look_at(face, Vector3.UP)
	# Вспышка-блик на месте установки в момент клика — фидбек «здание встало сюда».
	# Радиус ≈ под размер ячейки (по большей из сторон: глубина / хорда дуги).
	var f_depth: float = dims["outer"] - dims["inner"]
	var f_mid: float = (dims["inner"] + dims["outer"]) * 0.5
	var f_chord: float = 2.0 * f_mid * sin(deg_to_rad(float(dims["seg_deg"])) * 0.5)
	var root: Node = get_tree().current_scene
	if root != null:
		AoeVisual.spawn_flash(root, world_center, maxf(f_depth, f_chord) * 0.6)
	# На время стройки блок вне Grabbable — нельзя схватить силуэт. По завершении
	# BuildBlock сам возвращает себя в Grabbable (built), и здание можно поднять
	# и переставить в другую ячейку.
	block.remove_from_group(Grabbable.GROUP)
	for seg in _run_segments(r, s, fp):
		_rings[r][seg]["block"] = block
		_rings[r][seg]["pad"].visible = false
	# Стройка не мгновенная: форма поднимается по гриду за build_time, пуфф на
	# финише. По завершении (built) пересчитываем генераторы (харвестер ждёт готовых).
	if block is BuildBlock:
		var bb := block as BuildBlock
		bb.start_construction(build_time)
		if not bb.built.is_connected(_on_block_built):
			bb.built.connect(_on_block_built)
		# Разрушение скелетами — освобождаем ячейку и пересчитываем генераторы.
		if not bb.destroyed.is_connected(_on_block_destroyed):
			bb.destroyed.connect(_on_block_destroyed.bind(bb))
	if debug_log and LogConfig.master_enabled:
		print("[BuildGrid] стройка ×%d начата: кольцо %d сегмент %d (%s)" % [fp, r, s, str((block as BuildBlock).building_id) if block is BuildBlock else "?"])
	buildings_changed.emit()


func _on_block_built() -> void:
	buildings_changed.emit()


## Здание разрушено скелетами — освобождаем все его ячейки (нода уже уходит в
## queue_free сама). Пересчёт генераторов — через buildings_changed (если пал
## генератор, харвестер встаёт). Ячейка снова доступна под застройку.
func _on_block_destroyed(block) -> void:
	var freed := false
	for cell in _cells:
		if cell["block"] == block:
			cell["block"] = null
			cell["pad"].visible = false
			freed = true
	if freed and debug_log and LogConfig.master_enabled:
		print("[BuildGrid] здание разрушено — ячейки освобождены")
	buildings_changed.emit()


## fp подряд идущих сегментов с обёрткой по кольцу, начиная с s.
func _run_segments(r: int, s: int, fp: int) -> Array:
	var cnt: int = segment_counts[r]
	var segs: Array = []
	for k in range(fp):
		segs.append((s + k) % cnt)
	return segs


func _run_free(r: int, segs: Array) -> bool:
	for seg in segs:
		if _rings[r][seg]["block"] != null:
			return false
	return true


func _run_center_local(r: int, s: int, fp: int) -> Vector3:
	var cnt: int = segment_counts[r]
	var mid: float = _ring_inner(r) + ring_band * 0.5
	var ang: float = (float(s) + float(fp) * 0.5) * TAU / float(cnt)
	return Vector3(cos(ang) * mid, 0.0, sin(ang) * mid)


## Связность ряда: кольцо 0 ИЛИ у одной из ячеек занят сосед ВНЕ ряда.
func _run_placeable(r: int, segs: Array) -> bool:
	if r == 0:
		return true
	for seg in segs:
		for n in _neighbors(r, seg):
			if n[0] == r and segs.has(n[1]):
				continue
			var nc = _cell_at(n[0], n[1])
			if nc != null and nc["block"] != null:
				return true
	return false


## Размеры ячейки кольца tier (inner/outer/seg_deg) — чтобы здание в руке сразу
## было нужного размера (Camp конформит блок под это при спавне в руку).
func tier_cell_dims(tier: int, footprint: int = 1, gapless: bool = false) -> Dictionary:
	var t: int = clampi(tier, 0, segment_counts.size() - 1)
	var cnt: int = maxi(segment_counts[t], 1)
	var inner: float = _ring_inner(t)
	var fp: int = maxi(1, footprint)
	return {
		"inner": inner,
		"outer": inner + ring_band,
		"seg_deg": _seg_deg(inner, cnt, fp, gapless),
	}


## Сколько генераторов установлено в гриде (для гейта харвестера).
func generator_count() -> int:
	var n := 0
	for cell in _cells:
		var b = cell["block"]
		if b != null and is_instance_valid(b) and b is BuildBlock and (b as BuildBlock).building_id == CampBuildings.GENERATOR and (b as BuildBlock).is_built:
			n += 1
	return n


# --- Связность ---

## Ячейку можно занять: кольцо 0 (примыкает к ядру-харвестеру) ИЛИ занят сосед.
## Существующий набор по индукции уже связан с ядром, потому полной BFS не нужно.
func _is_placeable(cell: Dictionary) -> bool:
	if int(cell["r"]) == 0:
		return true
	for n in _neighbors(int(cell["r"]), int(cell["s"])):
		var nc = _cell_at(n[0], n[1])
		if nc != null and nc["block"] != null:
			return true
	return false


## Соседи ячейки (r,s): ±1 по своему кольцу + радиальные (внутрь/наружу) по
## ПЕРЕКРЫТИЮ УГЛОВ — работает при любых counts (кольца не обязаны быть кратны).
func _neighbors(r: int, s: int) -> Array:
	var cnt: int = segment_counts[r]
	var res: Array = [[r, (s - 1 + cnt) % cnt], [r, (s + 1) % cnt]]
	res.append_array(_radial_neighbors(r, s, -1))
	res.append_array(_radial_neighbors(r, s, 1))
	return res


## Ячейки соседнего кольца (r+dr), чьи угловые диапазоны перекрывают (r,s).
func _radial_neighbors(r: int, s: int, dr: int) -> Array:
	var nr: int = r + dr
	if nr < 0 or nr >= _rings.size():
		return []
	var cnt: int = segment_counts[r]
	var ncnt: int = segment_counts[nr]
	var lo: int = int(floor(float(s) * float(ncnt) / float(cnt)))
	var hi: int = int(ceil(float(s + 1) * float(ncnt) / float(cnt))) - 1
	var res: Array = []
	for ns in range(lo, hi + 1):
		res.append([nr, ((ns % ncnt) + ncnt) % ncnt])
	return res


func _cell_at(r: int, s: int):
	if r < 0 or r >= _rings.size():
		return null
	var ring: Array = _rings[r]
	if s < 0 or s >= ring.size():
		return null
	return ring[s]


# --- Подсветка пад-маркеров / видимость сетки ---

func _process(delta: float) -> void:
	if not _active:
		return
	_pulse_t += delta
	_update_grid_visuals()
	_orient_held_block()


## Пока здание в руке — каждый кадр разворачиваем его ЛИЦОМ К ЯДРУ (как оно
## встанет в ячейку), а не висит в повороте спавна. Рука рулит только позицией
## (_update_held_position поворот не трогает), так что конфликта нет. Та же
## ориентация, что в _place_run: look_at ядра горизонтально (-Z к ядру → сектор
## раскрыт наружу, как ячейки кольца).
func _orient_held_block() -> void:
	if _placing == null or not is_instance_valid(_placing):
		return
	var b: Node3D = _placing
	var face := Vector3(global_position.x, b.global_position.y, global_position.z)
	if b.global_position.distance_squared_to(face) < 0.0001:
		return  # блок ровно над ядром — look_at вырожден, пропускаем кадр
	b.look_at(face, Vector3.UP)


## Per-frame: сетка видна пока в руке здание ИЛИ что-то строится; пады —
## зелёная подсветка валидных (при удержании) и ПУЛЬС строящихся ячеек.
func _update_grid_visuals() -> void:
	if not _active:
		return
	var pulse: float = 0.5 + 0.5 * sin(_pulse_t * PULSE_SPEED)
	var any_build := false
	for cell in _cells:
		var pad: MeshInstance3D = cell["pad"]
		var mat: StandardMaterial3D = cell["mat"]
		var b = cell["block"]
		var constructing: bool = b != null and is_instance_valid(b) and b is BuildBlock and not (b as BuildBlock).is_built
		if constructing:
			any_build = true
			pad.visible = true
			mat.albedo_color = valid_color
			mat.emission = Color(valid_color.r, valid_color.g, valid_color.b)
			mat.emission_energy_multiplier = lerpf(0.25, 1.0, pulse)
		elif b != null:
			pad.visible = false
		elif _placing != null and _is_placeable(cell):
			pad.visible = true
			mat.albedo_color = valid_color
			mat.emission = Color(valid_color.r, valid_color.g, valid_color.b)
			mat.emission_energy_multiplier = 0.6
		else:
			pad.visible = false
	if _line_grid != null:
		_line_grid.visible = _placing != null or any_build


## Совместимость со старыми вызовами — единоразовый апдейт визуала.
func _refresh_pads() -> void:
	_update_grid_visuals()


func _horizontal_dist(a: Vector3, b: Vector3) -> float:
	var d := a - b
	d.y = 0.0
	return d.length()
