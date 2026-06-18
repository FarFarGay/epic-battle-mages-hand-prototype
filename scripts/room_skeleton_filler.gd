extends Node3D
## Sandbox-филлер: на _ready заполняет прямоугольную область бродячими скелетами.
## По умолчанию скелеты БРОДЯТ (WANDERING/RESTING) — ходячие мана-цели под дэш/спарк
## (1 скелет = 1 XP-орб = 5 маны). Башня помечена `skeleton_target` (в level_rooms.tscn),
## поэтому скелет АГРИТСЯ на неё, лишь когда она въезжает в его vision_radius, и
## БРОСАЕТ погоню, когда башня отъезжает (vision-gated скан — не идут через всю карту).
## Урон занижен (skeleton_attack_damage) — скелеты тут «раздражают», а не выносят.
## Спавн распределён по физкадрам, чтобы не было фрейм-спайка на старте.

@export var skeleton_scene: PackedScene
## Сколько скелетов. 80 × 5 маны = 400 = 4 × max_mana (100).
@export var count: int = 80
## Урон скелета по башне/гномам (Enemy.attack_damage). Дефолт Enemy = 8; тут занижаем —
## комнатные скелеты раздражают (лёгкий чип), а не убивают. 0 = не трогать сцену.
@export var skeleton_attack_damage: float = 3.0
## Центр области спавна (мир, XZ). Y берётся из spawn_y.
@export var area_center: Vector3 = Vector3.ZERO
## Полуразмеры области по X/Z — держать внутри стен комнаты (интерьер 36×28 →
## half ~16/12 с запасом от стен).
@export var area_half_x: float = 16.0
@export var area_half_z: float = 12.0
@export var spawn_y: float = 1.0
@export var spawns_per_frame: int = 8
## Запретная зона (мир, XZ) — точки внутри неё НЕ занимаются (пропасть/мост). Радиус
## 0 = выключено. Точка в зоне пере-роллится несколько раз, не вышло — спавн пропущен.
@export var exclude_center: Vector3 = Vector3.ZERO
@export var exclude_half_x: float = 0.0
@export var exclude_half_z: float = 0.0


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
		var spawn_pos: Vector3 = _pick_spawn_pos()
		if spawn_pos == Vector3.INF:
			# Не нашли точку вне запретной зоны — этот скелет пропускаем (не на пропасти).
			node.queue_free()
			continue
		node.global_position = spawn_pos
		# Wander под размер комнаты: дефолтные 5-15м рассчитаны на большую карту и
		# в тесной комнате упираются в стены (скелет целит за стену → стоит/жмётся).
		# Привязываем к area_half — скелет бродит внутри своей комнаты.
		var reach: float = minf(area_half_x, area_half_z)
		node.set(&"wander_distance_max", maxf(3.0, reach * 0.9))
		node.set(&"wander_distance_min", maxf(2.0, reach * 0.4))
		# Занижаем урон: комнатные скелеты — раздражатели, не убийцы (0 = не трогать).
		if skeleton_attack_damage > 0.0:
			node.set(&"attack_damage", skeleton_attack_damage)
		if (i + 1) % spawns_per_frame == 0:
			await get_tree().physics_frame
			if not is_inside_tree():
				return


## Случайная точка в области спавна, ВНЕ запретной зоны (пропасть/мост). До 8 попыток
## пере-ролла; не вышло — Vector3.INF (вызывающий пропустит спавн).
func _pick_spawn_pos() -> Vector3:
	var excluded: bool = exclude_half_x > 0.0 and exclude_half_z > 0.0
	for _attempt in range(8):
		var p := Vector3(
			area_center.x + randf_range(-area_half_x, area_half_x),
			spawn_y,
			area_center.z + randf_range(-area_half_z, area_half_z))
		if not excluded:
			return p
		var dx: float = absf(p.x - exclude_center.x)
		var dz: float = absf(p.z - exclude_center.z)
		if dx > exclude_half_x or dz > exclude_half_z:
			return p  # вне запретной зоны
	return Vector3.INF
