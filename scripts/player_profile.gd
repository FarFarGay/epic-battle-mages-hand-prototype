extends Node
## Профиль игрока: имя, которое он вписал в Торговую Хартию гномов. После подписи
## гномы обращаются по нему (DialogUI подставляет плейсхолдер {name}). Узел в сцене,
## ищется через группу GROUP.

const GROUP := &"player_profile"

var player_name: String = ""

## Прогресс-флаги гномов-строителей (Room6). Живут здесь — это singleton'-узел
## прогресса игрока, до которого диалоги/HUD уже дотягиваются через GROUP.
## - building_unlocked: запущен станок в Room11 → меню стен/башен открыто.
## - stone_thrower_defeated: убит камнеметатель → у гномов Room6 доступен найм лучников.
var building_unlocked: bool = false
var stone_thrower_defeated: bool = false


func _ready() -> void:
	add_to_group(GROUP)


## Открыть знание о постройках (idempotent). Зовёт BlueprintMachine на запуске
## станка; эмитит EventBus один раз — HUD разблокирует меню.
func unlock_building() -> void:
	if building_unlocked:
		return
	building_unlocked = true
	EventBus.building_unlocked.emit()


## Отметить победу над камнеметателем (idempotent) — открывает найм лучников Room6.
func mark_stone_thrower_defeated() -> void:
	stone_thrower_defeated = true


func is_signed() -> bool:
	return not player_name.strip_edges().is_empty()


func sign_name(n: String) -> void:
	player_name = n.strip_edges()


## Имя если подписано, иначе default (для {name} до подписи Хартии).
func display_name(default_name: String) -> String:
	return player_name if is_signed() else default_name
