extends SceneTree
## ВЫПЕЧКА модели харвестера (шахматный ФЕРЗЬ, Стаунтон). Запуск:
##   godot --headless --script res://tools/bake_harvester.gd
## Сохраняет:
##   res://models/harvester_visual.tscn — сцена (Body + GoldFinial + DrillAssembly)
##   res://models/materials/harvester_*.tres — материалы (не перезаписываются)
##
## Координаты ЛОКАЛЬНЫЕ (узел Harvester масштабирован 1.8 в сцене). y=0 — земля.
## Ферзь стоит на земле широким основанием; стройная вогнутая «талия», плавное
## тело, скромный коронет с мелкими зубцами и золотой шарик сверху (тема золота).
## Бур-шнек (DrillAssembly) уходит из центра вниз в землю — его вращает
## harvester.gd при добыче (под основанием, как механизм).

const MeshLib = preload("res://tools/mesh_lib.gd")

const MAT_DIR := "res://models/materials"
const SCENE_PATH := "res://models/harvester_visual.tscn"
const LATHE_SIDES := 32


func _initialize() -> void:
	_bake()
	quit()


func _bake() -> void:
	DirAccess.make_dir_recursive_absolute("res://models")
	DirAccess.make_dir_recursive_absolute(MAT_DIR)

	var ivory := _body_mat()
	var steel := _steel_mat()
	var gold := _gold_mat()

	var root := Node3D.new()
	root.name = "HarvesterVisual"

	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = _build_body_mesh()
	body.material_override = ivory
	root.add_child(body)
	body.owner = root

	var finial := MeshInstance3D.new()
	finial.name = "GoldFinial"
	finial.mesh = _build_finial_mesh()
	finial.material_override = gold
	root.add_child(finial)
	finial.owner = root

	var drill := Node3D.new()
	drill.name = "DrillAssembly"
	root.add_child(drill)
	drill.owner = root
	var drill_mesh := MeshInstance3D.new()
	drill_mesh.name = "DrillMesh"
	drill_mesh.mesh = _build_drill_mesh()
	drill_mesh.material_override = steel
	drill.add_child(drill_mesh)
	drill_mesh.owner = root

	var ps := PackedScene.new()
	var pack_err := ps.pack(root)
	assert(pack_err == OK, "pack failed")
	var save_err := ResourceSaver.save(ps, SCENE_PATH)
	if save_err == OK:
		print("[bake_harvester] сохранено: ", SCENE_PATH)
	else:
		push_error("[bake_harvester] не удалось сохранить, err=%d" % save_err)


# --- Геометрия ---

## Профиль ферзя (Стаунтон): пары (y, radius) снизу вверх. Достаточно точек для
## плавной вогнутой «талии» и мягкого тела — силуэт получается грациозным.
func _body_profile() -> Array:
	return [
		Vector2(0.00, 1.00),   # основание на земле — самое широкое
		Vector2(0.16, 1.00),
		Vector2(0.27, 0.78),   # фаска основания
		Vector2(0.37, 0.58),
		Vector2(0.45, 0.48),   # колечко над основанием
		Vector2(0.60, 0.39),
		Vector2(0.82, 0.33),   # стройная талия
		Vector2(1.08, 0.32),
		Vector2(1.32, 0.39),   # плавное расширение тела
		Vector2(1.52, 0.49),
		Vector2(1.66, 0.53),   # «плечо» — самое широкое в верхней части
		Vector2(1.78, 0.49),
		Vector2(1.88, 0.41),
		Vector2(1.96, 0.35),   # шея
		Vector2(2.06, 0.48),   # воротник-кольцо под короной
		Vector2(2.14, 0.42),
		Vector2(2.20, 0.32),   # основание коронета
		Vector2(2.32, 0.40),   # коронет слегка раскрыт
		Vector2(2.38, 0.37),   # обод коронета
	]


func _build_body_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_lathe(st, _body_profile(), LATHE_SIDES, true)
	# Коронет ферзя — кольцо МЕЛКИХ зубцов (а не грубые шипы). Маленькие конусы
	# по ободу; в центре сверху — золотой шарик.
	var teeth := 8
	var rim := 0.34
	for i in range(teeth):
		var a: float = TAU * float(i) / float(teeth)
		MeshLib.add_prism(st, 0.055, 0.006, 2.34, 2.50, 6, true, cos(a) * rim, sin(a) * rim)
	return st.commit()


func _build_finial_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_lathe(st, _sphere_profile(2.55, 0.15, 8), LATHE_SIDES, false)
	return st.commit()


func _build_drill_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Короткий бур под основанием: из центра вниз в землю (механизм добычи).
	var prof := [
		Vector2(0.42, 0.32),
		Vector2(0.22, 0.30),
		Vector2(0.18, 0.24),
		Vector2(0.00, 0.20),
		Vector2(-0.30, 0.02),
	]
	_lathe(st, prof, 10, false)
	return st.commit()


## Тело вращения из массива профиля (y, r). cap_ends — крышки на крайних
## сегментах; внутренние крышки скрыты в объёме.
func _lathe(st: SurfaceTool, profile: Array, sides: int, cap_ends: bool) -> void:
	var n: int = profile.size()
	for i in range(n - 1):
		var cap: bool = cap_ends and (i == 0 or i == n - 2)
		MeshLib.add_prism(st, profile[i].y, profile[i + 1].y, profile[i].x, profile[i + 1].x, sides, cap)


## Профиль сферы для навершия: центр (yc), радиус r, segs дуг (полюса — r=0).
func _sphere_profile(yc: float, r: float, segs: int) -> Array:
	var arr: Array = []
	for i in range(segs + 1):
		var t: float = PI * float(i) / float(segs)
		arr.append(Vector2(yc - cos(t) * r, sin(t) * r))
	return arr


# --- Материалы (создаём только если файла ещё нет) ---

func _body_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/harvester_body.tres"
	if FileAccess.file_exists(path):
		return load(path)
	var tex := "res://textures/metal_pattern_01/metal_pattern_01_1k/"
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 1.0, 1.0)
	m.albedo_texture = load(tex + "metal_pattern_01_color_1k.png")
	m.normal_enabled = true
	m.normal_texture = load(tex + "metal_pattern_01_normal_gl_1k.png")
	m.roughness = 1.0
	m.roughness_texture = load(tex + "metal_pattern_01_roughness_1k.png")
	m.metallic = 1.0
	m.metallic_texture = load(tex + "metal_pattern_01_metallic_1k.png")
	m.ao_enabled = true
	m.ao_texture = load(tex + "metal_pattern_01_ambient_occlusion_1k.png")
	# Меши процедурные, БЕЗ UV — триплонар по локальным осям. uv1_scale = тайлинг.
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(0.8, 0.8, 0.8)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ResourceSaver.save(m, path)
	return load(path)


func _steel_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/harvester_steel.tres"
	if FileAccess.file_exists(path):
		return load(path)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.40, 0.40, 0.46)
	m.metallic = 0.8
	m.roughness = 0.35
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ResourceSaver.save(m, path)
	return load(path)


func _gold_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/harvester_gold.tres"
	if FileAccess.file_exists(path):
		return load(path)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.98, 0.82, 0.25)
	m.metallic = 0.9
	m.roughness = 0.25
	m.emission_enabled = true
	m.emission = Color(1.0, 0.78, 0.25)
	m.emission_energy_multiplier = 1.5
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ResourceSaver.save(m, path)
	return load(path)
