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
	return _active_building != &""


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
	if _active_building == &"":
		return
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BuildAim] aim отменён")
	_finish_aim()


func _process(_delta: float) -> void:
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
