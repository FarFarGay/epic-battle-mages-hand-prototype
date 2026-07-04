class_name AoeVisual
extends RefCounted
## Общие визуалы AOE-удара/взрыва. Hub для всех радиус-эффектов руки и
## магии: explosion (полноценный взрыв 3-в-1), ground_ring (плоское кольцо
## на земле), expanding_ring (распахивающееся), dust (пылевой залп),
## pulse_sparks (искры наружу).
##
## Используется HandPhysicalSlam (хлопок по земле), Fireball (взрыв),
## Mine (триггер), HandSquadAim (aim-ring), squad-charge ability и др. —
## единый визуальный язык для «удара/AOE с разлётом всего вокруг».
## Без пула: spawn-частота низкая (cooldown 0.5-3с), overhead per-instance
## ≈0.2мс, неощутимо для прототипа.

const DUST_MATERIAL_PATH := "res://resources/slam_dust_material.tres"
const DUST_PROCESS_PATH := "res://resources/slam_dust_process.tres"

## render_priority плоских наземных маркеров (кольцо зоны каста, диск стройки,
## impact-кольцо). Туман войны — прозрачные плоскости (render_priority 0,
## depth_draw_never) на y=0.05/0.4; без приоритета верхняя плоскость тумана
## сортируется ПОВЕРХ маркера на земле (y≈0.05) и прячет «зону поражения» в
## задымлённых местах, а в раскрытых (alpha→0) она видна — отсюда «где-то есть,
## где-то нет». Приоритет > 0 кладёт маркер поверх дымки везде.
const GROUND_MARKER_PRIORITY := 2

const DUST_AMOUNT := 72
const DUST_LIFETIME := 0.9
const DUST_QUAD_SIZE := 0.22


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


## ФЛЕШ-КАДР: мгновенная полноэкранная вспышка → fade за duration. Язык
## КУЛЬМИНАЦИЙ (смерть гиганта, супер) — не звать на рядовых событиях.
## CanvasLayer с PROCESS_MODE_ALWAYS: вспышка гаснет и под slow-mo битом.
## mouse_filter=IGNORE — оверлей не перехватывает мышь (см. [[reference_godot_hud_blocks_mouselook]]).
static func spawn_screen_flash(tree: SceneTree, color: Color, alpha: float, duration: float = 0.14) -> void:
	if tree == null or tree.current_scene == null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 11  # над gameplay-HUD и Super-QTE (10)
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var rect := ColorRect.new()
	rect.color = Color(color.r, color.g, color.b, clampf(alpha, 0.0, 1.0))
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	tree.current_scene.add_child(layer)
	var tw := rect.create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_property(rect, "color:a", 0.0, duration)
	_queue_free_on_tween_callback(tw, layer)


## ДУЛЬНАЯ ВСПЫШКА: OmniLight-всплеск в точке выстрела, гаснет за duration.
## Продаёт момент вылета снаряда светом по земле/корпусу. Дёшево (без теней).
static func spawn_muzzle_flash(root: Node, pos: Vector3,
		color: Color = Color(1.0, 0.7, 0.35), energy: float = 5.0,
		light_range: float = 7.0, duration: float = 0.15) -> void:
	if root == null:
		return
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = energy
	light.omni_range = light_range
	light.shadow_enabled = false
	root.add_child(light)
	light.global_position = pos
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, duration)
	_queue_free_on_tween_callback(tw, light)


## ВОРОНКА-ДЕКАЛЬ: тёмное пятно выжженной земли на месте взрыва, медленно
## тает за lifetime. «Земля помнит бой» — поле после замеса выглядит как поле
## после замеса. Дёшево: плоский диск, unshaded.
static func spawn_scorch(root: Node, pos: Vector3, radius: float,
		lifetime: float = 30.0, color: Color = Color(0.12, 0.09, 0.06, 0.5)) -> void:
	var disc := spawn_ground_disc(root, pos, radius, color)
	if disc == null:
		return
	# Чуть НИЖЕ штатных наземных маркеров (0.03) — декаль фон, не сигнал.
	disc.global_position = pos + Vector3.UP * 0.02
	var mat := disc.material_override as StandardMaterial3D
	if mat != null:
		mat.render_priority = 1  # над туманом, под кольцами зон
	var tw := disc.create_tween()
	# Первые 70% жизни пятно держится, затем медленно тает.
	tw.tween_interval(lifetime * 0.7)
	tw.tween_property(mat, "albedo_color:a", 0.0, lifetime * 0.3)
	_queue_free_on_tween_callback(tw, disc)


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


## Искры-«разлёт горения» под рассеивание тумана (pulse). Используется
## fireball._explode и mine._explode после `FogOfWar.pulse_reveal`. Идея —
## визуальный сигнал «горение распространяется», как искры от загорающегося
## костра лагеря (см. camp_fire_particles.tscn).
##
## Параметры:
## `target_radius` — куда искры долетят (обычно = радиусу AOE-урона).
## `speed` — скорость частиц м/с. Совпадает с FogOfWar.PULSE_SPREAD_SPEED:
## фронт тумана и фронт искр движутся с одинаковой скоростью. Lifetime
## вычисляется как target_radius / speed — искры умирают ровно когда
## достигают края damage-зоны. С разбросом ±25% — край имеет ragged look.
static func spawn_pulse_sparks(root: Node, pos: Vector3, target_radius: float, speed: float) -> void:
	if root == null or target_radius <= 0.1 or speed <= 0.01:
		return
	var lifetime: float = target_radius / speed
	var quad := QuadMesh.new()
	quad.size = Vector2(0.28, 0.28)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.albedo_color = Color(1.0, 0.7, 0.3, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.6, 0.2, 1.0)
	mat.emission_energy_multiplier = 3.0
	quad.material = mat
	# Цветовой градиент: жёлто-белый → оранжевый → тёмный → прозрачный.
	var grad_color := Gradient.new()
	grad_color.offsets = PackedFloat32Array([0.0, 0.3, 0.8, 1.0])
	grad_color.colors = PackedColorArray([
		Color(1.0, 0.95, 0.55, 1.0),
		Color(1.0, 0.6, 0.15, 1.0),
		Color(0.6, 0.2, 0.05, 0.6),
		Color(0.2, 0.05, 0.0, 0.0),
	])
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = grad_color
	# Scale-curve: чуть растут на старте (warmth), затем гаснут в 0.
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.5))
	scale_curve.add_point(Vector2(0.2, 1.0))
	scale_curve.add_point(Vector2(0.7, 0.7))
	scale_curve.add_point(Vector2(1.0, 0.0))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve
	var ppm := ParticleProcessMaterial.new()
	ppm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ppm.emission_sphere_radius = 0.4
	ppm.spread = 180.0
	# flatness = 0.85 → почти горизонтальный разлёт (Y-компонента мала). Туман
	# на земле, искры должны разлетаться в XZ-плоскости, не подниматься столбом.
	ppm.flatness = 0.85
	# Скорость задаётся caller'ом (общая со скоростью распространения тумана).
	# ±25% — небольшой разброс, край искр не идеальное кольцо.
	ppm.initial_velocity_min = speed * 0.75
	ppm.initial_velocity_max = speed * 1.25
	# Лёгкая «плавучесть» вверх — тепловой подъём. Совпадает с camp_fire_particles.
	ppm.gravity = Vector3(0.0, 1.0, 0.0)
	# Damping мягко тормозит к концу lifetime'а — искра не вылетает за
	# target_radius по инерции.
	ppm.damping_min = 1.0
	ppm.damping_max = 2.0
	ppm.color_ramp = grad_tex
	ppm.scale_curve = scale_tex
	ppm.scale_min = 1.0
	ppm.scale_max = 1.6
	# Кол-во искр пропорционально радиусу: больше зона — больше «пылинок»,
	# плотность остаётся похожей. 8 искр на метр радиуса, мин 16, макс 64.
	# (Damage-радиус обычно мелкий, 1.5..3.5м → ~12..28 искр.)
	var amount: int = clampi(int(target_radius * 8.0), 16, 64)
	_spawn_oneshot_particles(root, pos, ppm, quad, amount, lifetime, target_radius)


## Полноценный взрыв: ядро-вспышка (sphere) + огненные частицы (быстрые,
## ярко-оранжевые, разлетаются радиально) + дымные (медленнее, темнее,
## поднимаются вверх). Всё процедурно, без внешних ассетов. Один вызов
## под полный AOE-эффект — используется Fireball'ом, Mine'ой.
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
	mat.render_priority = GROUND_MARKER_PRIORITY  # поверх тумана войны (см. const)
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


## Плоский СЕКТОР-дуга на земле — НАПРАВЛЕННЫЙ индикатор «откуда придёт угроза»
## (в отличие от кругового [spawn_ground_ring]): полоса кольца r_in..r_out,
## раскрытая на ±half_angle вокруг bearing. Угол как в build_block —
## d(t)=(sin t,0,cos t), t=0 → +Z; bearing=atan2(dir.x,dir.z) направляет дугу
## НА источник. duration<=0 → постоянная (caller владеет: пульсирует через
## material_override, освобождает queue_free). cull_disabled + unshaded →
## winding/нормали неважны. Возвращает MeshInstance3D.
static func spawn_ground_arc(
	root: Node,
	center: Vector3,
	bearing: float,
	half_angle: float,
	r_in: float,
	r_out: float,
	color: Color = Color(0.95, 0.16, 0.12, 0.6),
	duration: float = 0.0,
	segs: int = 24,
) -> MeshInstance3D:
	if root == null or r_out <= r_in or half_angle <= 0.0:
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a0: float = bearing - half_angle
	var a1: float = bearing + half_angle
	var n: int = maxi(2, segs)
	for i in range(n):
		var t0: float = lerpf(a0, a1, float(i) / float(n))
		var t1: float = lerpf(a0, a1, float(i + 1) / float(n))
		var d0 := Vector3(sin(t0), 0.0, cos(t0))
		var d1 := Vector3(sin(t1), 0.0, cos(t1))
		var pi0 := d0 * r_in
		var po0 := d0 * r_out
		var pi1 := d1 * r_in
		var po1 := d1 * r_out
		st.set_normal(Vector3.UP)
		st.add_vertex(pi0)
		st.add_vertex(po0)
		st.add_vertex(po1)
		st.set_normal(Vector3.UP)
		st.add_vertex(pi0)
		st.add_vertex(po1)
		st.add_vertex(pi1)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 2.0
	mat.render_priority = GROUND_MARKER_PRIORITY  # поверх тумана войны
	var mesh := MeshInstance3D.new()
	mesh.mesh = st.commit()
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	mesh.global_position = center + Vector3.UP * 0.06  # чуть над землёй / ground_ring
	if duration > 0.0:
		var tween := mesh.create_tween()
		tween.tween_property(mat, "albedo_color:a", 0.0, duration).set_trans(Tween.TRANS_LINEAR)
		_queue_free_on_tween_callback(tween, mesh)
	return mesh


## Плоский ЗАЛИТЫЙ диск на земле радиуса `radius` — заливка области (в отличие
## от контурного [spawn_ground_ring]). Используется для подсветки зоны
## строительства: игрок видит не только границу-кольцо, но и саму площадь
## «где можно строить». duration<=0 → постоянный, caller владеет жизненным
## циклом (queue_free). Низкая alpha рекомендуется — диск не должен забивать
## сцену. Возвращает MeshInstance3D.
static func spawn_ground_disc(
	root: Node,
	pos: Vector3,
	radius: float,
	color: Color = Color(0.45, 0.75, 1.0, 0.13),
) -> MeshInstance3D:
	if root == null or radius <= 0.0:
		return null
	# Тонкий цилиндр = плоский диск. Только верхняя крышка нужна (вид сверху).
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 0.02
	cyl.radial_segments = 64
	cyl.rings = 0
	cyl.cap_top = true
	cyl.cap_bottom = false
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Над туманом (>0), но на 1 ниже контурного кольца — заливка остаётся под ним.
	mat.render_priority = GROUND_MARKER_PRIORITY - 1
	var mesh := MeshInstance3D.new()
	mesh.mesh = cyl
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	# Чуть над землёй, но НИЖЕ контурного ring'а (0.05) — без z-fight'а.
	mesh.global_position = pos + Vector3.UP * 0.03
	return mesh


## Быстрая ВСПЫШКА-блик на земле: яркий залитый диск, scale-punch → fade.
## «Моргнуло и пропало» — для момента события (установка здания и т.п.).
## Авто-освобождение по завершении tween'а (WeakRef-safe).
static func spawn_flash(
	root: Node,
	pos: Vector3,
	radius: float,
	color: Color = Color(1.0, 0.95, 0.6, 0.9),
	duration: float = 0.28,
) -> void:
	if root == null or radius <= 0.0:
		return
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 0.02
	cyl.radial_segments = 48
	cyl.rings = 0
	cyl.cap_top = true
	cyl.cap_bottom = false
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 4.0
	mat.render_priority = GROUND_MARKER_PRIORITY  # поверх тумана войны
	var mesh := MeshInstance3D.new()
	mesh.mesh = cyl
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	mesh.global_position = pos + Vector3.UP * 0.06
	# Punch: быстро вспыхивает (scale 0.5→1.1 за 0.06с), затем гаснет alpha→0.
	mesh.scale = Vector3(0.5, 1.0, 0.5)
	var tween := mesh.create_tween()
	tween.tween_property(mesh, "scale", Vector3(1.1, 1.0, 1.1), 0.06).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, maxf(duration, 0.08)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_queue_free_on_tween_callback(tween, mesh)


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
	mat.render_priority = GROUND_MARKER_PRIORITY  # поверх тумана войны (см. const)
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


