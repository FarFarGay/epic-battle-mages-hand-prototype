extends CharacterBody3D
## Standalone crew body; role colours/tools follow the main project's CrewKit.
const Geo = preload("res://scripts/geo.gd")
const COLORS := {"archer_squad": Color("ad86d4"), "pikeman": Color("dfab67"), "worker": Color("d9a833"), "fire_mage": Color("c7331f")}
const HEALTH := {"archer_squad": 18.0, "pikeman": 100.0, "worker": 120.0, "fire_mage": 60.0}
signal died
var role := "archer_squad"
var max_hp := 0.0
var hp := 0.0
var dead := false
var embarked := true
var knockback := Vector3.ZERO
var health_label: Label3D
var hauling := false
var shot_cooldown := 0.0
var action_pulse := 0.0
var stride := 0.0
var visual: Node3D
var arms: Array[Node3D] = []
var legs: Array[Node3D] = []
var weapon: Node3D
var muzzle: Marker3D

func _ready() -> void:
	name = "Crew_" + role
	collision_layer = 4
	collision_mask = 67
	floor_snap_length = 0.3
	var collider := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.25
	capsule.height = 1.05
	collider.shape = capsule
	collider.position.y = 0.53
	add_child(collider)
	_build()
	health_label = Label3D.new()
	add_child(health_label)
	health_label.position.y = 1.5
	health_label.font_size = 28
	health_label.pixel_size = 0.012
	health_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	health_label.modulate = Color("ffb17b")
	reset_health()

func reset_health() -> void:
	max_hp = HEALTH[role]
	hp = max_hp
	dead = false
	knockback = Vector3.ZERO
	health_label.hide()

func take_damage(amount: float, direction: Vector3 = Vector3.ZERO) -> bool:
	# SoldierGnome in the main project is invulnerable only inside the tower.
	if dead or embarked or amount <= 0.0: return false
	hp = maxf(0.0, hp - amount)
	knockback = direction * 7.0
	health_label.text = "%d / %d" % [ceili(hp), int(max_hp)]
	health_label.show()
	if hp <= 0.0:
		dead = true
		collision_layer = 0
		collision_mask = 0
		hide()
		died.emit()
	return true

func _build() -> void:
	var cloth := Geo.material(COLORS[role])
	var skin := Geo.material(Color("d9b38c"))
	var beard := Geo.material(Color("e0c8a0"))
	var wood := Geo.material(Color("583821"))
	var steel := Geo.material(Color("9aadb2"), 0.6)
	var leather := Geo.material(Color("2c2929"))
	visual = Node3D.new()
	add_child(visual)
	Geo.box(visual, Vector3(0.42, 0.43, 0.31), Vector3(0, 0.59, 0), cloth)
	Geo.box(visual, Vector3(0.45, 0.09, 0.34), Vector3(0, 0.40, 0), leather)
	Geo.box(visual, Vector3(0.1, 0.085, 0.025), Vector3(0, 0.41, -0.18), steel)
	Geo.box(visual, Vector3(0.31, 0.29, 0.29), Vector3(0, 0.93, -0.015), skin)
	Geo.box(visual, Vector3(0.28, 0.23, 0.14), Vector3(0, 0.77, -0.20), beard)
	Geo.box(visual, Vector3(0.10, 0.09, 0.10), Vector3(0, 0.92, -0.20), skin)
	for side in [-1, 1]:
		Geo.box(visual, Vector3(0.035, 0.035, 0.02), Vector3(side * 0.077, 0.98, -0.166), leather)
		var leg := Node3D.new()
		visual.add_child(leg)
		leg.position = Vector3(side * 0.12, 0.36, 0)
		Geo.box(leg, Vector3(0.17, 0.28, 0.19), Vector3(0, -0.13, 0), leather)
		Geo.box(leg, Vector3(0.19, 0.11, 0.28), Vector3(0, -0.29, -0.04), leather)
		legs.append(leg)
		var arm := Node3D.new()
		visual.add_child(arm)
		arm.position = Vector3(side * 0.29, 0.76, 0)
		Geo.box(arm, Vector3(0.16, 0.24, 0.20), Vector3(0, -0.1, 0), cloth)
		Geo.box(arm, Vector3(0.15, 0.13, 0.15), Vector3(0, -0.25, -0.02), skin)
		arms.append(arm)
	weapon = Node3D.new()
	arms[1].add_child(weapon)
	weapon.position = Vector3(0, -0.19, -0.16)
	match role:
		"archer_squad":
			Geo.cylinder(visual, 0.20, 0.13, Vector3(0, 1.10, 0), cloth, 8, 0.13)
			Geo.box(visual, Vector3(0.26, 0.40, 0.14), Vector3(0, 0.61, 0.25), wood)
			for i in 4:
				Geo.box(visual, Vector3(0.025, 0.47, 0.025), Vector3(-0.09 + i * 0.06, 0.79, 0.26), beard)
			for side in [-1, 1]:
				Geo.line(weapon, Vector3.ZERO, Vector3(0, side * 0.32, 0.10), 0.045, wood)
			Geo.line(weapon, Vector3(0, -0.32, 0.10), Vector3(0, 0.32, 0.10), 0.012, beard)
		"pikeman":
			Geo.cylinder(visual, 0.21, 0.22, Vector3(0, 1.09, 0), steel, 8, 0.10)
			Geo.box(weapon, Vector3(0.045, 0.045, 1.45), Vector3(0, 0, -0.43), wood)
			Geo.box(weapon, Vector3(0.11, 0.06, 0.28), Vector3(0, 0, -1.18), steel)
			Geo.box(arms[0], Vector3(0.31, 0.47, 0.10), Vector3(0, -0.1, -0.19), steel)
		"worker":
			Geo.box(visual, Vector3(0.36, 0.12, 0.32), Vector3(0, 1.10, 0), cloth)
			Geo.box(weapon, Vector3(0.05, 0.55, 0.05), Vector3(0, 0.1, 0), wood)
			Geo.box(weapon, Vector3(0.27, 0.14, 0.15), Vector3(0, 0.38, 0), steel)
			Geo.box(visual, Vector3(0.30, 0.42, 0.08), Vector3(0, 0.56, 0.22), wood)
		"fire_mage":
			Geo.box(visual, Vector3(0.35, 0.21, 0.33), Vector3(0, 1.09, 0.035), cloth)
			Geo.box(weapon, Vector3(0.055, 1.04, 0.055), Vector3(0, 0.12, 0), wood)
			Geo.sphere(weapon, 0.105, Vector3(0, 0.67, 0), Geo.material(Color("ff8c26"), 0, 2.0))
	muzzle = Marker3D.new()
	visual.add_child(muzzle)
	muzzle.position = Vector3(0.27, 0.80, -0.50)
	var ring := Geo.ring(self, 0.39, 0.035, Vector3(0, 0.035, 0), Geo.material(COLORS[role], 0, 0.5))
	ring.scale.y = 0.18
	Geo.mark_ui(ring)

func set_embarked(on: bool) -> void:
	embarked = on
	visible = not on and not dead
	collision_layer = 0 if on or dead else 4
	collision_mask = 0 if on or dead else 67
	velocity = Vector3.ZERO
	knockback = Vector3.ZERO

func tick(dt: float, desired_velocity: Vector3, facing: Vector3, grip: float) -> void:
	if dead: return
	shot_cooldown = maxf(0.0, shot_cooldown - dt)
	var flat := Vector3(velocity.x, 0, velocity.z).lerp(desired_velocity + knockback, 1.0 - exp(-grip * dt))
	knockback = knockback.move_toward(Vector3.ZERO, 18.0 * dt)
	velocity = Vector3(flat.x, -2.0 if is_on_floor() else velocity.y - 24.0 * dt, flat.z)
	move_and_slide()
	rotation.y = lerp_angle(rotation.y, atan2(-facing.x, -facing.z), 1.0 - exp(-14.0 * dt))
	var pace := Vector2(velocity.x, velocity.z).length()
	stride += pace * dt * 2.6
	action_pulse = maxf(0.0, action_pulse - dt * 4.0)
	visual.position.y = absf(sin(stride)) * minf(pace * 0.009, 0.06)
	for i in 2:
		legs[i].rotation.x = sin(stride + i * PI) * minf(pace * 0.065, 0.55)
		arms[i].rotation.x = -2.5 if hauling else -0.4 - action_pulse * 0.6 + sin(stride + i * PI) * minf(pace * 0.02, 0.14)
	weapon.position.z = -0.16 - action_pulse * (0.45 if role == "pikeman" else -0.12)
