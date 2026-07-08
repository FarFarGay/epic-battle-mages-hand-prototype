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
## - fire_recipe_found: древний рецепт из пещеры доставлен в институт →
##   Кафедра огня доступна в палитре (гейт HUD).
var building_unlocked: bool = false
var stone_thrower_defeated: bool = false
var fire_recipe_found: bool = false


func _ready() -> void:
	add_to_group(GROUP)


## Открыть знание о постройках (idempotent). Зовёт BlueprintMachine на запуске
## станка. HUD/диалоги читают флаг поллингом (prof.get(&"building_unlocked")).
func unlock_building() -> void:
	building_unlocked = true


## Отметить победу над камнеметателем (idempotent) — открывает найм лучников Room6.
func mark_stone_thrower_defeated() -> void:
	stone_thrower_defeated = true


## Рецепт Огненного выстрела изучен институтом (idempotent) — зовёт
## GearElement._on_delivered; HUD-палитра читает флаг поллингом.
func unlock_fire_recipe() -> void:
	fire_recipe_found = true


func is_signed() -> bool:
	return not player_name.strip_edges().is_empty()


func sign_name(n: String) -> void:
	player_name = n.strip_edges()


## Имя если подписано, иначе default (для {name} до подписи Хартии).
func display_name(default_name: String) -> String:
	return player_name if is_signed() else default_name
