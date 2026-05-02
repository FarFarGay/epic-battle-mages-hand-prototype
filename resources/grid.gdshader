shader_type spatial;
// Имя «grid» оставлено историческим — раньше шейдер рисовал сетку 2×2м
// поверх базового цвета. С этапа 44 grid убран по геймдизайну: на полу
// только травянистый fbm-noise. Если понадобится вернуть линии — см.
// git log: коммит eabb562 (до этого) или e71f14b (с grid + noise).

uniform vec4 base_color : source_color = vec4(0.3, 0.5, 0.25, 1.0);

// Травянистый fbm-noise — два цвета (тёмный/светлый) смешиваются по
// fbm 3-octave hash-noise. Дёшево (~30 ops в fragment'е), один draw call
// на ground BoxMesh 400×400. noise_strength=0 — выключить, fallback на
// чистый base_color.
uniform float noise_strength : hint_range(0.0, 1.0) = 0.35;
uniform float noise_scale : hint_range(0.05, 2.0) = 0.5;
uniform vec4 grass_color_dark : source_color = vec4(0.18, 0.32, 0.12, 1.0);
uniform vec4 grass_color_light : source_color = vec4(0.45, 0.62, 0.28, 1.0);

varying vec3 world_pos;

// Простой 2D hash → value-noise. Дёшевле fbm на FastNoiseLite (тот в шейдере
// дороже из-за bilinear и mipmap), а для статичного пола качество избыточное.
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f); // smoothstep interpolant
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float fbm3(vec2 p) {
	// 3 октавы — компромисс между «равномерное тёмно-зелёное» и «слишком
	// шумное». Больше октав не нужно, fragment-шейдер на полу 400×400
	// рисуется на каждый пиксель.
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * value_noise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float n = fbm3(world_pos.xz * noise_scale);
	vec3 grass = mix(grass_color_dark.rgb, grass_color_light.rgb, smoothstep(0.2, 0.8, n));
	ALBEDO = mix(base_color.rgb, grass, noise_strength);
}
