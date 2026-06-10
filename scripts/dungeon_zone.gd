@tool
class_name DungeonZone
extends Node3D
## Зона данжа. Пока внутри зоны хотя бы один солдат
## ([code]SoldierGnome.SOLDIER_GROUP[/code]) — камера переключается на
## CentroidProxy (центр масс живых солдат в зоне). Все вышли или умерли —
## камера возвращается на дефолтную цель CameraRig'а (башня).
##
## Гранулярность — только Soldier'ы, потому что командовать «Иди сюда»
## можно именно ими (defender/gatherer на point-and-click не реагируют).
## Это совпадает с дизайн-условием «в данж только группой солдат».
##
## Дизайнерский флоу: ставишь сцену, крутишь `size` в инспекторе — обновляются
## ОДНОВРЕМЕННО BoxShape3D и зелёный visual-куб (видим только в редакторе).
## Single source of truth — поле `size` на этом узле; не трогай размер
## BoxShape3D и BoxMesh напрямую (перетрётся следующим refresh'ем).
##
## Структура .tscn:
## [codeblock]
## DungeonZone (Node3D, этот скрипт)
## ├── Area3D (collision_mask = Layers.FRIENDLY_UNIT = 256)
## │   └── CollisionShape3D (BoxShape3D)
## ├── Mesh (MeshInstance3D, BoxMesh) — зелёный индикатор, hidden в рантайме
## └── CentroidProxy (Node3D)
## [/codeblock]
##
## Башня в данж не пускается ГЕОМЕТРИЧЕСКИ (узкий проход) — collision-фильтр
## не используется. Если в будущем понадобится явный гейт — отдельный
## коллайдер на layer'е Tower, не здесь.

## Размер зоны в метрах (X×Y×Z). Применяется и к BoxShape3D под Area3D,
## и к зелёному visual-кубу. Y задаёт высоту зоны — для входа достаточно
## чтобы солдат пересёк её, ~2-4м хватает.
@export var size: Vector3 = Vector3(10.0, 4.0, 10.0):
	set(value):
		size = Vector3(maxf(value.x, 0.1), maxf(value.y, 0.1), maxf(value.z, 0.1))
		_refresh_visual()

## Живые солдаты внутри зоны. Поддерживается через body_entered/exited
## + per-tick инвалидация (на случай смерти внутри — Godot эмитит
## body_exited не сразу).
var _members: Array[Node3D] = []
var _camera_rig: CameraRig = null


func _ready() -> void:
	_refresh_visual()
	# Editor-mode (@tool): только визуал, никакой рантайм-логики.
	if Engine.is_editor_hint():
		return
	# Само-регистрация в группу — контракт потребителей границ данжа: WaveDirector
	# (не спавнить скелетов в данже — нет навмеш-выхода, бьются о стены) и StartMenu
	# (не ставить Tower/POI/Gate в нём). Раньше группа НИГДЕ не выставлялась → все
	# get_nodes_in_group(&"dungeon_zone") возвращали пусто, а avoidance был мёртв.
	add_to_group(&"dungeon_zone")
	var area := get_node_or_null("Area3D") as Area3D
	if area == null:
		push_error("[DungeonZone] нет Area3D-ребёнка — проверьте структуру сцены")
		return
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)
	_camera_rig = get_tree().get_first_node_in_group(CameraRig.CAMERA_RIG_GROUP) as CameraRig
	if _camera_rig == null:
		push_warning("[DungeonZone] CameraRig не найден в группе '%s'" % CameraRig.CAMERA_RIG_GROUP)
	# Стартовая позиция proxy = центр зоны. Чтобы первое включение фокуса
	# не телепортировало камеру из (0,0,0) до фактического centroid'а в
	# первом кадре после _process — там lerp уже доедет плавно с разумной
	# стартовой точки.
	var proxy := get_node_or_null("CentroidProxy") as Node3D
	if proxy != null:
		proxy.global_position = global_position


## Синхронизирует размер BoxShape3D и BoxMesh с экспортом `size`, и прячет
## зелёный visual-куб в рантайме (виден только в редакторе — для дизайнера).
## Зовётся из setter и из _ready.
func _refresh_visual() -> void:
	var mesh := get_node_or_null("Mesh") as MeshInstance3D
	if mesh != null:
		mesh.scale = size
		mesh.visible = Engine.is_editor_hint()
	var shape_node := get_node_or_null("Area3D/CollisionShape3D") as CollisionShape3D
	if shape_node != null:
		var box := shape_node.shape as BoxShape3D
		if box != null:
			box.size = size


func _on_body_entered(body: Node) -> void:
	if not body.is_in_group(SoldierGnome.SOLDIER_GROUP):
		return
	if body in _members:
		return
	var was_empty := _members.is_empty()
	_members.append(body as Node3D)
	if was_empty and _camera_rig != null:
		var proxy := get_node_or_null("CentroidProxy") as Node3D
		if proxy != null:
			_camera_rig.set_focus_override(proxy)


func _on_body_exited(body: Node) -> void:
	if not (body is Node3D):
		return
	_members.erase(body)
	if _members.is_empty() and _camera_rig != null:
		_camera_rig.clear_focus_override()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# Чистим freed-ссылки: солдат мог умереть внутри зоны, body_exited
	# для queue_free'нутого узла иногда приходит на следующем физкадре,
	# camera-флип хочется СРАЗУ, не через тик.
	var was_non_empty := not _members.is_empty()
	var i := _members.size() - 1
	while i >= 0:
		if not is_instance_valid(_members[i]):
			_members.remove_at(i)
		i -= 1
	if _members.is_empty():
		if was_non_empty and _camera_rig != null:
			_camera_rig.clear_focus_override()
		return
	# Centroid X/Z живых солдат. Y proxy = Y зоны — данж на том же уровне
	# что и зона (горизонтальный, не подвал). Камера держит свой обычный
	# угол/зум, просто следит за точкой посреди солдат.
	var proxy := get_node_or_null("CentroidProxy") as Node3D
	if proxy == null:
		return
	var sum := Vector3.ZERO
	for m in _members:
		sum += (m as Node3D).global_position
	var c: Vector3 = sum / float(_members.size())
	proxy.global_position = Vector3(c.x, global_position.y, c.z)
