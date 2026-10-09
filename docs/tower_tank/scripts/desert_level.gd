extends Node3D
## Playable greybox based on Levelart.pdf. Coordinates are metres, north is -Z.
const Geo = preload("res://scripts/geo.gd")
var A := Vector3(-60, 4, 46)
var B := Vector3(-28, 5, -46)
var C := Vector3(48, 4, 10)
const ENTRY_LENGTH := 96.0
var ENTRY_ATTACK_SIZE := 240
const ENTRY_SHIELD_EVERY := 6 # 200 ordinary + 40 guards: 600 hits, three perfect magazines.
const ENTRY_FRONT_DISTANCE := 26.0
var WORLD_SKELETONS := 120
const WORLD_SHIELD_EVERY := 8 # 105 ordinary skeletons and 15 guards.
const ORE_HEALTH := 100.0
const MINING_DAMAGE := 20.0
const MINING_INTERVAL := 0.65
const ORE_CELL_SIZE := 2.5
const WORLD_SPACING := 7.5
const ENTRY_POWDER_CACHES := [Vector2(25,-3),Vector2(43,-3.4),Vector2(61.5,5)]
const ENTRY_WEST := -128.0-ENTRY_LENGTH
@export_group("Map bounds")
@export var ENTRY_RECT := Rect2(ENTRY_WEST,-10,ENTRY_LENGTH,20)
@export var WORLD_BOUNDS := Rect2(ENTRY_WEST,-88,164.0-ENTRY_WEST,176)
var START := Vector3(ENTRY_WEST+10, 0.04, 0)
const BRIDGE_DOOR_POSITION := Vector3(-124,0,0)
const ENTRY_SUPPLIES := [Vector2(20,-4.8),Vector2(21.5,4.6),Vector2(36,-1.2),Vector2(44,4.4),Vector2(52,-4.2),Vector2(64,1.2)]
const ENTRY_PROP_LAYOUT := [
	[Vector2(-0.35,-2.6),1], [Vector2(0.15,-1.65),2], [Vector2(-0.2,-0.7),1], [Vector2(0.35,0.25),1],
	[Vector2(0,1.2),2], [Vector2(0.7,2.2),1], [Vector2(1.05,-1.4),1], [Vector2(1.5,1.45),2]]
const OUTLINE := [Vector2(-128,-10), Vector2(-114,-44), Vector2(-80,-78), Vector2(-14,-88), Vector2(40,-80), Vector2(84,-64), Vector2(116,-36), Vector2(128,-10), Vector2(128,10), Vector2(112,42), Vector2(80,70), Vector2(24,88), Vector2(-36,84), Vector2(-88,76), Vector2(-116,44), Vector2(-128,10)]
var arena
var terrain
var dressing
var ground_mat: Material = Geo.material(Color("68746a"))
var rock_mat: Material = Geo.material(Color("89958d"))
var dark_mat := Geo.material(Color("48525b"))
var pad_mat: Material = Geo.material(Color("9a9e8c"))
var house_mat: Material = Geo.material(Color("98aaa3"))
var ore_mat: Material = Geo.material(Color("718781"))
var accent_a := Geo.material(Color("786187"))
var accent_b := Geo.material(Color("547982"))
var accent_c := Geo.material(Color("92723f"))
var bridge_body: StaticBody3D
var bridge_guards: Array[StaticBody3D] = []
var bridge_door
var gate: StaticBody3D
var gate_bars: Node3D
var gate_handle
var platform: MeshInstance3D
var weight: RigidBody3D
var unlocked := false
var gate_open := false
var gate_lift := 0.0
var ore: Array[StaticBody3D] = []
var ore_cells: Dictionary = {}
var mining_time := 0.0
var ore_total := 0
var mined := 0
var mining := false
var mine_defense_started := false
var defense_waves
var completed := false
var encounters: Array[Dictionary] = []
var spawn_queue: Array[Dictionary] = []
var map_view
var current_zone := "ВХОД · АТАКА СКЕЛЕТОВ"
var last_safe := START
var automatic_encounters := true
var entry_barrel_positions: Array[Vector3] = []
var entry_prop_specs: Array[Dictionary] = []
var world_spawn_positions: Array[Vector3] = []
var world_probe := CapsuleShape3D.new()
var world_population_pending := false
var world_sync_frames := 0
@export var authored := false
var layout
var platform_rest := Vector3.ZERO
var gate_bars_rest := Vector3.ZERO

func bind_authored_world() -> void:
	layout = preload("res://scripts/canyon_layout.gd").new()
	layout.level = self
	layout.bind()

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
	dressing = load("res://scripts/canyon_dressing.gd").new()
	dressing.level = self
	add_child(dressing)
	ground_mat = dressing.ground_material
	pad_mat = dressing.worn_material
	rock_mat = dressing.stone_material
	ore_mat = dressing.ore_material
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
	_build_bridge_fence()
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
	dressing.build()

func _build_bridge_fence() -> void:
	var wood := Geo.material(Color("776047"))
	var beams := Geo.material(Color("4d3829"))
	for side in [-1,1]:
		var fence := StaticBody3D.new()
		fence.name = "BridgeFenceLeft" if side<0 else "BridgeFenceRight"
		add_child(fence)
		fence.position = BRIDGE_DOOR_POSITION+Vector3(0,0,side*13.0)
		fence.collision_layer = 1
		fence.collision_mask = 0
		Geo.collider(fence,Vector3(0.55,4.8,20),Vector3.UP*2.4)
		for i in 24:
			Geo.box(fence,Vector3(0.32,4.2,0.68),Vector3(0,2.1,-9.6+i*0.835),wood)
		for y in [0.7,3.5]: Geo.box(fence,Vector3(0.18,0.24,20),Vector3(-0.23,y,0),beams)
		for z in [-9.7,0.0,9.7]: Geo.box(fence,Vector3(0.75,4.8,0.55),Vector3(0,2.4,z),beams)
	bridge_door = load("res://scripts/level_dash_gate.gd").new()
	bridge_door.level = self
	bridge_door.position = BRIDGE_DOOR_POSITION
	add_child(bridge_door)

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
	if authored:
		layout.build_targets()
		return
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
	defense_waves = get_node_or_null("AtollC/DefenseWaves")
	if defense_waves: defense_waves.setup(arena)
	if arena.defenses: arena.defenses.reset()
	bridge_door.reset()
	unlocked = false
	gate_open = false
	gate_lift = 0.0
	gate.collision_layer = 1
	gate_bars.position = gate_bars_rest
	gate_handle.reset()
	if authored: platform.global_position = platform_rest
	else: platform.position.y = A.y+0.04
	mining = false
	mined = 0
	mine_defense_started = false
	completed = false
	spawn_queue.clear()
	ore.clear()
	ore_cells.clear()
	mining_time = 0.0
	arena.tank.position = START
	arena.tank.rotation.y = -PI/2
	arena.tank.turret_yaw = -PI/2
	if authored:
		arena.tank.rotation.y = layout.player_transform.basis.get_euler().y
		arena.tank.turret_yaw = arena.tank.rotation.y
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
	if authored:
		layout.spawn_gameplay()
	else:
		_spawn_generated_gameplay()
	ore_total = ore.size()
	encounters.clear()
	if map_view == null:
		map_view = load("res://scripts/level_map.gd").new()
		map_view.level = self
		arena.hud.add_child(map_view)
	map_view.hide()
	_queue_entry_attack()
	world_population_pending=true
	world_sync_frames=2 # Newly added colliders need a physics synchronization first.
	arena.crew.tell("Впереди скелеты · красные бочки помогут прорваться")

func _spawn_generated_gameplay() -> void:
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

func _world_spawn_open(pos: Vector3, exclude: Array[RID] = []) -> bool:
	var point := Vector2(pos.x,pos.z)
	var in_canyon := Geometry2D.is_point_in_polygon(point,PackedVector2Array(OUTLINE))
	var in_exit := pos.x>=128 and pos.x<=160 and absf(pos.z)<7.0
	if not in_canyon and not in_exit: return false
	# Leave room to land the super dash and read the open canyon beyond the door.
	if pos.x<-113 or absf(ground_height(pos))>0.01: return false
	for shelf in terrain.shelves:
		if shelf.bounds.grow(3.0).has_point(point): return false
	for ramp in terrain.ramps:
		var offset: Vector3 = pos-ramp.from
		var along: float = offset.dot(ramp.direction)
		if along>-3 and along<ramp.length+3 and absf(offset.dot(ramp.side))<ramp.width*0.5+2.0: return false
	world_probe.radius=0.55
	world_probe.height=2.0
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape=world_probe
	query.transform.origin=pos+Vector3.UP*1.15
	query.collision_mask=1|8|32
	if not exclude.is_empty():
		query.collision_mask|=2|4|64
		query.exclude=exclude
	return get_world_3d().direct_space_state.intersect_shape(query,1).is_empty()

func _queue_world_population() -> void:
	world_population_pending=false
	if authored:
		layout.queue_enemies(true)
		return
	# A jittered lattice distributes the initial population over the whole floor;
	# queue batches are only loading work, never proximity-triggered encounters.
	if world_spawn_positions.size()!=WORLD_SKELETONS:
		var random := RandomNumberGenerator.new()
		random.seed=94621
		var slots: Array[Vector3] = []
		for row in range(22):
			for column in range(37):
				var pos := Vector3(-110+column*WORLD_SPACING,0,-79+row*WORLD_SPACING)
				pos+=Vector3(random.randf_range(-1.4,1.4),0,random.randf_range(-1.4,1.4))
				if _world_spawn_open(pos): slots.append(pos)
		assert(slots.size()>=WORLD_SKELETONS,"The canyon needs enough free resident slots")
		world_spawn_positions.clear()
		for i in WORLD_SKELETONS:
			var slot := roundi(float(i)*(slots.size()-1)/(WORLD_SKELETONS-1))
			world_spawn_positions.append(slots[slot])
	for i in WORLD_SKELETONS:
		spawn_queue.append({"world_pos":world_spawn_positions[i],"shield_guard":i%WORLD_SHIELD_EVERY==2,"slot":i})

func _queue_entry_attack() -> void:
	if authored:
		layout.queue_enemies(false)
		return
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
	node.set_meta("hp",ORE_HEALTH)
	node.set_meta("ore_height", height)
	node.set_meta("spec",{"pos":pos,"barrel":false,"ore":true,"id":1000+ore.size()})
	ore.append(node)
	var cell := _ore_cell(pos)
	if not ore_cells.has(cell): ore_cells[cell] = []
	ore_cells[cell].append(node)
	arena.targets.append(node)

func damage_ore(node: StaticBody3D, amount: float, direction: Vector3, by_mining: bool = false) -> void:
	if not ore.has(node): return
	var hp: float = node.get_meta("hp")-amount
	node.set_meta("hp",hp)
	if hp > 0.0:
		if not by_mining:
			arena.fx.repeater_hit(node.global_position + Vector3.UP * 0.7, -direction)
			arena.sound.play("lock", -15.0, 0.75)
		return
	ore.erase(node)
	var cell := _ore_cell(node.global_position)
	ore_cells[cell].erase(node)
	if ore_cells[cell].is_empty(): ore_cells.erase(cell)
	arena.targets.erase(node)
	node.collision_layer = 0
	node.queue_free()
	mined += 1
	var out := -direction
	out.y = 0.0
	if out.length_squared() < 0.01: out = Vector3.LEFT
	out = out.normalized()
	arena.crew.loot.spawn_crystal(node.global_position + Vector3.UP * 0.7 + out * 0.35, out * 2.0 + Vector3.UP * 3.0)
	arena.hit_pulse = 1.0
	arena.battle.nav_dirty = true
	arena.fx.dust(node.position,direction*6)
	arena.sound.play("shatter",-12.0,0.8)
	if not mine_defense_started and automatic_encounters: _start_mine_defense()

func _start_mine_defense() -> void:
	mine_defense_started = true
	if defense_waves:
		# Separate story hook; no wave uses this event until a designer assigns it.
		defense_waves.notify_story_event(&"first_ore_mined")
		return
	if authored:
		layout.queue_mine_defense()
	else:
		for entrance in [C+Vector3(-33,0,0),C+Vector3(-16,0,-33),C+Vector3(-33,0,18)]:
			_queue_encounter(entrance,20,1)
	arena.crew.tell("Шахта разбужена: враги идут через три входа!")

func _queue_encounter(center: Vector3, count: int, giants: int) -> void:
	for i in count: spawn_queue.append({"center":center,"giant":i<giants,"tries":0,"slot":i})

func _spawn_batch() -> void:
	if world_population_pending:
		world_sync_frames-=1
		if world_sync_frames<=0: _queue_world_population()
	var attempts := 0
	while not spawn_queue.is_empty() and attempts < 10:
		var entry: Dictionary = spawn_queue.pop_front()
		attempts += 1
		if entry.has("entry_pos"):
			var enemy = arena.battle.spawn_enemy(entry.entry_pos,entry.get("giant",false),entry.shield_guard)
			if entry.has("yaw"): enemy.rotation.y = entry.yaw
			enemy.attack_on_spawn = true
			enemy.scan_left = 0.0
			continue
		if entry.has("world_pos"):
			var enemy = arena.battle.spawn_enemy(entry.world_pos,entry.get("giant",false),entry.shield_guard)
			enemy.world_resident=true
			enemy.rotation.y=entry.get("yaw",sin(float(entry.slot)*2.399)*PI)
			enemy.setup_patrol(entry.slot)
			continue
		var angle: float = float(entry.slot)*2.399 + float(entry.tries)*0.8
		var radius: float = 2.5+float(entry.slot%5)*1.5+float(entry.tries)*0.45
		var pos: Vector3 = entry.center+Vector3(cos(angle),0,sin(angle))*radius
		if arena.world_bounds.has_point(Vector2(pos.x,pos.z)) and pos.distance_to(arena.crew.center()) > 5.0 and arena.battle._spawn_clear(pos,entry.giant):
			arena.battle.spawn_enemy(pos,entry.giant)
		elif entry.tries < 30:
			entry.tries += 1
			spawn_queue.append(entry)

func cancel_spawning() -> void:
	spawn_queue.clear()
	world_population_pending=false
	world_sync_frames=0

func open_gate() -> void:
	if not unlocked or gate_open: return
	gate_open = true
	arena.sound.play("chamber",-2.0,0.65)
	arena.crew.tell("Ворота подняты и зафиксированы. Башня может пройти к верстаку")

func context_action() -> Dictionary:
	var pos: Vector3 = arena.crew.center()
	var workbench: Vector3 = layout.workbench_position if authored else A+Vector3(7,0,0)
	if gate_open and arena.crew.crewed and pos.distance_to(workbench) < 5.5:
		return {"kind":"level","id":"workbench","text":"E  ВЕРСТАК · ПОЧИНИТЬ БАШНЮ / ПОПОЛНИТЬ БОЛТЫ"}
	return {}

func interact(id: String) -> void:
	if id == "workbench":
		arena.tank.hp = arena.tank.MAX_HP
		arena.tank.crossbows.reset()
		arena.sound.play("ready",-5.0)
		arena.crew.tell("Башня обслужена · прочность и арбалеты восстановлены")

func _ore_cell(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x/ORE_CELL_SIZE),floori(pos.z/ORE_CELL_SIZE))

func _contact_ore(member: CharacterBody3D) -> StaticBody3D:
	# Slide contacts cover walking into a vein; the short surface check keeps
	# digging after releasing WASD while standing against the same face.
	for index in member.get_slide_collision_count():
		var body = member.get_slide_collision(index).get_collider()
		if body is StaticBody3D and ore.has(body): return body
	var nearest: StaticBody3D
	var distance := 0.36
	# Check only neighbouring cells instead of scanning the entire ore field
	# for each dwarf on every physics tick, including outside the mine.
	var cell := _ore_cell(member.global_position)
	var candidates: Array = []
	for x in range(-1,2):
		for z in range(-1,2): candidates.append_array(ore_cells.get(cell+Vector2i(x,z),[]))
	for node in candidates:
		var p: Vector3 = member.global_position - node.global_position
		if p.y < -0.3 or p.y > float(node.get_meta("ore_height")) + 0.2: continue
		var face: Vector3 = Vector3(clampf(p.x,-1.21,1.21),p.y+0.35,clampf(p.z,-1.21,1.21)) + node.global_position
		var gap := Vector2(member.global_position.x-face.x,member.global_position.z-face.z).length()
		if gap >= distance: continue
		var ray := PhysicsRayQueryParameters3D.create(member.global_position+Vector3.UP*0.35,face,1,[node.get_rid()])
		if not get_world_3d().direct_space_state.intersect_ray(ray).is_empty(): continue
		distance = gap
		nearest = node
	return nearest

func _mining_impact(node: StaticBody3D, from: Vector3) -> void:
	var visual: MeshInstance3D
	for child in node.get_children():
		if child is MeshInstance3D: visual = child; break
	if visual == null: return
	# Only an actively mined vein needs private flash state. Untouched ore
	# keeps the shared material to avoid extra render-state changes.
	if not visual.has_meta("mining_material"):
		if visual.material_override: visual.material_override=visual.material_override.duplicate()
		visual.set_meta("mining_material",true)
	var mat := visual.material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("hit_flash",1.0)
		var flash := visual.create_tween()
		flash.tween_method(func(value: float): mat.set_shader_parameter("hit_flash",value),1.0,0.0,0.24).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var out := from-node.global_position
	out.y=0.0
	out=out.normalized() if out.length_squared()>0.001 else Vector3.LEFT
	if not visual.has_meta("mining_rest"): visual.set_meta("mining_rest",visual.position)
	var rest: Vector3 = visual.get_meta("mining_rest")
	var local_out := node.global_basis.inverse()*out
	# Animate only the mesh. Collision, ore lookup and navigation stay fixed.
	visual.position=rest
	var shake := visual.create_tween()
	shake.tween_property(visual,"position",rest-local_out*0.075,0.035).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	shake.tween_property(visual,"position",rest+local_out*0.028,0.055)
	shake.tween_property(visual,"position",rest,0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var bounds := visual.get_aabb()
	var local := visual.to_local(from+Vector3.UP*0.48).clamp(bounds.position,bounds.end)
	var hit := visual.to_global(local)+out*0.08
	arena.fx.mining_hit(hit,out)
	arena.sound.play("bolt_hit",-6.0,0.7)

func _tick_mining(dt: float) -> void:
	mining = false
	mining_time += dt
	if arena.crew.crewed: return
	var miners: Dictionary = {}
	for member in arena.crew.members:
		if member.hauling: continue
		var target := _contact_ore(member)
		if target == null: continue
		mining = true
		if not miners.has(target): miners[target] = []
		miners[target].append(member)
	for target in miners:
		# One group hit per vein and interval: simultaneous dwarf contacts must
		# not multiply damage enough to destroy a fresh block in one frame.
		if mining_time + 0.000001 < float(target.get_meta("next_mining_hit",0.0)): continue
		target.set_meta("next_mining_hit",mining_time+MINING_INTERVAL)
		var from := Vector3.ZERO
		for member in miners[target]:
			member.action_pulse = 1.0
			from += member.global_position
		from /= miners[target].size()
		var direction: Vector3 = target.global_position - from
		direction.y = 0.0
		_mining_impact(target,from)
		damage_ore(target,MINING_DAMAGE,direction.normalized(),true)

func tick(dt: float) -> void:
	if arena.tuning_open: return
	if arena.defenses: arena.defenses.tick(dt)
	if defense_waves: defense_waves.tick(dt)
	var center: Vector3 = arena.crew.center()
	current_zone = "ПУСТЫНЯ · СВОБОДНЫЙ МАРШРУТ"
	if ENTRY_RECT.has_point(Vector2(center.x,center.z)): current_zone = "ВХОД · АТАКА СКЕЛЕТОВ И МОСТ"
	elif center.distance_to(A) < 24: current_zone = "A · ПАЗЛ И ВЕРСТАК"
	elif center.distance_to(B) < 24: current_zone = "B · ВХОД В ДАНЖ"
	elif center.distance_to(C) < 40: current_zone = "C · ДОБЫЧА И ОБОРОНА"
	elif center.x > 128: current_zone = "ВЫХОД ИЗ КАНЬОНА"
	if is_instance_valid(weight) and not gate_open:
		var plate: Vector3 = platform_rest if authored else A+Vector3(-8.5,0.04,-8)
		var ready: bool = weight.global_position.distance_to(plate+Vector3.UP*0.44) < 1.35 and weight.global_position.y < plate.y+0.86 and not weight.has_meta("hand_owner") and arena.crew.loot.cargo != weight
		if ready != unlocked:
			unlocked = ready
		platform.global_position.y = move_toward(platform.global_position.y,plate.y+(-0.025 if ready else 0.0),dt*0.3)
	gate_lift = move_toward(gate_lift,6.6 if gate_open else 0.0,dt*4.0)
	gate_bars.position = gate_bars_rest+Vector3.UP*gate_lift
	var layer := 0 if gate_lift > 6.3 else 1
	if gate.collision_layer != layer:
		gate.collision_layer = layer
		arena.battle.nav_dirty = true
	_spawn_batch()
	_tick_mining(dt)
	if center.x > 153 and not completed:
		completed = true
		arena.crew.tell("Маршрут пройден! Можно вернуться к атоллам · R — начать уровень заново")
	if arena.tank.position.y < -2:
		arena.tank.position = last_safe
		arena.tank.stop_drive()
		arena.tank.walker.reset_pose()
	elif arena.tank.position.y >= -0.1: last_safe = arena.tank.position
	if map_view.visible: map_view.queue_redraw()
	terrain.update_occlusion(arena.camera,center,dt)

func toggle_map() -> void:
	map_view.visible = not map_view.visible
	map_view.queue_redraw()
