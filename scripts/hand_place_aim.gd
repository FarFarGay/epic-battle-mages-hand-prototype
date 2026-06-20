class_name HandPlaceAim
extends Node
## Координатор СВОБОДНОГО размещения зданий рукой — ОДНА модель для всех точечных
## построек комнатного режима ([RoomBuildings]). Рука тащит силуэт за курсором;
## ЛКМ-зажим фиксирует точку, драг = поворот, отпускание ставит [RoomBuildSite].
## Без грида/колец/секторов. Sticky: после установки aim остаётся — ставь ещё
## (стены кирпичиками). Esc / повторный вызов того же id — выход.
##
## По образцу [HandBridgeAim]: на время aim'а Hand-категория = BUILD_AIM (остальной
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
## Радиус магнита (м): ближайшая snap-точка силуэта (центр/край) притягивается к
## ближайшей snap-точке соседней стены в пределах этого радиуса. 0 → магнит выкл.
@export var snap_radius: float = 1.6
@export var debug_log: bool = true
@export var effects_root_path: NodePath

var _hand: Hand
var _effects_root: Node = null
var _aiming: bool = false
var _building: StringName = &""
var _data: Dictionary = {}
var _footprint: Vector3 = Vector3(2.0, 1.5, 0.3)
var _ghost: MeshInstance3D = null
## Текущий поворот силуэта (рад). Крутится кликом средней кнопки мыши, сохраняется
## между установками (sticky) — следующая стена встаёт под тем же углом.
var _rot_y: float = 0.0
## Сработал ли магнит в этом кадре (для подсветки силуэта). Ставится в _snap_center.
var _snapped: bool = false


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
	# Силуэт следует за курсором, магнитясь к соседним стенам. ЛКМ — поставить
	# (sticky, ставим следующую). Поворот — клик средней кнопки (см. _input).
	var place: Vector3 = _snap_center(ground)
	_update_ghost(place)
	if Input.is_action_just_pressed(ACTION_COMMIT) and not _hand.is_pointer_over_ui():
		_commit(place)


## Поворот силуэта кликом СРЕДНЕЙ кнопки мыши (шаг rotate_step_deg). Ловим в _input
## (до _unhandled_input камеры) и ГАСИМ событие — иначе CameraRig включил бы орбиту
## на зажатие колеса (camera_rig.gd MOUSE_BUTTON_MIDDLE). Только пока активен aim.
func _input(event: InputEvent) -> void:
	if not _aiming:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_MIDDLE:
		if (event as InputEventMouseButton).pressed:
			_rot_y = wrapf(_rot_y + deg_to_rad(rotate_step_deg), -PI, PI)
		get_viewport().set_input_as_handled()  # и press, и release — камера не орбитит


## Ставит RoomBuildSite на точке pos с текущим поворотом. Площадку строят рабочие
## командой «Идти сюда» (area-клик по ней → BUILD).
func _commit(pos: Vector3) -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
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
	_ghost.global_position = pos + Vector3.UP * (_footprint.y * 0.5)
	_ghost.rotation.y = _rot_y
	# Подсветка «прилипло»: зелёный при сработавшем магните, иначе цвет каталога.
	var mat := _ghost.material_override as StandardMaterial3D
	if mat != null:
		var c: Color = ghost_color_snap if _snapped else Color(_data.get("ghost_color", ghost_color_valid))
		mat.albedo_color = c
		mat.emission = Color(c.r, c.g, c.b, 1.0)


func _spawn_ghost() -> void:
	_clear_ghost()
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	_ghost = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = _footprint
	_ghost.mesh = box
	var color: Color = _data.get("ghost_color", ghost_color_valid)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 0.4
	_ghost.material_override = mat
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _effects_root != null:
		_effects_root.add_child(_ghost)


func _clear_ghost() -> void:
	if is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null


func _finish() -> void:
	_aiming = false
	_clear_ghost()
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.pop_category()
