class_name SkeletonArcher
extends Enemy
## Скелет-лучник. Дальний боец: держит дистанцию, выпускает стрелы.
## Принципиально отличается от melee-Skeleton: AI ведёт kite-поведение
## (close gap / hold / retreat), удар = выстрел через Arrow, нет
## approach-кольца и LOD'а — лучник всегда «видимый» юнит, его TTH
## (time-to-hit) длиннее melee, FAR-режим лишний.
##
## Наследует Enemy базовую FSM (APPROACH → WINDUP → STRIKE → COOLDOWN):
## - APPROACH: kite-движение в зону [attack_radius_min, attack_radius_max].
## - WINDUP: стоит, целится. attack_windup длиннее чем у melee — это
##   «телеграф», игрок успевает увидеть и заслонить копейщика щитом палисада.
## - STRIKE: вызывает _perform_strike → инстансирует стрелу через arrow_scene.
##   STRIKE транзитное (как у базы), сразу COOLDOWN.
## - COOLDOWN: стоит, ждёт.
##
## Цели:
## - Скан через общий Enemy._target_grid раз в SCAN_INTERVAL.
## - Fallback: _forced_target (от WaveDirector), затем get_active_target
##   из базы (Tower от EnemySpawner).
##
## Снаряд:
## - arrow_scene должен инстанцироваться как Arrow. Mask = MASK_HOSTILE_PROJECTILE
##   в .tscn — стрела бьёт дружественных + блокируется палисадом.
##
## Не входит в SKELETON_GROUP (это группа melee-скелетов: target_load,
## skel_grid для boids-avoidance). Archer не нуждается в soft-cap «не больше
## 2 на цель» (несколько лучников по одной цели — нормально, концентрированный
## огонь) и не делает boids-avoidance (стоит на месте при стрельбе).

@export_group("Range")
## Предпочтительная верхняя граница огня. Дальше — идёт к цели.
@export var attack_radius_max: float = 14.0
## Минимальная дистанция. Ближе — отступает (kite).
@export var attack_radius_min: float = 8.0
## Радиус обнаружения цели. Должен быть ≥ attack_radius_max, иначе лучник
## «потеряет» цель сразу как выйдет за attack_radius_max при kite-отступе.
@export var vision_radius: float = 18.0
## Доля move_speed при отступе. <1 — отступает медленнее чем атакует.
@export_range(0.0, 1.0) var retreat_speed_factor: float = 0.8

@export_group("Projectile")
@export var arrow_scene: PackedScene = null
@export var arrow_damage_min: float = 12.0
@export var arrow_damage_max: float = 18.0
@export var arrow_speed: float = 22.0
## Точка спавна стрелы относительно archer'а — над головой, чтобы стрела
## не родилась внутри CollisionShape3D и не вылетела сразу в сам archer.
@export var arrow_spawn_offset: Vector3 = Vector3(0.0, 0.6, 0.0)
## Фиксированный разброс прицеливания в метрах. uniform-в-круге через sqrt(rand).
## В отличие от DefenderGnome — без обучения (опыта). Лучник одинаково плох всю
## жизнь, балансится количеством и темпом стрельбы.
@export var arrow_inaccuracy_radius: float = 1.5

@export_group("Shatter (распад на осколки на смерти)")
## Сколько RB-фрагментов спавнить в момент гибели. Меньше чем у Skeleton (7) —
## лучник тоньше, естественно осыпается мельче.
@export var shatter_fragment_count: int = 5
@export var shatter_lifetime: float = 2.0
## Цвет осколков. Дефолт — тёмно-фиолетовый под цвет тушки archer'а
## (albedo в .tscn ≈ Color(0.45, 0.2, 0.65)).
@export var shatter_color: Color = Color(0.45, 0.2, 0.65, 1.0)

@export_group("Debug")
@export var debug_log: bool = false

const SCAN_INTERVAL: float = 0.5

var _projectiles_root: Node = null
var _cached_target: Node3D = null
var _scan_timer: float = 0.0
var _forced_target: Node3D = null

@onready var _mesh: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	super._ready()
	# Phase-jitter скана — иначе пачка archer'ов из одной волны будет
	# каждые SCAN_INTERVAL пересчитывать цели в один кадр и давить spike'ом.
	_scan_timer = randf() * SCAN_INTERVAL
	_projectiles_root = get_tree().current_scene


## Override базового _ai_step. Базовый делает APPROACH через _approach_target
## с melee-семантикой (point-blank trigger). Здесь — своя ranged-логика:
## scan-throttle + kite + WINDUP/STRIKE/COOLDOWN. Базовая STRIKE-ветка
## дёргает наш _perform_strike (override ниже).
func _ai_step(delta: float) -> void:
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = SCAN_INTERVAL
		_rescan_target()
	var target: Node3D = _resolve_target()
	if target == null:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	# WINDUP-таймер тикается только здесь (COOLDOWN — в _physics_process базы).
	if _state == AttackState.WINDUP and _state_timer > 0.0:
		_state_timer = maxf(_state_timer - delta, 0.0)
	match _state:
		AttackState.APPROACH:
			_kite_to_range(target)
		AttackState.WINDUP:
			velocity.x = 0.0
			velocity.z = 0.0
			if _state_timer <= 0.0:
				_enter_state(AttackState.STRIKE)
				_perform_strike(target)
				_enter_state(AttackState.COOLDOWN)
		AttackState.STRIKE:
			pass  # транзитное, мгновенно переходит в COOLDOWN выше
		AttackState.COOLDOWN:
			velocity.x = 0.0
			velocity.z = 0.0
			if _state_timer <= 0.0:
				_enter_state(AttackState.APPROACH)


## Kite: цель далеко — идём, цель слишком близко — отступаем, в зоне — WINDUP.
## Отступ медленнее атаки (retreat_speed_factor) — иначе лучник на отбегает
## безнаказанно от melee. Lookat не нужен — capsule визуально симметричный.
func _kite_to_range(target: Node3D) -> void:
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	var dist: float = to_target.length()
	if dist > attack_radius_max:
		var dir: Vector3 = to_target.normalized()
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
	elif dist < attack_radius_min:
		# Отступаем от цели. Если to_target.length≈0 (наложение позиций) —
		# не двигаемся, иначе normalized() даст NaN.
		if dist < 0.001:
			velocity.x = 0.0
			velocity.z = 0.0
			_enter_state(AttackState.WINDUP)
			return
		var dir: Vector3 = -to_target / dist
		velocity.x = dir.x * move_speed * retreat_speed_factor
		velocity.z = dir.z * move_speed * retreat_speed_factor
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		_enter_state(AttackState.WINDUP)


## Скан целей через общий Enemy._target_grid (3×3 cell'ов вокруг archer'а).
## Кэшируется в _cached_target до следующего SCAN_INTERVAL.
func _rescan_target() -> void:
	Enemy._maybe_refresh_target_grid(get_tree())
	var here: Vector3 = global_position
	var best: Node3D = null
	var best_d_sq: float = vision_radius * vision_radius
	var cell: Vector2i = Enemy._grid_cell(here)
	for cx in range(cell.x - 1, cell.x + 2):
		for cz in range(cell.y - 1, cell.y + 2):
			var entries: Array = Enemy._target_grid.get(Vector2i(cx, cz), [])
			for entry in entries:
				# Variant + is_instance_valid ДО typed-cast — паттерн из Skeleton.
				# Цель могла queue_free'нуться между refresh'ем grid'а и сканом
				# (волна за 0.5с может убить 2-3 гнома). Typed `var node: Node3D
				# = entry[1]` на freed-ссылке вылетает с "Trying to assign
				# invalid previously freed instance".
				var raw = entry[1]
				if not is_instance_valid(raw):
					continue
				var node := raw as Node3D
				if node == null:
					continue
				# Skip melee-only цели (палисад, будущие стены/ворота). Они есть
				# в TARGET_GROUP для melee-ломаемости, но стрелять в них бесполезно.
				if node.is_in_group(Enemy.MELEE_ONLY_TARGET_GROUP):
					continue
				var d_sq: float = (node.global_position - here).length_squared()
				if d_sq < best_d_sq:
					best_d_sq = d_sq
					best = node
	_cached_target = best


## Резолв цели для текущего тика. Приоритет: scan-кэш → forced_target →
## base get_active_target (Tower от EnemySpawner). is_instance_valid проверки
## везде — цели queue_free'аются, кэш может протухнуть между сканами.
##
## Фильтр forced_target через виртуал `_target_still_valid` (живёт в Enemy
## с default-TARGET_GROUP) — наследники (SkeletonGiantThrower → Tower) могут
## разрешить дополнительные группы, не override'я весь _resolve_target.
func _resolve_target() -> Node3D:
	if is_instance_valid(_cached_target):
		return _cached_target
	if is_instance_valid(_forced_target) and _target_still_valid(_forced_target):
		return _forced_target
	var base_target: Node3D = get_active_target()
	if is_instance_valid(base_target):
		return base_target
	return null


## Override: вместо melee-AoE из Skeleton — выстрел стрелы. Спавн в
## _projectiles_root, баллистика через Arrow.setup. Inaccuracy — фиксированная
## (без обучения как у DefenderGnome).
func _perform_strike(target: Node3D) -> void:
	if not is_instance_valid(target):
		return
	if arrow_scene == null:
		push_warning("SkeletonArcher: arrow_scene не задан")
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		push_warning("SkeletonArcher: arrow_scene не инстанцируется как Arrow")
		return
	if not is_instance_valid(_projectiles_root):
		_projectiles_root = get_tree().current_scene
	_projectiles_root.add_child(arrow)
	var damage: float = randf_range(arrow_damage_min, arrow_damage_max)
	var spawn: Vector3 = global_position + arrow_spawn_offset
	# Прицел с рандомным смещением в круге inaccuracy. sqrt(rand) — uniform-в-круге.
	var aim: Vector3 = target.global_position
	if arrow_inaccuracy_radius > 0.0:
		var angle: float = randf() * TAU
		var r: float = sqrt(randf()) * arrow_inaccuracy_radius
		aim.x += cos(angle) * r
		aim.z += sin(angle) * r
	arrow.damage = damage
	arrow.speed = arrow_speed
	arrow.setup(spawn, aim)
	# Alarm-сигнал: outgoing shot по не-защитнику = атака лагеря, защитники
	# реагируют через `_alarm_target` (override cone-фильтра). Параллелит melee
	# `Skeleton._perform_strike` (см. skeleton.gd:1449). Без этого archer мог
	# держаться 8-14м от защитника, оставаться вне 90°-конуса и стрелять
	# безнаказанно — защитники не «слышали тетиву». Фильтр «наш лагерь»
	# применяется на стороне получателя в `DefenderGnome._on_skeleton_attacked_camp`.
	if not target.is_in_group(DefenderGnome.DEFENDER_GROUP):
		EventBus.skeleton_attacked_camp.emit(self, target, target.global_position)
	if debug_log and LogConfig.master_enabled:
		var d: float = global_position.distance_to(target.global_position)
		print("[Archer:%s] выстрел в %s (dist=%.1fм, dmg=%.1f)" % [name, target.name, d, damage])


## Duck-typed контракт для WaveDirector._assign_forced_targets (см. enemy.gd
## и wave_director.gd). Скелет-melee имеет тот же метод — WaveDirector
## вызывает через has_method, не зная типа.
func set_forced_target(target: Node3D) -> void:
	_forced_target = target


## Override Enemy._on_destroyed: прячем тело и спавним RB-осколки через
## ShatterEffect (тот же модуль что у Skeleton'а). Без этого override'а
## archer просто исчезал на смерти — визуально не читалось как «убил».
## Осколки живут в _effects_root, переживают queue_free archer'а.
func _on_destroyed() -> void:
	if _mesh != null:
		_mesh.visible = false
	if _effects_root != null:
		ShatterEffect.spawn(_effects_root, global_position, shatter_color,
			shatter_fragment_count, shatter_lifetime)
