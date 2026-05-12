class_name AoeVisual
extends RefCounted
## Общие визуалы AOE-удара/взрыва: распирающаяся distortion-сфера и пыль.
##
## Используется и `HandPhysicalSlam` (хлопок по земле), и `Fireball` (взрыв) —
## единый визуальный язык для «удара о землю с разлётом всего вокруг».
## Изначально жил в Slam с пулом MeshInstance3D'ей; перенесён сюда без пула,
## так как и slam (cooldown 0.5с) и fireball (cooldown 3с) спавнят визуал
## редко — overhead на каждый instance ≈0.2мс, неощутимо для прототипа.
##
## Доп. визуал индикатора чёткого радиуса (`spawn_radius_indicator`) даёт
## явные «габариты» AOE — solid translucent sphere фиксированного размера,
## fade-out. Distortion-волна и так показывает радиус, но дизайнеру удобнее
## видеть жирную границу для тюнинга.

const DISTORTION_MATERIAL_PATH := "res://resources/slam_distortion_material.tres"
const DUST_MATERIAL_PATH := "res://resources/slam_dust_material.tres"
const DUST_PROCESS_PATH := "res://resources/slam_dust_process.tres"

## SphereMesh с radius=0.5 — distortion-шейдер расчитан на unit-радиус
## (sphere_dist = length(object_position) - 0.5). Если radius иной —
## dissolve_alpha постоянно 0 и эффект невидим. Размер компенсируется
## через mesh.scale = target_radius / 0.5.
const VISUAL_BASE_RADIUS := 0.5
const VISUAL_BASE_HEIGHT := 1.0

const DUST_AMOUNT := 72
const DUST_LIFETIME := 0.9
const DUST_QUAD_SIZE := 0.22


## Распирающаяся distortion-волна. Расширяется до `radius` за `duration` с
## затуханием intensity. На завершении tween'а — queue_free. Без пула.
static func spawn_wave(root: Node, pos: Vector3, radius: float, duration: float = 0.45) -> void:
	if root == null:
		return
	var base_mat := load(DISTORTION_MATERIAL_PATH) as ShaderMaterial
	if base_mat == null:
		push_error("[AoeVisual] не загрузился %s" % DISTORTION_MATERIAL_PATH)
		return
	var mat := base_mat.duplicate() as ShaderMaterial
	var sphere := SphereMesh.new()
	sphere.radius = VISUAL_BASE_RADIUS
	sphere.height = VISUAL_BASE_HEIGHT
	var mesh := MeshInstance3D.new()
	mesh.mesh = sphere
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	mesh.global_position = pos
	mat.set_shader_parameter("intensity", 1.0)
	mat.set_shader_parameter("ripple_time", 0.0)
	mat.set_shader_parameter("ripple_center", pos)
	var target_scale: float = radius / sphere.radius
	var tween := mesh.create_tween()
	tween.set_parallel(true)
	tween.tween_property(mesh, "scale", Vector3.ONE * target_scale, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(_set_param.bind(mat, "intensity"), 1.0, 0.0, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_method(_set_param.bind(mat, "ripple_time"), 0.0, 1.0, duration).set_trans(Tween.TRANS_LINEAR)
	_queue_free_on_tween_finished(tween, mesh)


static func _set_param(value: float, mat: ShaderMaterial, param_name: String) -> void:
	if mat == null or not is_instance_valid(mat):
		return
	mat.set_shader_parameter(param_name, value)


## Lambda-helper: queue_free node на timeout таймера, БЕЗ Godot 4.6 warning'а
## «Lambda capture at index 0 was freed». Capture lambda — WeakRef
## (RefCounted), который сам не free'ится с queue_free Node'а; внутри получаем
## ref через get_ref(). Используется во всех spawn_* функциях этого модуля
## для cleanup'а через SceneTreeTimer.
static func _schedule_queue_free(tree: SceneTree, node: Node, delay: float) -> void:
	var node_ref: WeakRef = weakref(node)
	tree.create_timer(delay).timeout.connect(func() -> void:
		var n: Node = node_ref.get_ref()
		if n != null:
			n.queue_free()
	)


## То же что [_schedule_queue_free], но для Tween.finished / tween_callback.
## Tween живёт пока инстанс жив; на finished — пробуем queue_free node через
## WeakRef.
static func _queue_free_on_tween_callback(tween: Tween, node: Node) -> void:
	var node_ref: WeakRef = weakref(node)
	tween.tween_callback(func() -> void:
		var n: Node = node_ref.get_ref()
		if n != null:
			n.queue_free()
	)


## Аналог [_queue_free_on_tween_callback] для tween.finished сигнала (когда
## tween — parallel и нет tween_callback хвоста). WeakRef капчит mesh.
static func _queue_free_on_tween_finished(tween: Tween, node: Node) -> void:
	var node_ref: WeakRef = weakref(node)
	tween.finished.connect(func() -> void:
		var n: Node = node_ref.get_ref()
		if n != null:
			n.queue_free()
	)


## Пыль одним залпом — GPUParticles3D one_shot, explosiveness=1.0
## (все частицы спавнятся в первый кадр). Cleanup через таймер
## lifetime+0.2с.
static func spawn_dust(root: Node, pos: Vector3) -> void:
	if root == null:
		return
	var process_mat := load(DUST_PROCESS_PATH) as ParticleProcessMaterial
	var dust_mat := load(DUST_MATERIAL_PATH) as StandardMaterial3D
	if process_mat == null or dust_mat == null:
		push_error("[AoeVisual] dust assets не загрузились")
		return
	var quad := QuadMesh.new()
	quad.size = Vector2(DUST_QUAD_SIZE, DUST_QUAD_SIZE)
	var particles := GPUParticles3D.new()
	particles.process_material = process_mat
	particles.draw_pass_1 = quad
	particles.material_override = dust_mat
	particles.amount = DUST_AMOUNT
	particles.lifetime = DUST_LIFETIME
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(particles)
	particles.global_position = pos
	particles.emitting = true
	_schedule_queue_free(root.get_tree(), particles, DUST_LIFETIME + 0.2)


## Полноценный взрыв: ядро-вспышка (sphere) + огненные частицы (быстрые,
## ярко-оранжевые, разлетаются радиально) + дымные (медленнее, темнее,
## поднимаются вверх). Всё процедурно, без внешних ассетов. Замена для
## связки spawn_wave + spawn_dust + spawn_radius_indicator — один вызов
## вместо трёх.
static func spawn_explosion(root: Node, pos: Vector3, radius: float) -> void:
	if root == null:
		return
	_explosion_core(root, pos, radius)
	_explosion_fire(root, pos, radius)
	_explosion_smoke(root, pos, radius)


## Ядро взрыва: sphere unshaded emission, scale 0 → peak → 0. Время 0.3с.
## Радиус peak = radius × 0.7 (70% AOE), остальное закрывают partикли.
static func _explosion_core(root: Node, pos: Vector3, radius: float) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 24
	sphere.rings = 12
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.5, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.5, 1.0)
	mat.emission_energy_multiplier = 6.0
	var mesh := MeshInstance3D.new()
	mesh.mesh = sphere
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	mesh.global_position = pos
	mesh.scale = Vector3.ZERO
	var peak_scale: Vector3 = Vector3.ONE * radius * 1.4  # mesh radius = radius * 0.7
	var tween := mesh.create_tween()
	tween.tween_property(mesh, "scale", peak_scale, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(mesh, "scale", Vector3.ZERO, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_queue_free_on_tween_callback(tween, mesh)


## Огненные частицы: радиальный разлёт ярко-оранжевых quad-billboards,
## fade в 0.5с. Скорость 4..radius×4 — частицы разлетаются примерно до
## границы AOE за свой lifetime.
static func _explosion_fire(root: Node, pos: Vector3, radius: float) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.45, 0.45)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.albedo_color = Color(1.0, 0.55, 0.15, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.15, 1.0)
	mat.emission_energy_multiplier = 3.5
	quad.material = mat

	var grad_color := Gradient.new()
	grad_color.offsets = PackedFloat32Array([0.0, 0.4, 0.8, 1.0])
	grad_color.colors = PackedColorArray([
		Color(1.0, 0.95, 0.5, 1.0),
		Color(1.0, 0.55, 0.1, 1.0),
		Color(0.5, 0.1, 0.05, 0.6),
		Color(0.1, 0.05, 0.0, 0.0),
	])
	var grad_color_tex := GradientTexture1D.new()
	grad_color_tex.gradient = grad_color

	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 1.0))
	scale_curve.add_point(Vector2(0.6, 0.7))
	scale_curve.add_point(Vector2(1.0, 0.0))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve

	var ppm := ParticleProcessMaterial.new()
	ppm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ppm.emission_sphere_radius = radius * 0.15
	ppm.spread = 180.0
	ppm.initial_velocity_min = 4.0
	ppm.initial_velocity_max = radius * 4.0
	ppm.gravity = Vector3(0.0, -1.0, 0.0)
	ppm.color_ramp = grad_color_tex
	ppm.scale_curve = scale_tex
	ppm.scale_min = 1.0
	ppm.scale_max = 1.6

	var lifetime: float = 0.5
	_spawn_oneshot_particles(root, pos, ppm, quad, 60, lifetime, radius)


## Дымные частицы: серые, медленно поднимаются вверх, лётают дольше огня
## (чтобы дым ещё висел когда пламя потухнет). lifetime 1.2с.
static func _explosion_smoke(root: Node, pos: Vector3, radius: float) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.6, 0.6)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.albedo_color = Color(0.35, 0.32, 0.3, 0.8)
	quad.material = mat

	var grad_color := Gradient.new()
	grad_color.offsets = PackedFloat32Array([0.0, 0.4, 1.0])
	grad_color.colors = PackedColorArray([
		Color(0.4, 0.35, 0.3, 0.85),
		Color(0.5, 0.5, 0.5, 0.55),
		Color(0.6, 0.6, 0.6, 0.0),
	])
	var grad_color_tex := GradientTexture1D.new()
	grad_color_tex.gradient = grad_color

	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.5))
	scale_curve.add_point(Vector2(0.5, 1.2))
	scale_curve.add_point(Vector2(1.0, 1.6))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve

	var ppm := ParticleProcessMaterial.new()
	ppm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ppm.emission_sphere_radius = radius * 0.25
	ppm.direction = Vector3(0.0, 1.0, 0.0)
	ppm.spread = 60.0
	ppm.initial_velocity_min = 1.0
	ppm.initial_velocity_max = 3.0
	ppm.gravity = Vector3(0.0, 1.5, 0.0)  # «дым поднимается»
	ppm.color_ramp = grad_color_tex
	ppm.scale_curve = scale_tex
	ppm.scale_min = 0.8
	ppm.scale_max = 1.4

	var lifetime: float = 1.2
	_spawn_oneshot_particles(root, pos, ppm, quad, 40, lifetime, radius)


## Общий helper: создаёт one_shot GPUParticles3D, спавнит на root, через
## lifetime+0.3 cleanup'ит. Используется и fire, и smoke.
static func _spawn_oneshot_particles(root: Node, pos: Vector3, process_mat: ParticleProcessMaterial, draw_mesh: Mesh, amount: int, lifetime: float, visibility_radius: float) -> void:
	var particles := GPUParticles3D.new()
	particles.process_material = process_mat
	particles.draw_pass_1 = draw_mesh
	particles.amount = amount
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# AABB для культурой видимости — частицы могут улетать за bounds
	# emitter'а, иначе Godot их вкуллит. С запасом radius × 3.
	var ext: float = visibility_radius * 3.0
	particles.visibility_aabb = AABB(Vector3(-ext, -ext, -ext), Vector3(ext * 2.0, ext * 2.0, ext * 2.0))
	root.add_child(particles)
	particles.global_position = pos
	particles.emitting = true
	_schedule_queue_free(root.get_tree(), particles, lifetime + 0.3)


## Плоское кольцо на земле фиксированного `radius`. Используется для:
##   - warning-маркеров (lead time перед падением супер-фаербола);
##   - постоянного индикатора зоны бомбардировки в AIMING_TARGET (duration<=0
##     отключает auto-fade и tween'ы — caller сам владеет жизненным циклом).
## Возвращает MeshInstance3D — caller может двигать его, менять scale, и
## освободить через queue_free.
static func spawn_ground_ring(
	root: Node,
	pos: Vector3,
	radius: float,
	duration: float = 0.6,
	color: Color = Color(1.0, 0.55, 0.15, 0.95),
) -> MeshInstance3D:
	if root == null:
		return null
	var torus := TorusMesh.new()
	torus.outer_radius = radius
	torus.inner_radius = maxf(radius - 0.18, 0.1)
	torus.rings = 48
	torus.ring_segments = 8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 2.0
	var mesh := MeshInstance3D.new()
	mesh.mesh = torus
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	mesh.global_position = pos + Vector3.UP * 0.05  # чуть над землёй — без z-fight'а
	if duration > 0.0:
		# Auto-fade: pulse-in (sharp) → linear out до queue_free.
		var tween := mesh.create_tween()
		# Пульс-открытие: scale 0.85→1.0 за 0.08с
		mesh.scale = Vector3(0.85, 1.0, 0.85)
		tween.tween_property(mesh, "scale", Vector3.ONE, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		# После пульса — линейный fade alpha до конца duration
		tween.tween_property(mat, "albedo_color:a", 0.0, maxf(duration - 0.08, 0.05)).set_trans(Tween.TRANS_LINEAR)
		_queue_free_on_tween_callback(tween, mesh)
	return mesh


## Расширяющееся плоское кольцо ПОСТОЯННОЙ толщины: outer_radius растёт
## линейно от 0 до `max_radius` за `duration`, inner_radius всегда =
## outer − thickness. Без скейла меша — иначе фронт расплывался бы вширь
## пропорционально радиусу.
##
## Используется как «волна вызова» от башни. Юниты реагируют по мере
## прохождения фронта через их позицию (Camp.recall_wave_speed).
static func spawn_expanding_ring(
	root: Node,
	pos: Vector3,
	max_radius: float,
	duration: float,
	color: Color = Color(0.4, 0.85, 1.0, 0.95),
	thickness: float = 0.18,
) -> void:
	if root == null or max_radius <= 0.0 or duration <= 0.0:
		return
	var torus := TorusMesh.new()
	torus.outer_radius = thickness
	torus.inner_radius = 0.001
	torus.rings = 96
	torus.ring_segments = 8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 2.5
	var mesh := MeshInstance3D.new()
	mesh.mesh = torus
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	mesh.global_position = pos + Vector3.UP * 0.05
	# Анимация полей самого торус-меша (а не scale): тогда толщина не растёт
	# вместе с радиусом — ring остаётся «карандашным», как и нужно.
	var tween := mesh.create_tween()
	tween.set_parallel(true)
	tween.tween_method(func(r: float) -> void:
		if not is_instance_valid(torus):
			return
		torus.outer_radius = r + thickness
		torus.inner_radius = maxf(r, 0.001),
		0.001, max_radius, duration,
	).set_trans(Tween.TRANS_LINEAR)
	tween.tween_property(mat, "albedo_color:a", 0.0, duration).set_trans(Tween.TRANS_LINEAR)
	tween.set_parallel(false)
	_queue_free_on_tween_callback(tween, mesh)


## Solid translucent sphere фиксированного радиуса — явный «вижу габариты»
## визуал. Используется поверх distortion-волны (она тоже расширяется до
## radius, но за 0.45с с дисслв-шейдером — границу не видно мгновенно).
## Здесь сразу stand-up на полном размере, alpha plays down.
static func spawn_radius_indicator(root: Node, pos: Vector3, radius: float, color: Color = Color(1.0, 0.5, 0.15, 0.35), duration: float = 0.4) -> void:
	if root == null:
		return
	var sphere := SphereMesh.new()
	sphere.radius = VISUAL_BASE_RADIUS
	sphere.height = VISUAL_BASE_HEIGHT
	sphere.radial_segments = 24
	sphere.rings = 12
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # видим и снаружи, и изнутри
	mat.no_depth_test = false
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 0.6
	var mesh := MeshInstance3D.new()
	mesh.mesh = sphere
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	mesh.global_position = pos
	mesh.scale = Vector3.ONE * (radius / sphere.radius)
	var tween := mesh.create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_queue_free_on_tween_callback(tween, mesh)
