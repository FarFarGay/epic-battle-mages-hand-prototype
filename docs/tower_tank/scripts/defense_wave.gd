@tool
extends Node
## One editable wave. Story events are deliberately not wired to gameplay yet.
@export var enabled := true
@export var start_event: StringName = &"village_wave_1"
@export var entrances: Array[NodePath] = []
@export_group("Composition")
@export_range(0, 1000) var ordinary := 250
@export_range(0, 1000) var shields := 50
@export_range(0, 100) var giants := 0
@export_range(0, 500) var bombers := 0
@export_range(0, 500) var throwers := 0
@export_group("Spawn pacing")
@export_range(1, 24) var spawn_per_frame := 6

func total() -> int:
	return ordinary + shields + giants + bombers + throwers

func composition() -> Dictionary:
	return {&"ordinary":ordinary, &"shield":shields, &"giant":giants, &"bomber":bombers, &"thrower":throwers}
