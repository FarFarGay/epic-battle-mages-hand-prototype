shader_type canvas_item;
// Полноэкранный мягкий soft-focus (dreamy blur). Вешается на ColorRect во весь
// экран на CanvasLayer НИЖЕ HUD, но ПОСЛЕ постеризатора — тогда блюр заодно
// смягчает жёсткие банды постера. Orton-эффект: подмешиваем размытую копию к
// резкой картинке (softness). Дёшево: 13 тапов в два кольца.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
// Сила подмеса размытия: 0 = резко, 1 = полностью мягко.
uniform float softness : hint_range(0.0, 1.0) = 0.45;
// Радиус размытия в пикселях экрана.
uniform float blur_size : hint_range(0.0, 8.0) = 2.5;

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE * blur_size;
	vec2 px2 = px * 2.0;
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;

	vec3 sum = c * 4.0;
	// Внутреннее кольцо (4 ребра ×2, 4 диагонали ×1).
	sum += texture(screen_tex, SCREEN_UV + vec2(px.x, 0.0)).rgb * 2.0;
	sum += texture(screen_tex, SCREEN_UV + vec2(-px.x, 0.0)).rgb * 2.0;
	sum += texture(screen_tex, SCREEN_UV + vec2(0.0, px.y)).rgb * 2.0;
	sum += texture(screen_tex, SCREEN_UV + vec2(0.0, -px.y)).rgb * 2.0;
	sum += texture(screen_tex, SCREEN_UV + vec2(px.x, px.y)).rgb;
	sum += texture(screen_tex, SCREEN_UV + vec2(-px.x, px.y)).rgb;
	sum += texture(screen_tex, SCREEN_UV + vec2(px.x, -px.y)).rgb;
	sum += texture(screen_tex, SCREEN_UV + vec2(-px.x, -px.y)).rgb;
	// Внешнее кольцо (мягче спад) — 4 ребра ×1.
	sum += texture(screen_tex, SCREEN_UV + vec2(px2.x, 0.0)).rgb;
	sum += texture(screen_tex, SCREEN_UV + vec2(-px2.x, 0.0)).rgb;
	sum += texture(screen_tex, SCREEN_UV + vec2(0.0, px2.y)).rgb;
	sum += texture(screen_tex, SCREEN_UV + vec2(0.0, -px2.y)).rgb;

	vec3 blurred = sum / 20.0;  // 4 + 8 + 4 + 4
	COLOR = vec4(mix(c, blurred, softness), 1.0);
}
