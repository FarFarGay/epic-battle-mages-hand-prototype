extends SceneTree

## Выпекает ветку ангара интро в отдельную сцену res://scenes/intro_hangar.tscn,
## чтобы комнату можно было открыть в редакторе и двигать мышкой (как К4-ледник).
##
## ⛔ ОСТОРОЖНО, ПОВТОРНЫЙ ПРОГОН ЗАТРЁТ РУЧНЫЕ ПРАВКИ. Скрипт пересобирает
## сцену из ГЕОМЕТРИИ КОДА (_intro_build_hangar_geometry), а в intro_hangar.tscn
## с 2026-08-08 руками добавлена ветка Columns — восемь разрушаемых колонн
## (hangar_column.gd). Кодом они не строятся, поэтому перезапуск бейка их СНЕСЁТ.
## Нужен новый бейк — сначала перенеси Columns в код или подмешай ветку после
## pack'а.
##
## Запуск:
##   godot --path <проект> --headless --script res://tools/bake_hangar.gd
##
## Как работает: поднимает dungeon_intro, ждёт постройки ангара кодом, забирает
## узел «Hangar», проставляет owner всему поддереву (без него PackedScene.pack
## сохранит один корень) и пишет сцену. Дальше узел кладётся в dungeon_intro.tscn
## инстансом в группе intro_hangar — код увидит его и строить перестанет.


func _own(n: Node, root: Node) -> void:
	for c in n.get_children():
		c.owner = root
		_own(c, root)


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/dungeon_intro.tscn")
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	# Пара физкадров: ангар строится в _ready, но плиты въезжают под ветку сразу.
	await process_frame
	await process_frame
	var hangar: Node = scene.get_node_or_null(^"Hangar")
	if hangar == null:
		push_error("[bake_hangar] ветка Hangar не найдена — ангар не построился")
		quit(1)
		return
	# Отвязываем от сцены-донора: КОРНЕМ становится сам ангар, без обёртки —
	# иначе после инстанса код искал бы TowerDock на уровень глубже.
	var dock_pos := Vector3(scene.room_center.x - 24.0, 0.0, scene.room_center.z - 226.0)
	scene.remove_child(hangar)
	root.add_child(hangar)
	# Маркер дока башни: чтобы позицию тоже можно было двигать мышкой.
	var dock := Node3D.new()
	dock.name = "TowerDock"
	hangar.add_child(dock)
	(dock as Node3D).global_position = dock_pos
	_own(hangar, hangar)
	var ps := PackedScene.new()
	if ps.pack(hangar) != OK:
		push_error("[bake_hangar] pack не удался")
		quit(1)
		return
	var err: int = ResourceSaver.save(ps, "res://scenes/intro_hangar.tscn")
	if err != OK:
		push_error("[bake_hangar] save не удался: %d" % err)
		quit(1)
		return
	print("[bake_hangar] сохранено: res://scenes/intro_hangar.tscn, узлов=%d"
			% (hangar.get_child_count() + 1))
	quit(0)
