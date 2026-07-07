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

var _sockets: Array[RelaySocket] = []
var _runes: Array[MeshInstance3D] = []
var _count: int = 0
var _awake: bool = false


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


## Все элементы на месте. Пробуждение одностороннее: вынутый обратно элемент
## механизм уже не «усыпит» (руны погаснут, но _awake остаётся).
## Фаза меха-стража (§5.27.3 ⑤) повесит сюда спавн и открытие створ.
func _on_awakened() -> void:
	EventBus.camera_shake.emit(0.5, global_position)
	AoeVisual.spawn_explosion(get_tree().current_scene,
		global_position + Vector3.UP * 3.0, 3.0)
	EventBus.tutorial_hint.emit("Механизм Врат гудит — древний страж просыпается…", 8.0)
