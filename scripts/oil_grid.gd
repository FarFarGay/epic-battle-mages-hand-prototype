class_name CityGrid
extends RefCounted
## ЕДИНАЯ математика грида уровня. ОДИН источник для снапа, клеток и полимино-построек
## ([HandPlaceAim], [PadBuilding]) — чтобы grid-математика не расползлась копиями.
##
## ЛОТТИС (клетки) — фикс к уровню: якорь = НЕПОДВИЖНАЯ нода-маркер ([ANCHOR_GROUP], напр.
## GridAnchor с превью на всю карту), НЕ замок. Клетки стабильны, видны по всей карте,
## по ним ставят залежи/замок/постройки — ОДИН грид, не плавает.
## ПЛОЩАДКА застройки 9×9 (in_pad/is_pump) считается ОТ ЗАМКА (поставил замок по гриду →
## вокруг него зона), а НЕ от центра карты. Нет замка → строить негде.

## Группа ноды-якоря грида (один маркер на уровень; нет → мир-ноль).
const ANCHOR_GROUP := &"grid_anchor"
## Размер клетки (м). Совпадение с PipeSegment.ARM_LEN×2 — историческое (нефтесеть),
## кодом не связано: трубы вне меню, клетка — самостоятельная константа грида.
const CELL := 2.0
const PAD_RADIUS := 6   # клеток от центра до края площадки (6 → пятно 13×13)
const PUMP_RADIUS := 1  # ядро под замок (1 → 3×3 центральных клетки)


## Мировая позиция якоря грида = нода-маркер уровня (фикс). Нет маркера → мир-ноль.
static func anchor(tree: SceneTree) -> Vector3:
	var a := tree.get_first_node_in_group(ANCHOR_GROUP)
	return (a as Node3D).global_position if a is Node3D else Vector3.ZERO


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


## ЯДРО ГОРОДА (пересборка 2026-07-21, DESIGN §5.А): якорь площадки застройки —
## ВЕРФЬ (PadBuilding role dock, группа CORE_GROUP). Замок (Castle) оставлен
## запасным резолвом — легаси-контент Заставы может его построить, но ядром
## по умолчанию он больше не является.
const CORE_GROUP := &"city_core_anchor"


## Нода-ядро города: верфь, иначе замок, иначе null (города ещё нет).
static func core_node(tree: SceneTree) -> Node3D:
	var d := tree.get_first_node_in_group(CORE_GROUP)
	if d is Node3D and is_instance_valid(d):
		return d as Node3D
	var c := tree.get_first_node_in_group(Castle.GROUP)
	if c is Node3D and is_instance_valid(c):
		return c as Node3D
	return null


## Клетка ядра города (центр площадки застройки), или null если ядра ещё нет.
## Имя историческое (раньше ядром был замок) — оставлено, чтобы не трогать
## всех вызывающих; семантика теперь «клетка ядра» (верфь/замок).
static func castle_cell(tree: SceneTree):
	var n := core_node(tree)
	if n != null:
		return world_to_cell(n.global_position, tree)
	return null


## Клетка в пределах площадки застройки (квадрат радиуса PAD_RADIUS вокруг ЯДРА).
## Нет ядра → строить негде (сперва поставь верфь — она ставится свободно).
static func in_pad(cell: Vector2i, tree: SceneTree) -> bool:
	var cc = castle_cell(tree)
	if cc == null:
		return false
	return absi(cell.x - cc.x) <= PAD_RADIUS and absi(cell.y - cc.y) <= PAD_RADIUS


## Клетка под ядром-ЗАМКОМ — строить нельзя (там сам замок). Проверка только
## по замку: верфь — обычный пад, свои клетки держит через occupied_cells.
static func is_pump(cell: Vector2i, tree: SceneTree) -> bool:
	var c := tree.get_first_node_in_group(Castle.GROUP)
	if not (c is Node3D) or not is_instance_valid(c):
		return false
	var cc: Vector2i = world_to_cell((c as Node3D).global_position, tree)
	return absi(cell.x - cc.x) <= PUMP_RADIUS and absi(cell.y - cc.y) <= PUMP_RADIUS
