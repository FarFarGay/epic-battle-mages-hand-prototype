shader_type spatial;
// Имя «grid» оставлено историческим — раньше шейдер рисовал сетку 2×2м
// поверх базового цвета. С этапа 44 grid убран по геймдизайну: на полу
// только травянистый noise. Если понадобится вернуть линии — см. git log.
//
// Noise berётся из texture'ы (NoiseTexture2D с FastNoiseLite seamless),
// а не считается процедурно через hash21+fbm — на координатах ±200 (карта
// 400×400) float-precision in-shader hash'а ломалась и шум повторялся
// квадратами ~50м. Texture'а решает это: один раз сгенерировано на CPU
// (Godot bake'ит NoiseTexture2D в _ready), seamless=true делает плитку
// без видимых швов.

uniform vec4 base_color : source_color = vec4(0.3, 0.5, 0.25, 1.0);
uniform sampler2D noise_texture : hint_default_white, repeat_enable, filter_linear;

// Сила и масштаб noise. noise_scale = mostr-частота повторения тайла:
// при scale=0.02 один тайл texture'ы покрывает ~50м, при 0.04 — ~25м.
uniform float noise_strength : hint_range(0.0, 1.0) = 0.35;
uniform float noise_scale : hint_range(0.005, 0.5) = 0.02;
uniform vec4 grass_color_dark : source_color = vec4(0.18, 0.32, 0.12, 1.0);
uniform vec4 grass_color_light : source_color = vec4(0.45, 0.62, 0.28, 1.0);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float n = texture(noise_texture, world_pos.xz * noise_scale).r;
	vec3 grass = mix(grass_color_dark.rgb, grass_color_light.rgb, smoothstep(0.2, 0.8, n));
	ALBEDO = mix(base_color.rgb, grass, noise_strength);
}
