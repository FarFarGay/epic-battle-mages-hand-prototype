extends Node3D
## Uses the same carry / release / socket contract as the original range fixture.
const Geo = preload("res://scripts/geo.gd")
const HandObject = preload("res://scripts/hand_object.gd")
var arena
var hand
var cube: RigidBody3D
var seated := false
var opened := false
var socket_position := Vector3(-133,0,0)
var marker: MeshInstance3D
var label: Label3D
const DROP_ZONE := Rect2(-5,-3,10,6)
var idle_mat := Geo.material(Color(0.22,0.7,0.68,0.3))
var ready_mat := Geo.material(Color(0.95,0.72,0.22,0.65))

func _ready() -> void:
	# A picking-only plane lets the cursor target the future deck over the void.
	var dock := StaticBody3D.new()
	add_child(dock)
	dock.position = socket_position
	dock.collision_layer = 512
	dock.collision_mask = 0
	Geo.collider(dock,Vector3(10,0.06,6),Vector3.ZERO)
	idle_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ready_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	marker = Geo.box(self,Vector3(10,0.04,6),socket_position+Vector3.UP*0.04,idle_mat)
	Geo.mark_ui(marker)
	label = arena.crew.loot._marker(self,"ПЕРЕНЕСИ СЕКЦИЮ НА РАЗМЕТКУ",0)
	label.position = socket_position+Vector3.UP*1.8
	label.pixel_size = 0.011
	label.no_depth_test = true
	reset()

func reset() -> void:
	if is_instance_valid(cube):
		cube.collision_layer = 0
		cube.queue_free()
	seated = false
	opened = false
	arena.level.set_bridge(false)
	cube = HandObject.new()
	cube.arena = arena
	add_child(cube)
	cube.position = Vector3(-147,0.5,-6.5)
	cube.mass = 8.0
	cube.collision_layer = 8
	cube.collision_mask = 9
	cube.freeze = true
	Geo.collider(cube,Vector3(3.2,0.8,2.5),Vector3.ZERO)
	var steel := Geo.material(Color("658f90"))
	for i in 3: Geo.box(cube,Vector3(3.2,0.18,2.5),Vector3(0,(i-1)*0.28,0),steel)
	hand.register_item(cube,Vector3(3.2,0.8,2.5),"СЛОЖЕННАЯ СЕКЦИЯ МОСТА")
	arena.crew.loot._marker(cube,"F · РУКА\nСЕКЦИЯ МОСТА",1.4)
	marker.show()
	label.show()

func seat_position() -> Vector3:
	return socket_position+Vector3.UP*0.5

func can_snap(body: PhysicsBody3D, surface: Vector3) -> bool:
	if body != cube or opened: return false
	# The entire visible deck accepts the drop, including its banks. The palm's
	# projection offsets the carried section, so do not compare it to a tiny socket.
	var pointer := Vector2(surface.x-socket_position.x,surface.z-socket_position.z)
	if not DROP_ZONE.grow(0.35).has_point(pointer): return false
	var carried := Vector2(body.global_position.x-socket_position.x,body.global_position.z-socket_position.z)
	var closest := carried.clamp(DROP_ZONE.position,DROP_ZONE.end)
	if carried.distance_to(closest)>4.0 or absf(body.global_position.y-seat_position().y)>4.0: return false
	return hand._clear_line(hand._center(body),seat_position(),body)

func seat(body: RigidBody3D) -> void:
	if body != cube: return
	seated = true
	opened = true
	body.set_meta("hand_owner","bridge")
	body.freeze = true
	body.collision_layer = 0
	body.collision_mask = 0
	body.position = seat_position()
	body.hide()
	marker.hide()
	label.hide()
	arena.level.set_bridge(true)
	arena.sound.play("lock",-2.0,0.7)
	arena.crew.tell("Мост установлен · проезжай в пустыню · G — схема локации")

func unseat(_body: RigidBody3D) -> void:
	pass # Deployed bridge stays latched until the level is reset.

func tick(_dt: float) -> void:
	if is_instance_valid(cube) and not opened and not cube.has_meta("hand_owner") and cube.position.y < -1.5:
		reset()
		arena.crew.tell("Секция упала в пропасть — вернул её на берег. Перенеси на разметку и отпусти ЛКМ")
	var near: bool = arena.crew.center().distance_to(socket_position) < 45.0
	marker.visible = near and not opened
	label.visible = near and not opened
	var ready: bool = hand.held == cube and hand.cursor_valid and can_snap(cube,hand.cursor_surface)
	marker.material_override = ready_mat if ready else idle_mat
	label.text = "ОТПУСТИ ЛКМ — УСТАНОВИТЬ МОСТ" if ready else "ПЕРЕНЕСИ СЕКЦИЮ НА РАЗМЕТКУ\nИ ОТПУСТИ ЛКМ"
	if is_instance_valid(cube): cube.get_node("Marker").visible = near and not cube.has_meta("hand_owner")
