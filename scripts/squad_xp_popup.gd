class_name SquadXpPopup
extends Label3D
## Всплывающий «+N XP» над убитым скелетом. Создаётся `SquadXpFx` на
## EventBus.squad_xp_gained_at; живёт `lifetime` секунд, поднимаясь вверх
## и затухая. Сам себя освобождает в конце.
##
## Label3D: нативный 3D-текст в Godot 4, billboarded к камере. Не плодит
## CanvasLayer'ов и не нуждается в проекции мировых координат на экран.

@export var lifetime: float = 1.0
## Скорость подъёма (м/с). На 1с lifetime поднимется на ~0.8м — достаточно
## чтобы прочесть, не упуская связь с точкой убийства.
@export var rise_speed: float = 0.8
## Стартовый y-offset над переданной позицией (метры). Чтобы текст не
## проседал в труп — поднимаемся над центром скелета.
@export var spawn_height_offset: float = 1.5

var _life: float = 0.0
var _start_modulate: Color


func _ready() -> void:
	# Билборд: текст всегда лицом к камере. fixed_size НЕ включаем — он
	# трактует font_size×pixel_size как доли вьюпорта (font_size=64 при
	# pixel_size=0.012 даёт ~77% высоты экрана, как баг 2026-05-06).
	# Без fixed_size текст масштабируется с дистанцией камеры: близко
	# крупнее, далеко мельче — естественно читается.
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	pixel_size = 0.005  # Godot-дефолт
	# Поверх всех непрозрачных. shaded=false — без освещения, чистый цвет.
	no_depth_test = true
	shaded = false
	font_size = 48
	outline_size = 6
	outline_modulate = Color(0, 0, 0, 1)
	modulate = Color(1.0, 0.85, 0.2, 1.0)  # тёплое золото
	_start_modulate = modulate
	position.y += spawn_height_offset


func _process(delta: float) -> void:
	_life += delta
	if _life >= lifetime:
		queue_free()
		return
	# Подъём + плавный fade. fade — последняя 40% жизни, чтобы первое время
	# текст «удерживался» полной непрозрачностью.
	position.y += rise_speed * delta
	var fade_start: float = lifetime * 0.6
	if _life > fade_start:
		var t: float = (_life - fade_start) / (lifetime - fade_start)
		modulate.a = _start_modulate.a * (1.0 - t)
