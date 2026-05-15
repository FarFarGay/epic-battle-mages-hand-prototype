class_name WatchBell
extends StaticBody3D
## Сторожевой колокол — постройка-сторож. Гном-watcher внутри замечает
## приближение врагов в радиусе [alarm_radius] и эмитит [bell_alarmed].
## Camp слушает сигнал и отправляет двух ближайших защитников на помощь.
##
## **Damageable:** скелеты видят колокол как обычное здание (входит в
## [Camp.SKELETON_TARGET_GROUP]) и атакуют по тому же приоритету что и
## палатки (гномы > здания). На hp=0 колокол разрушается, гном-watcher
## становится свободным gatherer'ом и бежит в лагерь (логика в Camp).
##
## **Physics body** (2026-05-15): StaticBody3D с CapsuleShape вокруг
## post+bell. collision_layer = CAMP_OBSTACLE (32). До этого был Node3D
## без коллизии — стрелы скелетов-лучников (MASK_HOSTILE_PROJECTILE
## включает CAMP_OBSTACLE) пролетали сквозь колокол не нанося урон.
## Melee-удары работали через Damageable.try_damage (group-based, не
## зависит от физики). После фикса arrow.body_entered ловит колокол.
##
## **Гном внутри:** хранится как ссылка [_garrison_gnome]. На постройке
## Camp изымает gatherer'а из лагеря и привязывает; на разрушении —
## возрождается на месте колокола.
##
## **Не путать с deploy:** колокол НЕ palатка. Стоит автономно в любой
## точке (выбранной интерактивным aim'ом), не входит в `Camp._parts`,
## не следует за караваном, не сворачивается. Просто стоит до уничтожения.

const SKELETON_TARGET_GROUP := &"skeleton_target"
## Группа всех колоколов на сцене. Hand.BuildAim ищет через
## `get_nodes_in_group(WATCH_BELL_GROUP)` для pickup-relocate (ЛКМ
## курсором рядом с колоколом → переставить).
const WATCH_BELL_GROUP := &"watch_bell"

## Урон, который выдерживает колокол. Дешевле tent'а (120hp) — это сторож,
## не крепость. 4-5 хитов скелета и упал. Дизайнерская петля: «недостаточно
## защищён» → игрок строит ещё или ставит ближе к лагерю.
@export var hp: float = 60.0
## Радиус области alarm'а. Скелет в этой зоне → bell_alarmed эмитится с
## позицией колокола. Визуал — полупрозрачный круг при aim'е. По дизайну
## зона небольшая (7.5м) — сторож видит только ближайших врагов, не весь
## фронт. Это локальный пост, а не радар.
@export var alarm_radius: float = 7.5
## Минимальный интервал между alarm-эмитами. Без него каждый кадр в Area3D
## с новыми скелетами слал бы сигнал — спам. 0.5с достаточно: Camp успевает
## обработать диспатч защитников, alarm-эффект не мигает.
@export var alarm_cooldown: float = 0.5
## Цвет emission'а при наведении руки (hover). Тёплый жёлтый — как у
## CampPart'а, единый визуальный язык подсветки grab-объектов.
@export var highlight_color: Color = Color(1.0, 0.85, 0.4, 1.0)
@export var highlight_intensity: float = 1.0

signal damaged(amount: float)
signal destroyed
## Эмитится когда скелет вошёл в alarm-зону (но не чаще чем раз в alarm_cooldown).
## Camp слушает чтобы отправить помощь. Аргумент — мировая позиция колокола
## для удобства расчёта «ближайших защитников».
signal bell_alarmed(world_pos: Vector3)

@onready var _alarm_area: Area3D = $AlarmArea
@onready var _bell_mesh: MeshInstance3D = $BellMesh

## Per-instance копия материала BellMesh'а — иначе hover-emission поднялся бы
## на всех колоколах сразу (sub_resource shared в .tscn).
var _bell_material: StandardMaterial3D = null
var _base_emission_energy: float = 0.25
var _highlighted: bool = false
var _garrison_gnome: Node3D = null
var _alarm_cd: float = 0.0
var _destroyed: bool = false
## Счётчик скелетов сейчас в alarm-зоне. Поднимается на body_entered,
## опускается на body_exited (только для нод в SKELETON_GROUP). Используется
## защитниками в bell-mode: пока > 0, бой не закончен → не отзывают.
var _enemies_in_zone: int = 0
## True пока bell «в руке» (Hand BuildAim relocate). Защитники в bell-mode
## проверяют через [is_carried] и отпускаются, чтобы не стоять до linger'а
## пока bell физически не на сцене.
var _carried: bool = false


func _ready() -> void:
	Damageable.register(self)
	add_to_group(SKELETON_TARGET_GROUP)
	add_to_group(WATCH_BELL_GROUP)
	# Источник геометрии для NavMesh (колокол — небольшое препятствие).
	add_to_group(&"navmesh_source")
	# Hover-подсветка через общий сканер в Hand. Группа PICKUP_HIGHLIGHT_GROUP
	# собирает все non-Grabbable pickup-объекты — колокол, будущие постройки
	# с relocate'ом, интерактивные предметы. Hand сам управляет set_highlighted.
	add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)
	if _alarm_area != null:
		_alarm_area.body_entered.connect(_on_alarm_body_entered)
		_alarm_area.body_exited.connect(_on_alarm_body_exited)
	# Дублируем материал BellMesh per-instance — без duplicate hover-emission
	# поднялся бы на всех колоколах сцены сразу.
	if _bell_mesh != null and _bell_mesh.material_override is StandardMaterial3D:
		var src := _bell_mesh.material_override as StandardMaterial3D
		_base_emission_energy = src.emission_energy_multiplier
		_bell_material = src.duplicate() as StandardMaterial3D
		_bell_mesh.material_override = _bell_material


## Подсветка при hover'е рукой. Hand.physical scan'ит ближайший колокол в
## PICKUP_RADIUS и зажигает на нём set_highlighted(true), у остальных false.
func set_highlighted(value: bool) -> void:
	if _bell_material == null or _highlighted == value:
		return
	_highlighted = value
	if value:
		_bell_material.emission = highlight_color
		_bell_material.emission_energy_multiplier = highlight_intensity
	else:
		_bell_material.emission_energy_multiplier = _base_emission_energy
		_bell_material.emission = Color(0.95, 0.55, 0.1, 1.0)  # из .tscn


## Hand BuildAim вызывает при start_relocate: колокол временно «в руке» —
## визуал прячем, alarm отключаем, target-группу снимаем (скелеты больше
## не выберут как цель). На end_relocate всё восстанавливаем.
func set_carried(carried: bool) -> void:
	_carried = carried
	visible = not carried
	if _alarm_area != null:
		_alarm_area.monitoring = not carried
	if carried:
		remove_from_group(SKELETON_TARGET_GROUP)
		_enemies_in_zone = 0
	else:
		if not is_in_group(SKELETON_TARGET_GROUP):
			add_to_group(SKELETON_TARGET_GROUP)


## True если в alarm-зоне сейчас есть хоть один живой скелет. Защитники
## в bell-mode проверяют каждый тик; пока true — продлевают свой alarm-
## таймер; когда false → таймер истекает → возврат к патрулю.
func has_enemies_in_zone() -> bool:
	return _enemies_in_zone > 0


## True если bell сейчас «в руке» (relocate). Защитники должны отпустить
## bell-mode на время — иначе стояли бы до истечения linger-таймера.
func is_carried() -> bool:
	return _carried


func _process(delta: float) -> void:
	if _alarm_cd > 0.0:
		_alarm_cd -= delta


## Привязать гнома-watcher'а. Camp вызывает после постройки, изъяв
## gatherer'а из лагеря. Хранится только ссылка — гном физически уже
## queue_free'нут (визуально его «как бы нет», только колокол на карте).
## Освобождается на _die.
func set_garrison(gnome: Node3D) -> void:
	_garrison_gnome = gnome


func get_garrison() -> Node3D:
	return _garrison_gnome


# --- Damageable contract ---

func take_damage(amount: float) -> void:
	if _destroyed or amount <= 0.0:
		return
	hp -= amount
	if LogConfig.master_enabled:
		print("[Bell] получил урон %.1f, hp=%.1f" % [amount, hp])
	damaged.emit(amount)
	if hp <= 0.0:
		_die()


func _die() -> void:
	if _destroyed:
		return
	_destroyed = true
	remove_from_group(SKELETON_TARGET_GROUP)
	destroyed.emit()
	# queue_free делаем НЕ здесь — Camp на сигнале destroyed спавнит
	# свободного gatherer'а на месте колокола и потом сам зовёт queue_free.
	# Если Camp подписан не успел (race), страховка через call_deferred
	# free через 1 кадр.
	call_deferred("queue_free")


# --- Alarm ---

func _on_alarm_body_entered(body: Node) -> void:
	if _destroyed:
		return
	# Только скелеты считаются. Гномы/палатки в alarm-area не интересуют.
	if not body.is_in_group(Skeleton.SKELETON_GROUP):
		return
	_enemies_in_zone += 1
	# Alarm cd защищает от множественных emit-ов от пачки скелетов, ввалившихся
	# в один кадр. Сам счётчик увеличивается всегда — bell нужно знать сколько
	# скелетов в зоне для has_enemies_in_zone().
	if _alarm_cd > 0.0:
		return
	_alarm_cd = alarm_cooldown
	bell_alarmed.emit(global_position)


func _on_alarm_body_exited(body: Node) -> void:
	if not body.is_in_group(Skeleton.SKELETON_GROUP):
		return
	_enemies_in_zone = maxi(_enemies_in_zone - 1, 0)
