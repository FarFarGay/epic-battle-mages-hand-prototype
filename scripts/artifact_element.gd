class_name ArtifactElement
extends RelayItem
## Артефакт-находка вылазки (сюжет «Верхний Предел»): переносной предмет,
## который ДОСТАВЛЯЕТСЯ к зданию-приёмнику города по роли каталога
## ([deliver_role]), а не в сокет — сокет-снап RelayItem здесь выключен.
## Положил (или уронил) артефакт рядом со зданием → доводка-всасывание
## (паттерн CastleFoundation.seat) → [_on_delivered] → queue_free.
##
## Наследники задают deliver_role + визуал + эффект доставки:
##   Рецепт (пещера гномов)     → институт («magic»): открывает Кафедру огня.
##   Аккумулятор (храм-каньон)  → институт («magic»): Молния + Огненный шквал.
##   Звёздный кристалл (застава) → док («unload»): клад — монеты в казну.

## Роль здания-приёмника (ключ "role" каталога RoomBuildings).
@export var deliver_role: StringName = &"magic"
## Радиус доставки (XZ до центра здания).
@export var deliver_radius: float = 4.0
## Подсказка при ПЕРВОМ подборе рукой: что это и куда нести (наследники задают).
@export var pickup_hint: String = ""

var _held: bool = false
var _delivered: bool = false
var _hint_shown: bool = false


func _ready() -> void:
	super()
	# Артефакт можно везти на верхушке башни («верх башни = инвентарь»,
	# паркует MountSlot); с борта у здания-приёмника всасывается сам.
	add_to_group(&"tower_cargo")
	var poll := Timer.new()
	poll.wait_time = 0.5
	poll.autostart = true
	add_child(poll)
	poll.timeout.connect(_poll_delivery)


## Сокет-снап RelayItem ВЫКЛЮЧЕН: артефакт не садится в гнёзда цепей.
func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item == self:
		_held = false


func _on_hand_grabbed(item: Node3D) -> void:
	if item != self:
		return
	_held = true
	collision_layer = Layers.ITEMS
	if _snap_tween != null and _snap_tween.is_valid():
		_snap_tween.kill()
	_snap_tween = null
	if not _hint_shown and pickup_hint != "":
		_hint_shown = true
		EventBus.tutorial_hint.emit(pickup_hint, 9.0)


## Наследник может запретить доставку в моменте (гном-носильщик и т.п.).
func _delivery_blocked() -> bool:
	return false


func _poll_delivery() -> void:
	if _delivered or _held or _delivery_blocked():
		return
	var receiver := _nearest_receiver()
	if receiver == null:
		return
	if _xz_dist(receiver.global_position, global_position) > deliver_radius:
		return
	_deliver(receiver)


## Ближайшее здание города с ролью deliver_role.
func _nearest_receiver() -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	for n in get_tree().get_nodes_in_group(&"pad_building"):
		if not (n is Node3D) or not is_instance_valid(n):
			continue
		if n.get(&"_role") != deliver_role:
			continue
		var d: float = (n as Node3D).global_position.distance_squared_to(global_position)
		if d < best_d:
			best_d = d
			best = n
	return best


## Всасывание в здание: доводка вверх-внутрь → FX → эффект наследника → удаление.
func _deliver(receiver: Node3D) -> void:
	_delivered = true
	# Выход из группы груза = сигнал MountSlot отпустить пин (везли на борту).
	remove_from_group(&"tower_cargo")
	freeze = true
	collision_layer = 0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	var tw := create_tween()
	tw.tween_property(self, "global_position",
		receiver.global_position + Vector3.UP * 1.6, 0.5) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position, 1.4, 10.0)
		EventBus.camera_shake.emit(0.25, global_position)
		_on_delivered(receiver)
		queue_free())


## Эффект доставки — наследники обязаны переопределить.
func _on_delivered(_receiver: Node3D) -> void:
	pass


func _xz_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
