class_name OilGrid
extends RefCounted
## Единая математика нефте-СЕТКИ (якорь = центр коллектора-качалки). ОДИН источник
## для снапа, клеток и полимино-построек ([HandPlaceAim], [PadBuilding]) — чтобы
## grid-математика не расползлась копиями. Клетки — целочисленные, относительно якоря
## (якорь = клетка (0,0)). Площадка застройки — квадрат радиуса PAD_RADIUS вокруг
## качалки; центр (радиус PUMP_RADIUS) занят самой качалкой, строить нельзя.

const CELL := 2.0       # размер клетки (м) = PipeSegment.ARM_LEN * 2
const PAD_RADIUS := 4   # клеток от качалки до края площадки (4 → пятно 9×9)
const PUMP_RADIUS := 1  # ядро-качалка (1 → 3×3 центральных клетки заняты)


## Мировая позиция якоря сетки = центр коллектора (нет коллектора → мир-ноль).
static func anchor(tree: SceneTree) -> Vector3:
	var c := tree.get_first_node_in_group(OilCollector.GROUP)
	return (c as Node3D).global_position if c is Node3D else Vector3.ZERO


## Мировая точка → клетка (целочисленная, относительно якоря).
static func world_to_cell(pos: Vector3, tree: SceneTree) -> Vector2i:
	var a := anchor(tree)
	return Vector2i(roundi((pos.x - a.x) / CELL), roundi((pos.z - a.z) / CELL))


## Клетка → центр клетки в мире (Y берём от якоря — наземный).
static func cell_to_world(cell: Vector2i, tree: SceneTree) -> Vector3:
	var a := anchor(tree)
	return Vector3(a.x + cell.x * CELL, a.y, a.z + cell.y * CELL)


## Снап мировой точки к центру ближайшей клетки.
static func snap(pos: Vector3, tree: SceneTree) -> Vector3:
	var w := cell_to_world(world_to_cell(pos, tree), tree)
	return Vector3(w.x, pos.y, w.z)


## Поворот offset-клетки на rot (кратно 90°) вокруг (0,0). Совпадает с поворотом узла
## вокруг Y в Godot: Basis(Y,θ)·(x,_,z) при +90° даёт (z,_,-x) — иначе клетки занятости
## разъехались бы с визуалом повёрнутой фигуры.
static func rotate_offset(off: Vector2i, rot: float) -> Vector2i:
	match posmod(roundi(rot / (PI / 2.0)), 4):
		1: return Vector2i(off.y, -off.x)
		2: return Vector2i(-off.x, -off.y)
		3: return Vector2i(-off.y, off.x)
	return off


## Мировые клетки полимино: маска mask (Array[Vector2i]) при центре center, повороте rot.
static func building_cells(center: Vector3, mask: Array, rot: float, tree: SceneTree) -> Array:
	var base := world_to_cell(center, tree)
	var out: Array = []
	for off in mask:
		out.append(base + rotate_offset(off as Vector2i, rot))
	return out


## Клетка в пределах площадки застройки (квадрат радиуса PAD_RADIUS).
static func in_pad(cell: Vector2i) -> bool:
	return absi(cell.x) <= PAD_RADIUS and absi(cell.y) <= PAD_RADIUS


## Клетка занята ядром-качалкой (центр площадки) — строить нельзя.
static func is_pump(cell: Vector2i) -> bool:
	return absi(cell.x) <= PUMP_RADIUS and absi(cell.y) <= PUMP_RADIUS
