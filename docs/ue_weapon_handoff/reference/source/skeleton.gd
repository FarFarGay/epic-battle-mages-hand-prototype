extends CharacterBody3D
## Ordinary Skeleton/Enemy from the main project, without its world autoloads.
## Same base stats, variance, windup -> lunge -> recovery and interruptible attacks.
const Geo = preload("res://scripts/geo.gd")
enum State { APPROACH, WINDUP, LUNGE, RECOVERY, STAGGER }
var battle
var arena
var hp := 30.0
var max_hp := 30.0
var move_speed := 2.0
var attack_damage := 8.0
var attack_windup := 0.4
var close_windup := 0.1
var attack_cooldown := 1.0
var dead := false
var state := State.APPROACH
var timer := 0.0
var target: Node3D
var attack_direction := Vector3.FORWARD
var impulse := Vector3.ZERO
var scan_left := 0.0
var path_left := 0.0
var path := PackedVector3Array()
var stride := 0.0
var hit_flash := 0.0
var bump_cooldown := 0.0
var attacks := 0
var hits := 0
var visual: Node3D
var torso: Node3D
var arms: Array[Node3D] = []
var legs: Array[Node3D] = []
var bones: Array[MeshInstance3D] = []
var health: MeshInstance3D
var warning: MeshInstance3D
var bone_mat: StandardMaterial3D

func _ready() -> void:
	name = "Skeleton"
	collision_layer = 64
	collision_mask = 71 # world, tower, crew, other skeletons
	floor_snap_length = 0.3
	set_meta("enemy", true)
	var rng: RandomNumberGenerator = battle.rng
	hp *= rng.randf_range(0.8, 1.2)
	max_hp = hp
	move_speed *= rng.randf_range(0.85, 1.15)
	attack_damage *= rng.randf_range(0.8, 1.2)
	attack_windup *= rng.randf_range(0.8, 1.2)
	close_windup *= rng.randf_range(0.8, 1.2)
	attack_cooldown *= rng.randf_range(0.85, 1.15)
	scan_left = rng.randf_range(0.0, 0.4)
	path_left = rng.randf_range(0.0, 0.5)
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.9
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = 0.95
	add_child(shape)
	_build()

func _bone(parent: Node3D, size: Vector3, pos: Vector3) -> MeshInstance3D:
	var mesh := Geo.box(parent, size, pos, bone_mat)
	bones.append(mesh)
	return mesh

func _build() -> void:
	bone_mat = Geo.material(Color(0.88, 0.85, 0.78))
	var dark := Geo.material(Color("242729"))
	var rust := Geo.material(Color("65594d"), 0.55)
	var eye := Geo.material(Color("ff593e"), 0.0, 1.8)
	visual = Node3D.new()
	add_child(visual)
	torso = Node3D.new()
	visual.add_child(torso)
	torso.position.y = 0.95
	_bone(torso, Vector3(0.13, 0.61, 0.12), Vector3(0, 0.12, 0.09))
	_bone(torso, Vector3(0.44, 0.13, 0.25), Vector3(0, -0.05, 0))
	for i in 4:
		var width := 0.53 - absf(i - 1.5) * 0.055
		_bone(torso, Vector3(width, 0.065, 0.08), Vector3(0, 0.14 + i * 0.105, -0.15))
		for side in [-1, 1]:
			_bone(torso, Vector3(0.065, 0.065, 0.28), Vector3(side * width * 0.5, 0.14 + i * 0.105, -0.02))
	_bone(torso, Vector3(0.63, 0.09, 0.17), Vector3(0, 0.56, 0))
	_bone(torso, Vector3(0.12, 0.2, 0.12), Vector3(0, 0.65, 0))
	_bone(torso, Vector3(0.40, 0.35, 0.33), Vector3(0, 0.85, -0.025))
	_bone(torso, Vector3(0.28, 0.085, 0.25), Vector3(0, 0.61, -0.07))
	for side in [-1, 1]:
		Geo.box(torso, Vector3(0.12, 0.11, 0.03), Vector3(side * 0.105, 0.85, -0.198), dark)
		Geo.box(torso, Vector3(0.045, 0.036, 0.038), Vector3(side * 0.105, 0.85, -0.216), eye)
		for tooth in 2:
			_bone(torso, Vector3(0.046, 0.07, 0.07), Vector3(side * (0.035 + tooth * 0.06), 0.67, -0.16))
		var arm := Node3D.new()
		torso.add_child(arm)
		arm.position = Vector3(side * 0.36, 0.5, 0)
		_bone(arm, Vector3(0.10, 0.35, 0.11), Vector3(0, -0.15, 0))
		_bone(arm, Vector3(0.11, 0.31, 0.10), Vector3(0, -0.42, -0.09))
		_bone(arm, Vector3(0.15, 0.14, 0.14), Vector3(0, -0.58, -0.1))
		arms.append(arm)
		var leg := Node3D.new()
		visual.add_child(leg)
		leg.position = Vector3(side * 0.19, 0.89, 0)
		_bone(leg, Vector3(0.13, 0.40, 0.14), Vector3(0, -0.19, 0))
		_bone(leg, Vector3(0.16, 0.13, 0.16), Vector3(0, -0.42, -0.02))
		_bone(leg, Vector3(0.1, 0.37, 0.11), Vector3(0, -0.63, 0.025))
		_bone(leg, Vector3(0.18, 0.10, 0.33), Vector3(0, -0.82, -0.08))
		legs.append(leg)
	# A short chipped blade keeps this first enemy's silhouette distinct from crew.
	Geo.box(arms[1], Vector3(0.07, 0.07, 0.26), Vector3(0, -0.58, -0.20), rust)
	Geo.box(arms[1], Vector3(0.31, 0.07, 0.07), Vector3(0, -0.58, -0.31), rust)
	Geo.box(arms[1], Vector3(0.12, 0.055, 0.65), Vector3(0, -0.58, -0.66), rust)
	warning = Geo.ring(self, 0.72, 0.07, Vector3.UP * 0.06, Geo.material(Color("f0a04c"), 0, 1.0))
	warning.scale.y = 0.12
	warning.hide()
	var bar_root := Node3D.new()
	add_child(bar_root)
	bar_root.position.y = 2.2
	var background := Geo.box(bar_root, Vector3(0.75, 0.075, 0.02), Vector3.ZERO, dark)
	background.material_override.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	health = Geo.box(bar_root, Vector3(0.71, 0.045, 0.025), Vector3(0, 0, -0.018), eye)
	bar_root.rotation = arena.camera.rotation
	bar_root.hide()

func tick(dt: float) -> void:
	if dead: return
	bump_cooldown = maxf(0.0, bump_cooldown - dt)
	hit_flash = maxf(0.0, hit_flash - dt)
	bone_mat.albedo_color = Color("fff7d6") if hit_flash > 0.0 else Color(0.88, 0.85, 0.78)
	bone_mat.emission_enabled = hit_flash > 0.0
	bone_mat.emission = Color("d56b3c")
	bone_mat.emission_energy_multiplier = 0.6
	health.get_parent().visible = hp < max_hp
	health.get_parent().global_rotation = arena.aim_camera.global_rotation
	health.scale.x = maxf(hp / max_hp, 0.001)
	health.position.x = -0.355 * (1.0 - hp / max_hp)
	scan_left -= dt
	if not battle.valid_target(target) or scan_left <= 0.0:
		target = battle.choose_target(self)
		scan_left = 0.4
	var desired := Vector3.ZERO
	timer -= dt
	if state == State.STAGGER:
		desired = impulse
		impulse = impulse.move_toward(Vector3.ZERO, 20.0 * dt)
		if timer <= 0.0: state = State.APPROACH
	elif state == State.LUNGE:
		desired = attack_direction * 8.0
		if timer <= 0.0:
			state = State.RECOVERY
			timer = attack_cooldown
	elif state == State.RECOVERY:
		if timer <= 0.0: state = State.APPROACH
	elif battle.valid_target(target):
		var offset := target.global_position - global_position
		offset.y = 0.0
		var direction := offset.normalized()
		rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), 1.0 - exp(-12.0 * dt))
		var reach: float = 1.32 if target == arena.tank else 0.0
		if state == State.WINDUP:
			desired = direction * 1.5
			if timer <= 0.0: _strike(direction)
		elif offset.length() <= 1.5 + reach and battle.clear_sight(global_position, target.global_position, target):
			state = State.WINDUP
			timer = close_windup if offset.length() <= 1.05 + reach else attack_windup
		else:
			path_left -= dt
			if path_left <= 0.0:
				path = battle.find_path(global_position, target.global_position)
				path_left = 0.55
			while not path.is_empty() and Vector2(path[0].x - position.x, path[0].z - position.z).length() < 0.45:
				path.remove_at(0)
			if not path.is_empty(): direction = (path[0] - Vector3(position.x, 0, position.z)).normalized()
			desired = direction * move_speed
			for other in battle.enemies:
				if other == self: continue
				var gap: Vector3 = position - other.position
				gap.y = 0.0
				if gap.length_squared() > 0.001 and gap.length_squared() < 1.44:
					desired += gap.normalized() * (1.2 - gap.length()) * 1.5
	else:
		state = State.APPROACH
	velocity = Vector3(desired.x, -2.0 if is_on_floor() else velocity.y - 20.0 * dt, desired.z)
	move_and_slide()
	_animate(dt, desired.length())

func _strike(direction: Vector3) -> void:
	state = State.LUNGE
	timer = 0.2
	attack_direction = direction
	attacks += 1
	for victim in battle.player_targets():
		var offset: Vector3 = victim.global_position - global_position
		offset.y = 0.0
		var radius := 1.95 + (1.32 if victim == arena.tank else 0.0)
		if offset.length() <= radius and battle.clear_sight(global_position, victim.global_position, victim):
			if victim == arena.tank: victim.take_damage(attack_damage)
			else: victim.take_damage(attack_damage, offset.normalized() * 0.2)
			hits += 1
			arena.fx.repeater_hit(victim.global_position + Vector3.UP * 0.8, -direction)
	var slash := Geo.line(arena.fx, position + Vector3.UP + direction * 0.4, position + Vector3.UP + direction * 1.8, 0.065, arena.fx.hot)
	arena.fx.add_piece(slash, direction * 3.0, 0.12)
	arena.sound.play("bow", -14.0, 0.65)

func _animate(dt: float, speed: float) -> void:
	stride += speed * dt * 3.3
	var windup := state == State.WINDUP
	var striking := state == State.LUNGE
	warning.visible = windup
	torso.rotation.x = lerpf(torso.rotation.x, -0.22 if windup else (0.48 if striking else 0.10), 1.0 - exp(-22.0 * dt))
	visual.scale.y = lerpf(visual.scale.y, 0.84 if windup else 1.0, 1.0 - exp(-20.0 * dt))
	visual.position.y = absf(sin(stride)) * minf(speed * 0.02, 0.05)
	for i in 2:
		legs[i].rotation.x = sin(stride + i * PI) * minf(speed * 0.19, 0.65)
		arms[i].rotation.x = lerpf(arms[i].rotation.x, -2.0 if windup else (-1.15 if striking else -0.35 + sin(stride + i * PI) * 0.18), 1.0 - exp(-24.0 * dt))

func take_damage(amount: float, direction: Vector3 = Vector3.ZERO, force: float = 0.0) -> void:
	if dead or amount <= 0.0: return
	var before := hp
	hp = maxf(0.0, hp - amount)
	hit_flash = 0.11
	scan_left = 0.0
	arena.hit_pulse = 1.0
	if hp <= 0.0:
		dead = true
		collision_layer = 0
		collision_mask = 0
		hide()
		var power := 1.0 + clampf((amount - before) / maxf(before, 1.0), 0.0, 3.0) * 0.6
		for i in range(0, bones.size(), 3):
			var piece: MeshInstance3D = bones[i].duplicate()
			arena.fx.add_child(piece)
			piece.global_transform = bones[i].global_transform
			var scatter := Vector3(sin(i * 2.4), 1.3, cos(i * 2.4)) * 2.0 * power
			arena.fx.add_piece(piece, scatter + direction * power * 4.0, 2.0, 18.0, "piece", Vector3(4, 3, 5))
		battle.killed(self)
		queue_free()
	elif force > 0.0:
		state = State.STAGGER
		timer = 0.25
		impulse = direction * force
		warning.hide()
