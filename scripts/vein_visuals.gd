class_name VeinVisuals
extends RefCounted
## Визуальный язык ЗАЛЕЖЕЙ — один на весь проект: маркеры жил в гриде города
## (BuildGrid) и стоячие жилы-валуны в поле (VeinBoulder) собираются из одних
## и тех же примитивов. Код перенесён из BuildGrid 2026-07-21 (без изменений),
## обе стороны делегируют сюда — «один визуальный язык — один смысл».

## Залежь руды: 4 валуна (rock_col) + 3 кристалла (crystal_col, эмиссивные).
static func build_ore_pile(root: Node3D, rock_col: Color, crystal_col: Color) -> void:
	var stone_mat := StandardMaterial3D.new()
	stone_mat.albedo_color = rock_col
	stone_mat.roughness = 1.0
	var crystal_mat := StandardMaterial3D.new()
	crystal_mat.albedo_color = crystal_col
	crystal_mat.emission_enabled = true
	crystal_mat.emission = crystal_col
	crystal_mat.emission_energy_multiplier = 1.5
	var rock_pos := [Vector3(0.0, 0.0, 0.0), Vector3(0.33, 0.0, 0.12), Vector3(-0.26, 0.0, -0.2), Vector3(0.06, 0.0, -0.33)]
	var rock_sz := [Vector3(0.52, 0.36, 0.48), Vector3(0.38, 0.28, 0.42), Vector3(0.42, 0.3, 0.36), Vector3(0.3, 0.22, 0.32)]
	var rock_yaw := [0.3, -0.5, 0.8, -0.2]
	for i in range(4):
		var box := BoxMesh.new()
		box.size = rock_sz[i]
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = stone_mat
		mi.position = rock_pos[i] + Vector3(0.0, rock_sz[i].y * 0.5, 0.0)
		mi.rotation = Vector3(0.0, rock_yaw[i], 0.0)
		root.add_child(mi)
	var cr_pos := [Vector3(0.0, 0.0, 0.0), Vector3(0.2, 0.0, -0.05), Vector3(-0.12, 0.0, 0.16)]
	var cr_h := [0.62, 0.44, 0.52]
	var cr_tilt := [Vector3(0.1, 0.0, 0.05), Vector3(-0.12, 0.4, 0.08), Vector3(0.08, -0.3, -0.1)]
	for i in range(3):
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.0
		cyl.bottom_radius = 0.09
		cyl.height = cr_h[i]
		cyl.radial_segments = 5
		cyl.rings = 1
		var mi := MeshInstance3D.new()
		mi.mesh = cyl
		mi.material_override = crystal_mat
		mi.position = cr_pos[i] + Vector3(0.0, 0.2 + cr_h[i] * 0.5, 0.0)
		mi.rotation = cr_tilt[i]
		root.add_child(mi)


## Лесок (жила дерева): 3 деревца — ствол (коричневый цилиндр) + крона (зелёный конус).
static func build_grove(root: Node3D) -> void:
	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.4, 0.28, 0.16)
	trunk_mat.roughness = 1.0
	var leaf_mat := StandardMaterial3D.new()
	leaf_mat.albedo_color = Color(0.24, 0.5, 0.22)
	leaf_mat.roughness = 1.0
	var tree_pos := [Vector3(0.0, 0.0, 0.1), Vector3(0.4, 0.0, -0.22), Vector3(-0.36, 0.0, -0.04)]
	var tree_h := [0.95, 0.72, 0.84]
	for i in range(3):
		var th: float = tree_h[i]
		var trunk := CylinderMesh.new()
		trunk.top_radius = 0.06
		trunk.bottom_radius = 0.08
		trunk.height = th * 0.45
		trunk.radial_segments = 5
		var tm := MeshInstance3D.new()
		tm.mesh = trunk
		tm.material_override = trunk_mat
		tm.position = tree_pos[i] + Vector3(0.0, trunk.height * 0.5, 0.0)
		root.add_child(tm)
		var leaf := CylinderMesh.new()
		leaf.top_radius = 0.0
		leaf.bottom_radius = 0.3
		leaf.height = th * 0.72
		leaf.radial_segments = 6
		var lm := MeshInstance3D.new()
		lm.mesh = leaf
		lm.material_override = leaf_mat
		lm.position = tree_pos[i] + Vector3(0.0, trunk.height + leaf.height * 0.45, 0.0)
		root.add_child(lm)


## Цвета валунов/кристаллов по типу материала — те же пары, что были захардкожены
## в BuildGrid._spawn_vein_marker. [rock_col, crystal_col].
static func colors_for_type(t: int) -> Array:
	if t == ResourcePile.ResourceType.IRON:
		return [Color(0.36, 0.31, 0.3), Color(1.0, 0.55, 0.18)]
	return [Color(0.5, 0.5, 0.52), Color(0.62, 0.72, 0.92)]
