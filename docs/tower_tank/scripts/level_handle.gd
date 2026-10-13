extends StaticBody3D
const Geo = preload("res://scripts/geo.gd")
var level
var home := Vector3.ZERO

func _ready() -> void:
	if get_child_count() > 0:
		home = global_position
		return
	position = home
	collision_layer = 8
	collision_mask = 0
	Geo.collider(self,Vector3(0.7,0.7,1.1),Vector3.ZERO)
	Geo.box(self,Vector3(0.55,0.55,0.95),Vector3.ZERO,Geo.material(Color("d7ad55")))
	preload("res://scripts/tower_hand.gd").register_item(self,Vector3(0.7,0.7,1.1),"КНОПКА ВОРОТ · НАЖМИ РУКОЙ")

func reset() -> void:
	global_position = home
	collision_layer = 8
	collision_mask = 0
	remove_meta("hand_owner")

func can_hand_grab() -> bool:
	return level.unlocked and not level.gate_open and (level.campaign==null or level.campaign.puzzle_available())

func on_hand_grab() -> void:
	if can_hand_grab():
		level.open_gate()
		global_position = home+global_basis.x.normalized()*.15

func hand_move(_target: Vector3) -> void:
	pass

func on_hand_release(_motion: Vector3) -> void:
	global_position = home+global_basis.x.normalized()*.15 if level.gate_open else home
	collision_mask = 0
