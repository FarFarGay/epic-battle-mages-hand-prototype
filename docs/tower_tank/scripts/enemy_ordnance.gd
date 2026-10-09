extends Node3D
## A bounded set of simple ballistic stones; no per-stone physics bodies.
const Geo = preload("res://scripts/geo.gd")
var battle
var stones: Array[Dictionary] = []
var stone_mesh: SphereMesh
var ring_mesh: TorusMesh
var stone_material: Material
var warning_material: Material

func _ready() -> void:
	stone_mesh = SphereMesh.new()
	stone_mesh.radius = 0.27
	stone_mesh.height = 0.54
	stone_mesh.radial_segments = 8
	stone_mesh.rings = 4
	ring_mesh = TorusMesh.new()
	ring_mesh.inner_radius = 0.94
	ring_mesh.outer_radius = 1.0
	ring_mesh.rings = 24
	ring_mesh.ring_segments = 4
	stone_material = Geo.material(Color("6b5350"))
	warning_material = Geo.material(Color("ef794b"), 0, 0.6)

func reset() -> void:
	for stone in stones:
		stone.node.queue_free()
		stone.marker.queue_free()
	stones.clear()

func throw_stone(from: Vector3, to: Vector3, settings) -> bool:
	if stones.size() >= 96: return false
	to.y = battle.arena.ground_height(to)+0.08
	var node := Geo.mesh(self, stone_mesh, from, stone_material)
	var marker := Geo.mesh(self, ring_mesh, to, warning_material)
	marker.scale = Vector3(settings.stone_radius, 0.1, settings.stone_radius)
	Geo.mark_ui(marker)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stones.append({"node":node,"marker":marker,"from":from,"to":to,"age":0.0,"time":maxf(settings.stone_flight_time,0.2),"damage":settings.stone_damage,"radius":settings.stone_radius})
	return true

func tick(dt: float) -> void:
	for i in range(stones.size()-1,-1,-1):
		var stone := stones[i]
		stone.age += dt
		var t := minf(stone.age/stone.time, 1.0)
		var next: Vector3 = stone.from.lerp(stone.to,t)+Vector3.UP*(4.0*4.5*t*(1.0-t))
		var ray := PhysicsRayQueryParameters3D.create(stone.node.position,next,1|2|4|8|32)
		var hit := get_world_3d().direct_space_state.intersect_ray(ray)
		stone.node.position = next
		stone.node.rotation += Vector3(3,2,1)*dt
		if not hit.is_empty() or t >= 1.0:
			blast(hit.position if not hit.is_empty() else stone.to, stone.radius, stone.damage, false)
			stone.node.queue_free()
			stone.marker.queue_free()
			stones.remove_at(i)

func blast(point: Vector3, radius: float, damage: float, bomb: bool) -> void:
	var arena = battle.arena
	for victim in battle.player_targets():
		var offset: Vector3 = victim.global_position-point
		var reach := radius+(1.32 if victim==arena.tank else 0.25)
		if offset.length_squared()>reach*reach: continue
		if not battle.clear_sight(point,victim.global_position,victim): continue
		if victim==arena.tank: victim.take_damage(damage)
		else: victim.take_damage(damage, offset.normalized()*2.0)
	if bomb:
		arena.props.blast(point,radius)
		# Powder barrels retain their existing delayed chain-reaction logic.
		for target in arena.targets.duplicate():
			if is_instance_valid(target) and target.position.distance_to(point)<radius:
				arena._damage_target(target,damage)
		arena.fx.impact(point,false)
		arena.add_trauma(0.25*clampf(1.0-arena.tank.position.distance_to(point)/35.0,0.0,1.0))
		arena.sound.play("impact",-9.0,1.15)
	else:
		arena.fx.repeater_hit(point,Vector3.UP)
		arena.fx.dust(point,Vector3.UP*3)
		arena.sound.play("shatter",-14.0,0.7)
