extends SceneTree
## ВЫПЕЧКА модели башни (шахматная ЛАДЬЯ) в ассет. Запуск:
##   godot --headless --script res://tools/bake_tower.gd
## Геометрия строится кодом (MeshLib), но СОХРАНЯЕТСЯ один раз в:
##   res://models/tower_visual.tscn   — сцена (Body + Reactor)
##   res://models/materials/*.tres    — материалы (создаются только если их нет,
##                                       чтобы ручные правки цвета не затирались)
## tower.tscn инстансит tower_visual.tscn под VisualRoot. Рантайм НЕ генерит меши.
##
## Ладья = тело вращения (профиль radius-по-высоте) + зубчатая корона сверху.
## Вся каменная масса лежит в ноде "Body" — tower.gd берёт её для HitFlash и
## DashFx-призрака (полный силуэт). Reactor — тонкий светящийся пояс (виден ночью).

const MeshLib = preload("res://tools/mesh_lib.gd")

const MAT_DIR := "res://models/materials"
const SCENE_PATH := "res://models/tower_visual.tscn"

## Граней у тел вращения. Нормали сглажены (см. MeshLib.add_prism) — затенение
## круглое; число сторон теперь влияет в основном на гладкость СИЛУЭТА.
const LATHE_SIDES := 32


func _initialize() -> void:
	_bake()
	quit()


func _bake() -> void:
	DirAccess.make_dir_recursive_absolute("res://models")
	DirAccess.make_dir_recursive_absolute(MAT_DIR)

	var stone := _stone_mat()
	var reactor := _reactor_mat()

	var root := Node3D.new()
	root.name = "TowerVisual"

	# --- Body: вся каменная масса ладьи (основание + ствол + воротник + зубцы) ---
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = _build_body_mesh()
	body.material_override = stone
	root.add_child(body)
	body.owner = root

	# --- Glow: светящиеся жилы-каналы по форме ладьи (повторяют профиль тела).
	# Отдельная нода/материал — tower.gd гонит их яркость от количества маны. ---
	var glow := MeshInstance3D.new()
	glow.name = "Glow"
	glow.mesh = _build_glow_mesh()
	glow.material_override = reactor
	root.add_child(glow)
	glow.owner = root

	var ps := PackedScene.new()
	var pack_err := ps.pack(root)
	assert(pack_err == OK, "pack failed")
	var save_err := ResourceSaver.save(ps, SCENE_PATH)
	if save_err == OK:
		print("[bake_tower] сохранено: ", SCENE_PATH)
	else:
		push_error("[bake_tower] не удалось сохранить сцену, err=%d" % save_err)


# --- Геометрия (envelope ~2×6×2, центр в origin: y от -3 до +3) ---

## Профиль ладьи: пары (y, radius) снизу вверх. Тело вращения = призмы между
## соседними точками. Один источник формы и для тела, и для светящихся жил.
func _profile() -> Array:
	return [
		Vector2(-3.00, 1.16),   # основание — широкая «юбка»
		Vector2(-2.60, 1.16),
		Vector2(-2.42, 0.96),   # переход к стволу
		Vector2(-2.30, 0.92),
		Vector2(0.55, 0.80),    # ствол с лёгким сужением
		Vector2(1.25, 0.86),    # лёгкое утолщение к шее
		Vector2(1.45, 0.76),    # перехват шеи (вогнутость)
		Vector2(1.72, 1.02),    # воротник раскрывается
		Vector2(2.25, 1.22),    # венец — самый широкий верх
		Vector2(2.48, 1.20),    # площадка под зубцами
	]


func _build_body_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Крышки только на крайних сегментах (низ + площадка короны); внутренние
	# крышки скрыты внутри объёма.
	var profile := _profile()
	var n: int = profile.size()
	for i in range(n - 1):
		var cap: bool = (i == 0) or (i == n - 2)
		MeshLib.add_prism(st, profile[i].y, profile[i + 1].y, profile[i].x, profile[i + 1].x, LATHE_SIDES, cap)
	# Корона: зубцы-мерлоны по ободу с проёмами-бойницами. Стоят на площадке
	# (верх @2.48), центр оставлен свободным под турель (MountSlot @y3).
	var teeth := 8
	var rim := 1.04
	for i in range(teeth):
		var a: float = TAU * float(i) / float(teeth)
		var px: float = cos(a) * rim
		var pz: float = sin(a) * rim
		MeshLib.add_box_rot(st, Vector3(px, 2.74, pz), Vector3(0.40, 0.55, 0.34), a)
	return st.commit()


## Светящиеся вертикальные жилы вдоль тела ладьи. Идут по тому же профилю
## (повторяют геометрию), приподняты над поверхностью на EPS, чтобы не было
## z-fight. Охватывают ствол→шею→воротник (без юбки и короны).
func _build_glow_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var profile := _profile()
	var lo := 3   # верх «юбки» (начало ствола)
	var hi := 8   # венец (кромка короны)
	var veins := 6
	var eps := 0.02
	var half_w := 0.06   # половина угловой ширины жилы (рад)
	for v in range(veins):
		var a: float = TAU * float(v) / float(veins)
		var a0: float = a - half_w
		var a1: float = a + half_w
		var nrm := Vector3(cos(a), 0.0, sin(a))
		for i in range(lo, hi):
			var y0: float = profile[i].x
			var r0: float = profile[i].y + eps
			var y1: float = profile[i + 1].x
			var r1: float = profile[i + 1].y + eps
			var p00 := Vector3(cos(a0) * r0, y0, sin(a0) * r0)
			var p10 := Vector3(cos(a1) * r0, y0, sin(a1) * r0)
			var p11 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
			var p01 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
			MeshLib.quad(st, p00, p10, p11, p01, nrm)
	return st.commit()


# --- Материалы (создаём только если файла ещё нет → правки цвета переживают
#     повторную выпечку геометрии) ---

func _stone_mat() -> StandardMaterial3D:
	var path := MAT_DIR + "/tower_stone.tres"
	if FileAccess.file_exists(path):
		return load(path)
	var tex := "res://textures/bricks_wall_07/bricks_wall_07_1k/"
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 1.0, 1.0)
	m.albedo_texture = load(tex + "bricks_wall_07_baseColor_1k.png")
	m.normal_enabled = true
	m.normal_texture = load(tex + "bricks_wall_07_normal_gl_1k.png")  # Godot = OpenGL-нормали
	m.roughness = 1.0
	m.roughness_texture = load(tex + "bricks_wall_07_roughness_1k.png")
	m.metallic = 0.0
	m.ao_enabled = true
	m.ao_texture = load(tex + "bricks_wall_07_ambientOcclusion_1k.png")
	# Меши процедурные, БЕЗ UV — кладём текстуру триплонаром (проекция по локальным
	# осям меша). uv1_scale = тайлинг (больше = мельче кирпич).
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(0.7, 0.7, 0.7)
	# Лёгкое самосвечение — чтобы не была угольно-чёрной ночью (поверх текстуры).
	m.emission_enabled = true
	m.emission = Color(0.08, 0.07, 0.06)
	m.emission_energy_multiplier = 0.12
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
