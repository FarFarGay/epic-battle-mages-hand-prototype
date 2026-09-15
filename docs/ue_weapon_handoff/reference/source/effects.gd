extends Node3D
const Geo = preload("res://scripts/geo.gd")
var pieces: Array[Dictionary] = []
var marks: Array[Node3D] = []
var rng := RandomNumberGenerator.new()
var hot := Geo.material(Color("fff1c2"), 0.0, 2.5)
var gold := Geo.material(Color("ffb650"), 0.15, 1.8)
var smoke := Geo.material(Color("55565a"))
var dust_mat := Geo.material(Color("9f8e74"))
var stone := Geo.material(Color("918679"))
var brass := Geo.material(Color("b68b48"), 0.8)
var charred := Geo.material(Color("292d2c"))
var dash_mat := Geo.material(Color("73deda"), 0.0, 1.2)

func _ready() -> void:
	rng.randomize()

func _process(dt: float) -> void:
	for i in range(pieces.size() - 1, -1, -1):
		var p: Dictionary = pieces[i]
		p.life -= dt
		var node: Node3D = p.node
		if p.life <= 0.0:
			node.queue_free()
			pieces.remove_at(i)
			continue
		var age: float = 1.0 - p.life / p.total
		p.vel.y -= p.gravity * dt
		node.position += p.vel * dt
		node.rotation += p.spin * dt
		if p.gravity > 1.0 and node.position.y < 0.12:
			node.position.y = 0.12
			p.vel.y = absf(p.vel.y) * 0.28
			p.vel.x *= 0.78
			p.vel.z *= 0.78
			p.spin *= 0.65
		if p.mode == "ring" or p.mode == "muzzle_ring":
			node.scale = p.base * (1.0 + age * (3.4 if p.mode == "muzzle_ring" else 9.0))
			node.scale.y = maxf(0.01, (1.0 - age) * 0.25)
			var material: StandardMaterial3D = node.material_override
			material.albedo_color.a = (1.0 - age) * 0.65
		elif p.mode == "ghost":
			node.material_override.albedo_color.a = (1.0 - age) * 0.20
		elif p.mode == "smoke":
			node.scale = p.base * (0.35 + age * 1.8) * minf(p.life * 3.0, 1.0)
		else:
			node.scale = p.base * minf(p.life * 5.0, 1.0)

func add_piece(node: Node3D, vel: Vector3, life: float, gravity: float = 0.0, mode: String = "piece", spin: Vector3 = Vector3.ZERO) -> void:
	if node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	while pieces.size() >= 420:
		var oldest: Dictionary = pieces.pop_front()
		oldest.node.queue_free()
	pieces.append({"node": node, "vel": vel, "life": life, "total": life, "gravity": gravity, "mode": mode, "spin": spin, "base": node.scale})

func flash(pos: Vector3, energy: float, radius: float) -> void:
	var light := OmniLight3D.new()
	add_child(light)
	light.position = pos
	light.light_color = Color("ffba68")
	light.omni_range = radius
	light.light_energy = energy
	var tween := create_tween()
	tween.tween_property(light, "light_energy", 0.0, 0.17)
	tween.tween_callback(light.queue_free)

func ring(pos: Vector3, size: float, mat: Material = gold) -> void:
	var n := Geo.ring(self, size, 0.025, pos, _ring_material(mat))
	add_piece(n, Vector3.ZERO, 0.32, 0.0, "ring")

func _ring_material(source: StandardMaterial3D) -> StandardMaterial3D:
	var mat: StandardMaterial3D = source.duplicate()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color.a = 0.65
	mat.emission_energy_multiplier = 0.4
	return mat

func muzzle(pos: Vector3, direction: Vector3) -> void:
	flash(pos, 7.0, 10.0)
	var core := Geo.sphere(self, 0.58, pos + direction * 0.4, hot)
	core.scale = Vector3(1, 0.65, 1)
	add_piece(core, direction * 5.0, 0.075)
	for i in 16:
		var scatter := direction + Vector3(rng.randf_range(-0.55, 0.55), rng.randf_range(-0.25, 0.55), rng.randf_range(-0.55, 0.55))
		var n := Geo.box(self, Vector3(0.07, 0.07, rng.randf_range(0.3, 0.9)), pos, hot if i % 3 == 0 else gold)
		n.look_at(pos + scatter)
		add_piece(n, scatter * rng.randf_range(6.0, 15.0), rng.randf_range(0.1, 0.3), 4.0)
	for i in 9:
		var n := Geo.sphere(self, rng.randf_range(0.25, 0.55), pos + direction * rng.randf_range(0.2, 1.1), smoke)
		add_piece(n, direction * rng.randf_range(1.0, 3.0) + Vector3(rng.randf_range(-1.0, 1.0), 1.6, rng.randf_range(-1.0, 1.0)), rng.randf_range(0.45, 0.95), -0.2, "smoke")
	var wave := Geo.ring(self, 0.3, 0.018, pos, _ring_material(hot))
	wave.quaternion = Quaternion(Vector3.UP, direction)
	add_piece(wave, direction * 5.0, 0.12, 0.0, "muzzle_ring")

func impact(pos: Vector3, big: bool = false) -> void:
	var power := 1.6 if big else 1.0
	flash(pos + Vector3.UP, 5.0 * power, 12.0)
	ring(Vector3(pos.x, 0.09, pos.z), 0.5 * power)
	var ball := Geo.sphere(self, 0.65 * power, pos, hot)
	add_piece(ball, Vector3.ZERO, 0.12)
	for i in (34 if big else 20):
		var v := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(0.25, 1.25), rng.randf_range(-1.0, 1.0)).normalized() * rng.randf_range(4.0, 12.0) * power
		var size := rng.randf_range(0.08, 0.29) * power
		var n := Geo.box(self, Vector3(size, size, size * 1.7), pos, gold if i % 4 == 0 else stone)
		add_piece(n, v, rng.randf_range(0.5, 2.0), 17.0, "piece", Vector3(4, 3, 6))
	for i in 12:
		var n := Geo.sphere(self, rng.randf_range(0.3, 0.7) * power, pos, dust_mat if i % 2 else smoke)
		add_piece(n, Vector3(rng.randf_range(-2.0, 2.0), rng.randf_range(0.7, 3.5), rng.randf_range(-2.0, 2.0)) * power, rng.randf_range(0.7, 1.5), -0.15, "smoke")
	var mark := Geo.cylinder(self, rng.randf_range(0.6, 1.0) * power, 0.014, Vector3(pos.x, 0.018 + rng.randf() * 0.005, pos.z), charred, 13)
	mark.rotation.y = rng.randf() * TAU
	marks.append(mark)
	if marks.size() > 45:
		marks.pop_front().queue_free()

func spear_strike(pos: Vector3) -> void:
	pos.y = 0.12
	# The expanding ring reaches the actual 6.5 m hit radius.
	var wave := Geo.ring(self, 0.65, 0.035, pos, _ring_material(gold))
	add_piece(wave, Vector3.ZERO, 0.25, 0.0, "ring")
	flash(pos + Vector3.UP * 0.5, 2.0, 7.0)
	for i in 28:
		var direction := Vector3(sin(i * TAU / 28.0), 0, cos(i * TAU / 28.0))
		var slash := Geo.line(self, pos + direction * 1.4, pos + direction * 3.0, 0.055, gold)
		add_piece(slash, direction * 12.0, 0.25)
		var puff := Geo.sphere(self, 0.19, pos + direction * 1.8, dust_mat)
		add_piece(puff, direction * 6.0 + Vector3.UP * 0.4, 0.45, 0.0, "smoke")

func eject(pos: Vector3, direction: Vector3) -> void:
	var shell := Geo.cylinder(self, 0.13, 0.55, pos, brass, 10)
	shell.rotation.z = PI / 2.0
	add_piece(shell, direction * 4.0 + Vector3.UP * 3.4, 3.8, 13.0, "piece", Vector3(7.0, 4.0, 5.0))

func dust(pos: Vector3, motion: Vector3) -> void:
	var n := Geo.sphere(self, rng.randf_range(0.12, 0.22), pos, dust_mat)
	add_piece(n, -motion * 0.15 + Vector3(0, 0.3, 0), 0.65, 0.0, "smoke")

func trail(a: Vector3, b: Vector3) -> void:
	var n := Geo.line(self, a, b, 0.07, gold)
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_piece(n, Vector3.ZERO, 0.13)

func repeater_muzzle(pos: Vector3, direction: Vector3) -> void:
	var snap := Geo.box(self, Vector3(0.16, 0.10, 0.34), pos, hot)
	snap.look_at(pos + direction)
	add_piece(snap, direction * 4.0, 0.045)
	var puff := Geo.sphere(self, 0.09, pos, dust_mat)
	add_piece(puff, direction * 0.5 + Vector3.UP * 0.5, 0.20, 0.0, "smoke")

func repeater_trail(start: Vector3, finish: Vector3) -> void:
	if start.distance_squared_to(finish) < 0.0001: return
	var trace := Geo.line(self, start, finish, 0.027, gold)
	add_piece(trace, Vector3.ZERO, 0.065)

func repeater_hit(pos: Vector3, normal: Vector3) -> void:
	for i in 4:
		var scatter := normal * 2.0 + Vector3(rng.randf_range(-1.5, 1.5), rng.randf_range(0.4, 2.0), rng.randf_range(-1.5, 1.5))
		var chip := Geo.box(self, Vector3(0.055, 0.055, 0.13), pos, gold if i == 0 else stone)
		add_piece(chip, scatter, 0.22, 6.0, "piece", scatter * 2.0)

func dash_echo(actor, direction: Vector3, super_dash: bool) -> void:
	var mat := Geo.material(Color("79e8e4") if super_dash else Color("bfc9b1"))
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color.a = 0.20
	var back := direction * -0.75
	for part in [
		[1.10, 2.25, actor.body_visual.to_global(Vector3(0, 2.0, 0))],
		[1.28, 1.08, actor.body_visual.to_global(Vector3(0, 0.74, 0))],
		[1.24, 1.1, actor.turret.to_global(Vector3(0, 0.57, 0))]]:
		var ghost := Geo.cylinder(self, part[0], part[1], part[2] + back, mat, 20)
		add_piece(ghost, Vector3.ZERO, 0.22, 0.0, "ghost")
	for side in [-1, 1]:
		var pos: Vector3 = actor.position + actor.global_basis.x * side * 1.05
		dust(pos + Vector3.UP * 0.1, direction * 15.0)

func clear() -> void:
	for p in pieces:
		p.node.queue_free()
	pieces.clear()
	for n in marks:
		n.queue_free()
	marks.clear()
