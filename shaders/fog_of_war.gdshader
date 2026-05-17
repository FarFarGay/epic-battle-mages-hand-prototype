// Туман войны Tier 3 — persistent visibility memory с decay + noise-density.
//
// Архитектура:
//   - CPU поддерживает visibility-текстуру (128×128 L8) в FogOfWar.gd:
//     каждый tick (10Hz) все пиксели затухают (`* decay`), и вокруг каждой
//     дружественной точки рисуется soft-circle (max-blend). Результат:
//     быстро светлеет при входе юнита, медленно темнеет когда юнит ушёл.
//   - Этот шейдер сэмплирует visibility-текстуру + animated noise (2 слоя
//     разной частоты/скорости). Получается «плотный туман» — alpha
//     модулируется noise'ом + boundary дышит (wisps на краю vision'а).
//
// Mapping: world_xz ∈ [−map_half, +map_half] → uv ∈ [0, 1]. map_half должен
// совпадать со половиной размера Ground (=150м для 300×300).

shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

uniform sampler2D vision_texture : filter_linear, repeat_disable;
uniform sampler2D noise_texture : filter_linear, repeat_enable;
uniform vec4 fog_color : source_color = vec4(0.04, 0.04, 0.08, 0.9);
uniform float map_half : hint_range(10.0, 500.0) = 150.0;

// Память — оставляет min-floor visibility в местах где когда-то был.
uniform float persistent_memory : hint_range(0.0, 1.0) = 0.0;

// Noise-параметры: два слоя для parallax (медленный «облачный» + быстрый «вихрь»).
// Tweak в инспекторе если хочется плотнее/жиже/быстрее.
uniform float noise_scale_a : hint_range(0.001, 0.1) = 0.012;  // large clouds
uniform float noise_scale_b : hint_range(0.001, 0.1) = 0.045;  // small wisps
uniform float scroll_speed_a : hint_range(0.0, 0.5) = 0.025;
uniform float scroll_speed_b : hint_range(0.0, 0.5) = 0.08;

// Сила density-модуляции (variation тумана). 0 = плоский, 1 = max-noise.
uniform float density_amount : hint_range(0.0, 1.0) = 0.55;
// Сила boundary-wobble (рваная кромка vision'а). 0 = строгая окружность,
// 0.3 = заметные wisps, выше — раскидывает резко.
uniform float boundary_wobble : hint_range(0.0, 0.5) = 0.18;
// Объёмность: верхняя высота, где туман полностью растворяется. Нижний слой
// (y≈0) держит alpha=fog_color.a, верхний (y=fog_top_height) → 0. Несколько
// плоскостей на разной высоте дают «стек» с параллаксом — туман объёмный.
uniform float fog_top_height : hint_range(1.0, 30.0) = 6.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// World→UV для visibility.
	vec2 uv = vec2(
		(world_pos.x + map_half) / (map_half * 2.0),
		(world_pos.z + map_half) / (map_half * 2.0)
	);
	float visibility = texture(vision_texture, uv).r;
	visibility = max(visibility, persistent_memory * 0.5);

	// Noise + per-layer offset через world_pos.y (плоскости на разной высоте
	// сэмплируют разные углы noise → каждый слой выглядит уникально).
	vec2 height_offset = vec2(world_pos.y * 0.04, world_pos.y * 0.03);
	vec2 nuv_a = world_pos.xz * noise_scale_a + height_offset + vec2(TIME * scroll_speed_a, TIME * scroll_speed_a * 0.4);
	vec2 nuv_b = world_pos.xz * noise_scale_b - height_offset + vec2(-TIME * scroll_speed_b * 0.6, TIME * scroll_speed_b);
	float n_a = texture(noise_texture, nuv_a).r;
	float n_b = texture(noise_texture, nuv_b).r;
	float noise_combined = n_a * 0.7 + n_b * 0.3;

	// Boundary wobble: gate колоколом visibility × (1 - visibility) — wobble
	// максимальный на кромке (v=0.5), ноль внутри (v=1) и снаружи (v=0).
	// Это гарантирует ПОЛНОЕ осветление в зоне видимости и плотный туман
	// снаружи; рваная кромка живёт только на самой границе vision'а.
	float boundary_factor = 4.0 * visibility * (1.0 - visibility);
	float effective_vis = clamp(visibility + (noise_combined - 0.5) * boundary_wobble * boundary_factor, 0.0, 1.0);

	// Density: лёгкая вариация плотности по noise'у — туман не плоский, есть
	// гуще/жиже патчи. density_amount=0 → flat, 1 → max-variation. Применяем
	// только в фоговой зоне; внутри vision'а alpha и так уже 0.
	float density = mix(1.0, noise_combined * 0.6 + 0.4, density_amount);

	// Height fade: верхние слои плавно растворяются. Нижний слой (y=0) — alpha
	// в полную силу, верхний (y≥fog_top_height) — 0. Несколько MeshInstance3D
	// на разных y дают объёмный эффект «толщины» тумана.
	float height_alpha = 1.0 - smoothstep(0.0, fog_top_height, max(world_pos.y, 0.0));

	ALBEDO = fog_color.rgb;
	ALPHA = fog_color.a * (1.0 - effective_vis) * density * height_alpha;
}
