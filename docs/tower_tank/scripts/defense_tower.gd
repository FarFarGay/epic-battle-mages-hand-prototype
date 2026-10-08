extends StaticBody3D
## Fixed firing sector with target tracking inside it and physical burst bolts.
const Geo = preload("res://scripts/geo.gd")
const BOLT_SPEED := 48.0
var arena
var site
var preview := false
var turret: Node3D
var rail: Node3D
var muzzle: Marker3D
var target: Node3D
var scan_left := 0.0
var shot_left := 0.0
var reload_left := 0.0
var burst_left := 0
var recoil := 0.0
var shots_fired := 0
var bolts: Array[Dictionary] = []
var bolt_material := Geo.material(Color("ffe3a0"),0.2,1.4)

func _ready() -> void:
	turret = get_node("Turret")
	rail = get_node("Turret/Rail")
	muzzle = get_node("Turret/Rail/Muzzle")
	if preview: collision_layer = 0

func aim_point(enemy: Node3D) -> Vector3:
	return enemy.global_position+Vector3.UP*enemy.body_height*0.55

func in_sector(enemy: Node3D) -> bool:
	if not is_instance_valid(enemy) or enemy.is_queued_for_deletion() or enemy.dead or enemy.hand_held or enemy.hand_thrown: return false
	var offset := enemy.global_position-global_position
	offset.y = 0
	var distance := offset.length()
	if distance<0.4 or distance>site.firing_range: return false
	var forward := -global_basis.z.normalized()
	return forward.dot(offset/distance)>=cos(deg_to_rad(site.sector_degrees*0.5))

func has_sight(enemy: Node3D) -> bool:
	if not in_sector(enemy): return false
	var barrel_query := PhysicsRayQueryParameters3D.create(turret.global_position,muzzle.global_position,1|8|32,[get_rid()])
	barrel_query.hit_from_inside = true
	if not get_world_3d().direct_space_state.intersect_ray(barrel_query).is_empty(): return false
	var query := PhysicsRayQueryParameters3D.create(muzzle.global_position,aim_point(enemy),1|8|32,[get_rid()])
	query.hit_from_inside = true
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func _acquire() -> void:
	target = null
	var nearest := INF
	# Three local slots: cheap range/sector rejection before any line-of-sight ray.
	for enemy in arena.battle.enemies:
		if not in_sector(enemy): continue
		var distance := global_position.distance_squared_to(enemy.global_position)
		if distance<nearest and has_sight(enemy):
			nearest = distance
			target = enemy

func tick(dt: float) -> void:
	if preview: return
	_tick_bolts(dt)
	recoil = move_toward(recoil,0.0,dt*1.4)
	rail.position.z = recoil
	reload_left = maxf(0.0,reload_left-dt)
	shot_left = maxf(0.0,shot_left-dt)
	scan_left -= dt
	if not is_instance_valid(target) or not in_sector(target): target = null
	if scan_left<=0.0:
		scan_left = 0.20
		_acquire()
	if not is_instance_valid(target):
		if burst_left>0:
			burst_left = 0
			reload_left = maxf(reload_left,site.burst_reload)
		return
	var local := global_basis.inverse()*(aim_point(target)-turret.global_position)
	var desired_yaw := atan2(-local.x,-local.z)
	turret.rotation.y = lerp_angle(turret.rotation.y,desired_yaw,1.0-exp(-dt*12.0))
	rail.rotation.x = lerp_angle(rail.rotation.x,atan2(local.y,Vector2(local.x,local.z).length()),1.0-exp(-dt*12.0))
	if reload_left>0.00001 or shot_left>0.00001 or absf(angle_difference(turret.rotation.y,desired_yaw))>0.12: return
	if not has_sight(target):
		target = null
		return
	if burst_left==0: burst_left = site.burst_size
	_fire()
	burst_left -= 1
	shot_left = site.shot_interval
	if burst_left==0: reload_left = site.burst_reload

func _fire() -> void:
	var origin := muzzle.global_position
	var direction := (aim_point(target)-origin).normalized()
	var bolt := Geo.box(arena,Vector3(0.055,0.055,0.65),origin,bolt_material)
	bolt.name = "DefenseBolt"
	bolt.look_at(origin+direction)
	bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bolts.append({"node":bolt,"direction":direction,"remaining":site.firing_range})
	shots_fired += 1
	recoil = 0.16
	arena.fx.repeater_muzzle(origin,direction)
	if arena.camera.global_position.distance_to(origin)<90:
		arena.sound.play("repeater",-16.0,0.82)

func _tick_bolts(dt: float) -> void:
	for i in range(bolts.size()-1,-1,-1):
		var bolt: Dictionary = bolts[i]
		var start: Vector3 = bolt.node.global_position
		var distance: float = minf(BOLT_SPEED*dt,bolt.remaining)
		var finish: Vector3 = start+bolt.direction*distance
		var query := PhysicsRayQueryParameters3D.create(start,finish,1|8|32|64,[get_rid()])
		query.hit_from_inside = true
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		var end: Vector3 = hit.position if hit else finish
		arena.fx.repeater_trail(start,end)
		bolt.node.global_position = end
		bolt.remaining -= distance
		if hit:
			if hit.collider.has_meta("enemy") or hit.collider.has_meta("target"):
				arena._damage_target(hit.collider,site.bolt_damage,bolt.direction,1.0)
			elif hit.collider.get_meta("breakable",false): arena.props.shatter(hit.collider,bolt.direction)
			arena.fx.repeater_hit(hit.position,hit.normal)
		if hit or bolt.remaining<=0:
			bolt.node.queue_free()
			bolts.remove_at(i)

func change_heading(yaw: float) -> void:
	global_rotation.y = yaw
	target = null
	burst_left = 0
	scan_left = 0

func _exit_tree() -> void:
	for bolt in bolts:
		if is_instance_valid(bolt.node): bolt.node.queue_free()
	bolts.clear()
