extends Node
## Прогресс сюжетных заданий. Регистрируется как autoload (`QuestProgress`).
##
## Линейная цепочка квестов: `current_index` указывает на активного актора.
## Все акторы с `quest_order < current_index` — completed (квест выполнен),
## с `quest_order == current_index` — active (квест выдан, можно сдать),
## с `quest_order > current_index` — locked (ещё не разблокирован).
##
## Продвижение прогресса:
## - debug-вход «Q» (action `complete_quest`) — продвигает на 1 шаг вперёд;
##   используется до появления нормальной механики сдачи квеста.
## - программный вызов `advance()` — для будущих геймплейных триггеров.
##
## Сигнал о смене состояния идёт через EventBus (`quest_advanced`), чтобы
## подписчиков (QuestActor, HUD, …) было удобно цеплять без знания о наличии
## именно этого autoload-а.

var current_index: int = 0


func is_active(order: int) -> bool:
	return order == current_index


func is_completed(order: int) -> bool:
	return order < current_index


func is_locked(order: int) -> bool:
	return order > current_index


func advance() -> void:
	current_index += 1
	if LogConfig.master_enabled:
		print("[QuestProgress] продвижение → current_index=%d" % current_index)
	EventBus.quest_advanced.emit(current_index)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("complete_quest"):
		advance()
