extends Node3D
## The excavated scene persists during a run. Roof sections reveal as the
## expedition advances, keeping unopened galleries hidden from the overhead camera.
var arena
var reveal_wait := 0.0

func _ready() -> void:
	arena = get_node("../../..")

func reset_reveal() -> void:
	for roof in $Roof.get_children(): roof.show()
	reveal_wait = 0.0

func contains_point(point: Vector3) -> bool:
	var local := to_local(point)
	return Rect2(18,-20,124,60).has_point(Vector2(local.x,local.z)) and point.y>global_position.y+2.0

func _process(dt: float) -> void:
	if not is_instance_valid(arena) or not arena.crew: return
	reveal_wait -= dt
	if reveal_wait>0.0: return
	reveal_wait = 0.2
	var point: Vector3 = to_local(arena.crew.center())
	for roof in $Roof.get_children():
		if roof.visible and Vector2(roof.position.x-point.x,roof.position.z-point.z).length()<15.0:
			roof.hide()
