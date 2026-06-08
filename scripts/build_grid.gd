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
## Радиальная толщина одного кольца.
@export var ring_band: float = GridGeo.RING_BAND
## Угловой зазор между ячейками (градусы) — швы, чтобы ячейки читались раздельно.
@export var cell_gap_deg: float = GridGeo.CELL_GAP_DEG
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


# --- Построение ячеек + пад-маркеров ---

func _build_cells() -> void:
	for r in range(segment_counts.size()):
		var cnt: int = maxi(segment_counts[r], 1)
		var inner: float = core_radius + float(r) * ring_band
		var outer: float = inner + ring_band
		var seg_deg: float = 360.0 / float(cnt) - cell_gap_deg
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


## Чёткая сетка линиями: окружности на границах колец + радиальные разделители
## (по counts[r] в своём кольце — наружу делений больше). Плоские ленты по земле.
func _build_line_grid() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := pad_y + 0.01
	var hw := line_width * 0.5
	var n := segment_counts.size()
	# Концентрические окружности на каждой границе кольца (включая внешнюю).
	for r in range(n + 1):
		_add_ring_band(st, core_radius + float(r) * ring_band, hw, y)
	# Радиальные разделители — в каждом кольце своё число (4/8/16).
	for r in range(n):
		var cnt: int = maxi(segment_counts[r], 1)
		var r0: float = core_radius + float(r) * ring_band
		var r1: float = r0 + ring_band
		for s in range(cnt):
			_add_spoke(st, float(s) * TAU / float(cnt), r0, r1, hw, y)
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


## Плоское кольцо-лента (окружность ширины 2*hw) на радиусе radius.
func _add_ring_band(st: SurfaceTool, radius: float, hw: float, y: float) -> void:
	var yo := Vector3(0.0, y, 0.0)
	var ri: float = maxf(radius - hw, 0.0)
	var ro: float = radius + hw
	var segs := 64
	for i in range(segs):
		var t0 := float(i) / float(segs) * TAU
		var t1 := float(i + 1) / float(segs) * TAU
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
		# Освободили ячейки (возможно генераторные) → пересчёт добычи харвестера.
		if was_placed:
			buildings_changed.emit()
	# Видимость сетки и пульс строящихся ячеек ведёт _process.


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
	if not _charge_building(block):
		if debug_log and LogConfig.master_enabled:
			print("[BuildGrid] не хватает ресурсов на здание")
		return false
	_place_run(block, best_r, best_s, fp)
	return true


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
	var dims: Dictionary = tier_cell_dims(r, fp)
	if block is BuildBlock:
		(block as BuildBlock).conform_to_cell(dims["inner"], dims["outer"], dims["seg_deg"])
	block.attach_to_slot(self)
	var world_center := to_global(_run_center_local(r, s, fp))
	block.global_position = world_center + Vector3(0.0, block.mount_lift, 0.0)
	# Лицом к ядру (горизонтально, без наклона — цель на высоте блока).
	var face := Vector3(global_position.x, block.global_position.y, global_position.z)
	block.look_at(face, Vector3.UP)
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
	var mid: float = core_radius + (float(r) + 0.5) * ring_band
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
func tier_cell_dims(tier: int, footprint: int = 1) -> Dictionary:
	var t: int = clampi(tier, 0, segment_counts.size() - 1)
	var cnt: int = maxi(segment_counts[t], 1)
	var inner: float = core_radius + float(t) * ring_band
	var fp: int = maxi(1, footprint)
	return {
		"inner": inner,
		"outer": inner + ring_band,
		"seg_deg": float(fp) * 360.0 / float(cnt) - cell_gap_deg,
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
