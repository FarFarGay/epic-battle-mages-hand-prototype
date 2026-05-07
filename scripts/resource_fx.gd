extends Node
## Autoload-сервис для одноразовых частицных вспышек на сборе ресурса.
##
## Один и тот же эффект используется для двух событий:
##   - гном доставил единицу к anchor'у (Gnome._tick_commuting_to_base)
##   - рука забросила pile целиком в anchor-зону (Camp._consume_piles_in_drop_zone)
## Дизайнер просил единый визуальный язык — оба сборения должны читаться
## игроком одинаково: цвет соответствует типу ресурса, форма — короткий
## всплеск частиц вверх, гасит за ~0.6с.
##
## API: ResourceFx.pulse(position, color) — спавнит GPUParticles3D one-shot
## в указанной точке мира, через lifetime+margin queue_free'ит. Цвет тянем
## извне (caller знает тип через ResourcePile.color_for_type) — здесь нет
## зависимости от ResourcePile.

const PARTICLE_AMOUNT: int = 14
const PARTICLE_LIFETIME: float = 0.6
const CLEANUP_MARGIN_SEC: float = 0.4


## Запускает короткий всплеск частиц цвета `color` в точке `world_position`.
## Y слегка приподнят (+0.4м) — частицы стартуют над землёй, не прячутся в
## траве и не сливаются с ground noise.
func pulse(world_position: Vector3, color: Color) -> void:
	var particles := GPUParticles3D.new()
	particles.amount = PARTICLE_AMOUNT
	particles.lifetime = PARTICLE_LIFETIME
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.process_material = _make_process_material(color)
	particles.draw_pass_1 = _make_particle_mesh(color)
	# Привязываем к current_scene — переживёт queue_free владельца (если
	# Camp/Gnome удалятся в момент эффекта). Аналогично shatter-фрагментам.
	var root: Node = get_tree().current_scene
	if root == null:
		return
	root.add_child(particles)
	particles.global_position = Vector3(world_position.x, world_position.y + 0.4, world_position.z)
	particles.emitting = true
	# Таймер cleanup — particles сами не удаляются после one_shot.
	get_tree().create_timer(PARTICLE_LIFETIME + CLEANUP_MARGIN_SEC).timeout.connect(
		func() -> void:
			if is_instance_valid(particles):
				particles.queue_free()
	)


func _make_process_material(color: Color) -> ParticleProcessMaterial:
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3.UP
	mat.spread = 60.0
	mat.initial_velocity_min = 1.5
	mat.initial_velocity_max = 3.0
	mat.gravity = Vector3(0, -3.5, 0)
	mat.scale_min = 0.12
	mat.scale_max = 0.22
	mat.color = color
	return mat


func _make_particle_mesh(color: Color) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = 0.06
	mesh.height = 0.12
	# Unshaded + emission — частицы видны в любой свет, цвет не теряется в тенях.
	var standard := StandardMaterial3D.new()
	standard.albedo_color = color
	standard.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	standard.emission_enabled = true
	standard.emission = color
	standard.emission_energy_multiplier = 1.5
	mesh.material = standard
	return mesh
