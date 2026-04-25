class_name Camp
extends Node3D
## Лагерь — модуль каравана+развёртки. Цепочка из 4 палаток-StaticBody3D
## следует за башней (CARAVAN_FOLLOWING) и по hold-инпуту разворачивается в
## кольцо вокруг точки остановки башни (DEPLOYED), превращая палатки в
## твёрдые препятствия для самой башни.
##
## Состояния:
## - CARAVAN_FOLLOWING — палатки тянутся «змейкой» за башней. Hold R с условием
##   «башня стоит» ≥ deploy_duration разворачивает лагерь.
## - DEPLOYED — палатки lerp'ом смещаются на точки кольца радиуса deploy_radius
##   вокруг _deploy_anchor. Hold R ≥ pack_duration сворачивает (без
##   stationary-проверки).
##
## Коллизии: палатки всегда на слое CampObstacle (6, бит 5). Tower.mask=31
## не включает этот бит → башня проходит сквозь палатки в любом состоянии.
## Skeleton.mask=55 включает его → скелеты упираются в палатки и в каравне,
## и в развёрнутом лагере. Никакого рантайм-toggle коллизии нет.
##
## Зависит только от Tower через target_path. Локальные сигналы deployed/packed
## ре-эмитятся в EventBus для UI / звука / статистики.
##
## Заметка по реализации: enum формально содержит DEPLOYING/PACKING для
## расширения, но в текущем коде используются только CARAVAN_FOLLOWING и
## DEPLOYED — hold-таймер растёт прямо в них, отдельные «промежуточные»
## состояния не нужны.

signal deployed(anchor: Vector3)
signal packed

enum State { CARAVAN_FOLLOWING, DEPLOYING, DEPLOYED, PACKING }

@export_node_path("Node3D") var target_path: NodePath
## Коэффициент lerp при следовании палаток за лидером (башней или предыдущей палаткой).
@export var follow_speed: float = 4.0
## Расстояние между палатками в цепочке и между башней и parts[0].
@export var part_gap: float = 2.5
## За этим порогом ведущая палатка перестаёт двигаться (башня «ушла далеко»).
@export var follow_max_distance: float = 30.0
## Секунды зажатой R + неподвижности башни для развёртки.
@export var deploy_duration: float = 3.0
## Секунды зажатой R для свёртки (stationary не требуется).
@export var pack_duration: float = 4.0
## Радиус кольца, на которое расставляются палатки вокруг anchor.
@export var deploy_radius: float = 4.0
## Порог горизонтальной скорости башни, ниже которого считаем её стоящей.
@export var stationary_speed_threshold: float = 0.5
@export var debug_log: bool = true

var _tower: CharacterBody3D
var _state: State = State.CARAVAN_FOLLOWING
var _parts: Array[StaticBody3D] = []
## Таймер удержания R. Сбрасывается при отпускании, при потере stationary в
## CARAVAN_FOLLOWING и на фронте начала/завершения действия.
var _hold_progress: float = 0.0
var _deploy_anchor: Vector3 = Vector3.ZERO
var _deployed_targets: Array[Vector3] = []

# Логирование (фронт-триггеры, чтобы не спамить каждый кадр).
var _was_holding_stationary: bool = false
var _was_out_of_range: bool = false


func _ready() -> void:
	if not target_path.is_empty():
		_tower = get_node_or_null(target_path) as CharacterBody3D
	if not _tower:
		push_warning("Camp: target_path не разрешился, башня не задана")

	for child in get_children():
		if child is StaticBody3D:
			_parts.append(child as StaticBody3D)

	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	deployed.connect(func(anchor: Vector3) -> void: EventBus.camp_deployed.emit(anchor))
	packed.connect(func() -> void: EventBus.camp_packed.emit())


func _process(delta: float) -> void:
	_handle_input(delta)
	match _state:
		State.CARAVAN_FOLLOWING, State.DEPLOYING, State.PACKING:
			_update_caravan_follow(delta)
		State.DEPLOYED:
			_update_deployed(delta)


# --- Ввод / переходы состояний ---

func _handle_input(delta: float) -> void:
	if not Input.is_action_pressed("camp_toggle"):
		if _hold_progress > 0.0 and debug_log and LogConfig.master_enabled and _was_holding_stationary:
			print("[Camp] отсчёт прерван (отпущена R)")
		_hold_progress = 0.0
		_was_holding_stationary = false
		return

	match _state:
		State.CARAVAN_FOLLOWING:
			if _is_tower_stationary():
				if not _was_holding_stationary:
					if debug_log and LogConfig.master_enabled:
						print("[Camp] начат отсчёт развёртки")
					_was_holding_stationary = true
				_hold_progress += delta
				if _hold_progress >= deploy_duration:
					_start_deploy()
			else:
				if _was_holding_stationary and debug_log and LogConfig.master_enabled:
					print("[Camp] отсчёт прерван (башня поехала)")
				_hold_progress = 0.0
				_was_holding_stationary = false
		State.DEPLOYED:
			_hold_progress += delta
			if _hold_progress >= pack_duration:
				_start_pack()
		_:
			pass


func _is_tower_stationary() -> bool:
	if _tower == null:
		return false
	return Vector2(_tower.velocity.x, _tower.velocity.z).length() < stationary_speed_threshold


func _start_deploy() -> void:
	_state = State.DEPLOYED
	_deploy_anchor = _tower.global_position
	_deployed_targets.clear()
	var count := _parts.size()
	for i in range(count):
		var angle := float(i) * TAU / float(maxi(count, 1))
		var part_y: float = _parts[i].global_position.y
		var target := Vector3(
			_deploy_anchor.x + cos(angle) * deploy_radius,
			part_y,
			_deploy_anchor.z + sin(angle) * deploy_radius,
		)
		_deployed_targets.append(target)
	_hold_progress = 0.0
	_was_holding_stationary = false
	if debug_log and LogConfig.master_enabled:
		print("[Camp] лагерь развёрнут @ (%.1f, %.1f, %.1f)" % [_deploy_anchor.x, _deploy_anchor.y, _deploy_anchor.z])
	deployed.emit(_deploy_anchor)


func _start_pack() -> void:
	_state = State.CARAVAN_FOLLOWING
	_hold_progress = 0.0
	_was_holding_stationary = false
	if debug_log and LogConfig.master_enabled:
		print("[Camp] лагерь свёрнут")
	packed.emit()


# --- Движение палаток ---

func _update_caravan_follow(delta: float) -> void:
	if _tower == null or _parts.is_empty():
		return

	var lead_dist: float = _parts[0].global_position.distance_to(_tower.global_position)
	var leader_too_far := lead_dist > follow_max_distance

	if debug_log and LogConfig.master_enabled and leader_too_far != _was_out_of_range:
		if leader_too_far:
			print("[Camp] башня вне зоны видимости (dist=%.1f)" % lead_dist)
		else:
			print("[Camp] башня вернулась в зону видимости (dist=%.1f)" % lead_dist)
		_was_out_of_range = leader_too_far

	for i in range(_parts.size()):
		var part := _parts[i]
		var leader_pos: Vector3 = _tower.global_position if i == 0 else _parts[i - 1].global_position

		# Ведущая палатка стоит, если башня ушла за порог. Остальные всё равно
		# подтягиваются к своему (стоящему) лидеру — цепочка собирается.
		if i == 0 and leader_too_far:
			continue

		var to_leader := leader_pos - part.global_position
		to_leader.y = 0.0
		if to_leader.length_squared() < VecUtil.EPSILON_SQ:
			continue
		var dir := to_leader.normalized()
		var target_pos := leader_pos - dir * part_gap
		target_pos.y = part.global_position.y  # не дёргаем по высоте
		part.global_position = part.global_position.lerp(target_pos, follow_speed * delta)


func _update_deployed(delta: float) -> void:
	for i in range(_parts.size()):
		if i >= _deployed_targets.size():
			break
		var part := _parts[i]
		part.global_position = part.global_position.lerp(_deployed_targets[i], follow_speed * delta)
