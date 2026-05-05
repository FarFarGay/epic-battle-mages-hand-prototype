extends CanvasLayer
## Модал выбора squad-апгрейда. Открывается на EventBus.squad_leveled_up,
## показывает до 2 случайных карточек из Camp.available_upgrades(), на клике
## вызывает Camp.grant_upgrade и закрывается. Если _pending_upgrade_choices
## всё ещё > 0 (игрок проскочил несколько уровней подряд) — открывается
## повторно с обновлённым набором.
##
## Регистрируется как autoload — не привязан к main.tscn, доступен в любой
## сцене где есть Camp в группе `camp`. UI строится программно (без .tscn) —
## простая панель с двумя кнопками-карточками не тянет на отдельный файл.
##
## Pause: при показе ставит get_tree().paused = true, чтобы скелеты не лезли
## пока игрок думает. process_mode=ALWAYS на CanvasLayer'е и детях — кнопки
## работают при paused-игре, всё остальное замораживается.

const CARD_WIDTH: float = 300.0
const CARD_HEIGHT: float = 220.0
const CAMP_GROUP := &"camp"

var _camp: Node = null
var _overlay: ColorRect
var _panel: PanelContainer
var _title: Label
var _card1: Button
var _card2: Button
## Текущие id'шки на двух карточках. Нужны при клике, чтобы понять что выдать.
## Сохраняются как метаданные на самих кнопках через set_meta — пара
## handler'ов читает их.
var _last_choice_count: int = 0


func _ready() -> void:
	# Поверх любого HUD'а. Стандартный HUD на layer 0–1, ставим заведомо выше.
	layer = 100
	# CanvasLayer и все потомки работают при paused-игре. Без этого кнопки
	# не реагируют на клик когда get_tree().paused=true.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false
	EventBus.squad_leveled_up.connect(_on_level_up)


## Программная UI: full-screen overlay (полупрозрачный) + центрированная
## панель с заголовком и двумя кнопками. Никаких .tscn — конструируем при
## загрузке. Ленивый поиск Camp откладываем до первого show'а: на момент
## _ready Camp может ещё не быть в группе.
func _build_ui() -> void:
	var root_container := Control.new()
	root_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_container.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(root_container)

	# Полупрозрачный затемнитель + блокировка кликов сквозь модал.
	_overlay = ColorRect.new()
	_overlay.color = Color(0.0, 0.0, 0.0, 0.65)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root_container.add_child(_overlay)

	# Центрированная панель. PRESET_CENTER + смещение по custom_minimum_size/2
	# даёт устойчивое центрирование при любом разрешении окна.
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(680, 320)
	_panel.position = -_panel.custom_minimum_size / 2.0
	root_container.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 18)
	_panel.add_child(vbox)

	_title = Label.new()
	_title.text = "Уровень отряда повышен"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(_title)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 18)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)

	_card1 = _make_card()
	hbox.add_child(_card1)
	_card1.pressed.connect(_on_card_pressed.bind(_card1))

	_card2 = _make_card()
	hbox.add_child(_card2)
	_card2.pressed.connect(_on_card_pressed.bind(_card2))


func _make_card() -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.clip_text = false
	btn.add_theme_font_size_override("font_size", 16)
	return btn


func _resolve_camp() -> Node:
	if _camp != null and is_instance_valid(_camp):
		return _camp
	_camp = get_tree().get_first_node_in_group(CAMP_GROUP)
	return _camp


func _on_level_up(_level: int) -> void:
	_show_choices()


## Подбирает до 2 случайных доступных апгрейдов и показывает модал. Если
## доступных нет (игрок выбрал все) — молча выходит, ничего не показывая.
func _show_choices() -> void:
	var camp := _resolve_camp()
	if camp == null:
		push_warning("UpgradeModal: Camp не найден в группе '%s'" % CAMP_GROUP)
		return

	var available: Array = camp.available_upgrades()
	if available.is_empty():
		return
	available.shuffle()

	var first_id: StringName = available[0]
	_populate_card(_card1, first_id)
	_card1.visible = true

	if available.size() >= 2:
		var second_id: StringName = available[1]
		_populate_card(_card2, second_id)
		_card2.visible = true
		_last_choice_count = 2
	else:
		_card2.visible = false
		_last_choice_count = 1

	_title.text = "Уровень %d — выберите улучшение" % camp.get_squad_level()
	visible = true
	get_tree().paused = true


func _populate_card(btn: Button, id: StringName) -> void:
	var data: Dictionary = Camp.UPGRADE_CATALOG.get(id, {})
	var card_name: String = data.get("name", String(id))
	var card_desc: String = data.get("description", "")
	btn.text = "%s\n\n%s" % [card_name, card_desc]
	btn.set_meta("upgrade_id", id)


## Колбек обоих кнопок (.bind(btn) подставляет конкретную). Извлекает id
## из meta, выдаёт апгрейд, закрывает модал. Если Camp ещё держит уровни
## в очереди — открывается заново.
func _on_card_pressed(btn: Button) -> void:
	var id: StringName = btn.get_meta("upgrade_id", &"")
	var camp := _resolve_camp()
	if camp != null and id != &"":
		camp.grant_upgrade(id)
	_close()
	if camp != null and camp.get_pending_upgrade_choices() > 0:
		_show_choices()


func _close() -> void:
	visible = false
	get_tree().paused = false
