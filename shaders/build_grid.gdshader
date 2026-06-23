shader_type spatial;
// Сетка строительства на полу: линии по ГРАНИЦАМ клеток (тайл трубы = одна клетка),
// фаза привязана к якорю (центр коллектора), затухание к краю. Показывается, только
// пока активна нефте-стройка ([HandPlaceAim]). Не пишет глубину — лежит поверх травы.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec2 grid_anchor = vec2(0.0);            // мир XZ центра коллектора
uniform float cell = 2.0;                        // шаг клетки (м)
uniform float line_width = 0.05;                 // полуширина линии (м)
uniform vec4 line_color : source_color = vec4(0.45, 0.85, 1.0, 0.55);
uniform float fade_start = 16.0;                 // м от якоря — начало затухания
uniform float fade_end = 38.0;                   // м — полностью прозрачно

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Линии на границах клеток: центры клеток в anchor + cell*i, границы — на +cell/2.
	vec2 p = world_pos.xz - grid_anchor;
	vec2 g = abs(fract(p / cell + 0.5) - 0.5) * cell;  // расстояние до ближайшей линии по оси
	float d = min(g.x, g.y);
	float line = 1.0 - smoothstep(0.0, line_width, d);
	float dist = length(p);
	float fade = 1.0 - smoothstep(fade_start, fade_end, dist);
	float a = line * line_color.a * fade;
	if (a < 0.003) {
		discard;
	}
	ALBEDO = line_color.rgb;
	EMISSION = line_color.rgb * 0.6;
	ALPHA = a;
}
