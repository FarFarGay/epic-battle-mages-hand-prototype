shader_type spatial;
render_mode specular_disabled;

uniform vec4 earth_color : source_color = vec4(0.22, 0.26, 0.23, 1.0);
uniform vec4 dust_color : source_color = vec4(0.43, 0.39, 0.30, 1.0);
uniform vec4 routes[16];
uniform int route_count = 0;
uniform float wear = 0.0;
varying vec3 world_position;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_position.xz;
	float broad = noise(p * 0.075);
	float patches = noise(p * 0.31 + broad * 2.4);
	float grain = noise(p * 3.4);
	float path_distance = 1000.0;
	for (int i = 0; i < route_count; i++) {
		vec2 a = routes[i].xy;
		vec2 b = routes[i].zw;
		vec2 segment = b - a;
		float t = clamp(dot(p - a, segment) / max(dot(segment, segment), 0.01), 0.0, 1.0);
		path_distance = min(path_distance, length(p - a - t * segment));
	}
	float trail = 1.0 - smoothstep(2.2, 6.3, path_distance + (patches - 0.5) * 3.0);
	float dust = clamp(broad * 0.32 + patches * 0.20 + trail * 0.43 + wear, 0.0, 0.95);
	vec3 base = mix(earth_color.rgb, dust_color.rgb, dust);
	float ripple = sin(p.x * 2.0 + p.y * 0.6 + noise(p * 0.4) * 5.0);
	ALBEDO = base * (0.96 + grain * 0.055 + ripple * 0.009);
	ROUGHNESS = 0.98;
}
