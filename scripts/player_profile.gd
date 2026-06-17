extends Node
## Профиль игрока: имя, которое он вписал в Торговую Хартию гномов. После подписи
## гномы обращаются по нему (DialogUI подставляет плейсхолдер {name}). Узел в сцене,
## ищется через группу GROUP.

const GROUP := &"player_profile"

var player_name: String = ""


func _ready() -> void:
	add_to_group(GROUP)


func is_signed() -> bool:
	return not player_name.strip_edges().is_empty()


func sign_name(n: String) -> void:
	player_name = n.strip_edges()


## Имя если подписано, иначе default (для {name} до подписи Хартии).
func display_name(default_name: String) -> String:
	return player_name if is_signed() else default_name
