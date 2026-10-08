extends "res://scripts/hand_object.gd"
## A mined resource stays physical until carried or delivered to the tower.
const Geo = preload("res://scripts/geo.gd")
const SIZE := Vector3(0.58, 0.74, 0.58)

func _ready() -> void:
	collision_layer = 16
	collision_mask = 1 | 8 | 32 | 1024
	mass = 0.7
	linear_damp = 1.2
	angular_damp = 2.5
	set_meta("crystal", true)
	Geo.collider(self, SIZE, Vector3.ZERO)
	var mat := Geo.material(Color("77dbe8"), 0.25, 0.6)
	Geo.cylinder(self, 0.29, 0.48, Vector3.UP * 0.02, mat, 6, 0.19)
	Geo.cylinder(self, 0.19, 0.22, Vector3.UP * 0.26, mat, 6, 0.0)
	var tip := Geo.cylinder(self, 0.29, 0.22, Vector3.DOWN * 0.26, mat, 6, 0.0)
	tip.rotation.x = PI
	var physics := PhysicsMaterial.new()
	physics.bounce = 0.18
	physics.friction = 0.85
	physics_material_override = physics
	super._ready()
	preload("res://scripts/tower_hand.gd").register_item(self, SIZE, "КРИСТАЛЛ")

func can_hand_grab() -> bool:
	return not has_meta("crew_carrier") and not get_meta("depositing", false)
