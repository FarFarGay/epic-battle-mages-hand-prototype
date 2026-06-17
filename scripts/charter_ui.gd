extends CanvasLayer
## Документ «Торговая Хартия гномов» — забавная награда вместо золота. Показывает
## правила добросовестной торговли (стиль гном-Остин-Пауэрс) + поле подписи: игрок
## вписывает имя. На подписи — кладём имя в PlayerProfile (гномы будут так обращаться)
## и закрываем. Игра на паузе пока открыт (UI работает на паузе).

const GROUP := &"charter_ui"

signal signed(player_name: String)

@onready var _root: Control = $Root
@onready var _name_edit: LineEdit = $Root/Panel/Margin/VBox/SignRow/NameEdit
@onready var _sign_btn: Button = $Root/Panel/Margin/VBox/ButtonRow/SignButton
@onready var _cancel_btn: Button = $Root/Panel/Margin/VBox/ButtonRow/CancelButton

var _open: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	process_mode = Node.PROCESS_MODE_ALWAYS  # документ живёт на паузе
	_root.visible = false
	_sign_btn.pressed.connect(_on_sign)
	_cancel_btn.pressed.connect(close)
	_name_edit.text_submitted.connect(func(_t: String) -> void: _on_sign())


func is_open() -> bool:
	return _open


func open() -> void:
	if _open:
		return
	_open = true
	_root.visible = true
	get_tree().paused = true
	_name_edit.text = ""
	_name_edit.grab_focus()


func close() -> void:
	if not _open:
		return
	_open = false
	_root.visible = false
	get_tree().paused = false


func _on_sign() -> void:
	var n: String = _name_edit.text.strip_edges()
	if n.is_empty():
		return  # без имени не подписываем
	var prof := get_tree().get_first_node_in_group(&"player_profile")
	if prof != null and prof.has_method(&"sign_name"):
		prof.call(&"sign_name", n)
	signed.emit(n)
	close()
