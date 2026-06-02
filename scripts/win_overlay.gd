class_name WinOverlay
extends CanvasLayer
## Оверлей победы. Подписан на EventBus.match_won, показывает золотую
## панель с одной кнопкой «Новая партия». Кнопка делает то же что
## StartMenu.«Начать игру» — генерирует новые случайные позиции
## Tower/POI, ставит [MatchConfig.match_started]=true и reload'ит сцену.
##
## Esc игнорируется — оверлей модальный, выйти можно только клавишей или
## кликом по кнопке. Игрок продолжает видеть игровое поле сквозь
## полупрозрачную панель.

const GROUP := &"win_overlay"

@onready var _root: Control = $Root
@onready var _btn_restart: Button = $Root/Panel/VBox/RestartButton


func _ready() -> void:
	add_to_group(GROUP)
	_root.visible = false
	_btn_restart.pressed.connect(_on_restart_pressed)
	EventBus.match_won.connect(_on_match_won)


func _on_match_won() -> void:
	_show()


func _show() -> void:
	_root.visible = true
	_btn_restart.grab_focus()


## Reuse логики StartMenu — найти его в группе и дёрнуть restart. Так нет
## дублирования кода random-pick и reload'а; StartMenu — single source of
## truth для match-restart flow.
func _on_restart_pressed() -> void:
	var menu: StartMenu = get_tree().get_first_node_in_group(StartMenu.GROUP) as StartMenu
	if menu != null:
		menu.restart_match()
		return
	# Fallback если StartMenu не найден — просто reload без рандомизации.
	MatchConfig.match_started = true
	QuestProgress.current_index = 0
	get_tree().reload_current_scene()
