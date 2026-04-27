class_name OctagonTurret
extends CampModule
## Защитный модуль — восьмигранная турель, стреляющая стрелами в скелетов.
## Активна только когда mounted в слоте (на башне или в центре лагеря).
## Стрельба круговая — цели берутся из physics-shape-query по слою ENEMIES
## в радиусе `attack_radius`. Период между выстрелами случайный из
## [`fire_interval_min`, `fire_interval_max`] — даёт «живой» ритм вместо
## метронома.
##
## Урон стрелы откалиброван на skeleton.hp=30: дефолт `arrow_damage=35` →
## один выстрел = смерть скелета (по требованию задачи).
##
## Цели: всё, что на слое ENEMIES. Гномы (layer=0) и Tower (ACTORS) не
## считаются целями — стрелять по своим не нужно.

@export_group("Combat")
## Радиус сканирования целей (горизонтальный, через PhysicsShapeQuery).
@export var attack_radius: float = 12.0
## Урон стрелы. ≥ skeleton.hp=30 → ваншот.
@export var arrow_damage: float = 35.0
## Скорость стрелы (m/s). На дистанции 12м долетает за ~0.55с — успеваем
## по движущемуся скелету (move_speed=4).
@export var arrow_speed: float = 22.0
## Случайный интервал между выстрелами. Турель не стреляет метрономом, ритм
## плавающий — особенно важно при нескольких турелях (синхронные залпы
## выглядят неестественно).
@export var fire_interval_min: float = 0.4
@export var fire_interval_max: float = 0.9
## Откуда вылетает стрела относительно центра турели (поднимаем над мешем,
## чтобы не задеть сам корпус коллизией стрелы).
@export var arrow_spawn_offset: Vector3 = Vector3(0, 0.5, 0)
## Маска поиска целей. ENEMIES (бит 4 = 16). Гномы и башня не зацепляются.
@export_flags_3d_physics var target_mask: int = Layers.ENEMIES

@export_group("Refs")
@export var arrow_scene: PackedScene
## Куда складывать спавн стрел (чтобы они пережили move/destroy самой турели).
## Пусто → fallback на current_scene.
@export_node_path("Node") var projectiles_root_path: NodePath

@export_group("")
@export var debug_log: bool = false

@onready var _mesh: MeshInstance3D = $MeshInstance3D

var _fire_timer: float = 0.0
var _projectiles_root: Node = null


func _ready() -> void:
	super._ready()
	_apply_visual()
	if not projectiles_root_path.is_empty():
		_projectiles_root = get_node_or_null(projectiles_root_path)
	if _projectiles_root == null:
		_projectiles_root = get_tree().current_scene
	# Стартовая задержка случайна — несколько турелей не будут стрелять синхронно.
	_fire_timer = randf_range(fire_interval_min, fire_interval_max)


func _apply_visual() -> void:
	if _mesh == null:
		return
	_material = StandardMaterial3D.new()
	_material.albedo_color = module_color
	_mesh.material_override = _material


# --- Mount lifecycle ---

func _on_mounted(_slot: Node) -> void:
	# Сбрасываем таймер на «свежий» интервал, чтобы первый выстрел не вылетел
	# сразу при монтаже (ощущается как «выстрел в момент клика»).
	_fire_timer = randf_range(fire_interval_min, fire_interval_max)
	if debug_log and LogConfig.master_enabled:
		print("[OctagonTurret:%s] активирована" % name)


func _on_unmounted(_old_slot: Node) -> void:
	if debug_log and LogConfig.master_enabled:
		print("[OctagonTurret:%s] деактивирована" % name)


# --- Цикл стрельбы ---

func _physics_process(delta: float) -> void:
	if not is_mounted():
		return
	_fire_timer -= delta
	if _fire_timer > 0.0:
		return
	var target := _find_target()
	if target == null:
		# Цели нет — проверяем чаще, чем минимальный интервал.
		_fire_timer = 0.15
		return
	_fire_at(target)
	_fire_timer = randf_range(fire_interval_min, fire_interval_max)


func _find_target() -> Node3D:
	# PhysicsShapeQuery со сферой на attack_radius — тот же приём, что у Slam'а.
	# Возвращает все тела на target_mask, выбираем ближайшего.
	var space := get_world_3d().direct_space_state
	if space == null:
		return null
	var shape := SphereShape3D.new()
	shape.radius = attack_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), global_position)
	query.collision_mask = target_mask
	query.collide_with_bodies = true
	var results := space.intersect_shape(query, 32)
	var nearest: Node3D = null
	var nearest_dist := INF
	for r in results:
		var collider = r.collider
		if collider == null or not (collider is Node3D):
			continue
		var node := collider as Node3D
		# Цель должна быть Damageable — иначе мимо.
		if not Damageable.is_damageable(node):
			continue
		var d: float = global_position.distance_to(node.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = node
	return nearest


func _fire_at(target: Node3D) -> void:
	if arrow_scene == null:
		push_warning("OctagonTurret: arrow_scene не задана")
		return
	var arrow := arrow_scene.instantiate() as Arrow
	if arrow == null:
		push_warning("OctagonTurret: arrow_scene не инстанцируется как Arrow")
		return
	if not is_instance_valid(_projectiles_root):
		_projectiles_root = get_tree().current_scene
	_projectiles_root.add_child(arrow)
	var spawn := global_position + arrow_spawn_offset
	arrow.damage = arrow_damage
	arrow.speed = arrow_speed
	arrow.setup(spawn, target.global_position)
	if debug_log and LogConfig.master_enabled:
		print("[OctagonTurret:%s] выстрел в %s" % [name, target.name])
