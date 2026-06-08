shader_type canvas_item;
// Полноэкранный пост-эффект: постеризация в перцептивном пространстве OKLCH.
// Вешается на ColorRect во весь экран (CanvasLayer ниже HUD). Читает экран,
// переводит в OKLab→LCH, квантует светлоту/хрому/тон ступенями и собирает
// обратно — даёт плоские «банды» цвета (стилизованный палитровый вид).
//
// Палитру намеренно не подключаем (без .gdshaderinc): это чистая постеризация
// с миксом strength. Палитровый remap можно добавить вторым шагом.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

// Микс с оригиналом: 0 = выкл (исходник), 1 = полная постеризация.
uniform float strength : hint_range(0.0, 1.0) = 0.85;
// Ступени светлоты (главный вклад в постеризацию).
uniform float steps_l : hint_range(2.0, 32.0) = 7.0;
// Ступени тона (банды по кругу оттенков).
uniform float steps_h : hint_range(3.0, 48.0) = 10.0;
// Ступени хромы (насыщенности). Включается use_c.
uniform float steps_c : hint_range(2.0, 16.0) = 5.0;
uniform bool use_l = true;
uniform bool use_h = true;
uniform bool use_c = false;
// Лёгкий буст хромы перед квантованием — цвета сочнее (1.0 = без буста).
uniform float chroma_boost : hint_range(0.5, 2.0) = 1.12;

// TAU/PI — встроенные константы шейдерного языка Godot (переопределять нельзя).
// Опорный максимум хромы в OKLab для нормализации квантования.
const float C_REF = 0.33;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

vec3 linear_to_srgb(vec3 c) {
	c = clamp(c, vec3(0.0), vec3(1.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

vec3 linear_to_oklab(vec3 c) {
	float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
	float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
	float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
	l = pow(max(l, 0.0), 1.0 / 3.0);
	m = pow(max(m, 0.0), 1.0 / 3.0);
	s = pow(max(s, 0.0), 1.0 / 3.0);
	return vec3(
		0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
}

vec3 oklab_to_linear(vec3 lab) {
	float l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
	float m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
	float s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
	float l = l_ * l_ * l_;
	float m = m_ * m_ * m_;
	float s = s_ * s_ * s_;
	return vec3(
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

float quant(float v, float steps) {
	return floor(v * steps + 0.5) / steps;
}

void fragment() {
	vec3 src = texture(screen_tex, SCREEN_UV).rgb;
	vec3 lin = srgb_to_linear(max(src, vec3(0.0)));
	vec3 lab = linear_to_oklab(lin);

	float L = lab.x;
	float C = length(lab.yz) * chroma_boost;
	float H = atan(lab.z, lab.y);

	if (use_l) {
		L = quant(L, steps_l);
	}
	if (use_c) {
		C = quant(C / C_REF, steps_c) * C_REF;
	}
	if (use_h) {
		float hn = H / TAU + 0.5;        // 0..1
		hn = quant(hn, steps_h);
		H = (hn - 0.5) * TAU;
	}

	vec2 ab = vec2(cos(H), sin(H)) * C;
	vec3 out_lin = oklab_to_linear(vec3(L, ab));
	vec3 out_srgb = linear_to_srgb(out_lin);

	COLOR = vec4(mix(src, out_srgb, strength), 1.0);
}
