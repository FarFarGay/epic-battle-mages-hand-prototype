class_name HandPipeAim
extends Node
## Координатор прокладки ТРУБОПРОВОДА рукой — ДВА КЛИКА (бур → цистерна), по образцу
## [HandBridgeAim], но проще: труба соединяет ближайший [OilRig] с ближайшей
## [OilTank], и только ПОСЛЕ прокладки добыча идёт в цистерну (`rig.set_cistern`).
## Без трубы бур крутится, но нефть никуда не копится.
##
## v1: труба кладётся сразу на 2-м клике (визуальный пролёт-короб), без рабочей
## достройки — это «конструкторский акт рукой». Рабочую достройку трубы добавим позже.

const ACTION_COMMIT := &"hand_grab"   # ЛКМ — поставить точку
const ACTION_CANCEL := &"ui_cancel"   # Esc — отмена
const MIN_SPAN: float = 2.0

@export var pipe_color: Color = Color(0.42, 0.4, 0.36, 1.0)
@export var ghost_color: Color = Color(1.0, 0.7, 0.3, 0.5)
@export var pipe_thickness: float = 0.45
@export var pipe_y: float = 0.45
@export var debug_log: bool = true
@export var effects_root_path: NodePath

var _hand: Hand
var _effects_root: Node = null
var _aiming: bool = false
var _start: Vector3 = Vector3.INF
var _ghost: MeshInstance3D = null


func _ready() -> void:
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene


func setup(hand: Hand) -> void:
	_hand = hand


func is_aiming_any() -> bool:
	return _aiming


func toggle_aim() -> void:
	if _aiming:
		cancel_aim()
	else:
		start_aim()


func start_aim() -> void:
	if not is_instance_valid(_hand):
		push_warning("[Hand:PipeAim] start_aim — _hand не задан")
		return
	if _aiming:
		return
	_aiming = true
	_start = Vector3.INF
	_hand.push_category(Hand.Category.BUILD_AIM)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:PipeAim] старт прокладки трубы — кликни у бура, затем у цистерны")


func cancel_aim() -> void:
	if not _aiming:
		return
	_finish()


func _process(_delta: float) -> void:
	if not _aiming:
		return
	var ground: Vector3 = _hand.cursor_world_position()
	ground.y -= _hand.hand_height
	if Input.is_action_just_pressed(ACTION_CANCEL):
		cancel_aim()
		return
	if _start == Vector3.INF:
		_update_ghost(ground, ground)  # короткая «труба в руке» под курсором
		if Input.is_action_just_pressed(ACTION_COMMIT) and not _hand.is_pointer_over_ui():
			_start = ground
		return
	_update_ghost(_start, ground)
	if Input.is_action_just_pressed(ACTION_COMMIT) and not _hand.is_pointer_over_ui():
		_commit(ground)


## Второй клик: труба от _start к end. Соединяем ближайший бур с ближайшей цистерной.
func _commit(end: Vector3) -> void:
	var to := Vector3(end.x - _start.x, 0.0, end.z - _start.z)
	if to.length() < MIN_SPAN:
		return  # слишком коротко — ждём клик подальше
	var rig := _nearest_in_group(&"oil_rig", _start, end)
	var tank := _nearest_in_group(&"oil_tank", _start, end)
	if rig == null or tank == null:
		push_warning("[Hand:PipeAim] нужны и бур, и цистерна — труба не проложена")
		_finish()
		return
	_spawn_pipe(_start, end)
	if rig.has_method(&"set_cistern"):
		rig.call(&"set_cistern", tank)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:PipeAim] труба проложена: бур → цистерна, добыча пошла")
	_finish()


## Ближайший узел группы к ЛЮБОМУ из концов пролёта (порядок кликов не важен).
func _nearest_in_group(group: StringName, a: Vector3, b: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group(group):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var p: Vector3 = node.global_position
		var d: float = minf(Vector2(p.x - a.x, p.z - a.z).length_squared(),
				Vector2(p.x - b.x, p.z - b.z).length_squared())
		if d < best_d:
			best_d = d
			best = node
	return best


## Постоянная труба-короб от a к b (визуал магистрали).
func _spawn_pipe(a: Vector3, b: Vector3) -> void:
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	if _effects_root == null:
		return
	var m := MeshInstance3D.new()
	m.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = pipe_color
	mat.metallic = 0.4
	mat.roughness = 0.6
	m.material_override = mat
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_effects_root.add_child(m)
	_orient_segment(m, a, b, false)


## Силуэт-превью (один короб) от a к b. Лениво создаётся, живёт до _finish.
func _update_ghost(a: Vector3, b: Vector3) -> void:
	if not is_instance_valid(_ghost):
		_ghost = MeshInstance3D.new()
		_ghost.mesh = BoxMesh.new()
		var mat := StandardMaterial3D.new()
		mat.albedo_color = ghost_color
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.emission_enabled = true
		mat.emission = Color(ghost_color.r, ghost_color.g, ghost_color.b, 1.0)
		mat.emission_energy_multiplier = 0.5
		_ghost.material_override = mat
		_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _effects_root != null:
			_effects_root.add_child(_ghost)
	_orient_segment(_ghost, a, b, true)


## Тянет короб m вдоль a→b: длина = dist (мин thickness), локальный +X вдоль пролёта.
func _orient_segment(m: MeshInstance3D, a: Vector3, b: Vector3, _ghost_seg: bool) -> void:
	var to := Vector3(b.x - a.x, 0.0, b.z - a.z)
	var dist: float = maxf(to.length(), pipe_thickness)
	(m.mesh as BoxMesh).size = Vector3(dist, pipe_thickness, pipe_thickness)
	m.global_position = Vector3((a.x + b.x) * 0.5, pipe_y, (a.z + b.z) * 0.5)
	if to.length() > 0.001:
		var dir: Vector3 = to.normalized()
		m.rotation.y = atan2(-dir.z, dir.x)


func _finish() -> void:
	_aiming = false
	_start = Vector3.INF
	if is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.BUILD_AIM:
		_hand.pop_category()
