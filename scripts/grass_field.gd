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

## Сторона мира покрытия травой (метры). Должна совпадать с размером ground'а
## в main.tscn (BoxMesh size=400, центр в 0,0,0 → world_size=400).
@export var world_size: float = 400.0
## Сетка чанков. 8×8 при world_size=400 → каждый чанк 50м.
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


func _spawn_chunks() -> void:
	var rng := RandomNumberGenerator.new()
	if random_seed >= 0:
		rng.seed = random_seed
	else:
		rng.randomize()

	var chunk_size: float = world_size / float(chunk_count_xz)
	var half_world: float = world_size * 0.5
	var blades_per_chunk: int = maxi(int(round(chunk_size * chunk_size * density)), 1)

	for cx in range(chunk_count_xz):
		for cz in range(chunk_count_xz):
			var chunk_origin_x: float = -half_world + (float(cx) + 0.5) * chunk_size
			var chunk_origin_z: float = -half_world + (float(cz) + 0.5) * chunk_size
			_spawn_one_chunk(rng, Vector3(chunk_origin_x, 0.0, chunk_origin_z), chunk_size, blades_per_chunk)


## Один чанк: инстанс chunk_scene, transform на середину чанка, multimesh
## заполнен blades_per_chunk травинок в локальных координатах ±chunk_size/2.
func _spawn_one_chunk(rng: RandomNumberGenerator, origin: Vector3, chunk_size: float, count: int) -> void:
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

	var mm: MultiMesh = chunk.multimesh
	if mm == null:
		push_error("GrassField: chunk_scene.multimesh не задан")
		return
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = false
	mm.instance_count = count

	var half_chunk: float = chunk_size * 0.5
	for i in range(count):
		var lx: float = rng.randf_range(-half_chunk, half_chunk)
		var lz: float = rng.randf_range(-half_chunk, half_chunk)
		var size_mul: float = blade_scale * rng.randf_range(1.0 - blade_scale_variance, 1.0 + blade_scale_variance)
		var rot_y: float = rng.randf() * TAU
		var basis := Basis().rotated(Vector3.UP, rot_y).scaled(Vector3.ONE * size_mul)
		var t := Transform3D(basis, Vector3(lx, 0.0, lz))
		mm.set_instance_transform(i, t)
