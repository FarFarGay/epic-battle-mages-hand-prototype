extends Node3D
## Плавно следует за указанным узлом. Цель задаётся через @export.

@export_node_path("Node3D") var target_path: NodePath
@export var follow_speed: float = 8.0

var _target: Node3D


func _ready() -> void:
	if not target_path.is_empty():
		_target = get_node_or_null(target_path)
	if _target:
		global_position = _target.global_position


func _process(delta: float) -> void:
	if not _target:
		return
	global_position = global_position.lerp(_target.global_position, follow_speed * delta)
