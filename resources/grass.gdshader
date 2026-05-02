shader_type spatial;
// alpha_scissor вместо blend_mix — на 60fps впритык с 2000 скелетов overdraw
// плотной травы съел бы кадр. discard по порогу даёт «зубчатый» силуэт, для
// стилизованной травы это нормально. cull_disabled — quad виден с обеих сторон.
render_mode unshaded, cull_disabled, alpha_to_coverage;

// Цвет травы — линейный градиент от base (низ, тёмный) до tip (верх, светлый).
// blade_lighten поднимает верхушку на солнце, blade_darken прижимает корень.
group_uniforms color;
uniform vec4 base_color : source_color = vec4(0.2, 0.35, 0.12, 1.0);
uniform vec4 tip_color : source_color = vec4(0.5, 0.75, 0.32, 1.0);

// Силуэт травинки: треугольник, узкий сверху, широкий снизу. half_width_top —
// толщина у верхушки (в долях ширины quad), half_width_bottom — у корня.
group_uniforms shape;
uniform float half_width_top : hint_range(0.01, 0.5) = 0.05;
uniform float half_width_bottom : hint_range(0.05, 0.5) = 0.4;
uniform float alpha_threshold : hint_range(0.0, 1.0) = 0.5;

// Ветер: amplitude в метрах, frequency в герцах. Колебание затухает к корню
// через pow(1-uv.y, 2) — корень неподвижен, верхушка качается.
// world_offset_freq — пространственный сдвиг фазы по XZ, чтобы соседние
// травинки не качались синхронно (волна по полю).
group_uniforms wind;
uniform float wind_amplitude : hint_range(0.0, 0.5) = 0.08;
uniform float wind_frequency : hint_range(0.1, 5.0) = 1.2;
uniform float world_offset_freq : hint_range(0.0, 1.0) = 0.15;
uniform vec2 wind_direction = vec2(1.0, 0.3);

varying float v_uv_y;
varying vec2 v_uv;

void vertex() {
	// Биллборд через инверсию view-матрицы: переписываем MODELVIEW так,
	// чтобы quad всегда смотрел на камеру, но позиция MultiMesh-инстанса
	// (translation, в т.ч. random Y-rotation) сохраняется.
	mat4 model = MODEL_MATRIX;
	mat4 view_inv = INV_VIEW_MATRIX;
	// Сохраняем translation и scale, заменяем rotation на inverse view.
	vec3 origin = model[3].xyz;
	float scale_x = length(model[0].xyz);
	float scale_y = length(model[1].xyz);
	mat4 billboard = mat4(
		vec4(view_inv[0].xyz * scale_x, 0.0),
		vec4(view_inv[1].xyz * scale_y, 0.0),
		vec4(view_inv[2].xyz, 0.0),
		vec4(origin, 1.0)
	);
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard;

	// Ветер: смещение X в мировом пространстве, масштабируется к верхушке.
	// UV.y у Godot QuadMesh: 0 — низ (корень), 1 — верх (верхушка).
	// Inverted в нашем mesh'е (см. grass_quad_mesh.tres), потому qua-orientation:
	// если UV.y растёт от корня к верху, fade = uv.y^2 — корень тих, верхушка качается.
	float fade = UV.y * UV.y;
	float phase = TIME * wind_frequency + dot(origin.xz, vec2(world_offset_freq));
	float sway = sin(phase) * wind_amplitude * fade;
	// Сдвигаем VERTEX в локальных координатах billboard (X — горизонтально на экране).
	VERTEX.x += sway * wind_direction.x;
	VERTEX.z += sway * wind_direction.y;

	v_uv = UV;
	v_uv_y = UV.y;
}

void fragment() {
	// Силуэт: расстояние от центральной оси (UV.x=0.5) меньше переменного
	// half_width — линейная интерполяция от bottom (uv.y=0) до top (uv.y=1).
	float half_width = mix(half_width_bottom, half_width_top, v_uv_y);
	float dist_from_center = abs(v_uv.x - 0.5);
	// Внутри силуэта alpha=1, снаружи 0. alpha_to_coverage сгладит края
	// через MSAA-маску — выглядит мягче чем чистый discard.
	float alpha = step(dist_from_center, half_width);
	if (alpha < alpha_threshold) {
		discard;
	}

	// Цвет: градиент base→tip по uv.y.
	ALBEDO = mix(base_color.rgb, tip_color.rgb, v_uv_y);
	ALPHA = alpha;
}
