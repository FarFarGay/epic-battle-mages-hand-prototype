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
## Цвет силуэта-ОШИБКИ: труба не пристыкована к порту (ставить в воздух нельзя).
@export var ghost_color_invalid: Color = Color(1.0, 0.35, 0.3, 0.55)
## Радиус магнита (м): ближайшая snap-точка силуэта (центр/край) притягивается к
## ближайшей snap-точке соседней стены в пределах этого радиуса. 0 → магнит выкл.
@export var snap_radius: float = 1.6
## Радиус примагничивания КОНЦОВ труб к портам (больше стенового — концы стыковать
## должно быть легко). Используется в _snap_pipe.
@export var pipe_snap_radius: float = 2.8
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
	_set_build_zones_visible(true)  # показать зоны-индикаторы (напр. кольцо бура)
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
	# Трубы снапятся ПО КОНЦАМ (порты) к трубам/коллектору/буру; прочее — по стенам.
	var is_pipe: bool = _data.has("pipe_kind")
	var place: Vector3 = _snap_pipe(ground) if is_pipe else _snap_center(ground)
	_update_ghost(place)
	if Input.is_action_just_pressed(ACTION_COMMIT) and not _hand.is_pointer_over_ui():
		# Трубу в воздух нельзя — только встык к порту (бур/коллектор/другая труба).
		if is_pipe and not _snapped:
			if debug_log and LogConfig.master_enabled:
				print("[Hand:PlaceAim] труба не у порта — стыкуй к буру/коллектору/трубе")
			return
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
	# Мгновенная постройка (трубы): ставим готовую сцену сразу, без стройплощадки и
	# рабочих — длинную трассу не хочется хаулить. Снап-цель помечаем как у стен.
	if _data.get("instant", false):
		var ps := load(String(_data.get("scene", ""))) as PackedScene
		if ps != null:
			var b := ps.instantiate()
			scene.add_child(b)
			if b is Node3D:
				var bn := b as Node3D
				bn.global_position = pos
				bn.rotation.y = _rot_y
				if _data.get("snap_target", false):
					bn.add_to_group(WALL_SNAP_GROUP)
					bn.set_meta(&"wall_half_len", _footprint.x * 0.5)
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


## Снап трубы ПО КОНЦАМ: ближайший конец ставимого тайла притягивается к ближайшему
## порту существующего хоста (труба/коллектор/бур, группа pipe_port_host) в пределах
## snap_radius. Концы стыкуются как настоящие трубы — встык к выступу коллектора/бура.
func _snap_pipe(raw: Vector3) -> Vector3:
	_snapped = false
	if pipe_snap_radius <= 0.0:
		return raw
	var kind: int = int(_data.get("pipe_kind", 0))
	var bz := Basis(Vector3.UP, _rot_y)
	var my_ports: Array = []
	for lp in PipeSegment.local_ports(kind):
		my_ports.append(raw + bz * (lp as Vector3))
	var best_d: float = pipe_snap_radius
	var best_delta: Vector3 = Vector3.ZERO
	for host in get_tree().get_nodes_in_group(PipeSegment.PORT_HOST_GROUP):
		if not is_instance_valid(host) or not host.has_method(&"pipe_ports"):
			continue
		for hp in host.call(&"pipe_ports"):
			for mp in my_ports:
				var dx: float = (mp as Vector3).x - (hp as Vector3).x
				var dz: float = (mp as Vector3).z - (hp as Vector3).z
				var d: float = sqrt(dx * dx + dz * dz)
				if d < best_d:
					best_d = d
					best_delta = Vector3((hp as Vector3).x - (mp as Vector3).x, 0.0, (hp as Vector3).z - (mp as Vector3).z)
	if best_delta != Vector3.ZERO:
		_snapped = true
	return raw + best_delta


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
	var y_off: float = 0.0 if _data.has("pipe_kind") else _footprint.y * 0.5
	_ghost.global_position = pos + Vector3.UP * y_off
	_ghost.rotation.y = _rot_y  # поворот силуэта — игрок видит ориентацию (угол/крест)
	if _ghost_mat != null:
		var c: Color
		if _data.has("pipe_kind") and not _snapped:
			c = ghost_color_invalid  # труба не у порта — красный «нельзя»
		elif _snapped:
			c = ghost_color_snap
		else:
			c = Color(_data.get("ghost_color", ghost_color_valid))
		_ghost_mat.albedo_color = c
		_ghost_mat.emission = Color(c.r, c.g, c.b, 1.0)


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
	if _data.has("pipe_kind"):
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


func _clear_ghost() -> void:
	if is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null


func _finish() -> void:
	_aiming = false
	_clear_ghost()
	_set_build_zones_visible(false)  # спрятать зоны-индикаторы (вне режима стройки)
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.pop_category()


## Показать/спрятать наземные зоны-индикаторы стройки (группа build_zone_indicator).
## Сейчас это кольцо зоны бура ([OilRig]); видно только пока активен режим стройки.
func _set_build_zones_visible(v: bool) -> void:
	for n in get_tree().get_nodes_in_group(&"build_zone_indicator"):
		if n is Node3D:
			(n as Node3D).visible = v
