extends StaticBody3D
const Geo = preload("res://scripts/geo.gd")
var level
var home := Vector3.ZERO

func _ready() -> void:
	position = home
	collision_layer = 8
	collision_mask = 0
	Geo.collider(self,Vector3(0.7,0.7,1.1),Vector3.ZERO)
	Geo.box(self,Vector3(0.55,0.55,0.95),Vector3.ZERO,Geo.material(Color("d7ad55")))
	preload("res://scripts/tower_hand.gd").register_item(self,Vector3(0.7,0.7,1.1),"РУКОЯТЬ ВОРОТ · ПОТЯНИ ОТ СТЕНЫ")

func reset() -> void:
	position = home
	collision_layer = 8
	collision_mask = 0
	remove_meta("hand_owner")

func can_hand_grab() -> bool:
	return level.unlocked and not level.gate_open

func hand_move(target: Vector3) -> void:
	position = home + Vector3(clampf(target.x-home.x,-2.0,0.0),0,0)
	if home.x-position.x > 1.65: level.open_gate()

func on_hand_release(_motion: Vector3) -> void:
	position = home + Vector3.LEFT*2.0 if level.gate_open else home
	collision_mask = 0
