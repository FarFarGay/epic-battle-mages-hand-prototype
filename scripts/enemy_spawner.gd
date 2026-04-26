extends Node3D
## Спавнер врагов. По input action `spawn_enemies` порождает партию врагов
## равномерно по всей карте — позиция выбирается uniform из квадрата
## ±map_half_extent от центра (0,0).
##
## Не зависит ни от Skeleton, ни от Tower напрямую: всё через PackedScene и NodePath.
## Поддерживает несколько типов врагов через параллельные массивы enemy_scenes/enemy_counts.
## TODO: заменить на Array[WaveEntry: Resource] когда волн будет >2.
## Спавн распределяется по нескольким физкадрам, чтобы не было фрейм-спайка.
##
## target_path всё ещё нужен: базовый Enemy.set_target вызывается на спавне,
## чтобы будущие враги без vision-override (Skeleton override'ит и игнорирует
## _targets) могли таргетить башню по-старому.

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


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("spawn_enemies"):
		spawn_wave()


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
