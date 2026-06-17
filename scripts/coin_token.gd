extends Control
## Нарисованная монета (чистый _draw, без ассетов): тень, тёмный ободок, золотое
## тело, внутренний кант, ромб-эмблема и блик. Используется на столе торга
## (выложенные монеты, clickable=снять) и в кошельке (затравка для перетаскивания).

signal clicked

@export var radius: float = 16.0
## true → монету можно снять кликом (на столе). false → декор/превью (mouse игнор).
@export var clickable: bool = false


func _ready() -> void:
	custom_minimum_size = Vector2(radius * 2.0 + 4.0, radius * 2.0 + 4.0)
	if not clickable:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tooltip_text = "Снять монету"


func _gui_input(event: InputEvent) -> void:
	if not clickable:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit()
		accept_event()


func _draw() -> void:
	var c: Vector2 = size * 0.5
	var r: float = radius
	draw_circle(c + Vector2(0, 2), r, Color(0, 0, 0, 0.30))            # тень
	draw_circle(c, r, Color(0.55, 0.40, 0.10))                         # тёмный ободок
	draw_circle(c, r - 2.5, Color(0.97, 0.80, 0.30))                   # тело — золото
	draw_arc(c, r - 4.5, 0.0, TAU, 32, Color(0.70, 0.52, 0.16), 1.5)   # внутренний кант
	draw_circle(c, r - 7.0, Color(0.90, 0.72, 0.22))                   # внутренний диск
	# ромб-эмблема
	var s: float = r * 0.42
	var diamond := PackedVector2Array([
		c + Vector2(0, -s), c + Vector2(s * 0.62, 0),
		c + Vector2(0, s), c + Vector2(-s * 0.62, 0)])
	draw_colored_polygon(diamond, Color(0.66, 0.48, 0.14))
	# блик
	draw_circle(c - Vector2(r * 0.32, r * 0.36), r * 0.26, Color(1, 0.97, 0.78, 0.55))
