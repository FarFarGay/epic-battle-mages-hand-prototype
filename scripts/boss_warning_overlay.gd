class_name BossWarningOverlay
extends CanvasLayer
## Полупрозрачный баннер «Гигант приближается» вверху экрана. Подписан на
## [signal EventBus.boss_wave_incoming]: показывается на переданное число
## секунд (= [member WaveDirector.boss_wave_warning_seconds]) перед спавном
## боссовой волны, пульсирует красным, потом автоматически скрывается.
##
## Layer = 105 — над HUD'ом (PerfHud=10), но под WinOverlay (110): если
## игрок выиграет ровно в момент боссовой волны, win-панель перекроет
## баннер. Click-through (mouse_filter = ignore): баннер не блокирует
## ввод, игрок продолжает кастовать заклинания пока читает.
##
## Идемпотентность: повторный сигнал во время активного баннера сбрасывает
## таймер на новое значение и перезапускает анимацию. На практике редко —
## боссовые волны разделены [member WaveDirector.boss_wave_every_n] волнами,
## но защита бесплатная.

const GROUP := &"boss_warning_overlay"

@onready var _root: Control = $Root
@onready var _label: Label = $Root/Banner/Label

## Текущий cd до автоскрытия. Положительный → виден; ≤0 → скрыт.
## Тикается в [_process].
var _visible_cd: float = -1.0
## Tween пульсации alpha. Пересоздаётся при каждом show'е, kill'ится перед
## новым (иначе две пульсации перекладываются и видны рывки).
var _pulse_tween: Tween = null


func _ready() -> void:
	add_to_group(GROUP)
	_root.visible = false
	EventBus.boss_wave_incoming.connect(_on_boss_wave_incoming)


func _on_boss_wave_incoming(seconds_until_spawn: float) -> void:
	_visible_cd = seconds_until_spawn
	_show()


func _show() -> void:
	_root.visible = true
	# Пульсация alpha банера: 1.0 ↔ 0.55 раз в 0.6с. Создаёт ощущение
	# тревоги — статичный баннер игнорируется боковым зрением.
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
	_label.modulate.a = 1.0
	_pulse_tween = create_tween().set_loops()
	_pulse_tween.tween_property(_label, "modulate:a", 0.55, 0.3).set_trans(Tween.TRANS_SINE)
	_pulse_tween.tween_property(_label, "modulate:a", 1.0, 0.3).set_trans(Tween.TRANS_SINE)


func _hide() -> void:
	_root.visible = false
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
		_pulse_tween = null


func _process(delta: float) -> void:
	if _visible_cd < 0.0:
		return
	_visible_cd -= delta
	if _visible_cd <= 0.0:
		_visible_cd = -1.0
		_hide()
