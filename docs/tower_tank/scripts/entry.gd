extends Node

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var old_range := args.has("--range")
	for arg in args:
		if (arg.ends_with("-check") or arg == "--smoke") and arg != "--level-check": old_range = true
	get_tree().change_scene_to_file.call_deferred("res://main.tscn" if old_range else "res://desert.tscn")
