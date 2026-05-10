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
## Tower stats UI: HP-бар и Mana-бар, наверху по центру экрана. Реактивные
## обновления через EventBus.tower_health_changed / tower_mana_changed.
var _hp_bar: ProgressBar
var _hp_label: Label
var _mana_bar: ProgressBar
var _mana_label: Label
## Шкала «великой силы» — золотая полоска под маной. Когда full —
## заголовок мигает «ГОТОВО (Space)».
var _super_bar: ProgressBar
var _super_label: Label
## Кнопка журнала + бэйдж невыбранных апгрейдов. Тоже программная — и
## расположение, и счётчик заводить новой ноды в .tscn ради этого нет смысла.
var _journal_button: Button
var _journal_badge: Label
## Лейблы счётчиков ресурсов: ResourceType (int) → Label. Заполняется в
## _build_resources_rows, обновляется реактивно через EventBus.resources_changed.
var _resource_labels: Dictionary = {}
## Индикатор режима сбора (WORK/ALARM) — отдельный Label под кнопкой журнала,
## меняет цвет реактивно на EventBus.collection_mode_changed.
var _mode_label: Label

## Порядок и метаданные отображения ресурсов в правой панели. Пять типов из
## ResourcePile.ResourceType, кроме GENERIC (legacy-ящик, не геймплейный).
const RESOURCE_DISPLAY: Array = [
	{"type": ResourcePile.ResourceType.WOOD, "label": "дерево", "color": Color(0.45, 0.28, 0.15)},
	{"type": ResourcePile.ResourceType.STONE, "label": "камень", "color": Color(0.55, 0.55, 0.55)},
	{"type": ResourcePile.ResourceType.IRON, "label": "железо", "color": Color(0.45, 0.48, 0.55)},
	{"type": ResourcePile.ResourceType.FOOD, "label": "еда", "color": Color(0.85, 0.35, 0.25)},
	{"type": ResourcePile.ResourceType.PAGE, "label": "страницы", "color": Color(0.55, 0.35, 0.85)},
]


func _ready() -> void:
	if not camp_path.is_empty():
		_camp = get_node_or_null(camp_path) as Camp
	_build_tower_stats()
	_build_squad_row()
	_build_resources_rows()
	_build_journal_button()
	_update_counts()
	# Sync с текущим состоянием Camp (на случай позднего hookup или сцены
	# с уже накопленным XP). Затем подписываемся на инкременты.
	if is_instance_valid(_camp):
		_refresh_squad_bar(_camp.get_squad_xp(), _camp.get_squad_level())
		_refresh_journal_badge(_camp.get_pending_upgrade_choices())
		_sync_all_resources()
	EventBus.squad_xp_changed.connect(_refresh_squad_bar)
	EventBus.squad_leveled_up.connect(_on_level_up)
	EventBus.pending_upgrade_choices_changed.connect(_refresh_journal_badge)
	EventBus.resources_changed.connect(_on_resource_changed)
	EventBus.collection_mode_changed.connect(_refresh_mode_label)
	if is_instance_valid(_camp):
		_refresh_mode_label(_camp.get_collection_mode())

	# Tower stats: подписка на сигналы + начальный sync. Tower может ready'ться
	# раньше HUD'а — тогда initial emit из его _ready уйдёт «в пустоту»;
	# берём snapshot напрямую через group lookup.
	EventBus.tower_health_changed.connect(_refresh_tower_health)
	EventBus.tower_mana_changed.connect(_refresh_tower_mana)
	EventBus.super_charge_changed.connect(_refresh_super_charge)
	var tower := get_tree().get_first_node_in_group(Tower.GROUP) as Tower
	if tower != null:
		_refresh_tower_health(tower.hp, tower.max_hp)
		_refresh_tower_mana(tower.mana, tower.max_mana)
	if is_instance_valid(_camp):
		_refresh_super_charge(_camp.get_super_charge(), _camp.get_super_charge_max())


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
	if not is_instance_valid(_camp) or _squad_xp_bar == null:
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


## Кнопка журнала — крепится к нижнему правому углу HUD'а, под RightPanel.
## Бэйдж — Label поверх кнопки, виден только когда pending_upgrade_choices > 0.
## Программно, без правки .tscn.
func _build_journal_button() -> void:
	_journal_button = Button.new()
	_journal_button.text = "📔 журнал [J]"
	_journal_button.custom_minimum_size = Vector2(150, 36)
	_journal_button.add_theme_font_size_override("font_size", 14)
	# Под RightPanel (offset_bottom=240 в .tscn) — оставляю 10px зазор.
	_journal_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_journal_button.offset_left = -160
	_journal_button.offset_top = 250
	_journal_button.offset_right = -10
	_journal_button.offset_bottom = 286
	_journal_button.pressed.connect(_on_journal_button_pressed)
	add_child(_journal_button)

	# Бэйдж: красный кружок с числом в правом верхнем углу кнопки.
	_journal_badge = Label.new()
	_journal_badge.text = "0"
	_journal_badge.custom_minimum_size = Vector2(20, 20)
	_journal_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_journal_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_journal_badge.add_theme_font_size_override("font_size", 12)
	_journal_badge.add_theme_color_override("font_color", Color.WHITE)
	# Бэйдж получает свой StyleBox через PanelContainer-обёртку — но нам
	# хватит цветного фона через ColorRect под Label'ом.
	var bg := ColorRect.new()
	bg.color = Color(0.85, 0.15, 0.15, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_journal_badge.add_child(bg)
	_journal_badge.move_child(bg, 0)  # фон под текст
	_journal_badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_journal_badge.offset_left = -22
	_journal_badge.offset_top = -8
	_journal_badge.offset_right = -2
	_journal_badge.offset_bottom = 12
	_journal_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_journal_badge.visible = false
	_journal_button.add_child(_journal_badge)


func _on_journal_button_pressed() -> void:
	JournalPanel.toggle()


## Индикатор режима сбора. Под кнопкой журнала, программно. Зелёный при WORK,
## красный с маленькой подсказкой клавиши при ALARM. На WORK скрывается —
## стандартный режим, не требует акцента.
func _refresh_mode_label(mode: int) -> void:
	if _mode_label == null:
		_mode_label = Label.new()
		_mode_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_mode_label.offset_left = -160
		_mode_label.offset_top = 296
		_mode_label.offset_right = -10
		_mode_label.offset_bottom = 322
		_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_mode_label.add_theme_font_size_override("font_size", 13)
		add_child(_mode_label)
	# 1 = ALARM, 0 = WORK (Camp.CollectionMode значения).
	if mode == 1:
		_mode_label.text = "⚠ тревога [V→C сброс]"
		_mode_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4, 1.0))
		_mode_label.visible = true
	else:
		_mode_label.visible = false


func _refresh_journal_badge(count: int) -> void:
	if _journal_badge == null:
		return
	if count <= 0:
		_journal_badge.visible = false
	else:
		_journal_badge.text = "%d" % count
		_journal_badge.visible = true


## Строит ряды счётчиков ресурсов (4 типа: дерево/камень/железо/еда). Та же
## раскладка что и для гнома/лучника/палаток: цветной квадрат + название +
## число. Реактивные обновления — через _on_resource_changed; до первой
## доставки все счётчики «0», тогда они слегка приглушены.
func _build_resources_rows() -> void:
	if _vbox == null:
		return
	# Тонкая разделительная полоса перед ресурсами — визуально отделяет
	# «состав отряда» от «склада».
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	_vbox.add_child(sep)

	for entry in RESOURCE_DISPLAY:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_vbox.add_child(row)

		var icon := ColorRect.new()
		icon.custom_minimum_size = Vector2(20, 20)
		icon.color = entry["color"]
		row.add_child(icon)

		var name_label := Label.new()
		name_label.text = entry["label"]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
		name_label.add_theme_font_size_override("font_size", 14)
		row.add_child(name_label)

		var count_label := Label.new()
		count_label.text = "0"
		count_label.custom_minimum_size = Vector2(40, 0)
		count_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1))
		count_label.add_theme_font_size_override("font_size", 14)
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(count_label)

		_resource_labels[int(entry["type"])] = count_label


func _sync_all_resources() -> void:
	if not is_instance_valid(_camp):
		return
	for entry in RESOURCE_DISPLAY:
		var type: int = int(entry["type"])
		_refresh_resource_label(type, _camp.get_resource(type))


func _on_resource_changed(type: int, amount: int) -> void:
	_refresh_resource_label(type, amount)


## Цвет цифры: серый при 0 (склад пуст), белый при >0. Лёгкий feedback что
## хоть что-то накопилось — без отдельного бэйджа/иконки «есть запас».
func _refresh_resource_label(type: int, amount: int) -> void:
	var label: Label = _resource_labels.get(type, null)
	if label == null:
		return
	label.text = "%d" % amount
	if amount > 0:
		label.add_theme_color_override("font_color", Color.WHITE)
	else:
		label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1))


## Tower HP/Mana панель сверху по центру. Две полоски с overlay-Label'ами:
## красный HP сверху, синяя Mana снизу. Обновления через EventBus.
func _build_tower_stats() -> void:
	var panel := VBoxContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	# Centered: anchor_top=0, anchor_left=anchor_right=0.5; offset для ширины.
	var bar_width: int = 240
	panel.offset_left = -bar_width / 2
	panel.offset_top = 10
	panel.offset_right = bar_width / 2
	panel.offset_bottom = 56
	panel.add_theme_constant_override("separation", 4)
	add_child(panel)

	_hp_bar = _make_stat_bar(panel, Color(0.8, 0.15, 0.15, 1.0), bar_width)
	_hp_label = _make_stat_overlay(_hp_bar, "HP")

	_mana_bar = _make_stat_bar(panel, Color(0.2, 0.5, 0.95, 1.0), bar_width)
	_mana_label = _make_stat_overlay(_mana_bar, "MP")

	# Великая сила — золотой бар третьим. Высота меньше — это «накопление»,
	# не run-time ресурс как HP/MP, ему не нужен такой же визуальный вес.
	_super_bar = _make_stat_bar(panel, Color(1.0, 0.78, 0.18, 1.0), bar_width)
	_super_bar.custom_minimum_size = Vector2(bar_width, 12)
	_super_label = _make_stat_overlay(_super_bar, "ВЕЛИКАЯ СИЛА")
	_super_label.add_theme_font_size_override("font_size", 10)


func _make_stat_bar(parent: Control, fill_color: Color, width: int) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(width, 18)
	bar.show_percentage = false
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = 1.0
	# Per-bar StyleBoxFlat для fill — иначе все ProgressBar'ы общие
	# дефолтные стили и не отличаются цветом.
	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	fill.corner_radius_top_left = 2
	fill.corner_radius_top_right = 2
	fill.corner_radius_bottom_left = 2
	fill.corner_radius_bottom_right = 2
	bar.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	bg.corner_radius_top_left = 2
	bg.corner_radius_top_right = 2
	bg.corner_radius_bottom_left = 2
	bg.corner_radius_bottom_right = 2
	bar.add_theme_stylebox_override("background", bg)
	parent.add_child(bar)
	return bar


func _make_stat_overlay(bar: ProgressBar, prefix: String) -> Label:
	var label := Label.new()
	label.text = prefix + " 0/0"
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_font_size_override("font_size", 12)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(label)
	return label


func _refresh_tower_health(current: float, maximum: float) -> void:
	if _hp_bar == null:
		return
	_hp_bar.max_value = maxf(maximum, 1.0)
	_hp_bar.value = clampf(current, 0.0, maximum)
	_hp_label.text = "HP %d/%d" % [int(round(current)), int(round(maximum))]


func _refresh_tower_mana(current: float, maximum: float) -> void:
	if _mana_bar == null:
		return
	_mana_bar.max_value = maxf(maximum, 1.0)
	_mana_bar.value = clampf(current, 0.0, maximum)
	_mana_label.text = "MP %d/%d" % [int(round(current)), int(round(maximum))]


## Шкала великой силы. Когда full — лейбл переключается на «ГОТОВО (Space)»
## и набирает яркость; иначе показывает progress (целые числа, как HP/MP).
func _refresh_super_charge(current: float, maximum: float) -> void:
	if _super_bar == null:
		return
	_super_bar.max_value = maxf(maximum, 1.0)
	_super_bar.value = clampf(current, 0.0, maximum)
	if current >= maximum:
		_super_label.text = "ГОТОВО (Space)"
		_super_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.4, 1.0))
	else:
		_super_label.text = "ВЕЛИКАЯ СИЛА %d/%d" % [int(round(current)), int(round(maximum))]
		_super_label.add_theme_color_override("font_color", Color.WHITE)
