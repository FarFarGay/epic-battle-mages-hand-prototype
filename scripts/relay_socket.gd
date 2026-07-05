class_name RelaySocket
extends RedDiode
## Гнездо-разрыв цепи (пазл Room3): наследует у [RedDiode] провод от синего диода
## и бусину тока, но НЕ включает рычаг — решает, идёт ли ток ДАЛЬШЕ.
## Пустое гнездо: бусина добегает → разряд-пшик, цепь сбрасывается (синий диод
## reset → можно бить Искрой снова, софтлока нет). Вставлен ретранслятор
## ([RelayItem] рукой) → ток проходит насквозь: target_path.activate() (красный
## диод строит СВОЙ сегмент от гнезда — цепь из двух кусков).

## Куда слать ток, когда ретранслятор на месте (обычно красный диод).
@export var target_path: NodePath
## Высота посадки кристалла над центром гнезда.
@export var seat_height: float = 0.4

var _seated: bool = false
var _relay: Node3D = null


func _ready() -> void:
	super()
	add_to_group(&"relay_socket")


## Ретранслятор сел в гнездо (зовёт RelayItem). Группа relay_seated — маркер
## «разрыв закрыт» для внешних читателей (TutorialHint suppress_group и т.п.).
func seat(item: Node3D) -> void:
	_seated = true
	_relay = item
	add_to_group(&"relay_seated")


func unseat() -> void:
	_seated = false
	_relay = null
	remove_from_group(&"relay_seated")


func is_seated() -> bool:
	return _seated


## Куда защёлкивается кристалл (глобально).
func seat_transform() -> Transform3D:
	return Transform3D(global_transform.basis.orthonormalized(),
		global_position + Vector3.UP * seat_height)


## Бусина добежала до гнезда. Вместо включения рычага (база) — ветвление цепи.
func _on_current_arrived() -> void:
	if _seated:
		if _material != null:
			_material.albedo_color = live_color
			_material.emission = live_color
			_material.emission_energy_multiplier = 5.0
		if _relay != null and is_instance_valid(_relay) and _relay.has_method(&"on_current_pass"):
			_relay.call(&"on_current_pass")
		var target := get_node_or_null(target_path)
		if target != null and target.has_method(&"activate"):
			target.call(&"activate")
		elif not target_path.is_empty():
			push_warning("[RelaySocket] target_path не разрешён/без activate(): %s (%s)" % [target_path, name])
		return
	# Пусто: ток ушёл в землю. Пшик + откат сегмента и синего диода — ударная
	# Искра не «сгорает», игрок может замкнуть цепь и попробовать снова.
	AoeVisual.spawn_pulse_sparks(get_tree().current_scene, global_position + Vector3.UP * 0.3, 1.2, 8.0)
	_energized = false
	if _wire_material != null:
		_wire_material.albedo_color = idle_color
		_wire_material.emission = idle_color
		_wire_material.emission_energy_multiplier = 0.4
	var blue := get_node_or_null(wire_from_path)
	if blue != null and blue.has_method(&"reset"):
		blue.call(&"reset")
