extends Node3D
## Sandbox-филлер: на _ready заполняет прямоугольную область бродячими скелетами.
## В level_rooms нет skeleton_target-нод (лагеря/гномов/стен в группе) → у скелетов
## ноль vision-целей → они просто бродят (WANDERING/RESTING). Ходячие мана-цели
## под дэш/спарк: 1 скелет = 1 XP-орб = 5 маны, 80 шт = 4 полных манатанка.
## Спавн распределён по физкадрам, чтобы не было фрейм-спайка на старте.

@export var skeleton_scene: PackedScene
## Сколько скелетов. 80 × 5 маны = 400 = 4 × max_mana (100).
@export var count: int = 80
## Центр области спавна (мир, XZ). Y берётся из spawn_y.
@export var area_center: Vector3 = Vector3.ZERO
## Полуразмеры области по X/Z — держать внутри стен комнаты (интерьер 36×28 →
## half ~16/12 с запасом от стен).
@export var area_half_x: float = 16.0
@export var area_half_z: float = 12.0
@export var spawn_y: float = 1.0
@export var spawns_per_frame: int = 8


func _ready() -> void:
	# На _ready корень сцены ещё «busy setting up children» — add_child падает.
	# Ждём кадр, чтобы дерево достроилось, потом наполняем.
	await get_tree().physics_frame
	if is_inside_tree():
		_fill()


func _fill() -> void:
	if skeleton_scene == null or count <= 0:
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	for i in range(count):
		var inst := skeleton_scene.instantiate()
		var node := inst as Node3D
		if node == null:
			if inst != null:
				inst.queue_free()
			continue
		scene.add_child(node)
		node.global_position = Vector3(
			area_center.x + randf_range(-area_half_x, area_half_x),
			spawn_y,
			area_center.z + randf_range(-area_half_z, area_half_z))
		# Wander под размер комнаты: дефолтные 5-15м рассчитаны на большую карту и
		# в тесной комнате упираются в стены (скелет целит за стену → стоит/жмётся).
		# Привязываем к area_half — скелет бродит внутри своей комнаты.
		var reach: float = minf(area_half_x, area_half_z)
		node.set(&"wander_distance_max", maxf(3.0, reach * 0.9))
		node.set(&"wander_distance_min", maxf(2.0, reach * 0.4))
		if (i + 1) % spawns_per_frame == 0:
			await get_tree().physics_frame
			if not is_inside_tree():
				return
