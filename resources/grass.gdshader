shader_type spatial;
// 3D-mesh grass с vertex displacement (godotshaders.com/shader/grass-shader).
// Без transparency — silhouette даёт реальная геометрия (low-poly blade,
// 9 вершин / 7 трисов). Это важно: на 60fps впритык с 2000 скелетов
// fragment-нагрузка от alpha-discard билбордов нас бы добила; vertex
// displacement дешевле и стабильнее.
//
// cull_disabled — травинку видно с обеих сторон (внутренняя нормаль blade
// под углом часто смотрит «не туда»).
render_mode cull_disabled;

// Цветовой градиент base→tip по высоте. color_grad_height — на какой
// доле blade происходит переход (0 = вверху, 1 = внизу, 0.5 = середина).
group_uniforms color;
uniform vec4 base_color : source_color = vec4(0.18, 0.32, 0.12, 1.0);
uniform vec4 tip_color : source_color = vec4(0.5, 0.75, 0.32, 1.0);
uniform float color_grad_height : hint_range(0.0, 1.0) = 0.5;
uniform float grass_roughness : hint_range(0.0, 1.0) = 0.85;

// Ветер: vertex offset по noise-texture. sway — амплитуда смещения,
// sway_pow — степень затухания к корню (1.0 — линейно, 2.0 — квадратично:
// корень почти не двигается, верхушка качается сильно). sway_dir — вектор
// направления ветра в мире.
group_uniforms wind;
uniform sampler2D noise_texture : repeat_enable, filter_linear, hint_default_white;
uniform float sway : hint_range(0.0, 1.0) = 0.15;
uniform float sway_pow : hint_range(0.5, 4.0) = 2.0;
uniform float sway_time_scale : hint_range(0.0, 2.0) = 0.4;
uniform vec2 sway_dir = vec2(1.0, 0.3);
uniform float sway_noise_scale : hint_range(0.001, 0.5) = 0.05;

varying float v_height_norm;

void vertex() {
	// Высота вершины относительно blade (base в OBJ y=0, top y=4 — нормируем).
	// height_norm = 0 у корня, 1 у верхушки. Используется для затухания
	// ветра и для color-градиента.
	v_height_norm = clamp(VERTEX.y * 0.25, 0.0, 1.0); // y ∈ [0..4] → [0..1]

	// Двухкомпонентное движение для видимого ветра:
	// 1. Главная волна — sin(TIME × sway_time_scale + phase). Phase сдвигается
	//    по мировым XZ координатам инстанса → соседние травинки в разных фазах,
	//    бежит волна по полю.
	// 2. Локальная вариация из noise-texture — каждая травинка качается
	//    немного по-своему (разная амплитуда, не perfect-sin).
	vec3 instance_origin = MODEL_MATRIX[3].xyz;
	float global_phase = TIME * sway_time_scale + dot(instance_origin.xz, vec2(0.07, 0.13));
	float wave = sin(global_phase) * 0.5;  // ∈ [-0.5, 0.5]

	vec2 noise_uv = instance_origin.xz * sway_noise_scale + vec2(TIME * sway_time_scale * 0.5);
	float noise_val = texture(noise_texture, noise_uv).r - 0.5;  // ∈ [-0.5, 0.5]

	// Затухание ветра к корню: pow(height_norm, sway_pow). Верхушка качается,
	// корень почти неподвижен.
	float fade = pow(v_height_norm, sway_pow);
	// Смещение в локальных координатах. sway_dir — направление ветра по XZ.
	float bend = (wave + noise_val * 0.6) * sway * fade;
	VERTEX.x += sway_dir.x * bend;
	VERTEX.z += sway_dir.y * bend;
}

void fragment() {
	float t = smoothstep(0.0, color_grad_height, v_height_norm);
	ALBEDO = mix(base_color.rgb, tip_color.rgb, t);
	ROUGHNESS = grass_roughness;
}
