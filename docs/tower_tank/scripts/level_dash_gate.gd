extends StaticBody3D
## A closed wooden door is a movement obstacle, broken only by a super dash.
const Geo = preload("res://scripts/geo.gd")
var level
var broken := false
var panels: Node3D
var wood := Geo.material(Color("805236"))
var brace := Geo.material(Color("4d3829"))

func _ready() -> void:
	if has_node("Panels"):
		panels = get_node("Panels")
		return
	name = "BridgeDashDoor"
	collision_layer = 1
	collision_mask = 0
	Geo.collider(self,Vector3(0.5,5.2,6.0),Vector3.UP*2.6)
	panels = Node3D.new()
	panels.name = "Panels"
	add_child(panels)
	var iron := Geo.material(Color("687079"),0.7)
	for side in [-1,1]:
		for i in 8:
			Geo.box(panels,Vector3(0.38,4.6,0.35),Vector3(0,2.3,side*(0.2+i*0.37)),wood)
		for y in [0.7,3.9]:
			Geo.box(panels,Vector3(0.16,0.22,2.7),Vector3(-0.27,y,side*1.5),brace)
			Geo.box(panels,Vector3(0.18,0.32,0.4),Vector3(-0.38,y,side*2.7),iron)
		_panel_line(Vector3(-0.29,0.8,side*0.25),Vector3(-0.29,3.8,side*2.7),0.22,brace)
	Geo.box(panels,Vector3(0.2,0.18,1.5),Vector3(-0.4,2.3,0),iron)
	# A pair of warm metal chevrons marks the impact point without a world label.
	var mark := Geo.material(Color("d8a052"),0.3)
	for z in [-0.55,0.1]:
		_panel_line(Vector3(-0.42,3.1,z),Vector3(-0.42,2.8,z+0.38),0.09,mark)
		_panel_line(Vector3(-0.42,2.8,z+0.38),Vector3(-0.42,2.5,z),0.09,mark)

func _panel_line(a: Vector3, b: Vector3, width: float, material: Material) -> void:
	var beam := Geo.box(panels,Vector3(width,width,a.distance_to(b)),(a+b)*0.5,material)
	# Endpoints are door-local: orient along their local segment, not a world point.
	beam.quaternion = Quaternion(Vector3.BACK,(b-a).normalized())

func reset() -> void:
	broken = false
	collision_layer = 1
	panels.show()
	if level.arena.battle: level.arena.battle.nav_dirty = true

func can_super_dash_break() -> bool:
	return not broken

func break_by_super_dash(direction: Vector3) -> bool:
	if broken: return false
	broken = true
	collision_layer = 0
	panels.hide()
	var arena = level.arena
	arena.battle.nav_dirty = true
	for side in [-1,1]:
		for i in 8:
			var pos := to_global(Vector3(0,1.4+float(i%3)*0.8,side*(0.2+i*0.37)))
			var plank := Geo.box(arena.fx,Vector3(0.18,1.7,0.28),pos,wood)
			var velocity := direction*(7.0+float(i%4))+Vector3(0,2.0+float(i%3),side*(2.0+float(i%2)))
			arena.fx.add_piece(plank,velocity,2.1,17.0,"piece",Vector3(side*4.0,2.0,float(i%3)-1.0))
	for i in 6: arena.fx.dust(global_position+Vector3(0,0.5,(i-2.5)*0.8),-direction*10.0)
	arena.sound.play("shatter",-2.0,0.7)
	arena.add_trauma(0.55)
	arena.freeze = maxf(arena.freeze,0.075)
	arena.crew.tell("Дверь пробита · проход в каньон открыт")
	return true
