extends SceneTree
var arena
var checks := {}
var metrics := {}

func _initialize() -> void:
	_run.call_deferred()

func frames(count: int) -> void:
	for i in count: await physics_frame

func click(point: Vector2) -> void:
	arena.hand.test_pointer = point
	for pressed in [true,false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = root.get_final_transform()*point
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await frames(2)

func _run() -> void:
	arena = load("res://desert.tscn").instantiate()
	root.add_child(arena)
	if not arena.rendering_ready: await arena.rendering_prepared
	arena.set_physics_process(false)
	arena.level.cancel_spawning()
	arena.level.automatic_encounters = false
	arena.battle.reset()
	var shop = arena.defenses.pyrotechnician
	var defense = arena.defenses
	var loot = arena.crew.loot
	arena.tank.position = shop.output.global_position+Vector3(5,0.04,4)
	arena.tank.stop_drive()
	arena.focus = shop.global_position
	arena.zoom = 28
	arena._update_camera(1.0)
	arena.crew.input_armed = true
	await frames(3)
	checks.price_is_15 = shop.barrel_gold_cost==15
	checks.pickup_point_is_free = shop.output_reason(arena).is_empty()
	checks.pickup_point_cannot_be_built_over = not defense.placement.reason(shop.output.global_position).is_empty()
	metrics.output_reason = shop.output_reason(arena)
	await click(arena.aim_camera.unproject_position(shop.global_position+Vector3.UP*2))
	checks.house_opens_pyrotechnician_menu = defense.mode==defense.Mode.MENU and defense.active_shop==shop
	loot.coins = 14
	defense.tick(.016)
	checks.insufficient_gold_disables_buy = defense.choice.disabled and not shop.purchase(arena)
	loot.coins = 30
	loot.crystals = 0
	defense.tick(.016)
	checks.no_crystals_required = not defense.choice.disabled
	await arena._capture(arena.verification_path("pyrotechnician_menu.png"))
	var count: int = arena.targets.size()
	var authored: int = arena.target_specs.size()
	await click(defense.choice.get_global_rect().get_center())
	checks.purchase_spawns_one_barrel = arena.targets.size()==count+1
	checks.purchase_costs_gold_only = loot.coins==15 and loot.crystals==0
	if not checks.purchase_spawns_one_barrel:
		finish()
		return
	var barrel = shop.last_barrel.get_ref()
	checks.physical_hand_barrel = barrel is RigidBody3D and barrel.has_meta("hand_size") and barrel.get_meta("spec").barrel
	checks.purchased_barrel_not_added_to_reset_layout = arena.target_specs.size()==authored
	# Click again through the same menu, then burst purchases within one physics frame.
	await click(defense.choice.get_global_rect().get_center())
	checks.repeat_menu_purchase_without_pickup = arena.targets.size()==count+2 and loot.coins==0
	loot.coins = 150
	var batch := true
	for i in 10: batch = shop.purchase(arena) and batch
	checks.ten_immediate_purchases_succeed = batch and loot.coins==0 and arena.targets.size()==count+12
	var positions: Array[Vector3] = []
	for ref in shop.stock: positions.append(ref.get_ref().global_position)
	checks.stock_does_not_overlap = true
	for i in positions.size():
		for j in range(i+1,positions.size()):
			checks.stock_does_not_overlap = checks.stock_does_not_overlap and positions[i].distance_to(positions[j])>1.15
	checks.stock_fills_multiple_rows = positions.any(func(p): return shop.to_local(p).z>shop.output.position.z+1.0)
	checks.whole_stock_area_reserved = positions.all(func(p): return not defense.placement.reason(p).is_empty())
	await frames(3)
	await arena._capture(arena.verification_path("pyrotechnician_stock.png"))
	# Obstruct the whole yard: no charge when there is physically nowhere to spawn.
	var blocker := StaticBody3D.new()
	arena.add_child(blocker)
	blocker.global_transform = shop.global_transform
	preload("res://scripts/geo.gd").collider(blocker,Vector3(24,3,28),shop.output.position+Vector3(0,1.6,5))
	await frames(3)
	loot.coins = 15
	checks.full_or_blocked_yard_does_not_charge = not shop.purchase(arena) and loot.coins==15
	blocker.collision_layer = 0
	blocker.queue_free()
	await frames(3)
	checks.barrel_does_not_trigger_wave = arena.level.defense_waves.first_wave_left<0 and arena.level.defense_waves.active==-1
	defense.cancel()
	await arena._capture(arena.verification_path("pyrotechnician_barrel.png"))
	arena.hand.set_enabled(true)
	arena.crew.input_armed = true
	checks.hand_can_grab_purchased_barrel = arena.hand.grab(barrel)
	var face: Vector3 = arena.level.deep_mine.get_node("Markers/FirstFace").global_position
	barrel.global_position = face+Vector3(-4,.15,0)
	arena.hand.velocity_history.assign([Vector3.RIGHT*12])
	arena.hand._release(false,false)
	checks.hand_release_throws_barrel = barrel.thrown and not barrel.freeze and barrel.linear_velocity.length()>8
	var enemy = arena.battle.spawn_enemy(face+Vector3(-1,0,3))
	var ore_before: int = arena.level.ore.size()
	var coins_before: int = loot.loose_coins.size()
	await frames(100)
	checks.thrown_barrel_explodes_on_contact = not is_instance_valid(barrel)
	checks.explosion_mines_ore = arena.level.ore.size()<ore_before and not loot.loose_crystals.is_empty()
	checks.explosion_kills_skeleton = not is_instance_valid(enemy) or enemy.dead
	metrics.blocks_mined = ore_before-arena.level.ore.size()
	checks.vacated_first_position_reused = shop.next_output_position().distance_to(shop.output.global_position)<0.01
	# Clear earned enemy drops, then isolate a purchased barrel away from other targets.
	checks.can_buy_after_pickup = shop.purchase(arena) and loot.coins==0
	var second = shop.last_barrel.get_ref()
	second.global_position = Vector3(-95,1,65)
	coins_before = loot.loose_coins.size()
	arena._damage_target(second,999)
	await frames(3)
	checks.purchased_barrel_does_not_drop_free_gold = loot.loose_coins.size()==coins_before
	loot.coins = 15
	checks.can_purchase_again = shop.purchase(arena)
	var third = weakref(shop.last_barrel.get_ref())
	arena.reset_range()
	await frames(3)
	checks.reset_removes_purchased_barrels = not is_instance_valid(third.get_ref()) and not arena.targets.any(func(t): return t.get_meta("spec",{}).get("purchased",false))
	checks.reset_clears_currencies = loot.coins==0 and loot.crystals==0
	finish()

func finish() -> void:
	var passed: bool = checks.values().all(func(value): return value)
	var report := {"passed":passed,"checks":checks,"metrics":metrics}
	var file := FileAccess.open(arena.verification_path("pyrotechnician_check.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	file.close()
	print("PYROTECHNICIAN_CHECK: ",JSON.stringify(report))
	quit(0 if passed else 1)
