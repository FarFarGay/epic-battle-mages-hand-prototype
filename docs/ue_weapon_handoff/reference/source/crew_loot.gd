extends Node3D
## Port of dungeon_sandbox's E cargo, sticky haulers and physical coin magnet.
const Geo = preload("res://scripts/geo.gd")
var crew
var arena
var coins := 0
var supplies := 0
var cargo: RigidBody3D
var haulers: Array = []
var items: Array[RigidBody3D] = []
var chests: Array[Dictionary] = []
var loose_coins: Array[RigidBody3D] = []
var coin_sound_cd := 0.0
var gold := Geo.material(Color("edbb63"), 0.7, 0.5)
var wood := Geo.material(Color("705640"))
var iron := Geo.material(Color("53656a"), 0.6)

func reset() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	items.clear()
	chests.clear()
	loose_coins.clear()
	cargo = null
	haulers.clear()
	coins = 0
	supplies = 0
	for pos in [Vector3(7, 0, 10), Vector3(-5, 0, 7), Vector3(15, 0, -8)]:
		spawn_cargo(pos, 1 if items.is_empty() else 3)
	for pos in [Vector3(10, 0, 4), Vector3(-11, 0, 5), Vector3(-2, 0, -19)]:
		_spawn_chest(pos)
	for i in 9:
		spawn_coin(Vector3(5.8 + i * 0.55, 0.4, 8.2), Vector3.ZERO)

func _marker(parent: Node3D, text: String, height: float) -> Label3D:
	var label := Label3D.new()
	parent.add_child(label)
	label.name = "Marker"
	label.text = text
	label.position.y = height
	label.font_size = 38
	label.pixel_size = 0.009
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color("eac992")
	return label

func spawn_cargo(pos: Vector3, need: int) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Cargo_%d" % items.size()
	body.collision_layer = 8
	body.collision_mask = 9
	body.mass = float(need) * 2.0
	body.linear_damp = 1.6
	body.angular_damp = 2.0
	add_child(body)
	body.position = pos + Vector3.UP * 0.48
	var side := 0.75 if need == 1 else 1.12
	Geo.collider(body, Vector3.ONE * side, Vector3.ZERO)
	Geo.box(body, Vector3.ONE * side, Vector3.ZERO, wood)
	for x in [-1, 1]:
		Geo.box(body, Vector3(0.10, side + 0.025, side + 0.025), Vector3(x * side * 0.3, 0, 0), iron)
	Geo.box(body, Vector3(0.32, 0.26, 0.035), Vector3(0, 0, -side * 0.51), gold)
	body.set_meta("need", need)
	_marker(body, "[E]  ГРУЗ · %d гном." % need, side * 0.5 + 0.42)
	items.append(body)
	return body

func _spawn_chest(pos: Vector3) -> void:
	var root := StaticBody3D.new()
	add_child(root)
	root.position = pos
	root.collision_layer = 8
	Geo.collider(root, Vector3(1.15, 0.65, 0.80), Vector3.UP * 0.325)
	Geo.box(root, Vector3(1.15, 0.60, 0.80), Vector3.UP * 0.33, wood)
	for x in [-0.43, 0.43]:
		Geo.box(root, Vector3(0.12, 0.66, 0.86), Vector3(x, 0.33, 0), gold)
	var lid := Node3D.new()
	root.add_child(lid)
	lid.position = Vector3(0, 0.65, 0.4)
	Geo.box(lid, Vector3(1.2, 0.20, 0.88), Vector3(0, 0, -0.4), iron)
	Geo.box(root, Vector3(0.2, 0.25, 0.08), Vector3(0, 0.60, -0.45), gold)
	_marker(root, "[E]  СУНДУК", 1.40)
	chests.append({"node": root, "lid": lid, "opened": false})

func nearest_interaction(pos: Vector3) -> Dictionary:
	var best := {}
	var distance := 4.0
	for item in items:
		if item == cargo: continue
		var d := Vector2(pos.x - item.position.x, pos.z - item.position.z).length()
		if d < distance and _los(pos + Vector3.UP * 0.8, item.position):
			distance = d
			best = {"kind": "cargo", "node": item, "text": "E  ПОДНЯТЬ ГРУЗ · %d гном." % int(item.get_meta("need"))}
	for chest in chests:
		if chest.opened: continue
		var d: float = Vector2(pos.x - chest.node.position.x, pos.z - chest.node.position.z).length()
		if d < minf(distance, 3.0) and _los(pos + Vector3.UP * 0.8, chest.node.position + Vector3.UP * 0.5):
			distance = d
			best = {"kind": "chest", "entry": chest, "text": "E  ОТКРЫТЬ СУНДУК"}
	return best

func _los(from: Vector3, to: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to, 3)
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()

func pickup_cargo(item: RigidBody3D) -> bool:
	if crew.crewed or crew.members.is_empty() or cargo != null or not items.has(item): return false
	var c: Vector3 = crew.center()
	if Vector2(c.x - item.position.x, c.z - item.position.z).length() > 4.0 or not _los(c + Vector3.UP * 0.8, item.position): return false
	var need: int = item.get_meta("need")
	if crew.members.size() < need:
		crew.tell("Для груза нужно %d гномов" % need)
		return false
	var free: Array = crew.members.duplicate()
	free.sort_custom(func(a, b): return a.global_position.distance_squared_to(item.position) < b.global_position.distance_squared_to(item.position))
	haulers.clear()
	for i in need:
		free[i].hauling = true
		haulers.append(free[i])
	cargo = item
	cargo.freeze = true
	cargo.linear_velocity = Vector3.ZERO
	cargo.angular_velocity = Vector3.ZERO
	cargo.collision_layer = 0
	cargo.collision_mask = 0
	cargo.rotation = Vector3.ZERO
	cargo.get_node("Marker").hide()
	arena.sound.play("lock", -11.0, 1.4)
	crew.tell("Груз несут %d гном. · E / Q — опустить · у башни E — погрузить" % need)
	return true

func drop_cargo() -> void:
	if cargo == null: return
	var toss := Vector3.ZERO
	for member in haulers:
		member.hauling = false
		toss += Vector3(member.velocity.x, 0, member.velocity.z)
	toss /= maxf(haulers.size(), 1)
	cargo.collision_layer = 8
	cargo.collision_mask = 9
	cargo.freeze = false
	cargo.sleeping = false
	cargo.linear_velocity = toss + Vector3.UP * 2.0
	cargo.angular_velocity = Vector3(0.6, 1.0, 0.3)
	cargo.get_node("Marker").show()
	cargo = null
	haulers.clear()
	crew.tell("Груз опущен")

func store_cargo() -> void:
	if cargo == null: return
	supplies += int(cargo.get_meta("need"))
	for member in haulers: member.hauling = false
	haulers.clear()
	items.erase(cargo)
	cargo.queue_free()
	cargo = null
	arena.sound.play("pickup", -4.0, 0.85)

func open_chest(chest: Dictionary) -> bool:
	if crew.crewed or crew.members.is_empty() or chest.opened: return false
	var pos: Vector3 = chest.node.position
	if crew.center().distance_to(pos) > 3.1 or not _los(crew.center() + Vector3.UP * 0.8, pos + Vector3.UP * 0.5): return false
	chest.opened = true
	chest.node.get_node("Marker").hide()
	var tween := create_tween()
	tween.tween_property(chest.lid, "rotation:x", 1.9, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	for i in 12:
		var angle := i * TAU / 12.0
		var out := Vector3(cos(angle), 0, sin(angle))
		spawn_coin(pos + Vector3.UP * 0.9 + out * 0.3, out * 3.2 + Vector3.UP * 4.0)
	arena.sound.play("eject", -7.0, 0.8)
	crew.tell("Сундук открыт — монеты подбираются на ходу")
	return true

func spawn_coin(pos: Vector3, impulse: Vector3) -> void:
	if loose_coins.size() >= 180: return
	var coin := RigidBody3D.new()
	coin.collision_layer = 0
	coin.collision_mask = 1
	coin.mass = 0.15
	coin.linear_damp = 1.0
	coin.angular_damp = 1.5
	var collider := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.12
	collider.shape = shape
	coin.add_child(collider)
	var physics := PhysicsMaterial.new()
	physics.bounce = 0.3
	coin.physics_material_override = physics
	add_child(coin)
	coin.position = pos
	var mesh := Geo.cylinder(coin, 0.17, 0.07, Vector3.ZERO, gold, 10)
	mesh.rotation.x = PI / 2.0
	coin.linear_velocity = impulse
	coin.angular_velocity = Vector3(3, 5, 2)
	loose_coins.append(coin)

func tick(dt: float) -> void:
	coin_sound_cd = maxf(0.0, coin_sound_cd - dt)
	var player: Vector3 = crew.center()
	var alive: bool = not crew.members.is_empty()
	for item in items:
		item.get_node("Marker").visible = alive and not crew.crewed and item != cargo and item.position.distance_to(player) < 8.0
	for chest in chests:
		chest.node.get_node("Marker").visible = alive and not crew.crewed and not chest.opened and chest.node.position.distance_to(player) < 8.0
	if cargo != null and not haulers.is_empty():
		var c := Vector3.ZERO
		for member in haulers: c += member.global_position
		c /= haulers.size()
		cargo.global_position = Vector3(c.x, 1.5, c.z)
	# As in the dungeon, both the squad and the occupied tower collect coins.
	var target: Vector3 = crew.center()
	target.y = 0.8
	for i in range(loose_coins.size() - 1, -1, -1):
		var coin := loose_coins[i]
		if not alive:
			coin.gravity_scale = 1.0
			continue
		var offset := target - coin.position
		var ray := PhysicsRayQueryParameters3D.create(coin.position, target, 1)
		if Vector2(offset.x, offset.z).length() > 3.2 or not get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			coin.gravity_scale = 1.0
			continue
		if offset.length() < 0.65:
			coins += 1
			loose_coins.remove_at(i)
			coin.queue_free()
			if coin_sound_cd <= 0.0:
				arena.sound.play("pickup", -10.0, 1.0 + (coins % 5) * 0.08)
				coin_sound_cd = 0.08
			continue
		coin.sleeping = false
		coin.gravity_scale = 0.0
		coin.linear_velocity = coin.linear_velocity.move_toward(offset.normalized() * 11.0, 42.0 * dt)
