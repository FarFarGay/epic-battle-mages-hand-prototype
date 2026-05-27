class_name FrostPatch
extends Node3D
## Зона мороза на земле. Не двигается, не растёт — синий диск фиксированного
## радиуса, тикает `apply_freeze` на всех Enemy в радиусе с slow_factor
## `_slow_factor` (по умолчанию 0.4 = 60% медленнее). Длительность каждого
## tick'а небольшая (`_refresh_interval × 2`), но он перевызывается каждый
## тик → пока враг в зоне, эффект продлевается; вышел — фаза дотлевает.
##
## Зеркало [BurnPatch] для frost-эффекта. Отличия:
## - вместо `Damageable.try_damage` — `Enemy.apply_freeze(duration, factor)`.
## - нет hand_immune-фильтра (frost — soft cc, дружественные юниты могут
##   попадать под него; но мы фильтруем по `is Enemy`, гномы не пострадают).
## - нет FAR-fallback по Skeleton.SKELETON_GROUP — FAR-юниты невидимы и
##   плотно от лагеря (frost-patch у лагеря всегда NEAR/MID).
##
## Использование: спавнится [FrostBolt._explode] после AOE-импакта.

@export var debug_log: bool = true

var _radius: float = 4.0
## Множитель скорости врагов в зоне. 0.4 = 60% slow. Полная заморозка
## (0.0) — отдельный hit-эффект самой ракеты, не зоны.
var _slow_factor: float = 0.4
## Период применения эффекта (с). Каждый тик `apply_freeze` обновляет
## таймер на врагах в радиусе.
var _refresh_interval: float = 0.25
## Сколько секунд зона живёт. По истечении — `queue_free`. Lifetime НЕ
## сохраняется на враге автоматически — если он вышел из зоны и тик не
## возобновился, freeze дотает свой `freeze_per_tick` интервал.
var _duration: float = 4.0
## Длительность freeze-эффекта, накладываемого ОДНИМ тиком. Больше
## `_refresh_interval` × 2 — чтобы успеть подкопить эффект перед сбросом.
var _freeze_per_tick: float = 0.6
## Время раскрытия от 0 до полного `_radius`, секунд. Растёт линейно.
## Визуальный диск и эффект-зона следуют одному радиусу — игрок видит
## где сейчас лёд и где он начнёт замораживать. По достижении max —
## зона стабильна оставшееся время `_duration - _grow_duration`.
var _grow_duration: float = 1.0

var _elapsed: float = 0.0
var _next_tick_at: float = 0.0
var _ticks_done: int = 0

@onready var _disk: MeshInstance3D = get_node_or_null("Disk") as MeshInstance3D


func setup(
	radius: float,
	slow_factor: float,
	duration: float,
	refresh_interval: float = 0.25,
	freeze_per_tick: float = 0.6,
	grow_duration: float = 1.0,
) -> void:
	_radius = radius
	_slow_factor = clampf(slow_factor, 0.0, 1.0)
	_duration = duration
	_refresh_interval = maxf(refresh_interval, 0.05)
	_freeze_per_tick = maxf(freeze_per_tick, _refresh_interval * 2.0)
	# grow_duration не должен превышать total duration — иначе зона не успеет
	# раскрыться. Clamp до 90% duration на всякий случай.
	_grow_duration = clampf(grow_duration, 0.0, _duration * 0.9)
	# Первый тик сразу (в отличие от BurnPatch, где первый отложен) — frost
	# должен начать тормозить мгновенно при входе зоны, иначе врагов
	# подмораживает с лагом.
	_next_tick_at = 0.0


func _ready() -> void:
	# Стартовый scale = 0 (зона ещё не раскрылась). Растёт в _physics_process.
	# Если grow_duration=0 — мгновенно полный размер (legacy-режим).
	if _disk != null:
		var start_r: float = _current_radius()
		_disk.scale = Vector3(start_r / 0.5, 1.0, start_r / 0.5)


## Текущий радиус с учётом раскрытия. Линейный лерп от 0 до `_radius` за
## `_grow_duration` секунд. После — стабильный max.
func _current_radius() -> float:
	if _grow_duration <= 0.0:
		return _radius
	var t: float = clampf(_elapsed / _grow_duration, 0.0, 1.0)
	return _radius * t


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= _duration:
		queue_free()
		return
	# Визуал растущего диска — обновляется каждый кадр (cheap, всего scale).
	if _disk != null and _elapsed < _grow_duration:
		var r: float = _current_radius()
		_disk.scale = Vector3(r / 0.5, 1.0, r / 0.5)
	if _elapsed >= _next_tick_at:
		_apply_tick()
		_next_tick_at = _elapsed + _refresh_interval
		_ticks_done += 1


## Скан всех врагов в группе ENEMY_GROUP, фильтр по XZ-радиусу, на каждом
## вызов `apply_freeze`. Без physics-query — frost-зона больше типичного
## broad-phase shape'а (4м), скан по group дешевле и не зависит от
## collision_layer'ов.
func _apply_tick() -> void:
	var origin: Vector3 = global_position
	# Используем _current_radius (растёт от 0 к _radius) — эффект следует
	# визуалу, игрок видит точную зону действия в каждый момент.
	var cur_r: float = _current_radius()
	var radius_sq: float = cur_r * cur_r
	var hits: int = 0
	for n in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(n):
			continue
		var enemy := n as Enemy
		if enemy == null:
			continue
		var dx: float = enemy.global_position.x - origin.x
		var dz: float = enemy.global_position.z - origin.z
		if dx * dx + dz * dz > radius_sq:
			continue
		enemy.apply_freeze(_freeze_per_tick, _slow_factor)
		hits += 1
	if debug_log and LogConfig.master_enabled and hits > 0:
		print("[FrostPatch] tick %d: slow'd %d (factor=%.2f)" % [_ticks_done, hits, _slow_factor])
