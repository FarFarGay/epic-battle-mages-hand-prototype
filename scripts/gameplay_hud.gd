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
## Период обновления action bar'а — чаще чем общий counter (cooldown'ы
## меняются в течение секунды-двух, надо обновлять плавно).
const ACTION_BAR_UPDATE_INTERVAL: float = 0.1

## Метаданные всех способностей, которые могут стоять в слотах action bar'а.
## Ключ = ability_id (StringName). Каждая запись описывает куда смотреть
## (category + type) для подсветки и cooldown'а, и как заклинание выглядит
## (color, name).
##
## Super не в этой таблице — он не draggable, особняком (см. ACTION_BAR_FIXED_SUPER).
const ABILITY_META: Dictionary = {
	&"slam": {
		"name": "Хлоп", "color": Color(0.85, 0.85, 0.9),
		"category_str": "PHYSICAL", "type": 0,
	},
	&"flick": {
		"name": "Щелб", "color": Color(0.7, 0.8, 0.85),
		"category_str": "PHYSICAL", "type": 1,
	},
	&"fireball": {
		"name": "Огонь", "color": Color(1.0, 0.45, 0.1),
		"category_str": "MAGIC", "type": 0,
	},
	&"firestorm": {
		"name": "Шквал", "color": Color(0.9, 0.3, 0.05),
		"category_str": "MAGIC", "type": 1,
	},
	&"mine_scatter": {
		"name": "Мины", "color": Color(0.8, 0.3, 0.2),
		"category_str": "MAGIC", "type": 2,
	},
}

## Названия equip-actions в InputMap, в порядке слотов 1..5. Используется
## для центрального диспатча в HUD (раньше каждая способность слушала свой
## action; теперь HUD слушает все и резолвит через slot-assignments).
const SLOT_EQUIP_ACTIONS: Array[StringName] = [
	&"equip_slam",          # клавиша 1
	&"equip_flick",         # клавиша 2
	&"equip_fireball",      # клавиша 3
	&"equip_firestorm",     # клавиша 4
	&"equip_mine_scatter",  # клавиша 5
]

## Стартовая раскладка слотов. Игрок может пересобрать через drag-and-drop.
## Сохранение в файл — TODO (пока сбрасывается на дефолт при рестарте).
const ACTION_BAR_DEFAULT_ASSIGNMENT: Array[StringName] = [
	&"slam", &"flick", &"fireball", &"firestorm", &"mine_scatter",
]

## Super — фиксированный 6-й слот, не draggable. Имеет свою клавишу (Space)
## и свою семантику (QTE, charge-bar), бессмысленно ремапить.
const ACTION_BAR_FIXED_SUPER: Dictionary = {
	"key": "␣", "name": "Удар",
	"color": Color(1.0, 0.55, 0.15),
	"category_str": "SUPER", "type": -1,
}

@export_node_path("Camp") var camp_path: NodePath

## Счётчик собирателей переехал в gatherer card (squad_panel, см.
## _build_gatherer_card). RightPanel содержит только лучников/палатки/ресурсы.
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
## Панель squad-карточек справа столбиком. Создаётся на первый squad_created
## (lazy), убирается на squad_disbanded последнего. Каждая карточка — Control
## с иконкой типа, счётчиком живых, кнопками команд («Эскорт», «Идти сюда»,
## «Распустить»). Сама панель — VBoxContainer внутри ScrollContainer'а: 6+
## отрядов перестают вылезать за экран, появляется вертикальный скролл.
var _squad_panel: VBoxContainer
var _squad_scroll: ScrollContainer
## squad_id → Control карточки. Используется для update/remove на squad_changed.
var _squad_cards: Dictionary = {}
## Кэш ссылки на руку — для toggle_aim_for через HandSquadAim. Lookup по группе.
var _hand: Hand
## Action bar в нижней части экрана. Программно собирается в _build_action_bar.
## Структура: HBoxContainer со слотами; per-slot Control'ы хранятся в
## _action_slots для update'а на тике.
var _action_bar: HBoxContainer
## Per-slot Control'ы для обновления. Каждый — Dictionary {panel, stylebox,
## icon, key_label, name_label, slot_idx, draggable}. Индекс 0..4 — обычные
## (draggable), 5 — Super (fixed).
var _action_slots: Array = []
var _action_bar_update_timer: float = 0.0
## Текущая раскладка: индекс слота → ability_id (StringName из ABILITY_META).
## Меняется через drag-and-drop. По дефолту = ACTION_BAR_DEFAULT_ASSIGNMENT.
var _slot_assignments: Array[StringName] = []
## State перетаскивания. null когда не активно; иначе Dictionary с ghost-
## картой, source slot idx, физическими параметрами (pos, velocity).
var _drag_state: Dictionary = {}
## Постоянная карточка отряда защитников (нижний-левый угол). Иконка + счётчик
## живых + уровень отряда. Обновляется на _update_counts (0.25с) и
## EventBus.squad_leveled_up.
var _defender_card_count_label: Label
var _defender_card_disband_btn: Button

## Карточка гномов-собирателей (squad_panel, выше defender card). Показывает
## счётчик живых gatherer'ов + кнопки переключения режима «Работа» (C) /
## «Тревога» (V). Активный режим подсвечивается через font_color.
var _gatherer_card_count_label: Label
var _gatherer_work_btn: Button
var _gatherer_alarm_btn: Button

## Сколько защитников ставить в следующую линию обороны. Игрок настраивает
## через +/− счётчик в defender card. Дефолт — текущее историческое 3.
## Persistent между нажатиями «На защиту» — игрок может разбить отряд по
## линиям выбранного размера.
var _defense_slot_count: int = 3
var _defense_slot_label: Label
var _defense_slot_minus_btn: Button
var _defense_slot_plus_btn: Button

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
	_build_resources_rows()
	_build_journal_button()
	_build_action_bar()
	_build_gatherer_card()
	_build_defender_card()
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
	EventBus.collection_mode_changed.connect(_refresh_gatherer_mode_buttons)
	if is_instance_valid(_camp):
		var current_mode: int = _camp.get_collection_mode()
		_refresh_mode_label(current_mode)
		_refresh_gatherer_mode_buttons(current_mode)

	# Tower stats: подписка на сигналы + начальный sync. Tower может ready'ться
	# раньше HUD'а — тогда initial emit из его _ready уйдёт «в пустоту»;
	# берём snapshot напрямую через group lookup.
	EventBus.tower_health_changed.connect(_refresh_tower_health)
	EventBus.tower_mana_changed.connect(_refresh_tower_mana)
	EventBus.super_charge_changed.connect(_refresh_super_charge)
	EventBus.squad_created.connect(_on_squad_created)
	EventBus.squad_changed.connect(_on_squad_changed)
	EventBus.squad_disbanded.connect(_on_squad_disbanded)
	EventBus.squad_recall_ignored.connect(_on_squad_recall_ignored)
	EventBus.recall_zone_pulsed.connect(_on_recall_zone_pulsed)
	var tower := get_tree().get_first_node_in_group(Tower.GROUP) as Tower
	if tower != null:
		_refresh_tower_health(tower.hp, tower.max_hp)
		_refresh_tower_mana(tower.mana, tower.max_mana)
	if is_instance_valid(_camp):
		_refresh_super_charge(_camp.get_super_charge(), _camp.get_super_charge_max())


## Строит SquadRow программно и докидывает в существующий VBox правой панели.
## Рисуем сами, чтобы не править .tscn-файл — добавляется одной строкой кода.


## Карточка отряда собирателей (gatherer'ов). Живёт в _squad_panel самой
## первой — выше defender card и army squads. Показывает количество и
## две кнопки переключения режима: «Работа» (бинд C) и «Тревога» (бинд V).
## Активная кнопка визуально подсвечена через цвет шрифта.
##
## Без disband-кнопки: собиратели — base population лагеря, их рекрут идёт
## через постройку «новая палатка» (отдельная конверсия), расформирование
## не предусмотрено (некуда — они уже самый низкий «класс»).
func _build_gatherer_card() -> void:
	_ensure_squad_panel()
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Стиль карточки — коричневый border под цвет собирателей.
	var card_box := StyleBoxFlat.new()
	card_box.bg_color = Color(0.08, 0.08, 0.1, 0.78)
	card_box.border_color = Color(0.7, 0.45, 0.25, 0.9)
	card_box.set_border_width_all(2)
	card_box.set_corner_radius_all(4)
	card_box.content_margin_left = 6
	card_box.content_margin_right = 6
	card_box.content_margin_top = 4
	card_box.content_margin_bottom = 4
	card.add_theme_stylebox_override("panel", card_box)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(vbox)

	# Header — цветной квадратик + название с счётчиком.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(header)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(14, 14)
	swatch.color = Color(0.7, 0.45, 0.25, 1.0)
	header.add_child(swatch)
	_gatherer_card_count_label = Label.new()
	_gatherer_card_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gatherer_card_count_label.add_theme_font_size_override("font_size", 13)
	_gatherer_card_count_label.text = "Собиратели — —"
	header.add_child(_gatherer_card_count_label)

	# Ряд кнопок: «Работа [C]» / «Тревога [V]». Активный режим подсвечен.
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	btn_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(btn_row)

	_gatherer_work_btn = Button.new()
	_gatherer_work_btn.text = "Работа [C]"
	_gatherer_work_btn.focus_mode = Control.FOCUS_NONE
	_gatherer_work_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gatherer_work_btn.add_theme_font_size_override("font_size", 11)
	_gatherer_work_btn.pressed.connect(_on_gatherer_work_pressed)
	btn_row.add_child(_gatherer_work_btn)

	_gatherer_alarm_btn = Button.new()
	_gatherer_alarm_btn.text = "Тревога [V]"
	_gatherer_alarm_btn.focus_mode = Control.FOCUS_NONE
	_gatherer_alarm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gatherer_alarm_btn.add_theme_font_size_override("font_size", 11)
	_gatherer_alarm_btn.pressed.connect(_on_gatherer_alarm_pressed)
	btn_row.add_child(_gatherer_alarm_btn)

	_squad_panel.add_child(card)
	# Гарантируем первое место (выше defender card). Defender card строится
	# СРАЗУ после нас (см. _ready), он сделает add_child вторым — порядок ок.
	# move_child(0) на всякий случай: если когда-нибудь порядок _ready'ев
	# изменится, gatherer останется на месте.
	_squad_panel.move_child(card, 0)


## Постоянная карточка отряда защитников. Живёт в _squad_panel (там же где
## карточки копейщиков), всегда первая в списке. По стилю — копия soldier
## squad card'ы (PanelContainer + header swatch + title), без action-buttons:
## защитники не отзываются командами, они живут в палатках.
##
## Обновление текста — _refresh_defender_card на тике 0.25с (_update_counts).
func _build_defender_card() -> void:
	# Гарантируем что _squad_panel создан до добавления нашей карточки.
	_ensure_squad_panel()
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# IGNORE на корпусе карточки — иначе тело PanelContainer ловит hover
	# и Hand считает курсор «над UI» по всей карточке. Кнопки внутри
	# остаются STOP (дефолт) и продолжают принимать клики.
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Лёгкий красный border чтоб визуально отличать от squad-cards копейщиков.
	var card_box := StyleBoxFlat.new()
	card_box.bg_color = Color(0.08, 0.08, 0.1, 0.78)
	card_box.border_color = Color(0.7, 0.2, 0.2, 0.9)
	card_box.set_border_width_all(2)
	card_box.set_corner_radius_all(4)
	card_box.content_margin_left = 6
	card_box.content_margin_right = 6
	card_box.content_margin_top = 4
	card_box.content_margin_bottom = 4
	card.add_theme_stylebox_override("panel", card_box)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(vbox)

	# Header — цветной квадратик (как у squad'ов копейщиков) + название
	# с динамическим счётчиком, апдейтится в _refresh_defender_card.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(header)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(14, 14)
	swatch.color = Color(0.78, 0.2, 0.2, 1.0)  # цвет DefenderGnome
	header.add_child(swatch)
	_defender_card_count_label = Label.new()
	_defender_card_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_defender_card_count_label.add_theme_font_size_override("font_size", 13)
	_defender_card_count_label.text = "Защитники — —"
	header.add_child(_defender_card_count_label)

	# Уровень + XP-бар. Squad XP curve общая для всего отряда защитников
	# (не per-unit) — раньше эта полоска жила в правой панели рядом с
	# ресурсами, перенесена сюда (2026-05-16) ближе к юниту, к которому
	# относится. ProgressBar заполняется внутри текущего уровня
	# (см. _refresh_squad_bar). Overlay-Label поверх показывает «X/Y».
	var xp_row := HBoxContainer.new()
	xp_row.add_theme_constant_override("separation", 6)
	xp_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(xp_row)
	_squad_level_label = Label.new()
	_squad_level_label.text = "ур. 0"
	_squad_level_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9, 1))
	_squad_level_label.add_theme_font_size_override("font_size", 11)
	_squad_level_label.custom_minimum_size = Vector2(36, 0)
	xp_row.add_child(_squad_level_label)
	_squad_xp_bar = ProgressBar.new()
	_squad_xp_bar.custom_minimum_size = Vector2(0, 14)
	_squad_xp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_squad_xp_bar.show_percentage = false
	_squad_xp_bar.min_value = 0.0
	_squad_xp_bar.max_value = 1.0  # перенастроим под кривую при первом update
	_squad_xp_bar.value = 0.0
	xp_row.add_child(_squad_xp_bar)
	# Накладной Label с «X/Y» поверх bar'а.
	_squad_xp_label = Label.new()
	_squad_xp_label.text = "0/0"
	_squad_xp_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_squad_xp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_squad_xp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_squad_xp_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_squad_xp_label.add_theme_font_size_override("font_size", 10)
	_squad_xp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_squad_xp_bar.add_child(_squad_xp_label)

	# Счётчик «Слотов: N» с +/− кнопками. Управляет _defense_slot_count —
	# сколько защитников игрок хочет в следующей линии. Clamp 1..defender_count.
	# Persistent между «На защиту» нажатиями.
	var slot_row := HBoxContainer.new()
	slot_row.add_theme_constant_override("separation", 4)
	slot_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(slot_row)
	_defense_slot_minus_btn = Button.new()
	_defense_slot_minus_btn.text = "−"
	_defense_slot_minus_btn.focus_mode = Control.FOCUS_NONE
	_defense_slot_minus_btn.custom_minimum_size = Vector2(28, 22)
	_defense_slot_minus_btn.add_theme_font_size_override("font_size", 13)
	_defense_slot_minus_btn.pressed.connect(_on_defense_slot_minus_pressed)
	slot_row.add_child(_defense_slot_minus_btn)
	_defense_slot_label = Label.new()
	_defense_slot_label.text = "Слотов: 3"
	_defense_slot_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_defense_slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_defense_slot_label.add_theme_font_size_override("font_size", 12)
	slot_row.add_child(_defense_slot_label)
	_defense_slot_plus_btn = Button.new()
	_defense_slot_plus_btn.text = "+"
	_defense_slot_plus_btn.focus_mode = Control.FOCUS_NONE
	_defense_slot_plus_btn.custom_minimum_size = Vector2(28, 22)
	_defense_slot_plus_btn.add_theme_font_size_override("font_size", 13)
	_defense_slot_plus_btn.pressed.connect(_on_defense_slot_plus_pressed)
	slot_row.add_child(_defense_slot_plus_btn)

	# Кнопки команд:
	# «На защиту» → стартует BuildAim для DefenseMarker (drag-direction), игрок
	#   ставит линию обороны → _defense_slot_count ближайших СВОБОДНЫХ защитников
	#   идут в формацию. Повторный клик создаёт второй маркер (следующие N).
	# «Патруль» → отзывает всех с маркеров (destroy всех DefenseMarker'ов),
	#   защитники возвращаются к свободному патрулю.
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	btn_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(btn_row)

	var btn_defend := Button.new()
	btn_defend.text = "На защиту"
	btn_defend.focus_mode = Control.FOCUS_NONE
	btn_defend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_defend.add_theme_font_size_override("font_size", 11)
	btn_defend.pressed.connect(_on_defender_defend_pressed)
	btn_row.add_child(btn_defend)

	var btn_patrol := Button.new()
	btn_patrol.text = "Патруль"
	btn_patrol.focus_mode = Control.FOCUS_NONE
	btn_patrol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_patrol.add_theme_font_size_override("font_size", 11)
	btn_patrol.pressed.connect(_on_defender_patrol_pressed)
	btn_row.add_child(btn_patrol)

	# Второй ряд кнопок: «Расформировать» — отзывает 3 защитников обратно в
	# собирателей с компенсацией 50% ресурсов рекрута. Симметрично «Распустить»
	# на squad-карточках копейщиков.
	var btn_row2 := HBoxContainer.new()
	btn_row2.add_theme_constant_override("separation", 4)
	btn_row2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(btn_row2)

	_defender_card_disband_btn = Button.new()
	_defender_card_disband_btn.text = "Расформировать (×3)"
	_defender_card_disband_btn.focus_mode = Control.FOCUS_NONE
	_defender_card_disband_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_defender_card_disband_btn.add_theme_font_size_override("font_size", 11)
	_defender_card_disband_btn.tooltip_text = "Возвращает до 3 защитников в собирателей. Возврат: 50% ресурсов рекрута."
	_defender_card_disband_btn.pressed.connect(_on_defender_disband_pressed)
	btn_row2.add_child(_defender_card_disband_btn)

	# Вставляем после gatherer card. Defender строится сразу после gatherer'а
	# (см. _ready), index получится 1. Соответственно move_child(1) фиксирует
	# позицию, даже если порядок _ready'ев когда-то изменится.
	_squad_panel.add_child(card)
	_squad_panel.move_child(card, 1)


## «На защиту» — тактическая команда (не постройка). Стартует direction-aim
## для линии обороны: ЛКМ-drag задаёт origin + направление, на release
## защитники идут на формацию через Camp.place_defense_formation. Бесплатно.
## Размер линии — _defense_slot_count (1..N, выставляется счётчиком ±).
func _on_defender_defend_pressed() -> void:
	var hand := _resolve_hand()
	if hand == null or hand.build_aim == null:
		push_warning("[HUD:Defender] hand/build_aim не резолвится")
		return
	hand.build_aim.start_defense_formation_aim(_defense_slot_count)


## ± счётчика «Слотов»: меняют _defense_slot_count и обновляют label.
## Бапы вверх/вниз с clamp 1..max(defender_count, 1). Если защитников 0 —
## значение остаётся как было (всё равно «На защиту» disabled будет).
func _on_defense_slot_minus_pressed() -> void:
	_defense_slot_count = maxi(1, _defense_slot_count - 1)
	_refresh_defense_slot_label()


func _on_defense_slot_plus_pressed() -> void:
	var max_slots: int = _defense_slot_max()
	_defense_slot_count = mini(max_slots, _defense_slot_count + 1)
	_refresh_defense_slot_label()


## Максимально допустимое значение счётчика = defender_count лагеря
## (но не меньше 1, чтобы при 0 защитников счётчик не показывал «Слотов: 0»).
func _defense_slot_max() -> int:
	if _camp == null or not is_instance_valid(_camp):
		return 1
	return maxi(1, _camp.defender_count())


## Обновляет label + clamp _defense_slot_count к актуальному max. Зовётся
## из _refresh_defender_card (на смену defender_count) и из ± нажатий.
func _refresh_defense_slot_label() -> void:
	if _defense_slot_label == null:
		return
	var max_slots: int = _defense_slot_max()
	_defense_slot_count = clampi(_defense_slot_count, 1, max_slots)
	_defense_slot_label.text = "Слотов: %d / %d" % [_defense_slot_count, max_slots]
	if _defense_slot_minus_btn != null:
		_defense_slot_minus_btn.disabled = _defense_slot_count <= 1
	if _defense_slot_plus_btn != null:
		_defense_slot_plus_btn.disabled = _defense_slot_count >= max_slots


## «Патруль» — отзывает всех защитников с маркеров (Camp.disband_all_defense_markers).
## Маркеры уничтожаются, ассигнованные защитники освобождаются и возвращаются
## к свободному патрулю (с дебафом — стимул выстраивать заново когда нужно).
func _on_defender_patrol_pressed() -> void:
	if _camp == null or not is_instance_valid(_camp):
		return
	_camp.disband_all_defense_markers()


## «Расформировать» — отзывает 3 ближайших к лагерю защитников (приоритет:
## не в формации) обратно в собирателей. Возвращает 50% ресурсов рекрута
## пропорционально числу расформированных (за 3 защитников из cost {6,4} —
## 3 wood + 2 iron). Гейтится `can_disband_defenders()`: лагерь развёрнут
## И defender_count > 0.
func _on_defender_disband_pressed() -> void:
	if _camp == null or not is_instance_valid(_camp):
		return
	_camp.disband_defender_squad()


## Кнопки переключения режима собирателей. Camp.set_collection_mode эмитит
## EventBus.collection_mode_changed → _on_collection_mode_changed обновит
## визуал кнопок.
func _on_gatherer_work_pressed() -> void:
	if is_instance_valid(_camp):
		_camp.set_collection_mode(Camp.CollectionMode.WORK)


func _on_gatherer_alarm_pressed() -> void:
	if is_instance_valid(_camp):
		_camp.set_collection_mode(Camp.CollectionMode.ALARM)


## Обновляет счётчик собирателей + подсветку активной кнопки. Дёргается
## из _update_counts (0.25с) для счётчика и из _on_collection_mode_changed
## для кнопок.
func _refresh_gatherer_card() -> void:
	if _gatherer_card_count_label == null:
		return
	if _camp == null or not is_instance_valid(_camp):
		_gatherer_card_count_label.text = "Собиратели — —"
		return
	_gatherer_card_count_label.text = "Собиратели — %d" % _camp.gatherer_count()


## Меняет цвет шрифта на кнопках, чтобы было видно активный режим:
## активная — белая, неактивная — приглушённая. Цвет border'а тоже можно
## было бы менять, но через theme override font_color проще и работает
## кроссплатформенно.
func _refresh_gatherer_mode_buttons(mode: int) -> void:
	if _gatherer_work_btn == null or _gatherer_alarm_btn == null:
		return
	var active: Color = Color(1, 1, 0.7, 1)         # жёлтый — активный режим
	var inactive: Color = Color(0.6, 0.6, 0.65, 1)  # серый — неактивный
	if mode == Camp.CollectionMode.WORK:
		_gatherer_work_btn.add_theme_color_override("font_color", active)
		_gatherer_alarm_btn.add_theme_color_override("font_color", inactive)
	else:
		_gatherer_work_btn.add_theme_color_override("font_color", inactive)
		_gatherer_alarm_btn.add_theme_color_override("font_color", active)


## Обновляет текст карточки защитников + disabled-флаг «Расформировать»-кнопки.
## Дёргается из _update_counts (0.25с).
##
## Лейбл показывает «N (в строю: M)» чтобы игрок понимал, сколько защитников
## свободно под следующий маркер обороны (каждое «На защиту» забирает 3).
func _refresh_defender_card() -> void:
	if _defender_card_count_label == null:
		return
	if _camp == null or not is_instance_valid(_camp):
		_defender_card_count_label.text = "Защитники — —"
		if _defender_card_disband_btn != null:
			_defender_card_disband_btn.disabled = true
		return
	var total: int = _camp.defender_count()
	var in_formation: int = _camp.defenders_in_formation_count()
	_defender_card_count_label.text = "Защитники — %d (в строю: %d)" % [total, in_formation]
	# «ур. K» пишется через _refresh_squad_bar (см. squad_xp_changed signal),
	# не здесь — общий источник истины для уровня + xp-бара.
	if _defender_card_disband_btn != null:
		_defender_card_disband_btn.disabled = not _camp.can_disband_defenders()
	_refresh_defense_slot_label()


## Action bar по дну экрана. Diablo-style: горизонтальный ряд слотов,
## слоты 1..5 — draggable (можно переназначить через ЛКМ-drag), слот 6 (Super) —
## фиксированный.
##
## Структура: CenterContainer (anchor BOTTOM, center horizontally) →
## PanelContainer (фон бара) → HBoxContainer (ряд слотов). Каждый слот —
## PanelContainer (для StyleBox-рамки) с VBox: ColorRect-иконка + key/name.
##
## Update'ы — `_update_action_bar` каждые ACTION_BAR_UPDATE_INTERVAL (0.1с):
## active highlight (золотая рамка вокруг текущей equipped способности),
## cooldown-dim (~0.35× если can_trigger=false).
func _build_action_bar() -> void:
	_slot_assignments = ACTION_BAR_DEFAULT_ASSIGNMENT.duplicate()

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	center.offset_bottom = -16  # отступ от низа экрана
	center.offset_top = -84     # высота bar'а ≈ 68px + запас
	# IGNORE — этот wrapper тянется на всю ширину экрана. С PASS он бы попадал
	# в gui_get_hovered_control() и Hand.is_pointer_over_ui() блокировал бы
	# каст заклинаний над всей нижней полосой экрана.
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var bar_panel := PanelContainer.new()
	var bar_stylebox := StyleBoxFlat.new()
	bar_stylebox.bg_color = Color(0.08, 0.08, 0.1, 0.75)
	bar_stylebox.border_color = Color(0.25, 0.25, 0.3, 0.9)
	bar_stylebox.set_border_width_all(1)
	bar_stylebox.set_corner_radius_all(4)
	bar_stylebox.content_margin_left = 6
	bar_stylebox.content_margin_right = 6
	bar_stylebox.content_margin_top = 4
	bar_stylebox.content_margin_bottom = 4
	bar_panel.add_theme_stylebox_override("panel", bar_stylebox)
	# IGNORE — bar_panel шире слотов из-за padding'а. Промежутки (margins
	# и separation между слотами) не должны блокировать каст.
	bar_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(bar_panel)

	_action_bar = HBoxContainer.new()
	_action_bar.add_theme_constant_override("separation", 6)
	_action_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_panel.add_child(_action_bar)

	_action_slots.clear()
	# Draggable слоты 0..4 — ability_id из _slot_assignments.
	for i in range(_slot_assignments.size()):
		_action_slots.append(_build_action_slot(i, true))
	# Фиксированный Super-слот (индекс 5).
	_action_slots.append(_build_action_slot(_slot_assignments.size(), false))


## Один слот action bar'а. slot_idx — место в _action_slots; draggable=true
## для 0..4 (используют _slot_assignments[idx] как ability_id), false для
## Super (использует ACTION_BAR_FIXED_SUPER).
func _build_action_slot(slot_idx: int, draggable: bool) -> Dictionary:
	var slot_panel := PanelContainer.new()
	var slot_stylebox := StyleBoxFlat.new()
	slot_stylebox.bg_color = Color(0.12, 0.12, 0.15, 0.95)
	slot_stylebox.border_color = Color(0.3, 0.3, 0.35, 1)
	slot_stylebox.set_border_width_all(2)
	slot_stylebox.set_corner_radius_all(3)
	slot_panel.add_theme_stylebox_override("panel", slot_stylebox)
	# Slot panel ловит mouse-input (PASS) — нужно чтобы _on_slot_input
	# срабатывал на ЛКМ-зажиме. Bar и center — PASS (пропускают сквозь
	# к слотам и дальше, чтоб ПКМ в мир работала).
	slot_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_action_bar.add_child(slot_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot_panel.add_child(vbox)

	var icon := ColorRect.new()
	icon.custom_minimum_size = Vector2(48, 48)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(icon)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 4)
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(bottom)

	var key_label := Label.new()
	key_label.add_theme_color_override("font_color", Color(1, 1, 0.8, 1))
	key_label.add_theme_font_size_override("font_size", 12)
	bottom.add_child(key_label)

	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	name_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9, 1))
	name_label.add_theme_font_size_override("font_size", 10)
	bottom.add_child(name_label)

	# Draggable-слот ловит ЛКМ-зажим для начала drag'а. Super не draggable
	# (нет смысла ремапить — у него своя клавиша Space).
	if draggable:
		slot_panel.gui_input.connect(_on_slot_gui_input.bind(slot_idx))

	var slot: Dictionary = {
		"slot_idx": slot_idx,
		"draggable": draggable,
		"panel": slot_panel,
		"stylebox": slot_stylebox,
		"icon": icon,
		"key_label": key_label,
		"name_label": name_label,
		# rest_x — layout-позиция от HBoxContainer, кешируется после первого
		# sort'а (см. _cache_slot_rest_positions). Хочется анимировать сдвиг
		# вокруг неё: panel.position.x = rest_x + shift. Иначе HBox каждый
		# sort обнулял бы наше смещение.
		"rest_x": 0.0,
		"rest_cached": false,
	}
	# Первичное заполнение иконки/текстов.
	_refresh_slot_visuals(slot)
	return slot


## Обновляет иконку/текст слота из _slot_assignments (или ACTION_BAR_FIXED_SUPER
## для Super). Зовётся при build'е и после swap'а через drag-and-drop.
func _refresh_slot_visuals(slot: Dictionary) -> void:
	var slot_idx: int = slot.slot_idx
	var meta: Dictionary
	var key_text: String
	if slot.draggable:
		var ability_id: StringName = _slot_assignments[slot_idx]
		meta = ABILITY_META.get(ability_id, {})
		key_text = "%d" % (slot_idx + 1)
	else:
		meta = ACTION_BAR_FIXED_SUPER
		key_text = ACTION_BAR_FIXED_SUPER.key
	(slot.icon as ColorRect).color = meta.get("color", Color.WHITE)
	(slot.key_label as Label).text = key_text
	(slot.name_label as Label).text = meta.get("name", "—")


## Tick-обновление: highlight активного + cooldown-dim. Дёргается каждые
## ACTION_BAR_UPDATE_INTERVAL.
func _update_action_bar() -> void:
	var hand := _resolve_hand()
	for slot in _action_slots:
		var meta: Dictionary = _slot_meta(slot)
		var is_active: bool = _meta_is_active(hand, meta)
		var is_ready: bool = _meta_is_ready(hand, meta)

		var stylebox: StyleBoxFlat = slot.stylebox
		if is_active:
			stylebox.border_color = Color(1.0, 0.85, 0.2, 1.0)
			stylebox.set_border_width_all(3)
		else:
			stylebox.border_color = Color(0.3, 0.3, 0.35, 1)
			stylebox.set_border_width_all(2)

		var icon: ColorRect = slot.icon
		var base_color: Color = meta.get("color", Color.WHITE)
		if is_ready:
			icon.color = base_color
		else:
			icon.color = Color(base_color.r * 0.35, base_color.g * 0.35, base_color.b * 0.35, 1.0)


## Центральный input-handler: ловит equip-клавиши (1..5) и дёргает Hand
## соответственно slot-маппингу. Раньше каждая способность слушала свой
## action; теперь HUD — single dispatcher, что позволяет drag-and-drop
## переназначение.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		for i in range(SLOT_EQUIP_ACTIONS.size()):
			if Input.is_action_just_pressed(SLOT_EQUIP_ACTIONS[i]):
				_equip_slot(i)
				return
	# ЛКМ-отпускание во время drag'а — финализируем. Ловим именно
	# в _unhandled_input, не в _on_slot_gui_input, чтобы поймать отпускание
	# даже если курсор уехал за пределы слотов.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and not _drag_state.is_empty():
			_finish_drag()
			get_viewport().set_input_as_handled()


## Дёргает Hand в зависимости от того, какая способность сейчас в slot_idx.
## Эквивалент того что раньше делали ACTION_EQUIP_* в HandPhysical/HandSpell.
func _equip_slot(slot_idx: int) -> void:
	if slot_idx < 0 or slot_idx >= _slot_assignments.size():
		return
	var ability_id: StringName = _slot_assignments[slot_idx]
	var meta: Dictionary = ABILITY_META.get(ability_id, {})
	if meta.is_empty():
		return
	var hand := _resolve_hand()
	if hand == null:
		return
	match meta.category_str:
		"PHYSICAL":
			if hand.physical_actions != null:
				hand.physical_actions.equipped = meta.type
				hand.set_active_category(Hand.Category.PHYSICAL)
		"MAGIC":
			if hand.spell_actions != null:
				hand.spell_actions.equipped = meta.type
				hand.set_active_category(Hand.Category.MAGIC)


## --- Drag-and-drop переназначение слотов ---
##
## ЛКМ-зажим на draggable-слот → спавн ghost-карты в CanvasLayer'е, ghost
## следует за курсором по spring-damper физике (выглядит как «карта плавает
## за рукой», не приклеена). Отпустил над другим слотом → swap _slot_assignments,
## refresh визуала. Отпустил вне — restore исходного слота.
##
## Slot panel ловит ЛКМ через gui_input (mouse_filter=PASS).
## set_input_as_handled() блокирует прохождение клика в мир (иначе ЛКМ
## на слоте параллельно бы пытался grab'нуть предмет под HUD'ом).

## Жёсткая пружина — карта почти не отрывается от курсора, только лёгкий
## tilt на резком махе. Критическое демпфирование при k=350 ≈ 2·sqrt(350) ≈ 37.4;
## ставим 40 (слегка переcдемпфированная — без bounce'а на резких сменах
## направления). Если хочется больше «гулянья» — снизить stiffness до ~100-150.
const DRAG_SPRING_STIFFNESS: float = 350.0
const DRAG_SPRING_DAMPING: float = 40.0
## Множитель тильта (rad на 1 px/с горизонтальной velocity). При жёсткой
## пружине velocity мгновенно становится большой при махе — нужен меньший
## множитель чтоб карта не выходила в сальто.
const DRAG_TILT_PER_VELOCITY: float = 0.0006
const DRAG_TILT_MAX: float = 0.25

## Боковой сдвиг target-слота (px) при hover'е во время drag'а. Target
## «отъезжает» в сторону противоположную source'у — освобождая место
## для drag-карты. Target слева от source → сдвиг влево (−X), target
## справа → сдвиг вправо (+X). Игрок видит куда уйдёт displaced.
const DRAG_HOVER_SHIFT: float = 20.0
## Скорость анимации сдвига (1/сек). exp-decay для frame-rate independence.
const DRAG_HOVER_SHIFT_DECAY: float = 18.0


func _on_slot_gui_input(event: InputEvent, slot_idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if _drag_state.is_empty():
				_start_drag(slot_idx)
				# Блокируем прохождение клика в мир — иначе Hand попытается
				# grab'нуть предмет под action-bar'ом.
				get_viewport().set_input_as_handled()


## Спавнит ghost-карту над курсором, прячет иконку источника. Карта далее
## двигается через _process_drag_physics.
func _start_drag(slot_idx: int) -> void:
	if slot_idx < 0 or slot_idx >= _slot_assignments.size():
		return
	var ability_id: StringName = _slot_assignments[slot_idx]
	var meta: Dictionary = ABILITY_META.get(ability_id, {})
	if meta.is_empty():
		return

	# Ghost-карта: маленький Panel с иконкой и обводкой. Размер близок к слоту
	# (~56×64), точно угадывать не надо — пользователь смотрит на цвет/имя.
	var ghost := PanelContainer.new()
	var ghost_box := StyleBoxFlat.new()
	ghost_box.bg_color = Color(0.15, 0.15, 0.2, 0.95)
	ghost_box.border_color = Color(1.0, 0.85, 0.2, 1.0)
	ghost_box.set_border_width_all(2)
	ghost_box.set_corner_radius_all(4)
	ghost.add_theme_stylebox_override("panel", ghost_box)
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# pivot в центре для tilt-rotation'а.
	ghost.custom_minimum_size = Vector2(56, 64)
	add_child(ghost)
	ghost.pivot_offset = ghost.size / 2.0

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.add_child(vbox)

	var icon := ColorRect.new()
	icon.color = meta.color
	icon.custom_minimum_size = Vector2(48, 48)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(icon)

	var name_label := Label.new()
	name_label.text = meta.name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0, 1))
	name_label.add_theme_font_size_override("font_size", 10)
	vbox.add_child(name_label)

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var initial_pos: Vector2 = mouse_pos - ghost.custom_minimum_size / 2.0
	ghost.position = initial_pos

	_drag_state = {
		"source_idx": slot_idx,
		"ghost": ghost,
		"pos": initial_pos,
		"velocity": Vector2.ZERO,
	}

	# Источник: тускнеет + меняет name на «...» как индикатор «эту карту тащат».
	var source_slot: Dictionary = _action_slots[slot_idx]
	(source_slot.icon as ColorRect).color = Color(0.2, 0.2, 0.25, 0.5)
	(source_slot.name_label as Label).text = "..."

	# Блокируем мирные действия руки на время drag'а. Hand.is_pointer_over_ui
	# учитывает этот флаг — пока true, grab/magnet/slam/cast не запускаются.
	var hand := _resolve_hand()
	if hand != null:
		hand.ui_drag_active = true


## Каждый кадр (в _process) — spring-damper физика к курсору, tilt от velocity,
## плюс анимация подъёма target-слота при hover'е.
func _process_drag_physics(delta: float) -> void:
	if _drag_state.is_empty():
		_update_slot_lifts(delta, -1)
		return
	var ghost: Control = _drag_state.ghost
	if not is_instance_valid(ghost):
		_drag_state.clear()
		return
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var target_pos: Vector2 = mouse_pos - ghost.size / 2.0
	# Spring: a = (target - pos) * stiffness - velocity * damping
	var current_pos: Vector2 = _drag_state.pos
	var velocity: Vector2 = _drag_state.velocity
	var acc: Vector2 = (target_pos - current_pos) * DRAG_SPRING_STIFFNESS - velocity * DRAG_SPRING_DAMPING
	velocity += acc * delta
	current_pos += velocity * delta
	_drag_state.pos = current_pos
	_drag_state.velocity = velocity
	ghost.position = current_pos
	# Tilt: x-velocity → rotation. Clamp чтоб карта не делала сальто на резком махе.
	var tilt: float = clampf(velocity.x * DRAG_TILT_PER_VELOCITY, -DRAG_TILT_MAX, DRAG_TILT_MAX)
	ghost.rotation = tilt
	# Подсветка target-слота через лифт.
	var hover_idx: int = _detect_hover_target_idx(mouse_pos)
	_update_slot_lifts(delta, hover_idx)


## Детектит индекс draggable-слота под курсором. -1 если не над слотом или
## над source'ом (себя не выделяем).
func _detect_hover_target_idx(mouse_pos: Vector2) -> int:
	if _drag_state.is_empty():
		return -1
	var source_idx: int = int(_drag_state.get("source_idx", -1))
	for i in range(_slot_assignments.size()):
		var slot: Dictionary = _action_slots[i]
		if not slot.draggable:
			continue
		if i == source_idx:
			continue
		var panel: PanelContainer = slot.panel
		var rect := Rect2(panel.global_position, panel.size)
		if rect.has_point(mouse_pos):
			return i
	return -1


## Кеширует layout-позицию слотов (rest_x). Должна быть вызвана ПОСЛЕ первого
## sort'а HBoxContainer'а, иначе все .position.x = 0. Гард по panel.size.x > 0
## — до sort'а размер тоже 0, после sort'а size становится реальным.
func _cache_slot_rest_positions() -> void:
	for slot in _action_slots:
		if slot.rest_cached:
			continue
		var panel: PanelContainer = slot.panel
		if panel.size.x <= 0.0:
			# HBox ещё не сортировал. Попробуем в следующий тик.
			continue
		slot.rest_x = panel.position.x
		slot.rest_cached = true


## Анимирует panel.position.x вокруг rest_x. hover_idx — индекс target-слота
## (или -1 если нет hover'а). Target «отъезжает» в сторону, противоположную
## source'у: target слева от source → сдвиг влево (rest_x - shift), target
## справа → сдвиг вправо (rest_x + shift). Освобождает место для drag-карты.
func _update_slot_lifts(delta: float, hover_idx: int) -> void:
	_cache_slot_rest_positions()
	var source_idx: int = int(_drag_state.get("source_idx", -1))
	for i in range(_action_slots.size()):
		var slot: Dictionary = _action_slots[i]
		# Пока rest-позиция не закеширована (HBox не сортировал ещё) — не
		# трогаем .position.x, чтобы не перебить layout.
		if not slot.rest_cached:
			continue
		var panel: PanelContainer = slot.panel
		var rest_x: float = slot.rest_x
		var shift: float = 0.0
		if i == hover_idx and source_idx >= 0 and i != source_idx:
			if i < source_idx:
				shift = -DRAG_HOVER_SHIFT
			else:
				shift = DRAG_HOVER_SHIFT
		var target_x: float = rest_x + shift
		var current_x: float = panel.position.x
		var alpha: float = 1.0 - exp(-DRAG_HOVER_SHIFT_DECAY * delta)
		panel.position.x = lerpf(current_x, target_x, alpha)
		panel.position.y = 0.0


## Финализирует drag — детектит target-слот под курсором, swap _slot_assignments
## если попали в другой draggable-слот. Иначе восстанавливает source-слот.
func _finish_drag() -> void:
	if _drag_state.is_empty():
		return
	var ghost: Control = _drag_state.get("ghost")
	var source_idx: int = int(_drag_state.get("source_idx", -1))
	_drag_state.clear()

	# Разблокируем мирные действия руки.
	var hand := _resolve_hand()
	if hand != null:
		hand.ui_drag_active = false

	if source_idx < 0:
		if is_instance_valid(ghost):
			ghost.queue_free()
		return

	# Детект target-слота: проходим по _action_slots, ищем тот, чьё global_rect
	# содержит mouse_pos. Только draggable-слоты считаются target'ом — Super
	# нельзя ремапить.
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var target_idx: int = -1
	for i in range(_slot_assignments.size()):
		var slot: Dictionary = _action_slots[i]
		if not slot.draggable:
			continue
		var panel: PanelContainer = slot.panel
		var rect := Rect2(panel.global_position, panel.size)
		if rect.has_point(mouse_pos):
			target_idx = i
			break

	if target_idx >= 0 and target_idx != source_idx:
		# Swap ability_id'ов между двумя слотами.
		var tmp: StringName = _slot_assignments[source_idx]
		_slot_assignments[source_idx] = _slot_assignments[target_idx]
		_slot_assignments[target_idx] = tmp
		_refresh_slot_visuals(_action_slots[source_idx])
		_refresh_slot_visuals(_action_slots[target_idx])
	else:
		# Нет валидного target'а — восстанавливаем визуал исходного слота.
		_refresh_slot_visuals(_action_slots[source_idx])

	if is_instance_valid(ghost):
		ghost.queue_free()


## Резолв meta-данных слота: для draggable — из _slot_assignments, для Super —
## ACTION_BAR_FIXED_SUPER.
func _slot_meta(slot: Dictionary) -> Dictionary:
	if slot.draggable:
		var ability_id: StringName = _slot_assignments[slot.slot_idx]
		return ABILITY_META.get(ability_id, {})
	return ACTION_BAR_FIXED_SUPER


func _meta_is_active(hand: Hand, meta: Dictionary) -> bool:
	if hand == null or meta.is_empty():
		return false
	match meta.get("category_str", ""):
		"PHYSICAL":
			return hand.active_category == Hand.Category.PHYSICAL \
				and hand.physical_actions != null \
				and int(hand.physical_actions.equipped) == int(meta.type)
		"MAGIC":
			return hand.active_category == Hand.Category.MAGIC \
				and hand.spell_actions != null \
				and int(hand.spell_actions.equipped) == int(meta.type)
		"SUPER":
			return hand.active_category == Hand.Category.SUPER
	return false


func _meta_is_ready(hand: Hand, meta: Dictionary) -> bool:
	if hand == null or meta.is_empty():
		return true
	match meta.get("category_str", ""):
		"PHYSICAL":
			if hand.physical_actions == null:
				return true
			return hand.physical_actions.is_ability_ready(int(meta.type))
		"MAGIC":
			if hand.spell_actions == null:
				return true
			return hand.spell_actions.is_spell_ready(int(meta.type))
		"SUPER":
			if _camp != null and is_instance_valid(_camp):
				return _camp.is_super_ready()
			return true
	return true


func _process(delta: float) -> void:
	_update_timer -= delta
	if _update_timer <= 0.0:
		_update_counts()
		_update_squad_cards_dynamic()
		_update_timer = UPDATE_INTERVAL
	_action_bar_update_timer -= delta
	if _action_bar_update_timer <= 0.0:
		_update_action_bar()
		_action_bar_update_timer = ACTION_BAR_UPDATE_INTERVAL
	# Физика ghost-карты — каждый кадр, не throttled (чем плавнее, тем приятнее).
	_process_drag_physics(delta)


func _update_counts() -> void:
	if _camp == null or not is_instance_valid(_camp):
		_defender_count_label.text = "—"
		_tent_count_label.text = "—"
		_refresh_gatherer_card()
		return
	_defender_count_label.text = "%d" % _camp.defender_count()
	_tent_count_label.text = "%d" % _camp.tent_count_alive()
	_refresh_gatherer_card()
	_refresh_defender_card()


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
	_journal_button.focus_mode = Control.FOCUS_NONE
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
		_refresh_resource_label(type, _camp.economy.get_resource(type))


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
	panel.offset_left = -bar_width / 2.0
	panel.offset_top = 10
	panel.offset_right = bar_width / 2.0
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


## --- Squad cards (правая панель) ---

## Создаёт ScrollContainer + VBox для карточек squad'ов справа сверху, lazy
## — на первый squad_created. Anchored правый-верх, чтобы не конкурировать
## с tower_stats (top center) и resources (right column). ScrollContainer
## нужен на 6+ отрядов: фиксированная высота не вмещает столько карточек,
## вертикальный скролл — без обрезки нижних.
func _ensure_squad_panel() -> void:
	if _squad_panel != null and is_instance_valid(_squad_panel):
		return
	_squad_scroll = ScrollContainer.new()
	# PRESET_RIGHT_WIDE — anchor_top=0, anchor_bottom=1: контейнер тянется
	# на всю высоту экрана. Колонка СЛЕВА от RightPanel (та занимает
	# x∈[-200,-10] из gameplay_hud.tscn): зазор 10px → offset_right=-210,
	# ширина 220px → offset_left=-430. До этого squad-панель сидела
	# в том же x-диапазоне что и RightPanel и буквально перекрывала
	# счётчики ресурсов.
	_squad_scroll.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_squad_scroll.offset_left = -430.0
	_squad_scroll.offset_top = 80.0
	_squad_scroll.offset_right = -210.0
	_squad_scroll.offset_bottom = -20.0
	_squad_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# IGNORE на wrapper'е: ScrollContainer по дефолту STOP и ловит hover
	# в своём rect (полоса в полэкрана справа), из-за чего Hand считал
	# курсор «над UI» и блокировал каст. Кнопки внутри карточек остаются
	# STOP (дефолт) и продолжают принимать клики.
	_squad_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_squad_scroll)

	_squad_panel = VBoxContainer.new()
	_squad_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_squad_panel.add_theme_constant_override("separation", 6)
	_squad_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_squad_scroll.add_child(_squad_panel)


func _on_squad_created(squad: RefCounted) -> void:
	_ensure_squad_panel()
	var card := _build_squad_card(squad as Squad)
	_squad_panel.add_child(card)
	_squad_cards[(squad as Squad).id] = card


func _on_squad_changed(squad: RefCounted) -> void:
	var s := squad as Squad
	if s == null:
		return
	var card: Control = _squad_cards.get(s.id)
	if card == null or not is_instance_valid(card):
		return
	_refresh_squad_card(card, s)


func _on_squad_disbanded(squad: RefCounted) -> void:
	var s := squad as Squad
	if s == null:
		return
	var card: Control = _squad_cards.get(s.id)
	if card != null and is_instance_valid(card):
		card.queue_free()
	_squad_cards.erase(s.id)


## Игрок попытался recall'нуть отряд вне зоны — флешим карточку красным
## modulate'ом. Modulate-tween, без зависимостей. Если карточки нет
## (squad disbanded между событием и обработчиком) — silent skip.
func _on_squad_recall_ignored(squad: RefCounted) -> void:
	var s := squad as Squad
	if s == null:
		return
	var card: Control = _squad_cards.get(s.id)
	if card == null or not is_instance_valid(card):
		return
	var tween := create_tween()
	tween.tween_property(card, "modulate", Color(1.5, 0.4, 0.4, 1.0), 0.08)
	tween.tween_property(card, "modulate", Color.WHITE, 0.35)


## Q-нажатие → волна вызова: расширяющееся кольцо от башни до границы
## зоны за `duration`. Тонкий яркий фронт + размытый полупрозрачный тейл
## (второе кольцо, чуть отстаёт по времени и шире) — даёт визуал «пошёл
## импульс».
func _on_recall_zone_pulsed(center: Vector3, radius: float, duration: float) -> void:
	var scene := get_tree().current_scene
	# Фронт — тонкий, яркий.
	AoeVisual.spawn_expanding_ring(
		scene, center, radius, duration,
		Color(0.55, 0.9, 1.0, 0.95), 0.14,
	)
	# Тейл — спавним с задержкой, чтобы он «лагнул» за фронтом. Шире и
	# дим — читается как блюр/гало за импульсом. WeakRef на scene вместо
	# прямого capture — на смену сцены до timeout'а Godot 4.6 печатает
	# «Lambda capture at index 0 was freed».
	var trail_delay: float = 0.07
	var scene_ref: WeakRef = weakref(scene)
	var t := get_tree().create_timer(trail_delay)
	t.timeout.connect(func() -> void:
		var s: Node = scene_ref.get_ref()
		if s == null:
			return
		# duration уменьшаем на тот же delay — тейл успевает дойти до края
		# одновременно с фронтом, но всю дорогу остаётся позади.
		var trail_duration: float = maxf(duration - trail_delay, 0.05)
		AoeVisual.spawn_expanding_ring(
			s, center, radius, trail_duration,
			Color(0.4, 0.85, 1.0, 0.35), 0.22,
		)
	)


## Карточка одного squad'а. PanelContainer с иконкой, счётчиком и двумя
## кнопками команд. Метаданные ID/refs хранятся через set_meta — потом
## refresh_squad_card их читает чтобы обновить кнопки/текст.
func _build_squad_card(squad: Squad) -> Control:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.set_meta(&"squad_id", squad.id)
	# IGNORE на wrapper'ах — иначе тело карточки ловит hover и Hand
	# блокирует каст по всей правой панели. Кнопки внутри остаются STOP.
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(vbox)

	# Заголовок: цветной квадрат + имя + счётчик
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(header)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(14, 14)
	swatch.color = squad.icon_color
	header.add_child(swatch)
	var title := Label.new()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 13)
	title.set_meta(&"squad_title", true)
	header.add_child(title)

	# Кнопки команд. Назначаем bind через squad-id, в callback резолвим
	# Camp.get_squads().find(id) — squad-объект мог быть disbanded между
	# spawn-ом карточки и кликом.
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	btn_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(btn_row)

	# focus_mode = NONE на всех squad-кнопках. Без этого Godot Button
	# по дефолту имеет FOCUS_ALL, и нажатие Space на сфокусированной
	# (последней кликнутой) кнопке триггерит её pressed-сигнал. То есть
	# Space — суперудар по дизайну — параллельно «нажимал» «Идти сюда»,
	# и поверх голотого aim'а супера появлялся голубой ring squad-aim'а.
	var btn_aim := Button.new()
	btn_aim.text = "Идти сюда"
	btn_aim.focus_mode = Control.FOCUS_NONE
	btn_aim.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_aim.add_theme_font_size_override("font_size", 11)
	btn_aim.pressed.connect(_on_squad_aim_pressed.bind(squad.id))
	btn_aim.set_meta(&"squad_btn_aim", true)
	btn_row.add_child(btn_aim)

	var btn_escort := Button.new()
	btn_escort.text = "За башней"
	btn_escort.focus_mode = Control.FOCUS_NONE
	btn_escort.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_escort.add_theme_font_size_override("font_size", 11)
	btn_escort.pressed.connect(_on_squad_escort_pressed.bind(squad.id))
	btn_escort.set_meta(&"squad_btn_escort", true)
	btn_row.add_child(btn_escort)

	var btn_defend := Button.new()
	btn_defend.text = "Защищать"
	btn_defend.focus_mode = Control.FOCUS_NONE
	btn_defend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_defend.add_theme_font_size_override("font_size", 11)
	btn_defend.pressed.connect(_on_squad_defend_pressed.bind(squad.id))
	btn_defend.set_meta(&"squad_btn_defend", true)
	btn_row.add_child(btn_defend)

	# Вторая строка: «Распустить» — конвертит солдат обратно в gatherer'ов.
	# Disabled когда не все юниты в proximity лагеря (Camp.can_dismiss_squad).
	# Tooltip объясняет, что нужно вернуть в лагерь. Refresh state — в
	# `_refresh_squad_card` (статика на event-ах) и в `_update_squad_cards_dynamic`
	# (раз в 0.25с — пока юниты идут к лагерю, кнопка переключится сама).
	var btn_row2 := HBoxContainer.new()
	btn_row2.add_theme_constant_override("separation", 4)
	btn_row2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(btn_row2)
	var btn_dismiss := Button.new()
	btn_dismiss.text = "Распустить"
	btn_dismiss.focus_mode = Control.FOCUS_NONE
	btn_dismiss.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_dismiss.add_theme_font_size_override("font_size", 11)
	btn_dismiss.pressed.connect(_on_squad_dismiss_pressed.bind(squad.id))
	btn_dismiss.set_meta(&"squad_btn_dismiss", true)
	btn_row2.add_child(btn_dismiss)

	_refresh_squad_card(card, squad)
	return card


func _refresh_squad_card(card: Control, squad: Squad) -> void:
	var alive: int = squad.count_alive()
	var total: int = squad.members.size()
	var type_name: String = SoldierSystem.get_soldier_data(squad.soldier_type).get("name", str(squad.soldier_type))
	# Префикс «⚠» когда отряд вне recall-зоны: персистентный визуальный
	# маркер, что Q-recall его не вернёт. Обновляется и через event-driven
	# (этот метод), и периодически через _update_squad_cards_dynamic.
	var out_of_zone: bool = is_instance_valid(_camp) and not _camp.is_squad_in_recall_zone(squad)
	var prefix: String = "⚠ " if out_of_zone else ""
	# Title и подсветка кнопок согласно state. Поиск по meta — title-Label
	# единственный с set_meta(&"squad_title", true).
	for child in card.find_children("*", "Label", true, false):
		if child.has_meta(&"squad_title"):
			child.text = "%s%s — %d/%d" % [prefix, type_name, alive, total]
			child.add_theme_color_override("font_color", Color(1.0, 0.55, 0.4, 1.0) if out_of_zone else Color.WHITE)
	for btn in card.find_children("*", "Button", true, false):
		if btn.has_meta(&"squad_btn_escort"):
			btn.button_pressed = squad.state == Squad.State.ESCORTING_TOWER
			_apply_escort_state(btn, squad)
		elif btn.has_meta(&"squad_btn_defend"):
			btn.button_pressed = squad.state == Squad.State.DEFENDING_CAMP
		elif btn.has_meta(&"squad_btn_aim"):
			# Подсвечиваем когда HandSquadAim в режиме aim'а на этом squad'е
			# ИЛИ когда squad в HOLD-strict-режиме (юниты ещё идут к точке).
			var hand := _resolve_hand()
			var aiming: bool = hand != null and hand.squad_aim != null and hand.squad_aim.is_aiming(squad)
			btn.button_pressed = aiming or (squad.state == Squad.State.HOLDING_POSITION and squad.is_strict_move())
		elif btn.has_meta(&"squad_btn_dismiss"):
			_apply_dismiss_state(btn, squad)


## Вычисляется и через _refresh_squad_card (event-ы), и через
## _update_squad_cards_dynamic (раз в 0.25с — proximity и state лагеря
## меняются без отдельного сигнала на карточку).
func _apply_dismiss_state(btn: Button, squad: Squad) -> void:
	if not is_instance_valid(_camp):
		btn.disabled = true
		return
	var can: bool = _camp.can_dismiss_squad(squad)
	btn.disabled = not can
	if can:
		btn.tooltip_text = "Конвертировать обратно в gatherer'ов на их позиции"
	elif not _camp.is_deployed():
		btn.tooltip_text = "Размобилизация только в развёрнутом лагере"
	else:
		btn.tooltip_text = "Все юниты должны быть в радиусе лагеря"


## True/false-state и tooltip для кнопки «За башней»: гейт по recall-зоне.
## Если отряд вне зоны — кнопка disabled, объясняем игроку.
func _apply_escort_state(btn: Button, squad: Squad) -> void:
	if not is_instance_valid(_camp):
		btn.disabled = true
		return
	var in_zone: bool = _camp.is_squad_in_recall_zone(squad)
	btn.disabled = not in_zone
	if in_zone:
		btn.tooltip_text = "Отряд следует за башней"
	else:
		btn.tooltip_text = "Отряд вне зоны вызова — подойдите ближе с башней"


## Раз в UPDATE_INTERVAL: подсветка/disabled кнопок, зависящих от мирового
## state'а (proximity для dismiss, recall-зона для escort). Squad-сигналы
## это не покрывают: башня и юниты двигаются без эмита. Дёшево — ≤6-12
## карточек × 2 button.
func _update_squad_cards_dynamic() -> void:
	if not is_instance_valid(_camp) or _squad_cards.is_empty():
		return
	for squad in _camp.get_squads():
		var card: Control = _squad_cards.get(squad.id)
		if card == null or not is_instance_valid(card):
			continue
		for btn in card.find_children("*", "Button", true, false):
			if btn.has_meta(&"squad_btn_dismiss"):
				_apply_dismiss_state(btn, squad)
			elif btn.has_meta(&"squad_btn_escort"):
				_apply_escort_state(btn, squad)


func _on_squad_aim_pressed(squad_id: int) -> void:
	if LogConfig.master_enabled:
		print("[HUD:SquadAim] кнопка нажата squad_id=%d" % squad_id)
	var squad: Squad = _resolve_squad_by_id(squad_id)
	if squad == null:
		if LogConfig.master_enabled:
			print("[HUD:SquadAim]   squad не найден (id=%d) — возможно, уже распущен" % squad_id)
		return
	var hand := _resolve_hand()
	if hand == null:
		if LogConfig.master_enabled:
			print("[HUD:SquadAim]   hand не резолвится — нет узла в группе '%s'" % Hand.HAND_GROUP)
		return
	if hand.squad_aim == null:
		if LogConfig.master_enabled:
			print("[HUD:SquadAim]   hand.squad_aim == null — координатор не подключён в hand.tscn")
		return
	hand.squad_aim.toggle_aim_for(squad)
	# Обновляем подсветку кнопки.
	var card: Control = _squad_cards.get(squad_id)
	if card != null and is_instance_valid(card):
		_refresh_squad_card(card, squad)


func _on_squad_escort_pressed(squad_id: int) -> void:
	var squad: Squad = _resolve_squad_by_id(squad_id)
	if squad == null or not is_instance_valid(_camp):
		return
	# Гейт по recall-зоне: дублируем UI-disabled на случай race'а.
	if not _camp.is_squad_in_recall_zone(squad):
		EventBus.squad_recall_ignored.emit(squad)
		if LogConfig.master_enabled:
			print("[HUD:Squad] escort отклонён: отряд вне зоны вызова башни")
		return
	# Toggle, как у Q: уже escort → HOLD-soft на текущей позиции.
	if squad.state == Squad.State.ESCORTING_TOWER:
		squad.command_hold(_squad_alive_center_or_tower(squad), false)
	else:
		_camp.command_squad_escort(squad)


## Среднее живых членов squad'а; fallback на башню если членов нет.
## HUD-локальная версия аналогична Camp._squad_alive_center, но не
## трогает приватный API лагеря.
func _squad_alive_center_or_tower(squad: Squad) -> Vector3:
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for m in squad.members:
		if not is_instance_valid(m):
			continue
		sum += m.global_position
		n += 1
	if n > 0:
		return sum / float(n)
	var tower := get_tree().get_first_node_in_group(Tower.GROUP) as Tower
	if tower != null:
		return tower.global_position
	return Vector3.ZERO


func _on_squad_defend_pressed(squad_id: int) -> void:
	var squad: Squad = _resolve_squad_by_id(squad_id)
	if squad == null or not is_instance_valid(_camp):
		return
	_camp.command_squad_defend(squad)


func _on_squad_dismiss_pressed(squad_id: int) -> void:
	var squad: Squad = _resolve_squad_by_id(squad_id)
	if squad == null or not is_instance_valid(_camp):
		return
	# can_dismiss_squad — внутренний guard, но логируем намерение для отладки.
	if LogConfig.master_enabled:
		print("[HUD:Squad] dismiss squad_id=%d (can=%s)" % [squad_id, str(_camp.can_dismiss_squad(squad))])
	_camp.dismiss_squad(squad)


func _resolve_squad_by_id(squad_id: int) -> Squad:
	if not is_instance_valid(_camp):
		return null
	for s in _camp.get_squads():
		if s.id == squad_id:
			return s
	return null


func _resolve_hand() -> Hand:
	if is_instance_valid(_hand):
		return _hand
	_hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP) as Hand
	return _hand
