@tool
extends Node3D
## Move/duplicate/delete this node to edit the starting layout. Body contains
## the actual editable mesh and collision used by the game, not a proxy.
@export_enum("Prop", "Powder", "Ore", "Cargo", "Weight", "Chest", "BridgeSection", "Enemy", "Player", "MineDefense") var kind := "Prop"
@export var enabled := true
@export_enum("Ordinary", "Shield", "Giant") var enemy_type := "Ordinary":
	set(value):
		enemy_type = value
		if Engine.is_editor_hint(): _refresh.call_deferred()
@export var patrol := false
@export_range(1, 600) var wave_count := 20
@export_range(0, 100) var wave_giants := 1
@export_range(1.0, 10000.0) var health := 100.0

func _ready() -> void:
	if Engine.is_editor_hint(): _refresh()

func _refresh() -> void:
	if not Engine.is_editor_hint() or kind != "Enemy": return
	var shield := get_node_or_null("Shield")
	if shield: shield.visible = enemy_type == "Shield"
	var gear := get_node_or_null("GuardGear")
	if gear: gear.visible = enemy_type == "Shield"
	var body := get_node_or_null("Skeleton")
	if body: body.scale = Vector3.ONE * (1.8 if enemy_type == "Giant" else 1.0)
