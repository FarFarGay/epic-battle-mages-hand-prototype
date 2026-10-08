shader_type spatial;
render_mode cull_disabled, specular_disabled;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float wind = sin(TIME * 1.3 + world.x * 0.4 + world.z * 0.2);
	VERTEX.x += wind * VERTEX.y * VERTEX.y * 0.10;
	VERTEX.z += cos(TIME + world.z * 0.3) * VERTEX.y * VERTEX.y * 0.045;
}

void fragment() {
	ALBEDO = vec3(0.20, 0.23, 0.105) * COLOR.rgb;
	ROUGHNESS = 1.0;
}
