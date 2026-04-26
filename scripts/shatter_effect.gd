class_name ShatterEffect
extends RefCounted
## Визуальный эффект «рассыпание на смерти»: пачка RigidBody3D-кубиков с импульсами,
## удаляются скопом одним SceneTreeTimer (а не tween-per-fragment).
##
## Не зависит от Enemy/Skeleton — берёт parent / position / color / параметры извне.
## Layer=0 (никто не видит фрагменты), mask=Layers.TERRAIN (падают на пол, проходят
## сквозь всё остальное — без завалов на телах).

const FRAGMENT_SIZE := 0.25
const FRAGMENT_MASS := 0.1
const SPREAD_HORIZONTAL := 0.3
const SPREAD_VERTICAL := 2.0
const IMPULSE_RADIAL := 4.0
const IMPULSE_VERTICAL := 5.0
const ANGULAR_RANGE := 5.0


## Заспавнить пачку фрагментов. Все они становятся детьми `parent` и сами очищаются
## через `lifetime` секунд одним общим SceneTreeTimer.
static func spawn(
	parent: Node,
	position: Vector3,
	color: Color,
	fragment_count: int = 7,
	lifetime: float = 1.5
) -> void:
	if not is_instance_valid(parent):
		return
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	var fragments: Array[Node] = []
	for i in range(fragment_count):
		var body := _make_fragment(position, material)
		parent.add_child(body)
		body.global_position = position + Vector3(
			randf_range(-SPREAD_HORIZONTAL, SPREAD_HORIZONTAL),
			randf_range(0.0, SPREAD_VERTICAL),
			randf_range(-SPREAD_HORIZONTAL, SPREAD_HORIZONTAL)
		)
		var radial := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
		if radial.length_squared() > 0.0:
			radial = radial.normalized()
		body.linear_velocity = (radial * IMPULSE_RADIAL
			+ Vector3.UP * IMPULSE_VERTICAL * randf_range(0.5, 1.0))
		body.angular_velocity = Vector3(
			randf_range(-ANGULAR_RANGE, ANGULAR_RANGE),
			randf_range(-ANGULAR_RANGE, ANGULAR_RANGE),
			randf_range(-ANGULAR_RANGE, ANGULAR_RANGE)
		)
		fragments.append(body)

	# Один общий таймер на пачку — дешевле, чем Tween на каждый фрагмент.
	var timer := parent.get_tree().create_timer(lifetime)
	timer.timeout.connect(func() -> void:
		for f in fragments:
			# is_inside_tree() гасит сценарий «scene выгрузили, фрагменты freed,
			# а timer пережил смену сцены» — без этого upcoming queue_free лишний.
			if is_instance_valid(f) and f.is_inside_tree():
				f.queue_free()
	)


static func _make_fragment(_position: Vector3, material: StandardMaterial3D) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.collision_layer = 0
	body.collision_mask = Layers.TERRAIN
	body.mass = FRAGMENT_MASS
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * FRAGMENT_SIZE
	var coll := CollisionShape3D.new()
	coll.shape = shape
	body.add_child(coll)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * FRAGMENT_SIZE
	mesh.mesh = box
	mesh.material_override = material
	body.add_child(mesh)
	return body
