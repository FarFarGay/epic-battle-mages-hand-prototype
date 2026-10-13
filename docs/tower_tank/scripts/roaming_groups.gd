extends Node3D
## Authored patrol groups share a moving formation instead of 100 random goals.
const Geo = preload("res://scripts/geo.gd")
const DEFAULT_CENTERS := [Vector3(-74,0,8), Vector3(-14,0,26), Vector3(40,0,13)]
const SHORT_ROUTE := [Vector3(-114,0,0), Vector3(-74,0,8), Vector3(-54,0,18), Vector3(-14,0,26), Vector3(20,0,13), Vector3(40,0,13), Vector3(50,0,26), Vector3(50,0,34), Vector3(80,4,34)]
const LONG_ROUTE := [Vector3(-114,0,0), Vector3(-102,0,-31), Vector3(-77,0,-53), Vector3(-55,0,-70), Vector3(-8,0,-71), Vector3(20,0,-58), Vector3(64,0,-55), Vector3(82,0,-32), Vector3(80,0,-10), Vector3(80,4,16), Vector3(96,4,34)]
var level
var groups: Array[Dictionary] = []
var time := 0.0
var leash_left := 0.0
var pending: Array[Dictionary] = []
var candidate := 0
var pending_group := 0

func setup(owner_level) -> void:
	level = owner_level
	name = "RoamingGroups"
	_mark_routes()

func reset() -> void:
	time = 0.0
	leash_left = 0.0
	groups.clear()
	pending.clear()
	candidate = 0
	pending_group = 0
	if level.authored:
		for p in level.layout.placements:
			if p.kind == "PatrolGroup":
				pending.append({"origin":p.transform.origin,"travel":p.patrol_travel,"count":p.wave_count,"giants":p.wave_giants})
	else:
		for center in DEFAULT_CENTERS: pending.append({"origin":center,"travel":Vector3(4,0,0),"count":100,"giants":2})
	for spec in pending:
		groups.append({"origin":spec.origin,"center":spec.origin,"travel":spec.travel,"members":[],"alarmed":false,"alert_time":0.0,"slots":0})
	level.world_spawn_positions.clear()

func prepare_batch() -> bool:
	# Budget placement queries too: spawning 300 actors must not start with a
	# single giant physics-query spike. Validate the complete patrol sweep.
	var started := Time.get_ticks_usec()
	var attempts := 0
	while pending_group < pending.size() and attempts < 8 and Time.get_ticks_usec()-started < 1500:
		var spec: Dictionary = pending[pending_group]
		var group: Dictionary = groups[pending_group]
		var angle := candidate * 2.39996323
		var radius := 1.05 * sqrt(float(candidate))
		var offset := Vector3(cos(angle),0,sin(angle)) * radius
		candidate += 1
		attempts += 1
		assert(candidate < 500, "Patrol group needs a clear area for all its members")
		var pos: Vector3 = spec.origin + offset
		var clear := true
		for fraction in [-1.0,-0.5,0.0,0.5,1.0]:
			if not level._world_spawn_open(pos + spec.travel * fraction):
				clear = false
				break
		if not clear: continue
		var slot: int = group.slots
		var giant: bool = slot < spec.giants
		# The two giants occupy the first, widely separated usable slots.
		if giant and slot == 1 and pos.distance_to(level.world_spawn_positions.back()) < 2.2: continue
		level.world_spawn_positions.append(pos)
		level.spawn_queue.append({"world_pos":pos,"giant":giant,"shield_guard":false,"slot":level.world_spawn_positions.size()-1,"group":pending_group,"offset":offset})
		group.slots += 1
		if group.slots == spec.count:
			pending_group += 1
			candidate = 0
	return pending_group == pending.size()

func register(enemy, id: int, offset: Vector3) -> void:
	enemy.patrol_group = id
	enemy.group_offset = offset
	groups[id].members.append(enemy)

func unprepared_count() -> int:
	var total := 0
	for i in pending.size(): total += pending[i].count - groups[i].slots
	return total

func alert(id: int) -> void:
	if id < 0 or id >= groups.size() or groups[id].alarmed: return
	groups[id].alarmed = true
	groups[id].alert_time = time
	for enemy in groups[id].members:
		if not is_instance_valid(enemy) or enemy.dead: continue
		enemy.attack_on_spawn = true
		enemy.scan_left = 0.0

func tick(dt: float) -> void:
	time += dt
	leash_left -= dt
	for group in groups:
		if not group.alarmed: group.center = group.origin + group.travel * sin(time * 0.16)
	if leash_left > 0.0: return
	leash_left = 0.25
	var player: Vector3 = level.arena.crew.center()
	for group in groups:
		if not group.alarmed or player.distance_squared_to(group.center) < 60.0*60.0: continue
		if time - group.alert_time < 8.0: continue
		group.members = group.members.filter(func(e): return is_instance_valid(e) and not e.dead)
		if group.members.any(func(e): return e.position.distance_squared_to(player) < 34.0*34.0): continue
		group.alarmed = false
		for enemy in group.members:
			enemy.attack_on_spawn = false
			enemy.target = null
			enemy.path.clear()

func _mark_routes() -> void:
	var routes := PackedVector4Array([Vector4(level.ENTRY_WEST,0,-124,0), Vector4(-124,0,-114,0)])
	for route in [SHORT_ROUTE,LONG_ROUTE]:
		for i in range(1,route.size()): routes.append(Vector4(route[i-1].x,route[i-1].z,route[i].x,route[i].z))
	# Keep the side-atoll access roads; village approaches use the two new routes.
	for segment in [Vector4(-94,46,-52,45),Vector4(-80,38,-68.5,38),Vector4(-62,-41.5,-28,-41.5)]: routes.append(segment)
	var seen := {}
	for mesh in level.find_children("*","MeshInstance3D",true,false):
		var mat = mesh.material_override
		if not mat is ShaderMaterial or not mat.shader or not mat.shader.resource_path.ends_with("canyon_ground.gdshader"): continue
		if seen.has(mat): continue
		seen[mat] = true
		mat.set_shader_parameter("routes",routes)
		mat.set_shader_parameter("route_count",routes.size())
	for route_id in 2:
		var route: Array = SHORT_ROUTE if route_id == 0 else LONG_ROUTE
		var color := Color("d99d61") if route_id == 0 else Color("71c7bd")
		var mat := Geo.material(color,0.0,0.2)
		for i in range(1,route.size()-1):
			var pos: Vector3 = route[i]
			pos.y = level.ground_height(pos)
			var marker := Node3D.new()
			add_child(marker)
			marker.position = pos
			var direction: Vector3 = route[i+1]-pos
			marker.rotation.y = atan2(-direction.x,-direction.z)
			for side in [-1.0,1.0]:
				var arrow := Geo.box(marker,Vector3(0.22,0.035,1.4),Vector3(side*0.42,0.045,0),mat)
				arrow.rotation.y = side*0.65
	for route_id in 2:
		var sign := Label3D.new()
		add_child(sign)
		sign.position = Vector3(-113,3.0,-5.0 if route_id else 5.0)
		sign.text = "ДЕРЕВНЯ: ДЛИННЫЙ ОБХОД" if route_id else "ДЕРЕВНЯ: КОРОТКИЙ ПУТЬ · ПАТРУЛИ"
		sign.font_size = 34
		sign.pixel_size = 0.018
		sign.modulate = Color("71c7bd") if route_id else Color("d99d61")
		sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		Geo.mark_ui(sign)
