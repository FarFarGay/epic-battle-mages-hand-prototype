class_name GearElement
extends RelayItem
## Шестерня — элемент механизма Врат из «Подземелья гномов» (§5.27.2, комната
## В): лежит в конце лабиринта «под гнома» — башня в проём не пролезает, рука
## с дистанции не дотягивается. Добыча АРТЕЛЬЮ: гном-рабочий, оказавшись рядом
## (игрок командует «Идти сюда» в лабиринт), взваливает шестерню на голову и
## несёт КУДА ИДЁТ сам (никакого автопилота — движением рулят обычные команды
## отряда); у башни скидывает. Дальше стандартный путь [RelayItem]: рука несёт
## и вставляет в гнездо Врат.
##
## Grab / сокет-снап / вспышка тока — целиком от [RelayItem]; здесь только
## визуал шестерни вместо кристалла и слой «гном-носильщик»: поллинг 0.3с
## (сигналов «гном дошёл» нет, и они тут не нужны — [[feedback_no_redundant_signals]]).

## Радиус, в котором гном-рабочий подхватывает шестерню.
@export var pickup_radius: float = 1.8
## Ближе этого до башни носильщик скидывает груз; и подбор запрещён —
## башня рядом значит рука дотянется сама.
@export var tower_drop_radius: float = 7.0
@export var carry_height: float = 1.7

var _carrier: Node3D = null
var _held_by_hand: bool = false


func _ready() -> void:
	super()
	mass = 8.0
	var poll := Timer.new()
	poll.wait_time = 0.3
	poll.autostart = true
	add_child(poll)
	poll.timeout.connect(_poll_carry)


## Шестерня: плоский диск + втулка + 6 зубьев по ободу. Один материал на всё —
## highlight/вспышка тока от RelayItem красят весь элемент разом.
func _build_visual() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.72, 0.55, 0.28)
	_material.metallic = 0.6
	_material.roughness = 0.45
	_material.emission_enabled = true
	_material.emission = crystal_color
	_material.emission_energy_multiplier = 1.2
	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.55
	cyl.bottom_radius = 0.55
	cyl.height = 0.22
	disc.mesh = cyl
	disc.material_override = _material
	add_child(disc)
	var hub := MeshInstance3D.new()
	var hub_mesh := CylinderMesh.new()
	hub_mesh.top_radius = 0.18
	hub_mesh.bottom_radius = 0.18
	hub_mesh.height = 0.34
	hub.mesh = hub_mesh
	hub.material_override = _material
	add_child(hub)
	for i in 6:
		var tooth := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.22, 0.2, 0.22)
		tooth.mesh = box
		tooth.material_override = _material
		var ang: float = TAU * i / 6.0
		tooth.position = Vector3(cos(ang), 0.0, sin(ang)) * 0.62
		tooth.rotation.y = -ang
		add_child(tooth)
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.72
	shape.height = 0.34
	col.shape = shape
	add_child(col)


func _physics_process(_delta: float) -> void:
	if _carrier != null and is_instance_valid(_carrier):
		global_position = _carrier.global_position + Vector3.UP * carry_height


## Носильщик: подбор ближайшим гномом-рабочим / сброс у башни.
func _poll_carry() -> void:
	if _held_by_hand or is_seated_in_socket():
		return
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	if _carrier != null:
		if not is_instance_valid(_carrier):
			_drop()
		elif tower != null and _xz_dist(tower.global_position, global_position) <= tower_drop_radius:
			_drop()
			EventBus.tutorial_hint.emit("Гном донёс шестерню! Хватай рукой и неси в гнездо Врат", 7.0)
		return
	# Свободна: башня рядом — рука дотянется сама, гномов не дёргаем.
	if tower != null and _xz_dist(tower.global_position, global_position) <= tower_drop_radius:
		return
	var worker := _nearest_worker()
	if worker != null and _xz_dist(worker.global_position, global_position) <= pickup_radius:
		_attach(worker)


func is_seated_in_socket() -> bool:
	return _socket != null


func _attach(worker: Node3D) -> void:
	_carrier = worker
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_layer = Layers.MOUNTED_MODULE  # рука видит — можно выхватить с головы
	AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position, 0.8, 6.0)
	EventBus.tutorial_hint.emit("Гном взвалил шестерню — выведи его к башне", 7.0)


func _drop() -> void:
	_carrier = null
	freeze = false
	collision_layer = Layers.ITEMS


func _nearest_worker() -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group(SoldierGnome.SOLDIER_GROUP):
		var s := n as Node3D
		if s == null or not is_instance_valid(s):
			continue
		if s.get(&"soldier_type") != SoldierSystem.ROLE_WORKER:
			continue
		var d: float = s.global_position.distance_squared_to(global_position)
		if d < best_d:
			best_d = d
			best = s
	return best


func _xz_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Рука выхватила (в т.ч. с головы носильщика) — гном свободен.
func _on_hand_grabbed(item: Node3D) -> void:
	if item == self:
		_carrier = null
		_held_by_hand = true
	super(item)


func _on_hand_released(item: Node3D, velocity: Vector3) -> void:
	if item == self:
		_held_by_hand = false
	super(item, velocity)
