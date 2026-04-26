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

@export_subgroup("Magnet")
## Базовая сила магнита. Фактически прикладывается min(magnet_force, mass*max_accel).
@export var magnet_force: float = 30.0
## Внутри этого радиуса вокруг руки магнит силу не прикладывает. На нулевой
## дистанции направление дрожит, и константная сила колебала бы предмет
## туда-сюда. В дед-зоне грэб подхватит на следующем кадре — это именно та
## дистанция, на которой LMB и так сработает.
@export var magnet_dead_zone: float = 0.6
## Saturation: верхний предел ускорения от магнита (m/c²). Без него лёгкий
## предмет (mass=0.5) при magnet_force=30 получал бы 60 m/c² и пролетал руку
## насквозь, тяжёлый — еле трогался. С cap'ом фактическая сила =
## min(magnet_force, mass*max_accel): для mass=0.5 → 12.5 N (a=25), для mass≥1.2
## → 30 N (стандартный force).
@export var magnet_max_accel: float = 25.0
@export_subgroup("")

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
## Текущий захваченный объект — любой Grabbable RigidBody3D (Item, ResourcePile,
## ...). Класс не привязан, лишь бы был в группе Grabbable.GROUP.
var _held: RigidBody3D = null
var _is_grabbing: bool = false
var _current_candidate: RigidBody3D = null

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

func get_held_item() -> RigidBody3D:
	return _held


func is_holding() -> bool:
	return _held != null


## Возвращает ближайший допустимый Grabbable RigidBody3D в GrabArea (или null).
func find_grab_candidate() -> RigidBody3D:
	return _find_closest_grabbable(_hand.get_grabbable_bodies())


## Возвращает ближайшую damageable-цель в зоне захвата (с фильтром массы для RigidBody).
## Используется Flick'ом — он бьёт всё damageable, не только Items/Enemies по имени.
func find_flick_target() -> Node3D:
	var closest: Node3D = null
	var closest_dist := INF
	for body in _hand.get_grabbable_bodies():
		if not Damageable.is_damageable(body):
			continue
		if not _is_within_lift_mass(body):
			continue
		var d := _hand.global_position.distance_to(body.global_position)
		if d < closest_dist:
			closest_dist = d
			closest = body
	return closest


## Проходит ли тело mass-фильтр (mass < max_lift_mass). Не-RigidBody всегда
## true. Дедуп между find_flick_target и _find_closest_grabbable.
func _is_within_lift_mass(body: Node3D) -> bool:
	if body is RigidBody3D:
		return (body as RigidBody3D).mass < max_lift_mass
	return true


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
	var closest := _find_closest_grabbable(_hand.get_grabbable_bodies())
	if closest:
		_attach(closest)


func _apply_magnet() -> void:
	var closest := _find_closest_grabbable(_hand.get_magnet_bodies())
	if not closest:
		if debug_log and LogConfig.master_enabled and _was_magnetizing:
			print("[Hand:Physical] магнит: цели нет")
			_was_magnetizing = false
			_magnet_target_name = ""
		return
	var to_hand: Vector3 = _hand.global_position - closest.global_position
	var dist_sq := to_hand.length_squared()
	# Дед-зона: внутри неё магнит не работает. Без неё на нулевой дистанции
	# направление дрожит и сила колеблет предмет. Грэб всё равно подхватит в
	# следующем кадре, GrabArea (r=2) >> magnet_dead_zone (~0.6).
	if dist_sq < magnet_dead_zone * magnet_dead_zone:
		return
	var dist := sqrt(dist_sq)
	# Saturation: реальная сила = min(magnet_force, mass * max_accel).
	# Лёгкие предметы получают force, лимитированный по ускорению; тяжёлые —
	# полный magnet_force. Без этого mass=0.5 пролетал бы руку насквозь.
	var force_mag: float = minf(magnet_force, magnet_max_accel * closest.mass)
	var dir := to_hand / dist
	closest.apply_central_force(dir * force_mag)
	if debug_log and LogConfig.master_enabled and (not _was_magnetizing or _magnet_target_name != str(closest.name)):
		print("[Hand:Physical] магнит тянет %s (mass=%.1f, dist=%.2f, F=%.1f)" % [closest.name, closest.mass, dist, force_mag])
		_was_magnetizing = true
		_magnet_target_name = str(closest.name)


## Ближайший Grabbable RigidBody3D с массой < max_lift_mass.
## Класс цели не важен — Item, ResourcePile, любой будущий тип.
func _find_closest_grabbable(bodies: Array[Node3D]) -> RigidBody3D:
	var closest: RigidBody3D = null
	var closest_dist := INF
	for body in bodies:
		if not Grabbable.is_grabbable(body):
			continue
		if not (body is RigidBody3D):
			continue
		if not _is_within_lift_mass(body):
			continue
		var rb := body as RigidBody3D
		var d := _hand.global_position.distance_to(rb.global_position)
		if d < closest_dist:
			closest_dist = d
			closest = rb
	return closest


func _attach(body: RigidBody3D) -> void:
	_held = body
	_held.linear_velocity = Vector3.ZERO
	_held.angular_velocity = Vector3.ZERO
	_held.freeze = true
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Physical] схвачен %s (mass=%.1f)" % [body.name, body.mass])
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
	var candidate: RigidBody3D = null
	if not _held:
		candidate = _find_closest_grabbable(_hand.get_grabbable_bodies())
	if candidate == _current_candidate:
		return
	# set_highlighted — часть Grabbable-контракта; has_method защищает от
	## будущих Grabbable, у которых вдруг рамки нет.
	if _current_candidate and is_instance_valid(_current_candidate) and _current_candidate.has_method("set_highlighted"):
		_current_candidate.set_highlighted(false)
	if candidate and candidate.has_method("set_highlighted"):
		candidate.set_highlighted(true)
	if debug_log and LogConfig.master_enabled:
		if candidate:
			print("[Hand:Physical] кандидат: %s" % candidate.name)
		elif _current_candidate:
			print("[Hand:Physical] кандидат: —")
	_current_candidate = candidate
