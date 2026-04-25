class_name HandPhysicalActions
extends Node
## Координатор категории "Физические действия". Содержит "always-on" грабинг
## (LMB) и диспатчит активные способности (Slam / Flick) на ПКМ через подузлы.
##
## Дочерние узлы:
##   - Slam (hand_physical_slam.gd): хлопок по земле.
##   - Flick (hand_physical_flick.gd): щелбан с орбитой.
## Какая из них активна — определяется `equipped`, переключается клавишами 1 / 2.
##
## Зависит только от родителя — типа Hand. Через него получает позицию,
## сглаженную скорость, доступ к Area-зонам и lock_position() для щелбана.

signal grabbed(item: Item)
signal released(item: Item, velocity: Vector3)
signal slammed(position: Vector3, radius: float)
signal flicked(target: Node3D, velocity: Vector3)

enum AbilityType { NONE = -1, SLAM, FLICK }


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
# Текущее активное действие на ПКМ (NONE если нет, FLICK если рука сейчас в орбите).
# Slam — one-shot, hold-state не сохраняет.
var _action_active: AbilityType = AbilityType.NONE

# Логирование (фронт-триггеры)
var _was_magnetizing: bool = false
var _magnet_target_name: String = ""

@onready var _slam: Node = $Slam
@onready var _flick: Node = $Flick


func _ready() -> void:
	_hand = get_parent() as Hand
	if not _hand:
		push_error("HandPhysical: родитель не Hand")
		set_process(false)
		set_physics_process(false)
		return
	_hand.register_raycast_excluder(_get_excluded_rids)
	# Сабузлы эмитят свои сигналы локально — пробрасываем их наверх через
	# собственные сигналы PhysicalActions (внешний контракт сохраняется).
	if _slam and _slam.has_signal("slammed"):
		_slam.slammed.connect(slammed.emit)
	if _flick and _flick.has_signal("flicked"):
		_flick.flicked.connect(flicked.emit)
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	# grabbed/released пробрасывает Hand (он re-emit'ит из подмодуля); здесь
	# отправляем напрямую только slammed/flicked, у Hand их нет.
	slammed.connect(func(position: Vector3, radius: float) -> void: EventBus.hand_slammed.emit(position, radius))
	flicked.connect(func(target: Node3D, velocity: Vector3) -> void: EventBus.hand_flicked.emit(target, velocity))


func _process(delta: float) -> void:
	# Тикаем суб-способности (кулдауны, орбита и т.п.).
	if _slam:
		_slam.tick(delta)
	if _flick:
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
## Используется суб-способностями (Flick) — единственный источник правды
## для логики «кто сейчас под рукой».
func find_grab_candidate() -> Item:
	return _find_closest_item(_hand.grab_area.get_overlapping_bodies())


## Возвращает ближайшую цель для щелбана: Item (с mass-фильтром) или Enemy.
## Враги в GrabArea видны благодаря collision_mask=18 (Items+Enemies).
func find_flick_target() -> Node3D:
	var closest: Node3D = null
	var closest_dist := INF
	for body in _hand.grab_area.get_overlapping_bodies():
		if body is Item:
			if (body as Item).mass >= max_lift_mass:
				continue
		elif not (body is Enemy):
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
	if Input.is_action_just_pressed("equip_slam"):
		equipped = AbilityType.SLAM
	elif Input.is_action_just_pressed("equip_flick"):
		equipped = AbilityType.FLICK

	# Триггер активной способности (ПКМ).
	if _action_active == AbilityType.NONE:
		if Input.is_action_just_pressed("hand_action"):
			_dispatch_action_press()
	else:
		if Input.is_action_just_released("hand_action"):
			_dispatch_action_release()
			_action_active = AbilityType.NONE

	# LMB-грабинг — пока активен flick, отключён, чтобы не схватить цель щелбана.
	if _action_active == AbilityType.FLICK:
		return
	if Input.is_action_just_pressed("hand_grab"):
		_is_grabbing = true
		_try_grab()
	elif Input.is_action_just_released("hand_grab"):
		_is_grabbing = false
		_release()


func _dispatch_action_press() -> void:
	match equipped:
		AbilityType.SLAM:
			if _slam.can_trigger():
				_slam.on_press()
			elif debug_log and LogConfig.master_enabled:
				print("[Hand:Physical] хлопок на кулдауне")
			# Slam — one-shot, никакого hold-state не остаётся.
		AbilityType.FLICK:
			var started: bool = _flick.on_press()
			if started:
				_action_active = AbilityType.FLICK


func _dispatch_action_release() -> void:
	if _action_active == AbilityType.FLICK:
		_flick.on_release()


# --- Захват / бросок / магнит ---

func _try_grab() -> void:
	if _held:
		return
	var closest := _find_closest_item(_hand.grab_area.get_overlapping_bodies())
	if closest:
		_attach(closest)


func _apply_magnet() -> void:
	var closest := _find_closest_item(_hand.magnet_area.get_overlapping_bodies())
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
		candidate = _find_closest_item(_hand.grab_area.get_overlapping_bodies())
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
