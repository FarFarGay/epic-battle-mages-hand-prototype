class_name GateRuin
extends Node3D
## Древние Врата — руина в северной стене долины (акт II, §5.27): выход из
## долины дальше по миру, механизм сломан. В плите 3 пустых гнезда
## ([RelaySocket] без проводов — чистые сокеты) — элементы вылазок (паттерн
## [RelayItem]) вставляются рукой в любом порядке. Каждая посадка зажигает
## руну на плите; все три → механизм «оживает» (пробуждение меха-стража и
## открытие створ — следующая фаза акта, вешается на [_on_awakened]).
##
## Счёт — ПОЛЛИНГ гнёзд (Timer 0.5с, как [ValleyQuests]): RelaySocket.seat/
## unseat сигналов не эмитят, и плодить их ради одного читателя не надо.
## ValleyQuests читает прогресс через группу GROUP → [elements_count].

const GROUP := &"gate_ruin"

## Гнёзда механизма (дети-инстансы relay_socket.tscn, по порядку рун).
@export var socket_paths: Array[NodePath] = []
## Руны на плите — зажигаются слева направо по числу вставленных элементов.
@export var rune_paths: Array[NodePath] = []
@export var rune_dead_energy: float = 0.15
@export var rune_live_energy: float = 3.0
## Плита-створ (Blocker-StaticBody): после смерти стража съезжает под землю.
@export var slab_path: NodePath = ^"Slab"
## Мех-страж Врат ([EnemyMech], СОЛО-дуэль — канон «строго 1 за раз»).
@export var mech_scene: PackedScene
## Задержка выхода стража после оживления механизма (сек) — время на предупреждение.
@export var mech_delay: float = 3.0
## Насколько плита уезжает вниз при открытии.
@export var slab_slide_depth: float = 7.0

var _sockets: Array[RelaySocket] = []
var _runes: Array[MeshInstance3D] = []
var _count: int = 0
var _awake: bool = false
var _mech: Node3D = null
var _open: bool = false
var _won: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	for p: NodePath in socket_paths:
		var s := get_node_or_null(p) as RelaySocket
		if s != null:
			_sockets.append(s)
	for p: NodePath in rune_paths:
		var r := get_node_or_null(p) as MeshInstance3D
		if r != null:
			_runes.append(r)
	if _sockets.is_empty():
		push_warning("[GateRuin] socket_paths пуст — механизм некому оживить (%s)" % name)
	var poll := Timer.new()
	poll.wait_time = 0.5
	poll.autostart = true
	add_child(poll)
	poll.timeout.connect(_poll)


func elements_count() -> int:
	return _count


func elements_total() -> int:
	return _sockets.size()


func is_awake() -> bool:
	return _awake


func _poll() -> void:
	_check_victory()
	var n: int = 0
	for s in _sockets:
		if is_instance_valid(s) and s.is_seated():
			n += 1
	if n == _count:
		return
	var grew: bool = n > _count
	_count = n
	_update_runes()
	if grew:
		AoeVisual.spawn_pulse_sparks(get_tree().current_scene,
			global_position + Vector3.UP * 2.0, 1.6, 10.0)
		EventBus.tutorial_hint.emit(
			"Руна Врат вспыхнула: элементов %d/%d" % [_count, _sockets.size()], 5.0)
	if not _awake and _sockets.size() > 0 and _count >= _sockets.size():
		_awake = true
		_on_awakened()


func _update_runes() -> void:
	for i in _runes.size():
		var mat := _runes[i].material_override as StandardMaterial3D
		if mat != null:
			mat.emission_energy_multiplier = \
				rune_live_energy if i < _count else rune_dead_energy


func is_open() -> bool:
	return _open


func is_guard_down() -> bool:
	return _awake and _mech == null


## Все элементы на месте. Пробуждение одностороннее: вынутый обратно элемент
## механизм уже не «усыпит» (руны погаснут, но _awake остаётся).
## Финал акта: предупреждение → из врат выходит мех-страж (соло-дуэль, СТРОГО
## один — канон [[project_ebm_mech_solo_apex]]) → убил → створ открывается →
## башня в проёме = победа (см. [_poll] хвост).
func _on_awakened() -> void:
	EventBus.camera_shake.emit(0.5, global_position)
	AoeVisual.spawn_explosion(get_tree().current_scene,
		global_position + Vector3.UP * 3.0, 3.0)
	EventBus.tutorial_hint.emit("Механизм Врат гудит — древний страж просыпается…", 8.0)
	EventBus.boss_wave_incoming.emit(mech_delay)
	var t := get_tree().create_timer(mech_delay)
	t.timeout.connect(_spawn_mech)


func _spawn_mech() -> void:
	if mech_scene == null:
		push_warning("[GateRuin] mech_scene не задан — страж не выйдет, врата откроются сразу")
		_open_gates()
		return
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	_mech = mech_scene.instantiate() as Node3D
	scene.add_child(_mech)
	_mech.global_position = global_position + Vector3(0, 1.2, 6.0)
	if _mech.has_signal(&"destroyed"):
		_mech.connect(&"destroyed", _on_mech_destroyed)
	AoeVisual.spawn_explosion(scene, _mech.global_position, 2.5)
	EventBus.camera_shake.emit(0.6, _mech.global_position)
	EventBus.tutorial_hint.emit("⚔ СТРАЖ ВРАТ! Срази его — путь наружу за ним", 8.0)


func _on_mech_destroyed() -> void:
	_mech = null
	_open_gates()


## Створ уезжает под землю (как MetalDoor): навмеш снимаем СИНХРОННО в конце
## съезда — физика и навмеш согласованы, агенты не ходят «сквозь» плиту.
func _open_gates() -> void:
	if _open:
		return
	_open = true
	EventBus.tutorial_hint.emit("⚑ Врата открыты! Веди башню в проём — путь из долины свободен", 10.0)
	var slab := get_node_or_null(slab_path) as Node3D
	if slab == null:
		return
	var tween := create_tween()
	tween.tween_property(slab, "position:y", slab.position.y - slab_slide_depth, 2.2) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(func() -> void:
		if is_instance_valid(slab):
			if slab.is_in_group(&"navmesh_source"):
				slab.remove_from_group(&"navmesh_source")
			var nav := get_tree().get_first_node_in_group(&"nav_region")
			if nav != null and nav.has_method(&"rebake"):
				nav.rebake()
			slab.queue_free())
	AoeVisual.spawn_dust(get_tree().current_scene, global_position + Vector3.UP * 0.5)
	EventBus.camera_shake.emit(0.5, global_position)


## Башня вошла в открытый проём (полоса врат, XZ) → победа акта.
func _check_victory() -> void:
	if not _open or _won:
		return
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	if tower == null:
		return
	var p: Vector3 = tower.global_position
	if absf(p.x - global_position.x) <= 4.5 and p.z <= global_position.z - 0.5:
		_won = true
		EventBus.match_won.emit()
