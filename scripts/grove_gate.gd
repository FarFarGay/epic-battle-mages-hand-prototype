extends Node3D
## Сценарий «работа под угрозой» (Room5): рубка рощи шумит — первый удар топора
## будит скелетов (волна с флангов), каждое срубленное дерево — ещё волна.
## Цель работы — МОНЕТЫ (единая валюта, 2026-07-07): брёвна продаются казне на
## сдаче у башни; накопилось на мостки (coins_ready_threshold) → подсказка
## «открой Стройку». Сами мостки — постройка каталога ([RoomBuildings.BRIDGE_PLANK])
## за монеты → готовая доска → рука кладёт её поперёк пропасти.
##
## Слушает сигналы [WoodSource] chopped/depleted (пути в source_paths); казну
## поллит таймером (GoldBank пополнение не сигналит). Точки спавна волн —
## дочерние Marker3D. Подсказки шлёт напрямую в EventBus.tutorial_hint.

## Деревья-источники (WoodSource) — рубка любых из них двигает сценарий.
@export var source_paths: Array[NodePath] = []
## Кем атаковать на шум рубки.
@export var skeleton_scene: PackedScene
## Размер волны на ПЕРВЫЙ удар топора (шум разбудил).
@export var first_chop_wave: int = 4
## Размер волны на каждое СРУБЛЕННОЕ дерево.
@export var tree_felled_wave: int = 6
## Урон волновых скелетов (комнатные «раздражатели», как room_skeleton_filler).
@export var wave_attack_damage: float = 3.0
## Порог казны (в бронзе), при котором подсказываем стройку мостков (= их цена).
@export var coins_ready_threshold: int = 30
@export_multiline var hint_ambush: String = "Шум рубки разбудил скелетов — защити рабочих!"
@export_multiline var hint_coins_ready: String = "Монет хватает! Карточка артели → Стройка → Мостки: ставь у пропасти"

var _ambush_started: bool = false
var _coins_hint_shown: bool = false
var _felled: int = 0
var _spawn_points: Array[Vector3] = []
var _spawn_cursor: int = 0


func _ready() -> void:
	for c in get_children():
		if c is Marker3D:
			_spawn_points.append((c as Marker3D).global_position)
	for path in source_paths:
		var src := get_node_or_null(path)
		if src == null:
			push_warning("[GroveGate] source_path не разрешён: %s" % path)
			continue
		src.connect(&"chopped", _on_chopped)
		src.connect(&"depleted", _on_depleted)
	# Порог казны: GoldBank на пополнение не сигналит — дешёвый поллинг таймером.
	# Хинт гейтится начатой рубкой (иначе богач с горшков получит его на входе в сцену).
	var poll := Timer.new()
	poll.wait_time = 0.5
	poll.autostart = true
	add_child(poll)
	poll.timeout.connect(_check_coins)


func _on_chopped(_remaining: int) -> void:
	if _ambush_started:
		return
	_ambush_started = true
	EventBus.tutorial_hint.emit(hint_ambush, 7.0)
	_spawn_wave(first_chop_wave)


func _on_depleted() -> void:
	_felled += 1
	_spawn_wave(tree_felled_wave)


## Монет накопилось на мостки → подсказка следующего шага. Один раз; только
## после начала рубки (богатый с горшков игрок не получит хинт до работы).
func _check_coins() -> void:
	if _coins_hint_shown or not _ambush_started:
		return
	var bank := get_tree().get_first_node_in_group(GoldBank.GROUP)
	if bank == null or not bank.has_method(&"get_gold"):
		return
	if int(bank.call(&"get_gold")) >= coins_ready_threshold:
		_coins_hint_shown = true
		EventBus.tutorial_hint.emit(hint_coins_ready, 9.0)


## Волна с флангов: скелеты по точкам-маркерам (поровну, с разбросом), сразу
## идут на башню (forced-цель — fallback зрения, вблизи vision сам возьмёт).
func _spawn_wave(count: int) -> void:
	if skeleton_scene == null or count <= 0:
		return
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var tower := get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	for i in range(count):
		var inst := skeleton_scene.instantiate() as Node3D
		if inst == null:
			continue
		scene_root.add_child(inst)
		var base: Vector3 = global_position
		if not _spawn_points.is_empty():
			base = _spawn_points[_spawn_cursor % _spawn_points.size()]
			_spawn_cursor += 1
		var pos: Vector3 = base + Vector3(randf_range(-1.5, 1.5), 0.0, randf_range(-1.5, 1.5))
		pos.y = 1.0
		inst.global_position = pos
		if wave_attack_damage > 0.0:
			inst.set(&"attack_damage", wave_attack_damage)
		if tower != null and inst.has_method(&"set_forced_target"):
			inst.call(&"set_forced_target", tower)
		AoeVisual.spawn_dust(scene_root, pos)
