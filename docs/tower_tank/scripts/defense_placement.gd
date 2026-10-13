extends RefCounted
## Check the whole footprint against the authored plateau and physics scene.
const RADIUS := 1.7
var arena
var atoll: Node3D
var mesa: StaticBody3D

func surface(point: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(point+Vector3.UP*20,point-Vector3.UP*20,1024)
	return arena.get_world_3d().direct_space_state.intersect_ray(query)

func on_atoll(point: Vector3) -> bool:
	var hit := surface(point)
	return not hit.is_empty() and hit.collider==mesa and absf(point.y-hit.position.y)<1.2

func reason(point: Vector3) -> String:
	for offset in [Vector2.ZERO,Vector2(1,0),Vector2(-1,0),Vector2(0,1),Vector2(0,-1),Vector2(.707,.707),Vector2(-.707,.707),Vector2(.707,-.707),Vector2(-.707,-.707)]:
		var sample := point+Vector3(offset.x,0,offset.y)*RADIUS
		var hit := surface(sample)
		if hit.is_empty() or hit.collider!=mesa or hit.normal.y<0.98 or absf(hit.position.y-point.y)>0.12:
			return "Нужна ровная площадка на атолле · отступи от края"
	var local := atoll.to_local(point)
	var workshop_point: Vector3 = point-arena.defenses.mechanic.global_position
	if Rect2(-5,-4,10,9).grow(RADIUS).has_point(Vector2(workshop_point.x,workshop_point.z)):
		return "Место для будущей мастерской механика"
	if arena.defenses.pyrotechnician.reserves_point(point,RADIUS):
		return "Оставь свободной площадку выдачи пиротехника"
	if Rect2(16,-11,20,22).grow(RADIUS).has_point(Vector2(local.x,local.z)):
		return "Оставь свободным вход в шахту"
	for entrance in arena.level.defense_waves.get_node("Entrances").get_children():
		var crest: Vector3 = entrance.get_node("Crest").global_position
		var foot: Vector3 = entrance.get_node("Foot").global_position
		var delta := Vector2(crest.x-foot.x,crest.z-foot.z).normalized()*6.0
		var closest := Geometry2D.get_closest_point_to_segment(Vector2(point.x,point.z),Vector2(crest.x,crest.z),Vector2(crest.x,crest.z)+delta)
		if closest.distance_to(Vector2(point.x,point.z))<3.5+RADIUS:
			return "Оставь свободным выход с пандуса"
	# Include structures placed this frame, before the physics server syncs.
	for site in arena.defenses.sites:
		if is_instance_valid(site.tower) and Vector2(site.global_position.x-point.x,site.global_position.z-point.z).length()<RADIUS*2:
			return "Слишком близко к другой башне"
	var shape := CylinderShape3D.new()
	shape.radius = RADIUS
	shape.height = 5.0
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform.origin = point+Vector3.UP*2.6
	query.collision_mask = 1|2|4|8|32|64
	if not arena.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty():
		return "Место занято · отступи от здания или отряда"
	return ""
