shader_type spatial;
render_mode cull_back;
varying float flash;
varying float palette;
varying float brute;

vec3 rotate_x(vec3 p, float a) {
	float s = sin(a); float c = cos(a);
	return vec3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

void vertex() {
	float phase = INSTANCE_CUSTOM.x;
	float speed = INSTANCE_CUSTOM.y;
	float mode = mod(INSTANCE_CUSTOM.z, 16.0);
	float lean = INSTANCE_CUSTOM.w;
	float part = UV2.x;
	vec3 pivot = vec3(0.0);
	float angle = 0.0;
	if (part > 2.5) {
		float side = part < 3.5 ? -1.0 : 1.0;
		pivot = vec3(side * 0.19, 0.89, 0.0);
		angle = sin(phase + (side > 0.0 ? 3.14159 : 0.0)) * min(speed * 0.19, 0.65);
		if (mode > 4.5) angle = sin(phase + side * 1.57) * 0.45;
	} else if (part > 0.5) {
		float side = part < 1.5 ? -1.0 : 1.0;
		pivot = vec3(side * 0.36, 1.45, 0.0);
		angle = -0.35 + sin(phase + (side > 0.0 ? 3.14159 : 0.0)) * 0.18;
		angle = mix(angle, -2.0, clamp(-lean / 0.22, 0.0, 1.0));
		angle = mix(angle, -1.15, clamp((lean - 0.1) / 0.38, 0.0, 1.0));
		if (mode > 4.5) angle = -1.4 + sin(phase + side * 1.57) * 0.25;
	}
	VERTEX = pivot + rotate_x(VERTEX - pivot, angle);
	NORMAL = rotate_x(NORMAL, angle);
	if (part < 2.5) {
		VERTEX = vec3(0.0, 0.95, 0.0) + rotate_x(VERTEX - vec3(0.0, 0.95, 0.0), lean);
		NORMAL = rotate_x(NORMAL, lean);
	}
	VERTEX.y *= 1.0 - 0.16 * clamp(-lean / 0.22, 0.0, 1.0);
	VERTEX.y += abs(sin(phase)) * min(speed * 0.02, 0.05);
	palette = UV2.y;
	flash = step(15.5, mod(INSTANCE_CUSTOM.z, 32.0)) * (1.0 - step(0.5, palette));
	brute = step(31.5, INSTANCE_CUSTOM.z);
}

void fragment() {
	vec3 tint = palette < 0.5 ? vec3(0.88, 0.85, 0.78) : (palette < 1.5 ? vec3(0.14, 0.15, 0.16) : (palette < 2.5 ? vec3(0.40, 0.35, 0.30) : vec3(1.0, 0.35, 0.24)));
	if (palette < 0.5) tint = mix(tint, vec3(0.76, 0.57, 0.32), brute);
	if (palette > 1.5 && palette < 2.5) tint = mix(tint, vec3(0.24, 0.18, 0.15), brute);
	ALBEDO = mix(tint, vec3(1.0, 0.96, 0.78), flash);
	ROUGHNESS = 0.74;
	EMISSION = tint * step(2.5, palette) * 1.8 + vec3(0.5, 0.12, 0.025) * flash;
}
