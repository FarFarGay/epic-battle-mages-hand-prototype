@tool
extends Node3D
## Spawn faces along local -Z. Move Spawn / Foot / Crest in the editor.
@export_range(2, 20) var columns := 6
@export_range(2, 60) var rows := 30
@export_range(1.5, 4.0) var spacing := 1.8
@export_range(0.0, 2.0) var route_half_width := 1.4
var cursor := 0

func candidate() -> Vector3:
	var slot := cursor % (columns * rows)
	cursor += 1
	return $Spawn.to_global(Vector3((slot % columns - (columns-1)*0.5)*spacing, 0, (slot / columns)*spacing))

func route(lane: float) -> PackedVector3Array:
	var side: Vector3 = $Spawn.global_basis.x * lane * route_half_width
	return PackedVector3Array([$Foot.global_position+side, $Crest.global_position+side])
