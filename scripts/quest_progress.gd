extends Node
## Прогресс сюжетных заданий. Регистрируется как autoload (`QuestProgress`).
##
## Линейная цепочка квестов: `current_index` указывает на активного актора.
## Все акторы с `quest_order < current_index` — completed (квест выполнен),
## с `quest_order == current_index` — active (квест выдан, можно сдать),
## с `quest_order > current_index` — locked (ещё не разблокирован).
##
## Продвижение прогресса:
## - программный вызов `advance()` — для геймплейных триггеров;
## - дебаг-кнопка «Продвинуть квест» во вкладке «Читы» Журнала — фоллбэк
##   до появления нормальной механики сдачи.
##
## Сигнал о смене состояния идёт через EventBus (`quest_advanced`), чтобы
## подписчиков (QuestActor, JournalPanel, HUD, …) было удобно цеплять без
## знания о наличии именно этого autoload-а.
##
## **Каталог квестов хранится на сцене**, не здесь: каждый QuestActor
## декларирует свои `quest_title` / `quest_description` экспортами. Журнал
## опрашивает группу `QuestActor.POI_GROUP`, сортирует по `quest_order`,
## рендерит карточки. Так не дублируем источник истины (сцена+скрипт=пакет).

enum State { LOCKED, ACTIVE, COMPLETED }

var current_index: int = 0


func is_active(order: int) -> bool:
	return order == current_index


func is_completed(order: int) -> bool:
	return order < current_index


func is_locked(order: int) -> bool:
	return order > current_index


## Состояние квеста как enum — удобнее для UI чем три отдельных проверки.
func get_state(order: int) -> int:
	if order < current_index:
		return State.COMPLETED
	if order == current_index:
		return State.ACTIVE
	return State.LOCKED


func advance() -> void:
	current_index += 1
	if LogConfig.master_enabled:
		print("[QuestProgress] продвижение → current_index=%d" % current_index)
	EventBus.quest_advanced.emit(current_index)


## Helper для UI: все QuestActor'ы со сцены, отсортированные по quest_order
## (LOCKED/ACTIVE/COMPLETED — все, журнал сам решает как отобразить).
## Требует доступа к SceneTree — autoload передаёт свой `get_tree()`.
func get_actors_sorted() -> Array:
	var actors: Array = []
	for n in get_tree().get_nodes_in_group(QuestActor.POI_GROUP):
		if n is QuestActor:
			actors.append(n)
	actors.sort_custom(func(a: QuestActor, b: QuestActor) -> bool:
		return a.quest_order < b.quest_order)
	return actors
