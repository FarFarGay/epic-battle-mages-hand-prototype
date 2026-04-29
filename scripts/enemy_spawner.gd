class_name EnemySpawner
extends Node3D
## Спавнер врагов — низкоуровневый «как». Порождает партии по PackedScene в
## заданных паттернах (uniform по карте, кольцо вокруг точки), распределяя
## спавн по нескольким физкадрам чтобы не было фрейм-спайка.
##
## Не зависит ни от Skeleton, ни от Tower напрямую: всё через PackedScene и NodePath.
## target_path нужен: базовый Enemy.set_target вызывается на спавне для будущих
## врагов без vision-override (Skeleton override'ит и игнорирует _targets).
##
## Высокоуровневое «когда и сколько» (фазы кампании, волны, респавн) живёт в
## WaveDirector — он зовёт публичные spawn_uniform / spawn_ring отсюда. Старый
## spawn_wave() со списками enemy_scenes/enemy_counts оставлен как debug helper
## (можно вызвать вручную для смешанных волн без режиссёра).

@export var enemy_scenes: Array[PackedScene]
@export var enemy_counts: Array[int]
@export_node_path("Node3D") var target_path: NodePath
@export_node_path("Node") var spawn_root_path: NodePath
## Полу-длина квадратной карты от центра (0,0). Спавн uniform в [-extent, extent].
@export var map_half_extent: float = 95.0
## Y-координата спавна врагов (над уровнем земли).
@export var spawn_y: float = 1.0
@export var debug_log: bool = true

const _SPAWNS_PER_FRAME: int = 6

var _target: Node3D
var _spawn_root: Node


func _ready() -> void:
	if not target_path.is_empty():
		_target = get_node_or_null(target_path)
	if not _target:
		push_warning("EnemySpawner: target_path не разрешился, цель не задана")
	if not spawn_root_path.is_empty():
		_spawn_root = get_node_or_null(spawn_root_path)
	if not _spawn_root:
		_spawn_root = get_tree().current_scene


# --- Публичный API для WaveDirector ---

## Спавн одного врага в указанной точке. Синхронный, без yield —
## вызывается из режиссёрских таймеров (по 1 скелету раз в N сек).
func spawn_at(scene: PackedScene, pos: Vector3) -> Enemy:
	if scene == null or not is_instance_valid(_spawn_root):
		return null
	var instance := scene.instantiate()
	var enemy := instance as Enemy
	if not enemy:
		push_warning("EnemySpawner.spawn_at: сцена не инстанцируется как Enemy")
		if instance:
			instance.queue_free()
		return null
	_spawn_root.add_child(enemy)
	enemy.global_position = pos
	if is_instance_valid(_target):
		enemy.set_target(_target)
	return enemy


## Спавн `count` врагов uniform по квадрату карты. Async — распределено
## по физкадрам через _SPAWNS_PER_FRAME, чтобы первичная волна 20-50
## штук не давала фрейм-спайка.
func spawn_uniform(scene: PackedScene, count: int) -> void:
	if scene == null or count <= 0:
		return
	var spawned := 0
	for i in range(count):
		var pos := Vector3(
			randf_range(-map_half_extent, map_half_extent),
			spawn_y,
			randf_range(-map_half_extent, map_half_extent),
		)
		if spawn_at(scene, pos):
			spawned += 1
		if (i + 1) % _SPAWNS_PER_FRAME == 0:
			if not await _yield_and_validate():
				return
	if debug_log and LogConfig.master_enabled:
		print("[EnemySpawner] uniform: %d/%d врагов спавнено" % [spawned, count])


## Спавн `count` врагов **группой** в малом радиусе вокруг `center` —
## используется для волн: 10 скелетов появляются рядом друг с другом
## в случайной точке карты. Синхронный (10 спавнов в кадре — терпимо,
## без yield, чтобы WaveDirector мог сразу присвоить forced_target).
## Возвращает список спавненных Enemy для постобработки.
func spawn_group(scene: PackedScene, count: int, center: Vector3, group_radius: float) -> Array[Enemy]:
	var spawned: Array[Enemy] = []
	if scene == null or count <= 0:
		return spawned
	for i in range(count):
		var angle := randf() * TAU
		var r := sqrt(randf()) * group_radius  # sqrt — uniform в круге, не кучкуется в центре
		var pos := Vector3(
			center.x + cos(angle) * r,
			spawn_y,
			center.z + sin(angle) * r,
		)
		pos.x = clampf(pos.x, -map_half_extent, map_half_extent)
		pos.z = clampf(pos.z, -map_half_extent, map_half_extent)
		var enemy := spawn_at(scene, pos)
		if enemy:
			spawned.append(enemy)
	if debug_log and LogConfig.master_enabled:
		print("[EnemySpawner] group: %d/%d врагов в (%.1f, %.1f) r=%.1f" % [spawned.size(), count, center.x, center.z, group_radius])
	return spawned


## Спавн `count` врагов на кольце радиуса `radius` вокруг `center`. Углы
## распределены равномерно (`TAU / count`) с jitter'ом ±angle_jitter_deg
## и ±radius_jitter, чтобы кольцо выглядело естественно, а не правильным
## многоугольником. Async, как spawn_uniform.
func spawn_ring(scene: PackedScene, count: int, center: Vector3, radius: float, angle_jitter_deg: float = 15.0, radius_jitter: float = 3.0) -> void:
	if scene == null or count <= 0:
		return
	var jitter_rad := deg_to_rad(angle_jitter_deg)
	var spawned := 0
	for i in range(count):
		var base_angle := float(i) * TAU / float(count)
		var angle := base_angle + randf_range(-jitter_rad, jitter_rad)
		var r := radius + randf_range(-radius_jitter, radius_jitter)
		var pos := Vector3(
			center.x + cos(angle) * r,
			spawn_y,
			center.z + sin(angle) * r,
		)
		# Clamp в пределах карты — на случай если центр близко к краю.
		pos.x = clampf(pos.x, -map_half_extent, map_half_extent)
		pos.z = clampf(pos.z, -map_half_extent, map_half_extent)
		if spawn_at(scene, pos):
			spawned += 1
		if (i + 1) % _SPAWNS_PER_FRAME == 0:
			if not await _yield_and_validate():
				return
	if debug_log and LogConfig.master_enabled:
		print("[EnemySpawner] ring: %d/%d врагов вокруг (%.1f, %.1f) r=%.1f" % [spawned, count, center.x, center.z, radius])


## Удаляет всех живых скелетов из сцены. Используется WaveDirector'ом при
## P-рестарте кампании. Группа `skeleton` ставится в Skeleton._ready —
## другие враги (если появятся) сюда не попадут. queue_free, без shatter
## (визуальный эффект тут не нужен — это «обнуление», не смерть).
func kill_all_skeletons() -> int:
	var killed := 0
	for n in get_tree().get_nodes_in_group(&"skeleton"):
		if is_instance_valid(n):
			n.queue_free()
			killed += 1
	if debug_log and LogConfig.master_enabled:
		print("[EnemySpawner] вычищено скелетов: %d" % killed)
	return killed


# --- Старый API (debug helper для ручных смешанных волн) ---

func spawn_wave() -> void:
	if enemy_scenes.size() != enemy_counts.size():
		push_error("EnemySpawner: размеры enemy_scenes (%d) и enemy_counts (%d) не совпадают" % [enemy_scenes.size(), enemy_counts.size()])
		return
	if not is_instance_valid(_spawn_root):
		push_error("EnemySpawner: spawn_root не найден")
		return

	var spawned := 0
	var overall := 0

	for type_index in range(enemy_scenes.size()):
		var scene: PackedScene = enemy_scenes[type_index]
		var count: int = enemy_counts[type_index]
		var warned_for_type := false

		for i in range(count):
			var instance := scene.instantiate() if scene else null
			var enemy := instance as Enemy
			if not enemy:
				if not warned_for_type:
					push_warning("EnemySpawner: сцена[%d] не инстанцируется как Enemy, пропуск" % type_index)
					warned_for_type = true
				if instance:
					instance.queue_free()
				overall += 1
				if overall % _SPAWNS_PER_FRAME == 0:
					if not await _yield_and_validate():
						return
				continue

			var pos := Vector3(
				randf_range(-map_half_extent, map_half_extent),
				spawn_y,
				randf_range(-map_half_extent, map_half_extent),
			)
			_spawn_root.add_child(enemy)
			enemy.global_position = pos
			# Базовая Enemy._targets — фолбэк для будущих врагов без vision-override.
			# Skeleton override'ит get_active_target и эту цель игнорирует.
			if is_instance_valid(_target):
				enemy.set_target(_target)
			spawned += 1
			overall += 1

			if overall % _SPAWNS_PER_FRAME == 0:
				if not await _yield_and_validate():
					return

	if debug_log and LogConfig.master_enabled:
		print("[EnemySpawner] спавн волны: %d врагов uniform по карте (±%.0f)" % [spawned, map_half_extent])


# Yield + проверка, что спавнер ещё в дереве. Возвращает false → caller прерывается.
func _yield_and_validate() -> bool:
	await get_tree().physics_frame
	return is_inside_tree() and is_instance_valid(_spawn_root)
