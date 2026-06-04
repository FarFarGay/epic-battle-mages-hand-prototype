class_name HandBuildAim
extends Node
## Координатор aim-режима для построек, требующих интерактивного выбора
## точки (флаг `requires_aim` в [Camp.CAMP_BUILDING_CATALOG]). Сейчас —
## сторожевой колокол: ПКМ-курсор показывает место, кольцо вокруг — радиус
## области alarm'а будущего колокола.
##
## По образцу [HandSquadAim]: Hand-категория переключается на BUILD_AIM,
## остальные ввод-системы гасятся. UI (gameplay_hud или JournalPanel)
## запускает через `start_aim(building_id)`; повторный вызов с тем же id
## → cancel_aim (toggle). Esc — отмена без построения.

const ACTION_AIM_COMMIT := &"hand_action"
const ACTION_AIM_CANCEL := &"ui_cancel"

## Высота отрыва ground-индикатора от земли. Достаточно чтобы избежать
## z-fighting'а с terrain'ом, недостаточно чтобы читалось как «висит».
const AIM_RING_HEIGHT: float = 0.05

## Высота центра preview-меша постройки над землёй. Превью-меш BoxMesh
## ~1.5м высотой → центр на 0.75м чтобы низ совпал с землёй.
const PREVIEW_MESH_CENTER_HEIGHT: float = 0.75

@export_group("Visual")
## Цвет ground-ring'а — visualization будущей alarm-зоны колокола.
## Жёлто-оранжевый = «здесь будет стоять сторож».
@export var aim_ring_color: Color = Color(1.0, 0.8, 0.25, 0.85)
## Цвет когда строительство не разрешено в этой точке (вне build_zone лагеря).
## Игрок видит что ПКМ не сработает.
@export var aim_ring_color_invalid: Color = Color(0.85, 0.25, 0.25, 0.9)
## Цвет большого круга зоны строительства (вокруг лагеря). Полупрозрачный
## голубой — отличается от preview-кольца постройки и aim-ring'а squad'а.
@export var build_zone_color: Color = Color(0.45, 0.75, 1.0, 0.55)
## Цвет preview-сегмента в активной части ломаной (от последнего vertex'а к
## курсору) когда сегмент в build_zone. Полупрозрачный зелёный — «строится сюда».
@export var brush_preview_color_valid: Color = Color(0.3, 0.9, 0.3, 0.55)
## Цвет preview когда хотя бы один сегмент текущего отрезка вне build_zone.
## Игрок видит «ПКМ не сработает».
@export var brush_preview_color_invalid: Color = Color(0.9, 0.3, 0.3, 0.65)
## Цвет уже зафиксированных vertex-пар (от vertex_i к vertex_{i+1}).
## Чуть бледнее зелёного активного — игрок видит «эта часть уже подтверждена».
@export var brush_committed_color: Color = Color(0.5, 0.85, 0.5, 0.45)
## Цвет active-preview когда vertex-лимит достигнут (BRUSH_MAX_VERTICES).
## Жёлто-оранжевый = «больше не добавишь, нажми ПКМ для постройки».
@export var brush_preview_color_max: Color = Color(0.95, 0.7, 0.15, 0.7)

@export var debug_log: bool = true

@export_group("")

var _hand: Hand
var _camp: Camp
var _effects_root: Node = null
var _active_building: StringName = &""
## Кэш радиуса будущей постройки — для визуального кольца. Заполняется
## в start_aim по building-id'у. 0 = нет визуала, кольцо не рисуется.
var _aim_radius: float = 0.0
var _aim_indicator: MeshInstance3D = null
## Большой круг зоны строительства вокруг центра лагеря — видим только в
## активном aim'е. Не двигается (camp.build_zone_center статичен в DEPLOYED).
var _build_zone_indicator: MeshInstance3D = null
## Direction-aim режим (drag-направление: ЛКМ-зажим → origin → drag → release).
## _direction_aim_mode определяет что вызвать на commit:
##   "" — выкл, обычный single-point aim.
##   "archer_post" / другие — drag-flow для построек, требующих facing'а.
## _direction_origin = INF до press'а; после press'а — позиция.
var _direction_aim_mode: String = ""
var _direction_origin: Vector3 = Vector3.INF
## Визуал линии направления — стрелка от origin к курсору во время drag'а.
var _direction_arrow: MeshInstance3D = null
## Радиус «захвата» от точки курсора для будущих pickup-объектов.
## Совпадает с [Hand.PICKUP_HIGHLIGHT_RADIUS] — игрок видит подсветку, видит и точку
## действия. 1.5м комфортно — попадать пиксель-в-пиксель не нужно.
const PICKUP_RADIUS: float = 1.5

# --- Brush-mode (polyline editor для частокола и подобных) ---
## Если true — мы в brush-режиме, polyline editor активен. ЛКМ ставит
## vertex'ы ломаной, preview-сегменты следуют курсору, ПКМ — построить,
## Esc — отмена.
var _brush_mode: bool = false
## Зафиксированные точки ломаной (мировые позиции, Y клампится к anchor.y).
var _brush_vertices: Array[Vector3] = []
## Длина одного сегмента в метрах. Читается из catalog'а на start_brush.
var _brush_segment_length: float = 2.0
## Стоимость одного сегмента (Dict ResourceType → amount). Используется
## для affordability-проверки — если total_cost > наличия, preview краснеет.
var _brush_cost_per_segment: Dictionary = {}
## Building id, из которого читали параметры — для commit'а зовём
## правильный method у Camp.
var _brush_building: StringName = &""
## Preview-сегменты для УЖЕ зафиксированных vertex-пар (от vertex_i к
## vertex_{i+1}). Создаются один раз при добавлении vertex'а, не пересчитываются
## каждый кадр. На cancel/commit — очищаются.
var _brush_committed_meshes: Array[MeshInstance3D] = []
## Preview-сегменты для активной части (от последнего vertex'а к курсору).
## Пересоздаются каждый кадр в _update_brush_active_preview — курсор движется.
var _brush_active_meshes: Array[MeshInstance3D] = []
## Счётчик уже зафиксированных сегментов (накапливается в _add_brush_vertex
## при спавне committed-preview). Используется для affordability-проверки —
## считать длины committed-пар каждый кадр было бы лишним.
var _brush_committed_segments_count: int = 0
## Маленькое кольцо вокруг кандидата snap'а (если первый vertex попадёт
## близко к существующему palisade-vertex'у). Spawn'ится / hide'ится в
## [_update_brush_active_preview]. Persistent — переиспользуется между
## кадрами через visibility.
var _brush_snap_indicator: MeshInstance3D = null
## Анти-spam: жёсткий лимит вершин в одной ломаной. 20 = ~38 сегментов × 2м =
## линия длиной 76м, перекрывает разумную «оборонную стену».
const BRUSH_MAX_VERTICES: int = 20
## Минимальная длина отрезка для постройки сегмента. Короче — игнорируется.
const BRUSH_MIN_SEGMENT_LENGTH: float = 0.5
## Радиус snap'а первой вершины к существующему palisade-vertex (углу
## уже построенной стены). Игрок может «продолжить» от любого угла без
## точного попадания пикселем — в этом радиусе курсор магнитит к vertex'у.
## 1.5м совпадает с [PICKUP_RADIUS] — единый «handler-радиус» руки.
const BRUSH_SNAP_RADIUS: float = 1.5
## Цвет snap-индикатора (маленькое кольцо вокруг кандидата на snap).
## Чуть ярче active-preview — глаз цепляется.
const BRUSH_SNAP_COLOR := Color(0.55, 1.0, 0.55, 0.85)


func _ready() -> void:
	_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp


func setup(hand: Hand) -> void:
	_hand = hand


## Hand.physical вызывает в обработке ЛКМ-press (ACTION_GRAB). Если в радиусе
## [PICKUP_RADIUS] от курсора есть колокол — переходим в relocate-mode, иначе
## возвращаем false (hand_physical продолжает обычное grab/slam).
## True если сейчас идёт aim для указанной постройки.
func is_aiming(building_id: StringName) -> bool:
	return _active_building == building_id


func is_aiming_any() -> bool:
	return _active_building != &"" or _brush_mode


## Стартует polyline-режим для brush-постройки (частокол и подобные). UI
## (JournalPanel) зовёт когда игрок кликает карточку с `brush_mode: true` в
## CAMP_BUILDING_CATALOG. ЛКМ ставит vertex'ы ломаной, ПКМ — построить, Esc —
## отмена.
func start_brush(building_id: StringName) -> void:
	if not is_instance_valid(_hand):
		push_warning("[Hand:BuildAim] start_brush — _hand не задан")
		return
	if is_aiming_any():
		cancel_aim()
	var data: Dictionary = Camp.CAMP_BUILDING_CATALOG.get(building_id, {})
	if not data.get("brush_mode", false):
		push_warning("[Hand:BuildAim] start_brush: %s не brush_mode" % building_id)
		return
	if not is_instance_valid(_camp):
		_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	_brush_mode = true
	_brush_building = building_id
	_brush_vertices = []
	_brush_committed_segments_count = 0
	_brush_segment_length = float(data.get("segment_length", 2.0))
	_brush_cost_per_segment = data.get("cost_per_segment", {})
	_hand.push_category(Hand.Category.BUILD_AIM)
	_spawn_build_zone_only_indicator()
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BuildAim] brush-старт %s, segment_length=%.1f" % [
			building_id, _brush_segment_length,
		])


## Спавнит ТОЛЬКО большой круг build-zone (без preview-кольца под курсором
## как в обычном aim'е — у brush'а свой preview через сегменты).
func _spawn_build_zone_only_indicator() -> void:
	_clear_indicator()
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	if not is_instance_valid(_camp):
		_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	if is_instance_valid(_camp):
		var zone_center: Vector3 = _camp.build_zone_center()
		if zone_center != Vector3.INF:
			_build_zone_indicator = AoeVisual.spawn_ground_ring(
				_effects_root, zone_center, _camp.build_radius, 0.0, build_zone_color,
			)


## Toggle: если aim активен на этой постройке → cancel. Иначе → start.
func toggle_aim_for(building_id: StringName) -> void:
	if _active_building == building_id:
		cancel_aim()
	else:
		start_aim(building_id)


## Запуск aim'а. Радиус кольца берётся из CAMP_BUILDING_CATALOG (поле
## `aim_radius` — preview визуала; не задано → 0, кольцо не рисуется).
## Для сторожевого колокола это [WatchBell.alarm_radius] (15м).
##
## Если в каталоге у постройки стоит флаг `requires_direction: true` — это
## drag-direction flow с auto-fallback на короткий клик (наружу от лагеря),
## аналогично defense-formation. Используется для построек с явным facing'ом
## (стрелковый пост, будущие орудия). Иначе — обычный single-point aim.
func start_aim(building_id: StringName) -> void:
	if not is_instance_valid(_hand):
		push_warning("[Hand:BuildAim] start_aim — _hand не задан")
		return
	if _active_building != &"":
		cancel_aim()
	_active_building = building_id
	var data: Dictionary = Camp.CAMP_BUILDING_CATALOG.get(building_id, {})
	_aim_radius = float(data.get("aim_radius", 0.0))
	# `requires_direction` → direction-aim flow (drag для facing, короткий клик
	# фолбэк на «наружу от лагеря»). Сама диспатч-ветка в _commit_direction_aim
	# идёт по «_» — generic, она дёрнет Camp.try_build с position + facing_dir.
	if data.get("requires_direction", false):
		_direction_aim_mode = "_generic"
	else:
		_direction_aim_mode = ""
	_direction_origin = Vector3.INF
	_hand.push_category(Hand.Category.BUILD_AIM)
	_spawn_indicator()
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BuildAim] aim старт для %s, radius=%.1f, direction=%s" % [
			building_id, _aim_radius, str(_direction_aim_mode != ""),
		])


func cancel_aim() -> void:
	if _brush_mode:
		if debug_log and LogConfig.master_enabled:
			print("[Hand:BuildAim:Brush] отмена ломаной")
		_finish_brush()
		return
	if _active_building == &"":
		return
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BuildAim] aim отменён")
	_finish_aim()


func _process(_delta: float) -> void:
	# Brush-режим (частокол) — polyline editor.
	if _brush_mode:
		_process_brush()
		return
	if _active_building == &"":
		return
	var ground: Vector3 = _hand.cursor_world_position()
	ground.y -= _hand.hand_height
	# Direction-aim — отдельный flow с ЛКМ-зажимом для origin'а и release'ом
	# для commit'а. Превью включает стрелку от origin к курсору.
	if _direction_aim_mode != "":
		_process_direction_aim(ground)
		return
	if is_instance_valid(_aim_indicator):
		_aim_indicator.global_position = ground + Vector3.UP * AIM_RING_HEIGHT
		var in_zone: bool = is_instance_valid(_camp) and _camp.is_in_build_zone(ground)
		_set_ring_color(_aim_indicator, aim_ring_color if in_zone else aim_ring_color_invalid)
	if Input.is_action_just_pressed(ACTION_AIM_CANCEL):
		cancel_aim()
		return
	if Input.is_action_just_pressed(ACTION_AIM_COMMIT) and not _hand.is_pointer_over_ui():
		_commit_aim()


## Direction-aim flow:
##   1. До press'а — кольцо едет за курсором, ЛКМ задаёт origin.
##   2. После press'а — origin зафиксирован, стрелка показывает направление
##      от origin к курсору. Перекрашивается invalid если origin вне зоны.
##   3. ЛКМ release → commit с {position: origin, facing_dir: cursor - origin}.
##   4. Esc → отмена.
func _process_direction_aim(ground: Vector3) -> void:
	if Input.is_action_just_pressed(ACTION_AIM_CANCEL):
		cancel_aim()
		return
	# Pre-press: кольцо едет за курсором, ждём ЛКМ.
	if _direction_origin == Vector3.INF:
		if is_instance_valid(_aim_indicator):
			_aim_indicator.global_position = ground + Vector3.UP * AIM_RING_HEIGHT
			var in_zone_pre: bool = is_instance_valid(_camp) and _camp.is_in_build_zone(ground)
			_set_ring_color(_aim_indicator, aim_ring_color if in_zone_pre else aim_ring_color_invalid)
		# ЛКМ press вне UI и в build_zone → фиксируем origin.
		if Input.is_action_just_pressed(ACTION_BRUSH_VERTEX) and not _hand.is_pointer_over_ui():
			if is_instance_valid(_camp) and _camp.is_in_build_zone(ground):
				_direction_origin = ground
				_spawn_direction_arrow()
		return
	# После press'а — обновляем стрелку origin → cursor.
	if is_instance_valid(_aim_indicator):
		_aim_indicator.global_position = _direction_origin + Vector3.UP * AIM_RING_HEIGHT
	_update_direction_arrow(ground)
	# Release ЛКМ → commit.
	if Input.is_action_just_released(ACTION_BRUSH_VERTEX):
		_commit_direction_aim(ground)


## Спавнит mesh-стрелку для drag-превью. Тонкая прямоугольная полоса
## с эмиссией, ориентируется в `_update_direction_arrow`.
func _spawn_direction_arrow() -> void:
	if not is_instance_valid(_effects_root):
		_effects_root = get_tree().current_scene
	if _direction_arrow != null and is_instance_valid(_direction_arrow):
		_direction_arrow.queue_free()
	_direction_arrow = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.15, 0.05, 1.0)  # x=толщина, z=длина (масштабируем)
	_direction_arrow.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.3, 0.8)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.3, 1.0)
	mat.emission_energy_multiplier = 0.8
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_direction_arrow.material_override = mat
	_direction_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_effects_root.add_child(_direction_arrow)


## Каждый кадр обновляет позицию/масштаб/ориентацию стрелки от _direction_origin
## к текущему курсору. Длина = horizontal-дистанция; ось +Z (вперёд).
func _update_direction_arrow(ground: Vector3) -> void:
	if not is_instance_valid(_direction_arrow):
		return
	var to_cursor: Vector3 = ground - _direction_origin
	to_cursor.y = 0.0
	var d: float = to_cursor.length()
	if d < 0.05:
		_direction_arrow.visible = false
		return
	_direction_arrow.visible = true
	var dir: Vector3 = to_cursor / d
	# Центр стрелки — посередине между origin и cursor, чуть над землёй.
	var mid: Vector3 = _direction_origin + to_cursor * 0.5 + Vector3.UP * AIM_RING_HEIGHT
	_direction_arrow.global_position = mid
	# Ориентация: локальный +Z должен смотреть от origin к cursor. look_at
	# смотрит -Z на target, поэтому ставим target позади mid.
	_direction_arrow.look_at(mid - dir, Vector3.UP)
	# Длина по Z: BoxMesh.size.z = 1, масштабируем scale.z = d.
	_direction_arrow.scale = Vector3(1.0, 1.0, d)


## Минимальная длина drag'а в метрах, при которой расцениваем жест как
## explicit facing. Меньше — это «короткий клик», facing вычисляется
## автоматически наружу от центра лагеря. 0.5м ≈ маленький drag, который
## игрок мог сделать неосознанно при «обычном клике» — игнорируем.
const DEFENSE_AUTO_FACING_DRAG_THRESHOLD: float = 0.5

func _commit_direction_aim(ground: Vector3) -> void:
	var origin: Vector3 = _direction_origin
	var to_cursor: Vector3 = ground - origin
	to_cursor.y = 0.0
	var drag_length_sq: float = to_cursor.length_squared()
	var facing: Vector3 = Vector3.FORWARD
	if drag_length_sq > 0.0001:
		facing = to_cursor.normalized()
	# Очистим стрелку до dispatch'а — на любом исходе она больше не нужна.
	if is_instance_valid(_direction_arrow):
		_direction_arrow.queue_free()
	_direction_arrow = null
	_direction_origin = Vector3.INF
	# Резолвим Camp.
	if not is_instance_valid(_camp):
		_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	if not is_instance_valid(_camp):
		push_warning("[Hand:BuildAim] _camp не резолвится — commit прерван")
		_finish_aim()
		return
	# Гибрид click/drag: короткий drag → facing вычисляется автоматически
	# наружу от центра лагеря; явный drag → используем direction как facing.
	var is_short_click: bool = drag_length_sq < DEFENSE_AUTO_FACING_DRAG_THRESHOLD * DEFENSE_AUTO_FACING_DRAG_THRESHOLD
	if is_short_click:
		var camp_center: Vector3 = _camp.build_zone_center()
		var to_pos: Vector3 = origin - camp_center
		to_pos.y = 0.0
		facing = to_pos.normalized() if to_pos.length_squared() > 0.0001 else Vector3.FORWARD
	# Generic drag-direction для построек с requires_direction
	# (стрелковый пост, будущие орудия).
	var result: Dictionary = _camp.try_build(_active_building, {
		"position": origin,
		"facing_dir": facing,
	})
	if LogConfig.master_enabled:
		print("[Hand:BuildAim] direction-commit %s @ (%.1f, %.1f) face=(%.2f, %.2f) %s → %s / %s" % [
			_active_building, origin.x, origin.z, facing.x, facing.z,
			"[auto]" if is_short_click else "[drag]",
			"success" if result.get("success", false) else "FAIL",
			str(result.get("reason", "")),
		])
	_finish_aim()


# --- Brush-mode (polyline editor) ---

const ACTION_BRUSH_VERTEX := &"hand_grab"  # ЛКМ ставит vertex'ы

## Brush-процесс: обновляет preview активной части (от last_vertex к курсору),
## слушает ЛКМ/ПКМ/Esc.
func _process_brush() -> void:
	if not is_instance_valid(_hand):
		return
	var cursor: Vector3 = _hand.cursor_world_position()
	cursor.y -= _hand.hand_height
	_update_brush_active_preview(cursor)
	if Input.is_action_just_pressed(ACTION_AIM_CANCEL):
		cancel_aim()
		return
	if Input.is_action_just_pressed(ACTION_AIM_COMMIT) and not _hand.is_pointer_over_ui():
		_commit_brush()
		return
	if Input.is_action_just_pressed(ACTION_BRUSH_VERTEX) and not _hand.is_pointer_over_ui():
		_add_brush_vertex(cursor)


## Ищет ближайший palisade-vertex (PalisadePost из группы palisade_vertex)
## в радиусе [BRUSH_SNAP_RADIUS] от cursor'а. Если нашёл — возвращает его
## позицию, иначе Vector3.INF. Используется для snap'а первой вершины новой
## цепочки — игрок может продолжить от любого угла без пикселя в пиксель.
##
## Горизонтальная дистанция (Y игнорируется) — palisade всегда на земле
## лагеря, snap по XZ.
func _find_snap_vertex(cursor: Vector3) -> Vector3:
	var best_pos: Vector3 = Vector3.INF
	var best_d_sq: float = BRUSH_SNAP_RADIUS * BRUSH_SNAP_RADIUS
	for node in get_tree().get_nodes_in_group(PalisadeSegment.PALISADE_VERTEX_GROUP):
		if not is_instance_valid(node):
			continue
		var post: Node3D = node as Node3D
		if post == null:
			continue
		var dx: float = post.global_position.x - cursor.x
		var dz: float = post.global_position.z - cursor.z
		var d_sq: float = dx * dx + dz * dz
		if d_sq < best_d_sq:
			best_d_sq = d_sq
			best_pos = post.global_position
	return best_pos


## Добавляет vertex в ломаную. Если это первая точка — просто сохраняем
## (нет committed-segment'ов от него до предыдущей). Иначе считаем сегменты
## от last_vertex до новой точки и спавним committed-preview'ы.
func _add_brush_vertex(cursor: Vector3) -> void:
	if _brush_vertices.size() >= BRUSH_MAX_VERTICES:
		# Visual feedback за счёт цвета active-preview происходит в
		# _update_brush_active_preview (brush_preview_color_max). Здесь
		# только лог для дизайнера.
		if debug_log and LogConfig.master_enabled:
			print("[Hand:BuildAim:Brush] лимит вершин (%d) — ПКМ строит или Esc отменяет" % BRUSH_MAX_VERTICES)
		return
	# Y клампим к anchor — все сегменты на земле лагеря.
	var anchor: Vector3 = _camp.build_zone_center() if is_instance_valid(_camp) else Vector3.ZERO
	if anchor == Vector3.INF:
		anchor = Vector3.ZERO
	var pt: Vector3 = Vector3(cursor.x, anchor.y, cursor.z)
	# Snap первой вершины новой цепочки к существующему palisade-vertex.
	# Игрок может «продолжить» от любого угла уже построенной стены.
	if _brush_vertices.is_empty():
		var snap: Vector3 = _find_snap_vertex(cursor)
		if snap != Vector3.INF:
			pt = Vector3(snap.x, anchor.y, snap.z)
		_brush_vertices.append(pt)
		if debug_log and LogConfig.master_enabled:
			var snap_note: String = " [SNAP]" if snap != Vector3.INF else ""
			print("[Hand:BuildAim:Brush] vertex 1 @ (%.1f, %.1f)%s" % [pt.x, pt.z, snap_note])
		return
	var last: Vector3 = _brush_vertices[-1]
	if (last - pt).length() < BRUSH_MIN_SEGMENT_LENGTH:
		# Слишком близко к последнему vertex'у — игнорируем, чтобы не плодить
		# vertex'ы один-в-один.
		return
	_brush_vertices.append(pt)
	# Перерисовываем committed-preview между last и pt. Возвращает count
	# спавненных сегментов — копим в _brush_committed_segments_count для
	# total-cost label'а.
	var committed_count: int = _spawn_committed_preview_segments(last, pt)
	_brush_committed_segments_count += committed_count
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BuildAim:Brush] vertex %d @ (%.1f, %.1f), +%d сегментов" % [
			_brush_vertices.size(), pt.x, pt.z, committed_count,
		])


## Пересчитывает preview активной части (от last_vertex'а до курсора).
## Каждый кадр обновляет позицию/цвет существующих preview-меш'ей вместо
## queue_free + create. Раньше при BRUSH_MAX_VERTICES=20 и 60FPS делал до
## ~2280 alloc/free MeshInstance3D в секунду — теперь только перепозиция.
## Cleanup пула — в [_finish_brush].
##
## _brush_active_meshes используется как пул переменного размера: вершины
## приходят/уходят, разница по сравнению с прошлым кадром обычно ≤1 сегмент.
func _update_brush_active_preview(cursor: Vector3) -> void:
	# Все существующие preview сначала «hide»; ниже разиспользуем нужное
	# количество, лишние останутся hidden до следующего тика или free на
	# _finish_brush.
	for m in _brush_active_meshes:
		if is_instance_valid(m):
			m.visible = false
	var used: int = 0
	if _brush_vertices.is_empty():
		# Snap-индикатор: если рядом с курсором есть palisade-vertex, рисуем
		# маленькое кольцо на нём — игрок видит «здесь начнётся новая стена».
		var snap_pos: Vector3 = _find_snap_vertex(cursor)
		_update_brush_snap_indicator(snap_pos)
		# Ещё не поставили первый vertex — показываем «фантомный сегмент»
		# в точке курсора (горизонтально, дефолтная ориентация). Подсказка:
		# «ЛКМ поставит первую точку».
		_acquire_preview_segment(used, cursor, 0.0, brush_preview_color_valid)
		return
	# После постановки первого vertex'а snap-индикатор не нужен.
	_update_brush_snap_indicator(Vector3.INF)
	var last: Vector3 = _brush_vertices[-1]
	var pt: Vector3 = Vector3(cursor.x, last.y, cursor.z)
	var dir: Vector3 = pt - last
	var length: float = dir.length()
	if length < BRUSH_MIN_SEGMENT_LENGTH:
		# Курсор слишком близко к last_vertex — preview пустой.
		return
	# ceil вместо floor + равномерный шаг — см. камп.gd:try_build_palisade_line.
	# Preview должен совпадать со spawn'ом, иначе игрок видит одно, получает
	# другое.
	var count: int = int(ceil(length / _brush_segment_length))
	if count <= 0:
		return
	var step_length: float = length / float(count)
	var step: Vector3 = dir.normalized() * step_length
	# Yaw: локальная ось +X сегмента (длина BoxMesh) должна идти вдоль dir.
	var rot_y: float = atan2(-dir.z, dir.x)
	# Проверка валидности: все сегменты в build_zone.
	var all_in_zone: bool = true
	for j in range(count):
		var center: Vector3 = last + step * (float(j) + 0.5)
		if not is_instance_valid(_camp) or not _camp.is_in_build_zone(center):
			all_in_zone = false
			break
	# Affordability: total = committed + active. Если хоть одного ресурса не
	# хватает на полный план — весь blueprint краснеет (и активный, и
	# committed). Это единственный сигнал «не построится» — label убран.
	var total: int = _brush_committed_segments_count + count
	var can_afford: bool = _can_afford_total(total)
	var at_max: bool = _brush_vertices.size() >= BRUSH_MAX_VERTICES
	var active_color: Color
	if not all_in_zone or not can_afford:
		active_color = brush_preview_color_invalid
	elif at_max:
		active_color = brush_preview_color_max
	else:
		active_color = brush_preview_color_valid
	for j in range(count):
		var center: Vector3 = last + step * (float(j) + 0.5)
		_acquire_preview_segment(used, center, rot_y, active_color)
		used += 1
	# Committed сегменты держат свой цвет, но краснеют синхронно — это часть
	# того же blueprint'а. Перекраска копеечная (≤ ~38 мешей).
	var committed_color: Color = brush_committed_color if can_afford else brush_preview_color_invalid
	for m in _brush_committed_meshes:
		_apply_color_to_mesh(m, committed_color)


## Показывает / прячет маленький snap-индикатор на palisade-vertex'е.
## Принимает Vector3.INF чтобы спрятать (snap не найден или первый vertex
## уже поставлен).
func _update_brush_snap_indicator(target: Vector3) -> void:
	if target == Vector3.INF:
		if is_instance_valid(_brush_snap_indicator):
			_brush_snap_indicator.visible = false
		return
	if not is_instance_valid(_brush_snap_indicator):
		if _effects_root == null:
			_effects_root = get_tree().current_scene
		_brush_snap_indicator = AoeVisual.spawn_ground_ring(
			_effects_root, target, BRUSH_SNAP_RADIUS, 0.0, BRUSH_SNAP_COLOR,
		)
	_brush_snap_indicator.global_position = target + Vector3.UP * AIM_RING_HEIGHT
	_brush_snap_indicator.visible = true


## Pool-API: переиспользует mesh из [_brush_active_meshes] по индексу `slot`,
## создавая при необходимости. После вызова mesh виден, на нужной позиции,
## с нужной ориентацией и цветом. Caller инкрементит счётчик использованных.
func _acquire_preview_segment(slot: int, pos: Vector3, rot_y: float, color: Color) -> void:
	var mesh: MeshInstance3D = null
	if slot < _brush_active_meshes.size():
		mesh = _brush_active_meshes[slot]
		if not is_instance_valid(mesh):
			mesh = _make_preview_segment(pos, rot_y, color)
			_brush_active_meshes[slot] = mesh
			return
	else:
		mesh = _make_preview_segment(pos, rot_y, color)
		if mesh != null:
			_brush_active_meshes.append(mesh)
		return
	# Reuse: перепозиция + цвет, видимость on.
	mesh.global_position = pos + Vector3.UP * PREVIEW_MESH_CENTER_HEIGHT
	mesh.rotation.y = rot_y
	_apply_color_to_mesh(mesh, color)
	mesh.visible = true




## Спавнит committed-preview между двумя vertex'ами (от vertex_i к vertex_{i+1}).
## Постоянные до cancel/commit — игрок видит уже зафиксированную часть.
## Возвращает count спавненных сегментов (для total-cost подсчёта).
func _spawn_committed_preview_segments(a: Vector3, b: Vector3) -> int:
	var dir: Vector3 = b - a
	var length: float = dir.length()
	if length < BRUSH_MIN_SEGMENT_LENGTH:
		return 0
	# ceil + равномерный шаг — синхронно со spawn'ом в Camp.
	var count: int = int(ceil(length / _brush_segment_length))
	if count <= 0:
		return 0
	var step_length: float = length / float(count)
	var step: Vector3 = dir.normalized() * step_length
	var rot_y: float = atan2(-dir.z, dir.x)
	for j in range(count):
		var center: Vector3 = a + step * (float(j) + 0.5)
		var seg := _make_preview_segment(center, rot_y, brush_committed_color)
		if seg != null:
			_brush_committed_meshes.append(seg)
	return count


## Хватает ли ресурсов на total сегментов. Итерация по словарю стоимости —
## обычно один ресурс (wood), но может быть и больше.
func _can_afford_total(total: int) -> bool:
	if total <= 0:
		return true
	if not is_instance_valid(_camp):
		return true
	for type in _brush_cost_per_segment:
		var per: int = int(_brush_cost_per_segment[type])
		if _camp.economy.get_resource(type) < per * total:
			return false
	return true


## Перекраска уже созданного preview-меша. Используется для committed-сегментов:
## цвет blueprint'а меняется на красный при недостатке ресурсов синхронно с
## активной частью.
func _apply_color_to_mesh(mesh: MeshInstance3D, color: Color) -> void:
	if not is_instance_valid(mesh):
		return
	var mat := mesh.material_override as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = color
	mat.emission = Color(color.r, color.g, color.b, 1.0)


## Создаёт один preview-сегмент: BoxMesh с прозрачным материалом нужного
## цвета. Размер согласован с palisade_segment.tscn (2 × 1.5 × 0.3).
func _make_preview_segment(pos: Vector3, rot_y: float, color: Color) -> MeshInstance3D:
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	if _effects_root == null:
		return null
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(_brush_segment_length, 1.5, 0.3)
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 0.4
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_effects_root.add_child(mesh)
	mesh.global_position = pos + Vector3.UP * PREVIEW_MESH_CENTER_HEIGHT
	mesh.rotation.y = rot_y
	return mesh


## ПКМ — построить ломаную. К существующим vertex'ам добавляется текущая
## позиция курсора как последняя точка (если курсор дальше MIN от last).
## Атомарный try_build_palisade_line — либо всё, либо ничего.
##
## **После успешного commit'а brush-режим НЕ выходит** — игрок может тут
## же кликать ЛКМ и начать новую цепочку (возможно snap'нувшись к только
## что построенной). Это паттерн «continuous build mode»: вошёл один раз
## через журнал, строишь сколько хочешь, Esc для выхода. Реализован через
## [_reset_brush_for_next_chain] вместо [_finish_brush] — категория Hand'а,
## visual-zone, brush_building остаются. Если игрок нажал ПКМ без vertex'ов
## или с одним — silent no-op (без выхода): иначе случайный ПКМ ломал бы
## flow «строй продолжение».
func _commit_brush() -> void:
	if not is_instance_valid(_hand) or not is_instance_valid(_camp):
		_finish_brush()
		return
	# Добавляем cursor как последний vertex (если он валиден и достаточно
	# далеко от last). Это даёт игроку «закрытие» ломаной одним ПКМ'ом без
	# лишнего ЛКМ-клика.
	var cursor: Vector3 = _hand.cursor_world_position()
	cursor.y -= _hand.hand_height
	var anchor: Vector3 = _camp.build_zone_center()
	if anchor == Vector3.INF:
		anchor = Vector3.ZERO
	cursor.y = anchor.y
	var final_vertices: Array[Vector3] = _brush_vertices.duplicate()
	if not final_vertices.is_empty():
		var last: Vector3 = final_vertices[-1]
		if (last - cursor).length() >= BRUSH_MIN_SEGMENT_LENGTH:
			final_vertices.append(cursor)
	if final_vertices.size() < 2:
		# ПКМ без достаточного количества vertex'ов — silent (НЕ выходим из
		# режима). Игрок мог случайно ткнуть ПКМ; режим должен пережить это.
		if debug_log and LogConfig.master_enabled:
			print("[Hand:BuildAim:Brush] ПКМ no-op — нужно ≥2 vertex'а")
		return
	var result: Dictionary = _camp.try_build_palisade_line(final_vertices)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BuildAim:Brush] commit → %s/%s/segments=%d" % [
			"success" if result.get("success", false) else "fail",
			str(result.get("reason", "")),
			int(result.get("segments_built", 0)),
		])
	# НЕ выходим из brush'а — игрок может сразу начать следующую цепочку.
	_reset_brush_for_next_chain()


## Сброс vertex-state'а для новой цепочки без выхода из brush-режима.
## Очищает vertex-array, committed/active-preview-меши, счётчик сегментов.
## Не трогает: _brush_mode, _brush_building, _brush_segment_length, Hand-
## category, build-zone-индикатор — всё это валидно для следующей цепочки.
func _reset_brush_for_next_chain() -> void:
	_brush_vertices.clear()
	_brush_committed_segments_count = 0
	for m in _brush_committed_meshes:
		if is_instance_valid(m):
			m.queue_free()
	_brush_committed_meshes.clear()
	# Active-preview меши не освобождаем — переиспользуются по pool-API на
	# следующем _update_brush_active_preview (visibility off + reset).
	for m in _brush_active_meshes:
		if is_instance_valid(m):
			m.visible = false


## Cleanup и возврат категории. Зовётся ТОЛЬКО из cancel_aim (Esc) —
## _commit_brush'а теперь сюда не зовёт, а уходит в [_reset_brush_for_next_chain]
## оставляя brush-режим живым.
func _finish_brush() -> void:
	_brush_mode = false
	_brush_building = &""
	_brush_vertices.clear()
	_brush_committed_segments_count = 0
	for m in _brush_committed_meshes:
		if is_instance_valid(m):
			m.queue_free()
	_brush_committed_meshes.clear()
	for m in _brush_active_meshes:
		if is_instance_valid(m):
			m.queue_free()
	_brush_active_meshes.clear()
	if is_instance_valid(_brush_snap_indicator):
		_brush_snap_indicator.queue_free()
	_brush_snap_indicator = null
	_clear_indicator()
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.pop_category()


## Меняет albedo + emission материала кольца — синхронно с aim_indicator
## (создаётся через AoeVisual.spawn_ground_ring, мы знаем что material_override
## это StandardMaterial3D).
func _set_ring_color(ring: MeshInstance3D, color: Color) -> void:
	if ring == null:
		return
	var mat := ring.material_override as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = color
	mat.emission = Color(color.r, color.g, color.b, 1.0)


func _commit_aim() -> void:
	if _active_building == &"":
		return
	if not is_instance_valid(_camp):
		_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	if not is_instance_valid(_camp):
		push_warning("[Hand:BuildAim] _camp не резолвится — действие не оформлено")
		_finish_aim()
		return
	var ground: Vector3 = _hand.cursor_world_position()
	ground.y -= _hand.hand_height
	# Гейт: ПКМ вне build_zone — игнор, aim остаётся (игрок не теряет
	# контекст).
	if not _camp.is_in_build_zone(ground):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:BuildAim] ПКМ вне build_zone — игнор")
		return
	# Обычная постройка с нуля.
	var result: Dictionary = _camp.try_build(_active_building, {"position": ground})
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BuildAim] commit %s @ (%.1f, %.1f, %.1f) → %s/%s" % [
			_active_building, ground.x, ground.y, ground.z,
			"success" if result.get("success", false) else "fail",
			str(result.get("reason", "")),
		])
	_finish_aim()


func _finish_aim() -> void:
	_clear_indicator()
	if is_instance_valid(_direction_arrow):
		_direction_arrow.queue_free()
	_direction_arrow = null
	_direction_origin = Vector3.INF
	_direction_aim_mode = ""
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.pop_category()
	_active_building = &""
	_aim_radius = 0.0


func _spawn_indicator() -> void:
	_clear_indicator()
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	# Lazy-resolve Camp: HandBuildAim._ready может вызваться раньше Camp._ready
	# (порядок дерева bottom-up; Hand стоит выше Camp в main.tscn). Первый
	# aim-старт пытался читать null _camp и пропускал zone-индикатор; теперь
	# при необходимости резолвим перед спавном.
	if not is_instance_valid(_camp):
		_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	# Большой круг зоны строительства вокруг лагеря (статичный). Только
	# в DEPLOYED — иначе build_zone_center=INF, скип.
	if is_instance_valid(_camp):
		var zone_center: Vector3 = _camp.build_zone_center()
		if zone_center != Vector3.INF:
			_build_zone_indicator = AoeVisual.spawn_ground_ring(
				_effects_root, zone_center, _camp.build_radius, 0.0, build_zone_color,
			)
	# Preview-кольцо постройки под курсором (двигается в _process).
	if _aim_radius > 0.0:
		_aim_indicator = AoeVisual.spawn_ground_ring(
			_effects_root,
			_hand.cursor_world_position() - Vector3.UP * _hand.hand_height,
			_aim_radius,
			0.0,
			aim_ring_color,
		)


func _clear_indicator() -> void:
	if is_instance_valid(_aim_indicator):
		_aim_indicator.queue_free()
	_aim_indicator = null
	if is_instance_valid(_build_zone_indicator):
		_build_zone_indicator.queue_free()
	_build_zone_indicator = null
