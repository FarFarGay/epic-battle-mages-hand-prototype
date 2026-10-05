extends Node3D
## The main crew's default binding/ability balance, adapted to range targets.
const Geo = preload("res://scripts/geo.gd")
var crew
var arena
var spear_cd := 0.0
var wave_cd := 0.0
var mage_cd := 0.0
var arrows_fired := 0
var spells_fired := 0
var bolts: Array[Dictionary] = []
var burns: Array[Dictionary] = []
var arrow_mat := Geo.material(Color("dfc995"), 0.25, 0.6)
var ember_mat := Geo.material(Color("ff893f"), 0, 2.0)

func reset() -> void:
	for bolt in bolts:
		bolt.node.queue_free()
	bolts.clear()
	burns.clear()
	spear_cd = 0.0
	wave_cd = 0.0
	mage_cd = 0.0
	arrows_fired = 0
	spells_fired = 0

func tick(dt: float) -> void:
	spear_cd = maxf(0.0, spear_cd - dt)
	wave_cd = maxf(0.0, wave_cd - dt)
	mage_cd = maxf(0.0, mage_cd - dt)
	_tick_bolts(dt)
	_tick_burns(dt)
	if crew.crewed or crew.members.is_empty() or not crew.input_armed or arena.tuning_open or arena.pointer_over_ui():
		return
	if Input.is_action_pressed("tank_fire"):
		for member in crew.members:
			if member.role == "archer_squad" and not member.hauling and member.shot_cooldown <= 0.0:
				_shoot(member, "arrow")
				member.shot_cooldown = 0.64 + float(crew.members.find(member) % 3) * 0.06
	if Input.is_action_just_pressed("crew_strike"):
		strike()
	if Input.is_action_just_pressed("crew_special"):
		special()

func _available(role: String) -> Array:
	return crew.members.filter(func(member): return member.role == role and not member.hauling)

func _shoot(member, kind: String) -> void:
	var from: Vector3 = member.muzzle.global_position
	var target: Vector3 = arena.aim_position
	target.y = maxf(target.y, arena.ground_height(target)+0.75)
	var direction := (target - from).normalized()
	if direction.length_squared() < 0.5: direction = crew.facing
	var node: Node3D
	if kind == "arrow":
		node = Geo.box(self, Vector3(0.04, 0.04, 0.58), from, arrow_mat)
		node.look_at(from + direction)
		arrows_fired += 1
		arena.sound.play("bow", -9.0)
	else:
		node = Geo.sphere(self, 0.18, from, ember_mat)
		spells_fired += 1
		arena.sound.play("spell", -7.0)
	bolts.append({"node": node, "vel": direction * (28.0 if kind == "arrow" else 17.0), "range": 12.0 if kind == "arrow" else 20.0, "kind": kind, "damage": 10.0 if kind == "arrow" else 30.0, "hit_ids": []})
	member.action_pulse = 1.0

func strike() -> void:
	if crew.crewed or crew.members.is_empty(): return
	var spears := _available("pikeman")
	if spear_cd > 0.0:
		crew.tell("Копейщики: %.1f с до удара" % spear_cd)
		return
	if spears.is_empty():
		crew.tell("В отряде не осталось копейщиков" if crew.role_count("pikeman") == 0 else "Копейщики несут груз — сначала опусти его")
		return
	spear_cd = 6.0
	var origin: Vector3 = crew.center()
	for member in spears:
		member.action_pulse = 1.0
	for target in arena.combat_targets():
		var offset: Vector3 = target.position - origin
		offset.y = 0.0
		if offset.length() <= 6.5 and arena.strike_clear(origin, target.position):
			_sparks(target.position + Vector3.UP, arrow_mat, 10)
			arena.fx.dust(target.position, -offset.normalized() * 15.0)
			arena._damage_target(target, 28.0 * spears.size(), offset.normalized(), 11.0, &"crew")
	for prop in arena.props.props.duplicate():
		var offset: Vector3 = prop.position - origin
		offset.y = 0.0
		if offset.length() <= 6.5 and arena.strike_clear(origin, prop.position):
			arena.props.shatter(prop, offset.normalized(), 2.0)
	arena.fx.spear_strike(origin)
	arena.sound.play("strike", 0.0, 0.78)
	arena.sound.play("step", -5.0, 0.65)
	arena.add_trauma(0.45)
	arena.freeze = maxf(arena.freeze, 0.08)
	crew.motion *= 0.2
	for member in crew.members: member.velocity *= 0.2

func special() -> void:
	if crew.crewed or crew.members.is_empty(): return
	var workers := _available("worker")
	var mages := _available("fire_mage")
	var used := false
	if wave_cd <= 0.0 and not workers.is_empty():
		wave_cd = 14.0
		used = true
		var start: Vector3 = crew.center() + crew.facing * 1.8
		start.y = arena.ground_height(start)+0.55
		var wave := Node3D.new()
		add_child(wave)
		wave.position = start
		wave.look_at(start + crew.facing)
		for i in 7:
			var rock := Geo.box(wave, Vector3(0.55, 0.55 + (i % 2) * 0.3, 0.7), Vector3((i - 3) * 0.53, 0, 0), arena.fx.stone)
			rock.rotation = Vector3(i * 0.5, i * 0.7, i * 0.4)
		bolts.append({"node": wave, "vel": crew.facing * 13.0, "range": 20.0, "kind": "wave", "damage": 45.0 * workers.size(), "hit_ids": []})
		for member in workers: member.action_pulse = 1.0
		arena.sound.play("strike", -3.0, 0.65)
		arena.add_trauma(0.2)
	if mage_cd <= 0.0 and not mages.is_empty():
		mage_cd = 5.0
		used = true
		for member in mages:
			_shoot(member, "fire")
	if not used:
		crew.tell("Спецприёмы перезаряжаются или гномы заняты грузом")

func _clear_to(start: Vector3, target: Node3D) -> bool:
	var q := PhysicsRayQueryParameters3D.create(start, target.global_position + Vector3.UP * 0.8, 3)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or hit.collider == target

func _tick_bolts(dt: float) -> void:
	for i in range(bolts.size() - 1, -1, -1):
		var bolt: Dictionary = bolts[i]
		var from: Vector3 = bolt.node.global_position
		var next: Vector3 = from + bolt.vel * dt
		if bolt.kind=="wave" and absf(arena.ground_height(next)-arena.ground_height(from))<0.65:
			next.y=arena.ground_height(next)+0.55
		var query := PhysicsRayQueryParameters3D.create(from, next, 99)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		var remove := false
		if bolt.kind == "wave":
			arena.props.crush_segment(from, hit.position if hit and not hit.collider.has_meta("breakable") else next, 2.1, 1.5)
			# Wide sweep, each target once; walls and the parked hull block it.
			for target in arena.combat_targets():
				var id: int = target.get_instance_id()
				var relative: Vector3 = target.position - next
				relative.y = 0.0
				var direction: Vector3 = bolt.vel.normalized()
				if not bolt.hit_ids.has(id) and absf(relative.dot(direction)) < 0.8 and absf(relative.dot(direction.cross(Vector3.UP))) < 2.3 and _clear_to(from, target):
					bolt.hit_ids.append(id)
					arena._damage_target(target, bolt.damage, direction, 12.0, &"crew")
			remove = not hit.is_empty() and not hit.collider.has_meta("target") and not hit.collider.has_meta("breakable") and not hit.collider.has_meta("enemy")
			if int(bolt.range * 5.0) % 3 == 0:
				arena.fx.dust(next, bolt.vel * 0.3)
		elif not hit.is_empty():
			if hit.collider.has_meta("breakable"):
				arena.props.shatter(hit.collider, bolt.vel.normalized())
			if bolt.kind == "arrow":
				if hit.collider.has_meta("target") or hit.collider.has_meta("enemy"):
					arena._damage_target(hit.collider, bolt.damage, bolt.vel.normalized(), 2.5, &"crew")
				_sparks(hit.position, arrow_mat, 4)
			else:
				_fire_burst(hit.position, hit.collider)
			remove = true
		elif bolt.kind == "fire":
			var trail := Geo.sphere(arena.fx, 0.10, from, ember_mat)
			arena.fx.add_piece(trail, Vector3.UP * 0.2, 0.16)
		bolt.node.global_position = next
		bolt.range -= (next - from).length()
		if bolt.range <= 0.0 and bolt.kind == "fire" and not remove:
			_fire_burst(next, null)
		if remove or bolt.range <= 0.0:
			bolt.node.queue_free()
			bolts.remove_at(i)

func _sparks(pos: Vector3, mat: Material, count: int) -> void:
	for i in count:
		var node := Geo.box(arena.fx, Vector3.ONE * 0.065, pos, mat)
		arena.fx.add_piece(node, Vector3(sin(i * 2.4), 1.8, cos(i * 2.4)) * 2.0, 0.25, 8.0)

func _fire_burst(pos: Vector3, direct) -> void:
	arena.props.blast(pos, 2.6)
	arena.fx.flash(pos, 2.5, 5.0)
	arena.fx.ring(Vector3(pos.x, arena.ground_height(pos)+0.08, pos.z), 0.28, ember_mat)
	_sparks(pos, ember_mat, 10)
	arena.sound.play("spell", -8.0, 0.7)
	for target in arena.combat_targets():
		if target == direct or (target.position + Vector3.UP * 0.8).distance_to(pos) < 2.6 and _clear_to(pos, target):
			arena._damage_target(target, 30.0 if target == direct else 10.0, (target.position - pos).normalized(), 4.0, &"crew")
	burns.append({"pos": Vector3(pos.x, arena.ground_height(pos)+0.08, pos.z), "life": 3.0, "tick": 0.5})

func _tick_burns(dt: float) -> void:
	for i in range(burns.size() - 1, -1, -1):
		var burn: Dictionary = burns[i]
		burn.life -= dt
		burn.tick -= dt
		if burn.tick <= 0.0:
			burn.tick = 0.5
			_sparks(burn.pos, ember_mat, 3)
			for target in arena.combat_targets():
				if Vector2(target.position.x - burn.pos.x, target.position.z - burn.pos.z).length() < 2.6 and _clear_to(burn.pos + Vector3.UP * 0.5, target):
					arena._damage_target(target, 4.0, Vector3.ZERO, 0.0, &"crew")
		if burn.life <= 0.0: burns.remove_at(i)
