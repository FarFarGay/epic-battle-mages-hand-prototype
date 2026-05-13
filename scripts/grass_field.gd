class_name GrassField
extends Node3D
## Сеть chunked MultiMeshInstance3D-узлов, покрывающих карту травой.
## На _ready создаёт chunk_count_xz × chunk_count_xz узлов, каждый со своим
## MultiMesh, заполненным random-позициями травинок в своём прямоугольнике.
##
## **Зачем чанки:** Godot культит MultiMeshInstance3D по общему AABB. Один
## большой MultiMesh на 400×400 был бы виден всегда (AABB пересекает frustum
## из любой точки), и все его 8000+ инстансов гнал бы vertex-шейдер каждый
## кадр. Сетка чанков 50×50м даёт 64 отдельных AABB, frustum culling
## оставляет только видимые ~12-20 чанков — основной win.
##
## **Visibility range:** дополнительно к frustum'у, дальние чанки скрываются
## по visibility_range (`max=visibility_distance`). Когда камера отъезжает
## от чанка > visibility_distance — он переключается в hidden, vertex
## displacement не идёт.
##
## **Cost-estimate (при density=0.1, chunk_count=8, chunk_size=50):**
## - 64 чанка × 250 травинок × 7 трисов = ~112k трисов суммарно.
## - В кадре видно ~16 чанков (frustum + visibility) × 250 = 4000 blade ×
##   7 трисов = 28k трисов. Вершинный шейдер дешёвый (один texture-sample
##   + offset). Fragment-cost минимальный (без alpha, без discard, без overdraw).
## - Один draw call на чанк (MultiMesh batched) = 16 draw calls в кадре.
##
## **Откат:** density=0 (или удалить ноду из main.tscn).

## Сторона fallback-мира (метры) — используется только когда `coverage_target_path`
## пуст или указывает на невалидный узел. Квадратный регион с центром в (0,0).
@export var world_size: float = 400.0
## Опциональная ссылка на `VisualInstance3D` (обычно `GroundMesh`), чьи мировые
## границы AABB задают зону покрытия травой. Когда указан — `world_size`
## игнорируется, а grass спавнится только внутри XZ-проекции этого AABB.
## Это даёт единый источник правды для размера ground'а: дизайнер двигает
## или масштабирует Ground в `main.tscn` — grass подстраивается без правки
## параметров здесь.
@export var coverage_target_path: NodePath
## Сетка чанков. 8×8 → каждый чанк ≈ coverage_size / 8.
@export var chunk_count_xz: int = 8
## Травинок на квадратный метр. На 64 чанках при density=0.1 это
## ~16k blade всего. 0.05 — реже, 0.2 — гуще (но vertex-cost растёт линейно).
@export var density: float = 0.1
## Дистанция, дальше которой чанк culled через visibility_range. Меньше —
## меньше нагрузка, но видна граница «появления травы». 80м — компромисс.
@export var visibility_distance: float = 80.0
## Размер blade — multimesh-scale. blade.obj базово 1м ширина, 4м высота;
## scale=0.2 даёт 0.2м×0.8м. Variance ±0.3 — естественный разброс.
@export var blade_scale: float = 0.2
@export var blade_scale_variance: float = 0.3
## Сцена с MultiMeshInstance3D (mesh + material override). Каждый чанк —
## инстанс этой сцены, отличается только заполненным MultiMesh.
@export var chunk_scene: PackedScene
## Сид для воспроизводимого распределения. -1 = random на каждом запуске.
@export var random_seed: int = -1


func _ready() -> void:
	if chunk_scene == null:
		push_error("GrassField: chunk_scene не задан в инспекторе")
		return
	if density <= 0.0:
		# 0 = «трава выключена» (быстрый откат через инспектор без удаления).
		return
	_spawn_chunks()


## Зона покрытия в мировых координатах: XZ-прямоугольник.
## Если `coverage_target_path` указан и валиден — берём world AABB цели.
## Иначе — квадрат `world_size×world_size` с центром в (0,0).
func _get_coverage_rect() -> Rect2:
	if not coverage_target_path.is_empty():
		var node: Node = get_node_or_null(coverage_target_path)
		if node is VisualInstance3D:
			var local_aabb: AABB = (node as VisualInstance3D).get_aabb()
			var world_aabb: AABB = node.global_transform * local_aabb
			return Rect2(world_aabb.position.x, world_aabb.position.z, world_aabb.size.x, world_aabb.size.z)
		push_warning("GrassField: coverage_target_path не указывает на VisualInstance3D — fallback на world_size")
	var half: float = world_size * 0.5
	return Rect2(-half, -half, world_size, world_size)


func _spawn_chunks() -> void:
	var rng := RandomNumberGenerator.new()
	if random_seed >= 0:
		rng.seed = random_seed
	else:
		rng.randomize()

	var rect: Rect2 = _get_coverage_rect()
	var chunk_size_x: float = rect.size.x / float(chunk_count_xz)
	var chunk_size_z: float = rect.size.y / float(chunk_count_xz)
	var blades_per_chunk: int = maxi(int(round(chunk_size_x * chunk_size_z * density)), 1)

	for cx in range(chunk_count_xz):
		for cz in range(chunk_count_xz):
			var chunk_origin_x: float = rect.position.x + (float(cx) + 0.5) * chunk_size_x
			var chunk_origin_z: float = rect.position.y + (float(cz) + 0.5) * chunk_size_z
			_spawn_one_chunk(rng, Vector3(chunk_origin_x, 0.0, chunk_origin_z), Vector2(chunk_size_x, chunk_size_z), blades_per_chunk)


## Один чанк: инстанс chunk_scene, transform на середину чанка, multimesh
## заполнен blades_per_chunk травинок в локальных координатах ±chunk_size/2.
##
## **КРИТИЧНО**: MultiMesh в `grass_chunk.tscn` — это `sub_resource`, и при
## `chunk_scene.instantiate()` Godot **разделяет** этот ресурс между всеми
## инстансами (NodePath на ресурс копируется, не сам ресурс). Без
## `duplicate()` 256 чанков пишут в один общий MultiMesh, instance_count
## и set_instance_transform перезаписывают друг друга — это и спамит
## ошибки в дебаггере (429 шт. на скрине геймдизайнера). После duplicate
## каждый чанк получает свой собственный MultiMesh-буфер.
func _spawn_one_chunk(rng: RandomNumberGenerator, origin: Vector3, chunk_size: Vector2, count: int) -> void:
	var chunk: MultiMeshInstance3D = chunk_scene.instantiate() as MultiMeshInstance3D
	if chunk == null:
		push_error("GrassField: chunk_scene не инстанцируется как MultiMeshInstance3D")
		return
	add_child(chunk)
	chunk.global_position = origin
	# Visibility-range: чанк виден только когда камера ближе visibility_distance.
	# begin=0 → виден начиная от 0м, end=visibility_distance → пропадает дальше.
	chunk.visibility_range_end = visibility_distance
	chunk.visibility_range_end_margin = visibility_distance * 0.1

	if chunk.multimesh == null:
		push_error("GrassField: chunk_scene.multimesh не задан")
		return
	# Per-instance копия — иначе все чанки делят один shared MultiMesh
	# (см. док-комментарий выше).
	var mm: MultiMesh = chunk.multimesh.duplicate() as MultiMesh
	chunk.multimesh = mm
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = false
	mm.instance_count = count

	var half_x: float = chunk_size.x * 0.5
	var half_z: float = chunk_size.y * 0.5
	for i in range(count):
		var lx: float = rng.randf_range(-half_x, half_x)
		var lz: float = rng.randf_range(-half_z, half_z)
		var size_mul: float = blade_scale * rng.randf_range(1.0 - blade_scale_variance, 1.0 + blade_scale_variance)
		var rot_y: float = rng.randf() * TAU
		var tx_basis := Basis().rotated(Vector3.UP, rot_y).scaled(Vector3.ONE * size_mul)
		var t := Transform3D(tx_basis, Vector3(lx, 0.0, lz))
		mm.set_instance_transform(i, t)
