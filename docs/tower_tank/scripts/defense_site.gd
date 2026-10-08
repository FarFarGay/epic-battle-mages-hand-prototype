extends Node3D
## Authored build slot. Move or duplicate this node in desert.tscn.
@export var tower_scene: PackedScene
@export_range(1,1000) var crystal_cost := 10
@export_range(5.0,60.0) var firing_range := 27.0
@export_range(15.0,180.0) var sector_degrees := 110.0
@export_range(1.0,100.0) var bolt_damage := 8.0
@export_range(1,30) var burst_size := 5
@export_range(0.05,1.0) var shot_interval := 0.10
@export_range(0.2,10.0) var burst_reload := 1.8
var tower
var arena
var picker: StaticBody3D
var ring: MeshInstance3D

func _ready() -> void:
	picker = get_node("Pick")
	picker.set_meta("defense_site",self)
	ring = get_node("BuildRing")

func reset() -> void:
	if is_instance_valid(tower):
		tower.collision_layer = 0
		tower.queue_free()
	tower = null
	ring.show()
	if arena and arena.battle: arena.battle.nav_dirty = true

func construct(yaw: float) -> Node3D:
	if is_instance_valid(tower): return tower
	tower = tower_scene.instantiate()
	tower.arena = arena
	tower.site = self
	add_child(tower)
	tower.global_rotation.y = yaw
	tower.collision_layer = 1 | 2048
	tower.set_meta("defense_site",self)
	ring.hide()
	arena.battle.nav_dirty = true
	return tower
