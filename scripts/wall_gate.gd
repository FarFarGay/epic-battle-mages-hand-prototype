class_name WallGate
extends StaticBody3D
## Ворота в частоколе. Защитная постройка: блокирует врагов физически
## (`CAMP_OBSTACLE` слой как у [PalisadeSegment]), пропускает своих —
## дружественные юниты (гномы, солдаты) на `FRIENDLY_UNIT` слое имеют
## маску `TERRAIN`-only и физически проходят сквозь стены/ворота всегда.
##
## **Open/close** — двойной эффект:
## 1. Анимация дверей (визуал) на любого друга в trigger-зоне.
## 2. **Body-collider отключается** пока в зоне есть друзья. Это нужно для
##    Tower: её маска включает CAMP_OBSTACLE → без disable'а она физически
##    упиралась бы в ворота как в стену, несмотря на анимацию. Гномы и так
##    проходят (mask=TERRAIN-only). Скелетов триггер не ловит (mask их слой
##    не включает), но **они могут проскочить пока другой свой в зоне** —
##    дизайнерски acceptable edge case: «ворота не закрылись вовремя».
##
## Архитектура:
## - Триггер-Area3D детектит дружественных юнитов в радиусе [trigger_radius].
##   Счётчик `_friendlies_inside` инкрементится на `body_entered` и
##   декрементится на `body_exited`. >0 → состояние OPEN (анимация).
## - Двери `DoorLeft` / `DoorRight` — Node3D-pivot'ы по краям ворот.
##   Меш-внутри сдвинут так, чтобы pivot сидел на петле. Tween вращает
##   pivot на 90° внутрь/наружу.
## - Damage: [hp]=60 (2× палисада, ворота крепче). На destroy — queue_free.

const SKELETON_TARGET_GROUP := &"skeleton_target"
const WALL_GATE_GROUP := &"wall_gate"

## Ширина ворот (метры). 4м = 2 башни шириной 2м — фиксированный размер,
## не настраивается на инстансе. Camp.try_build_wall_gate валидирует
## участок стены ≥ этой ширины перед постройкой.
const GATE_WIDTH: float = 4.0
## Время анимации открытия/закрытия дверей (секунды). Достаточно быстро
## чтобы своим не было заметной задержки, но не моментально.
const ANIMATE_TIME: float = 0.35
## Угол распахнутой двери (рад). 90° = двери перпендикулярно стене.
const OPEN_ANGLE: float = PI / 2.0

@export var hp: float = 60.0
## Радиус триггер-зоны для друзей (по горизонтали). 3м — небольшой
## буфер: гном или Tower подошли на расстоянии руки → двери уже
## распахиваются. Без буфера — гном «проходит сквозь закрытые двери»
## визуально, что выглядит странно.
@export var trigger_radius: float = 3.0

signal damaged(amount: float)
signal destroyed

@onready var _door_left_pivot: Node3D = $DoorLeftPivot
@onready var _door_right_pivot: Node3D = $DoorRightPivot
@onready var _trigger: Area3D = $Trigger
@onready var _body_collider: CollisionShape3D = $BodyCollider

var _friendlies_inside: int = 0
var _is_open: bool = false
var _tween_left: Tween = null
var _tween_right: Tween = null
var _destroyed: bool = false


func _ready() -> void:
	Damageable.register(self)
	add_to_group(SKELETON_TARGET_GROUP)
	add_to_group(WALL_GATE_GROUP)
	# MELEE_ONLY: лучники-скелеты не тратят стрелы на ворота (как палисад).
	add_to_group(Enemy.MELEE_ONLY_TARGET_GROUP)
	# Источник NavMesh: ворота выгрызают навмеш как палисад — гномы строят
	# обход (через сами ворота они физически и так проходят, но навигация
	# должна это учитывать чтобы не тыкаться).
	add_to_group(&"navmesh_source")
	# Сфера-триггер своих юнитов. Не используем @export collision_shape
	# поскольку радиус известен (фиксированный размер ворот).
	if _trigger != null:
		_trigger.body_entered.connect(_on_friendly_entered)
		_trigger.body_exited.connect(_on_friendly_exited)


# --- Open/close (визуал) ---

func _on_friendly_entered(_body: Node3D) -> void:
	_friendlies_inside += 1
	if _friendlies_inside == 1:
		_open()


func _on_friendly_exited(_body: Node3D) -> void:
	_friendlies_inside = maxi(_friendlies_inside - 1, 0)
	if _friendlies_inside == 0:
		_close()


func _open() -> void:
	if _is_open or _destroyed:
		return
	_is_open = true
	# Отключаем body-collider — Tower (collision_mask включает CAMP_OBSTACLE)
	# сможет проехать. Гномам не нужно (их mask=TERRAIN-only).
	if _body_collider != null:
		_body_collider.disabled = true
	_play_door_tween(_door_left_pivot, -OPEN_ANGLE, _tween_left)
	_play_door_tween(_door_right_pivot, OPEN_ANGLE, _tween_right)


func _close() -> void:
	if not _is_open or _destroyed:
		return
	_is_open = false
	# Возвращаем стену — Tower и скелеты снова блокируются.
	if _body_collider != null:
		_body_collider.disabled = false
	_play_door_tween(_door_left_pivot, 0.0, _tween_left)
	_play_door_tween(_door_right_pivot, 0.0, _tween_right)


func _play_door_tween(pivot: Node3D, target_y: float, prev: Tween) -> void:
	if pivot == null:
		return
	if prev != null and prev.is_valid():
		prev.kill()
	var t := create_tween()
	t.tween_property(pivot, "rotation:y", target_y, ANIMATE_TIME) \
		.set_trans(Tween.TRANS_QUART) \
		.set_ease(Tween.EASE_OUT)
	if pivot == _door_left_pivot:
		_tween_left = t
	else:
		_tween_right = t


# --- Damageable ---

func take_damage(amount: float) -> void:
	if _destroyed or amount <= 0.0:
		return
	hp -= amount
	if LogConfig.master_enabled:
		print("[WallGate] получил урон %.1f, hp=%.1f" % [amount, hp])
	damaged.emit(amount)
	if hp <= 0.0:
		_die()


func _die() -> void:
	if _destroyed:
		return
	_destroyed = true
	remove_from_group(SKELETON_TARGET_GROUP)
	remove_from_group(WALL_GATE_GROUP)
	destroyed.emit()
	call_deferred("queue_free")
