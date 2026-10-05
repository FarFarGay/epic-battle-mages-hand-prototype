extends Node3D
const Geo = preload("res://scripts/geo.gd")
const Tank = preload("res://scripts/tank.gd")
const Effects = preload("res://scripts/effects.gd")
const Sound = preload("res://scripts/sound.gd")
const Hud = preload("res://scripts/hud.gd")
const Crew = preload("res://scripts/crew.gd")
const Breakables = preload("res://scripts/breakables.gd")
const Battle = preload("res://scripts/battle.gd")
const TowerHand = preload("res://scripts/tower_hand.gd")
const HandObject = preload("res://scripts/hand_object.gd")
const CAMERA_DEFAULT_YAW := PI / 4.0
const CAMERA_ORBIT_OFFSET := Vector3(24, 24, 24)
const CANYON_CAMERA_ORBIT_OFFSET := Vector3(23, 40, 23)
const CAMERA_TURN_SENSITIVITY := 0.005

@export var shake_strength := 1.0
@export var desert_mode := false
var level
var world_bounds := Rect2(-28, -28, 56, 56)
var tank
var fx
var sound
var hud
var crew
var props
var battle
var hand
var camera: Camera3D
var aim_camera: Camera3D
var camera_yaw := CAMERA_DEFAULT_YAW
var camera_rotating := false
var camera_return_pointer := Vector2.ZERO
var targets: Array[PhysicsBody3D] = []
var shells: Array[Dictionary] = []
var target_specs: Array[Dictionary] = []
var respawns: Array[Dictionary] = []
var trauma := 0.0
var kick := Vector3.ZERO
var zoom_punch := 0.0
var zoom := 24.0
var focus := Vector3(0, 0.6, 2)
var freeze := 0.0
var flash_alpha := 0.0
var ready_pulse := 0.0
var hit_pulse := 0.0
var kills := 0
var tuning_open := false
var interface_visible := true
var aim_position := Vector3(0, 0.0, -8)
var ground_aim_position := Vector3(0, 0.0, -8)
var actual_hit := Vector3.ZERO
var time := 0.0
var test_aim := false
var rng := RandomNumberGenerator.new()
var amber := Geo.material(Color("e9ae5e"), 0.2, 0.7)
var cyan := Geo.material(Color("5bbeb6"), 0.1, 0.45)
var red := Geo.material(Color("f47456"), 0.15, 1.3)
var stone := Geo.material(Color("9e9886"))
var dark := Geo.material(Color("343e40"), 0.15)
var powder_red := Geo.material(Color("ae3e2f"), 0.2)
var bullet_material := Geo.material(Color("fff0bb"), 0.0, 3.0)
var _reset_requested := false
var _range_generation := 0

func _ready() -> void:
	get_tree().node_added.connect(_register_world_label)
	rng.seed = 7142
	_bind_inputs()
	if desert_mode:
		level = load("res://scripts/desert_level.gd").new()
		level.arena = self
		add_child(level)
		world_bounds = level.WORLD_BOUNDS
	_build_world()
	fx = Effects.new()
	fx.name = "Effects"
	add_child(fx)
	sound = Sound.new()
	sound.name = "Sound"
	add_child(sound)
	tank = Tank.new()
	tank.arena = self
	add_child(tank)
	tank.reset_state()
	camera = Camera3D.new()
	camera.name = "IsometricCamera"
	add_child(camera)
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE if level else Camera3D.PROJECTION_ORTHOGONAL
	camera.fov = 40.0
	camera.size = zoom
	camera.far = 600 if desert_mode else 180
	camera.current = true
	# A matching, non-rendering camera isolates mouse picking from impact shake.
	aim_camera = Camera3D.new()
	aim_camera.name = "StableAimProjection"
	add_child(aim_camera)
	aim_camera.projection = camera.projection
	aim_camera.fov = camera.fov
	aim_camera.far = camera.far
	aim_camera.current = false
	_update_camera(1.0)
	_build_targets()
	crew = Crew.new()
	crew.arena = self
	add_child(crew)
	props = Breakables.new()
	props.arena = self
	add_child(props)
	props.reset()
	battle = Battle.new()
	battle.arena = self
	# Existing verification modes keep an empty range; battle tests spawn fixtures.
	battle.waves_enabled = not desert_mode and (OS.get_cmdline_user_args().is_empty() or "--range" in OS.get_cmdline_user_args())
	add_child(battle)
	hand = TowerHand.new()
	hand.arena = self
	add_child(hand)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	hud.arena = self
	layer.add_child(hud)
	if level: level.setup_gameplay()
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	if OS.get_cmdline_user_args().has("--level-check") or OS.get_cmdline_user_args().has("--level-preview"):
		add_child(load("res://verification/level_regression.gd").new())
	elif OS.get_cmdline_user_args().has("--smoke"):
		_smoke_test.call_deferred()
	elif OS.get_cmdline_user_args().has("--aim-check"):
		var probe: Node = load("res://verification/aim_regression.gd").new()
		add_child(probe)
	elif OS.get_cmdline_user_args().has("--drive-check"):
		var probe: Node = load("res://verification/drive_regression.gd").new()
		add_child(probe)
	elif OS.get_cmdline_user_args().has("--crew-check"):
		var probe: Node = load("res://verification/crew_regression.gd").new()
		add_child(probe)
	elif OS.get_cmdline_user_args().has("--crew-damage-check"):
		var probe: Node = load("res://verification/crew_damage_regression.gd").new()
		add_child(probe)
	elif OS.get_cmdline_user_args().has("--dash-check"):
		var probe: Node = load("res://verification/dash_regression.gd").new()
		add_child(probe)
	elif OS.get_cmdline_user_args().has("--crossbow-check"):
		var probe: Node = load("res://verification/crossbow_regression.gd").new()
		add_child(probe)
	elif OS.get_cmdline_user_args().has("--battle-check"):
		var probe: Node = load("res://verification/battle_regression.gd").new()
		add_child(probe)
	elif OS.get_cmdline_user_args().has("--horde-check"):
		var probe: Node = load("res://verification/horde_regression.gd").new()
		add_child(probe)
	elif OS.get_cmdline_user_args().has("--hand-check"):
		var probe: Node = load("res://verification/hand_regression.gd").new()
		add_child(probe)

func _bind_inputs() -> void:
	var bindings := {"tank_forward": KEY_W, "tank_reverse": KEY_S, "tank_left": KEY_A, "tank_right": KEY_D, "tank_cruise": KEY_SHIFT, "crew_strike": KEY_SPACE}
	for action in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var event := InputEventKey.new()
		event.physical_keycode = bindings[action]
		InputMap.action_add_event(action, event)
	if not InputMap.has_action("tank_fire"):
		InputMap.add_action("tank_fire")
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	InputMap.action_add_event("tank_fire", mouse)
	if not InputMap.has_action("crew_special"):
		InputMap.add_action("crew_special")
	var secondary := InputEventMouseButton.new()
	secondary.button_index = MOUSE_BUTTON_RIGHT
	InputMap.action_add_event("crew_special", secondary)

func _build_world() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("1e292d")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("b2ccd3")
	env.ambient_light_energy = 0.40
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color("657478")
	env.fog_light_energy = 0.65
	env.fog_density = 0.0016
	environment.environment = env
	add_child(environment)
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-48, -32, 0)
	sun.light_color = Color("ffdfac")
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 85.0
	if level:
		env.background_color = Color("777d89")
		env.fog_enabled = false
		sun.light_color = Color("fff3df")
		sun.light_energy = 0.75
		level.build_world()
		return
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	add_child(ground)
	Geo.collider(ground, Vector3(120, 1, 120), Vector3(0, -0.5, 0))
	Geo.box(ground, Vector3(120, 0.5, 120), Vector3(0, -0.26, 0), Geo.material(Color("38494b")))
	# A single MultiMesh for the paving; tiny gaps keep the scale readable.
	var tile_mesh := BoxMesh.new()
	tile_mesh.size = Vector3(1.97, 0.07, 1.97)
	var tile_mat := Geo.material(Color.WHITE)
	tile_mat.vertex_color_use_as_albedo = true
	tile_mesh.material = tile_mat
	var paving := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = tile_mesh
	mm.instance_count = 28 * 28
	for x in 28:
		for z in 28:
			var idx := x * 28 + z
			mm.set_instance_transform(idx, Transform3D(Basis.IDENTITY, Vector3((x - 13.5) * 2, -0.03, (z - 13.5) * 2)))
			var tint := rng.randf_range(0.88, 1.05)
			mm.set_instance_color(idx, Color(0.16 * tint, 0.21 * tint, 0.22 * tint))
	paving.multimesh = mm
	add_child(paving)
	var paint := Geo.material(Color("727b72"))
	for radius in [6.0, 12.0, 20.0]:
		var circle := Geo.ring(self, radius, 0.055, Vector3(0, 0.029, 0), paint)
		circle.scale.y = 0.07
		Geo.mark_ui(circle)
	for side in [-1, 1]:
		Geo.box(self, Vector3(0.085, 0.012, 46), Vector3(side * 24, 0.025, 0), paint)
		Geo.box(self, Vector3(46, 0.012, 0.085), Vector3(0, 0.025, side * 24), paint)
		for along in range(-24, 25, 4):
			_wall(Vector3(along, 0, side * 29), Vector3(3.75, rng.randf_range(0.9, 2.7), 1.2))
			_wall(Vector3(side * 29, 0, along), Vector3(1.2, rng.randf_range(0.9, 2.7), 3.75))
		for z in [-24, -8, 8, 24]:
			var pillar := Vector3(side * 26, 0, z)
			Geo.box(self, Vector3(1.1, 0.3, 1.1), pillar + Vector3.UP * 0.15, dark)
			Geo.box(self, Vector3(0.6, 2.5, 0.6), pillar + Vector3.UP * 1.5, stone)
			Geo.cylinder(self, 0.5, 0.2, pillar + Vector3.UP * 2.9, dark)
			Geo.sphere(self, 0.22, pillar + Vector3.UP * 3.15, cyan)
	# Start position, forward chevrons and scattered rubble outside the range.
	var start_marker := Geo.ring(self, 2.6, 0.09, Vector3(0, 0.034, 5), cyan)
	start_marker.scale.y = 0.12
	Geo.mark_ui(start_marker)
	for z in [1.8, 0.7, -0.4]:
		Geo.mark_ui(Geo.line(self, Vector3(-0.42, 0.05, z + 0.35), Vector3(0, 0.05, z), 0.065, paint))
		Geo.mark_ui(Geo.line(self, Vector3(0.42, 0.05, z + 0.35), Vector3(0, 0.05, z), 0.065, paint))
	for i in 65:
		var angle := rng.randf() * TAU
		var dist := rng.randf_range(30, 44)
		var n := Geo.box(self, Vector3(rng.randf_range(0.3, 1.5), rng.randf_range(0.2, 0.7), rng.randf_range(0.4, 1.7)), Vector3(cos(angle) * dist, 0.15, sin(angle) * dist), stone)
		n.rotation = Vector3(rng.randf() * 0.3, angle, rng.randf() * 0.2)

func _wall(pos: Vector3, size: Vector3) -> void:
	var wall := StaticBody3D.new()
	add_child(wall)
	wall.position = pos
	Geo.collider(wall, Vector3(size.x, 7.0, size.z), Vector3(0, 3.5, 0))
	Geo.box(wall, size, Vector3.UP * size.y / 2, dark)
	Geo.box(wall, Vector3(size.x + 0.12, 0.18, size.z + 0.12), Vector3.UP * size.y, stone)

func _build_targets() -> void:
	if level:
		level.build_targets()
		return
	var locations := [Vector3(0, 0, -8), Vector3(-7, 0, -5), Vector3(7, 0, -7), Vector3(-5, 0, -14), Vector3(4, 0, -15), Vector3(12, 0, -1), Vector3(-13, 0, 1), Vector3(11, 0, 9), Vector3(-9, 0, 11)]
	for i in locations.size():
		target_specs.append({"pos": locations[i], "barrel": false, "id": i + 1})
	for pos in [Vector3(-3, 0, -13), Vector3(-1, 0, -13), Vector3(6, 0, -14), Vector3(9, 0, -7)]:
		target_specs.append({"pos": pos, "barrel": true, "id": target_specs.size() + 1})
	for spec in target_specs:
		_spawn_target(spec)

func _spawn_target(spec: Dictionary) -> void:
	var target: PhysicsBody3D = HandObject.new() if spec.barrel else StaticBody3D.new()
	if target is RigidBody3D:
		target.arena = self
		target.mass = 6.0
		target.freeze = true
		target.collision_layer = 1 | 8
		target.collision_mask = 9 | 32
	target.name = "Target_%02d" % spec.id
	add_child(target)
	target.position = spec.pos
	target.set_meta("spec", spec)
	target.set_meta("hp", 8.0 if spec.barrel else 100.0)
	target.set_meta("target", true)
	targets.append(target)
	if battle: battle.nav_dirty = true
	var height := 1.3 if spec.barrel else 2.8
	var width := 0.85 if spec.barrel else 1.15
	Geo.collider(target, Vector3(width, height, width), Vector3.UP * height / 2)
	if spec.barrel:
		TowerHand.register_item(target, Vector3(width, height, width), "ПОРОХОВАЯ БОЧКА", Vector3.UP * height * 0.5)
		Geo.cylinder(target, 0.43, 1.2, Vector3.UP * 0.6, powder_red if spec.get("entry_supply",false) else dark, 10)
		for y in [0.16, 0.94]:
			Geo.cylinder(target, 0.46, 0.16, Vector3.UP * y, amber, 10)
		Geo.cylinder(target, 0.27, 0.1, Vector3.UP * 1.23, red, 8)
	else:
		Geo.box(target, Vector3(1.7, 0.25, 1.7), Vector3.UP * 0.125, dark)
		Geo.box(target, Vector3(1.15, 1.95, 1.15), Vector3.UP * 1.2, stone)
		for y in [0.45, 1.2, 2.1]:
			Geo.box(target, Vector3(1.23, 0.11, 1.23), Vector3.UP * y, dark)
		Geo.cylinder(target, 0.68, 0.3, Vector3.UP * 2.37, dark, 4, 0.4)
		Geo.cylinder(target, 0.27, 0.57, Vector3.UP * 2.79, red, 4, 0.0)
		var crystal_base := Geo.cylinder(target, 0.27, 0.22, Vector3.UP * 2.4, red, 4, 0.0)
		crystal_base.rotation.x = PI
		for side in [-1, 1]:
			Geo.box(target, Vector3(0.3, 0.55, 0.025), Vector3(0, 1.67, side * 0.59), red)
			Geo.box(target, Vector3(0.025, 0.55, 0.3), Vector3(side * 0.59, 1.67, 0), red)
		var label := Label3D.new()
		target.add_child(label)
		label.position.y = 3.5
		label.text = "%02d" % spec.id
		label.font_size = 40
		label.pixel_size = 0.009
		label.modulate = Color("ecd9b8")
		label.outline_modulate = Color("202c30")
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true

func _physics_process(dt: float) -> void:
	if not is_instance_valid(tank):
		return
	if _reset_requested:
		_reset_requested = false
		reset_range()
	if freeze > 0.0:
		freeze -= dt
		return
	_update_aim(dt)
	props.tick(dt)
	crew.tick(dt)
	if crew.crewed:
		tank.aim_world = aim_position
	tank.tick(dt)
	hand.tick(dt)
	_update_actual_hit()
	_update_shells(dt)
	battle.tick(dt)
	if level: level.tick(dt)
	for i in range(respawns.size() - 1, -1, -1):
		respawns[i].time -= dt
		if respawns[i].time <= 0.0 and tank.global_position.distance_to(respawns[i].spec.pos) > 3.5 and (crew.crewed or crew.center().distance_to(respawns[i].spec.pos) > 4.0):
			_spawn_target(respawns[i].spec)
			respawns.remove_at(i)

func _process(dt: float) -> void:
	var real_dt := dt / maxf(Engine.time_scale, 0.01)
	if tank and tank.dash:
		if tank.dash.is_aiming(): _update_aim(real_dt)
		tank.dash.frame(real_dt)
	time += dt
	trauma = maxf(0.0, trauma - dt * 1.9)
	kick = kick.lerp(Vector3.ZERO, 1.0 - exp(-dt * 10))
	zoom_punch = lerpf(zoom_punch, 0.0, 1.0 - exp(-dt * 7))
	flash_alpha = maxf(0.0, flash_alpha - dt * 4.0)
	ready_pulse = maxf(0.0, ready_pulse - dt * 2.3)
	hit_pulse = maxf(0.0, hit_pulse - dt * 3.0)
	if camera and tank:
		_update_camera(real_dt)
	if hud:
		hud.update_reticle(dt)
		hud.queue_redraw()

func _update_camera(dt: float) -> void:
	# Target height must not move the camera and make that same target leave
	# the mouse ray again. Follow the ground projection, independent of hits.
	var followed: Vector3 = crew.center() if crew != null and not crew.crewed else tank.position
	var lead: Vector3 = (ground_aim_position - followed) * 0.13
	lead.y = 0.0
	lead = lead.limit_length(2.8)
	var desired: Vector3 = followed + Vector3(0, 0.75, 0) + lead
	focus = focus.lerp(desired, 1.0 - exp(-dt * 5.0))
	var shake := trauma * trauma * shake_strength
	var offset := Vector3(sin(time * 103) * 0.44, cos(time * 91) * 0.25, sin(time * 117) * 0.35) * shake
	var base_orbit := CANYON_CAMERA_ORBIT_OFFSET if level else CAMERA_ORBIT_OFFSET
	var orbit := base_orbit.rotated(Vector3.UP, camera_yaw - CAMERA_DEFAULT_YAW)
	if level: orbit *= zoom/30.0
	aim_camera.position = focus + orbit
	aim_camera.look_at(focus)
	aim_camera.size = zoom
	camera.global_transform = aim_camera.global_transform
	camera.position += offset + kick * shake_strength
	camera.rotation.z += sin(time * 85) * shake * 0.011
	camera.size = zoom + zoom_punch * shake_strength
	if level: camera.position += orbit.normalized()*zoom_punch*shake_strength

func ground_height(point: Vector3) -> float:
	return level.ground_height(point) if level else 0.0

func terrain_point(origin: Vector3, direction: Vector3, extra_mask: int=0) -> Vector3:
	if level:
		var ray := PhysicsRayQueryParameters3D.create(origin,origin+direction*1000.0,1024|extra_mask)
		var hit := get_world_3d().direct_space_state.intersect_ray(ray)
		if hit: return hit.position
	var flat = Plane(Vector3.UP,0.0).intersects_ray(origin,direction)
	return flat if flat!=null else origin+direction*100

func _update_aim(dt: float, pointer: Vector2 = Vector2.INF) -> void:
	if camera_rotating: return
	if test_aim:
		ground_aim_position = Vector3(aim_position.x, ground_height(aim_position), aim_position.z)
	if not test_aim and not tuning_open:
		var mouse := get_viewport().get_mouse_position() if not pointer.is_finite() else pointer
		var origin := aim_camera.project_ray_origin(mouse)
		var direction := aim_camera.project_ray_normal(mouse)
		var desired := aim_position
		var ground_hit = terrain_point(origin,direction)
		if ground_hit != null:
			ground_aim_position = ground_hit
			desired = ground_hit
		# Ease the depth transition when crossing a target silhouette.
		var ray := PhysicsRayQueryParameters3D.create(origin, origin + direction * 180, 97)
		var hit := get_world_3d().direct_space_state.intersect_ray(ray)
		if hit and (hit.collider.has_meta("target") or hit.collider.has_meta("breakable") or hit.collider.has_meta("enemy")):
			desired = hit.position
		aim_position = aim_position.lerp(desired, 1.0 - exp(-dt * 22.0))

func _update_actual_hit() -> void:
	if not crew.crewed:
		actual_hit = aim_position
		return
	var start: Vector3 = tank.muzzle.global_position
	var end: Vector3 = start - tank.muzzle.global_basis.z * 85.0
	var query := PhysicsRayQueryParameters3D.create(start, end, 97)
	var actual := get_world_3d().direct_space_state.intersect_ray(query)
	actual_hit = actual.position if actual else end

func shoot(origin: Vector3, direction: Vector3) -> void:
	var shell := Geo.sphere(self, 0.14, origin, bullet_material)
	shell.name = "CannonShell"
	shells.append({"node": shell, "vel": direction * 57.0, "life": 2.1})
	fx.muzzle(origin, direction)
	fx.ring(tank.position + Vector3.UP * 0.06, 0.55, fx.dust_mat)
	sound.play("fire")
	add_trauma(0.8)
	kick -= Vector3(direction.x, 0, direction.z) * 0.6
	zoom_punch = 1.3
	freeze = 0.045
	flash_alpha = 0.14

func _update_shells(dt: float) -> void:
	for i in range(shells.size() - 1, -1, -1):
		var shell: Dictionary = shells[i]
		var old: Vector3 = shell.node.position
		var next: Vector3 = old + shell.vel * dt
		var ray := PhysicsRayQueryParameters3D.create(old, next, 97)
		var hit := get_world_3d().direct_space_state.intersect_ray(ray)
		fx.trail(old, hit.position if hit else next)
		shell.node.position = next
		shell.life -= dt
		if hit:
			_explode(hit.position, hit.collider)
		if hit or shell.life <= 0.0:
			shell.node.queue_free()
			shells.remove_at(i)

func _explode(pos: Vector3, collider: Object = null, large: bool = false) -> void:
	# Dungeon barrel balance: radius 4.5, 25 to soldiers, 150 to enemies.
	# Cannon splash keeps its existing 60 damage and 2.8 m radius.
	var radius := 4.5 if large else 2.8
	props.blast(pos, 3.6 if large else radius)
	crew.blast(pos, radius, 25.0 if large else 60.0)
	fx.impact(pos, large)
	var distance: float = tank.position.distance_to(pos)
	add_trauma((0.65 if large else 0.38) * clampf(1.0 - distance / 45.0, 0.15, 1.0))
	sound.play("impact", -3.0 if large else -6.0, 0.85 if large else 1.0)
	if collider != null and is_instance_valid(collider) and (collider.has_meta("target") or collider.has_meta("enemy")):
		_damage_target(collider, 110.0, (collider.global_position - pos).normalized(), 12.0)
	for target in combat_targets():
		if not is_instance_valid(target) or target == collider:
			continue
		var dist: float = (target.position + Vector3.UP).distance_to(pos)
		if dist <= radius:
			if large and target.has_meta("spec") and target.get_meta("spec").barrel:
				if not target.get_meta("blast_pending", false):
					target.set_meta("blast_pending", true)
					get_tree().create_timer(0.18, false, true).timeout.connect(_detonate_barrel.bind(weakref(target), _range_generation))
			else:
				_damage_target(target, 150.0 if large else 60.0, (target.global_position - pos).normalized(), 12.0)

func _detonate_barrel(ref: WeakRef, generation: int) -> void:
	var target = ref.get_ref()
	if generation == _range_generation and is_instance_valid(target):
		_damage_target(target, 99.0)

func strike_clear(from: Vector3, to: Vector3) -> bool:
	# Range targets share layer 1 with walls; ignore them for radial strike LOS.
	var excluded: Array[RID] = []
	for target in targets: excluded.append(target.get_rid())
	var query := PhysicsRayQueryParameters3D.create(from+Vector3.UP*0.9, to+Vector3.UP*0.9, 3, excluded)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func combat_targets() -> Array:
	var result: Array = []
	result.append_array(targets)
	if battle: result.append_array(battle.enemies)
	return result

func _damage_target(target: Node3D, damage: float, direction: Vector3 = Vector3.ZERO, force: float = 0.0, source: StringName = &"") -> void:
	if level and target.has_meta("ore"):
		level.damage_ore(target, damage, direction)
		return
	if target.has_meta("enemy"):
		target.take_damage(damage, direction, force, source)
		return
	if not targets.has(target):
		return
	hit_pulse = 1.0
	var hp: float = target.get_meta("hp") - damage
	target.set_meta("hp", hp)
	if hp > 0.0:
		var tween := create_tween()
		tween.tween_property(target, "rotation:z", 0.1, 0.07)
		tween.tween_property(target, "rotation:z", 0.0, 0.16)
		return
	var spec: Dictionary = target.get_meta("spec")
	var pos := target.position
	targets.erase(target)
	if battle: battle.nav_dirty = true
	target.collision_layer = 0
	target.hide()
	target.queue_free()
	kills += 1
	if crew != null:
		for i in 3:
			crew.loot.spawn_coin(pos + Vector3.UP * 1.0, Vector3(sin(i * 2.1) * 2.0, 3.0, cos(i * 2.1) * 2.0))
	if not level: respawns.append({"spec": spec, "time": 7.5})
	fx.impact(pos + Vector3.UP * 1.2, true)
	freeze = maxf(freeze, 0.045)
	if spec.barrel:
		# Deferred chain reaction avoids editing the active target iteration.
		_chain_blast.call_deferred(pos + Vector3.UP * 0.7, _range_generation)

func _chain_blast(pos: Vector3, generation: int) -> void:
	if generation == _range_generation: _explode(pos, null, true)

func add_trauma(amount: float) -> void:
	trauma = minf(1.0, trauma + amount)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_EQUAL:
		set_interface_visible(not interface_visible)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			if not tuning_open and not pointer_over_ui(): _begin_camera_rotation()
		else:
			_end_camera_rotation()
		get_viewport().set_input_as_handled()
		return
	if camera_rotating and event is InputEventMouseMotion:
		var delta: Vector2 = event.screen_relative
		camera_yaw = wrapf(camera_yaw - delta.x * CAMERA_TURN_SENSITIVITY, -PI, PI)
		_update_camera(0.0)
		get_viewport().set_input_as_handled()
		return
	if camera_rotating and event is InputEventKey and event.pressed and event.physical_keycode in [KEY_F, KEY_E, KEY_TAB, KEY_R, KEY_ESCAPE]:
		_end_camera_rotation()
	if event is InputEventKey and event.physical_keycode == KEY_SPACE and not event.echo and crew.crewed:
		tank.dash.space(event.pressed)
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_F2:
				_end_camera_rotation()
				hand.cancel_drag()
				tank.dash.cancel()
				get_tree().change_scene_to_file.call_deferred("res://main.tscn" if desert_mode else "res://desert.tscn")
			KEY_G:
				if level and interface_visible and not tuning_open: level.toggle_map()
			KEY_F:
				if not tuning_open and crew.crewed:
					hand.set_enabled(not hand.enabled)
					get_viewport().set_input_as_handled()
			KEY_E:
				if not tuning_open: crew.interact_requested = true
			KEY_Q:
				if not tuning_open: crew.drop_requested = true
			KEY_R:
				tank.dash.cancel()
				tank.crossbows.cancel_trigger()
				_reset_requested = true
			KEY_N:
				if not tuning_open and battle.waves_enabled: battle.wave_requested = true
			KEY_TAB:
				if not interface_visible: return
				hand.cancel_drag()
				tank.dash.cancel()
				tank.crossbows.cancel_trigger()
				get_viewport().set_input_as_handled()
				tuning_open = not tuning_open
				hud.panel.visible = tuning_open
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if tuning_open else Input.MOUSE_MODE_HIDDEN
			KEY_M:
				sound.muted = not sound.muted
				AudioServer.set_bus_mute(0, sound.muted)
			KEY_ESCAPE:
				if tank.dash.is_aiming():
					tank.dash.cancel()
				elif tuning_open:
					tuning_open = false
					hud.panel.hide()
					Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
				else:
					get_tree().quit()
			KEY_F12: _capture("user://iron_citadel.png")
	if hand.enabled and event is InputEventMouseButton and not tank.dash.is_aiming():
		if event.button_index == MOUSE_BUTTON_LEFT:
			hand.trigger(event.pressed)
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed: hand.place_gently()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed and tank.dash.commit():
			tank.crossbows.cancel_trigger()
			get_viewport().set_input_as_handled()
		else:
			tank.crossbows.trigger(event.pressed)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and not tuning_open:
			zoom = maxf(18.0, zoom - 1.5)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and not tuning_open:
			zoom = minf(72.0, zoom + 1.5)
		elif event.button_index == MOUSE_BUTTON_LEFT and weapon_mode_active() and not tuning_open and crew.crewed and crew.input_armed and not pointer_over_ui() and not tank.dash.blocks_gun():
			# A press in the last 0.18 s of reload is remembered.
			tank.buffered_shot = 0.18

func _register_world_label(node: Node) -> void:
	if node is Label3D: Geo.mark_ui(node)

func set_interface_visible(value: bool) -> void:
	interface_visible = value
	if not value and tuning_open:
		tuning_open = false
		hud.panel.hide()
		if not camera_rotating: Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	hud.visible = value
	camera.cull_mask = (camera.cull_mask | Geo.UI_LAYER) if value else (camera.cull_mask & ~Geo.UI_LAYER)
	aim_camera.cull_mask = camera.cull_mask

func _begin_camera_rotation() -> void:
	if camera_rotating: return
	camera_return_pointer = get_viewport().get_mouse_position()
	camera_rotating = true
	tank.buffered_shot = 0.0
	tank.crossbows.cancel_trigger()
	crew.input_armed = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	hud.reset_reticle()

func _end_camera_rotation(restore_pointer: bool = true) -> void:
	if not camera_rotating: return
	camera_rotating = false
	crew.input_armed = false
	tank.buffered_shot = 0.0
	tank.crossbows.cancel_trigger()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if tuning_open else Input.MOUSE_MODE_HIDDEN
	if restore_pointer:
		var pointer := camera_return_pointer
		if hand != null and is_instance_valid(hand.held):
			pointer = aim_camera.unproject_position(hand.cursor_world)
			# Discard camera motion from the throw velocity history.
			hand.velocity_history.clear()
			hand.cursor_initialized = false
		var viewport := get_viewport().get_visible_rect()
		Input.warp_mouse(pointer.clamp(viewport.position, viewport.end - Vector2.ONE))
	hud.reset_reticle()

func pointer_over_ui() -> bool:
	return camera_rotating or (hud != null and hud.pointer_over_ui())

func weapon_mode_active() -> bool:
	return hand == null or not hand.enabled

func reset_range() -> void:
	_end_camera_rotation()
	camera_yaw = CAMERA_DEFAULT_YAW
	_range_generation += 1
	if hand: hand.reset()
	if battle: battle.reset()
	for target in targets:
		target.collision_layer = 0
		target.queue_free()
	targets.clear()
	respawns.clear()
	for shell in shells:
		shell.node.queue_free()
	shells.clear()
	fx.clear()
	for spec in target_specs:
		_spawn_target(spec)
	tank.reset_state()
	crew.reset()
	props.reset()
	if level: level.setup_gameplay()
	tank.shot_count = 0
	kills = 0
	trauma = 0.0
	freeze = 0.0
	zoom_punch = 0.0
	kick = Vector3.ZERO
	flash_alpha = 0.0
	hit_pulse = 0.0
	focus = tank.position + Vector3.UP
	ground_aim_position = Vector3(aim_position.x, 0, aim_position.z)
	hud.reset_reticle()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(tank) and tank.dash != null:
		_end_camera_rotation(false)
		if hand: hand.cancel_drag()
		crew.input_armed = false
		Input.action_release("tank_cruise")
		tank.cruising = false
		tank.dash.cancel()
		tank.crossbows.cancel_trigger()

func verification_path(filename: String) -> String:
	var directory := "res://verification/" if OS.has_feature("editor") else "user://verification/"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--report-dir="):
			directory = arg.trim_prefix("--report-dir=").path_join("") + "/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	return directory + filename

func _capture(path: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if path.begins_with("res://verification/"):
		path = verification_path(path.get_file())
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("CAPTURE: ", path)

func _smoke_test() -> void:
	# Exercises the real input path, world collision, lag, firing and reload.
	test_aim = true
	aim_position = Vector3(0, 1.5, -8)
	await get_tree().create_timer(0.5).timeout
	await _capture("res://verification/01_ready.png")
	var start: Vector3 = tank.position
	Input.action_press("tank_forward")
	await get_tree().create_timer(0.6).timeout
	Input.action_release("tank_forward")
	var forward_ok: bool = tank.position.z < start.z - 0.5 and tank.position.x < start.x - 0.5
	start = tank.position
	Input.action_press("tank_left")
	await get_tree().create_timer(0.45).timeout
	Input.action_release("tank_left")
	var left_ok: bool = (tank.position - start).dot(aim_camera.global_basis.x) < -1.0
	await get_tree().create_timer(0.35).timeout
	tank.reset_state()
	Input.action_press("tank_reverse")
	await get_tree().create_timer(0.6).timeout
	Input.action_release("tank_reverse")
	var reverse_ok: bool = tank.position.z > 5.5
	tank.reset_state()
	aim_position = Vector3(12, 1.5, 5)
	await get_tree().physics_frame
	var lag_ok: bool = absf(angle_difference(tank.turret_yaw, -PI / 2)) > 0.5
	await get_tree().create_timer(1.0).timeout
	var convergence_ok: bool = absf(angle_difference(tank.turret_yaw, -PI / 2)) < 0.06
	aim_position = Vector3(0, 1.5, -8)
	await get_tree().create_timer(1.1).timeout
	Input.action_press("tank_fire")
	await get_tree().create_timer(0.055).timeout
	Input.action_release("tank_fire")
	await _capture("res://verification/02_fire.png")
	var first_shot: int = tank.shot_count
	Input.action_press("tank_fire")
	await get_tree().create_timer(0.35).timeout
	Input.action_release("tank_fire")
	var reload_blocks: bool = tank.shot_count == first_shot
	await _capture("res://verification/03_impact.png")
	await get_tree().create_timer(1.6).timeout
	var hit_ok: bool = kills >= 1
	var reload_ok: bool = tank.cooldown <= 0.0
	var result := {"forward": forward_ok, "left_moves_in_screen_direction": left_ok, "reverse": reverse_ok, "aim_lag": lag_ok, "aim_converges": convergence_ok, "reload_blocks_fire": reload_blocks, "projectile_destroys_target": hit_ok, "reload_finishes": reload_ok}
	# A second shot proves the chamber unlocks after reload.
	Input.action_press("tank_fire")
	await get_tree().create_timer(0.15).timeout
	Input.action_release("tank_fire")
	result["second_shot"] = tank.shot_count == first_shot + 1
	_reset_requested = true
	await get_tree().create_timer(0.15).timeout
	result["reset"] = targets.size() == target_specs.size() and kills == 0 and shells.is_empty()
	var tab_event := InputEventKey.new()
	tab_event.physical_keycode = KEY_TAB
	tab_event.keycode = KEY_TAB
	tab_event.pressed = true
	Input.parse_input_event(tab_event.duplicate())
	await get_tree().process_frame
	result["tuning_opens"] = tuning_open and hud.panel.visible
	var sliders: Array[Node] = hud.find_children("*", "HSlider", true, false)
	var lag_slider: HSlider = sliders[0]
	lag_slider.grab_focus()
	lag_slider.value = 0.26
	result["tuning_applies"] = is_equal_approx(tank.aim_lag, 0.26)
	await _capture("res://verification/04_tuning.png")
	tab_event.pressed = false
	Input.parse_input_event(tab_event.duplicate())
	tab_event.pressed = true
	Input.parse_input_event(tab_event.duplicate())
	await get_tree().process_frame
	result["tuning_closes_with_slider_focus"] = not tuning_open and not hud.panel.visible
	tab_event.pressed = false
	Input.parse_input_event(tab_event.duplicate())
	var walker_checks: Dictionary = await _check_walker()
	result.merge(walker_checks)
	var passed := true
	for ok in result.values():
		passed = passed and ok
	print("SMOKE_RESULT: ", JSON.stringify(result))
	var file := FileAccess.open(verification_path("smoke_result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	get_tree().quit(0 if passed else 1)

func _check_walker() -> Dictionary:
	reset_range()
	await get_tree().physics_frame
	var checks := {"two_legs": tank.walker.legs.size() == 2, "feet_stay_planted": true, "one_support_foot": true, "legs_connected": true}
	var lifts := 0
	var stance_samples := 0
	var screenshot_taken := false
	var max_leg := 0.0
	Input.action_press("tank_forward")
	for frame in 105:
		var before: Array[Dictionary] = []
		for leg in tank.walker.legs:
			before.append({"pos": leg.foot.global_position, "swing": leg.swing})
		await get_tree().physics_frame
		var airborne := 0
		for i in 2:
			var leg: Dictionary = tank.walker.legs[i]
			if not before[i].swing and not leg.swing:
				stance_samples += 1
				if before[i].pos.distance_to(leg.foot.global_position) > 0.002:
					checks.feet_stay_planted = false
			if leg.foot.global_position.y > 0.10:
				airborne += 1
				lifts += 1
			max_leg = maxf(max_leg, leg.stem.scale.y)
			checks.legs_connected = checks.legs_connected and leg.stem.to_global(Vector3(0, -0.5, 0)).distance_to(leg.foot.to_global(Vector3(0, 0.88, 0.11))) < 0.005
		if airborne > 1:
			checks.one_support_foot = false
		if frame > 40 and airborne == 1 and not screenshot_taken:
			screenshot_taken = true
			await _capture("res://verification/05_walking.png")
	Input.action_release("tank_forward")
	# Allow the chassis to brake and both feet to finish settling.
	await get_tree().create_timer(1.7).timeout
	checks["legs_step"] = lifts > 15 and tank.walker.footfalls >= 3 and stance_samples > 20
	checks["feet_settle"] = not tank.walker.legs[0].swing and not tank.walker.legs[1].swing
	var count_before: int = tank.walker.footfalls
	await get_tree().create_timer(0.4).timeout
	checks["idle_feet_stable"] = tank.walker.footfalls == count_before
	Input.action_press("tank_right")
	await get_tree().create_timer(1.2).timeout
	Input.action_release("tank_right")
	checks["sideways_steps"] = tank.walker.footfalls > count_before
	await get_tree().create_timer(0.8).timeout
	count_before = tank.walker.footfalls
	Input.action_press("tank_reverse")
	await get_tree().create_timer(1.2).timeout
	Input.action_release("tank_reverse")
	checks["reverse_steps"] = tank.walker.footfalls > count_before
	print("WALKER_METRICS: ", JSON.stringify({"lift_samples": lifts, "stance_samples": stance_samples, "max_leg_length": max_leg, "footfalls": tank.walker.footfalls}))
	return checks
