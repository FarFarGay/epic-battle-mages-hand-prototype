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


func _ready() -> void:
	add_to_group(GROUP)
	_rebuild_btn.pressed.connect(func() -> void: rebuild_requested.emit())
	_leave_btn.pressed.connect(func() -> void: leave_requested.emit())


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


func _rebuild_rows(by_type: Dictionary) -> void:
	for c in _crew.get_children():
		c.queue_free()
	var total: int = 0
	for id in by_type:
		total += int(by_type[id])
	_title.text = "ЭКИПАЖ БАШНИ — %d" % total
	if total <= 0:
		var empty := Label.new()
		empty.text = "пусто"
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		_crew.add_child(empty)
		return
	# Порядок строк — как в каталоге, чтобы состав не прыгал между кадрами.
	for id in SoldierSystem.SOLDIER_CATALOG:
		if not by_type.has(id):
			continue
		var data: Dictionary = SoldierSystem.get_soldier_data(id)
		var row := Label.new()
		row.text = "● %s — %d" % [str(data.get("name", str(id))), int(by_type[id])]
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_font_size_override("font_size", 13)
		row.add_theme_color_override("font_color",
				data.get("icon_color", Color(0.85, 0.85, 0.9)))
		_crew.add_child(row)
