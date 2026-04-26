class_name HandPhysicalActions
extends Node
## Координатор категории "Физические действия". Содержит "always-on" грабинг
## (LMB) и диспатчит активные способности (Slam / Flick) на ПКМ через подузлы.
##
## Дочерние узлы:
##   - Slam (HandPhysicalSlam): хлопок по земле.
##   - Flick (HandPhysicalFlick): щелбан с орбитой.
## Какая из них активна — определяется `equipped`, переключается клавишами 1 / 2.
##
## Зависит только от родителя — типа Hand. Hand передан в _ready через get_parent;
## дальше связь с подмодулями устанавливается через явный setup().

signal grabbed(item: Node3D)
signal released(item: Node3D, velocity: Vector3)
signal slammed(position: Vector3, radius: float)
signal flicked(target: Node3D, velocity: Vector3)

enum AbilityType { NONE = -1, SLAM, FLICK }

const ACTION_GRAB := &"hand_grab"
const ACTION_ACTION := &"hand_action"
const ACTION_EQUIP_SLAM := &"equip_slam"
const ACTION_EQUIP_FLICK := &"equip_flick"


@export_group("Balance")
@export var max_lift_mass: float = 10.0
@export var throw_strength: float = 1.2
@export var max_throw_speed: float = 30.0
@export var hold_offset: Vector3 = Vector3(0, -1.0, 0)
@export var magnet_force: float = 30.0

@export_group("Equipment")
## Текущая активная способность. Меняется клавишами 1 / 2 в рантайме.
@export var equipped: AbilityType = AbilityType.SLAM:
	set(value):
		if equipped == value:
			return
		equipped = value
		if is_inside_tree() and debug_log and LogConfig.master_enabled:
			print("[Hand:Physical] экипировано: %s" % AbilityType.keys()[value])

@export_group("")
@export var debug_log: bool = true

var _hand: Hand
var _held: Item = null
var _is_grabbing: bool = false
var _current_candidate: Item = null

# Логирование (фронт-триггеры)
var _was_magnetizing: bool = false
var _magnet_target_name: String = ""

@onready var _slam: HandPhysicalSlam = $Slam
@onready var _flick: HandPhysicalFlick = $Flick


func _ready() -> void:
	_hand = get_parent() as Hand
	if not _hand:
		push_error("HandPhysical: родитель не Hand")
		set_process(false)
		set_physics_process(false)
		return
	_hand.register_raycast_excluder(_get_excluded_rids)
	# Передаём подмодулям ссылку на Hand и на координатор — чтобы они не лезли
	# к дереву через get_parent()-цепочки.
	_slam.setup(_hand, self)
	_flick.setup(_hand, self)
	_slam.slammed.connect(slammed.emit)
	_flick.flicked.connect(flicked.emit)
	# Re-emit на глобальный EventBus.
	slammed.connect(func(position: Vector3, radius: float) -> void: EventBus.hand_slammed.emit(position, radius))
	flicked.connect(func(target: Node3D, velocity: Vector3) -> void: EventBus.hand_flicked.emit(target, velocity))


func _exit_tree() -> void:
	# Если рука выгружается с захваченным предметом — освобождаем, чтобы Item
	# не остался freeze=true в мире.
	if _held:
		_release()


func _process(delta: float) -> void:
	# Тикаем суб-способности (кулдауны, орбита и т.п.).
	_slam.tick(delta)
	_flick.tick(delta)
	_handle_input()
	_update_held_position()
	_update_candidate_highlight()


func _physics_process(_delta: float) -> void:
	# Магнит и попытка захвата — в физик-кадре, чтобы силы суммировались стабильно.
	if _is_grabbing and not _held:
		_try_grab()
		if not _held:
			_apply_magnet()
		elif debug_log and LogConfig.master_enabled and _was_magnetizing:
			_was_magnetizing = false
			_magnet_target_name = ""


# --- Публичный API ---

func get_held_item() -> Item:
	return _held


func is_holding() -> bool:
	return _held != null


## Возвращает ближайший допустимый Item внутри GrabArea (или null).
func find_grab_candidate() -> Item:
	return _find_closest_item(_hand.get_grabbable_bodies())


## Возвращает ближайшую damageable-цель в зоне захвата (с фильтром массы для RigidBody).
## Используется Flick'ом — он бьёт всё damageable, не только Items/Enemies по имени.
func find_flick_target() -> Node3D:
	var closest: Node3D = null
	var closest_dist := INF
	for body in _hand.get_grabbable_bodies():
		if not Damageable.is_damageable(body):
			continue
		if body is RigidBody3D and (body as RigidBody3D).mass >= max_lift_mass:
			continue
		var d := _hand.global_position.distance_to(body.global_position)
		if d < closest_dist:
			closest_dist = d
			closest = body
	return closest


# --- Raycast excluder ---

func _get_excluded_rids() -> Array[RID]:
	if _held:
		return [_held.get_rid()]
	return []


# --- Ввод ---

func _handle_input() -> void:
	# Смена экипировки доступна всегда.
	if Input.is_action_just_pressed(ACTION_EQUIP_SLAM):
		equipped = AbilityType.SLAM
	elif Input.is_action_just_pressed(ACTION_EQUIP_FLICK):
		equipped = AbilityType.FLICK

	# Триггер активной способности (ПКМ). Источник правды о hold-state — сам подмодуль.
	if not _any_ability_active():
		if Input.is_action_just_pressed(ACTION_ACTION):
			_dispatch_action_press()
	else:
		if Input.is_action_just_released(ACTION_ACTION):
			_dispatch_action_release()

	# LMB-грабинг через polling, не через just_pressed/released:
	# во время flick'а edge-события пропускались бы и _is_grabbing залипало
	# (магнит после flick'а тянул бы предметы постоянно).
	var grab_pressed := Input.is_action_pressed(ACTION_GRAB)
	var was_grabbing := _is_grabbing
	_is_grabbing = grab_pressed
	# Во время flick'а рука прицеплена к орбите — не grab'ать и не release'ить.
	# _is_grabbing уже синхронизирован выше, так что после окончания flick'а
	# магнит сам прекратится при отпущенной LMB.
	if _flick.is_active():
		return
	if _is_grabbing and not was_grabbing:
		_try_grab()
	elif not _is_grabbing and was_grabbing:
		_release()


func _any_ability_active() -> bool:
	# Slam — one-shot (всегда возвращает false), Flick — hold-state.
	return _slam.is_active() or _flick.is_active()


func _dispatch_action_press() -> void:
	match equipped:
		AbilityType.SLAM:
			if _slam.can_trigger():
				_slam.on_press()
			elif debug_log and LogConfig.master_enabled:
				print("[Hand:Physical] хлопок на кулдауне")
		AbilityType.FLICK:
			_flick.on_press()


func _dispatch_action_release() -> void:
	if _flick.is_active():
		_flick.on_release()


# --- Захват / бросок / магнит ---

func _try_grab() -> void:
	if _held:
		return
	var closest := _find_closest_item(_hand.get_grabbable_bodies())
	if closest:
		_attach(closest)


func _apply_magnet() -> void:
	var closest := _find_closest_item(_hand.get_magnet_bodies())
	if not closest:
		if debug_log and LogConfig.master_enabled and _was_magnetizing:
			print("[Hand:Physical] магнит: цели нет")
			_was_magnetizing = false
			_magnet_target_name = ""
		return
	var to_hand: Vector3 = _hand.global_position - closest.global_position
	if to_hand.length_squared() < VecUtil.EPSILON_SQ:
		return
	closest.apply_central_force(to_hand.normalized() * magnet_force)
	if debug_log and LogConfig.master_enabled and (not _was_magnetizing or _magnet_target_name != str(closest.name)):
		print("[Hand:Physical] магнит тянет %s (mass=%.1f, dist=%.2f)" % [closest.name, closest.mass, to_hand.length()])
		_was_magnetizing = true
		_magnet_target_name = str(closest.name)


func _find_closest_item(bodies: Array[Node3D]) -> Item:
	var closest: Item = null
	var closest_dist := INF
	for body in bodies:
		if body is Item:
			var item := body as Item
			if item.mass >= max_lift_mass:
				continue
			var d := _hand.global_position.distance_to(item.global_position)
			if d < closest_dist:
				closest_dist = d
				closest = item
	return closest


func _attach(item: Item) -> void:
	_held = item
	_held.linear_velocity = Vector3.ZERO
	_held.angular_velocity = Vector3.ZERO
	_held.freeze = true
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Physical] схвачен %s (mass=%.1f)" % [item.name, item.mass])
	grabbed.emit(_held)


func _release() -> void:
	if not _held:
		return
	var item_name := str(_held.name)
	_held.freeze = false
	var v := _hand.smoothed_velocity() * throw_strength
	if v.length() > max_throw_speed:
		v = v.normalized() * max_throw_speed
	_held.linear_velocity = v
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Physical] отпущен %s, v=(%.2f, %.2f, %.2f), |v|=%.2f" % [item_name, v.x, v.y, v.z, v.length()])
	released.emit(_held, v)
	_held = null


func _update_held_position() -> void:
	if _held:
		_held.global_position = _hand.global_position + hold_offset


# --- Подсветка кандидата ---

func _update_candidate_highlight() -> void:
	var candidate: Item = null
	if not _held:
		candidate = _find_closest_item(_hand.get_grabbable_bodies())
	if candidate == _current_candidate:
		return
	if _current_candidate and is_instance_valid(_current_candidate):
		_current_candidate.set_highlighted(false)
	if candidate:
		candidate.set_highlighted(true)
	if debug_log and LogConfig.master_enabled:
		if candidate:
			print("[Hand:Physical] кандидат: %s" % candidate.name)
		elif _current_candidate:
			print("[Hand:Physical] кандидат: —")
	_current_candidate = candidate
