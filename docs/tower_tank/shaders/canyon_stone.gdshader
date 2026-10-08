shader_type spatial;
render_mode specular_disabled;

uniform vec4 stone_color : source_color = vec4(0.30, 0.32, 0.29, 1.0);
uniform vec4 seam_color : source_color = vec4(0.13, 0.17, 0.17, 1.0);
uniform float mineral = 0.0;
uniform float hit_flash : hint_range(0.0, 1.0) = 0.0;
varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 p = world_position;
	float bend = sin(p.x * 0.7 + p.z * 0.4) * 0.15;
	float band = sin((p.y + bend) * 8.0);
	float fleck = fract(sin(dot(floor(p * 6.0), vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	float vein = smoothstep(0.97, 0.995, sin(p.x * 1.3 + p.y * 3.7 + sin(p.z * 2.0)));
	vec3 base = mix(stone_color.rgb, seam_color.rgb, smoothstep(0.75, 0.96, band) * 0.32);
	base = mix(base, vec3(0.36, 0.23, 0.09), vein * mineral * 0.6);
	ALBEDO = mix(base * (0.97 + fleck * 0.05), vec3(1.0, 0.82, 0.42), hit_flash * 0.8);
	EMISSION = vec3(0.65, 0.30, 0.08) * hit_flash;
	ROUGHNESS = 0.92;
}
