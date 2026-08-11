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


func _ready() -> void:
	add_to_group(GROUP)
	_rebuild_btn.pressed.connect(func() -> void: rebuild_requested.emit())
	_leave_btn.pressed.connect(_on_main_pressed)
	# Список состава прячем НАВСЕГДА: кто есть и сколько живых, показывает общий
	# ряд карточек (SquadCards) — тот же, что в подземелье. Держать здесь второй
	# список про тот же отряд незачем, виджет остаётся про ДЕЙСТВИЯ.
	_crew.visible = false


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
	_shown_valid = false  # заголовок зависит от режима — перерисовать
	_rebuild_rows(_shown)


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


## Заголовок = сводка: сколько всего пилотов и где они. Разбивка по классам —
## на карточках, здесь её намеренно нет (один состав в двух местах = каша).
func _rebuild_rows(by_type: Dictionary) -> void:
	var total: int = 0
	for id in by_type:
		total += int(by_type[id])
	_title.text = ("ЭКИПАЖ БАШНИ — %d" if _crewed else "ОТРЯД В ПОЛЕ — %d") % total
