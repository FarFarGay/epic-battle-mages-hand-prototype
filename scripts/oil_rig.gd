class_name OilRig
extends StaticBody3D
## Гномья нефтекачалка (Room8) — центральный объект геймлупа. Сломана; игрок
## восстанавливает её цепочкой квестов гномов-строителей, затем она качает нефть,
## а игрок защищает её от штурма. Накопил oil_goal нефти → победа матча.
##
## Стадии (разворачиваем инкрементами; здесь — каркас состояний + API-хуки):
##   BROKEN    — мёртвая, ржавая, без движения. Требует «лицензии строителя»
##               (PlayerProfile.building_unlocked = станок Room11 запущен), иначе
##               гномы не подпускают к ремонту.
##   RESTORING — игрок отстраивает узлы (restore_module × modules_required) —
##               стройкой/починкой механизмов. Все узлы собраны → готова к пуску.
##   PUMPING   — мастер-рычаг запущен (ignite): насос качает, oil тикает вверх,
##               качалка стягивает орду (стадия защиты). oil >= oil_goal → победа.
##
## NB: победа/штурм пока НЕ подключены (стадии 3-4) — oil копится и логируется,
## без emit match_won, чтобы не ломать текущее условие (1000 золота / ключ).

const GROUP := &"oil_rig"

signal state_changed(new_state: int)
signal module_restored(done: int, total: int)
signal oil_changed(oil: float, goal: float)
signal ignited

enum State { BROKEN, RESTORING, PUMPING }

@export_group("Восстановление")
## Сколько узлов отстроить в стадии RESTORING до готовности к пуску.
@export var modules_required: int = 3

@export_group("Добыча")
## Нефть в секунду в режиме PUMPING.
@export var oil_per_sec: float = 1.0
## Цель матча — накопить столько нефти (победа). Подключим к WinOverlay стадией 4.
@export var oil_goal: float = 100.0

@export_group("Визуал бура")
## Узел бита-бура (крутится вокруг Y в PUMPING). Пусто — без вращения.
@export var drill_path: NodePath
## Скорость вращения бура (рад/с) в работе.
@export var drill_spin_speed: float = 7.0

@export_group("Отладка")
@export var debug_log: bool = true

var _state: int = State.BROKEN
var _modules_done: int = 0
var _oil: float = 0.0
var _drill: Node3D = null


func _ready() -> void:
	add_to_group(GROUP)
	_drill = get_node_or_null(drill_path) as Node3D
	set_process(false)  # тикаем только в PUMPING


func _process(delta: float) -> void:
	if _state != State.PUMPING:
		return
	# Вращение бура.
	if _drill != null:
		_drill.rotation.y += drill_spin_speed * delta
	# Добыча нефти.
	var before: float = _oil
	_oil = minf(_oil + oil_per_sec * delta, oil_goal)
	if _oil != before:
		oil_changed.emit(_oil, oil_goal)
		# Стадия 4 (TODO): при _oil >= oil_goal → победа (EventBus.match_won).


## Гейт ремонта: есть ли у игрока «лицензия строителя» (станок Room11 запущен).
func restore_unlocked() -> bool:
	var p := get_tree().get_first_node_in_group(&"player_profile")
	return p != null and p.get(&"building_unlocked") == true


## Перейти к ремонту (BROKEN → RESTORING). No-op без лицензии строителя.
func begin_restore() -> bool:
	if _state != State.BROKEN:
		return _state == State.RESTORING
	if not restore_unlocked():
		if debug_log and LogConfig.master_enabled:
			print("[OilRig] ремонт закрыт — нет знания построек (станок Room11)")
		return false
	_set_state(State.RESTORING)
	return true


## Отстроен один узел качалки (зовёт стадия 2 — build-site / починка механизма).
## Все собраны → готова к пуску (ждём мастер-рычаг → ignite).
func restore_module() -> void:
	if _state != State.RESTORING:
		return
	_modules_done = mini(_modules_done + 1, modules_required)
	module_restored.emit(_modules_done, modules_required)
	if debug_log and LogConfig.master_enabled:
		print("[OilRig] узел %d/%d" % [_modules_done, modules_required])


## Все ли узлы собраны (стадия 3 разрешает пуск).
func ready_to_ignite() -> bool:
	return _state == State.RESTORING and _modules_done >= modules_required


## Запуск насоса (мастер-рычаг). Требует собранных узлов. → PUMPING.
func ignite() -> void:
	if not ready_to_ignite():
		return
	_set_state(State.PUMPING)
	set_process(true)
	ignited.emit()
	if debug_log and LogConfig.master_enabled:
		print("[OilRig] ★ НАСОС ЗАПУЩЕН — добыча нефти пошла")


func get_oil() -> float:
	return _oil


func get_state() -> int:
	return _state


func _set_state(s: int) -> void:
	if _state == s:
		return
	_state = s
	state_changed.emit(s)
	if debug_log and LogConfig.master_enabled:
		print("[OilRig] state → %s" % ["BROKEN", "RESTORING", "PUMPING"][s])
