class_name HandPhysicalFlick
extends Node
## Flick (щелбан) — physical-категория, направленный выпад предмета по курсору.
## Триггерится координатором PhysicalActions, когда `equipped == FLICK` и зажата ПКМ.
##
## Hold-state: пока ПКМ зажата, рука «прилипает» к орбите вокруг цели; на release —
## импульс в противоположную сторону.
##
## Связь с Hand устанавливается через setup(hand, coord) от координатора —
## никаких get_parent()-цепочек.

signal flicked(target: Node3D, velocity: Vector3)

@export_group("Balance")
@export var flick_orbit_radius: float = 1.5
@export var flick_force: float = 25.0
## Минимум диапазона урона. На скелете hp=30 минимум 15 → два удара минимума ровно убивают.
@export var flick_damage_min: float = 15.0
## Максимум диапазона. ≥ skeleton hp → шанс one-shot'а.
@export var flick_damage_max: float = 35.0
## Длительность knockback'а на kinematic-цели при щелбане (AI отключён это время).
@export var flick_knockback_duration: float = 0.3

@export_group("")
@export var debug_log: bool = true

var _hand: Hand
var _coord: HandPhysicalActions
var _flick_target: Node3D = null
# Текущее горизонтальное направление от цели к руке. Обновляется каждый кадр
# из cursor_world_position(); если курсор «заехал» прямо на цель и горизонталь
# пропала — держим прошлое направление, а не дрожим.
var _flick_orbit_dir: Vector3 = Vector3.RIGHT
var _active: bool = false


## Вызывается координатором HandPhysicalActions._ready после установления связи с Hand.
func setup(hand: Hand, coord: HandPhysicalActions) -> void:
	_hand = hand
	_coord = coord


# --- Публичный API (вызывается координатором PhysicalActions) ---

func is_active() -> bool:
	return _active


func on_press() -> bool:
	if _coord.is_holding():
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Physical:Flick] щелбан: рука занята, сначала отпустите предмет")
		return false
	var target := _coord.find_flick_target()
	if not target:
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Physical:Flick] щелбан: цели под рукой нет")
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
	var damage := randf_range(flick_damage_min, flick_damage_max)
	Pushable.try_push(_flick_target, velocity, flick_knockback_duration)
	Damageable.try_damage(_flick_target, damage)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Physical:Flick] щелбан: %s полетел в (%.2f, %.2f), |v|=%.2f, dmg=%.1f" % [_flick_target.name, dir.x, dir.z, velocity.length(), damage])
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
	# Hand сейчас locked — пишем напрямую через документированный API.
	_hand.set_locked_position(_flick_target.global_position + _flick_orbit_dir * flick_orbit_radius)
