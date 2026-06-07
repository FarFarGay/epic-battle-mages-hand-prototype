class_name BuildBlock
extends CampModule
## Пустая нефункциональная болванка-блок — для отработки САМОГО процесса
## строительства (схватил рукой → поднёс к слоту кольца → защёлкнулся гранью
## наружу). Геймплея нет: ни стрельбы, ни HP, ни производства. Позже на её место
## въедут конкретные здания, HP+разрушение, починка гномами, связки.
##
## Форма — толстый сектор-«кусок пирога» (кольцевой сектор): дыра под харвестер
## в центре (inner_radius), стены до outer_radius, высота height. 8 таких в
## слотах октагон-кольца (RingBase) разворачиваются гранью наружу
## (slot.align_rotation) и смыкаются в **кольцо комнат** вокруг ядра.
##
## Меш генерится процедурно вокруг точки центра кольца, лежащей в локале на
## -Z*mid (mid = (inner+outer)/2). Слот через look_at смотрит -Z на центр —
## значит mid должен совпадать с RingBase.ring_radius (=5.5), чтобы комната
## центрировалась на слоте и все 8 сошлись в одном мировом центре.
##
## Наследует от CampModule весь grab/mount-контракт; здесь только геометрия+визуал.

@export_group("Room shape")
## Внутренний радиус сектора — дворик под харвестер (центр композиции). Большой,
## чтобы блоки стояли поодаль и не затмевали ядро.
@export var inner_radius: float = 4.3
## Внешний радиус сектора. (inner+outer)/2 должно совпадать с RingBase.ring_radius (=5.5).
@export var outer_radius: float = 6.7
## Угловая ширина в градусах. 45 = впритык (сплошное кольцо). Узко (28°) → блоки
## стоят раздельными будками с заметными промежутками, не сливаясь в стену.
@export var sector_deg: float = 28.0
## Высота стен комнаты. Низкие, чтобы не возвышаться над харвестером.
@export var height: float = 1.6
## Тесселяция дуги (сегментов на сектор). Больше = глаже скругление.
@export var arc_segments: int = 6
@export_group("")

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _collision: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	super._ready()
	_build_geometry()
	_apply_visual()
	# Низ комнаты на земле. Слоты теперь чистые позиции (module_offset=0), весь
	# подъём — здесь: меш центрирован по Y (±height/2), значит origin держим на
	# height/2 над точкой слота.
	mount_lift = height * 0.5


func _build_geometry() -> void:
	if _mesh != null:
		_mesh.mesh = _build_sector_mesh()
	if _collision != null:
		# Грубый bounding-box под grab/rest свободного блока (точная форма для
		# монтажа не нужна — смонтированный блок заморожен и на слое MOUNTED_MODULE).
		var box := BoxShape3D.new()
		var depth := outer_radius - inner_radius
		var width := 2.0 * outer_radius * sin(deg_to_rad(sector_deg) * 0.5)
		box.size = Vector3(maxf(width, 0.2), height, maxf(depth, 0.2))
		_collision.shape = box
		_collision.position = Vector3.ZERO


## Кольцевой сектор, экструдированный по высоте. Центр кольца — в локале (0,0,-mid),
## origin блока (0,0,0) лежит на mid-радиусе. -Z = к центру (после look_at слота).
func _build_sector_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mid := (inner_radius + outer_radius) * 0.5
	var c := Vector3(0.0, 0.0, -mid)
	var half := deg_to_rad(sector_deg) * 0.5
	var up := Vector3(0.0, height * 0.5, 0.0)
	var segs: int = maxi(2, arc_segments)
	for i in range(segs):
		var t0 := -half + (float(i) / float(segs)) * (2.0 * half)
		var t1 := -half + (float(i + 1) / float(segs)) * (2.0 * half)
		# Радиаль на угле t: (sin t, 0, cos t); t=0 → +Z (наружу через origin).
		var d0 := Vector3(sin(t0), 0.0, cos(t0))
		var d1 := Vector3(sin(t1), 0.0, cos(t1))
		var pi0 := c + d0 * inner_radius
		var po0 := c + d0 * outer_radius
		var pi1 := c + d1 * inner_radius
		var po1 := c + d1 * outer_radius
		_quad(st, pi0 + up, po0 + up, po1 + up, pi1 + up)   # верх (+Y)
		_quad(st, pi1 - up, po1 - up, po0 - up, pi0 - up)   # низ (-Y)
		_quad(st, po0 - up, po1 - up, po1 + up, po0 + up)   # внешняя стена
		_quad(st, pi1 - up, pi0 - up, pi0 + up, pi1 + up)   # внутренняя стена
	# Радиальные торцы (боковые стены комнаты) на крайних углах.
	var dA := Vector3(sin(-half), 0.0, cos(-half))
	var dB := Vector3(sin(half), 0.0, cos(half))
	var piA := c + dA * inner_radius
	var poA := c + dA * outer_radius
	var piB := c + dB * inner_radius
	var poB := c + dB * outer_radius
	_quad(st, piA - up, poA - up, poA + up, piA + up)
	_quad(st, poB - up, piB - up, piB + up, poB + up)
	st.generate_normals()
	return st.commit()


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c2: Vector3, d: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c2)
	st.add_vertex(a)
	st.add_vertex(c2)
	st.add_vertex(d)


## Уникальный материал на инстанс — база CampModule тоглит на нём emission при
## наведении руки. cull выключен: двусторонняя отрисовка спасает от случайных
## вывернутых граней процедурного меша (placeholder, не финальный арт).
func _apply_visual() -> void:
	if _mesh == null:
		return
	_material = StandardMaterial3D.new()
	_material.albedo_color = module_color
	_material.roughness = 0.85
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh.material_override = _material
