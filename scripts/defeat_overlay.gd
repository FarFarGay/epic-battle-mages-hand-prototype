class_name DefeatOverlay
extends CanvasLayer
## Оверлей поражения. Подписан на EventBus.match_lost, показывает тёмно-красную
## панель с одной кнопкой «Новая партия». Зеркало [WinOverlay]: кнопка делает то
## же, что StartMenu.«Начать игру» — рандомит позиции Tower/POI, ставит
## [MatchConfig.match_started]=true и reload'ит сцену.
##
## Esc игнорируется — оверлей модальный. Игрок видит поле сквозь полупрозрачную
## панель. Сейчас единственное условие поражения — разрушение ядра (харвестера),
## см. MatchGoal._on_harvester_destroyed.

const GROUP := &"defeat_overlay"

@onready var _root: Control = $Root
@onready var _subtitle: Label = $Root/Panel/VBox/Subtitle
@onready var _btn_restart: Button = $Root/Panel/VBox/RestartButton


func _ready() -> void:
	add_to_group(GROUP)
	# Работаем НА ПАУЗЕ: поражение замораживает игру (get_tree().paused), но
	# панель и кнопка рестарта должны принимать ввод.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root.visible = false
	_btn_restart.pressed.connect(_on_restart_pressed)
	EventBus.match_lost.connect(_on_match_lost)


## reason — причина поражения (ядро / башня), идёт в подзаголовок панели.
func _on_match_lost(reason: String) -> void:
	if _subtitle != null and reason != "":
		_subtitle.text = reason
	_show()
	# Замораживаем игру за оверлеем. Снимется на рестарте (StartMenu.restart_match).
	get_tree().paused = true


func _show() -> void:
	_root.visible = true
	_btn_restart.grab_focus()


## Показан ли оверлей (для StartMenu — не открывать паузу-меню поверх финала).
func is_showing() -> bool:
	return _root != null and _root.visible


## Reuse логики StartMenu — single source of truth для match-restart flow.
func _on_restart_pressed() -> void:
	var menu: StartMenu = get_tree().get_first_node_in_group(StartMenu.GROUP) as StartMenu
	if menu != null:
		menu.restart_match()
		return
	# Fallback если StartMenu не найден — просто reload без рандомизации.
	# paused живёт на SceneTree и переживает reload — иначе новый матч стартует
	# замёрзшим (поражение ставит paused=true).
	get_tree().paused = false
	MatchConfig.match_started = true
	QuestProgress.current_index = 0
	get_tree().reload_current_scene()
