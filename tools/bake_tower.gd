extends SceneTree
## ВЫПЕЧКА модели башни (гномий мех-крепость) в ассет. Запуск:
##   godot --headless --script res://tools/bake_tower.gd
## Геометрия строится кодом (MeshLib), но СОХРАНЯЕТСЯ один раз в:
##   res://models/tower_visual.tscn   — сцена (3 части: Body/Chassis/Reactor)
##   res://models/materials/*.tres    — материалы (создаются только если их нет,
##                                       чтобы ручные правки цвета не затирались)
## tower.tscn инстансит tower_visual.tscn под VisualRoot. Рантайм НЕ генерит меши.
##
## Силуэт собран так, что вся каменная масса (тело + парапет + зубцы) лежит в
## ноде "Body" — tower.gd берёт её для HitFlash и DashFx-призрака (полный силуэт).

const MeshLib = preload("res://tools/mesh_lib.gd")

const MAT_DIR := "res://models/materials"
const SCENE_PATH := "res://models/tower_visual.tscn"


func _initialize() -> void:
	_bake()
	quit()


func _bake() -> void:
	DirAccess.make_dir_recursive_absolute("res://models")
	DirAccess.make_dir_recursive_absolute(MAT_DIR)

	var stone := _stone_mat()
	var metal := _metal_mat()
	var reactor := _reactor_mat()

	var root := Node3D.new()
	root.name = "TowerVisual"

	# --- Body: вся каменная масса (тело-восьмигранник + парапет + зубцы) ---
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = _build_body_mesh()
	body.material_override = stone
	root.add_child(body)
	body.owner = root

	# --- Chassis: тёмный металл — ходовая база, гусеницы, рёбра-контрфорсы ---
	var chassis := MeshInstance3D.new()
	chassis.name = "Chassis"
	chassis.mesh = _build_chassis_mesh()
	chassis.material_override = metal
	root.add_child(chassis)
	chassis.owner = root

	# --- Reactor: светящийся пояс мана-реактора (читается ночью) ---
	var reactor_mi := MeshInstance3D.new()
	reactor_mi.name = "Reactor"
	reactor_mi.mesh = _build_reactor_mesh()
	reactor_mi.material_override = reactor
	root.add_child(reactor_mi)
	reactor_mi.owner = root

	var ps := PackedScene.new()
	var pack_err := ps.pack(root)
	assert(pack_err == OK, "pack failed")
	var save_err := ResourceSaver.save(ps, SCENE_PATH)
	if save_err == OK:
		print("[bake_tower] сохранено: ", SCENE_PATH)
	else:
		push_error("[bake_tower] не удалось сохранить сцену, err=%d" % save_err)


# --- Геометрия (envelope ~2×6×2, центр в origin: y от -3 до +3) ---

func _build_body_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Тело-восьмигранник с лёгким сужением кверху.
	MeshLib.add_prism(st, 1.18, 0.95, -1.9, 2.2, 8, true)
	# Парапет — расширяющийся «воротник» (машикули) под зубцами.
	MeshLib.add_prism(st, 1.05, 1.32, 2.2, 2.55, 8, true)
	# Зубцы-мерлоны по ободу (центр-площадка под турель остаётся свободной).
	var teeth := 8
	for i in range(teeth):
		var a: float = TAU * float(i) / float(teeth)
		var px: float = cos(a) * 1.18
		var pz: float = sin(a) * 1.18
		MeshLib.add_box(st, Vector3(px, 2.8, pz), Vector3(0.34, 0.55, 0.34))
	return st.commit()


func _build_chassis_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Корпус-ходовая.
	MeshLib.add_box(st, Vector3(0.0, -2.4, 0.0), Vector3(2.4, 1.2, 2.4))
	# Гусеницы по бокам.
	MeshLib.add_box(st, Vector3(1.05, -2.6, 0.0), Vector3(0.55, 0.8, 2.9))
	MeshLib.add_box(st, Vector3(-1.05, -2.6, 0.0), Vector3(0.55, 0.8, 2.9))
	# Рёбра-контрфорсы по диагоналям — «бронированный мех».
	var rib := 0.8
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			MeshLib.add_box(st, Vector3(sx * rib, -0.6, sz * rib), Vector3(0.26, 2.6, 0.26))
	return st.commit()


func _build_reactor_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Светящийся пояс — слегка выступает за тело (тело на этой высоте ≈1.03).
	MeshLib.add_prism(st, 1.22, 1.22, -0.25, 0.55, 16, false)
	return st.commit()


# --- Материалы (создаём только если файла ещё нет → правки цвета переживают
#     повторную выпечку геометрии) ---

func _stone_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/tower_stone.tres"
	if FileAccess.file_exists(path):
		return load(path)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.56, 0.52, 0.46)
	m.roughness = 0.92
	m.metallic = 0.0
	# Лёгкое собственное свечение — чтобы не была угольно-чёрной ночью.
	m.emission_enabled = true
	m.emission = Color(0.56, 0.52, 0.46)
	m.emission_energy_multiplier = 0.22
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ResourceSaver.save(m, path)
	return load(path)


func _metal_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/tower_metal.tres"
	if FileAccess.file_exists(path):
		return load(path)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.28, 0.29, 0.34)
	m.metallic = 0.7
	m.roughness = 0.45
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ResourceSaver.save(m, path)
	return load(path)


func _reactor_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/tower_reactor.tres"
	if FileAccess.file_exists(path):
		return load(path)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.78, 0.42)
	m.roughness = 0.4
	m.emission_enabled = true
	m.emission = Color(1.0, 0.7, 0.35)
	m.emission_energy_multiplier = 3.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ResourceSaver.save(m, path)
	return load(path)
