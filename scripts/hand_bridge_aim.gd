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
var _preview: MeshInstance3D = null


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
		# Ждём первый клик — начало пролёта.
		if Input.is_action_just_pressed(ACTION_COMMIT) and not _hand.is_pointer_over_ui():
			_start = ground
			_spawn_preview()
		return
	# Первая точка есть — тянем превью к курсору, ждём второй клик.
	_update_preview(ground)
	if Input.is_action_just_pressed(ACTION_COMMIT) and not _hand.is_pointer_over_ui():
		_commit(ground)


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
	var site := Node3D.new()
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


func _spawn_preview() -> void:
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	if _effects_root == null:
		return
	if is_instance_valid(_preview):
		_preview.queue_free()
	_preview = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 0.12, SPAN_HALF_Z * 2.0)  # X масштабируем по длине
	_preview.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ghost_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(ghost_color.r, ghost_color.g, ghost_color.b, 1.0)
	mat.emission_energy_multiplier = 0.5
	_preview.material_override = mat
	_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_effects_root.add_child(_preview)


## Тянет превью-настил от _start к курсору (центр, длина, ориентация).
func _update_preview(cursor: Vector3) -> void:
	if not is_instance_valid(_preview):
		return
	var to := Vector3(cursor.x - _start.x, 0.0, cursor.z - _start.z)
	var d: float = to.length()
	if d < 0.05:
		_preview.visible = false
		return
	_preview.visible = true
	var mid: Vector3 = _start + to * 0.5 + Vector3.UP * 0.14
	_preview.global_position = mid
	var dir: Vector3 = to / d
	_preview.rotation.y = atan2(-dir.z, dir.x)
	_preview.scale = Vector3(d, 1.0, 1.0)


func _finish() -> void:
	_aiming = false
	_start = Vector3.INF
	if is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.pop_category()
