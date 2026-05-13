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
## Категория Hand'а до старта aim'а — на завершении возвращаем.
var _pre_aim_category: int = Hand.Category.PHYSICAL
var _aim_indicator: MeshInstance3D = null
## Большой круг зоны строительства вокруг центра лагеря — видим только в
## активном aim'е. Не двигается (camp.build_zone_center статичен в DEPLOYED).
var _build_zone_indicator: MeshInstance3D = null
## Если не null — мы в режиме relocate существующего колокола. _commit_aim
## вместо try_build сдвигает позицию этого инстанса. На finish — колокол
## возвращается на исходное место (отмена) или остаётся где переставили.
var _relocating_bell: WatchBell = null
## Сентинель building_id для режима relocate. Не из CAMP_BUILDING_CATALOG.
const RELOCATE_SENTINEL: StringName = &"<relocate>"
## Радиус «захвата» колокола от точки курсора. ЛКМ в пределах этого
## радиуса от любого колокола → start_relocate. Совпадает с
## [Hand.PICKUP_HIGHLIGHT_RADIUS] — игрок видит подсветку, видит и точку
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
## для preview-счётчика (через лог) и для info-feed (если добавим UI).
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
## при спавне committed-preview). Используется для total-cost label'а —
## считать длины committed-пар каждый кадр было бы лишним.
var _brush_committed_segments_count: int = 0
## Floating Label3D с подсказкой «N сегментов · M wood». Спавнится в
## start_brush, обновляется каждый кадр в _update_brush_active_preview,
## удаляется в _finish_brush.
var _brush_cost_label: Label3D = null
## Анти-spam: жёсткий лимит вершин в одной ломаной. 20 = ~38 сегментов × 2м =
## линия длиной 76м, перекрывает разумную «оборонную стену».
const BRUSH_MAX_VERTICES: int = 20
## Минимальная длина отрезка для постройки сегмента. Короче — игнорируется.
const BRUSH_MIN_SEGMENT_LENGTH: float = 0.5


func _ready() -> void:
	_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp


func setup(hand: Hand) -> void:
	_hand = hand


## Hand.physical вызывает в обработке ЛКМ-press (ACTION_GRAB). Если в радиусе
## [PICKUP_RADIUS] от курсора есть колокол — переходим в relocate-mode, иначе
## возвращаем false (hand_physical продолжает обычное grab/slam).
func try_pickup_at_cursor() -> bool:
	if not is_instance_valid(_hand) or _hand.is_holding():
		return false
	if is_aiming_any():
		return false  # уже что-то строим/двигаем, лишний pickup игнорируем
	var cursor: Vector3 = _hand.cursor_world_position()
	cursor.y -= _hand.hand_height
	var r_sq: float = PICKUP_RADIUS * PICKUP_RADIUS
	for n in get_tree().get_nodes_in_group(WatchBell.WATCH_BELL_GROUP):
		if not is_instance_valid(n):
			continue
		var bell := n as WatchBell
		if bell == null:
			continue
		var dx: float = bell.global_position.x - cursor.x
		var dz: float = bell.global_position.z - cursor.z
		if dx * dx + dz * dz <= r_sq:
			start_relocate(bell)
			return true
	return false


## Запуск relocate-mode для конкретного колокола. Колокол прячется и
## отключается (set_carried(true)), под курсором появляется preview-кольцо
## его alarm-зоны. ПКМ в build_zone — переставить, Esc — отмена (колокол
## возвращается на исходное место).
func start_relocate(bell: WatchBell) -> void:
	if bell == null:
		return
	if _active_building != &"":
		cancel_aim()
	if not is_instance_valid(_hand):
		push_warning("[Hand:BuildAim] start_relocate — _hand не задан")
		return
	if not is_instance_valid(_camp):
		_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	_relocating_bell = bell
	_active_building = RELOCATE_SENTINEL
	_aim_radius = bell.alarm_radius
	_pre_aim_category = _hand.active_category
	_hand.set_active_category(Hand.Category.BUILD_AIM)
	bell.set_carried(true)
	_spawn_indicator()
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BuildAim] relocate-старт %s @ (%.1f, %.1f)" % [
			bell.name, bell.global_position.x, bell.global_position.z,
		])


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
	_pre_aim_category = _hand.active_category
	_hand.set_active_category(Hand.Category.BUILD_AIM)
	_spawn_build_zone_only_indicator()
	_spawn_brush_cost_label()
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
func start_aim(building_id: StringName) -> void:
	if not is_instance_valid(_hand):
		push_warning("[Hand:BuildAim] start_aim — _hand не задан")
		return
	if _active_building != &"":
		cancel_aim()
	_active_building = building_id
	# Берём радиус из catalog'а (если есть). Для WatchBell его пишем как
	# alarm_radius — отдельное поле в catalog'е, не из инстанса постройки
	# (тот ещё не создан). Дефолт 0 — без preview-кольца.
	var data: Dictionary = Camp.CAMP_BUILDING_CATALOG.get(building_id, {})
	_aim_radius = float(data.get("aim_radius", 0.0))
	_pre_aim_category = _hand.active_category
	_hand.set_active_category(Hand.Category.BUILD_AIM)
	_spawn_indicator()
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BuildAim] aim старт для %s, radius=%.1f, prev_category=%s" % [
			building_id, _aim_radius, Hand.Category.keys()[_pre_aim_category],
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
	# Hover-подсветка обрабатывается в Hand._update_pickup_highlight через
	# общую группу PICKUP_HIGHLIGHT_GROUP — здесь только aim-индикатор.
	if _active_building == &"":
		return
	var ground: Vector3 = _hand.cursor_world_position()
	ground.y -= _hand.hand_height
	if is_instance_valid(_aim_indicator):
		_aim_indicator.global_position = ground + Vector3.UP * 0.05
		# Перекрашиваем preview-кольцо в invalid когда курсор вне зоны строй-
		# ки — игрок видит «здесь ПКМ не сработает».
		var in_zone: bool = is_instance_valid(_camp) and _camp.is_in_build_zone(ground)
		_set_ring_color(_aim_indicator, aim_ring_color if in_zone else aim_ring_color_invalid)
	if Input.is_action_just_pressed(ACTION_AIM_CANCEL):
		cancel_aim()
		return
	if Input.is_action_just_pressed(ACTION_AIM_COMMIT) and not _hand.is_pointer_over_ui():
		_commit_aim()


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
	if _brush_vertices.is_empty():
		_brush_vertices.append(pt)
		if debug_log and LogConfig.master_enabled:
			print("[Hand:BuildAim:Brush] vertex 1 @ (%.1f, %.1f)" % [pt.x, pt.z])
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
## Каждый кадр уничтожает старые active-preview'ы и спавнит новые. Дёшево
## при <10 сегментах в активной части.
func _update_brush_active_preview(cursor: Vector3) -> void:
	# Очистка старых.
	for m in _brush_active_meshes:
		if is_instance_valid(m):
			m.queue_free()
	_brush_active_meshes.clear()
	if _brush_vertices.is_empty():
		# Ещё не поставили первый vertex — показываем «фантомный сегмент»
		# в точке курсора (горизонтально, дефолтная ориентация). Подсказка:
		# «ЛКМ поставит первую точку».
		var seg := _make_preview_segment(cursor, 0.0, brush_preview_color_valid)
		if seg != null:
			_brush_active_meshes.append(seg)
		return
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
	var at_max: bool = _brush_vertices.size() >= BRUSH_MAX_VERTICES
	var color: Color
	if at_max:
		color = brush_preview_color_max
	elif all_in_zone:
		color = brush_preview_color_valid
	else:
		color = brush_preview_color_invalid
	for j in range(count):
		var center: Vector3 = last + step * (float(j) + 0.5)
		var seg := _make_preview_segment(center, rot_y, color)
		if seg != null:
			_brush_active_meshes.append(seg)
	# Total-cost label рядом с курсором. count = active-сегменты под
	# курсором (если активная часть валидна), плюс committed уже зафиксированы.
	_update_brush_cost_label(cursor, count, all_in_zone, at_max)


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


## Спавнит Label3D с подсказкой total-cost. Зовётся в start_brush.
## Позиция обновляется каждый кадр в _update_brush_cost_label.
func _spawn_brush_cost_label() -> void:
	if _brush_cost_label != null and is_instance_valid(_brush_cost_label):
		_brush_cost_label.queue_free()
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	_brush_cost_label = Label3D.new()
	_brush_cost_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_brush_cost_label.no_depth_test = true
	_brush_cost_label.fixed_size = true
	_brush_cost_label.pixel_size = 0.005
	_brush_cost_label.text = "0 сегментов"
	_brush_cost_label.modulate = brush_preview_color_valid
	_effects_root.add_child(_brush_cost_label)


## Обновляет текст и цвет cost-label'а. Total = committed + active. Cost =
## total × cost_per_segment. Цвет:
##   - green: валидно и хватает ресурсов
##   - red: вне build_zone ИЛИ не хватает ресурсов
##   - yellow: достигнут лимит вершин (max-feedback)
func _update_brush_cost_label(cursor: Vector3, active_count: int, all_in_zone: bool, at_max: bool) -> void:
	if _brush_cost_label == null or not is_instance_valid(_brush_cost_label):
		return
	# Label над курсором, чтобы не закрывал preview-сегменты под ним.
	_brush_cost_label.global_position = cursor + Vector3.UP * 1.8
	var total: int = _brush_committed_segments_count + active_count
	# Cost подсчитываем по словарю (обычно один ресурс — wood, но может быть и больше).
	var cost_lines: Array[String] = []
	var can_afford_total: bool = true
	for type in _brush_cost_per_segment:
		var per: int = int(_brush_cost_per_segment[type])
		var total_cost: int = per * total
		cost_lines.append("%d %s" % [total_cost, _resource_short_name(type)])
		if is_instance_valid(_camp) and _camp.get_resource(type) < total_cost:
			can_afford_total = false
	var cost_str: String = " · ".join(cost_lines) if not cost_lines.is_empty() else ""
	var suffix: String = ""
	if at_max:
		suffix = " · лимит"
	_brush_cost_label.text = "%d сегмент%s%s%s" % [
		total,
		_plural_segments(total),
		(" · " + cost_str) if not cost_str.is_empty() else "",
		suffix,
	]
	if at_max:
		_brush_cost_label.modulate = brush_preview_color_max
	elif not all_in_zone or not can_afford_total:
		_brush_cost_label.modulate = brush_preview_color_invalid
	else:
		_brush_cost_label.modulate = brush_preview_color_valid


## Короткое имя ресурса для UI. Не таскаем словарь RESOURCE_DISPLAY из
## JournalPanel — здесь нужны только базовые.
func _resource_short_name(type: int) -> String:
	match type:
		ResourcePile.ResourceType.WOOD: return "wood"
		ResourcePile.ResourceType.STONE: return "stone"
		ResourcePile.ResourceType.IRON: return "iron"
		ResourcePile.ResourceType.FOOD: return "food"
		ResourcePile.ResourceType.PAGE: return "page"
		_: return "?"


## Русское склонение «сегмент / сегмента / сегментов». Без отдельной библиотеки.
func _plural_segments(n: int) -> String:
	var mod10: int = n % 10
	var mod100: int = n % 100
	if mod10 == 1 and mod100 != 11:
		return ""
	if mod10 >= 2 and mod10 <= 4 and (mod100 < 10 or mod100 >= 20):
		return "а"
	return "ов"


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
	mesh.global_position = pos + Vector3.UP * 0.75  # центр меша на 0.75м — над землёй
	mesh.rotation.y = rot_y
	return mesh


## ПКМ — построить ломаную. К существующим vertex'ам добавляется текущая
## позиция курсора как последняя точка (если курсор дальше MIN от last).
## Атомарный try_build_palisade_line — либо всё, либо ничего.
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
		if debug_log and LogConfig.master_enabled:
			print("[Hand:BuildAim:Brush] недостаточно vertex'ов для постройки (нужно ≥2)")
		_finish_brush()
		return
	var result: Dictionary = _camp.try_build_palisade_line(final_vertices)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BuildAim:Brush] commit → %s/%s/segments=%d" % [
			"success" if result.get("success", false) else "fail",
			str(result.get("reason", "")),
			int(result.get("segments_built", 0)),
		])
	_finish_brush()


## Cleanup и возврат категории. Зовётся и из _commit_brush, и из cancel_aim.
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
	if is_instance_valid(_brush_cost_label):
		_brush_cost_label.queue_free()
	_brush_cost_label = null
	_clear_indicator()
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.set_active_category(_pre_aim_category)


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
	# Ветка relocate: сдвигаем существующий колокол вместо новой постройки.
	if _relocating_bell != null:
		if is_instance_valid(_relocating_bell):
			_relocating_bell.global_position = Vector3(ground.x, _relocating_bell.global_position.y, ground.z)
			_relocating_bell.set_carried(false)
			if debug_log and LogConfig.master_enabled:
				print("[Hand:BuildAim] relocate-commit %s → (%.1f, %.1f)" % [
					_relocating_bell.name, ground.x, ground.z,
				])
		_relocating_bell = null  # set_carried уже снят, в _finish_aim не трогаем повторно
		_finish_aim()
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
	# Если был relocate, не commit'нутый (cancel через Esc) — возвращаем
	# колокол на место (set_carried(false) восстанавливает visible/alarm).
	# Если commit прошёл — _relocating_bell уже null'ится в _commit_aim.
	if _relocating_bell != null:
		if is_instance_valid(_relocating_bell):
			_relocating_bell.set_carried(false)
		_relocating_bell = null
	_clear_indicator()
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.set_active_category(_pre_aim_category)
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
