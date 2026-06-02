class_name Gate
extends Node3D
## Ворота победы. Тор'инг по карте в случайной точке (не в подземелье),
## ставится через [MatchConfig.next_gate_pos]. Цвет каркаса меняется в
## зависимости от состояния:
##  - **LOCKED** — серый: ключ не доставлен в башню. Tower может пройти,
##    но это ничего не сделает.
##  - **UNLOCKED** — золотой+пульсация: ключ в башне. Tower-проход активирует
##    эмит [signal EventBus.tower_passed_gate].
##  - **PASSED** — приглушённый зелёный: уже пройдены. Повторно не эмитят.
##
## Self-monitor: подписываемся на [signal EventBus.key_delivered_to_tower]
## → переходим в UNLOCKED. В _process проверяем дистанцию Tower'а до
## центра ворот; если ≤ [pass_radius] И state=UNLOCKED → PASSED и эмит.

enum State { LOCKED, UNLOCKED, PASSED }

const GROUP := &"gate"

## Радиус «прохождения через ворота» (м). Tower должен войти в этот круг
## вокруг центра ворот чтобы триггерить переход.
@export var pass_radius: float = 3.5

## Цвета индикатора по состояниям. Дизайнер тюнит через инспектор.
@export var color_locked: Color = Color(0.55, 0.55, 0.6, 1.0)
@export var color_unlocked: Color = Color(0.95, 0.78, 0.18, 1.0)
@export var color_passed: Color = Color(0.4, 0.9, 0.5, 1.0)

@onready var _mesh: MeshInstance3D = $Frame
@onready var _light: OmniLight3D = $Light

var _state: int = State.LOCKED
var _tower: Node3D = null
var _pulse_phase: float = 0.0
var _material: StandardMaterial3D


func _ready() -> void:
	add_to_group(GROUP)
	# Per-instance копия material — несколько Gate'ов на сцене не должны
	# делить emission. Сейчас Gate один, но архитектурно правильно.
	if _mesh != null and _mesh.material_override is StandardMaterial3D:
		_material = (_mesh.material_override as StandardMaterial3D).duplicate()
		_mesh.material_override = _material
	_apply_state_visual()
	EventBus.key_delivered_to_tower.connect(_on_key_delivered)


func get_state() -> int:
	return _state


func _on_key_delivered() -> void:
	if _state != State.LOCKED:
		return
	_state = State.UNLOCKED
	_apply_state_visual()
	if LogConfig.master_enabled:
		print("[Gate] разблокированы (ключ в башне)")


func _process(delta: float) -> void:
	_pulse_phase += delta * 3.0
	# Pulse-emission для UNLOCKED — выраженная «приглашающая» анимация.
	if _state == State.UNLOCKED and _material != null:
		var pulse: float = 0.7 + 0.3 * sin(_pulse_phase)
		_material.emission_energy_multiplier = 1.5 * pulse
		if _light != null:
			_light.light_energy = 2.0 * pulse
	if _state == State.PASSED:
		return
	# Tower-resolve lazy. После reload сцены Tower создаётся заново.
	if not is_instance_valid(_tower):
		_tower = get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	if _tower == null:
		return
	var dx: float = _tower.global_position.x - global_position.x
	var dz: float = _tower.global_position.z - global_position.z
	if dx * dx + dz * dz > pass_radius * pass_radius:
		return
	# Tower вошёл в круг. LOCKED — просто проход без эффекта (нет ключа).
	# UNLOCKED — триггер.
	if _state != State.UNLOCKED:
		return
	_state = State.PASSED
	_apply_state_visual()
	if LogConfig.master_enabled:
		print("[Gate] tower прошёл через ворота")
	# Расходуем ключ — KeyItem перейдёт в CONSUMED (визуально исчезнет).
	var key: KeyItem = get_tree().get_first_node_in_group(KeyItem.GROUP) as KeyItem
	if key != null:
		key.consume()
	EventBus.tower_passed_gate.emit()


func _apply_state_visual() -> void:
	if _material == null:
		return
	var c: Color = color_locked
	var emit_mult: float = 0.3
	match _state:
		State.LOCKED:
			c = color_locked
			emit_mult = 0.3
		State.UNLOCKED:
			c = color_unlocked
			emit_mult = 1.5
		State.PASSED:
			c = color_passed
			emit_mult = 0.6
	_material.albedo_color = c
	_material.emission = c
	_material.emission_energy_multiplier = emit_mult
	if _light != null:
		_light.light_color = c
		_light.light_energy = 1.5 if _state == State.UNLOCKED else 0.5
