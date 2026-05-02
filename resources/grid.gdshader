shader_type spatial;

uniform vec4 base_color : source_color = vec4(0.3, 0.5, 0.25, 1.0);
uniform vec4 grid_color : source_color = vec4(0.1, 0.2, 0.1, 1.0);
uniform float grid_size = 2.0;
uniform float line_width = 0.04;

// «Травянистый» fbm-noise поверх базового цвета — даёт ощущение лужайки без
// 3D-травы. Дёшево (3 octaves hash-noise в fragment'е, ~30 ops). Сила и
// масштаб тюнятся с инспектора. Отключение: noise_strength=0.
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
	// Травяной слой: fbm по мировым XZ, индексирует градиент dark→light.
	float n = fbm3(world_pos.xz * noise_scale);
	vec3 grass = mix(grass_color_dark.rgb, grass_color_light.rgb, smoothstep(0.2, 0.8, n));
	vec3 ground = mix(base_color.rgb, grass, noise_strength);

	// Поверх — старый grid (тёмные линии 2×2м для визуального масштаба).
	vec2 d = abs(mod(world_pos.xz - grid_size * 0.5, grid_size) - grid_size * 0.5);
	float line = min(d.x, d.y);
	float aa = fwidth(line);
	float t = 1.0 - smoothstep(line_width, line_width + aa, line);
	ALBEDO = mix(ground, grid_color.rgb, t);
}
