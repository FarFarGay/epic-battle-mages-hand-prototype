extends Node3D
## One shared animated mesh for the whole crowd, plus batched world UI.
const Geo = preload("res://scripts/geo.gd")
const CAPACITY := 1024
var battle
var bodies: MultiMesh
var shields: MultiMesh
var guard_gear: MultiMesh
var warnings: MultiMesh
var bars: MultiMesh
var debris: MultiMesh
var debris_states: Array[Dictionary] = []
var debris_cursor := 0
var chunks: Array[Dictionary] = []
var bone_color := Color(0.88, 0.85, 0.78, 1)
var _surface: SurfaceTool

func _ready() -> void:
	var material := ShaderMaterial.new()
	material.shader = preload("res://scripts/crowd.gdshader")
	bodies = _batch(_build_mesh(), material)
	shields = _batch(_build_shield_mesh(), material)
	guard_gear = _batch(_build_guard_mesh(), material)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.65
	ring.outer_radius = 0.72
	ring.rings = 24
	ring.ring_segments = 4
	warnings = _batch(ring, Geo.material(Color("f0a04c"), 0, 1.0), true)
	var bar := BoxMesh.new()
	bar.size = Vector3(0.75, 0.075, 0.02)
	var bar_shader := Shader.new()
	bar_shader.code = "shader_type spatial; render_mode unshaded; varying float hp; varying float shield; void vertex(){ hp = INSTANCE_CUSTOM.x; shield = INSTANCE_CUSTOM.y; } void fragment(){ ALBEDO = UV.x < hp ? mix(vec3(1.0,0.22,0.06),vec3(0.18,0.72,1.0),shield) : vec3(0.12,0.15,0.16); }"
	var bar_material := ShaderMaterial.new()
	bar_material.shader = bar_shader
	bars = _batch(bar, bar_material, true)
	var chip := BoxMesh.new()
	var chip_shader := Shader.new()
	chip_shader.code = "shader_type spatial; varying vec3 tint; void vertex(){ tint = INSTANCE_CUSTOM.rgb; } void fragment(){ ALBEDO = tint; ROUGHNESS = 0.74; }"
	var chip_material := ShaderMaterial.new()
	chip_material.shader = chip_shader
	debris = _batch(chip, chip_material)
	get_child(get_child_count() - 1).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _batch(mesh: Mesh, material: Material, ui: bool = false) -> MultiMesh:
	var node := MultiMeshInstance3D.new()
	var data := MultiMesh.new()
	data.transform_format = MultiMesh.TRANSFORM_3D
	data.use_custom_data = true
	data.instance_count = CAPACITY
	data.visible_instance_count = 0
	data.mesh = mesh
	data.custom_aabb = AABB(Vector3(-36, -10, -36), Vector3(72, 30, 72))
	if battle.arena.level:
		var bounds: Rect2 = battle.arena.world_bounds.grow(12.0)
		data.custom_aabb = AABB(Vector3(bounds.position.x, -10, bounds.position.y), Vector3(bounds.size.x, 40, bounds.size.y))
	node.multimesh = data
	node.material_override = material
	add_child(node)
	if ui: Geo.mark_ui(node)
	return data

func update_instances() -> void:
	if not is_visible_in_tree(): return
	var count := 0
	var warning_count := 0
	var bar_count := 0
	var shield_count := 0
	var guard_count := 0
	var camera_basis: Basis = battle.arena.aim_camera.global_basis
	for enemy in battle.enemies:
		if enemy.dead or count >= CAPACITY: continue
		var pose: Transform3D = enemy.global_transform
		var phase: float = enemy.stride
		if not enemy.hand_held and not enemy.hand_thrown and enemy.render_time >= 0.0 and battle.arena.is_physics_processing() and not battle.arena.tuning_open and battle.arena.freeze <= 0.0:
			var display_time: float = battle.simulation_time + Engine.get_physics_interpolation_fraction() * battle.get_physics_process_delta_time()
			var alpha := clampf((display_time - enemy.render_time) / maxf(enemy.render_period, 0.001), 0.0, 1.0)
			pose.origin = enemy.render_from.lerp(pose.origin, alpha)
			phase = lerpf(enemy.render_stride, phase, alpha)
		var body_pose: Transform3D = pose * enemy.visual.transform.scaled_local(Vector3.ONE * enemy.body_size)
		bodies.set_instance_transform(count, body_pose)
		var mode: int = 5 if enemy.hand_held else (6 if enemy.hand_thrown else enemy.state)
		var animation := Color(phase, enemy.animation_speed, mode + (16 if enemy.hit_flash > 0.0 else 0) + (32 if enemy.giant else 0), enemy.body_lean)
		bodies.set_instance_custom_data(count, animation)
		if enemy.shield_guard:
			guard_gear.set_instance_transform(guard_count, body_pose)
			guard_gear.set_instance_custom_data(guard_count, animation)
			guard_count += 1
			if enemy.shield_hp>0.0:
				shields.set_instance_transform(shield_count, body_pose)
				shields.set_instance_custom_data(shield_count, animation)
				shield_count += 1
		count += 1
		if enemy.warning.visible:
			warnings.set_instance_transform(warning_count, Transform3D(Basis.from_scale(Vector3(enemy.body_size, 0.12, enemy.body_size)), enemy.position + Vector3.UP * 0.06))
			warning_count += 1
		var show_shield: bool = enemy.shield_hp>0.0 and enemy.shield_hp<enemy.SHIELD_MAX_HP
		if enemy.giant or enemy.hp < enemy.max_hp or show_shield:
			bars.set_instance_transform(bar_count, Transform3D(camera_basis.scaled_local(Vector3(1.8, 1.5, 1) if enemy.giant else Vector3.ONE), enemy.position + Vector3.UP * (enemy.body_height + 0.3)))
			bars.set_instance_custom_data(bar_count, Color(enemy.shield_hp/enemy.SHIELD_MAX_HP if show_shield else enemy.hp/enemy.max_hp,1 if show_shield else 0,0,0))
			bar_count += 1
	bodies.visible_instance_count = count
	shields.visible_instance_count = shield_count
	guard_gear.visible_instance_count = guard_count
	warnings.visible_instance_count = warning_count
	bars.visible_instance_count = bar_count

func _box(size: Vector3, pos: Vector3, part: float = 0, color: Color = Color(0.88, 0.85, 0.78, 1), glow: float = 0.0, palette_override: float = -1.0) -> void:
	var box := BoxMesh.new()
	box.size = size
	var arrays := box.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for index in indices:
		_surface.set_normal(normals[index])
		var palette := 0.0 if color.a > 0.5 else (3.0 if glow > 0.0 else (1.0 if color.r < 0.2 else 2.0))
		if palette_override>=0.0: palette = palette_override
		_surface.set_uv2(Vector2(part, palette))
		_surface.add_vertex(vertices[index] + pos)
	if color.a > 0.5: chunks.append({"mesh": box, "position": pos})

func _build_mesh() -> ArrayMesh:
	_surface = SurfaceTool.new()
	_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var chest := Vector3.UP * 0.95
	_box(Vector3(0.13, 0.61, 0.12), chest + Vector3(0, 0.12, 0.09))
	_box(Vector3(0.44, 0.13, 0.25), chest + Vector3(0, -0.05, 0))
	for i in 4:
		var width := 0.53 - absf(i - 1.5) * 0.055
		_box(Vector3(width, 0.065, 0.08), chest + Vector3(0, 0.14 + i * 0.105, -0.15))
		for side in [-1, 1]: _box(Vector3(0.065, 0.065, 0.28), chest + Vector3(side * width * 0.5, 0.14 + i * 0.105, -0.02))
	_box(Vector3(0.63, 0.09, 0.17), chest + Vector3(0, 0.56, 0))
	_box(Vector3(0.12, 0.2, 0.12), chest + Vector3(0, 0.65, 0))
	_box(Vector3(0.40, 0.35, 0.33), chest + Vector3(0, 0.85, -0.025))
	_box(Vector3(0.28, 0.085, 0.25), chest + Vector3(0, 0.61, -0.07))
	for side in [-1, 1]:
		_box(Vector3(0.12, 0.11, 0.03), chest + Vector3(side * 0.105, 0.85, -0.198), 0, Color(0.14, 0.15, 0.16, 0))
		_box(Vector3(0.045, 0.036, 0.038), chest + Vector3(side * 0.105, 0.85, -0.216), 0, Color(1, 0.35, 0.24, 0), 1)
		for tooth in 2: _box(Vector3(0.046, 0.07, 0.07), chest + Vector3(side * (0.035 + tooth * 0.06), 0.67, -0.16))
		var arm := Vector3(side * 0.36, 1.45, 0)
		var arm_part := 1.0 if side < 0 else 2.0
		_box(Vector3(0.10, 0.35, 0.11), arm + Vector3(0, -0.15, 0), arm_part)
		_box(Vector3(0.11, 0.31, 0.10), arm + Vector3(0, -0.42, -0.09), arm_part)
		_box(Vector3(0.15, 0.14, 0.14), arm + Vector3(0, -0.58, -0.1), arm_part)
		var leg := Vector3(side * 0.19, 0.89, 0)
		var leg_part := 3.0 if side < 0 else 4.0
		_box(Vector3(0.13, 0.40, 0.14), leg + Vector3(0, -0.19, 0), leg_part)
		_box(Vector3(0.16, 0.13, 0.16), leg + Vector3(0, -0.42, -0.02), leg_part)
		_box(Vector3(0.1, 0.37, 0.11), leg + Vector3(0, -0.63, 0.025), leg_part)
		_box(Vector3(0.18, 0.10, 0.33), leg + Vector3(0, -0.82, -0.08), leg_part)
	var right_arm := Vector3(0.36, 1.45, 0)
	var rust := Color(0.40, 0.35, 0.30, 0)
	_box(Vector3(0.07, 0.07, 0.26), right_arm + Vector3(0, -0.58, -0.20), 2, rust)
	_box(Vector3(0.31, 0.07, 0.07), right_arm + Vector3(0, -0.58, -0.31), 2, rust)
	_box(Vector3(0.12, 0.055, 0.65), right_arm + Vector3(0, -0.58, -0.66), 2, rust)
	var mesh := _surface.commit()
	_surface = null
	return mesh

func _build_shield_mesh() -> ArrayMesh:
	_surface = SurfaceTool.new()
	_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trim := Color(0,0,0,0) # Gear is scattered separately from the bones.
	_box(Vector3(1.0,1.22,0.11),Vector3(-0.30,1.08,-0.40),1,trim,0,5)
	_box(Vector3(0.84,1.07,0.16),Vector3(-0.30,1.08,-0.47),1,trim,0,4)
	_box(Vector3(0.70,0.075,0.05),Vector3(-0.30,1.08,-0.565),1,trim,0,5)
	_box(Vector3(0.075,0.89,0.05),Vector3(-0.30,1.08,-0.565),1,trim,0,5)
	_box(Vector3(0.18,0.22,0.09),Vector3(-0.30,1.08,-0.615),1,trim,0,6)
	var mesh := _surface.commit()
	_surface = null
	return mesh

func _build_guard_mesh() -> ArrayMesh:
	_surface = SurfaceTool.new()
	_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var metal := Color(0,0,0,0)
	_box(Vector3(0.51,0.15,0.42),Vector3(0,1.98,-0.025),0,metal,0,6)
	_box(Vector3(0.53,0.065,0.45),Vector3(0,1.895,-0.025),0,metal,0,5)
	for side in [-1,1]:
		_box(Vector3(0.25,0.18,0.30),Vector3(side*0.36,1.46,0),1 if side<0 else 2,metal,0,6)
	var mesh := _surface.commit()
	_surface = null
	return mesh

func _add_debris(chip: Dictionary) -> void:
	if debris_states.size() < 384: debris_states.append(chip)
	else:
		debris_states[debris_cursor % 384] = chip
		debris_cursor += 1

func scatter_shield(enemy, direction: Vector3) -> void:
	for i in 4:
		var offset := Vector3((i%2-0.5)*0.42,(i/2-0.5)*0.48,0)
		_add_debris({"pos":enemy.to_global(Vector3(-0.3,1.08,-0.5)+offset),"velocity":direction*3.0+enemy.global_basis*Vector3(offset.x*7.0,2.5+i*0.4,-2.0),"life":1.4,"rotation":enemy.rotation,"size":Vector3(0.42,0.48,0.10),"color":Color("327f9e") if i%2==0 else Color("aa8751")})

func scatter(enemy, direction: Vector3, power: float) -> void:
	for i in range(0, chunks.size(), 3):
		var part: Dictionary = chunks[i]
		var spread := Vector3(sin(i * 2.4), 1.3, cos(i * 2.4)) * 2.0 * power
		var chip := {"pos": enemy.to_global(part.position * enemy.body_size), "velocity": spread + direction * power * 4.0, "life": 2.0, "rotation": enemy.rotation, "size": part.mesh.size * enemy.body_size}
		_add_debris(chip)

func clear_debris() -> void:
	debris_states.clear()
	debris.visible_instance_count = 0

func tick_debris(dt: float) -> void:
	var count := 0
	for i in range(debris_states.size() - 1, -1, -1):
		var chip := debris_states[i]
		chip.life -= dt
		if chip.life <= 0.0:
			debris_states.remove_at(i)
			continue
		chip.velocity.y -= 18.0 * dt
		chip.pos += chip.velocity * dt
		chip.rotation += Vector3(4, 3, 5) * dt
		var floor_y: float=battle.arena.ground_height(chip.pos)+0.12
		if chip.pos.y < floor_y:
			chip.pos.y = floor_y
			chip.velocity *= Vector3(0.78, -0.28, 0.78)
		if is_visible_in_tree():
			debris.set_instance_transform(count, Transform3D(Basis.from_euler(chip.rotation).scaled(chip.size * minf(chip.life * 5.0, 1.0)), chip.pos))
			debris.set_instance_custom_data(count,chip.get("color",bone_color))
		count += 1
	debris.visible_instance_count = count
