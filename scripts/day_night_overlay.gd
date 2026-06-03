class_name DayNightOverlay
extends CanvasLayer
## Индикатор day/night-фазы в правом верхнем углу. Показывает текущую фазу
## (День/Ночь) и обратный отсчёт до смены. Пуллит [WaveDirector] раз в кадр
## (дёшево), отдельно подписан на [signal EventBus.day_phase_changed] для
## мгновенной смены цвета/текста на старте новой фазы — без задержки в
## один кадр после переключения.
##
## Layer = 95 — над PerfHud (10), под BossWarningOverlay (105) и WinOverlay
## (110). Click-through (mouse_filter=ignore): не мешает играть.

const GROUP := &"day_night_overlay"

## Цвет text'а во время дня. Тёплый светло-жёлтый, ассоциация с солнцем.
const DAY_COLOR := Color(1.0, 0.9, 0.45, 1.0)
## Цвет text'а во время ночи. Холодный сине-фиолетовый, ассоциация с
## опасностью/луной.
const NIGHT_COLOR := Color(0.62, 0.65, 1.0, 1.0)

@onready var _root: Control = $Root
@onready var _label: Label = $Root/Panel/Label

var _wave_director: WaveDirector = null
var _is_night: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	EventBus.day_phase_changed.connect(_on_day_phase_changed)
	# WaveDirector один на сцену — берём через группу. Может быть null если
	# overlay создан до wave_director'а (порядок _ready); тогда пробуем
	# ещё раз в _process.
	_wave_director = get_tree().get_first_node_in_group(WaveDirector.GROUP) as WaveDirector
	# Скрываем до старта кампании — фаза не имеет смысла в IDLE-меню.
	_root.visible = false
	# Sync: WaveDirector._ready может уже стартовать кампанию (если
	# MatchConfig.match_started=true после reload). В порядке _ready он —
	# раньше нашего, эмит day_phase_changed мы пропустили. Подхватываем
	# текущее состояние вручную.
	if _wave_director != null and _wave_director.is_running():
		_on_day_phase_changed(_wave_director.is_night(), _wave_director.get_day_night_remaining())


func _on_day_phase_changed(is_night_now: bool, _duration: float) -> void:
	_is_night = is_night_now
	_root.visible = true
	_label.add_theme_color_override("font_color", NIGHT_COLOR if is_night_now else DAY_COLOR)


func _process(_delta: float) -> void:
	if not _root.visible:
		return
	if _wave_director == null:
		_wave_director = get_tree().get_first_node_in_group(WaveDirector.GROUP) as WaveDirector
		if _wave_director == null:
			return
	var remaining: float = _wave_director.get_day_night_remaining()
	# Округляем вверх — игроку психологически легче видеть «1с» а не «0с»
	# на последнем тике до смены.
	var seconds: int = int(ceil(remaining))
	var minutes: int = seconds / 60
	var rest: int = seconds % 60
	var phase_name: String = "Ночь" if _is_night else "День"
	_label.text = "%s %d:%02d" % [phase_name, minutes, rest]
