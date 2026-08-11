extends CanvasLayer
## ⭐ ЕДИНЫЙ ВИДЖЕТ ЭКИПАЖА (2026-08-08). Гном — не юнит при башне, а её ПИЛОТ:
## башня едет, потому что внутри сидят гномы. Виджет и есть окно в кабину —
## ОДИН на весь экипаж, а не карточка на каждый класс.
##
## Показывает состав по классам и ровно две кнопки:
##   «Пересобрать отряд» — перестроить состав;
##   «Покинуть башню»    — экипаж выходит наружу.
## Больше на нём нет ничего осознанно: остальные глаголы гномов (режимы,
## тревога, найм) — не про пилотов.
##
## Сам виджет НИЧЕГО не решает: жмут кнопку — он эмитит сигнал, а что делать,
## знает сцена. Поэтому один и тот же узел годится и данжу, и большому миру.
##
## Разметка живёт в crew_widget.tscn (юзер двигает панель мышкой), код только
## наполняет строки состава.

signal rebuild_requested
signal leave_requested
## Экипаж снаружи и просится обратно в кабину. Отдельный сигнал, а не «leave
## наоборот»: сцена решает, можно ли сесть (близко ли башня), и виджет об этом
## правиле знать не обязан.
signal board_requested

const GROUP := &"crew_widget"

@onready var _panel: Control = $Panel
@onready var _title: Label = $Panel/Margin/Rows/Title
@onready var _crew: VBoxContainer = $Panel/Margin/Rows/Crew
@onready var _rebuild_btn: Button = $Panel/Margin/Rows/Buttons/RebuildBtn
@onready var _leave_btn: Button = $Panel/Margin/Rows/Buttons/LeaveBtn

## Прошлый состав: строки пересобираем ТОЛЬКО когда он изменился. set_crew
## зовут каждый кадр — перестраивать узлы на каждом было бы мусором на ровном месте.
var _shown: Dictionary = {}
var _shown_valid: bool = false
## В кабине или в поле. От этого зависит и заголовок, и что делает главная кнопка.
var _crewed: bool = true
## Строка подсказок под составом: снаружи она называет кнопки отряда, в кабине
## молчит (там глаголы башни, их показывает её собственный HUD).
var _hint: Label = null
## Карточки классов: id → {card, box, act, color}. Пересобираются только вместе
## с составом; каждый кадр по ним ходит лишь set_states.
var _cards: Dictionary = {}


func _ready() -> void:
	add_to_group(GROUP)
	_rebuild_btn.pressed.connect(func() -> void: rebuild_requested.emit())
	_leave_btn.pressed.connect(_on_main_pressed)
	_hint = Label.new()
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", Color(0.68, 0.72, 0.8))
	_hint.visible = false
	# Между составом и кнопками: подсказка описывает то, что рядом с ней жмут.
	_crew.get_parent().add_child(_hint)
	_crew.get_parent().move_child(_hint, _crew.get_index() + 1)


## Главная кнопка: в кабине выпускает экипаж, в поле — зовёт обратно.
func _on_main_pressed() -> void:
	if _crewed:
		leave_requested.emit()
	else:
		board_requested.emit()


## ⭐ ПЕРЕКЛЮЧЕНИЕ РЕЖИМА. Виджет один и тот же в обе стороны — меняются
## заголовок, подпись главной кнопки и подсказка. Заводить второе окно «панель
## отряда» нельзя: это тот же экипаж, просто снаружи, и два окна про один
## состав — ровно та мешанина, которую мы и разбирали.
func set_crewed(crewed: bool) -> void:
	if _crewed == crewed and _shown_valid:
		return
	_crewed = crewed
	_leave_btn.text = "Покинуть башню" if crewed else "Вернуться в башню  [E]"
	# Пересобрать состав можно только из кабины (экран сбора — её интерфейс).
	_rebuild_btn.visible = crewed
	_hint.visible = not crewed
	_shown_valid = false  # заголовок зависит от режима — перерисовать строки
	_rebuild_rows(_shown)


## Готовность способностей отряда: подсказка кнопок с живым отсчётом. Зовут
## каждый кадр — текст собираем, но пишем только при изменении.
func set_hint(text: String) -> void:
	if _hint != null and _hint.text != text:
		_hint.text = text


## Состав экипажа из живых членов отряда. Принимаем сам массив юнитов, а не
## готовые цифры: считать по soldier_type — единственный источник правды, и
## мёртвые отсеиваются здесь же (пилот, которого убили, в кабине не сидит).
func set_crew(members: Array) -> void:
	var by_type: Dictionary = {}
	for m in members:
		if not is_instance_valid(m):
			continue
		var t := StringName(str(m.get(&"soldier_type")))
		if t == &"":
			t = SoldierSystem.ROLE_WORKER
		by_type[t] = int(by_type.get(t, 0)) + 1
	if _shown_valid and by_type == _shown:
		return
	_shown = by_type
	_shown_valid = true
	_rebuild_rows(by_type)


## Кнопку «Покинуть башню» можно погасить снаружи (например, на ходу или в
## тоннеле, откуда высаживаться некуда) — виджет сам таких правил не знает.
func set_leave_enabled(on: bool) -> void:
	if _leave_btn != null:
		_leave_btn.disabled = not on


func set_rebuild_enabled(on: bool) -> void:
	if _rebuild_btn != null:
		_rebuild_btn.disabled = not on


## ⭐ КАРТОЧКА НА КЛАСС, А НЕ СТРОЧКА (2026-08-11, юзер: «где карточки, какие у
## тебя гномы с их атаками?»). Строка «● Лучники — 3» говорит, КТО есть, но
## молчит о том, ЧТО он умеет и можно ли этим жать прямо сейчас. Карточка
## отвечает на все три вопроса разом: класс, живые из скольких, его кнопка и
## готовность. Бордер белеет на готовности — телеграф на самой карточке (тот же
## приём, что у карточек данжа: полоска отката читается хуже, чем «загорелось»).
func _rebuild_rows(by_type: Dictionary) -> void:
	for c in _crew.get_children():
		c.queue_free()
	_cards.clear()
	var total: int = 0
	for id in by_type:
		total += int(by_type[id])
	_title.text = ("ЭКИПАЖ БАШНИ — %d" if _crewed else "ОТРЯД В ПОЛЕ — %d") % total
	if total <= 0:
		var empty := Label.new()
		empty.text = "экипажа нет"
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		_crew.add_child(empty)
		return
	# Порядок — как в каталоге, чтобы карточки не прыгали местами между кадрами.
	for id in SoldierSystem.SOLDIER_CATALOG:
		if not by_type.has(id):
			continue
		_cards[id] = _build_card(id, int(by_type[id]))


## Одна карточка класса. Строку способности заполняет владелец (set_states) —
## виджет не знает ни кнопок, ни откатов, он их только показывает.
func _build_card(id: StringName, alive: int) -> Dictionary:
	var data: Dictionary = SoldierSystem.get_soldier_data(id)
	var col: Color = data.get("icon_color", Color(0.85, 0.85, 0.9))
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.09, 0.09, 0.13, 0.92)
	box.border_color = col
	box.set_border_width_all(1)
	box.set_corner_radius_all(3)
	box.content_margin_left = 6.0
	box.content_margin_right = 6.0
	box.content_margin_top = 3.0
	box.content_margin_bottom = 3.0
	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_theme_stylebox_override("panel", box)
	var rows := VBoxContainer.new()
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_theme_constant_override("separation", 0)
	card.add_child(rows)
	var head := Label.new()
	head.text = "%s ×%d" % [str(data.get("name", str(id))), alive]
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_font_size_override("font_size", 13)
	head.add_theme_color_override("font_color", col)
	rows.add_child(head)
	var act := Label.new()
	act.mouse_filter = Control.MOUSE_FILTER_IGNORE
	act.add_theme_font_size_override("font_size", 11)
	act.add_theme_color_override("font_color", Color(0.72, 0.75, 0.82))
	rows.add_child(act)
	_crew.add_child(card)
	return {"card": card, "box": box, "act": act, "color": col}


## Состояния способностей: {класс: {"line": текст кнопки, "armed": готова ли}}.
## Зовут каждый кадр — трогаем только то, что изменилось.
func set_states(states: Dictionary) -> void:
	for id in _cards:
		var c: Dictionary = _cards[id]
		var st: Dictionary = states.get(id, {})
		var line: String = str(st.get("line", ""))
		var act: Label = c["act"]
		# В кабине кнопок отряда нет — строку способности прячем, а не врём ею.
		act.visible = not _crewed and line != ""
		if act.text != line:
			act.text = line
		var armed: bool = bool(st.get("armed", false))
		var box: StyleBoxFlat = c["box"]
		var want: Color = Color(1, 1, 1, 0.95) if armed else (c["color"] as Color)
		if box.border_color != want:
			box.border_color = want
			box.bg_color = Color(0.16, 0.15, 0.2, 0.95) if armed \
					else Color(0.09, 0.09, 0.13, 0.92)
