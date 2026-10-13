extends SceneTree
var arena
var level
var mine
var checks := {}
var metrics := {}

func _initialize() -> void:
	_run.call_deferred()

func frames(count: int) -> void:
	for i in count: await physics_frame

func view_at(point: Vector3, size: float, file: String) -> void:
	arena.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	arena.camera.size = size
	arena.camera.position = point+Vector3(15,75,55)
	arena.camera.look_at(point)
	await arena._capture(arena.verification_path(file))

func _run() -> void:
	arena = load("res://desert.tscn").instantiate()
	root.add_child(arena)
	if not arena.rendering_ready: await arena.rendering_prepared
	arena.set_physics_process(false)
	arena.set_process(false)
	arena.level.cancel_spawning()
	arena.level.automatic_encounters = false
	arena.battle.reset()
	level = arena.level
	mine = level.deep_mine
	var tank = arena.tank
	var face: Vector3 = mine.get_node("Markers/FirstFace").global_position
	var mouth: Vector3 = mine.get_node("Markers/Entrance").global_position
	var chamber: Vector3 = mine.get_node("Markers/DeepChamber").global_position
	var initial: int = level.ore.size()
	checks.triple_deposit_count = initial>=438
	checks.mine_extends_beyond_old_boundary = chamber.x>220 and arena.world_bounds.has_point(Vector2(chamber.x,chamber.z))
	checks.village_at_east_wall = level.C.is_equal_approx(Vector3(96,4,34))
	checks.markers_have_floor = true
	for marker in mine.get_node("Markers").get_children():
		checks.markers_have_floor = checks.markers_have_floor and absf(level.ground_height(marker.global_position)-4.0)<0.01
	checks.north_ramp_moves_with_village = level.get_node("AtollC/Ramp6").position.is_equal_approx(Vector3(-16,0,-44))
	tank.position = level.C+Vector3(10,0.04,0)
	tank.stop_drive()
	await frames(3)
	for i in 100:
		var collision = tank.move_and_collide(Vector3.RIGHT*0.15)
		if collision: metrics.entry_blocker = str(collision.get_collider().get_path())
	checks.village_connects_to_mine = tank.position.x>mouth.x-0.2
	for i in 160: tank.move_and_collide(Vector3.RIGHT*0.15)
	checks.rock_face_blocks_tower = tank.position.x<face.x-1.5 and tank.position.x>face.x-4
	mine._process(1.0)
	checks.distant_roof_still_closed = mine.get_node("Roof/Roof_130_0").visible
	arena.hud.hide()
	await view_at(level.C+Vector3(43,0,5),153,"deep_mine_overview.png")
	await view_at(mouth,42,"deep_mine_entrance.png")
	# Excavate a tower-width corridor; side deposits must stay intact.
	for node in level.ore.duplicate():
		var p: Vector3 = mine.to_local(node.global_position)
		if absf(p.z)<=2.5: level.damage_ore(node,1000,Vector3.RIGHT,true)
	await frames(3)
	var excavated: int = initial-level.ore.size()
	checks.excavation_opens_only_selected_blocks = excavated>90 and level.ore.size()>initial*0.65
	checks.crystals_created_by_excavation = level.mined==excavated and not arena.crew.loot.loose_crystals.is_empty()
	for i in 680:
		tank.move_and_collide(Vector3.RIGHT*0.15)
		if i%20==0:
			mine._process(1.0)
			await physics_frame
	checks.tower_reaches_deep_chamber = tank.position.x>chamber.x-2 and absf(tank.position.y-4.04)<0.1
	checks.roof_opens_with_progress = not mine.get_node("Roof/Roof_130_0").visible
	metrics.tower_end = str(tank.position)
	metrics.excavated = excavated
	metrics.deposits = initial
	await view_at(tank.position,48,"deep_mine_excavated.png")
	level.tick(0.016)
	checks.mine_does_not_complete_exit = not level.completed and level.current_zone.begins_with("ГЛУБОКАЯ")
	# Retreat leaves the tunnel and discovered chambers open.
	for i in 900: tank.move_and_collide(Vector3.LEFT*0.15)
	checks.return_to_village = tank.position.x<face.x-4
	checks.excavation_persists_on_return = level.ore.size()==initial-excavated and not mine.get_node("Roof/Roof_130_0").visible
	arena.reset_range()
	await frames(3)
	checks.reset_restores_mine = level.ore.size()==initial and mine.get_node("Roof/Roof_130_0").visible
	var passed := true
	for v in checks.values(): passed = passed and v
	var report := {"passed":passed,"checks":checks,"metrics":metrics}
	var file := FileAccess.open(arena.verification_path("deep_mine_check.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	print("DEEP_MINE_CHECK: ",JSON.stringify(report))
	quit(0 if passed else 1)
