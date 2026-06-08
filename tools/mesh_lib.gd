extends RefCounted
## Геометрические помощники для процедурных моделей, которые ВЫПЕКАЮТСЯ в ассеты
## один раз (см. tools/bake_*.gd), а не генерятся в рантайме. Спавнеры грузят
## готовый .tscn/.res.
##
## Все грани с ЯВНЫМИ нормалями (set_normal перед каждым add_vertex) — как в
## build_block.gd: generate_normals + двусторонняя отрисовка давали вывернутый
## свет. Материалы выпекаемых моделей ставим cull_mode=DISABLED, поэтому winding
## не критичен для видимости (нормали отвечают за свет).
##
## Подключение: const MeshLib = preload("res://tools/mesh_lib.gd") — без
## class_name, чтобы не зависеть от class-cache при запуске через --script.


## Квад из двух треугольников с явной нормалью n на всех вершинах. Порядок
## a→b→c→d — по контуру (CCW снаружи для корректного back-cull, если включат).
static func quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	for v in [a, b, c, a, c, d]:
		st.set_normal(n)
		st.add_vertex(v)


## Прямоугольный параллелепипед: центр + размер. 6 граней, нормали наружу.
static func add_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	var h := size * 0.5
	var c := center
	var p000 := c + Vector3(-h.x, -h.y, -h.z)
	var p100 := c + Vector3(h.x, -h.y, -h.z)
	var p010 := c + Vector3(-h.x, h.y, -h.z)
	var p110 := c + Vector3(h.x, h.y, -h.z)
	var p001 := c + Vector3(-h.x, -h.y, h.z)
	var p101 := c + Vector3(h.x, -h.y, h.z)
	var p011 := c + Vector3(-h.x, h.y, h.z)
	var p111 := c + Vector3(h.x, h.y, h.z)
	quad(st, p101, p100, p110, p111, Vector3.RIGHT)    # +X
	quad(st, p000, p001, p011, p010, Vector3.LEFT)     # -X
	quad(st, p011, p111, p110, p010, Vector3.UP)       # +Y
	quad(st, p000, p100, p101, p001, Vector3.DOWN)     # -Y
	quad(st, p001, p101, p111, p011, Vector3.BACK)     # +Z
	quad(st, p100, p000, p010, p110, Vector3.FORWARD)  # -Z


## Правильная n-угольная призма (опционально коническая: r0 снизу @y0, r1 сверху
## @y1). sides — число граней (8 = башня-восьмигранник). cap — крышки сверху/снизу.
## cx/cz — смещение оси в плоскости XZ.
static func add_prism(st: SurfaceTool, r0: float, r1: float, y0: float, y1: float, sides: int, cap: bool = true, cx: float = 0.0, cz: float = 0.0) -> void:
	var n_sides: int = maxi(3, sides)
	var pts0: Array = []
	var pts1: Array = []
	for i in range(n_sides):
		var a: float = TAU * float(i) / float(n_sides)
		var dx: float = cos(a)
		var dz: float = sin(a)
		pts0.append(Vector3(cx + dx * r0, y0, cz + dz * r0))
		pts1.append(Vector3(cx + dx * r1, y1, cz + dz * r1))
	for i in range(n_sides):
		var j: int = (i + 1) % n_sides
		var amid: float = TAU * (float(i) + 0.5) / float(n_sides)
		var n := Vector3(cos(amid), 0.0, sin(amid))
		quad(st, pts0[i], pts0[j], pts1[j], pts1[i], n)
	if cap:
		var topc := Vector3(cx, y1, cz)
		var botc := Vector3(cx, y0, cz)
		for i in range(n_sides):
			var j: int = (i + 1) % n_sides
			st.set_normal(Vector3.UP)
			st.add_vertex(topc)
			st.set_normal(Vector3.UP)
			st.add_vertex(pts1[j])
			st.set_normal(Vector3.UP)
			st.add_vertex(pts1[i])
			st.set_normal(Vector3.DOWN)
			st.add_vertex(botc)
			st.set_normal(Vector3.DOWN)
			st.add_vertex(pts0[i])
			st.set_normal(Vector3.DOWN)
			st.add_vertex(pts0[j])


## Завершить SurfaceTool в ArrayMesh. opt_path — если задан, ещё и сохранить .res.
static func commit(st: SurfaceTool) -> ArrayMesh:
	return st.commit()
