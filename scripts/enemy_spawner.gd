extends Node3D
## Спавнер врагов. По input action `spawn_enemies` порождает партию скелетов
## кольцом вокруг target.
##
## Не зависит ни от Skeleton, ни от Tower напрямую: всё через PackedScene и NodePath.

@export var skeleton_scene: PackedScene
@export_node_path("Node3D") var target_path: NodePath
@export var spawn_radius: float = 25.0
@export var spawn_radius_jitter: float = 0.3
@export var spawn_count: int = 50
@export var debug_log: bool = true

var _target: Node3D


func _ready() -> void:
	if not target_path.is_empty():
		_target = get_node_or_null(target_path)
	if not _target:
		push_warning("EnemySpawner: target_path не разрешился, цель не задана")


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("spawn_enemies"):
		spawn_skeleton_wave()


func spawn_skeleton_wave() -> void:
	if not skeleton_scene:
		push_error("EnemySpawner: skeleton_scene не задан")
		return
	if not _target:
		push_error("EnemySpawner: target не найден")
		return
	var center: Vector3 = _target.global_position
	var spawned := 0
	for i in range(spawn_count):
		var skeleton := skeleton_scene.instantiate() as Skeleton
		if not skeleton:
			continue
		var angle := randf() * TAU
		var dist := spawn_radius * (1.0 + (randf() - 0.5) * spawn_radius_jitter)
		var pos := center + Vector3(cos(angle) * dist, 1.0, sin(angle) * dist)
		get_tree().current_scene.add_child(skeleton)
		skeleton.global_position = pos
		skeleton.set_target(_target)
		spawned += 1
	if debug_log:
		print("[EnemySpawner] спавн волны: %d скелетов вокруг %s" % [spawned, _target.name])
