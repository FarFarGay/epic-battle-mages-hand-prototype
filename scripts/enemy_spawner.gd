extends Node3D
## Спавнер врагов. По input action `spawn_enemies` порождает партию врагов
## кольцом вокруг target.
##
## Не зависит ни от Skeleton, ни от Tower напрямую: всё через PackedScene и NodePath.
## Поддерживает несколько типов врагов через параллельные массивы enemy_scenes/enemy_counts.
## TODO: заменить на Array[WaveEntry: Resource] когда волн будет >2.
## Спавн распределяется по нескольким физкадрам, чтобы не было фрейм-спайка.

@export var enemy_scenes: Array[PackedScene]
@export var enemy_counts: Array[int]
@export_node_path("Node3D") var target_path: NodePath
@export_node_path("Node") var spawn_root_path: NodePath
@export var spawn_radius: float = 25.0
@export var spawn_radius_jitter: float = 0.3
@export var spawn_height_offset: float = 1.0
@export var debug_log: bool = true

const _SPAWNS_PER_FRAME: int = 6
const _CENTER_INVALID := Vector3.INF

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
	if not is_instance_valid(_target):
		push_error("EnemySpawner: target не найден")
		return
	if not is_instance_valid(_spawn_root):
		push_error("EnemySpawner: spawn_root не найден")
		return

	var center: Vector3 = _target.global_position
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
					var fresh := await _yield_frame_and_recenter()
					if fresh == _CENTER_INVALID:
						return
					center = fresh
				continue

			var angle := randf() * TAU
			var dist := spawn_radius * (1.0 + (randf() - 0.5) * spawn_radius_jitter)
			var pos := Vector3(
				center.x + cos(angle) * dist,
				_target.global_position.y + spawn_height_offset,
				center.z + sin(angle) * dist
			)
			_spawn_root.add_child(enemy)
			enemy.global_position = pos
			enemy.set_target(_target)
			spawned += 1
			overall += 1

			if overall % _SPAWNS_PER_FRAME == 0:
				var fresh := await _yield_frame_and_recenter()
				if fresh == _CENTER_INVALID:
					return
				center = fresh

	if debug_log and LogConfig.master_enabled:
		print("[EnemySpawner] спавн волны: %d врагов вокруг %s" % [spawned, _target.name])


# Один await + проверка валидности target и спавнера. Возвращает свежий center
# либо _CENTER_INVALID, если что-то протухло — caller прерывается.
func _yield_frame_and_recenter() -> Vector3:
	await get_tree().physics_frame
	if not is_inside_tree():
		return _CENTER_INVALID
	if not is_instance_valid(_target):
		return _CENTER_INVALID
	return _target.global_position
