extends CanvasLayer
## Игровой HUD. Слева — индикаторы способностей (1=хлоп, 2=щелк), справа —
## статус лагеря (гномы / лучники / уровень=число палаток + squad XP).
## Под PerfHud, который сидит на (10, 10..70). Сцена самодостаточна,
## ссылка на Camp приходит через @export_node_path.
##
## Обновление по таймеру 0.25с для счётчиков; squad-бар сидит на сигналах
## EventBus.squad_xp_changed / squad_leveled_up — обновляется реактивно
## без таймера, мгновенный feedback на убийство.

const UPDATE_INTERVAL: float = 0.25

@export_node_path("Camp") var camp_path: NodePath

@onready var _gnome_count_label: Label = $RightPanel/Margin/VBox/GnomeRow/CountLabel
@onready var _defender_count_label: Label = $RightPanel/Margin/VBox/DefenderRow/CountLabel
@onready var _tent_count_label: Label = $RightPanel/Margin/VBox/TentRow/CountLabel
@onready var _vbox: VBoxContainer = $RightPanel/Margin/VBox

var _camp: Camp
var _update_timer: float = 0.0
## Squad XP UI — построен программно, чтобы не править gameplay_hud.tscn.
## Структура: Icon (золото) + Label "ур. N" + ProgressBar с XP/threshold.
var _squad_level_label: Label
var _squad_xp_bar: ProgressBar
var _squad_xp_label: Label  # текст поверх бара


func _ready() -> void:
	if not camp_path.is_empty():
		_camp = get_node_or_null(camp_path) as Camp
	_build_squad_row()
	_update_counts()
	# Sync с текущим состоянием Camp (на случай позднего hookup или сцены
	# с уже накопленным XP). Затем подписываемся на инкременты.
	if _camp != null:
		_refresh_squad_bar(_camp.get_squad_xp(), _camp.get_squad_level())
	EventBus.squad_xp_changed.connect(_refresh_squad_bar)
	EventBus.squad_leveled_up.connect(_on_level_up)


## Строит SquadRow программно и докидывает в существующий VBox правой панели.
## Рисуем сами, чтобы не править .tscn-файл — добавляется одной строкой кода.
func _build_squad_row() -> void:
	if _vbox == null:
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_vbox.add_child(row)

	var icon := ColorRect.new()
	icon.custom_minimum_size = Vector2(20, 20)
	icon.color = Color(1.0, 0.85, 0.2, 1.0)  # золото — squad XP
	row.add_child(icon)

	_squad_level_label = Label.new()
	_squad_level_label.text = "ур. 0"
	_squad_level_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_squad_level_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_squad_level_label.add_theme_font_size_override("font_size", 14)
	row.add_child(_squad_level_label)

	# ProgressBar с overlay-Label поверх. min_size фиксирована, чтобы не
	# конфликтовала с overall-шириной правой панели (190px минус Icon+Label).
	_squad_xp_bar = ProgressBar.new()
	_squad_xp_bar.custom_minimum_size = Vector2(80, 18)
	_squad_xp_bar.show_percentage = false
	_squad_xp_bar.min_value = 0.0
	_squad_xp_bar.max_value = 1.0  # перенастроим под кривую при первом update
	_squad_xp_bar.value = 0.0
	row.add_child(_squad_xp_bar)

	# Накладной Label с «X / Y» — текст по центру бара.
	_squad_xp_label = Label.new()
	_squad_xp_label.text = "0/0"
	_squad_xp_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_squad_xp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_squad_xp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_squad_xp_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_squad_xp_label.add_theme_font_size_override("font_size", 11)
	_squad_xp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_squad_xp_bar.add_child(_squad_xp_label)


func _process(delta: float) -> void:
	_update_timer -= delta
	if _update_timer <= 0.0:
		_update_counts()
		_update_timer = UPDATE_INTERVAL


func _update_counts() -> void:
	if _camp == null or not is_instance_valid(_camp):
		_gnome_count_label.text = "—"
		_defender_count_label.text = "—"
		_tent_count_label.text = "—"
		return
	_gnome_count_label.text = "%d" % _camp.gatherer_count()
	_defender_count_label.text = "%d" % _camp.defender_count()
	_tent_count_label.text = "%d" % _camp.tent_count_alive()


## Обновление squad-бара. Вызывается на каждом инкременте XP (через
## EventBus.squad_xp_changed). Реактивный путь — мгновенно, без таймера.
##
## Бар показывает прогресс ВНУТРИ текущего уровня: X = (xp - prev_threshold),
## Y = (next_threshold - prev_threshold). На максимальном уровне (curve
## исчерпана) — бар на 100%, текст «MAX».
func _refresh_squad_bar(xp: int, level: int) -> void:
	if _camp == null or _squad_xp_bar == null:
		return
	_squad_level_label.text = "ур. %d" % level
	var curve: Array = _camp.squad_level_xp_curve
	if level >= curve.size():
		_squad_xp_bar.max_value = 1.0
		_squad_xp_bar.value = 1.0
		_squad_xp_label.text = "MAX"
		return
	var prev_threshold: int = curve[level - 1] if level > 0 else 0
	var next_threshold: int = curve[level]
	var span: int = next_threshold - prev_threshold
	var progress: int = xp - prev_threshold
	_squad_xp_bar.max_value = float(maxi(span, 1))
	_squad_xp_bar.value = float(progress)
	_squad_xp_label.text = "%d/%d" % [progress, span]


## Level-up: моргаем баром белым на ~200мс — мгновенный feedback что цель
## достигнута, до открытия модала. modulate-tween, без зависимостей.
func _on_level_up(_level: int) -> void:
	if _squad_xp_bar == null:
		return
	var tween := create_tween()
	tween.tween_property(_squad_xp_bar, "modulate", Color(1.5, 1.5, 1.5, 1.0), 0.08)
	tween.tween_property(_squad_xp_bar, "modulate", Color.WHITE, 0.2)
