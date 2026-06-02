class_name MatchGoal
extends Node
## Условие победы матча. Один узел на main.tscn. Победа = ВСЕ условия:
##  - **Gold** ≥ [target_gold] (1000)
##  - **Tower прошёл через Gate** (с ключом — Gate сама требует ключа в башне)
##
## Подписан на EventBus.resources_changed (отслеживает gold) и
## EventBus.tower_passed_gate (отслеживает gate). На каждом из событий
## вызывается [_check_win] — если оба ✓ и ещё не победил, эмитит
## [signal EventBus.match_won]. Edge-trigger: один раз за жизнь сцены.
##
## На reload_current_scene (новая партия через StartMenu) узел пересоздаётся
## вместе со сценой — состояние сбрасывается, проверка начинает заново.

## Сколько золота нужно набрать для победы.
@export var target_gold: int = 1000

## Группа для discovery (HUD/прогрессбары).
const GROUP := &"match_goal"

var _already_won: bool = false
var _gate_passed: bool = false
## Кэш последнего известного золота — на случай если tower_passed_gate
## пришёл первым (а в resources_changed gold ещё не дошёл из-за порядка
## сигналов). Тогда _check_win по золоту из Camp читает текущее на месте.
var _last_known_gold: int = 0


func _ready() -> void:
	add_to_group(GROUP)
	EventBus.resources_changed.connect(_on_resources_changed)
	EventBus.tower_passed_gate.connect(_on_tower_passed_gate)


func get_target_gold() -> int:
	return target_gold


func get_current_gold() -> int:
	var camp := get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	if camp == null or camp.economy == null:
		return _last_known_gold
	return camp.economy.get_resource(ResourcePile.ResourceType.GOLD)


func is_gate_passed() -> bool:
	return _gate_passed


func _on_resources_changed(type: int, amount: int) -> void:
	if type != int(ResourcePile.ResourceType.GOLD):
		return
	_last_known_gold = amount
	_check_win()


func _on_tower_passed_gate() -> void:
	_gate_passed = true
	_check_win()


## Проверка обоих условий. На gold читаем актуальное из Camp (не кэш) —
## порядок resources_changed/tower_passed_gate не гарантирован, нельзя
## полагаться только на _last_known_gold.
func _check_win() -> void:
	if _already_won:
		return
	if not _gate_passed:
		return
	var current_gold: int = get_current_gold()
	if current_gold < target_gold:
		return
	_already_won = true
	if LogConfig.master_enabled:
		print("[MatchGoal] победа: GOLD=%d ≥ %d И gate_passed" % [current_gold, target_gold])
	EventBus.match_won.emit()
