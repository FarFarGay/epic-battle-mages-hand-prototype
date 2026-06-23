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
	_update_grid()  # сетка пола — только для труб/бура (нефте-решётка)
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
	# Силуэт следует за курсором. ЛКМ — поставить (sticky, ставим следующую). Поворот —
	# клик средней кнопки (см. _input). Нефте-постройки (трубы И бур) притягивают порты
	# к ЕДИНОЙ решётке (якорь — коллектор) → концы всегда совпадают; прочее — по стенам.
	var is_pipe: bool = _data.has("pipe_kind")
	var is_oil: bool = is_pipe or _building == RoomBuildings.OIL_DRILL
	var place: Vector3
	if is_oil:
		place = _snap_oil_grid(ground)
		# _snapped = порт примагниченной постройки совпал с портом существующего хоста
		# (коллектор/бур/труба). Для труб это ГЕЙТ (в воздух нельзя), буру — лишь подсветка.
		_snapped = _touches_host(_oil_ports_world(place, _rot_y))
	else:
		place = _snap_center(ground)
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


## Ставит RoomBuildSite на точке pos с текущим поворотом. Площадку строят рабочие
## командой «Идти сюда» (area-клик по ней → BUILD).
func _commit(pos: Vector3) -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
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
	var c := get_tree().get_first_node_in_group(OilCollector.GROUP)
	return (c as Node3D).global_position if c is Node3D else Vector3.ZERO


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
## труб (в воздух нельзя) и подсветки силуэта. Допуск — [OilCollector.PORT_TOL].
func _touches_host(ports: Array) -> bool:
	var tol2: float = OilCollector.PORT_TOL * OilCollector.PORT_TOL
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


## Сетка пола для нефте-построек (труба/бур): полупрозрачные клетки шага oil_grid,
## фаза — центр коллектора (та же решётка, что у снапа). Для прочих зданий скрыта.
func _update_grid() -> void:
	var is_oil: bool = _data.has("pipe_kind") or _building == RoomBuildings.OIL_DRILL
	if not is_oil:
		_clear_grid()
		return
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	var anchor: Vector3 = _oil_anchor()
	if not is_instance_valid(_grid):
		_grid = MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(80.0, 80.0)
		_grid.mesh = pm
		_grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = load("res://shaders/build_grid.gdshader")
		mat.set_shader_parameter(&"cell", oil_grid)
		_grid.material_override = mat
		_effects_root.add_child(_grid)
	var m := _grid.material_override as ShaderMaterial
	if m != null:
		m.set_shader_parameter(&"grid_anchor", Vector2(anchor.x, anchor.z))
	_grid.global_position = Vector3(anchor.x, 0.06, anchor.z)  # поверх травы


func _clear_grid() -> void:
	if is_instance_valid(_grid):
		_grid.queue_free()
	_grid = null


## Снести ближайшую трубу к точке курсора (ПКМ). Радиус — чуть меньше клетки, чтобы
## целить однозначно. Связность сети пересчитает OilCollector следующим тиком.
func _delete_pipe_under_cursor() -> void:
	var g: Vector3 = _hand.cursor_world_position()
	g.y -= _hand.hand_height
	var best: Node3D = null
	var best_d: float = (oil_grid * 0.7) * (oil_grid * 0.7)
	for n in get_tree().get_nodes_in_group(PipeSegment.GROUP):
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		var node := n as Node3D
		var dx: float = node.global_position.x - g.x
		var dz: float = node.global_position.z - g.z
		var d: float = dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best = node
	if best != null:
		AoeVisual.spawn_dust(get_tree().current_scene, best.global_position)
		best.queue_free()
		if debug_log and LogConfig.master_enabled:
			print("[Hand:PlaceAim] труба снесена (ПКМ)")


func _finish() -> void:
	_aiming = false
	_clear_ghost()
	_clear_grid()
	_set_build_zones_visible(false)  # спрятать зоны-индикаторы (вне режима стройки)
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.pop_category()


## Показать/спрятать наземные зоны-индикаторы стройки (группа build_zone_indicator).
## Сейчас это кольцо зоны бура ([OilRig]); видно только пока активен режим стройки.
func _set_build_zones_visible(v: bool) -> void:
	for n in get_tree().get_nodes_in_group(&"build_zone_indicator"):
		if n is Node3D:
			(n as Node3D).visible = v
