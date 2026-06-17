extends CanvasLayer
## Диалоговое окно (с нуля). open(data, start) показывает узел диалога: текст реплики
## + кнопки-ветки. Выбор ветки → опциональный эффект (signal effect_selected) +
## переход к next-узлу или закрытие. Пока открыт — игра на ПАУЗЕ (как StartMenu),
## сам UI работает на паузе (PROCESS_MODE_ALWAYS).
##
## Формат данных (Dictionary узлов):
##   {
##     &"<node_id>": {
##       "text": "реплика",
##       "choices": [
##         { "label": "текст кнопки", "next": &"<node_id>" | &"", "effect": &"<id>" (опц.) },
##         ...
##       ],
##     },
##     ...
##   }
## next пустой / нет такого узла → закрыть. effect (если задан) эмитится в effect_selected.

const GROUP := &"dialog_ui"

## Выбрана ветка с эффектом — слушатель (поселение/квест-логика) реагирует.
signal effect_selected(effect_id: StringName)

@onready var _root: Control = $Root
@onready var _text: Label = $Root/Panel/Margin/VBox/Text
@onready var _choices: VBoxContainer = $Root/Panel/Margin/VBox/Choices

var _data: Dictionary = {}
var _open: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS  # UI живёт на паузе
	_root.visible = false


func is_open() -> bool:
	return _open


## Открыть диалог с данными data, начиная с узла start_node. Ставит игру на паузу.
func open(data: Dictionary, start_node: StringName) -> void:
	if _open:
		return
	_data = data
	_open = true
	_root.visible = true
	get_tree().paused = true
	_show_node(start_node)


func close() -> void:
	if not _open:
		return
	_open = false
	_root.visible = false
	get_tree().paused = false


func _show_node(node_id: StringName) -> void:
	var node: Dictionary = _data.get(node_id, {})
	if node.is_empty():
		close()
		return
	_text.text = _apply_name(String(node.get("text", "")))
	for c in _choices.get_children():
		c.queue_free()
	var choices: Array = node.get("choices", [])
	for choice in choices:
		if not _req_met(choice.get("req", &"")):
			continue  # ветка скрыта по условию (signed / unsigned)
		var btn := Button.new()
		btn.text = String(choice.get("label", "..."))
		btn.custom_minimum_size = Vector2(0, 36)
		btn.add_theme_font_size_override("font_size", 16)
		btn.pressed.connect(_on_choice.bind(choice))
		_choices.add_child(btn)


## Условие показа ветки: &"signed" — только после подписи Хартии, &"unsigned" — только
## до, пусто — всегда. Статус берём из PlayerProfile.
func _req_met(req: StringName) -> bool:
	if req == &"":
		return true
	var prof := get_tree().get_first_node_in_group(&"player_profile")
	var signed: bool = prof != null and prof.has_method(&"is_signed") and prof.call(&"is_signed")
	if req == &"signed":
		return signed
	if req == &"unsigned":
		return not signed
	return true


## Подставляет имя игрока вместо {name} (из PlayerProfile; до подписи Хартии — «чужак»).
func _apply_name(text: String) -> String:
	if not text.contains("{name}"):
		return text
	var prof := get_tree().get_first_node_in_group(&"player_profile")
	var nm: String = "чужак"
	if prof != null and prof.has_method(&"display_name"):
		nm = prof.call(&"display_name", "чужак")
	return text.replace("{name}", nm)


func _on_choice(choice: Dictionary) -> void:
	var effect: StringName = choice.get("effect", &"")
	if effect != &"":
		effect_selected.emit(effect)
	var nxt: StringName = choice.get("next", &"")
	if nxt == &"" or not _data.has(nxt):
		close()
	else:
		_show_node(nxt)
