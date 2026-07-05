class_name TutorialHint
extends Area3D
## Обучающая подсказка: по триггеру шлёт [signal EventBus.tutorial_hint], HUD
## показывает плашку внизу экрана на duration секунд. Один скрипт на все виды
## триггеров — параметризуется trigger_mode: зона въезда башни (ZONE) /
## первая набранная мана (MANA_GAINED) / порог текущей маны (MANA_AT_LEAST) /
## в watch_group появился узел (GROUP_APPEARS — «шаг пазла сделан, вот следующий») /
## watch_group ОПУСТЕЛА (GROUP_EMPTIED — «врага/препятствия не стало»: ждёт,
## пока группа непуста, стреляет на опустение — на старте без группы не срабатывает).
## Одноразовая: сработала → queue_free.

enum Trigger { ZONE, MANA_GAINED, MANA_AT_LEAST, GROUP_APPEARS, GROUP_EMPTIED }

## Слой башни (Tower.collision_layer = 4) — зона реагирует только на неё.
const TOWER_LAYER := 4

@export_multiline var text: String = ""
## Сколько секунд плашка висит на HUD.
@export var duration: float = 6.0
@export var trigger_mode: Trigger = Trigger.ZONE
## Для ZONE: полный размер триггер-бокса (Y с запасом — башня высокая).
@export var zone_size: Vector3 = Vector3(8, 8, 8)
## Для MANA_AT_LEAST: порог текущей маны башни.
@export var mana_threshold: float = 50.0
## Если в этой группе есть хоть один узел — подсказка НЕ показывается и снимается
## (условие уже выполнено: например, «нужен мост» глушится группой bridge_snapped).
@export var suppress_group: StringName = &""
## Для GROUP_APPEARS: стреляем, когда в этой группе появляется хоть один узел
## (маркер выполненного шага, напр. relay_seated).
@export var watch_group: StringName = &""


func _ready() -> void:
	match trigger_mode:
		Trigger.ZONE:
			collision_layer = 0
			collision_mask = TOWER_LAYER
			monitoring = true
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = zone_size
			shape.shape = box
			add_child(shape)
			body_entered.connect(_on_body_entered)
		Trigger.MANA_GAINED, Trigger.MANA_AT_LEAST:
			# Мана-триггеры зоной не пользуются — подписка на шину до самосноса.
			monitoring = false
			EventBus.tower_mana_changed.connect(_on_mana_changed)
		Trigger.GROUP_APPEARS, Trigger.GROUP_EMPTIED:
			# Сигналов «узел вошёл в группу / группа опустела» у движка нет —
			# дешёвый поллинг таймером. Timer-нода умирает вместе с подсказкой.
			monitoring = false
			var poll := Timer.new()
			poll.wait_time = 0.3
			poll.autostart = true
			add_child(poll)
			poll.timeout.connect(_check_watch_group)


func _on_body_entered(body: Node3D) -> void:
	if body is Tower:
		_fire()


## Был ли watch_group непустым хоть раз (для GROUP_EMPTIED: стреляем на переход
## «был → не стало», а не на пустоту со старта сцены).
var _group_was_present: bool = false


func _check_watch_group() -> void:
	if watch_group == &"":
		return
	var present: bool = get_tree().get_first_node_in_group(watch_group) != null
	if trigger_mode == Trigger.GROUP_APPEARS:
		if present:
			_fire()
		return
	if present:
		_group_was_present = true
	elif _group_was_present:
		_fire()


func _on_mana_changed(current: float, _maximum: float) -> void:
	if trigger_mode == Trigger.MANA_GAINED and current > 0.0:
		_fire()
	elif trigger_mode == Trigger.MANA_AT_LEAST and current >= mana_threshold:
		_fire()


func _fire() -> void:
	if suppress_group != &"" and get_tree().get_first_node_in_group(suppress_group) != null:
		# Условие подсказки уже выполнено игроком — молча самоснимаемся.
		set_deferred("monitoring", false)
		if EventBus.tower_mana_changed.is_connected(_on_mana_changed):
			EventBus.tower_mana_changed.disconnect(_on_mana_changed)
		queue_free()
		return
	EventBus.tutorial_hint.emit(text, duration)
	# queue_free отложен до конца кадра — сигнальные подписки Area рвутся сами
	# при выходе из дерева. Прямое monitoring=false внутри body_entered запрещено
	# физикой (in/out signal) — только deferred.
	set_deferred("monitoring", false)
	if EventBus.tower_mana_changed.is_connected(_on_mana_changed):
		EventBus.tower_mana_changed.disconnect(_on_mana_changed)
	queue_free()
