shader_type spatial;

uniform vec4 base_color : source_color = vec4(0.3, 0.5, 0.25, 1.0);
uniform vec4 grid_color : source_color = vec4(0.1, 0.2, 0.1, 1.0);
uniform float grid_size = 2.0;
uniform float line_width = 0.04;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 d = abs(mod(world_pos.xz - grid_size * 0.5, grid_size) - grid_size * 0.5);
	float line = min(d.x, d.y);
	float aa = fwidth(line);
	float t = 1.0 - smoothstep(line_width, line_width + aa, line);
	ALBEDO = mix(base_color.rgb, grid_color.rgb, t);
}
