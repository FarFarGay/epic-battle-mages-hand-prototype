extends RigidBody3D
## A tumbling disk settles onto its supporting surface before it goes to sleep.
var age := 0.0

func _ready() -> void:
	can_sleep = false

func on_hand_release(motion: Vector3) -> void:
	age = 0.0
	can_sleep = false
	linear_velocity = motion

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if freeze or has_meta("hand_owner"): return
	age += state.step
	if age<0.8 or gravity_scale<=0.0 or state.get_contact_count()==0 or state.linear_velocity.length_squared()>0.09: return
	var pose := state.transform
	var ray := PhysicsRayQueryParameters3D.create(pose.origin+Vector3.UP*0.23,pose.origin-Vector3.UP*0.32,1|8|32|1024,[get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty() or hit.normal.y<0.65: return
	var normal: Vector3 = hit.normal
	var up := normal if pose.basis.y.dot(normal)>=0.0 else -normal
	var right := pose.basis.x.slide(up).normalized()
	if right.is_zero_approx(): right = Vector3.RIGHT.slide(up).normalized()
	var rest_basis := Basis(right,up,right.cross(up).normalized())
	# Small disks can reach the engine's sleep threshold while balancing on
	# an edge. Finish that last tip smoothly, without snapping airborne coins.
	pose.basis = pose.basis.slerp(rest_basis,1.0-exp(-state.step*7.0)).orthonormalized()
	var alignment := absf(pose.basis.y.dot(normal))
	var support := 0.18*sqrt(maxf(0.0,1.0-alignment*alignment))+0.04*alignment
	var clearance: float = (pose.origin-hit.position).dot(normal)
	pose.origin += normal*maxf(0.0,support+0.006-clearance)
	state.transform = pose
	state.angular_velocity = state.angular_velocity.move_toward(Vector3.ZERO,state.step*14.0)
	if alignment>0.999:
		pose.origin = hit.position+normal*0.042
		state.transform = pose
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		can_sleep = true
		state.sleeping = true
