extends Node3D
const Geo = preload("res://scripts/geo.gd")
@export var cannon_gold_cost := 100
@export var cannon_crystal_cost := 20
var available := false
var structure: StaticBody3D

func _ready() -> void:
	structure = StaticBody3D.new()
	structure.name = "Structure"
	structure.set_meta("mechanic_workshop",self)
	add_child(structure)
	var wall := Geo.material(Color("98aaa3"))
	var metal := Geo.material(Color("48525b"),.5)
	var gold := Geo.material(Color("d5ab61"))
	Geo.box(structure,Vector3(4.5,3.2,4),Vector3(0,1.6,0),wall)
	Geo.collider(structure,Vector3(4.5,3.2,4),Vector3(0,1.6,0))
	Geo.box(self,Vector3(5,.35,4.5),Vector3(0,3.35,0),metal)
	Geo.box(self,Vector3(1.2,2,.08),Vector3(0,1,2.04),metal)
	Geo.box(self,Vector3(3.8,.18,2.1),Vector3(0,2.4,2.9),gold)
	for x in [-1.7,1.7]: Geo.box(self,Vector3(.16,2.4,.16),Vector3(x,1.2,3.7),metal)
	Geo.box(structure,Vector3(1.5,1,.7),Vector3(3,.5,1.6),metal)
	Geo.collider(structure,Vector3(1.5,1,.7),Vector3(3,.5,1.6))
	var wheel := Geo.ring(self,.65,.17,Vector3(2.3,2,2.1),gold)
	wheel.rotation.x = PI/2
	var sign := Label3D.new()
	sign.text = "МЕХАНИК"
	sign.font_size = 64
	sign.pixel_size = .018
	sign.modulate = Color("ffe0a0")
	sign.outline_size = 10
	sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sign.position.y = 5.7
	add_child(sign)
	set_available(false)

func set_available(value: bool) -> void:
	available = value
	visible = value
	structure.collision_layer = 1 if value else 0

func purchase(arena) -> bool:
	if not available or arena.tank.cannon_installed: return false
	var loot = arena.crew.loot
	if loot.coins<cannon_gold_cost or loot.crystals<cannon_crystal_cost: return false
	loot.coins -= cannon_gold_cost
	loot.crystals -= cannon_crystal_cost
	arena.tank.set_cannon_installed(true)
	arena.crew.tell("Пушка установлена · ЛКМ — огонь · ПКМ — бортовое оружие")
	return true
