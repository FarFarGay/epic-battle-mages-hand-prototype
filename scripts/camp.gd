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
signal deployed(anchor: Vector3)
signal packed

## CARAVAN_FOLLOWING — палатки тянутся за башней, гномы IN_TENT.
## DEPLOYED — палатки в кольце вокруг anchor'а, гномы бродят и собирают ресурсы.
## PACKING_RETURNING — пользователь начал свёртку, гномы возвращаются в палатки;
##                     сами палатки пока не двигаются — ждут гномов. Когда все
##                     гномы IN_TENT — переход в CARAVAN_FOLLOWING.
enum State { CARAVAN_FOLLOWING, DEPLOYED, PACKING_RETURNING }

@export_node_path("Node3D") var target_path: NodePath
## Палатки лагеря в порядке цепочки. Прокидываются вручную в инспекторе.
## Если пусто — _ready() заполнит из get_children() с фильтром по имени `CaravanPart*`.
@export var part_nodes: Array[StaticBody3D] = []
## Decay-коэффициент (log-rate) экспоненциального следования палаток.
## Чем выше — тем быстрее палатка догоняет точку-цель. Не зависит от dt.
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
## Порог смещения цели за кадр, ниже которого считаем её неподвижной.
@export var stationary_threshold: float = 0.01

@export_group("Gnomes")
## Сцена гнома — спавнится по gnomes_per_tent на каждую палатку.
@export var gnome_scene: PackedScene
## Сколько гномов живёт в каждой палатке.
@export var gnomes_per_tent: int = 2

@export_group("")
@export var debug_log: bool = true

var _tower: Node3D
var _state: State = State.CARAVAN_FOLLOWING
var _parts: Array[StaticBody3D] = []
## Таймер удержания R в CARAVAN_FOLLOWING (для развёртки).
var _deploy_hold: float = 0.0
## Таймер удержания R в DEPLOYED (для свёртки).
var _pack_hold: float = 0.0
var _deploy_anchor: Vector3 = Vector3.ZERO
var _deployed_targets: Array[Vector3] = []
## Позиция башни на прошлом кадре — для эпсилон-чека неподвижности.
var _last_target_pos: Vector3 = Vector3.INF
## Гномы лагеря — gnomes_per_tent × количество палаток. Создаются в _ready.
var _gnomes: Array[Gnome] = []

## Публичный геттер anchor'а — гномы читают, чтобы знать, куда нести ресурс.
var deploy_anchor: Vector3:
	get:
		return _deploy_anchor

# Логирование (фронт-триггеры, чтобы не спамить каждый кадр).
var _was_holding_stationary: bool = false
var _was_out_of_range: bool = false


func _ready() -> void:
	if not target_path.is_empty():
		_tower = get_node_or_null(target_path) as Node3D
	if not _tower:
		push_warning("Camp: target_path не разрешился, башня не задана")

	if not part_nodes.is_empty():
		for p in part_nodes:
			if p:
				_parts.append(p)
	else:
		for child in get_children():
			if child is StaticBody3D and child.name.begins_with("CaravanPart"):
				_parts.append(child as StaticBody3D)

	# Скелеты могут уничтожить палатку — слушаем destroyed, чтобы вычистить _parts
	# (иначе _update_*-циклы поймают invalid-инстанс).
	for p in _parts:
		if p is CampPart:
			(p as CampPart).destroyed.connect(_on_part_destroyed.bind(p))

	_spawn_gnomes()

	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	deployed.connect(func(anchor: Vector3) -> void: EventBus.camp_deployed.emit(anchor))
	packed.connect(func() -> void: EventBus.camp_packed.emit())


func _spawn_gnomes() -> void:
	if gnome_scene == null:
		if debug_log and LogConfig.master_enabled:
			print("[Camp] gnome_scene не задан — гномы не спавнятся")
		return
	for tent in _parts:
		for i in range(gnomes_per_tent):
			var gnome := gnome_scene.instantiate() as Gnome
			if gnome == null:
				push_warning("Camp: gnome_scene не инстанцируется как Gnome")
				continue
			add_child(gnome)
			gnome.global_position = tent.global_position
			gnome.setup(self, tent)
			# Скелет может убить гнома — выкидываем из _gnomes, иначе claim-чек
			# и _all_gnomes_home будут спотыкаться об invalid-инстансы.
			gnome.destroyed.connect(_on_gnome_destroyed.bind(gnome))
			_gnomes.append(gnome)


func _on_part_destroyed(part: StaticBody3D) -> void:
	_parts.erase(part)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] палатка %s уничтожена (осталось: %d)" % [part.name, _parts.size()])


func _on_gnome_destroyed(gnome: Gnome) -> void:
	_gnomes.erase(gnome)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] гном %s убит (осталось: %d)" % [gnome.name, _gnomes.size()])


func _process(delta: float) -> void:
	_handle_input(delta)
	match _state:
		State.CARAVAN_FOLLOWING:
			_update_caravan_follow(delta)
		State.DEPLOYED:
			_update_deployed(delta)
		State.PACKING_RETURNING:
			# Палатки стоят на местах развёртки, гномы возвращаются.
			# Когда все дома — финализируем pack.
			_update_deployed(delta)
			if _all_gnomes_home():
				_finalize_pack()
	if _tower != null:
		_last_target_pos = _tower.global_position


func _all_gnomes_home() -> bool:
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if not g.is_home():
			return false
	return true


# --- Дележ куч между гномами ---

## True, если кучу уже нацелил какой-то гном (≠ exclude_gnome). Гном-сканер
## пропускает claimed-кучи, чтобы каждый нашёл «своё».
func is_pile_claimed(pile: ResourcePile, exclude_gnome: Gnome = null) -> bool:
	if not is_instance_valid(pile):
		return false
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g == exclude_gnome:
			continue
		if g.get_assigned_pile() == pile:
			return true
	return false


# --- Ввод / переходы состояний ---

func _handle_input(delta: float) -> void:
	if not Input.is_action_pressed("camp_toggle"):
		if _deploy_hold > 0.0 and debug_log and LogConfig.master_enabled and _was_holding_stationary:
			print("[Camp] отсчёт прерван (отпущена R)")
		_deploy_hold = 0.0
		_pack_hold = 0.0
		_was_holding_stationary = false
		return

	match _state:
		State.CARAVAN_FOLLOWING:
			if _is_tower_stationary():
				if not _was_holding_stationary:
					if debug_log and LogConfig.master_enabled:
						print("[Camp] начат отсчёт развёртки")
					_was_holding_stationary = true
				_deploy_hold += delta
				if _deploy_hold >= deploy_duration:
					_start_deploy()
			else:
				if _was_holding_stationary and debug_log and LogConfig.master_enabled:
					print("[Camp] отсчёт прерван (башня поехала)")
				_deploy_hold = 0.0
				_was_holding_stationary = false
		State.DEPLOYED:
			_pack_hold += delta
			if _pack_hold >= pack_duration:
				_start_pack()
		State.PACKING_RETURNING:
			# Во время сбора отсчёт не накапливается — гномам нужно дойти.
			pass


func _is_tower_stationary() -> bool:
	if _tower == null:
		return false
	if _last_target_pos == Vector3.INF:
		return false
	var d := _tower.global_position - _last_target_pos
	d.y = 0.0
	return d.length() < stationary_threshold


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
	_deploy_hold = 0.0
	_pack_hold = 0.0
	_was_holding_stationary = false
	if debug_log and LogConfig.master_enabled:
		print("[Camp] лагерь развёрнут @ (%.1f, %.1f, %.1f)" % [_deploy_anchor.x, _deploy_anchor.y, _deploy_anchor.z])
	deployed.emit(_deploy_anchor)
	# Палатки становятся уязвимы к атакам скелетов только в развёрнутом виде.
	for p in _parts:
		if p is CampPart:
			(p as CampPart).set_vulnerable(true)
	# Гномы выходят бродить.
	for g in _gnomes:
		if is_instance_valid(g):
			g.enter_deployed()


func _start_pack() -> void:
	# Сначала зовём гномов домой; финальный переход в CARAVAN — после прихода всех.
	_state = State.PACKING_RETURNING
	_deploy_hold = 0.0
	_pack_hold = 0.0
	_was_holding_stationary = false
	# Палатки сразу неуязвимы — игрок начал свёртку, тент бронируется.
	# Гномы остаются целью, пока не дойдут до своих палаток (они сами выходят
	# из skeleton_target в _enter_in_tent).
	for p in _parts:
		if p is CampPart:
			(p as CampPart).set_vulnerable(false)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] свёртка инициирована — ждём гномов")
	for g in _gnomes:
		if is_instance_valid(g):
			g.request_return()


func _finalize_pack() -> void:
	_state = State.CARAVAN_FOLLOWING
	if debug_log and LogConfig.master_enabled:
		print("[Camp] лагерь свёрнут (все гномы дома)")
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
		target_pos.y = _ground_y_at(part, target_pos)
		part.global_position = _exp_decay(part.global_position, target_pos, follow_speed, delta)


func _update_deployed(delta: float) -> void:
	for i in range(_parts.size()):
		if i >= _deployed_targets.size():
			break
		var part := _parts[i]
		part.global_position = _exp_decay(part.global_position, _deployed_targets[i], follow_speed, delta)


# --- Helpers ---

## Покадрово стабильное смягчение к target. decay — log-rate (чем больше, тем быстрее).
static func _exp_decay(current: Vector3, target: Vector3, decay: float, delta: float) -> Vector3:
	return target + (current - target) * exp(-decay * delta)


## Y под точкой target_pos через raycast по слою TERRAIN. Если raycast пуст —
## возвращаем текущую Y палатки (не дёргаем по высоте).
func _ground_y_at(part: StaticBody3D, target_pos: Vector3) -> float:
	var space := part.get_world_3d().direct_space_state
	if space == null:
		return part.global_position.y
	var from := target_pos + Vector3.UP * 5.0
	var to := target_pos + Vector3.DOWN * 50.0
	var query := PhysicsRayQueryParameters3D.create(from, to, Layers.TERRAIN)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return part.global_position.y
	return (hit["position"] as Vector3).y
