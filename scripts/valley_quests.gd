class_name ValleyQuests
extends Node
## Чеклист-задания Долины (город, зона за Room5): постоянная строка «⚑ Задание»
## на HUD ведёт игрока по городским урокам — станок → замок → шахта → дом+казарма
## → стены → верфь → пережить ночь → наполнить замок. Одна цепочка, шаги
## последовательные.
##
## Механика: ПОЛЛИНГ состояния мира (Timer 0.5с) — условия читаются из групп/
## флагов, никакой подписки на десяток сигналов. Шаг выполнен → плашка
## «✓ …» (EventBus.tutorial_hint) + следующий текст в строку
## (EventBus.valley_quest_changed). Ночь-шаг событийный (day_phase_changed).
##
## Строка на HUD появляется с ПЕРВОГО шага цепочки, выполненного или начатого:
## гейт activation_check (по умолчанию — знание построек ИЛИ вход башни в
## долину), чтобы чеклист не висел с самого старта пещеры.

## Прямоугольник долины (XZ): строка заданий активируется, когда башня внутри.
@export var valley_center: Vector2 = Vector2(55.0, 84.0)
@export var valley_size: Vector2 = Vector2(74.0, 86.0)

var _step: int = 0
var _active: bool = false
## Ночь-шаг: штурм начался при живом замке (ждём рассвета).
var _night_started: bool = false
var _night_survived: bool = false
var _won: bool = false


## Цепочка: text — в строку HUD; done — Callable():bool (поллинг).
## Тексты держим короткими: строка одна.
var _steps: Array = []


func _ready() -> void:
	_steps = [
		{"text": "Найди Гильдию Камня и запусти станок-чертёжник",
			"done": func() -> bool: return _building_known()},
		{"text": "Построй качалку-замок у жилы (карточка артели → Стройка)",
			"done": func() -> bool: return _castle_built()},
		{"text": "Поставь шахту на жилу — монеты закапают сами",
			"done": func() -> bool: return _has_role(&"mine")},
		{"text": "Расстройся: дом (население) и казарма (гарнизон)",
			"done": func() -> bool: return _has_role(&"housing") and _has_role(&"barracks")},
		{"text": "Обнеси город стеной: 5 секций обороны",
			"done": func() -> bool: return _count_role(&"defend") >= 5},
		{"text": "Построй верфь и купи башне срез-улучшение",
			"done": func() -> bool: return _has_role(&"dock") and _slice_installed()},
		{"text": "Ночью будет штурм. Переживи его — защити замок",
			"done": func() -> bool: return _night_survived},
		{"text": "Наполняй замок: шахты качают, город защищает",
			"done": func() -> bool: return _won},
	]
	EventBus.day_phase_changed.connect(_on_day_phase)
	EventBus.match_won.connect(_on_won)
	tree_exiting.connect(func() -> void:
		EventBus.day_phase_changed.disconnect(_on_day_phase)
		EventBus.match_won.disconnect(_on_won))
	var poll := Timer.new()
	poll.wait_time = 0.5
	poll.autostart = true
	add_child(poll)
	poll.timeout.connect(_tick)


func _tick() -> void:
	if _step >= _steps.size():
		return
	# Активация строки: башня доехала до долины (или знание уже добыто читом).
	if not _active:
		if not (_tower_in_valley() or _building_known()):
			return
		_active = true
		EventBus.valley_quest_changed.emit(_current_text())
	# Проверка текущего шага (и каскад — вдруг игрок перевыполнил вперёд).
	while _step < _steps.size() and (_steps[_step]["done"] as Callable).call():
		EventBus.tutorial_hint.emit("✓ %s" % _steps[_step]["text"], 5.0)
		_step += 1
		EventBus.valley_quest_changed.emit(_current_text())


func _current_text() -> String:
	if _step >= _steps.size():
		return ""  # цепочка пройдена — строка гаснет
	return "⚑ %s" % String(_steps[_step]["text"])


# --- Условия шагов (чтение мира) ---

func _building_known() -> bool:
	var prof := get_tree().get_first_node_in_group(&"player_profile")
	return prof != null and bool(prof.get(&"building_unlocked"))


func _castle_built() -> bool:
	return get_tree().get_first_node_in_group(Castle.GROUP) != null


func _has_role(role: StringName) -> bool:
	return _count_role(role) > 0


func _count_role(role: StringName) -> int:
	var c: int = 0
	for n in get_tree().get_nodes_in_group(&"pad_building"):
		if is_instance_valid(n) and n.get(&"_role") == role:
			c += 1
	return c


func _slice_installed() -> bool:
	var up := get_tree().get_first_node_in_group(&"tower_upgrades")
	if up == null:
		return false
	var installed: Variant = up.get(&"_installed")
	return installed is Dictionary and not (installed as Dictionary).is_empty()


func _tower_in_valley() -> bool:
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	if tower == null:
		return false
	var p: Vector3 = tower.global_position
	return absf(p.x - valley_center.x) <= valley_size.x * 0.5 \
			and absf(p.z - valley_center.y) <= valley_size.y * 0.5


# --- Ночь-шаг (событийный) ---

func _on_day_phase(is_night: bool, _duration: float) -> void:
	if is_night:
		# Штурм считается пережитым, только если замок был на месте к ночи.
		_night_started = _castle_built()
	elif _night_started and _castle_built():
		_night_survived = true


func _on_won() -> void:
	_won = true
