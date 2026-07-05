extends Node3D
## Сценарий «работа под угрозой» (Room5): плашка моста придавлена рощей —
## недоступна руке, пока деревья стоят. Первый удар топора будит скелетов
## (волна с флангов), каждое срубленное дерево — ещё волна. Вся роща срублена →
## плашка освобождается (пыль + подсказка), путь через пропасть открыт.
##
## Слушает сигналы [WoodSource] chopped/depleted (пути в source_paths).
## Точки спавна волн = дочерние Marker3D (волна делится между ними поровну).
## Подсказки шлёт напрямую в EventBus.tutorial_hint (та же плашка HUD).

## Деревья-источники (WoodSource) — рубка любых из них двигает сценарий.
@export var source_paths: Array[NodePath] = []
## Плашка моста (BridgePlank), запертая до вырубки рощи.
@export var plank_path: NodePath
## Кем атаковать на шум рубки.
@export var skeleton_scene: PackedScene
## Размер волны на ПЕРВЫЙ удар топора (шум разбудил).
@export var first_chop_wave: int = 4
## Размер волны на каждое СРУБЛЕННОЕ дерево.
@export var tree_felled_wave: int = 6
## Урон волновых скелетов (комнатные «раздражатели», как room_skeleton_filler).
@export var wave_attack_damage: float = 3.0
@export_multiline var hint_ambush: String = "Шум рубки разбудил скелетов — защити рабочих!"
@export_multiline var hint_freed: String = "Роща расчищена! Мосток свободен — положи его через пропасть"

var _plank: RigidBody3D = null
var _ambush_started: bool = false
var _felled: int = 0
var _spawn_points: Array[Vector3] = []
var _spawn_cursor: int = 0


func _ready() -> void:
	for c in get_children():
		if c is Marker3D:
			_spawn_points.append((c as Marker3D).global_position)
	_plank = get_node_or_null(plank_path) as RigidBody3D
	if _plank != null:
		# Запереть: слой 0 → GrabArea руки её не видит, freeze → не толкается.
		_plank.freeze = true
		_plank.collision_layer = 0
	for path in source_paths:
		var src := get_node_or_null(path)
		if src == null:
			push_warning("[GroveGate] source_path не разрешён: %s" % path)
			continue
		src.connect(&"chopped", _on_chopped)
		src.connect(&"depleted", _on_depleted)


func _on_chopped(_remaining: int) -> void:
	if _ambush_started:
		return
	_ambush_started = true
	EventBus.tutorial_hint.emit(hint_ambush, 7.0)
	_spawn_wave(first_chop_wave)


func _on_depleted() -> void:
	_felled += 1
	if _felled < source_paths.size():
		_spawn_wave(tree_felled_wave)
		return
	# Роща вырублена: последняя волна + освобождение плашки.
	_spawn_wave(tree_felled_wave)
	_release_plank()


func _release_plank() -> void:
	if _plank == null or not is_instance_valid(_plank):
		return
	_plank.freeze = false
	_plank.collision_layer = Layers.ITEMS
	AoeVisual.spawn_dust(get_tree().current_scene, _plank.global_position)
	EventBus.tutorial_hint.emit(hint_freed, 8.0)


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
