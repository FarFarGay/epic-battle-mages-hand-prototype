extends Node3D
## A small reversible socket/gate fixture, following the original relay/mount contract.
const Geo = preload("res://scripts/geo.gd")
const HandObject = preload("res://scripts/hand_object.gd")
var arena
var hand
var cube: RigidBody3D
var seated := false
var opened := false
var socket_position := Vector3(18, 0, 14)
var gate_position := Vector3(22, 0, 4)
var gate: StaticBody3D
var bars: Node3D
var lamp: MeshInstance3D
var label: Label3D
var live := Geo.material(Color("71d9c8"), 0.3, 1.4)
var idle := Geo.material(Color("d39348"), 0.4, 0.5)

func _ready() -> void:
	name = "HandPuzzle"
	var stone := Geo.material(Color("676277"), 0.2)
	var iron := Geo.material(Color("34464a"), 0.7)
	Geo.cylinder(self, 1.15, 0.25, socket_position + Vector3.UP * 0.125, stone)
	Geo.ring(self, 0.74, 0.12, socket_position + Vector3.UP * 0.3, idle)
	lamp = Geo.sphere(self, 0.15, socket_position + Vector3(1.1, 0.35, 0), idle)
	Geo.line(self, socket_position + Vector3.UP * 0.06, gate_position + Vector3.UP * 0.06, 0.05, idle)
	gate = StaticBody3D.new()
	add_child(gate)
	gate.position = gate_position
	gate.collision_layer = 1
	Geo.collider(gate, Vector3(6, 8.4, 0.45), Vector3.UP * 4.2)
	bars = Node3D.new()
	gate.add_child(bars)
	for x in range(-3, 4): Geo.box(bars, Vector3(0.12, 7.8, 0.18), Vector3(x * 0.85, 3.9, 0), iron)
	for y in [0.5, 3.4, 7.7]: Geo.box(bars, Vector3(5.5, 0.15, 0.24), Vector3(0, y, 0), iron)
	for side in [-1, 1]:
		var post := StaticBody3D.new()
		add_child(post)
		post.position = gate_position + Vector3(side * 3.35, 0, 0)
		Geo.collider(post, Vector3(0.6, 8.4, 0.9), Vector3.UP * 4.2)
		Geo.box(post, Vector3(0.6, 8.4, 0.9), Vector3.UP * 4.2, stone)
	Geo.box(self, Vector3(7.3, 0.4, 1.0), gate_position + Vector3.UP * 8.4, stone)
	label = arena.crew.loot._marker(self, "", 0)
	label.position = socket_position + Vector3(0, 2.4, 0)
	label.font_size = 32
	reset()

func reset() -> void:
	if is_instance_valid(cube):
		cube.collision_layer = 0
		cube.queue_free()
	seated = false
	_set_open(false)
	bars.position.y = 0
	bars.scale.y = 1.0
	cube = HandObject.new()
	cube.arena = arena
	add_child(cube)
	cube.name = "RelayCube"
	cube.position = Vector3(14, 0.65, 14)
	cube.mass = 4.0
	cube.collision_layer = 8
	cube.collision_mask = 9
	cube.linear_damp = 1.6
	cube.angular_damp = 2.0
	Geo.collider(cube, Vector3.ONE * 0.9, Vector3.ZERO)
	Geo.box(cube, Vector3.ONE * 0.9, Vector3.ZERO, Geo.material(Color("454355"), 0.5))
	for side in [-1, 1]:
		Geo.box(cube, Vector3(0.06, 0.55, 0.55), Vector3(side * 0.46, 0, 0), live)
		Geo.box(cube, Vector3(0.55, 0.55, 0.06), Vector3(0, 0, side * 0.46), live)
	Geo.sphere(cube, 0.22, Vector3(0, 0.47, 0), live)
	hand.register_item(cube, Vector3.ONE * 0.9, "СИЛОВОЙ КУБ")
	arena.crew.loot._marker(cube, "F · РУКА\nСИЛОВОЙ КУБ", 1.3).font_size = 32
	_update_label()

func seat_position() -> Vector3:
	return socket_position + Vector3.UP * 0.76

func seat(body: RigidBody3D) -> void:
	if body != cube: return
	seated = true
	body.set_meta("hand_owner", "socket")
	body.freeze = true
	body.collision_layer = hand.HELD_LAYER
	body.collision_mask = 0
	body.global_position = seat_position()
	body.rotation = Vector3.ZERO
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	arena.sound.play("lock", -3.0, 0.8)
	arena.fx.ring(socket_position + Vector3.UP * 0.3, 0.8, arena.fx.dash_mat)
	arena.crew.tell("Куб в гнезде — ворота открыты. Можно вынуть его и увезти на башне")
	_set_open(true)

func unseat(body: RigidBody3D) -> void:
	if body != cube or not seated: return
	seated = false
	_update_label()

func _gate_occupied() -> bool:
	var bodies: Array = [arena.tank]
	bodies.append_array(arena.crew.members if not arena.crew.crewed else [])
	if arena.battle: bodies.append_array(arena.battle.enemies)
	for body in bodies:
		var delta: Vector3 = body.global_position - gate_position
		if absf(delta.x) < 4.7 and absf(delta.z) < 1.8: return true
	return false

func _set_open(value: bool) -> void:
	opened = value
	if gate: gate.collision_layer = 0 if value else 1
	if lamp: lamp.material_override = live if value else idle
	if arena.battle: arena.battle.nav_dirty = true
	_update_label()

func _update_label() -> void:
	if label: label.text = "ГНЕЗДО · КУБ УСТАНОВЛЕН" if seated else "ГНЕЗДО · ПОЛОЖИ КУБ"

func tick(dt: float) -> void:
	if is_instance_valid(cube): cube.get_node("Marker").visible = not cube.has_meta("hand_owner")
	if seated and not is_instance_valid(cube): seated = false
	if seated:
		cube.global_position = seat_position()
	elif opened and not _gate_occupied():
		_set_open(false)
		arena.sound.play("chamber", -8.0, 0.65)
	bars.position.y = move_toward(bars.position.y, 8.2 if opened else 0.0, dt * 11.0)
	bars.scale.y = maxf(0.025, 1.0 - bars.position.y / 8.4)
