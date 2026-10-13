extends Node3D
## Construction starts wave one; the campaign schedules later defenses.
signal wave_started(number: int, total: int)
signal wave_completed(number: int)
signal all_waves_completed
@export var test_hotkey_enabled := true
@export var test_launch_distance := 75.0
@export_range(0.0,60.0) var first_tower_wave_delay := 5.0
@export var enemy_settings: Resource = preload("res://scripts/defense_enemy_settings.gd").new()
var arena
var waves: Array[Node] = []
var active := -1
var completed := 0
var pending: Array[Dictionary] = []
var living: Dictionary = {}
var spawned_by_entrance: Dictionary = {}
var spawned_by_type: Dictionary = {}
var events: Dictionary = {}
var blocked_time := 0.0
var elapsed := 0.0
var first_wave_left := -1.0
var open_zone_reached := false
var village_reached := false

func setup(owner_arena) -> void:
	arena = owner_arena
	waves.clear()
	for child in get_children():
		if child.has_method("composition") and child.enabled: waves.append(child)
	reset()

func reset() -> void:
	# Also safe when a story script cancels a wave without resetting the map.
	if arena and arena.battle.ordnance: arena.battle.ordnance.reset()
	for ref in living.values():
		var enemy = ref.get_ref()
		if is_instance_valid(enemy):
			arena.battle.enemies.erase(enemy)
			enemy.collision_layer = 0
			enemy.queue_free()
	living.clear()
	pending.clear()
	events.clear()
	spawned_by_entrance.clear()
	spawned_by_type.clear()
	active = -1
	completed = 0
	elapsed = 0.0
	blocked_time = 0.0
	first_wave_left = -1.0
	open_zone_reached = false
	village_reached = false
	for entrance in $Entrances.get_children(): entrance.cursor = 0

func tower_built(site: Node3D) -> void:
	if completed != 0 or active >= 0 or first_wave_left >= 0.0: return
	if not get_parent().is_ancestor_of(site) or not is_instance_valid(site.tower): return
	open_zone_reached = true
	village_reached = true
	first_wave_left = first_tower_wave_delay

func status_visible() -> bool:
	return open_zone_reached or active >= 0 or first_wave_left >= 0.0

func notify_story_event(event: StringName) -> bool:
	if event == &"": return false
	events[event] = true
	return _try_story_start()

func _try_story_start() -> bool:
	if arena.level.campaign and arena.level.campaign.enabled: return false
	# The opening wave belongs to the first construction, not a story/debug key.
	if completed == 0: return false
	if active >= 0 or completed >= waves.size(): return false
	var key: StringName = waves[completed].start_event
	return request_wave(completed) if key != &"" and events.has(key) else false

func start_next_test_wave() -> bool:
	if arena.level.campaign and arena.level.campaign.enabled:
		arena.crew.tell(status_text())
		return false
	if not test_hotkey_enabled: return false
	if completed == 0:
		arena.crew.tell(status_text())
		return false
	if arena.crew.center().distance_to(global_position) > test_launch_distance:
		arena.crew.tell("N — запуск обороны рядом с деревней")
		return false
	return request_wave(completed)

func request_wave(index: int) -> bool:
	if active >= 0 or index != completed or index < 0 or index >= waves.size(): return false
	if arena.battle.player_targets().is_empty(): return false
	var config = waves[index]
	var routes: Array[Node] = []
	for path in config.entrances:
		var entrance = config.get_node_or_null(path)
		if entrance == null or not entrance.has_method("candidate"):
			push_warning("Defense wave has an invalid entrance: " + str(path))
			return false
		routes.append(entrance)
	if routes.is_empty() or config.total() <= 0: return false
	var types: Array[StringName] = []
	var composition: Dictionary = config.composition()
	for kind in composition:
		for i in composition[kind]: types.append(kind)
	# Deterministic interleaving: specials arrive throughout the same wave.
	var rng := RandomNumberGenerator.new()
	rng.seed = 8243 + index
	for i in range(types.size()-1, 0, -1):
		var j := rng.randi_range(0, i)
		var value := types[i]
		types[i] = types[j]
		types[j] = value
	spawned_by_entrance.clear()
	spawned_by_type.clear()
	for i in types.size():
		pending.append({"kind":types[i], "entrance":routes[i % routes.size()], "lane":rng.randf_range(-1.0, 1.0)})
	active = index
	first_wave_left = -1.0
	# Battle expands the shared map during preparation, or detects the new
	# active region next tick. Spawning does not itself change static obstacles.
	elapsed = 0.0
	blocked_time = 0.0
	arena.crew.tell("Оборона · волна %d · %d врагов · входов: %d" % [index+1, types.size(), routes.size()])
	wave_started.emit(index+1, types.size())
	return true

func remaining() -> int:
	return pending.size() + living.size()

func needs_approach_navigation() -> bool:
	return active>=0 or first_wave_left>=0 or (arena.level.campaign!=null and arena.level.campaign.enabled and arena.level.campaign.seconds_left>=0)

func navigation_bounds() -> Rect2:
	var bounds := Rect2(Vector2(global_position.x,global_position.z),Vector2.ZERO)
	for entrance in $Entrances.get_children():
		var spawn: Node3D = entrance.get_node("Spawn")
		var half_width: float = (entrance.columns-1)*entrance.spacing*0.5
		for x in [-half_width,half_width]:
			for z in [0.0,(entrance.rows-1)*entrance.spacing]:
				var point := spawn.to_global(Vector3(x,0,z))
				bounds = bounds.expand(Vector2(point.x,point.z))
		for name in ["Foot","Crest"]:
			var point: Vector3 = entrance.get_node(name).global_position
			bounds = bounds.expand(Vector2(point.x,point.z))
	return bounds.grow(5.0)

func enemy_removed(enemy) -> void:
	living.erase(enemy.get_instance_id())

func tick(dt: float) -> void:
	var center: Vector3 = arena.crew.center()
	if center.x > arena.level.ENTRY_RECT.end.x+10.0: open_zone_reached = true
	if Vector2(center.x-global_position.x,center.z-global_position.z).length()<28.0 and center.y>global_position.y+2.0:
		village_reached = true
	if arena.battle.player_targets().is_empty(): return
	if active < 0 and completed == 0 and first_wave_left >= 0.0:
		first_wave_left = maxf(0.0,first_wave_left-dt)
		if first_wave_left <= 0.000001: request_wave(0)
	if active < 0: return
	elapsed += dt
	var started := Time.get_ticks_usec()
	var spawned := 0
	var attempts := 0
	while not pending.is_empty() and spawned < waves[active].spawn_per_frame and attempts < 24:
		if Time.get_ticks_usec()-started > 1800: break
		var ticket: Dictionary = pending.pop_front()
		var entrance = ticket.entrance
		var point: Vector3 = entrance.candidate()
		attempts += 1
		var ground: float = arena.ground_height(point)
		# Do not put the rear of a formation on another atoll or inside scenery.
		if absf(ground-entrance.get_node("Spawn").global_position.y) > 0.7 or not arena.world_bounds.has_point(Vector2(point.x,point.z)) or point.distance_squared_to(arena.crew.center()) < 64.0 or not arena.battle._spawn_clear(point, ticket.kind==&"giant"):
			pending.append(ticket) # No lost enemies if an entrance is obstructed.
			continue
		var enemy = arena.battle.spawn_enemy(point, ticket.kind==&"giant", ticket.kind==&"shield", ticket.kind, enemy_settings)
		enemy.attack_on_spawn = true
		enemy.scan_left = 0.0
		enemy.wave_owner = self
		enemy.set_wave_route(entrance,entrance.lane_at(point))
		enemy.wave_entrance = entrance.name
		living[enemy.get_instance_id()] = weakref(enemy)
		spawned_by_entrance[entrance.name] = spawned_by_entrance.get(entrance.name, 0)+1
		spawned_by_type[ticket.kind] = spawned_by_type.get(ticket.kind, 0)+1
		spawned += 1
	blocked_time = blocked_time+dt if spawned==0 and not pending.is_empty() else 0.0
	# Weak refs handle externally removed actors as well as combat deaths.
	for id in living.keys():
		var actor = living[id].get_ref()
		if not is_instance_valid(actor) or actor.dead: living.erase(id)
	if remaining() == 0:
		var number := active+1
		completed += 1
		active = -1
		arena.battle.nav_dirty = true
		arena.crew.tell("Волна %d отбита" % number)
		wave_completed.emit(number)
		if completed == waves.size(): all_waves_completed.emit()
		else: _try_story_start()

func status_text() -> String:
	if active >= 0:
		return "ОБОРОНА %d/%d · ОСТАЛОСЬ %d%s" % [active+1, waves.size(), remaining(), " · ВХОД ЗАНЯТ" if blocked_time>5.0 else ""]
	if completed>0 and arena.level.campaign and arena.level.campaign.enabled: return arena.level.campaign.status_text()
	if completed >= waves.size(): return "ОБОРОНА · ВСЕ ВОЛНЫ ОТБИТЫ"
	if completed == 0:
		if first_wave_left >= 0.0: return "ПЕРВАЯ ВОЛНА ЧЕРЕЗ %d С · ПРИГОТОВЬСЯ"%ceili(first_wave_left)
		if village_reached: return "ЦЕЛЬ · ПОСТРОЙ 1 БАШНЮ · ЛКМ ПО ДОМУ КАМЕНЩИКА"
		return "ЦЕЛЬ · ДОБЕРИСЬ ДО АТОЛЛА С ШАХТОЙ · G — КАРТА"
	return "N · ОБОРОНА: ВОЛНА %d/%d" % [completed+1, waves.size()]
