extends Node3D
## Playable greybox based on Levelart.pdf. Coordinates are metres, north is -Z.
const Geo = preload("res://scripts/geo.gd")
const A := Vector3(-60, 4, 46)
const B := Vector3(-28, 5, -46)
const C := Vector3(48, 4, 10)
const ENTRY_LENGTH := 96.0
const ENTRY_ATTACK_SIZE := 240
const ENTRY_SHIELD_EVERY := 6 # 200 ordinary + 40 guards: 600 hits, three perfect magazines.
const ENTRY_FRONT_DISTANCE := 26.0
const ENTRY_POWDER_CACHES := [Vector2(25,-3),Vector2(43,-3.4),Vector2(61.5,5)]
const ENTRY_WEST := -128.0-ENTRY_LENGTH
const ENTRY_RECT := Rect2(ENTRY_WEST,-10,ENTRY_LENGTH,20)
const WORLD_BOUNDS := Rect2(ENTRY_WEST,-88,164.0-ENTRY_WEST,176)
const START := Vector3(ENTRY_WEST+10, 0.04, 0)
const ENTRY_SUPPLIES := [Vector2(20,-4.8),Vector2(21.5,4.6),Vector2(36,-1.2),Vector2(44,4.4),Vector2(52,-4.2),Vector2(64,1.2)]
const ENTRY_PROP_LAYOUT := [
	[Vector2(-0.35,-2.6),1], [Vector2(0.15,-1.65),2], [Vector2(-0.2,-0.7),1], [Vector2(0.35,0.25),1],
	[Vector2(0,1.2),2], [Vector2(0.7,2.2),1], [Vector2(1.05,-1.4),1], [Vector2(1.5,1.45),2]]
const OUTLINE := [Vector2(-128,-10), Vector2(-114,-44), Vector2(-80,-78), Vector2(-14,-88), Vector2(40,-80), Vector2(84,-64), Vector2(116,-36), Vector2(128,-10), Vector2(128,10), Vector2(112,42), Vector2(80,70), Vector2(24,88), Vector2(-36,84), Vector2(-88,76), Vector2(-116,44), Vector2(-128,10)]
var arena
var terrain
var ground_mat := Geo.material(Color("897252"))
var rock_mat := Geo.material(Color("aa7756"))
var dark_mat := Geo.material(Color("48525b"))
var pad_mat := Geo.material(Color("958063"))
var house_mat := Geo.material(Color("8b7b68"))
var ore_mat := Geo.material(Color("967139"))
var accent_a := Geo.material(Color("786187"))
var accent_b := Geo.material(Color("547982"))
var accent_c := Geo.material(Color("92723f"))
var bridge_body: StaticBody3D
var bridge_guards: Array[StaticBody3D] = []
var gate: StaticBody3D
var gate_bars: Node3D
var gate_handle
var platform: MeshInstance3D
var weight: RigidBody3D
var unlocked := false
var gate_open := false
var gate_lift := 0.0
var ore: Array[StaticBody3D] = []
var ore_total := 0
var mined := 0
var mining := false
var mining_left := 0.0
var mine_defense_started := false
var completed := false
var encounters: Array[Dictionary] = []
var spawn_queue: Array[Dictionary] = []
var map_view
var current_zone := "ВХОД · АТАКА СКЕЛЕТОВ"
var last_safe := START
var automatic_encounters := true
var entry_barrel_positions: Array[Vector3] = []
var entry_prop_specs: Array[Dictionary] = []

func block(pos: Vector3, size: Vector3, mat: Material, solid: bool = true, yaw: float = 0.0) -> Node3D:
	var node: Node3D = StaticBody3D.new() if solid else Node3D.new()
	add_child(node)
	node.position = pos
	node.rotation.y = yaw
	Geo.box(node, size, Vector3.UP * size.y * 0.5, mat)
	if solid: Geo.collider(node, size, Vector3.UP * size.y * 0.5)
	return node

func _wall_segment(from: Vector3, to: Vector3, height: float = 7.0, width: float = 2.0) -> void:
	var node := block((from + to) * 0.5, Vector3(width, height, from.distance_to(to) + 0.05), rock_mat)
	node.look_at(to)

func _floor(pos: Vector3, size: Vector2, mat: Material) -> StaticBody3D:
	var body := block(pos-Vector3.UP*0.4,Vector3(size.x,0.4,size.y),mat) as StaticBody3D
	body.collision_layer=1|1024
	return body

func build_world() -> void:
	name = "CanyonLevel"
	terrain=load("res://scripts/canyon_terrain.gd").new()
	terrain.level=self
	add_child(terrain)
	# Flat collider beneath the polygon; no rectangular slab outside the canyon.
	var ground := _floor(Vector3.ZERO, Vector2(256,176), ground_mat)
	ground.get_child(0).hide()
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in OUTLINE.size():
		var a: Vector2 = OUTLINE[i]
		var b: Vector2 = OUTLINE[(i+1)%OUTLINE.size()]
		for point in [Vector3.ZERO,Vector3(a.x,0,a.y),Vector3(b.x,0,b.y)]:
			surface.set_normal(Vector3.UP)
			surface.add_vertex(point)
	Geo.mesh(self,surface.commit(),Vector3.ZERO,ground_mat)
	_floor(Vector3((ENTRY_WEST-138)*0.5,0,0), Vector2(ENTRY_LENGTH-10,20), pad_mat)
	_floor(Vector3(146,0,0), Vector2(36,20), pad_mat)
	for i in OUTLINE.size():
		var a: Vector2 = OUTLINE[i]
		var b: Vector2 = OUTLINE[(i + 1) % OUTLINE.size()]
		if a.x == b.x and absf(a.x) == 128.0: continue
		var edge := (b-a).normalized()
		terrain.cliff_chain(Vector3(a.x,0,a.y),Vector3(b.x,0,b.y),Vector3(edge.y,0,-edge.x),18.0+(i%3)*2.0)
	for side in [-1,1]:
		terrain.cliff_chain(Vector3(ENTRY_WEST,0,side*10),Vector3(-128,0,side*10),Vector3(0,0,side),15)
		terrain.cliff_chain(Vector3(128,0,side*10),Vector3(164,0,side*10),Vector3(0,0,side),16)
	terrain.cliff_chain(Vector3(ENTRY_WEST,0,-10),Vector3(ENTRY_WEST,0,10),Vector3.LEFT,15)
	terrain.cliff_chain(Vector3(164,0,-10),Vector3(164,0,10),Vector3.RIGHT,16)
	_floor(Vector3(-133,-5,0), Vector2(10,20), dark_mat)
	bridge_body = _floor(Vector3(-133,0,0), Vector2(10.2,6), dark_mat)
	for side in [-1,1]:
		Geo.box(bridge_body,Vector3(10.2,0.85,0.25),Vector3(0,0.825,side*2.9),rock_mat)
		Geo.collider(bridge_body,Vector3(10.2,0.85,0.25),Vector3(0,0.825,side*2.9))
	for x in [-138.0,-128.0]:
		var guard := StaticBody3D.new()
		add_child(guard)
		guard.position = Vector3(x,0,0)
		guard.collision_layer = 256 # Player safety edge; hand and projectiles pass.
		Geo.collider(guard, Vector3(0.25,9,20), Vector3.UP * 4.5)
		bridge_guards.append(guard)
	set_bridge(false)
	# Three large obstructions reproduce the sightline breaks on the layout.
	terrain.crag(Vector3(-79,0,-21),Vector3(11,14,12),1)
	terrain.crag(Vector3(-69,0,-16),Vector3(6,8,7),2)
	terrain.crag(Vector3(-85,0,-12),Vector3(5,6,5),0)
	_build_wreck()
	terrain.crag(Vector3(69,0,-43),Vector3(12,16,12),2)
	terrain.crag(Vector3(81,0,-38),Vector3(7,10,7),0)
	terrain.crag(Vector3(87,0,-34),Vector3(5,6,5),1)
	_build_a()
	_build_b()
	_build_c()

func _build_a() -> void:
	terrain.plateau(A,32)
	terrain.ramp(Vector3(A.x-34,0,A.z),A+Vector3(-16,0,0),5)
	terrain.ramp(Vector3(A.x-32,0,A.z-8),A+Vector3(-16,0,-8),4)
	for z in [-3.5,3.5]: terrain.crag(A+Vector3(-16,0,z),Vector3(2.8,7.5,2),0)
	terrain.crag(A+Vector3(11,0,-12),Vector3(6,3.5,5),2)
	terrain.crag(A+Vector3(-1,0,-13),Vector3(7,2.4,3),1)
	# A low passage and a roof physically exclude the tower and its overhead hand.
	var canopy_mat := Geo.material(Color(0.56,0.47,0.37,0.35))
	canopy_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	block(A+Vector3(-10,1.45,-8), Vector3(13,0.35,8), canopy_mat)
	block(A+Vector3(-17,1.45,-8), Vector3(3,0.35,5), canopy_mat)
	platform = Geo.box(self, Vector3(2.2,0.08,2.2), A+Vector3(-8.5,0.04,-8), Geo.material(Color("3a9687")))
	gate = StaticBody3D.new()
	add_child(gate)
	gate.position = A+Vector3(-16,0,0)
	Geo.collider(gate, Vector3(0.45,6.5,5), Vector3.UP*3.25)
	gate_bars = Node3D.new()
	gate.add_child(gate_bars)
	for i in 7: Geo.box(gate_bars,Vector3(0.22,6.3,0.15),Vector3(0,3.15,(i-3)*0.73),dark_mat)
	for y in [0.4,3.3,6.2]: Geo.box(gate_bars,Vector3(0.3,0.18,4.8),Vector3(0,y,0),dark_mat)
	block(A+Vector3(-16,6.5,0),Vector3(1.6,0.6,7),accent_a)
	gate_handle = load("res://scripts/level_handle.gd").new()
	gate_handle.level = self
	gate_handle.home = A+Vector3(-19,1.3,-3.9)
	add_child(gate_handle)
	Geo.line(self,A+Vector3(-8.5,0.12,-8),A+Vector3(-19,0.12,-3.9),0.06,accent_a)
	block(A+Vector3(8,0,-1),Vector3(3.6,1.2,2),house_mat)
	block(A+Vector3(8,1.2,-1),Vector3(4.1,0.2,2.4),dark_mat,false)
	for x in [6.0,10.0]: block(A+Vector3(x,0,-2),Vector3(0.22,3.4,0.22),dark_mat)
	block(A+Vector3(8,3.4,-1.6),Vector3(4.6,0.16,3),house_mat,false)

func _build_b() -> void:
	terrain.plateau(B,32)
	terrain.ramp(Vector3(B.x-34,0,B.z+4.5),B+Vector3(-16,0,4.5),5)
	terrain.crag(B+Vector3(-11,0,-11),Vector3(5,3,5),1)
	terrain.crag(B+Vector3(11,0,-11),Vector3(5,4,5),2)
	block(B+Vector3(-4,0,-11),Vector3(6,6,6),rock_mat)
	block(B+Vector3(4,0,-11),Vector3(6,6,6),rock_mat)
	block(B+Vector3(0,1.5,-11),Vector3(2,4.5,6),rock_mat)
	block(B+Vector3(0,0.008,3),Vector3(10,0.025,10),pad_mat,false)
	for i in 4: block(B+Vector3(0,0,-6.5-i*0.5),Vector3(2.5,0.04+i*0.03,0.5),pad_mat,false)

func _build_c() -> void:
	terrain.plateau(C,56)
	terrain.ramp(Vector3(C.x-46,0,C.z),C+Vector3(-28,0,0),7)
	terrain.ramp(Vector3(C.x-44,0,C.z+18),C+Vector3(-28,0,18),5)
	terrain.ramp(Vector3(C.x-16,0,C.z-44),C+Vector3(-16,0,-28),5)
	for pos in [Vector2(-17,-18),Vector2(-9,-21),Vector2(-14,-10),Vector2(-18,14),Vector2(-9,12),Vector2(-9,23)]:
		block(C+Vector3(pos.x,0,pos.y),Vector3(4.5,3.2,4),house_mat)
		block(C+Vector3(pos.x,3.2,pos.y),Vector3(4.9,0.3,4.4),dark_mat,false)
		block(C+Vector3(pos.x,3.5,pos.y),Vector3(4.3,0.16,3.9),pad_mat,false)
		block(C+Vector3(pos.x,0,pos.y+2.03),Vector3(0.9,1.9,0.05),dark_mat,false)
		block(C+Vector3(pos.x,2.2,pos.y+2.9),Vector3(3.8,0.14,2.1),accent_b,false)
		for side in [-1,1]: block(C+Vector3(pos.x+side*1.7,0,pos.y+3.7),Vector3(0.14,2.2,0.14),dark_mat,false)
	block(C+Vector3(-17,0.01,0),Vector3(13,0.03,12),pad_mat,false)

func _build_wreck() -> void:
	var wood := Geo.material(Color("5f4b3c"))
	var deck := block(Vector3(-34,0,4),Vector3(30,1.5,8),wood,true,-0.24)
	for side in [-1,1]:
		Geo.box(deck,Vector3(27,0.45,0.4),Vector3(0,3.5,side*3.6),wood)
		for x in range(-12,15,4):
			var rib := Geo.box(deck,Vector3(0.38,3.1,0.4),Vector3(x,2.7,side*3.3),wood)
			rib.rotation.x=side*0.22
	var mast := Geo.box(deck,Vector3(0.55,10,0.55),Vector3(-2,5.2,0),wood)
	mast.rotation.z=-0.28
	Geo.box(deck,Vector3(8,0.3,0.3),Vector3(-4,7,0),wood)

func ground_height(point: Vector3) -> float:
	return terrain.height_at(point) if terrain else 0.0

func set_bridge(opened: bool) -> void:
	bridge_body.visible = opened
	bridge_body.collision_layer = (1|1024) if opened else 0
	for guard in bridge_guards: guard.collision_layer = 0 if opened else 256
	if arena.battle: arena.battle.nav_dirty = true

func build_targets() -> void:
	# Powder chains along the advancing column reward a well-timed shot.
	# Offset powder caches sit by the barricades; each chain is local.
	for center in ENTRY_POWDER_CACHES:
		for x in [-1.2,1.2]:
			for z in [-1.4,1.4]:
				var pos := START+Vector3(center.x+x,-START.y,center.y+z)
				entry_barrel_positions.append(pos)
				arena.target_specs.append({"pos":pos,"barrel":true,"entry_supply":true,"id":arena.target_specs.size()+1})
	for cache in ENTRY_SUPPLIES:
		for item in ENTRY_PROP_LAYOUT:
			var offset: Vector2 = item[0]
			entry_prop_specs.append({"pos":START+Vector3(cache.x+offset.x,-START.y,cache.y+offset.y),"kind":item[1],"yaw":sin(cache.x+offset.y*2.7)*0.24})
	for pos in [Vector3(-113,0,10),Vector3(-7,0,-32),Vector3(0,0,-53),Vector3(-30,0,63),C+Vector3(-22,0,-3),C+Vector3(-21,0,21)]:
		arena.target_specs.append({"pos":pos,"barrel":true,"id":arena.target_specs.size()+1})
	for spec in arena.target_specs: arena._spawn_target(spec)

func setup_gameplay() -> void:
	unlocked = false
	gate_open = false
	gate_lift = 0.0
	gate.collision_layer = 1
	gate_bars.position.y = 0
	gate_handle.reset()
	platform.position.y = A.y+0.04
	mining = false
	mined = 0
	mining_left = 0.0
	mine_defense_started = false
	completed = false
	spawn_queue.clear()
	ore.clear()
	arena.tank.position = START
	arena.tank.rotation.y = -PI/2
	arena.tank.turret_yaw = -PI/2
	arena.tank.collision_mask |= 256
	arena.tank.walker.reset_pose()
	last_safe = START
	arena.focus = START
	arena.aim_position = START+Vector3(16,1,0)
	arena.ground_aim_position = START+Vector3(16,0,0)
	arena.zoom = 30
	arena.camera_yaw = -PI/4 # Look along the approach so the front is visible at spawn.
	arena.crew.formation_spacing = 0.85
	for member in arena.crew.members:
		member.extra_collision_mask = 256
		member.visual.scale = Vector3.ONE * 0.65
		member.health_label.position.y = 1.0
		var shape: CollisionShape3D = member.get_child(0)
		shape.shape.radius = 0.19
		shape.shape.height = 0.70
		shape.position.y = 0.35
	weight = arena.crew.loot.spawn_cargo(A+Vector3(-12,0,-8),1)
	weight.set_meta("hand_label","ГРУЗ ДЛЯ ВЕСОВОЙ ПЛАТФОРМЫ")
	for pos in [Vector3(0,0,44),Vector3(-8,0,-76),Vector3(-42,0,73),B+Vector3(-10,0,1),B+Vector3(10,0,7),C+Vector3(-20,0,8)]:
		arena.crew.loot._spawn_chest(pos)
	for pos in [Vector3(-8,0,-74),Vector3(-41,0,72),B+Vector3(-9,0,3),B+Vector3(11,0,9)]: arena.crew.loot.spawn_cargo(pos,1)
	for spec in entry_prop_specs:
		var prop = arena.props.spawn_prop(spec.pos,spec.kind)
		prop.rotation.y = spec.yaw
		prop.set_meta("entry_supply",true)
	for pos in [Vector3(-100,0,20),Vector3(3,0,-20),Vector3(15,0,-66),Vector3(-18,0,74),C+Vector3(-20,0,-6),B+Vector3(9,0,5)]:
		for i in 4: arena.props.spawn_prop(pos+Vector3((i%2)*1.4,0,(i/2)*1.4),i%3)
	for x in range(-1,9):
		for z in range(-9,10):
			var p := Vector2((x-4)*2.5/13.0,z*2.5/23.0)
			if p.length_squared() > 1.0 or ((x+z)%9 == 0 and x < 1): continue
			_spawn_ore(C+Vector3(x*2.5,0,z*2.5),2.0+float(posmod(x+z,3))*0.65)
	ore_total = ore.size()
	encounters.assign([
		{"name":"Б1 · ДОРОЖНЫЙ БОЙ","pos":Vector3(-99,0,19),"count":18,"giants":1,"radius":23.0,"triggered":false},
		{"name":"Б2 · ДОРОЖНЫЙ БОЙ","pos":Vector3(4,0,-19),"count":24,"giants":2,"radius":24.0,"triggered":false},
		{"name":"Б3 · ОХРАНА ЛУТА","pos":Vector3(14,0,-68),"count":18,"giants":1,"radius":19.0,"triggered":false},
		{"name":"Б4 · ОХРАНА ЛУТА","pos":Vector3(-18,0,73),"count":24,"giants":2,"radius":20.0,"triggered":false},
		{"name":"Л1 · УСИЛЕННАЯ ОХРАНА","pos":Vector3(0,0,44),"count":30,"giants":3,"radius":14.0,"triggered":false}])
	if map_view == null:
		map_view = load("res://scripts/level_map.gd").new()
		map_view.level = self
		arena.hud.add_child(map_view)
	map_view.hide()
	_queue_entry_attack()
	arena.crew.tell("Впереди скелеты · красные бочки помогут прорваться")

func _queue_entry_attack() -> void:
	# One continuous column: every rank advances from the start. Sample free
	# slots evenly so avoiding props never bunches the whole wave at the front.
	var slots: Array[Vector3] = []
	for i in 12*35:
		var row: int = i/12
		var column: int = i%12
		var pos := START+Vector3(ENTRY_FRONT_DISTANCE+row*1.35+sin(i*2.3)*0.12,0,(column-5.5)*1.35+cos(i*1.7)*0.12)
		if _entry_spawn_open(pos): slots.append(pos)
	assert(slots.size()>=ENTRY_ATTACK_SIZE,"Entry supplies must leave space for the wave")
	for i in ENTRY_ATTACK_SIZE:
		var slot := roundi(float(i)*(slots.size()-1)/(ENTRY_ATTACK_SIZE-1))
		spawn_queue.append({"entry_pos":slots[slot],"shield_guard":i%ENTRY_SHIELD_EVERY==2})

func _entry_spawn_open(pos: Vector3) -> bool:
	# Reserve object footprints before the physics world has synchronized on R.
	var cell := Vector3(roundf(pos.x),0,roundf(pos.z))
	for barrel in entry_barrel_positions:
		if absf(pos.x-barrel.x)<0.98 and absf(pos.z-barrel.z)<0.98: return false
		if absf(cell.x-barrel.x)<1.04 and absf(cell.z-barrel.z)<1.04: return false
	for spec in entry_prop_specs:
		if absf(pos.x-spec.pos.x)<0.96 and absf(pos.z-spec.pos.z)<0.96: return false
		if absf(cell.x-spec.pos.x)<1.05 and absf(cell.z-spec.pos.z)<1.05: return false
	# Folded bridge section and its pickup space stay clear too.
	return not (absf(pos.x+147)<2.1 and absf(pos.z+6.5)<1.8)

func _spawn_ore(pos: Vector3, height: float) -> void:
	var node := block(pos,Vector3(2.42,height,2.42),ore_mat) as StaticBody3D
	node.set_meta("ore",true)
	node.set_meta("target",true)
	node.set_meta("hp",80.0)
	node.set_meta("spec",{"pos":pos,"barrel":false,"ore":true,"id":1000+ore.size()})
	ore.append(node)
	arena.targets.append(node)

func damage_ore(node: StaticBody3D, amount: float, direction: Vector3) -> void:
	if not ore.has(node): return
	var hp: float = node.get_meta("hp")-amount
	node.set_meta("hp",hp)
	if hp > 0.0: return
	ore.erase(node)
	arena.targets.erase(node)
	node.collision_layer = 0
	node.queue_free()
	mined += 1
	arena.crew.loot.supplies += 1
	arena.hit_pulse = 1.0
	arena.battle.nav_dirty = true
	arena.fx.dust(node.position,direction*6)
	arena.sound.play("shatter",-12.0,0.8)
	if not mine_defense_started and automatic_encounters: _start_mine_defense()

func _start_mine_defense() -> void:
	mine_defense_started = true
	for entrance in [C+Vector3(-33,0,0),C+Vector3(-16,0,-33),C+Vector3(-33,0,18)]:
		_queue_encounter(entrance,20,1)
	arena.crew.tell("Шахта разбужена: враги идут через три входа!")

func _queue_encounter(center: Vector3, count: int, giants: int) -> void:
	for i in count: spawn_queue.append({"center":center,"giant":i<giants,"tries":0,"slot":i})

func _spawn_batch() -> void:
	var attempts := 0
	while not spawn_queue.is_empty() and attempts < 10:
		var entry: Dictionary = spawn_queue.pop_front()
		attempts += 1
		if entry.has("entry_pos"):
			var enemy = arena.battle.spawn_enemy(entry.entry_pos,false,entry.shield_guard)
			enemy.attack_on_spawn = true
			enemy.scan_left = 0.0
			continue
		var angle: float = float(entry.slot)*2.399 + float(entry.tries)*0.8
		var radius: float = 2.5+float(entry.slot%5)*1.5+float(entry.tries)*0.45
		var pos: Vector3 = entry.center+Vector3(cos(angle),0,sin(angle))*radius
		if arena.world_bounds.has_point(Vector2(pos.x,pos.z)) and pos.distance_to(arena.crew.center()) > 5.0 and arena.battle._spawn_clear(pos,entry.giant):
			arena.battle.spawn_enemy(pos,entry.giant)
		elif entry.tries < 30:
			entry.tries += 1
			spawn_queue.append(entry)

func open_gate() -> void:
	if not unlocked or gate_open: return
	gate_open = true
	arena.sound.play("chamber",-2.0,0.65)
	arena.crew.tell("Ворота подняты и зафиксированы. Башня может пройти к верстаку")

func context_action() -> Dictionary:
	var pos: Vector3 = arena.crew.center()
	if gate_open and arena.crew.crewed and pos.distance_to(A+Vector3(7,0,0)) < 5.5:
		return {"kind":"level","id":"workbench","text":"E  ВЕРСТАК · ПОЧИНИТЬ БАШНЮ / ПОПОЛНИТЬ БОЛТЫ"}
	if not arena.crew.crewed and arena.crew.loot.cargo == null and not ore.is_empty() and pos.distance_to(C+Vector3(-6,0,0)) < 10:
		return {"kind":"level","id":"mine","text":"E  " + ("ОСТАНОВИТЬ ДОБЫЧУ" if mining else "РАБОЧИЕ: ДОБЫВАТЬ БЛИЖНЮЮ ПОРОДУ")}
	return {}

func interact(id: String) -> void:
	if id == "workbench":
		arena.tank.hp = arena.tank.MAX_HP
		arena.tank.crossbows.reset()
		arena.sound.play("ready",-5.0)
		arena.crew.tell("Башня обслужена · прочность и арбалеты восстановлены")
	elif id == "mine":
		if arena.crew.role_count("worker") == 0:
			arena.crew.tell("Для добычи нужны рабочие; породу можно разбить пушкой")
			return
		mining = not mining
		mining_left = 0.0
		arena.crew.tell("Добыча включена · подводи рабочих к открывающемуся фронту породы" if mining else "Добыча остановлена")

func tick(dt: float) -> void:
	if arena.tuning_open: return
	var center: Vector3 = arena.crew.center()
	current_zone = "ПУСТЫНЯ · СВОБОДНЫЙ МАРШРУТ"
	if center.x < -128: current_zone = "ВХОД · АТАКА СКЕЛЕТОВ И МОСТ"
	elif center.distance_to(A) < 24: current_zone = "A · ПАЗЛ И ВЕРСТАК"
	elif center.distance_to(B) < 24: current_zone = "B · ВХОД В ДАНЖ"
	elif center.distance_to(C) < 40: current_zone = "C · ДОБЫЧА И ОБОРОНА"
	elif center.x > 128: current_zone = "ВЫХОД ИЗ КАНЬОНА"
	if is_instance_valid(weight) and not gate_open:
		var ready: bool = weight.position.distance_to(A+Vector3(-8.5,0.48,-8)) < 1.35 and weight.position.y < A.y+0.9 and not weight.has_meta("hand_owner") and arena.crew.loot.cargo != weight
		if ready != unlocked:
			unlocked = ready
		platform.position.y = move_toward(platform.position.y,A.y+(0.015 if ready else 0.04),dt*0.3)
	gate_lift = move_toward(gate_lift,6.6 if gate_open else 0.0,dt*4.0)
	gate_bars.position.y = gate_lift
	var layer := 0 if gate_lift > 6.3 else 1
	if gate.collision_layer != layer:
		gate.collision_layer = layer
		arena.battle.nav_dirty = true
	if automatic_encounters:
		for encounter in encounters:
			if not encounter.triggered and center.distance_to(encounter.pos) < encounter.radius:
				encounter.triggered = true
				_queue_encounter(encounter.pos,encounter.count,encounter.giants)
				arena.crew.tell(encounter.name)
	_spawn_batch()
	if mining and not arena.crew.crewed and not arena.crew.members.is_empty():
		mining_left -= dt
		if mining_left <= 0:
			mining_left = 1.2
			var nearest: StaticBody3D
			var distance := 8.0
			var workers: Array = arena.crew.combat._available("worker")
			for node in ore:
				var d := node.position.distance_to(center)
				if d < distance and arena.strike_clear(center,node.position):
					distance = d
					nearest = node
			if nearest and not workers.is_empty():
				for worker in workers: worker.action_pulse = 1.0
				damage_ore(nearest,40.0*workers.size(),Vector3.UP)
	if center.x > 153 and not completed:
		completed = true
		arena.crew.tell("Маршрут пройден! Можно вернуться к атоллам · R — начать уровень заново")
	if arena.tank.position.y < -2:
		arena.tank.position = last_safe
		arena.tank.stop_drive()
		arena.tank.walker.reset_pose()
	elif arena.tank.position.y >= -0.1: last_safe = arena.tank.position
	if map_view.visible: map_view.queue_redraw()
	terrain.update_occlusion(arena.camera,center)

func toggle_map() -> void:
	map_view.visible = not map_view.visible
	map_view.queue_redraw()
