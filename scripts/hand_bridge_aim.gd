class_name HandBridgeAim
extends Node
## Координатор планирования МОСТА рукой — ДВА КЛИКА: первый ЛКМ ставит начало пролёта,
## второй ЛКМ — конец. Между ними тянется ghost-превью настила. По второму клику в
## мире создаётся BridgeSite (чертёж-стройплощадка), куда игрок отправляет отряд
## рабочих командой «Идти сюда» — они сами рубят/носят/строят.
##
## По образцу [HandSquadAim]: на время aim'а Hand-категория = BUILD_AIM (остальной
## ввод гасится). UI (gameplay_hud, кнопка «Строить мост») запускает start_aim();
## повторный вызов → cancel (toggle). Esc — отмена. НЕ завязан на Camp (комнатный режим).

const BRIDGE_SITE_SCRIPT := preload("res://scripts/bridge_site.gd")

const ACTION_COMMIT := &"hand_grab"   # ЛКМ — поставить точку
const ACTION_CANCEL := &"ui_cancel"   # Esc — отмена

## Минимальная длина пролёта — короче игнорируем (случайный второй клик у первого).
const MIN_SPAN: float = 2.0
## Метров настила на одну доску → во сколько брёвен обойдётся мост (длиннее — дороже).
const METERS_PER_PLANK: float = 1.0
const MIN_PLANKS: int = 3
const MAX_PLANKS: int = 24
## Полуширина настила по Z (ходимая ширина моста).
const SPAN_HALF_Z: float = 2.0

@export var ghost_color: Color = Color(0.55, 0.78, 0.95, 0.5)
@export var debug_log: bool = true
@export var effects_root_path: NodePath

var _hand: Hand
var _effects_root: Node = null
var _aiming: bool = false
## Начало пролёта (мир). INF = первый клик ещё не сделан.
var _start: Vector3 = Vector3.INF
## Пул силуэтов-досок превью (плитка): до первого клика — одна доска «в руке» в точке
## курсора; после — ряд досок от _start к курсору. Переиспользуются между кадрами.
var _plank_ghosts: Array[MeshInstance3D] = []


func _ready() -> void:
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene


func setup(hand: Hand) -> void:
	_hand = hand


func is_aiming_any() -> bool:
	return _aiming


## Toggle: активен → отмена; иначе — старт. UI зовёт кнопкой «Строить мост».
func toggle_aim() -> void:
	if _aiming:
		cancel_aim()
	else:
		start_aim()


func start_aim() -> void:
	if not is_instance_valid(_hand):
		push_warning("[Hand:BridgeAim] start_aim — _hand не задан")
		return
	if _aiming:
		return
	_aiming = true
	_start = Vector3.INF
	_hand.push_category(Hand.Category.BUILD_AIM)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BridgeAim] старт планирования моста")


func cancel_aim() -> void:
	if not _aiming:
		return
	_finish()
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BridgeAim] отмена")


func _process(_delta: float) -> void:
	if not _aiming:
		return
	var ground: Vector3 = _hand.cursor_world_position()
	ground.y -= _hand.hand_height
	if Input.is_action_just_pressed(ACTION_CANCEL):
		cancel_aim()
		return
	if _start == Vector3.INF:
		# До первого клика — силуэт ПЕРВОЙ доски «в руке» под курсором.
		_update_first_plank(ground)
		if Input.is_action_just_pressed(ACTION_COMMIT) and not _hand.is_pointer_over_ui():
			_start = ground
		return
	# Первая точка есть — тянем РЯД досок-силуэтов к курсору, ждём второй клик.
	_update_plank_row(_start, ground)
	if Input.is_action_just_pressed(ACTION_COMMIT) and not _hand.is_pointer_over_ui():
		_commit(ground)


## Число досок по длине пролёта — синхронно с BridgeSite.planks_needed в _create_bridge.
func _planks_for(dist: float) -> int:
	return clampi(int(round(dist / METERS_PER_PLANK)), MIN_PLANKS, MAX_PLANKS)


## Второй клик: если пролёт достаточной длины — создаём BridgeSite и выходим.
## Короткий — игнорируем (превью остаётся, игрок кликнет дальше).
func _commit(end: Vector3) -> void:
	var to := Vector3(end.x - _start.x, 0.0, end.z - _start.z)
	var dist: float = to.length()
	if dist < MIN_SPAN:
		if debug_log and LogConfig.master_enabled:
			print("[Hand:BridgeAim] пролёт слишком короткий (%.1f) — игнор" % dist)
		return
	_create_bridge(_start, end, dist)
	_finish()


## Создаёт BridgeSite на БЛИЖНЕМ к РАБОЧИМ конце пролёта (они строят — заходят с
## ближайшего к ним края), локальный +X направлен к ДАЛЬНЕМУ концу. Доски растут от
## ближнего конца к дальнему — рабочий стоит на доступном краю и строит «от себя»,
## а не упирается в середину пропасти. Длина = dist, число досок ∝ длине.
func _create_bridge(start: Vector3, end: Vector3, dist: float) -> void:
	# Ближний конец = тот, что ближе к рабочим (они строят). Опора — ближайший к
	# пролёту гном-рабочий; нет рабочих → fallback на башню → на start.
	var mid: Vector3 = (start + end) * 0.5
	var ref: Vector3 = _build_reference_point(mid)
	var near: Vector3 = start
	var far: Vector3 = end
	var d_start: float = Vector2(start.x - ref.x, start.z - ref.z).length()
	var d_end: float = Vector2(end.x - ref.x, end.z - ref.z).length()
	if d_end < d_start:
		near = end
		far = start
	var site := StaticBody3D.new()
	site.set_script(BRIDGE_SITE_SCRIPT)
	site.span_length = dist
	site.span_half_z = SPAN_HALF_Z
	site.planks_needed = clampi(int(round(dist / METERS_PER_PLANK)), MIN_PLANKS, MAX_PLANKS)
	var scene := get_tree().current_scene
	if scene == null:
		return
	scene.add_child(site)
	site.global_position = Vector3(near.x, near.y, near.z)
	# Локальный +X — к дальнему концу. look_at смотрит -Z на target, поэтому yaw напрямую.
	var dir := Vector3(far.x - near.x, 0.0, far.z - near.z).normalized()
	site.rotation.y = atan2(-dir.z, dir.x)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:BridgeAim] мост от (%.1f,%.1f) к (%.1f,%.1f), длина %.1f, досок %d" % [
			near.x, near.z, far.x, far.z, dist, site.planks_needed])


## Опора для выбора ближнего конца: позиция ближайшего к пролёту гнома-рабочего (кто
## будет строить). Нет рабочих → башня → сам центр пролёта. Спрятанные в башне рабочие
## стоят в точке башни — тогда ближний конец естественно со стороны башни.
func _build_reference_point(mid: Vector3) -> Vector3:
	var best: Vector3 = Vector3.INF
	var best_d: float = INF
	for s in get_tree().get_nodes_in_group(&"soldier"):
		if not is_instance_valid(s):
			continue
		if not (s.has_method(&"is_worker") and s.is_worker()):
			continue
		var p: Vector3 = (s as Node3D).global_position
		var d: float = Vector2(p.x - mid.x, p.z - mid.z).length()
		if d < best_d:
			best_d = d
			best = p
	if best != Vector3.INF:
		return best
	var tower := get_tree().get_first_node_in_group(&"tower")
	if tower != null:
		return (tower as Node3D).global_position
	return mid


## До первого клика: одна доска-силуэт «в руке» под курсором (первая деталь).
## Направление ещё не задано — кладём горизонтально, размером в одну доску.
func _update_first_plank(cursor: Vector3) -> void:
	_acquire_plank(0, cursor + Vector3.UP * 0.14, 0.0, METERS_PER_PLANK)
	_hide_planks_from(1)


## Тянет РЯД досок-силуэтов от _start к курсору: плитка из _planks_for(d) досок вдоль
## пролёта (последняя — у курсора, «с другой стороны»). Так игрок видит сам настил, а
## не абстрактную область.
func _update_plank_row(start: Vector3, cursor: Vector3) -> void:
	var to := Vector3(cursor.x - start.x, 0.0, cursor.z - start.z)
	var d: float = to.length()
	if d < 0.05:
		_hide_planks_from(0)
		return
	var count: int = _planks_for(d)
	var step: float = d / float(count)
	var dir: Vector3 = to / d
	var rot_y: float = atan2(-dir.z, dir.x)
	for i in range(count):
		var center: Vector3 = start + dir * (step * (float(i) + 0.5)) + Vector3.UP * 0.14
		_acquire_plank(i, center, rot_y, step)
	_hide_planks_from(count)


## Pool-API: переиспользует доску-силуэт по индексу slot (создавая при необходимости).
## После вызова доска видна, на месте, нужной длины/ориентации.
func _acquire_plank(slot: int, pos: Vector3, rot_y: float, length: float) -> void:
	var m: MeshInstance3D = null
	if slot < _plank_ghosts.size():
		m = _plank_ghosts[slot]
		if not is_instance_valid(m):
			m = _make_plank()
			_plank_ghosts[slot] = m
	else:
		m = _make_plank()
		_plank_ghosts.append(m)
	(m.mesh as BoxMesh).size = Vector3(length * 0.92, 0.12, SPAN_HALF_Z * 2.0)
	m.global_position = pos
	m.rotation.y = rot_y
	m.visible = true


func _make_plank() -> MeshInstance3D:
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	var m := MeshInstance3D.new()
	m.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ghost_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(ghost_color.r, ghost_color.g, ghost_color.b, 1.0)
	mat.emission_energy_multiplier = 0.5
	m.material_override = mat
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _effects_root != null:
		_effects_root.add_child(m)
	return m


## Прячет доски-силуэты с индекса from и дальше (лишние при укорачивании ряда).
func _hide_planks_from(from: int) -> void:
	for i in range(from, _plank_ghosts.size()):
		var m: MeshInstance3D = _plank_ghosts[i]
		if is_instance_valid(m):
			m.visible = false


func _finish() -> void:
	_aiming = false
	_start = Vector3.INF
	for m in _plank_ghosts:
		if is_instance_valid(m):
			m.queue_free()
	_plank_ghosts.clear()
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.pop_category()
