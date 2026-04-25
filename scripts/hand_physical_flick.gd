extends Node
## Flick (щелбан) — physical-категория, направленный выпад предмета по курсору.
## Триггерится координатором PhysicalActions, когда `equipped == FLICK` и зажата ПКМ.
##
## Hold-state: пока ПКМ зажата, рука «прилипает» к орбите вокруг цели; на release —
## импульс в противоположную сторону.

signal flicked(target: Item, velocity: Vector3)

@export var flick_orbit_radius: float = 1.5
@export var flick_force: float = 25.0
@export var flick_damage: float = 5.0

@export var debug_log: bool = true

var _hand: Hand
var _coord: HandPhysicalActions
var _flick_target: Item = null
# Текущее горизонтальное направление от цели к руке. Обновляется каждый кадр
# из cursor_world_position(); если курсор «заехал» прямо на цель и горизонталь
# пропала — держим прошлое направление, а не дрожим.
var _flick_orbit_dir: Vector3 = Vector3.RIGHT
var _active: bool = false


func _ready() -> void:
	_coord = get_parent() as HandPhysicalActions
	if not _coord:
		push_error("HandPhysicalFlick: ожидается родитель PhysicalActions (HandPhysicalActions)")
		set_process(false)
		set_physics_process(false)
		return
	_hand = _coord.get_parent() as Hand
	if not _hand:
		push_error("HandPhysicalFlick: ожидается Hand через PhysicalActions → Hand")
		set_process(false)
		set_physics_process(false)
		return


# --- Публичный API (вызывается координатором PhysicalActions) ---

func is_active() -> bool:
	return _active


func on_press() -> bool:
	if _coord.is_holding():
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Physical:Flick] щелбан: рука занята, сначала отпустите предмет")
		return false
	var target := _coord.find_grab_candidate()
	if not target:
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Physical:Flick] щелбан: предмета под рукой нет")
		return false
	_flick_target = target
	# Стартовое направление — текущая горизонтальная разница руки и цели.
	# Если рука прямо над целью (XZ почти совпадают) — берём дефолтный +X.
	var to_hand_h := VecUtil.horizontal(_hand.global_position - target.global_position)
	if to_hand_h.length_squared() > VecUtil.EPSILON_SQ:
		_flick_orbit_dir = to_hand_h.normalized()
	else:
		_flick_orbit_dir = Vector3.RIGHT
	_hand.lock_position(true)
	_active = true
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Physical:Flick] щелбан: захват цели %s" % target.name)
	return true


func on_release() -> void:
	if not _active:
		return
	_hand.lock_position(false)
	_active = false
	if not is_instance_valid(_flick_target):
		_flick_target = null
		return
	var dir: Vector3 = _flick_target.global_position - _hand.global_position
	dir.y = 0.0
	if dir.length_squared() < VecUtil.EPSILON_SQ:
		_flick_target = null
		return
	dir = dir.normalized()
	var velocity: Vector3 = dir * flick_force
	_flick_target.apply_central_impulse(velocity)
	_flick_target.take_damage(flick_damage)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Physical:Flick] щелбан: %s полетел в (%.2f, %.2f), |v|=%.2f" % [_flick_target.name, dir.x, dir.z, velocity.length()])
	flicked.emit(_flick_target, velocity)
	_flick_target = null


func tick(_delta: float) -> void:
	if not _active:
		return
	if not is_instance_valid(_flick_target):
		# Цель уничтожилась во время прицеливания — отменяем.
		_hand.lock_position(false)
		_flick_target = null
		_active = false
		return
	# Направление берём из курсора: куда мышь — там и рука относительно цели.
	# Если курсор совсем близко к цели — держим прошлое направление, без рывков.
	var cursor: Vector3 = _hand.cursor_world_position()
	var to_cursor_h := VecUtil.horizontal(cursor - _flick_target.global_position)
	if to_cursor_h.length_squared() > VecUtil.EPSILON_SQ:
		_flick_orbit_dir = to_cursor_h.normalized()
	_hand.global_position = _flick_target.global_position + _flick_orbit_dir * flick_orbit_radius
