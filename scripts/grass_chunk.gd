class_name GrassChunk
extends MultiMeshInstance3D
## Локальный «островок» травы вокруг POI или другой точки. На _ready
## заполняет MultiMesh случайными позициями в круге radius с density на м².
##
## Дизайнерская петля: класть как ребёнка [QuestActor] (или просто Node3D
## на сцене), задавать radius/density в инспекторе. Чанк центрируется в
## global_position своего родителя, поэтому травы спавнятся вокруг него.
##
## Cost: 1 draw call для всего чанка (MultiMesh batched через GPU). На
## плотности 1 травинка/м² и radius=12 это ~452 инстанса per POI × 3 POI
## = ~1356 травинок суммарно. Каждая = quad из 2 трисов с biллбордом и
## ветром. На GPU это копейки; на CPU — один статичный buffer заполненный
## в _ready, дальше нулевая нагрузка.
##
## Frustum culling: Godot культит MultiMesh по общему AABB. Чанк r=12м
## имеет ~24×24м AABB, который попадает в frustum ровно когда POI на
## экране — отдельных visibility_range не нужно (камера далеко от POI =
## весь чанк за frustum, не рисуется).
##
## Откат: noise_strength на ground shader → 0, плюс убрать GrassChunk из
## quest_actor.tscn (или просто visible=false на корне).

## Радиус круга, в котором разбрасываются травинки. Соответствует
## QuestActor.safe_radius (по умолчанию 12м).
@export var radius: float = 12.0
## Плотность травы — травинок на квадратный метр. 1.0 = одна травинка/м².
## На radius=12 (площадь ~452м²) это даёт ~452 инстанса на POI.
@export var density: float = 1.0
## Случайный множитель размера травинок. Variance 0.7..1.3 даёт
## естественный разброс высоты (без него все травинки идентичны).
@export var size_variance_min: float = 0.7
@export var size_variance_max: float = 1.3
## Опционально: исключить центральный круг (где стоит костёр) — травы
## там не будет, чтобы не торчать сквозь поленья. 0 — без исключения.
@export var exclude_center_radius: float = 1.0
## Сид для воспроизводимого распределения. -1 = random на каждом запуске.
## Полезно когда хочется одинаковую раскладку (тестирование, тюнинг).
@export var random_seed: int = -1


func _ready() -> void:
	# Без mesh не работает — это не GrassChunk, дизайнер забыл подключить.
	if multimesh == null:
		push_error("GrassChunk: multimesh не задан в инспекторе")
		return
	if multimesh.mesh == null:
		push_error("GrassChunk: multimesh.mesh не задан (ожидается grass_quad_mesh.tres)")
		return
	_populate()


## Генерирует instance_count трансформов в круге radius. Каждый transform —
## позиция (x, 0, z) в локальных координатах + случайный поворот Y +
## случайный uniform-scale в диапазоне size_variance.
##
## Y-rotation на бильборд-trave не влияет визуально (шейдер всё равно
## разворачивает quad к камере), но сохраняет логичный «direction» для
## будущих фич (трава, gнущаяся в одном направлении).
func _populate() -> void:
	var rng := RandomNumberGenerator.new()
	if random_seed >= 0:
		rng.seed = random_seed
	else:
		rng.randomize()

	# Площадь круга × density. Минус центральная exclude-зона.
	var area := PI * radius * radius
	if exclude_center_radius > 0.0:
		area -= PI * exclude_center_radius * exclude_center_radius
	var count := int(round(area * density))
	count = maxi(count, 1)

	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = false
	multimesh.use_custom_data = false
	multimesh.instance_count = count

	for i in range(count):
		var pos := _random_in_annulus(rng, exclude_center_radius, radius)
		var size_mul: float = rng.randf_range(size_variance_min, size_variance_max)
		var rot_y: float = rng.randf() * TAU
		# Базис: scale × rotation. Translation отдельно — корень травинки на полу
		# (y=0 в локальных, родитель отвечает за высоту). center_offset в
		# grass_quad_mesh.tres (Vector3(0,0.3,0)) поднимает quad так, что низ
		# на y=0 локально → стоит на полу.
		var basis := Basis().rotated(Vector3.UP, rot_y).scaled(Vector3.ONE * size_mul)
		var t := Transform3D(basis, Vector3(pos.x, 0.0, pos.y))
		multimesh.set_instance_transform(i, t)


## Случайная точка в кольце (inner_r, outer_r). Используется чтобы
## исключить центральный круг (где стоит костёр).
##
## sqrt(randf()) даёт uniform-в-круге (без концентрации к центру), но
## при inner_r > 0 нужна inverse-CDF: r = sqrt(randf() × (R² − r²) + r²).
func _random_in_annulus(rng: RandomNumberGenerator, inner_r: float, outer_r: float) -> Vector2:
	var u := rng.randf()
	var r := sqrt(u * (outer_r * outer_r - inner_r * inner_r) + inner_r * inner_r)
	var theta := rng.randf() * TAU
	return Vector2(cos(theta) * r, sin(theta) * r)
