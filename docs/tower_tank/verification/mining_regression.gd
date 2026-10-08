extends Node
## Real canyon physics and input: contact mining, cargo, delivery and hand.
const Geo = preload("res://scripts/geo.gd")
var arena
var level
var crew
var loot
var hand
var checks := {}
var metrics := {}
const ACTIONS := ["tank_forward", "tank_reverse", "tank_left", "tank_right"]

func _ready() -> void:
	arena = get_parent()
	level = arena.level
	crew = arena.crew
	loot = crew.loot
	hand = arena.hand
	_run.call_deferred()

func _frames(count: int) -> void:
	for index in count: await get_tree().physics_frame

func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await _frames(2)

func _place_crew(pos: Vector3) -> void:
	for action in ACTIONS: Input.action_release(action)
	crew.anchor = pos
	crew.motion = Vector3.ZERO
	crew.facing = Vector3.RIGHT
	arena.aim_position = pos + Vector3.RIGHT * 10.0
	arena.ground_aim_position = arena.aim_position
	for index in crew.members.size():
		var member = crew.members[index]
		member.global_position = pos + crew._slot(index, crew.facing) + Vector3.UP * 0.04
		member.velocity = Vector3.ZERO
		member.knockback = Vector3.ZERO
	await _frames(3)

func _walk(direction: Vector3, frames: int) -> void:
	for index in frames:
		var right: Vector3 = arena.aim_camera.global_basis.x
		var back: Vector3 = arena.aim_camera.global_basis.z
		right.y = 0.0
		back.y = 0.0
		var x := direction.dot(right.normalized())
		var y := direction.dot(back.normalized())
		for action in ACTIONS: Input.action_release(action)
		Input.action_press("tank_right" if x > 0 else "tank_left", absf(x))
		Input.action_press("tank_reverse" if y > 0 else "tank_forward", absf(y))
		await _frames(1)
	for action in ACTIONS: Input.action_release(action)
	await _frames(10)

func _point(pos: Vector3, frames: int = 5) -> void:
	for index in frames:
		hand.test_pointer = arena.aim_camera.unproject_position(pos)
		await _frames(1)

func _mouse(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = hand.test_pointer
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await _frames(3)

func _check_five_hits() -> void:
	var vein: StaticBody3D
	for node in level.ore:
		if node.position.distance_to(level.C+Vector3(-2.5,0,0))<0.1:
			vein=node
			break
	checks.fresh_vein_exists=vein!=null
	if vein==null: return
	await _place_crew(vein.position+Vector3(-2.3,0,0))
	var touching: int=crew.members.filter(func(member): return level._contact_ore(member)==vein).size()
	var hp_steps: Array[float]=[]
	var hit_frames: Array[int]=[]
	var last_hp:=100.0
	var began_frame:=Engine.get_physics_frames()
	for frame in 200:
		var hp: float=float(vein.get_meta("hp")) if is_instance_valid(vein) else 0.0
		if hp!=last_hp:
			hp_steps.append(hp)
			hit_frames.append(Engine.get_physics_frames()-began_frame)
			last_hp=hp
		if hp<=0.0: break
		if frame==0: await arena._capture(arena.verification_path("mining_00_hit.png"))
		if frame==18: await arena._capture(arena.verification_path("mining_00_rest.png"))
		await _frames(1)
	metrics.group_hit_hp=hp_steps
	metrics.group_hit_frames=hit_frames
	checks.multiple_dwarves_cannot_one_shot=touching>=2 and not hp_steps.is_empty() and hp_steps[0]==80.0
	checks.four_hits_leave_block_alive=hp_steps.size()==5 and hp_steps[3]==20.0
	checks.fifth_hit_breaks_block=hp_steps==[80.0,60.0,40.0,20.0,0.0] and not is_instance_valid(vein)
	var spaced:=hit_frames.size()==5
	# Placement advanced three frames before observing the first hit.
	if spaced: spaced=hit_frames[1]-hit_frames[0]>=35
	for index in range(2,hit_frames.size()): spaced=spaced and hit_frames[index]-hit_frames[index-1]>=38
	checks.mining_hits_have_interval=spaced

func _run() -> void:
	await _frames(6)
	level.cancel_spawning()
	level.automatic_encounters = false
	arena.battle.reset()
	arena.test_aim = true
	arena.tank.global_position = level.C + Vector3(-18,0.04,0)
	arena.tank.stop_drive()
	arena.tank.walker.reset_pose()
	arena.focus = arena.tank.position
	arena._update_camera(1.0)
	await _frames(3)
	checks.crew_can_exit_at_mine = crew.disembark()
	await _place_crew(level.C + Vector3(-7,0,0))
	var initial: int = level.ore.size()
	await _frames(60)
	checks.no_remote_mining = level.ore.size() == initial and not level.mining
	await _check_five_hits()
	await _walk(Vector3.RIGHT,300)
	checks.wasd_contact_mines_without_e = level.ore.size() < initial and level.mined > 0
	checks.ore_spawns_physical_crystals = loot.loose_crystals.size() == level.mined and loot.loose_crystals.all(func(item): return item.mass > 0 and item.collision_layer == 16)
	checks.mining_does_not_credit_resource = loot.crystals == 0 and loot.supplies == 0
	metrics.mined_by_contact = level.mined
	await _place_crew(level.C + Vector3(-8,0,0))
	await _frames(180)
	checks.crystals_rest_on_plateau = loot.loose_crystals.all(func(item): return item.position.y >= level.C.y+0.20 and item.position.y < level.C.y+0.9 and item.linear_velocity.length() < 0.8)
	if loot.loose_crystals.is_empty():
		_finish()
		return
	# Bring a real mined drop within reach, then use actual E events.
	var first: RigidBody3D = loot.loose_crystals.front()
	await _place_crew(first.position - Vector3(3.0,first.position.y-level.C.y,0))
	await _frames(8)
	checks.no_auto_crystal_pickup = loot.carried_crystal_count() == 0
	await _key(KEY_E)
	checks.e_picks_mined_crystal = loot.carried_crystal_count() == 1
	for index in 2:
		loot.spawn_crystal(crew.center()+Vector3.UP*0.6)
		await _frames(3)
		await _key(KEY_E)
	checks.crystals_stack_on_one_gnome = loot.carried_crystal_count() == 3 and loot.crystal_stacks.size() == 1
	var carrier = loot.crystal_stacks.keys().front()
	var stack: Array = loot.crystal_stacks[carrier].duplicate()
	checks.stack_spacing_and_hand_exclusion = stack.all(func(item): return item.freeze and item.collision_layer == 0 and not hand._available(item)) and absf(stack[1].position.y-stack[0].position.y-0.76)<0.01
	var old: Vector3 = stack.front().position
	await _walk(Vector3.LEFT,20)
	checks.stack_follows_carrier = stack.front().position.distance_to(old)>0.8 and stack.front().position.distance_to(carrier.position+Vector3.UP)<0.01
	await arena._capture(arena.verification_path("mining_01_stack.png"))
	await _key(KEY_Q)
	checks.q_drops_stack_physically = loot.carried_crystal_count()==0 and stack.all(func(item): return not item.freeze and item.collision_layer==16) and not carrier.hauling
	await _frames(120)
	for item in stack:
		item.position = crew.center()+Vector3.UP*0.6
		item.linear_velocity = Vector3.ZERO
		await _frames(2)
		checks.repickup_after_drop = loot.pickup_crystal(item) and checks.get("repickup_after_drop",true)
	# Deposit E takes precedence over boarding and credits only after absorption.
	await _place_crew(arena.tank.position + Vector3(6,-0.04,0))
	checks.deposit_context_near_tower = crew.context_action().kind == "crystals_deposit"
	await _key(KEY_E)
	checks.e_deposits_without_boarding = not crew.crewed and loot.carried_crystal_count()==0 and loot.crystal_deliveries.size()==3 and loot.crystals==0
	checks.no_double_deposit = not loot.deposit_crystal(stack.front())
	await _frames(10)
	await arena._capture(arena.verification_path("mining_02_absorption.png"))
	await _frames(70)
	checks.absorption_credits_exact_count = loot.crystals==3 and loot.crystal_deliveries.is_empty() and stack.all(func(item): return not is_instance_valid(item))
	await _key(KEY_E)
	checks.next_e_boards_and_keeps_resource = crew.crewed and loot.crystals==3
	# The real hand cursor can pick a loose resource and release it at the tower.
	var item: RigidBody3D = loot.spawn_crystal(arena.tank.position+Vector3(8,0.6,6))
	await _frames(120)
	await _key(KEY_F)
	await _point(item.global_position)
	await _mouse(true)
	checks.hand_picks_ground_crystal = hand.held == item
	await _point(arena.tank.position,18)
	checks.hand_offers_resource_deposit = hand.snap_destination=="tower" and hand.status_text().contains("КРИСТАЛЛ")
	await _mouse(false)
	await _frames(60)
	checks.hand_deposit_credits_resource = loot.crystals==4 and not is_instance_valid(item) and hand.mounted==null
	# A filled roof cargo slot does not prevent delivering crystals.
	var cargo: RigidBody3D = loot.spawn_cargo(arena.tank.position+Vector3(5,0,5),1)
	await _point(cargo.position)
	checks.hand_can_grab_roof_cargo = hand.grab(cargo)
	await _point(arena.tank.position,18)
	hand._release(true,true)
	checks.roof_fixture_mounted = hand.mounted==cargo
	item = loot.spawn_crystal(arena.tank.position+Vector3(7,0.6,5))
	await _frames(80)
	await _point(item.position)
	checks.hand_grabs_with_occupied_roof = hand.grab(item)
	await _point(arena.tank.position,18)
	hand._release(true,true)
	await _frames(60)
	checks.hand_deposit_preserves_roof_cargo = loot.crystals==5 and hand.mounted==cargo
	hand.set_enabled(false)
	checks.resource_survives_disembark = crew.disembark() and loot.crystals==5
	await _place_crew(level.C+Vector3(-10,0,8))
	item = loot.spawn_crystal(crew.center()+Vector3.UP*0.6)
	await _frames(3)
	checks.pickup_for_casualty = loot.pickup_crystal(item)
	carrier = item.get_meta("crew_carrier")
	carrier.take_damage(1000.0)
	await _frames(5)
	checks.dead_carrier_drops_crystal = loot.carried_crystal_count()==0 and not item.freeze and item.collision_layer==16 and not item.has_meta("crew_carrier") and loot.crystals==5
	# Reset during attraction must cancel delayed credit and remove every drop.
	checks.pending_delivery_fixture = loot.deposit_crystal(item)
	arena.reset_range()
	level.cancel_spawning()
	arena.battle.reset()
	await _frames(90)
	checks.reset_clears_all_crystal_state = loot.crystals==0 and loot.loose_crystals.is_empty() and loot.crystal_stacks.is_empty() and loot.crystal_deliveries.is_empty() and crew.members.size()==9 and crew.members.all(func(member): return not member.hauling)
	_finish()

func _finish() -> void:
	var passed: bool = checks.values().all(func(value): return value)
	var report := {"passed":passed,"checks":checks,"metrics":metrics}
	var file := FileAccess.open(arena.verification_path("mining_check.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	print("MINING_CHECK: ",JSON.stringify(report))
	get_tree().quit(0 if passed else 1)
