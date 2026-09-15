extends SceneTree
## Run against the source project with --script and -- --out=<absolute folder>.
func _initialize() -> void:
	_export.call_deferred()

func _export() -> void:
	var output := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
	if output.is_empty():
		push_error("Missing --out=<folder>")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var sound = load("res://scripts/sound.gd").new()
	root.add_child(sound)
	var exported := []
	for kind in ["fire", "impact", "eject", "chamber", "lock", "ready", "repeater", "bolt_hit", "repeater_reload", "step"]:
		var error: int = sound.bank[kind].save_to_wav(output.path_join(kind + ".wav"))
		if error != OK:
			push_error("Cannot export " + kind)
			quit(1)
			return
		exported.append(kind)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 24.0
	var metadata := {"audio": exported, "sample_rate": sound.RATE, "camera_keep_aspect_enum": camera.keep_aspect, "camera_size": camera.size, "viewport_size": root.size, "projection": str(camera.get_camera_projection())}
	var file := FileAccess.open(output.path_join("export_metadata.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(metadata, "  "))
	file.close()
	print("REFERENCE_AUDIO: ", JSON.stringify(metadata))
	sound.queue_free()
	await process_frame
	quit()
