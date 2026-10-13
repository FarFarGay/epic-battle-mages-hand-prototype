extends Node3D
const Geo = preload("res://scripts/geo.gd")
@export var defense_blueprint: PackedScene = preload("res://scenes/defense_site.tscn")

func _ready() -> void:
	$Structure.set_meta("mason_workshop",self)
	var gold := Geo.material(Color("d5ab61"))
	var stone := Geo.material(Color("859391"))
	var timber := Geo.material(Color("594938"))
	Geo.box(self,Vector3(3.2,.12,.14),Vector3(0,3.12,2.2),gold)
	Geo.box(self,Vector3(1.6,.85,.14),Vector3(0,2.7,3.8),timber)
	Geo.box(self,Vector3(.14,.64,.12),Vector3(0,2.7,3.91),gold)
	Geo.box(self,Vector3(.65,.23,.18),Vector3(0,2.95,3.94),stone)
	# Stone supplies and a masonry bench distinguish the house without new art assets.
	var supplies := StaticBody3D.new()
	supplies.set_meta("mason_workshop",self)
	add_child(supplies)
	for x in [-1.2,-.4,.4]:
		Geo.box(supplies,Vector3(.7,.5,.7),Vector3(x,.25,4.5),stone)
		Geo.collider(supplies,Vector3(.7,.5,.7),Vector3(x,.25,4.5))
	Geo.box(supplies,Vector3(1.5,.2,.7),Vector3(2.8,1.0,1.8),timber)
	Geo.collider(supplies,Vector3(1.5,1.1,.7),Vector3(2.8,.55,1.8))
	for x in [2.2,3.4]:
		Geo.box(supplies,Vector3(.16,.9,.5),Vector3(x,.45,1.8),timber)
	var label := Label3D.new()
	label.name = "WorkshopSign"
	label.text = "КАМЕНЩИК"
	label.font_size = 64
	label.pixel_size = .018
	label.modulate = Color("ffe0a0")
	label.outline_size = 10
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0,5.9,0)
	add_child(label)
