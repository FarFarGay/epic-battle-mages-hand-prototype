extends CanvasLayer
## Журнал игрока. Кнопка в HUD + клавиша J. Две вкладки: «Юниты» — апгрейды
## отряда (тратят накопленные `Camp._pending_upgrade_choices`); «Лагерь» —
## постройки за ресурсы (заглушка до фазы 2 ресурсной экономики).
##
## Не ставит игру на паузу — игрок выбирает апгрейд в любой момент, банк
## выборов копится в Camp до закрытия. Это сознательный отказ от старого
## UpgradeModal'а с автопаузой — дизайнер не хотел останавливать каждый
## раз бой ради карточки.
##
## Реактивное обновление: подписка на EventBus.pending_upgrade_choices_changed
## (бэйдж и список) и squad_xp_changed (заголовок). Перерисовка только при
## открытом журнале — пока скрыт, refresh откладывается до следующего open.

const CAMP_GROUP := &"camp"

enum Tab { UNITS, CAMP, PLAN, SPELLS, ARMY, QUESTS, DEBUG }

## Preset'ы плана сбора. Главное число — приоритет «фокусного» типа (55), у
## остальных 15 — нормализация в Camp.set_collection_priority даст 0.55/0.15/0.15/0.15.
## Equal — ровно 25% каждому. Если игроку понадобятся свободные слайдеры,
## добавим custom-mode позже.
const PLAN_PRESETS: Array = [
	{
		"id": &"equal",
		"label": "Равномерно",
		"weights": {
			ResourcePile.ResourceType.WOOD: 1.0,
			ResourcePile.ResourceType.STONE: 1.0,
			ResourcePile.ResourceType.IRON: 1.0,
			ResourcePile.ResourceType.FOOD: 1.0,
		},
	},
	{
		"id": &"wood_focus",
		"label": "Больше дерева",
		"weights": {
			ResourcePile.ResourceType.WOOD: 55.0,
			ResourcePile.ResourceType.STONE: 15.0,
			ResourcePile.ResourceType.IRON: 15.0,
			ResourcePile.ResourceType.FOOD: 15.0,
		},
	},
	{
		"id": &"stone_focus",
		"label": "Больше камня",
		"weights": {
			ResourcePile.ResourceType.WOOD: 15.0,
			ResourcePile.ResourceType.STONE: 55.0,
			ResourcePile.ResourceType.IRON: 15.0,
			ResourcePile.ResourceType.FOOD: 15.0,
		},
	},
	{
		"id": &"iron_focus",
		"label": "Больше железа",
		"weights": {
			ResourcePile.ResourceType.WOOD: 15.0,
			ResourcePile.ResourceType.STONE: 15.0,
			ResourcePile.ResourceType.IRON: 55.0,
			ResourcePile.ResourceType.FOOD: 15.0,
		},
	},
	{
		"id": &"food_focus",
		"label": "Больше еды",
		"weights": {
			ResourcePile.ResourceType.WOOD: 15.0,
			ResourcePile.ResourceType.STONE: 15.0,
			ResourcePile.ResourceType.IRON: 15.0,
			ResourcePile.ResourceType.FOOD: 55.0,
		},
	},
]

var _camp: Node = null
var _current_tab: Tab = Tab.UNITS

var _backdrop: ColorRect
var _panel: PanelContainer
var _tab_units_btn: Button
var _tab_camp_btn: Button
var _tab_plan_btn: Button
var _tab_spells_btn: Button
var _tab_army_btn: Button
var _tab_quests_btn: Button
var _tab_debug_btn: Button
var _content: VBoxContainer
var _header_label: Label


func _ready() -> void:
	# Поверх HUD'а (HUD на layer 0). Ниже потенциальных «hard-stop» попапов
	# (Esc-меню в будущем поставим выше — журнал должен прятаться под ним).
	layer = 95
	_build_ui()
	visible = false
	EventBus.pending_upgrade_choices_changed.connect(_on_pending_changed)
	EventBus.squad_xp_changed.connect(_on_squad_xp_changed)
	EventBus.squad_upgrade_granted.connect(_on_upgrade_granted)
	# Camp-вкладка реактивна на ресурсы (афорд) + состояние (packed_only) +
	# состав построек (одноразовые превратились в «уже куплено»).
	EventBus.resources_changed.connect(_on_resources_changed)
	EventBus.camp_deployed.connect(_on_camp_state_changed_anchor)
	EventBus.camp_packed.connect(_on_camp_state_changed)
	EventBus.camp_buildings_changed.connect(_on_camp_state_changed)
	# План реактивен на изменение приоритета (другой preset нажат).
	EventBus.collection_priority_changed.connect(_on_collection_priority_changed)
	# Задания реактивны на продвижение квеста (любой источник: чит, программный
	# триггер). При смене активного квеста перерисовываем вкладку.
	EventBus.quest_advanced.connect(_on_quest_advanced)
	# Заклинания: реактивно на unlock/upgrade (включая программные касты
	# в будущем). Перерисовываем вкладку SPELLS если она активна.
	EventBus.spell_unlocked.connect(_on_spell_changed)
	EventBus.spell_upgraded.connect(_on_spell_changed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_journal"):
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	visible = true
	_refresh()


func close() -> void:
	visible = false


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# Полупрозрачный фон. Клики по нему НЕ закрывают журнал — слишком легко
	# случайно промахнуться. Закрытие — крестик или повторное J.
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_backdrop)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(720, 520)
	_panel.position = -_panel.custom_minimum_size / 2.0
	root.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(vbox)

	_build_header(vbox)
	_build_tabs(vbox)

	_content = VBoxContainer.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 8)
	vbox.add_child(_content)


func _build_header(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)

	var title := Label.new()
	title.text = "Журнал"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)

	_header_label = Label.new()
	_header_label.add_theme_font_size_override("font_size", 14)
	_header_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 1.0))
	row.add_child(_header_label)

	var close_btn := Button.new()
	close_btn.text = "×"
	close_btn.custom_minimum_size = Vector2(32, 32)
	close_btn.add_theme_font_size_override("font_size", 18)
	close_btn.pressed.connect(close)
	row.add_child(close_btn)


func _build_tabs(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)

	_tab_units_btn = _make_tab_button("Юниты")
	_tab_units_btn.pressed.connect(_select_tab.bind(Tab.UNITS))
	row.add_child(_tab_units_btn)

	_tab_camp_btn = _make_tab_button("Лагерь")
	_tab_camp_btn.pressed.connect(_select_tab.bind(Tab.CAMP))
	row.add_child(_tab_camp_btn)

	_tab_plan_btn = _make_tab_button("План")
	_tab_plan_btn.pressed.connect(_select_tab.bind(Tab.PLAN))
	row.add_child(_tab_plan_btn)

	_tab_spells_btn = _make_tab_button("Заклинания")
	_tab_spells_btn.pressed.connect(_select_tab.bind(Tab.SPELLS))
	row.add_child(_tab_spells_btn)

	_tab_army_btn = _make_tab_button("Армия")
	_tab_army_btn.pressed.connect(_select_tab.bind(Tab.ARMY))
	row.add_child(_tab_army_btn)

	_tab_quests_btn = _make_tab_button("Задания")
	_tab_quests_btn.pressed.connect(_select_tab.bind(Tab.QUESTS))
	row.add_child(_tab_quests_btn)

	_tab_debug_btn = _make_tab_button("Читы")
	_tab_debug_btn.pressed.connect(_select_tab.bind(Tab.DEBUG))
	row.add_child(_tab_debug_btn)

	# Разделитель под вкладками — визуально отделяет хедер от контента.
	var sep := HSeparator.new()
	parent.add_child(sep)


func _make_tab_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(120, 32)
	btn.add_theme_font_size_override("font_size", 16)
	btn.toggle_mode = true
	return btn


func _select_tab(tab: Tab) -> void:
	_current_tab = tab
	_refresh()


## Перерисовка всего журнала. Дёргается на open(), на смене вкладки и на
## внешних сигналах (только если visible — иначе откладывается).
func _refresh() -> void:
	if not visible:
		return
	var camp := _resolve_camp()
	_tab_units_btn.button_pressed = (_current_tab == Tab.UNITS)
	_tab_camp_btn.button_pressed = (_current_tab == Tab.CAMP)
	_tab_plan_btn.button_pressed = (_current_tab == Tab.PLAN)
	_tab_spells_btn.button_pressed = (_current_tab == Tab.SPELLS)
	_tab_army_btn.button_pressed = (_current_tab == Tab.ARMY)
	_tab_quests_btn.button_pressed = (_current_tab == Tab.QUESTS)
	_tab_debug_btn.button_pressed = (_current_tab == Tab.DEBUG)
	_clear_content()
	# DEBUG/QUESTS работают без Camp (читы дёргают WaveDirector, задания
	# читают QuestActor'ы со сцены). SPELLS читает SpellSystem-state и Camp
	# нужен только для afford-чека стоимости — лучше показать карточки
	# даже без camp, кнопки disable'нутся через can_afford.
	var camp_optional: bool = _current_tab == Tab.DEBUG or _current_tab == Tab.QUESTS or _current_tab == Tab.SPELLS
	if camp == null and not camp_optional:
		var warn := Label.new()
		warn.text = "Лагерь не найден."
		_content.add_child(warn)
		return
	match _current_tab:
		Tab.UNITS:
			_build_units_tab(camp)
		Tab.CAMP:
			_build_camp_tab(camp)
		Tab.PLAN:
			_build_plan_tab(camp)
		Tab.SPELLS:
			_build_spells_tab(camp)
		Tab.ARMY:
			_build_army_tab(camp)
		Tab.QUESTS:
			_build_quests_tab()
		Tab.DEBUG:
			_build_debug_tab(camp)


func _clear_content() -> void:
	for child in _content.get_children():
		child.queue_free()


func _build_units_tab(camp: Node) -> void:
	var squad_level: int = camp.get_squad_level()
	var pending: int = camp.get_pending_upgrade_choices()
	_header_label.text = "уровень %d · доступно выборов: %d" % [squad_level, pending]

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)

	# Идём по полному каталогу (а не available_upgrades): хочется показать
	# и взятые («активен»), и невзятые, и заблокированные по уровню.
	# Сортировка по требуемому уровню — чтобы tree читался сверху вниз.
	var ids: Array = Camp.UPGRADE_CATALOG.keys()
	ids.sort_custom(func(a, b): return _required_level(a) < _required_level(b))
	for id in ids:
		list.add_child(_build_unit_card(camp, id, pending, squad_level))


func _required_level(id: StringName) -> int:
	var data: Dictionary = Camp.UPGRADE_CATALOG.get(id, {})
	return int(data.get("level", 1))


func _build_unit_card(camp: Node, id: StringName, pending: int, squad_level: int) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	card.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 4)
	hbox.add_child(info)

	var data: Dictionary = Camp.UPGRADE_CATALOG.get(id, {})
	var required_level: int = int(data.get("level", 1))

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	info.add_child(title_row)

	var name_label := Label.new()
	name_label.text = data.get("name", String(id))
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(name_label)

	var level_tag := Label.new()
	level_tag.text = "ур. %d" % required_level
	level_tag.add_theme_font_size_override("font_size", 12)
	level_tag.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0, 1.0))
	title_row.add_child(level_tag)

	var desc_label := Label.new()
	desc_label.text = data.get("description", "")
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.add_theme_font_size_override("font_size", 12)
	desc_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1.0))
	desc_label.custom_minimum_size = Vector2(420, 0)
	info.add_child(desc_label)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(160, 48)
	hbox.add_child(btn)

	# Цепочка состояний: уже взят > заблокирован по уровню > нет очков > можно брать.
	# Порядок важен — взятый апгрейд показываем «активен» независимо от того,
	# какой сейчас squad_level (на случай если в будущем уровни могут падать).
	var active: bool = camp.has_upgrade(id)
	if active:
		btn.text = "✓ активен"
		btn.disabled = true
		_dim(card, 0.6)
	elif squad_level < required_level:
		btn.text = "требуется ур. %d" % required_level
		btn.disabled = true
		_dim(card, 0.45)
	elif pending <= 0:
		btn.text = "нет очков"
		btn.disabled = true
	else:
		btn.text = "выбрать"
		_wire_action_button(btn, _on_unit_upgrade_pressed.bind(id))

	return card


## Притеняет недоступную карточку — слегка прозрачная, легче читать активные.
func _dim(node: Control, alpha: float) -> void:
	node.modulate = Color(1, 1, 1, alpha)


## Привязка кнопки к действию с защитой от дребезга. Двойной клик до
## перерисовки UI мог бы списать ресурс/level дважды (Camp.try_build,
## Camp.grant_upgrade, SpellSystem.try_unlock/try_upgrade проверяют ресурсы
## внутри, но между двумя кликами в одном кадре первый уже списал —
## второй увидит «не хватает» и тихо откажет, а если хватит — спишет ещё
## раз). Disable'им сразу: следующий _refresh пересоздаст карточку.
func _wire_action_button(btn: Button, callback: Callable) -> void:
	btn.pressed.connect(func() -> void:
		if btn.disabled:
			return
		btn.disabled = true
		callback.call()
	)


func _on_unit_upgrade_pressed(id: StringName) -> void:
	var camp := _resolve_camp()
	if camp == null:
		return
	camp.grant_upgrade(id)
	# pending_upgrade_choices_changed придёт сразу, _refresh подхватит.


## Метаданные ресурсов для вёрстки строки цены: ResourceType → {label, color}.
## Локальная копия (HUD держит свою) — типы редко меняются, лучше дубль чем
## зависимость UI-autoload'а от gameplay_hud'а.
const RESOURCE_DISPLAY: Dictionary = {
	ResourcePile.ResourceType.WOOD: {"label": "дерево", "color": Color(0.45, 0.28, 0.15)},
	ResourcePile.ResourceType.STONE: {"label": "камень", "color": Color(0.55, 0.55, 0.55)},
	ResourcePile.ResourceType.IRON: {"label": "железо", "color": Color(0.45, 0.48, 0.55)},
	ResourcePile.ResourceType.FOOD: {"label": "еда", "color": Color(0.85, 0.35, 0.25)},
	ResourcePile.ResourceType.PAGE: {"label": "страницы", "color": Color(0.55, 0.35, 0.85)},
}


func _build_camp_tab(camp: Node) -> void:
	_header_label.text = "постройки лагеря"

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)

	for id in Camp.CAMP_BUILDING_CATALOG.keys():
		list.add_child(_build_building_card(camp, id))


func _build_building_card(camp: Node, id: StringName) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	card.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 4)
	hbox.add_child(info)

	var data: Dictionary = Camp.CAMP_BUILDING_CATALOG.get(id, {})

	var name_label := Label.new()
	name_label.text = data.get("name", String(id))
	name_label.add_theme_font_size_override("font_size", 16)
	info.add_child(name_label)

	var desc_label := Label.new()
	desc_label.text = data.get("description", "")
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.add_theme_font_size_override("font_size", 12)
	desc_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1.0))
	desc_label.custom_minimum_size = Vector2(380, 0)
	info.add_child(desc_label)

	# Строка цены: иконки ресурсов + числа. Подсвечиваем красным то, чего
	# не хватает — игрок сразу видит что собирать дальше.
	info.add_child(_build_cost_row(camp, data.get("cost", {})))

	# Правая колонка: кнопка построить. Состояние и текст определяются
	# can_build_reason + can_afford. Полный disabled — если нельзя по
	# состоянию (свёрнут/развёрнут) ИЛИ ресурсам.
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(180, 56)
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.add_theme_font_size_override("font_size", 13)
	hbox.add_child(btn)

	var reason: String = camp.can_build_reason(id)
	var cost: Dictionary = data.get("cost", {})
	var affordable: bool = camp.can_afford(cost)
	if reason != "":
		btn.text = reason
		btn.disabled = true
		_dim(card, 0.55)
	elif not affordable:
		btn.text = "не хватает ресурсов"
		btn.disabled = true
	else:
		btn.text = "построить"
		_wire_action_button(btn, _on_build_pressed.bind(id))

	return card


## Строка стоимости: для каждого типа ресурса в cost — цветной квадратик +
## «текущий/требуется». Красный текст если нехватка по этому типу.
func _build_cost_row(camp: Node, cost: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	for type in cost:
		var amount_required: int = int(cost[type])
		var amount_have: int = camp.get_resource(type)
		var enough: bool = amount_have >= amount_required

		var item := HBoxContainer.new()
		item.add_theme_constant_override("separation", 4)
		row.add_child(item)

		var display: Dictionary = RESOURCE_DISPLAY.get(type, {})
		var icon := ColorRect.new()
		icon.custom_minimum_size = Vector2(14, 14)
		icon.color = display.get("color", Color.WHITE)
		item.add_child(icon)

		var label := Label.new()
		label.text = "%d/%d" % [amount_have, amount_required]
		label.add_theme_font_size_override("font_size", 12)
		if enough:
			label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 1.0))
		else:
			label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5, 1.0))
		item.add_child(label)

	return row


func _on_build_pressed(id: StringName) -> void:
	var camp := _resolve_camp()
	if camp == null:
		return
	# Кнопка нажимаема только когда can_build_reason пуст и can_afford true,
	# поэтому try_build здесь должен почти всегда успешно вернуть. Если нет —
	# Camp сам залогирует через push_error / debug_log.
	camp.try_build(id)
	# resources_changed / camp_buildings_changed эмитятся внутри try_build,
	# наши хендлеры подхватят и перерисуют.


func _resolve_camp() -> Node:
	if _camp != null and is_instance_valid(_camp):
		return _camp
	_camp = get_tree().get_first_node_in_group(CAMP_GROUP)
	return _camp


func _on_pending_changed(_count: int) -> void:
	_refresh()


func _on_squad_xp_changed(_xp: int, _level: int) -> void:
	if _current_tab == Tab.UNITS:
		_refresh()


func _on_upgrade_granted(_id: StringName) -> void:
	_refresh()


func _on_resources_changed(_type: int, _amount: int) -> void:
	# Юнит-вкладка от ресурсов не зависит — рефрешим только активную.
	# Армия зависит (cost-row + can_recruit disabled-state).
	if _current_tab == Tab.CAMP or _current_tab == Tab.ARMY:
		_refresh()


func _on_camp_state_changed_anchor(_anchor: Vector3) -> void:
	# camp_deployed эмитит anchor; нам он тут не нужен, общий рефреш.
	_on_camp_state_changed()


func _on_camp_state_changed() -> void:
	if _current_tab == Tab.CAMP:
		_refresh()


func _on_collection_priority_changed(_weights: Dictionary) -> void:
	if _current_tab == Tab.PLAN:
		_refresh()


## Вкладка «План»: 5 preset-кнопок распределения сбора. Активный preset
## (тот, что соответствует текущему _collection_priority Camp'а) подсвечен.
## Нажатие на другую — Camp.set_collection_priority + reactive _refresh.
##
## Determining «активный preset»: сравниваем нормализованные weights camp'а
## с нормализованными preset'ами. Если совпадают (с эпсилон) — это активный.
## При свободном custom-режиме (если добавим позже) ни один preset не будет
## активен — это нормально.
func _build_plan_tab(camp: Node) -> void:
	_header_label.text = "приоритет сбора"

	var msg := Label.new()
	msg.text = "Куда направить гномов: чем выше доля типа, тем чаще они выбирают такой ресурс."
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.add_theme_font_size_override("font_size", 12)
	msg.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1.0))
	_content.add_child(msg)

	var current: Dictionary = camp.get_collection_priority()

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(list)

	for preset in PLAN_PRESETS:
		list.add_child(_build_plan_preset_card(camp, preset, current))


func _build_plan_preset_card(camp: Node, preset: Dictionary, current: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	card.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 4)
	hbox.add_child(info)

	var name_label := Label.new()
	name_label.text = preset["label"]
	name_label.add_theme_font_size_override("font_size", 16)
	info.add_child(name_label)

	# Строка долей: цветной квадратик + проценты для каждого типа.
	var weights: Dictionary = preset["weights"]
	info.add_child(_build_plan_weights_row(weights))

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(140, 48)
	hbox.add_child(btn)

	var is_active: bool = _weights_match(current, weights)
	if is_active:
		btn.text = "✓ активен"
		btn.disabled = true
	else:
		btn.text = "выбрать"
		btn.pressed.connect(_on_plan_preset_pressed.bind(weights))
	if is_active:
		_dim(card, 1.0)  # активный — полная яркость
	else:
		_dim(card, 0.85)

	return card


## Строка долей: для каждого типа маленький квадратик цвета + процент.
## Нормализуем weights к 100% локально, чтобы показать «доли».
func _build_plan_weights_row(weights: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var total: float = 0.0
	for w in weights.values():
		total += float(w)
	if total <= 0.0:
		total = 1.0  # защита от деления на 0

	for type in weights:
		var pct: int = int(round(float(weights[type]) / total * 100.0))
		var item := HBoxContainer.new()
		item.add_theme_constant_override("separation", 4)
		row.add_child(item)

		var icon := ColorRect.new()
		icon.custom_minimum_size = Vector2(14, 14)
		icon.color = ResourcePile.color_for_type(int(type))
		item.add_child(icon)

		var label := Label.new()
		label.text = "%d%%" % pct
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 1.0))
		item.add_child(label)

	return row


## Совпадают ли нормализованные веса. Camp хранит уже нормализованные (sum=1).
## Preset'ы — сырые (sum=любая) — нормализуем тут перед сравнением.
func _weights_match(camp_weights: Dictionary, preset_weights: Dictionary) -> bool:
	var preset_total: float = 0.0
	for w in preset_weights.values():
		preset_total += float(w)
	if preset_total <= 0.0:
		return false
	const EPS: float = 0.005
	for type in preset_weights:
		var preset_norm: float = float(preset_weights[type]) / preset_total
		var camp_val: float = float(camp_weights.get(type, 0.0))
		if absf(preset_norm - camp_val) > EPS:
			return false
	return true


func _on_plan_preset_pressed(weights: Dictionary) -> void:
	var camp := _resolve_camp()
	if camp == null:
		return
	camp.set_collection_priority(weights)


## Вкладка «Заклинания»: каталог из SpellSystem.SPELL_CATALOG. Каждое
## заклинание — карточка с описанием и кнопкой действия:
##   - locked: «открыть» (списывает unlock_cost через Camp.try_spend);
##   - unlocked, есть апгрейды: «улучшить → ур. N+1» (списывает upgrade_costs[N]);
##   - max level: «макс. уровень» (disabled).
##
## Параметры текущего уровня показываются в карточке для feedback'а — что
## именно поменяется после апгрейда. Stats преставлены generic (key/value
## из level-data), чтобы каталог можно было расширять без правок UI.
func _build_spells_tab(camp: Node) -> void:
	_header_label.text = "книга заклинаний"

	var msg := Label.new()
	msg.text = "Тратьте «страницы» для разблокировки и улучшения заклинаний башни."
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.add_theme_font_size_override("font_size", 12)
	msg.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1.0))
	_content.add_child(msg)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)

	for id in SpellSystem.SPELL_CATALOG.keys():
		list.add_child(_build_spell_card(camp, id))


func _build_spell_card(camp: Node, id: StringName) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	card.add_child(hbox)

	# Цветная иконка-плашка слева — узнаваемый идентификатор заклинания.
	var data: Dictionary = SpellSystem.get_spell_data(id)
	var icon := ColorRect.new()
	icon.custom_minimum_size = Vector2(8, 0)
	icon.color = data.get("icon_color", Color(0.5, 0.5, 0.7, 1.0))
	hbox.add_child(icon)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 4)
	hbox.add_child(info)

	var unlocked: bool = SpellSystem.is_unlocked(id)
	var current_level: int = SpellSystem.get_level(id)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	info.add_child(title_row)

	var name_label := Label.new()
	name_label.text = data.get("name", String(id))
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(name_label)

	var status_tag := Label.new()
	status_tag.add_theme_font_size_override("font_size", 12)
	if unlocked:
		var max_idx: int = (data.get("levels", []) as Array).size() - 1
		status_tag.text = "ур. %d / %d" % [current_level, max_idx]
		status_tag.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0, 1.0))
	else:
		status_tag.text = "🔒 закрыто"
		status_tag.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65, 1.0))
	title_row.add_child(status_tag)

	var desc_label := Label.new()
	desc_label.text = data.get("description", "")
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.add_theme_font_size_override("font_size", 12)
	desc_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1.0))
	desc_label.custom_minimum_size = Vector2(380, 0)
	info.add_child(desc_label)

	# Stats текущего уровня (generic key:value). Скрываем в locked — не
	# спойлерим, у игрока нет данных пока не открыто.
	if unlocked:
		var stats: Dictionary = SpellSystem.get_current_level_data(id)
		info.add_child(_build_spell_stats_row(stats))

	# Стоимость следующего шага (unlock или upgrade).
	var cost: Dictionary = data.get("unlock_cost", {}) if not unlocked else SpellSystem.get_next_upgrade_cost(id)
	if not cost.is_empty():
		info.add_child(_build_cost_row(camp, cost))

	# Правая кнопка действия. Логика disable'а:
	# - locked: «открыть», disabled если не хватает или camp нет;
	# - unlocked + есть апгрейды: «улучшить», disabled аналогично;
	# - max level: «макс. уровень», disabled.
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(160, 56)
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.add_theme_font_size_override("font_size", 13)
	hbox.add_child(btn)

	if not unlocked:
		var affordable: bool = camp != null and camp.can_afford(cost)
		btn.text = "открыть"
		if not affordable:
			btn.disabled = true
			_dim(card, 0.6)
		else:
			_wire_action_button(btn, _on_unlock_spell_pressed.bind(id))
	elif SpellSystem.can_upgrade_further(id):
		var affordable: bool = camp != null and camp.can_afford(cost)
		btn.text = "улучшить → ур. %d" % (current_level + 1)
		if not affordable:
			btn.disabled = true
		else:
			_wire_action_button(btn, _on_upgrade_spell_pressed.bind(id))
	else:
		btn.text = "макс. уровень"
		btn.disabled = true
		_dim(card, 0.85)

	return card


## Generic-рендер stats: для каждого ключа level-data рисуем «key: value».
## Сейчас level-data — Dictionary с float'ами/int'ами (damage/radius/cooldown/...);
## будут более сложные значения — расширим helper.
func _build_spell_stats_row(stats: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	for key in stats.keys():
		var item := Label.new()
		item.text = "%s: %s" % [str(key), _format_stat(stats[key])]
		item.add_theme_font_size_override("font_size", 11)
		item.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0, 1.0))
		row.add_child(item)
	return row


func _format_stat(v: Variant) -> String:
	if v is float:
		return "%.1f" % v
	return str(v)


func _on_unlock_spell_pressed(id: StringName) -> void:
	SpellSystem.try_unlock(id)
	# spell_unlocked signal перерисует вкладку через _on_spell_changed.


func _on_upgrade_spell_pressed(id: StringName) -> void:
	SpellSystem.try_upgrade(id)


func _on_spell_changed(_id_or_other: Variant = null, _level: int = 0) -> void:
	if _current_tab == Tab.SPELLS:
		_refresh()


## Вкладка «Армия»: список типов солдат из SoldierSystem.SOLDIER_CATALOG,
## текущая численность по типам, кнопка «Призвать» (Camp.recruit_soldier).
##
## Призыв = конвертация одного gatherer'а в soldier'а. Кнопка disabled если
## не хватает gatherer'ов или ресурсов (Camp.can_recruit). Реактивно через
## EventBus.camp_buildings_changed (его эмитит recruit_soldier).
func _build_army_tab(camp: Node) -> void:
	if camp == null:
		_header_label.text = "армия"
		return
	_header_label.text = "армия — gatherer'ов: %d, солдат: %d" % [camp.gatherer_count(), camp.soldier_count()]

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)

	for id in SoldierSystem.SOLDIER_CATALOG.keys():
		list.add_child(_build_soldier_card(camp, id))


func _build_soldier_card(camp: Node, id: StringName) -> Control:
	var data: Dictionary = SoldierSystem.get_soldier_data(id)
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 6)
	card.add_child(info)

	# Заголовок: цветная точка + имя + текущая численность (всего солдат
	# этого типа / squad_size — игрок видит «у меня X лучников, отряд из 5»).
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	info.add_child(header)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(14, 14)
	swatch.color = data.get("icon_color", Color.WHITE)
	header.add_child(swatch)
	var title := Label.new()
	var current_count: int = camp.soldier_count(id)
	var squad_size: int = SoldierSystem.get_squad_size(id)
	title.text = "%s — %d в строю (отряд × %d)" % [data.get("name", str(id)), current_count, squad_size]
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	# Описание
	var desc := Label.new()
	desc.text = data.get("description", "")
	desc.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95, 0.85))
	desc.add_theme_font_size_override("font_size", 12)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(desc)

	# Stats-row (generic key:value, как у Spell)
	var stats: Dictionary = data.get("stats", {})
	if not stats.is_empty():
		info.add_child(_build_spell_stats_row(stats))

	# Cost-row (если есть)
	var cost: Dictionary = data.get("cost", {})
	if not cost.is_empty():
		info.add_child(_build_cost_row(camp, cost))

	# Кнопка «Призвать отряд» — disabled если can_recruit_squad == false
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(180, 36)
	btn.add_theme_font_size_override("font_size", 13)
	var can_recruit: bool = camp.can_recruit_squad(id)
	if can_recruit:
		btn.text = "Призвать отряд (×%d)" % squad_size
		_wire_action_button(btn, _on_recruit_pressed.bind(id))
	else:
		# Расшифруем причину для UX. Порядок проверок — от «жёстких» (state)
		# к «мягким» (нехватка ресурсов): игроку показываем главную причину.
		var available: int = camp.gatherer_count()
		var has_resources: bool = camp.can_afford(cost)
		if not camp.is_deployed():
			btn.text = "только в развёрнутом лагере"
		elif available < squad_size:
			btn.text = "гномов: %d / %d" % [available, squad_size]
		elif not has_resources:
			btn.text = "не хватает ресурсов"
		else:
			btn.text = "недоступно"
		btn.disabled = true
		_dim(card, 0.7)
	info.add_child(btn)

	return card


func _on_recruit_pressed(id: StringName) -> void:
	var camp := _resolve_camp()
	if camp == null:
		return
	camp.recruit_squad(id)
	# camp_buildings_changed придёт от Camp, _on_buildings_changed → _refresh.


## Вкладка «Задания»: список всех QuestActor'ов со сцены, отсортированный по
## quest_order. Каждый рендерится карточкой по своему состоянию:
##   - LOCKED — «???» вместо заголовка/описания, низкая яркость;
##   - ACTIVE — заголовок + описание, золотой статус-таг;
##   - COMPLETED — заголовок (приглушено) + описание, зелёный «✓» статус.
##
## Контента (списка квестов) пока нет — экспорты на QuestActor'ах пустые,
## журнал покажет fallback-заголовки. Дизайнер заполняет quest_title /
## quest_description на каждом QuestActor в редакторе по мере появления
## квестов; журнал подхватит автоматически без правок кода.
##
## Реактивность: подписка на `EventBus.quest_advanced` в `_ready` — при
## продвижении прогресса (через advance() или чит) активный квест перейдёт
## в completed, следующий разблокируется, журнал перерисуется.
func _build_quests_tab() -> void:
	var actors: Array = QuestProgress.get_actors_sorted()
	_header_label.text = "выполнено: %d из %d" % [QuestProgress.current_index, actors.size()]

	if actors.is_empty():
		var warn := Label.new()
		warn.text = "Нет заданий на сцене."
		warn.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 1.0))
		_content.add_child(warn)
		return

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)

	for actor in actors:
		list.add_child(_build_quest_card(actor as QuestActor))


func _build_quest_card(actor: QuestActor) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	card.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 4)
	hbox.add_child(info)

	var state: int = QuestProgress.get_state(actor.quest_order)

	var title_label := Label.new()
	title_label.add_theme_font_size_override("font_size", 16)
	info.add_child(title_label)

	var desc_label := Label.new()
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.add_theme_font_size_override("font_size", 12)
	desc_label.custom_minimum_size = Vector2(420, 0)
	info.add_child(desc_label)

	var fallback_title: String = actor.quest_title if actor.quest_title != "" else "Задание #%d" % (actor.quest_order + 1)

	var status_label := Label.new()
	status_label.add_theme_font_size_override("font_size", 13)
	status_label.custom_minimum_size = Vector2(140, 0)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hbox.add_child(status_label)

	match state:
		QuestProgress.State.LOCKED:
			# Скрываем заголовок и описание — игрок не должен видеть будущие
			# задания, чтобы не спойлерить. Только сам факт «впереди ещё есть».
			title_label.text = "???"
			title_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55, 1.0))
			desc_label.text = "Задание ещё не разблокировано."
			desc_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
			status_label.text = "🔒 закрыто"
			status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
			_dim(card, 0.5)
		QuestProgress.State.ACTIVE:
			title_label.text = fallback_title
			title_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4, 1.0))
			desc_label.text = actor.quest_description if actor.quest_description != "" else "(описание ещё не задано)"
			desc_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95, 1.0))
			status_label.text = "▶ активно"
			status_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4, 1.0))
		QuestProgress.State.COMPLETED:
			title_label.text = fallback_title
			title_label.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7, 1.0))
			desc_label.text = actor.quest_description if actor.quest_description != "" else "(описание ещё не задано)"
			desc_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 1.0))
			status_label.text = "✓ выполнено"
			status_label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.55, 1.0))
			_dim(card, 0.75)

	return card


func _on_quest_advanced(_new_index: int) -> void:
	if _current_tab == Tab.QUESTS:
		_refresh()


## Вкладка «Читы»: дебаг-кнопки, заменяющие старые keyboard-actions
## (P/O/[/]) и плюс новый чит «+100 каждого ресурса». Нет авто-disable
## по состоянию: WaveDirector сам печатает «проигнорировано» если
## вызов невалиден (нет активного POI и т.п.) — так дизайнер быстрее
## понимает, в каком стейте находится симуляция.
func _build_debug_tab(camp: Node) -> void:
	_header_label.text = "дебаг-читы"

	var wd: Node = get_tree().get_first_node_in_group(WaveDirector.GROUP)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(list)

	list.add_child(_build_cheat_card(
		"Старт/рестарт волн",
		"Фоновый прилив + сброс активного POI. Повторный вызов чистит живых скелетов.",
		"запустить",
		wd,
		func(): wd.cheat_start_campaign(),
	))
	list.add_child(_build_cheat_card(
		"Немедленная волна",
		"Спавн POI-волны на активный лагерь, сброс таймера. Без активного POI — лог-предупреждение.",
		"волна",
		wd,
		func(): wd.cheat_force_wave(),
	))
	list.add_child(_build_cheat_card(
		"+100 скелетов",
		"Моментальный спавн 100 скелетов uniform по safe-зонам. Не трогает фазу.",
		"спавн",
		wd,
		func(): wd.cheat_spawn_100(),
	))
	list.add_child(_build_cheat_card(
		"Stress 2000 скелетов",
		"Async-спавн 2000 скелетов по всему квадрату карты. Для замеров перфоманса в PerfHud.",
		"стресс-тест",
		wd,
		func(): wd.cheat_stress_2000(),
	))
	list.add_child(_build_cheat_card(
		"+100 каждого ресурса",
		"Накидывает 100 единиц дерева/камня/железа/еды на склад лагеря.",
		"+100",
		camp,
		func(): _grant_all_resources(camp, 100),
	))
	list.add_child(_build_cheat_card(
		"Призвать копейщиков",
		"Спавнит отряд копейщиков (×5) кольцом вокруг центра лагеря. Без затрат gatherer'ов и ресурсов, без проверки развёрнутости.",
		"копейщики",
		camp,
		func(): camp.cheat_summon_squad(&"pikeman"),
	))
	# QuestProgress — autoload, всегда есть. Передаём self как target, чтобы
	# карточка не disable'илась (логика _build_cheat_card: target == null →
	# disabled). Сам autoload в качестве target — приемлемо.
	list.add_child(_build_cheat_card(
		"Продвинуть квест",
		"Завершает текущий активный квест и разблокирует следующий. Заменяет старую клавишу Q.",
		"следующий",
		QuestProgress,
		func(): QuestProgress.advance(),
	))


## Универсальная карточка чита: заголовок + описание + кнопка. Если target
## не найден (WaveDirector не загружен / Camp нет) — кнопка disabled.
func _build_cheat_card(title: String, desc: String, btn_text: String, target: Node, action: Callable) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	card.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 4)
	hbox.add_child(info)

	var name_label := Label.new()
	name_label.text = title
	name_label.add_theme_font_size_override("font_size", 16)
	info.add_child(name_label)

	var desc_label := Label.new()
	desc_label.text = desc
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.add_theme_font_size_override("font_size", 12)
	desc_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1.0))
	desc_label.custom_minimum_size = Vector2(420, 0)
	info.add_child(desc_label)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(160, 48)
	btn.add_theme_font_size_override("font_size", 13)
	hbox.add_child(btn)

	if target == null:
		btn.text = "недоступно"
		btn.disabled = true
		_dim(card, 0.55)
	else:
		btn.text = btn_text
		btn.pressed.connect(action)

	return card


## Чит-выдача: amount каждого из 4 типов ресурсов на склад лагеря.
## Идём через add_resource — он сам эмитит resources_changed на каждый тип,
## HUD-счётчики и Camp-вкладка журнала перерисуются автоматически.
func _grant_all_resources(camp: Node, amount: int) -> void:
	if camp == null:
		return
	for type in [
		ResourcePile.ResourceType.WOOD,
		ResourcePile.ResourceType.STONE,
		ResourcePile.ResourceType.IRON,
		ResourcePile.ResourceType.FOOD,
		ResourcePile.ResourceType.PAGE,
	]:
		camp.add_resource(int(type), amount)
