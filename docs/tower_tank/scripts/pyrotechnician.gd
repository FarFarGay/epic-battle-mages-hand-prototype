extends Node3D
const Geo = preload("res://scripts/geo.gd")
@export_range(1,1000) var barrel_gold_cost := 15
@export_range(1,15) var stock_columns := 7
@export_range(1,15) var stock_rows := 8
const STOCK_SPACING := 1.35
var output: Marker3D
var last_barrel: WeakRef
var stock: Array[WeakRef] = []
var serial := 0

func _ready() -> void:
	$Structure.set_meta("pyrotechnician",self)
	var red := Geo.material(Color("ad493a"))
	var metal := Geo.material(Color("d9ac63"))
	var wood := Geo.material(Color("594938"))
	Geo.box(self,Vector3(3.2,.12,.14),Vector3(0,3.12,2.2),red)
	Geo.box(self,Vector3(1.6,.85,.14),Vector3(0,2.7,3.8),wood)
	Geo.cylinder(self,.28,.62,Vector3(0,2.7,4.0),red,10)
	for y in [2.48,2.91]: Geo.cylinder(self,.30,.08,Vector3(0,y,4.0),metal,10)
	Geo.box(self,Vector3(.10,.24,.10),Vector3(0,3.12,4.0),metal)
	output = Marker3D.new()
	output.name = "BarrelOutput"
	output.position = Vector3(0,.04,6)
	add_child(output)
	Geo.box(self,Vector3(1.3,.06,1.3),Vector3(0,.02,6),wood)
	var label := Label3D.new()
	label.name = "WorkshopSign"
	label.text = "ПИРОТЕХНИК"
	label.font_size = 64
	label.pixel_size = .018
	label.modulate = Color("ffb282")
	label.outline_size = 10
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0,5.9,0)
	add_child(label)

func stock_area() -> Rect2:
	return Rect2(-floori(stock_columns/2.0)*STOCK_SPACING-STOCK_SPACING*.5,output.position.z-STOCK_SPACING*.5,stock_columns*STOCK_SPACING,stock_rows*STOCK_SPACING)

func reserves_point(point: Vector3, margin: float) -> bool:
	var local := to_local(point)
	return stock_area().grow(margin).has_point(Vector2(local.x,local.z))

func _spot_free(point: Vector3) -> bool:
	# Newly bought bodies may not have reached the physics server yet.
	for ref in stock:
		var barrel = ref.get_ref()
		if not is_instance_valid(barrel) or barrel.is_queued_for_deletion(): continue
		var delta: Vector3 = barrel.global_position-point
		if absf(delta.y)<1.8 and Vector2(delta.x,delta.z).length()<1.15: return false
	var ray := PhysicsRayQueryParameters3D.create(point+Vector3.UP*2,point-Vector3.UP,1024)
	var ground: Dictionary = get_world_3d().direct_space_state.intersect_ray(ray)
	if ground.is_empty() or absf(ground.position.y-point.y)>.2:
		return false
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.05,1.45,1.05)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform.basis = global_basis.orthonormalized()
	query.transform.origin = point+Vector3.UP*.8
	query.collision_mask = 1|2|4|8|32|64
	return get_world_3d().direct_space_state.intersect_shape(query,1).is_empty()

func next_output_position() -> Vector3:
	stock = stock.filter(func(ref): return is_instance_valid(ref.get_ref()) and not ref.get_ref().is_queued_for_deletion())
	for row in stock_rows:
		for column in stock_columns:
			# Fill each row from the middle out, then move away from the house.
			var offset := ceili(column/2.0)*(1 if column%2==0 else -1)
			var point := to_global(output.position+Vector3(offset*STOCK_SPACING,0,row*STOCK_SPACING))
			if _spot_free(point): return point
	return Vector3.INF

func output_reason(_arena) -> String:
	return "" if next_output_position().is_finite() else "Перед лавкой нет свободного места · забери часть бочек"

func purchase(arena) -> bool:
	if arena.crew.loot.coins<barrel_gold_cost: return false
	var point := next_output_position()
	if not point.is_finite(): return false
	serial += 1
	# Use the existing physical powder barrel, including hand pickup and impact blast.
	# Keep it out of target_specs so a purchased item never returns for free on reset.
	arena._spawn_target({"pos":point,"barrel":true,"entry_supply":true,"purchased":true,"id":50000+serial})
	var barrel = arena.targets.back()
	barrel.global_rotation.y = global_rotation.y
	last_barrel = weakref(barrel)
	stock.append(last_barrel)
	arena.crew.loot.coins -= barrel_gold_cost
	arena.sound.play("lock",-3.0,.8)
	arena.crew.tell("Бочка готова у лавки · F — рука · забери и брось")
	return true
