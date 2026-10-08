extends Node3D
## Standalone port of hand_physical.gd + mount_slot.gd: drag, release, roof cargo.
## F selects this input context; weapon projectiles/reloads remain independent.
const Geo = preload("res://scripts/geo.gd")
const Puzzle = preload("res://scripts/hand_puzzle.gd")
const ITEM_GROUP := &"tower_hand_item"
const HELD_LAYER := 128
const PICK_MASK := 1 | 8 | 16 | 32 | 64 | HELD_LAYER | 512
const MAX_MASS := 10.0
const REACH := 18.0
const GRAB_RADIUS := 1.5
const CARGO_SNAP_RADIUS := 2.5
var arena
var enabled := false
var held: PhysicsBody3D
var mounted: RigidBody3D
var candidate: Node3D
var puzzle
var rack: Node3D
var hand_mesh: Node3D
var fingers: Array[Node3D] = []
var marker: MeshInstance3D
var cursor_surface := Vector3.ZERO
var cursor_world := Vector3.ZERO
var cursor_valid := false
var grab_pressed := false
var grab_requested := false
var grab_age := 0.0
var release_requested := false
var gentle_release := false
var velocity_history: Array[Vector3] = []
var previous_cursor := Vector3.ZERO
var cursor_initialized := false
var snap_destination := ""
var test_pointer := Vector2.INF
var teal := Geo.material(Color("71d9c8"), 0.25, 0.6)
var gold := Geo.material(Color("edb96d"), 0.35, 0.4)

func _ready() -> void:
	name = "TowerHand"
	rack = Node3D.new()
	rack.name = "CargoAnchor"
	arena.tank.turret.add_child(rack)
	rack.position = Vector3(0, 1.50, 0.30)
	_build_hand()
	puzzle = load("res://scripts/level_bridge.gd").new() if arena.level else Puzzle.new()
	puzzle.arena = arena
	puzzle.hand = self
	add_child(puzzle)
	_show(false)

static func register_item(body: PhysicsBody3D, size: Vector3, label: String, center: Vector3 = Vector3.ZERO) -> void:
	body.add_to_group(ITEM_GROUP)
	body.set_meta("hand_size", size)
	body.set_meta("hand_label", label)
	body.set_meta("hand_center", center)
	body.set_meta("hand_home", body.global_position)
	body.set_meta("hand_free_layer", body.collision_layer)
	body.set_meta("hand_free_mask", body.collision_mask)
	if body is RigidBody3D:
		body.set_meta("hand_free_mode", body.freeze_mode)
		body.continuous_cd = true

func _build_hand() -> void:
	hand_mesh = Node3D.new()
	add_child(hand_mesh)
	var skin := Geo.material(Color("eadbb9"), 0.25, 0.22)
	Geo.box(hand_mesh, Vector3(0.54, 0.19, 0.58), Vector3.ZERO, skin)
	Geo.box(hand_mesh, Vector3(0.46, 0.23, 0.18), Vector3(0, 0, 0.34), gold)
	for i in 4:
		var finger := Node3D.new()
		hand_mesh.add_child(finger)
		finger.position = Vector3((i - 1.5) * 0.145, 0, -0.24)
		Geo.box(finger, Vector3(0.115, 0.16, 0.38 - absf(i - 1.5) * 0.04), Vector3(0, 0, -0.14), skin)
		Geo.sphere(finger, 0.075, Vector3(0, 0, -0.31), skin)
		fingers.append(finger)
	var thumb := Geo.box(hand_mesh, Vector3(0.17, 0.17, 0.35), Vector3(-0.35, 0, 0.04), skin)
	thumb.rotation.y = -0.6
	hand_mesh.rotation_degrees = Vector3(20, -45, 0)
	marker = Geo.ring(self, 0.8, 0.035, Vector3.ZERO, teal)
	marker.scale.y = 0.1
	Geo.mark_ui(hand_mesh)
	Geo.mark_ui(marker)

func _show(value: bool) -> void:
	hand_mesh.visible = value
	marker.visible = value and cursor_valid

func set_enabled(value: bool) -> void:
	if value and (arena.tank.dead or not arena.crew.crewed or arena.tuning_open): return
	if enabled == value: return
	cancel_drag()
	enabled = value
	arena.tank.buffered_shot = 0.0
	arena.tank.crossbows.cancel_trigger()
	arena.tank.dash.cancel()
	arena.crew.input_armed = false
	cursor_initialized = false
	if arena.hud: arena.hud.reset_reticle()
	_show(value)
	arena.crew.tell("Рука · ЛКМ держать — взять · отпусти у башни — груз / ресурс" if value else "Прицел · ЛКМ — пушка · ПКМ — арбалеты")

func trigger(pressed: bool) -> void:
	if not pressed:
		if grab_pressed or is_instance_valid(held): release_requested = true
		grab_pressed = false
		return
	if not _can_use(): return
	grab_pressed = true
	grab_requested = true
	grab_age = 0.0

func place_gently() -> void:
	grab_pressed = false
	grab_requested = false
	release_requested = true
	gentle_release = true

func _can_use() -> bool:
	return enabled and arena.crew.crewed and not arena.tank.dead and arena.crew.input_armed and not arena.tuning_open and not arena.pointer_over_ui() and not arena.tank.dash.active and not arena.tank.dash.is_aiming()

func cancel_drag() -> void:
	grab_pressed = false
	grab_requested = false
	release_requested = false
	gentle_release = false
	_release(true, false)
	candidate = null
	snap_destination = ""
	velocity_history.clear()
	cursor_initialized = false

func reset() -> void:
	cancel_drag()
	_drop_mounted()
	enabled = false
	test_pointer = Vector2.INF
	_show(false)
	puzzle.reset()

func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func _center(body: Node3D) -> Vector3:
	return body.to_global(body.get_meta("hand_center", Vector3.ZERO))

func _clear_line(from: Vector3, to: Vector3, ignore: PhysicsBody3D = null) -> bool:
	if from.distance_squared_to(to) < 0.001: return true
	var ray := PhysicsRayQueryParameters3D.create(from, to, 1)
	ray.hit_from_inside = true
	if ignore: ray.exclude = [ignore.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()

func can_reach(node: Node3D) -> bool:
	return is_instance_valid(node) and _flat_distance(arena.tank.global_position, _center(node)) <= REACH and _clear_line(arena.tank.global_position + Vector3.UP * (5.8 if arena.level else 3.0), _center(node) + Vector3.UP * 0.3, node as PhysicsBody3D)

func _available(body: Node3D) -> bool:
	if not is_instance_valid(body) or body.is_queued_for_deletion() or not body is PhysicsBody3D or not body.is_in_group(ITEM_GROUP): return false
	if body.get_meta("broken", false): return false
	if body.has_method("can_hand_grab") and not body.can_hand_grab(): return false
	var mass: float = body.mass if body is RigidBody3D else 6.0
	return body != arena.crew.loot.cargo and mass < MAX_MASS and can_reach(body)

func update_pointer(pointer: Vector2) -> void:
	var origin: Vector3 = arena.aim_camera.project_ray_origin(pointer)
	var direction: Vector3 = arena.aim_camera.project_ray_normal(pointer)
	var ray := PhysicsRayQueryParameters3D.create(origin, origin + direction * 180.0, PICK_MASK)
	if is_instance_valid(held): ray.exclude = [held.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	# Foreground scenery may cover an item on screen while the tower can reach it.
	# Pick items separately; can_reach still rejects a wall between tower and item.
	if not is_instance_valid(held):
		var pick_ray := PhysicsRayQueryParameters3D.create(origin, origin + direction * 180.0, 8 | 16 | 32 | 64 | HELD_LAYER)
		var item_hit := get_world_3d().direct_space_state.intersect_ray(pick_ray)
		if item_hit and _available(item_hit.collider): hit = item_hit
	var plane_hit = arena.terrain_point(origin,direction,512)
	if plane_hit == null:
		cursor_valid = false
		candidate = null
		return
	cursor_surface = plane_hit if is_instance_valid(held) else (hit.position if hit else plane_hit)
	# A second projection, as in Hand._update_cursor_world, keeps the palm at the cursor.
	var palm_hit = Plane(Vector3.UP, cursor_surface.y + 2.5).intersects_ray(origin, direction)
	cursor_world = palm_hit if palm_hit != null else cursor_surface + Vector3.UP * 2.5
	cursor_valid = _flat_distance(cursor_surface, arena.tank.global_position) <= REACH
	candidate = null
	if not cursor_valid or is_instance_valid(held): return
	if hit and _available(hit.collider):
		candidate = hit.collider
	else:
		var best := GRAB_RADIUS
		for body in get_tree().get_nodes_in_group(ITEM_GROUP):
			if not _available(body): continue
			var distance: float = _flat_distance(body.global_position, cursor_surface)
			if distance < best and absf(body.global_position.y - cursor_surface.y) < 2.5:
				best = distance
				candidate = body
		if candidate == null and hit:
			for chest in arena.crew.loot.chests:
				if hit.collider == chest.node and not chest.opened and can_reach(chest.node): candidate = chest.node

func tick(dt: float) -> void:
	if arena.tank.dead:
		set_enabled(false)
		_drop_mounted()
	elif not arena.crew.crewed:
		set_enabled(false)
	_tick_mounted()
	puzzle.tick(dt)
	if not enabled:
		_show(false)
		return
	if arena.defenses and arena.defenses.mode!=arena.defenses.Mode.IDLE:
		_show(false)
		return
	if arena.tuning_open or arena.tank.dash.active or arena.tank.dash.is_aiming():
		cancel_drag()
		_show(false)
		return
	if arena.camera_rotating:
		# Orbiting moves only the camera; a held object stays at its world position.
		velocity_history.clear()
		cursor_initialized = false
		if release_requested:
			_release(true, false)
			release_requested = false
			gentle_release = false
		_show(false)
		return
	update_pointer(test_pointer if test_pointer.is_finite() else get_viewport().get_mouse_position())
	if cursor_initialized:
		velocity_history.append((cursor_world - previous_cursor) / maxf(dt, 0.001))
		if velocity_history.size() > 6: velocity_history.pop_front()
	previous_cursor = cursor_world
	cursor_initialized = true
	if grab_pressed: grab_age += dt
	if (grab_pressed or grab_requested or (release_requested and not gentle_release)) and _can_use() and not is_instance_valid(held) and is_instance_valid(candidate):
		if candidate.has_meta("chest") and grab_age < 0.18:
			if release_requested:
				for chest in arena.crew.loot.chests:
					if chest.node == candidate: arena.crew.loot.open_chest(chest, true)
		elif candidate is PhysicsBody3D and candidate.is_in_group(ITEM_GROUP):
			grab(candidate)
		else:
			for chest in arena.crew.loot.chests:
				if chest.node == candidate: arena.crew.loot.open_chest(chest, true)
			grab_pressed = false
	grab_requested = false
	if is_instance_valid(held):
		var target := cursor_world + Vector3(0, -1.0, 0)
		var horizontal: Vector3 = target - arena.tank.global_position
		horizontal.y = 0
		if horizontal.length() > REACH:
			horizontal = horizontal.limit_length(REACH)
			target.x = arena.tank.global_position.x + horizontal.x
			target.z = arena.tank.global_position.z + horizontal.z
		# Sweep the whole carried collider instead of teleporting it through scenery.
		if held.has_method("hand_move"): held.hand_move(target)
		else: held.move_and_collide(target - _center(held))
		if held is RigidBody3D:
			held.linear_velocity = Vector3.ZERO
			held.angular_velocity = Vector3.ZERO
		elif held is CharacterBody3D:
			held.velocity = Vector3.ZERO
	else:
		held = null
	if release_requested:
		_release(gentle_release or arena.pointer_over_ui(), not arena.pointer_over_ui())
		release_requested = false
		gentle_release = false
	snap_destination = _snap_destination()
	hand_mesh.global_position = cursor_world
	for finger in fingers: finger.rotation.x = lerpf(finger.rotation.x, 1.15 if held else 0.0, 1.0 - exp(-dt * 20.0))
	marker.global_position = (candidate.global_position if is_instance_valid(candidate) else cursor_surface) + Vector3.UP * 0.06
	marker.scale.x = 1.15 if candidate else 0.7
	marker.scale.z = marker.scale.x
	marker.material_override = gold if snap_destination != "" or is_instance_valid(candidate) else teal
	_show(not arena.pointer_over_ui())

func grab(body: PhysicsBody3D) -> bool:
	if not _can_use() or is_instance_valid(held) or not _available(body): return false
	if mounted == body: mounted = null
	if body == puzzle.cube: puzzle.unseat(body)
	held = body
	body.set_meta("hand_owner", "hand")
	if body.has_method("on_hand_grab"): body.on_hand_grab()
	if body is RigidBody3D:
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.freeze = true
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
	body.collision_layer = HELD_LAYER | int(body.get_meta("hand_free_layer", 8))
	body.collision_mask = 9
	velocity_history.clear()
	if body.has_node("Marker"): body.get_node("Marker").hide()
	arena.sound.play("lock", -9.0, 1.25)
	return true

func _snap_destination() -> String:
	if not is_instance_valid(held) or not cursor_valid: return ""
	if not held is RigidBody3D: return ""
	if held == puzzle.cube:
		if puzzle.has_method("can_snap"):
			if puzzle.can_snap(held,cursor_surface): return "socket"
		elif _flat_distance(cursor_surface, puzzle.socket_position) <= 1.5 and held.global_position.distance_to(puzzle.seat_position()) < 4.0 and _clear_line(_center(held), puzzle.seat_position(), held):
			return "socket"
	if (not is_instance_valid(mounted) or held.get_meta("crystal", false)) and _flat_distance(cursor_surface, arena.tank.global_position) <= CARGO_SNAP_RADIUS and _flat_distance(held.global_position, arena.tank.global_position) <= 4.0 and _clear_line(_center(held), _cargo_position(held), held):
		return "tower"
	return ""

func _cargo_position(body: RigidBody3D) -> Vector3:
	var size: Vector3 = body.get_meta("hand_size", Vector3.ONE)
	var center: Vector3 = body.get_meta("hand_center", Vector3.ZERO)
	return rack.global_position + Vector3.UP * (size.y * 0.5 + 0.06) - body.global_basis * center

func _restore_free(body: PhysicsBody3D) -> void:
	body.remove_meta("hand_owner")
	body.collision_layer = body.get_meta("hand_free_layer", 8)
	body.collision_mask = body.get_meta("hand_free_mask", 9)
	if body is RigidBody3D:
		body.freeze_mode = body.get_meta("hand_free_mode", RigidBody3D.FREEZE_MODE_STATIC)
		body.freeze = false
		body.sleeping = false

func _release(gently: bool, allow_snap: bool) -> void:
	if not is_instance_valid(held):
		held = null
		return
	var destination := _snap_destination() if allow_snap else ""
	var body := held
	held = null
	_restore_free(body)
	if destination == "socket":
		puzzle.seat(body)
	elif destination == "tower":
		if body.get_meta("crystal", false):
			arena.crew.loot.deposit_crystal(body)
			velocity_history.clear()
			snap_destination = ""
			arena.crew.tell("Кристалл втягивается в башню")
			return
		mounted = body as RigidBody3D
		body.set_meta("hand_owner", "tower")
		mounted.freeze = true
		body.collision_layer = HELD_LAYER | int(body.get_meta("hand_free_layer", 8))
		body.collision_mask = 0
		_tick_mounted()
		arena.sound.play("lock", -4.0, 0.9)
		arena.fx.ring(rack.global_position, 0.7, arena.fx.dash_mat)
		arena.crew.tell("Груз закреплён на башне. F — в бой; схвати груз рукой, чтобы снять")
	else:
		var motion := Vector3.ZERO
		for sample in velocity_history: motion += sample
		motion /= maxf(1.0, velocity_history.size())
		# Original soft release: ordinary placement is not an accidental fast throw.
		var throw_velocity := Vector3.ZERO if gently or motion.length() < 8.0 else (motion * 1.2).limit_length(30.0)
		if body.has_method("on_hand_release"): body.on_hand_release(throw_velocity)
		elif body is RigidBody3D: body.linear_velocity = throw_velocity
		arena.sound.play("eject", -12.0, 1.2)
	velocity_history.clear()
	snap_destination = ""

func _tick_mounted() -> void:
	if not is_instance_valid(mounted):
		mounted = null
		return
	mounted.global_basis = rack.global_basis.orthonormalized()
	mounted.global_position = _cargo_position(mounted)
	mounted.linear_velocity = Vector3.ZERO
	mounted.angular_velocity = Vector3.ZERO

func _drop_mounted() -> void:
	if not is_instance_valid(mounted):
		mounted = null
		return
	var body := mounted
	mounted = null
	_restore_free(body)
	body.linear_velocity = -arena.tank.global_basis.x * 2.5 + Vector3.UP

func status_text() -> String:
	if arena.defenses:
		var building_hint: String = arena.defenses.status_text()
		if not building_hint.is_empty(): return building_hint
	if is_instance_valid(held):
		if snap_destination == "tower": return "ОТПУСТИ ЛКМ — СДАТЬ КРИСТАЛЛ" if held.get_meta("crystal", false) else "ОТПУСТИ ЛКМ — ЗАКРЕПИТЬ НА БАШНЕ"
		if snap_destination == "socket": return "ОТПУСТИ ЛКМ — УСТАНОВИТЬ МОСТ" if arena.level else "ОТПУСТИ ЛКМ — ВСТАВИТЬ В ГНЕЗДО"
		return "ЛКМ — НЕСТИ · ПКМ — АККУРАТНО ОТПУСТИТЬ"
	if is_instance_valid(candidate):
		if candidate.get_meta("hand_owner", "") == "tower": return "ЗАЖМИ ЛКМ — СНЯТЬ ГРУЗ С БАШНИ"
		if candidate == puzzle.cube and puzzle.seated: return "ЗАЖМИ ЛКМ — ВЫНУТЬ КУБ ИЗ ГНЕЗДА"
		if candidate.has_meta("chest"): return "ЛКМ — ОТКРЫТЬ · УДЕРЖИВАТЬ — НЕСТИ СУНДУК"
		return "ЗАЖМИ ЛКМ — ВЗЯТЬ"
	return "ПОДВЕДИ БАШНЮ БЛИЖЕ · РАДИУС 18 М" if not cursor_valid else "НАВЕДИ РУКУ НА ПРЕДМЕТ ИЛИ СКЕЛЕТА"
