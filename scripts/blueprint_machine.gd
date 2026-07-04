class_name BlueprintMachine
extends Node3D
## Станок-чертёжник гномов-строителей (квест Room11). Координатор пазла
## «запусти механизм»: к станку подключены N диодов ([SparkDiode]); чтобы он
## ожил, надо подать ток в ПРАВИЛЬНОМ порядке (= порядок в [diode_paths]).
##
## Цикл:
##   IDLE  — диоды заглушены (locked). Башня подходит ближе activate_radius → DEMO.
##   DEMO  — станок «проигрывает» последовательность (flash_hint по диодам по
##           очереди). После показа → INPUT.
##   INPUT — диоды расглушены; игрок бьёт Искрой по диодам. Верный следующий →
##           диод фиксируется зелёным (его собственный on_spark). Ошибка в
##           порядке → сброс всех диодов + повторный показ (DEMO).
##   DONE  — вся последовательность верна → диоды заглушены, включается рычаг-
##           пускач ([lever_path].enable()). Игрок дёргает рычаг → lever зовёт
##           наш activate() → [_ignite]: станок оживает, PlayerProfile.unlock_building.
##
## Реюз: детект попадания Искрой живёт в SparkBolt → on_spark() у членов
## SPARK_TARGET_GROUP; диоды сообщают сюда через сигнал `sparked`. Рычаг — тот же
## [Lever] что и в дверных пазлах (enable-gate + target.activate()).

enum State { IDLE, DEMO, INPUT, DONE }

## Порядок диодов = правильная последовательность подачи тока. Diodes резолвятся
## как [SparkDiode]; индекс в массиве = ожидаемый шаг.
@export var diode_paths: Array[NodePath] = []
## Финальный рычаг-пускач ([Lever]). Стартует disabled; включаем на DONE.
@export var lever_path: NodePath
## Меш-ядро станка — подсветим эмиссией на запуске (опц.).
@export var core_path: NodePath

@export_group("Демо / тайминги")
## Радиус (XZ) от станка, на котором приближение башни запускает первый показ.
@export var activate_radius: float = 11.0
## Пауза между вспышками диодов в демо-показе (сек).
@export var demo_step_time: float = 0.6
## Длительность вспышки одного диода в демо.
@export var demo_flash_time: float = 0.45
## Пауза перед стартом демо (после захода в радиус / после ошибки).
@export var demo_lead_in: float = 0.5
## Показывать демо заново после ошибки. False — просто сброс, играешь по памяти.
@export var replay_on_fail: bool = true

@export_group("Отладка")
@export var debug_log: bool = true

var _state: int = State.IDLE
var _step: int = 0
var _diodes: Array[SparkDiode] = []
var _lever: Node = null
var _core_mat: StandardMaterial3D = null
var _tower: Node3D = null


func _ready() -> void:
	for p in diode_paths:
		var d := get_node_or_null(p) as SparkDiode
		if d != null:
			d.locked = true  # до показа Искра не засчитывается
			var idx: int = _diodes.size()
			d.sparked.connect(_on_diode_sparked.bind(idx))
			_diodes.append(d)
		else:
			push_warning("[BlueprintMachine] diode_path не SparkDiode: %s" % p)
	_lever = get_node_or_null(lever_path)
	if _lever != null and _lever.has_method(&"disable"):
		_lever.call(&"disable")
	var core := get_node_or_null(core_path) as MeshInstance3D
	if core != null and core.get_surface_override_material(0) != null:
		_core_mat = core.get_surface_override_material(0)
	elif core != null and core.material_override is StandardMaterial3D:
		_core_mat = core.material_override as StandardMaterial3D


func _process(_delta: float) -> void:
	# Триггер первого показа: башня подошла к станку. Дальше state ≠ IDLE — выходим.
	if _state != State.IDLE:
		return
	if _diodes.is_empty():
		return
	if _tower == null or not is_instance_valid(_tower):
		_tower = get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
		if _tower == null:
			return
	var dx: float = _tower.global_position.x - global_position.x
	var dz: float = _tower.global_position.z - global_position.z
	if dx * dx + dz * dz <= activate_radius * activate_radius:
		_play_demo()


## Демо-показ: вспышки диодов по очереди в порядке diode_paths. Гард валидности
## после await — станок мог быть удалён (рестарт сцены) посреди показа.
func _play_demo() -> void:
	_state = State.DEMO
	_step = 0
	for d in _diodes:
		d.locked = true
		d.reset()
	if debug_log and LogConfig.master_enabled:
		print("[BlueprintMachine] ДЕМО последовательности (%d шагов)" % _diodes.size())
	await get_tree().create_timer(demo_lead_in).timeout
	if not is_instance_valid(self):
		return
	for d in _diodes:
		if not is_instance_valid(self):
			return
		if is_instance_valid(d):
			d.flash_hint(demo_flash_time)
			AoeVisual.spawn_pulse_sparks(get_tree().current_scene,
				d.global_position + Vector3.UP * 0.3, 1.2, 7.0)
		await get_tree().create_timer(demo_step_time).timeout
	if not is_instance_valid(self):
		return
	_begin_input()


## Расглушить диоды — игрок повторяет последовательность Искрой.
func _begin_input() -> void:
	_state = State.INPUT
	_step = 0
	for d in _diodes:
		d.reset()
		d.locked = false
	if debug_log and LogConfig.master_enabled:
		print("[BlueprintMachine] ВВОД — повтори порядок Искрой")


## Диод сработал (Искра). index — позиция диода в diode_paths (через bind).
func _on_diode_sparked(index: int) -> void:
	if _state != State.INPUT:
		return
	if index == _step:
		_step += 1
		if debug_log and LogConfig.master_enabled:
			print("[BlueprintMachine] верно %d/%d" % [_step, _diodes.size()])
		if _step >= _diodes.size():
			_on_sequence_complete()
	else:
		if debug_log and LogConfig.master_enabled:
			print("[BlueprintMachine] ОШИБКА порядка (ждал %d, пришёл %d) — сброс" % [_step, index])
		_fail()


## Ошибка порядка: сброс диодов + фызл, затем повторный показ (или просто ввод).
func _fail() -> void:
	for d in _diodes:
		d.locked = true
		d.reset()
		AoeVisual.spawn_pulse_sparks(get_tree().current_scene,
			d.global_position + Vector3.UP * 0.3, 1.0, 5.0)
	if replay_on_fail:
		_play_demo()
	else:
		_begin_input()


## Вся последовательность верна — глушим диоды, включаем рычаг-пускач.
func _on_sequence_complete() -> void:
	_state = State.DONE
	for d in _diodes:
		d.locked = true
	if _lever != null and _lever.has_method(&"enable"):
		_lever.call(&"enable")
	if debug_log and LogConfig.master_enabled:
		print("[BlueprintMachine] последовательность собрана → рычаг-пускач включён")


## Зовёт рычаг ([Lever].target_path → станок) когда игрок его довёл. Запуск станка.
func activate() -> void:
	_ignite()


## Станок оживает: вспышка ядра + искры + знание о постройках игроку.
func _ignite() -> void:
	var root: Node = get_tree().current_scene
	if is_instance_valid(root):
		AoeVisual.spawn_explosion(root, global_position + Vector3.UP * 0.8, 2.0)
		AoeVisual.spawn_pulse_sparks(root, global_position + Vector3.UP * 0.8, 2.5, 18.0)
	EventBus.camera_shake.emit(0.4, global_position)
	if _core_mat != null:
		_core_mat.emission_enabled = true
		_core_mat.emission = Color(1.0, 0.8, 0.3)
		_core_mat.emission_energy_multiplier = 4.0
	var profile := get_tree().get_first_node_in_group(&"player_profile")
	if profile != null and profile.has_method(&"unlock_building"):
		profile.call(&"unlock_building")
	if debug_log and LogConfig.master_enabled:
		print("[BlueprintMachine] ★ СТАНОК ЗАПУЩЕН — знание о постройках открыто")
