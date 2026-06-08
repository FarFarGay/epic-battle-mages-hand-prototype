extends SceneTree
## ВЫПЕЧКА модели генератора (паровая гномо-машина). Запуск:
##   godot --headless --script res://tools/bake_generator.gd
## Сохраняет:
##   res://models/generator_visual.tscn — сцена (Body + Gear + Vent)
##   res://models/materials/generator_*.tres — материалы (не перезаписываются)
##
## ВАЖНО: модель строится в ЛОКАЛЬНОЙ системе грид-клина генератора (ring 0),
## чтобы ЗАМЕНИТЬ собой сектор-блок целиком, а не стоять «нахлобучкой» сверху.
## Параметры клина (BuildGrid дефолты): core_radius=2.5, ring_band=1.8 →
## внутренний R 2.5, внешний 4.3, mid 3.4; угол 88° (одна из 4 ячеек). Центр
## кольца в локале блока — (0,0,-MID); d(t)=(sin t,0,cos t), t=0 → +Z (наружу от
## ядра). По Y центрируем как сектор (±height/2 = ±0.8), труба выше. 4 генератора
## смыкаются в кольцо машин вокруг харвестера.
##
## Силуэт: изогнутый котёл-банк по дуге на опорной плите; 2 выхлопные трубы;
## латунный маховик-шестерня на ВНЕШНЕЙ грани (узел "Gear" — BuildBlock крутит
## его вокруг локального Y, т.е. горизонтального вала); светящиеся венты-топки
## ("Vent") по бокам внешней грани.

const MeshLib = preload("res://tools/mesh_lib.gd")
# GridGeometry — dependency-free общий источник формы ячейки (его же читает
# BuildGrid). preload'им только его, НЕ build_grid.gd: тот тянет EventBus/Camp
# и не компилируется в headless --script контексте.
const GridGeo = preload("res://scripts/grid_geometry.gd")

const MAT_DIR := "res://models/materials"
const SCENE_PATH := "res://models/generator_visual.tscn"

# Геометрия клина ring-0 — выводится из ЕДИНОГО источника (GridGeometry),
# чтобы модель не разъехалась с реальной ячейкой при правке параметров грида.
const R_IN := GridGeo.CORE_RADIUS
const R_OUT := GridGeo.CORE_RADIUS + GridGeo.RING_BAND
const MID := (R_IN + R_OUT) * 0.5          # центр кольца на -Z
# Половина угла ячейки (рад): (360/seg − зазор)/2. PI/180 вместо deg_to_rad —
# const-выражение должно сворачиваться на парсе.
const HALF := (360.0 / float(GridGeo.SEGMENTS_RING0) - GridGeo.CELL_GAP_DEG) * 0.5 * PI / 180.0
const Y_BOT := -0.8       # низ блока (±height/2, height=1.6)
const Y_TOP := 0.8


func _initialize() -> void:
	_bake()
	quit()


func _bake() -> void:
	DirAccess.make_dir_recursive_absolute("res://models")
	DirAccess.make_dir_recursive_absolute(MAT_DIR)

	var body_mat := _body_mat()
	var pipes_mat := _pipes_mat()
	var brass := _brass_mat()
	var vent := _vent_mat()

	var root := Node3D.new()
	root.name = "GeneratorVisual"

	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = _build_body_mesh()
	body.material_override = body_mat
	root.add_child(body)
	body.owner = root

	var pipes := MeshInstance3D.new()
	pipes.name = "Pipes"
	pipes.mesh = _build_pipes_mesh()
	pipes.material_override = pipes_mat
	root.add_child(pipes)
	pipes.owner = root

	var gear := MeshInstance3D.new()
	gear.name = "Gear"
	gear.mesh = _build_gear_mesh()
	gear.material_override = brass
	# Маховик на ВНЕШНЕЙ грани (центр угла, r=R_OUT → локально z=+0.9). Диск
	# смоделирован вокруг Y; поворот +Y→+Z ставит колесо лицом наружу, вращение
	# вокруг локального Y узла = вокруг горизонтального вала-Z.
	gear.transform = Transform3D(Basis(Vector3(1, 0, 0), PI * 0.5), Vector3(0.0, 0.0, R_OUT - MID + 0.06))
	root.add_child(gear)
	gear.owner = root

	var vent_mi := MeshInstance3D.new()
	vent_mi.name = "Vent"
	vent_mi.mesh = _build_vent_mesh()
	vent_mi.material_override = vent
	root.add_child(vent_mi)
	vent_mi.owner = root

	var ps := PackedScene.new()
	var pack_err := ps.pack(root)
	assert(pack_err == OK, "pack failed")
	var save_err := ResourceSaver.save(ps, SCENE_PATH)
	if save_err == OK:
		print("[bake_generator] сохранено: ", SCENE_PATH)
	else:
		push_error("[bake_generator] не удалось сохранить, err=%d" % save_err)


# --- Геометрия (в системе клина: центр кольца (0,0,-MID)) ---

func _build_body_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Опорная плита на всю ячейку (низкая).
	MeshLib.add_arc_slab(st, 0.0, -MID, R_IN, R_OUT, -HALF, HALF, Y_BOT, Y_BOT + 0.22, 16)
	# Котёл-банк по дуге — основное тело, слегка поджато от краёв.
	MeshLib.add_arc_slab(st, 0.0, -MID, R_IN + 0.18, R_OUT - 0.18, -HALF * 0.94, HALF * 0.94, Y_BOT + 0.22, 0.45, 16)
	# Верхняя палуба.
	MeshLib.add_arc_slab(st, 0.0, -MID, R_IN + 0.18, R_OUT - 0.18, -HALF * 0.94, HALF * 0.94, 0.45, 0.62, 16)
	return st.commit()


## Выхлопные трубы (отдельный меш — своя текстура bricks_wall_15). Две на
## mid-радиусе, симметрично, с раструбом-навершием.
func _build_pipes_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in [-1.0, 1.0]:
		var a: float = s * deg_to_rad(20.0)
		var cx: float = sin(a) * MID
		var cz: float = -MID + cos(a) * MID
		MeshLib.add_prism(st, 0.14, 0.12, 0.6, 1.7, 10, true, cx, cz)
		MeshLib.add_prism(st, 0.19, 0.15, 1.64, 1.82, 10, true, cx, cz)
	return st.commit()


## Маховик-шестерня вокруг Y (узел ставит его вертикально на внешней грани). Диск
## + ступица + зубья. Центрирован в начале координат узла — крутится на месте.
func _build_gear_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	MeshLib.add_prism(st, 0.40, 0.40, -0.05, 0.05, 18, true)
	MeshLib.add_prism(st, 0.12, 0.12, -0.09, 0.09, 10, true)
	var teeth := 9
	for i in range(teeth):
		var a: float = TAU * float(i) / float(teeth)
		MeshLib.add_box_rot(st, Vector3(cos(a) * 0.44, 0.0, sin(a) * 0.44),
			Vector3(0.12, 0.14, 0.09), a)
	return st.commit()


## Светящиеся венты-топки по бокам внешней грани (±28°), лицом наружу (yaw=угол).
func _build_vent_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in [-1.0, 1.0]:
		var a: float = s * deg_to_rad(28.0)
		var cx: float = sin(a) * (R_OUT - 0.12)
		var cz: float = -MID + cos(a) * (R_OUT - 0.12)
		MeshLib.add_box_rot(st, Vector3(cx, -0.05, cz), Vector3(0.5, 0.5, 0.12), a)
	return st.commit()


# --- Материалы (создаём только если файла ещё нет) ---

## Корпус генератора — кирпич bricks_wall_11 (триплонар: меши без UV).
func _body_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/generator_body.tres"
	if FileAccess.file_exists(path):
		return load(path)
	return _brick_mat(path, "res://textures/bricks_wall_11/bricks_wall_11_1k/", "bricks_wall_11", 0.6)


## Трубы — кирпич bricks_wall_15. Мельче тайл (трубы тонкие).
func _pipes_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/generator_pipes.tres"
	if FileAccess.file_exists(path):
		return load(path)
	return _brick_mat(path, "res://textures/bricks_wall_15/bricks_wall_15_1k/", "bricks_wall_15", 1.8)


## Сборка кирпичного PBR-материала (albedo/normal_gl/roughness/AO), триплонар.
## Кирпич неметаллический — metallic не трогаем (0). scale — тайлинг триплонара.
func _brick_mat(path: String, tex: String, name: String, scale: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	# Кирпич матовый (metallic=0) и тёмный в линейном пространстве — под слабую
	# sky-ambient/SDFGI грани не у солнца проваливаются. Подъём albedo ×1.6
	# поднимает яркость самой поверхности, не трогая свет/траву.
	m.albedo_color = Color(1.6, 1.6, 1.6)
	m.albedo_texture = load(tex + name + "_basecolor_1k.png")
	m.normal_enabled = true
	m.normal_texture = load(tex + name + "_normal_gl_1k.png")
	m.roughness_texture = load(tex + name + "_roughness_1k.png")
	m.ao_enabled = true
	m.ao_texture = load(tex + name + "_ambientocclusion_1k.png")
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(scale, scale, scale)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ResourceSaver.save(m, path)
	return load(path)


func _brass_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/generator_brass.tres"
	if FileAccess.file_exists(path):
		return load(path)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.72, 0.55, 0.22)
	m.metallic = 0.9
	m.roughness = 0.32
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ResourceSaver.save(m, path)
	return load(path)


func _vent_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/generator_vent.tres"
	if FileAccess.file_exists(path):
		return load(path)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.9, 0.4, 0.12)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.5, 0.15)
	m.emission_energy_multiplier = 2.2
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ResourceSaver.save(m, path)
	return load(path)
