extends Node3D
## Adapted from ../scripts/crew_controller.gd and CrewKit: the same four roles,
## camera-relative squad drive, cursor-facing formation and exclusive input owner.
const Gnome = preload("res://scripts/crew_gnome.gd")
const Combat = preload("res://scripts/crew_combat.gd")
const Loot = preload("res://scripts/crew_loot.gd")
const Geo = preload("res://scripts/geo.gd")
const ROSTER := ["pikeman", "pikeman", "archer_squad", "archer_squad", "archer_squad", "worker", "worker", "fire_mage", "fire_mage"]
const BOARD_DISTANCE := 8.0
const MOVE_SPEED := 10.0
const SPACING := 1.35
var arena
var formation_spacing := SPACING
var members: Array[CharacterBody3D] = []
var roster: Array[CharacterBody3D] = []
var crewed := true
var input_armed := true
var motion := Vector3.ZERO
var anchor := Vector3.ZERO
var facing := Vector3.FORWARD
var combat
var loot
var notice := "E — высадить экипаж"
var notice_time := 6.0
var interact_requested := false
var board_requested := false
var drop_requested := false
var board_marker: Label3D
var board_ring: MeshInstance3D

func _ready() -> void:
	name = "GnomeCrew"
	for role in ROSTER:
		var member := Gnome.new()
		member.role = role
		add_child(member)
		members.append(member)
		roster.append(member)
		member.died.connect(_member_died.bind(member))
	combat = Combat.new()
	combat.crew = self
	combat.arena = arena
	add_child(combat)
	loot = Loot.new()
	loot.crew = self
	loot.arena = arena
	add_child(loot)
	board_marker = Label3D.new()
	arena.tank.add_child(board_marker)
	board_marker.position.y = 5.8
	board_marker.font_size = 34
	board_marker.pixel_size = 0.008
	board_marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	board_marker.no_depth_test = true
	board_marker.modulate = Color("71d9c8")
	board_ring = Geo.ring(arena, 2.75, 0.045, Vector3.ZERO, Geo.material(Color("71d9c8"), 0, 0.5))
	board_ring.scale.y = 0.1
	Geo.mark_ui(board_ring)
	reset()

func center() -> Vector3:
	if crewed:
		return arena.tank.global_position
	if members.is_empty(): return anchor
	var result := Vector3.ZERO
	for member in members:
		result += member.global_position
	return result / maxf(members.size(), 1)

func role_count(role: String) -> int:
	return members.filter(func(member): return member.role == role).size()

func _member_died(member: CharacterBody3D) -> void:
	if not members.has(member): return
	var last_center := center()
	if loot.haulers.has(member): loot.drop_cargo()
	loot.drop_crystals(member)
	member.hauling = false
	members.erase(member)
	var corpse: Node3D = member.visual.duplicate()
	arena.fx.add_child(corpse)
	corpse.global_transform = member.visual.global_transform
	arena.fx.add_piece(corpse, member.knockback + Vector3.UP * 3.5, 3.0, 18.0, "piece", Vector3(3, 0, 1.5))
	if members.is_empty():
		anchor = Vector3(last_center.x, 0, last_center.z)
		motion = Vector3.ZERO
		input_armed = false
		tell("Отряд погиб. R — восстановить полигон и экипаж")
	else:
		tell("Гном погиб · осталось %d / 9" % members.size())

func blast(pos: Vector3, radius: float, damage: float) -> void:
	if crewed: return
	# Snapshot: a casualty is removed immediately, even in a barrel chain reaction.
	for member in members.duplicate():
		var offset: Vector3 = member.global_position - pos
		if offset.length() > radius: continue
		offset.y = 0.0
		member.take_damage(damage, offset.normalized())

func tell(message: String) -> void:
	notice = message
	notice_time = 3.5

func reset() -> void:
	crewed = true
	input_armed = false
	motion = Vector3.ZERO
	facing = Vector3.FORWARD
	interact_requested = false
	board_requested = false
	drop_requested = false
	members.assign(roster)
	for member in members:
		member.reset_health()
		member.set_embarked(true)
		member.hauling = false
		member.shot_cooldown = 0.0
		member.global_position = arena.tank.global_position
	combat.reset()
	loot.reset()
	board_marker.hide()
	board_ring.hide()
	tell("E — высадить экипаж")

func tick(dt: float) -> void:
	notice_time = maxf(0.0, notice_time - dt)
	# No held shot may leak across boarding, a UI click, or leaving the cabin.
	if not Input.is_action_pressed("tank_fire") and not Input.is_action_pressed("crew_special") and not Input.is_action_pressed("crew_strike"):
		input_armed = true
	if arena.tuning_open:
		interact_requested = false
		board_requested = false
		drop_requested = false
	else:
		if board_requested:
			if crewed: disembark()
			else: board()
		elif interact_requested:
			interact()
		elif drop_requested and not crewed:
			loot.drop_cargo()
			loot.drop_crystals()
	interact_requested = false
	board_requested = false
	drop_requested = false
	if not crewed and not members.is_empty():
		_drive(dt)
	else:
		for member in members:
			member.global_position = arena.tank.global_position + Vector3.UP * 2.0
			member.shot_cooldown = maxf(0.0, member.shot_cooldown - dt)
	combat.tick(dt)
	loot.tick(dt)
	board_marker.visible = not crewed and not members.is_empty()
	board_ring.visible = board_marker.visible
	if not crewed:
		board_ring.global_position = arena.tank.global_position + Vector3.UP * 0.06
		board_marker.text = "БАШНЯ РАЗБИТА" if arena.tank.dead else ("[E]  В БАШНЮ" if can_board() else "БАШНЯ  ·  %d м" % int(board_distance()))

		if not arena.tank.dead and loot.carried_crystal_count() > 0 and can_board():
			board_marker.text = "[E]  СДАТЬ КРИСТАЛЛЫ"

func _drive(dt: float) -> void:
	var c := center()
	var input := Input.get_vector("tank_left", "tank_right", "tank_forward", "tank_reverse") if not arena.tuning_open else Vector2.ZERO
	var right: Vector3 = arena.aim_camera.global_basis.x
	right.y = 0.0
	right = right.normalized()
	var back: Vector3 = arena.aim_camera.global_basis.z
	back.y = 0.0
	back = back.normalized()
	var desired: Vector3 = (right * input.x + back * input.y) * MOVE_SPEED
	motion = motion.lerp(desired, 1.0 - exp(-dt * (10.0 if input.length_squared() > 0.0 else 6.0)))
	var flat := Vector3(c.x, 0, c.z)
	if anchor.distance_to(flat) > 8.0:
		anchor = flat
	anchor += motion * dt
	anchor = anchor.lerp(flat, 1.0 - exp(-3.0 * dt))
	var look: Vector3 = arena.ground_aim_position - flat
	look.y = 0.0
	if look.length_squared() > 6.25:
		var angle := lerp_angle(atan2(-facing.x, -facing.z), atan2(-look.x, -look.z), 1.0 - exp(-3.5 * dt))
		facing = Vector3(-sin(angle), 0, -cos(angle))
	var positions: Array[Vector3] = []
	for member in members:
		positions.append(member.global_position)
	for i in members.size():
		var member = members[i]
		var slot := anchor + _slot(i, facing)
		var pull := slot - positions[i]
		pull.y = 0.0
		var desired_velocity := motion + (pull * 10.0).limit_length(6.0)
		# Soft separation prevents bunching without locking the group in doorways.
		for j in positions.size():
			if j == i: continue
			var gap := positions[i] - positions[j]
			gap.y = 0.0
			var distance := gap.length()
			if distance > 0.001 and distance < 0.65:
				desired_velocity += gap / distance * (0.65 - distance) * 12.0
		member.tick(dt, desired_velocity, facing, lerpf(16.0, 16.0 * 0.68, i / 8.0))

func _slot(i: int, direction: Vector3) -> Vector3:
	var right := direction.cross(Vector3.UP)
	# Center the surviving formation; an incomplete grid would pull an idle squad.
	var centroid := Vector2.ZERO
	for index in members.size(): centroid += Vector2(index % 3, index / 3)
	centroid /= maxf(members.size(), 1)
	return right * (float(i % 3) - centroid.x) * formation_spacing - direction * (float(i / 3) - centroid.y) * formation_spacing

func board_distance() -> float:
	var offset: Vector3 = center() - arena.tank.global_position
	return Vector2(offset.x, offset.z).length()

func can_board() -> bool:
	if arena.tank.dead or crewed or members.is_empty() or board_distance() > BOARD_DISTANCE:
		return false
	var destination: Vector3 = arena.tank.global_position + Vector3.UP * 0.7
	for member in members:
		if member.global_position.distance_to(arena.tank.global_position) > BOARD_DISTANCE + 2.5:
			return false
		var q := PhysicsRayQueryParameters3D.create(member.global_position + Vector3.UP * 0.7, destination, 1)
		if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			return false
	return true

func _clear_spawn(pos: Vector3) -> bool:
	if not arena.world_bounds.grow(-0.5).has_point(Vector2(pos.x, pos.z)):
		return false
	var shape := CapsuleShape3D.new()
	shape.radius = 0.30
	shape.height = 1.15
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform.origin = pos + Vector3.UP * 0.65
	query.collision_mask = 67
	if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
		return false
	var ray := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.4, pos - Vector3.UP, 1)
	var floor_hit := get_world_3d().direct_space_state.intersect_ray(ray)
	return not floor_hit.is_empty() and floor_hit.normal.y > 0.8 and absf(floor_hit.position.y-pos.y) < 0.15

func disembark() -> bool:
	if not crewed or members.is_empty():
		return false
	var spawn_positions: Array[Vector3] = []
	var spawn_center := Vector3.ZERO
	# Search a complete formation before changing modes; never put a dwarf in a wall.
	for radius in [5.0, 7.0, 9.0]:
		for sample in 16:
			var angle: float = arena.tank.rotation.y + sample * TAU / 16.0
			spawn_center = arena.tank.global_position + Vector3(cos(angle), 0, sin(angle)) * radius
			spawn_center.y = arena.ground_height(spawn_center)+0.04
			spawn_positions.clear()
			var exit_ray := PhysicsRayQueryParameters3D.create(arena.tank.global_position + Vector3.UP * 0.7, spawn_center + Vector3.UP * 0.7, 1)
			if not get_world_3d().direct_space_state.intersect_ray(exit_ray).is_empty(): continue
			for i in members.size():
				var pos := spawn_center + _slot(i, Vector3.FORWARD)
				pos.y=arena.ground_height(pos)+0.04
				if not _clear_spawn(pos): break
				spawn_positions.append(pos)
			if spawn_positions.size() == members.size(): break
		if spawn_positions.size() == members.size(): break
	if spawn_positions.size() != members.size():
		tell("Для высадки тесно — отведи башню от стены")
		return false
	crewed = false
	if arena.hand: arena.hand.set_enabled(false)
	if arena.battle: arena.battle.nav_dirty = true
	arena.tank.dash.cancel()
	arena.tank.crossbows.cancel_trigger()
	input_armed = false
	motion = Vector3.ZERO
	anchor = spawn_center
	facing = Vector3.FORWARD
	arena.tank.stop_drive()
	arena.tank.kick_velocity = Vector3.ZERO
	arena.tank.buffered_shot = 0.0
	for i in members.size():
		members[i].global_position = spawn_positions[i]
		members[i].set_embarked(false)
	arena.sound.play("servo", -9.0, 1.3)
	arena.fx.ring(spawn_center, 0.32, arena.fx.brass)
	_reset_reticle()
	tell("Экипаж снаружи. WASD — отряд · E — предмет / посадка")
	return true

func board() -> bool:
	if not can_board():
		tell("Подведи весь отряд к башне: не дальше 8 м, без преград")
		return false
	loot.store_cargo()
	loot.deposit_carried_crystals()
	crewed = true
	input_armed = false
	motion = Vector3.ZERO
	arena.tank.buffered_shot = 0.0
	if arena.battle: arena.battle.nav_dirty = true
	for member in members:
		member.set_embarked(true)
		member.global_position = arena.tank.global_position + Vector3.UP * 2.0
	arena.sound.play("lock", -4.0, 0.8)
	arena.add_trauma(0.15)
	_reset_reticle()
	tell("%d гномов на борту — башня под управлением" % members.size())
	return true

func _reset_reticle() -> void:
	if arena.hud:
		arena.hud.reset_reticle()

func context_action() -> Dictionary:
	if members.is_empty(): return {"kind": "none", "text": "ОТРЯД ПОГИБ  ·  R — НАЧАТЬ ЗАНОВО"}
	if not crewed and loot.carried_crystal_count() > 0 and can_board():
		return {"kind": "crystals_deposit", "text": "E  СДАТЬ КРИСТАЛЛЫ В БАШНЮ · %d" % loot.carried_crystal_count()}
	if arena.level:
		var action: Dictionary = arena.level.context_action()
		if not action.is_empty(): return action
	if crewed: return {"kind": "exit", "text": "E  ВЫСАДИТЬ ЭКИПАЖ"}
	var item: Dictionary = loot.nearest_interaction(center())
	if item.get("kind", "") == "crystal": return item
	if loot.cargo != null:
		if can_board(): return {"kind": "board", "text": "E  ПОГРУЗИТЬ И СЕСТЬ В БАШНЮ"}
		return {"kind": "drop", "text": "E  ОПУСТИТЬ ГРУЗ"}
	if not item.is_empty(): return item
	if loot.carried_crystal_count() > 0:
		return {"kind": "crystals_drop", "text": "E / Q  ОПУСТИТЬ КРИСТАЛЛЫ · У БАШНИ E — СДАТЬ"}
	if can_board(): return {"kind": "board", "text": "E  СЕСТЬ В БАШНЮ"}
	if arena.tank.dead: return {"kind": "none", "text": "БАШНЯ РАЗБИТА  ·  БОЙ ЭКИПАЖЕМ  ·  R — ЗАНОВО"}
	return {"kind": "none", "text": "БАШНЯ  %d м  ·  подойди для посадки" % int(board_distance())}

func interact() -> void:
	if members.is_empty():
		tell("Отряд погиб. R — восстановить полигон и экипаж")
		return
	var action := context_action()
	match action.kind:
		"level": arena.level.interact(action.id)
		"exit": disembark()
		"board": board()
		"drop": loot.drop_cargo()
		"cargo": loot.pickup_cargo(action.node)
		"crystal": loot.pickup_crystal(action.node)
		"crystals_deposit": loot.deposit_carried_crystals()
		"crystals_drop": loot.drop_crystals()
		"chest": loot.open_chest(action.entry)
		_: tell("Рядом нет предметов. Для посадки подойди к башне")
