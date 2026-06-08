class_name GateBlock
extends BuildBlock
## Грид-ворота: арка с дверьми в 1 ячейке кольца. Ведёт себя как gapless-стена
## (смыкается с соседями), но это ПРОХОД для своих и СТЕНА для врагов —
## переиспользует механику [WallGate]:
##   - слой `WALL_GATE_BLOCK`: скелеты (маска включает) упираются и бьют; гномы/
##     башня (маска без него) проходят физически.
##   - НЕ в `navmesh_source`: навмеш видит проём → гномы строят путь СКВОЗЬ;
##     скелеты тоже пытаются, но упираются физически (узкое защитное горло).
##   - Двери — чисто визуальный feedback: триггер-Area ловит своих → распахивает.
##
## Меш процедурный: два боковых пилона по краям ячейки + перемычка-арка сверху,
## по центру дверной проём с двумя створками на петлях. Коллизия — сплошной
## клин (наследуется от BuildBlock._rebuild_collision): врага держит вся ячейка,
## «открытые двери» гейтят только визуально.

const MeshLib = preload("res://tools/mesh_lib.gd")

## Доля половины дуги, отданная под дверной проём (центр). Остальное — пилоны.
const DOORWAY_HALF_FRAC := 0.45
## Высота перемычки-арки как доля height (верхняя часть над проёмом).
const LINTEL_FRAC := 0.28
## Толщина створки двери (м).
const DOOR_THICKNESS := 0.12
## Угол распахнутой створки (рад).
const OPEN_ANGLE := PI / 2.0
## Время анимации дверей (с).
const ANIMATE_TIME := 0.35
## Радиус триггер-зоны «свой рядом» (м).
const TRIGGER_RADIUS := 2.6

var _door_left: Node3D = null
var _door_right: Node3D = null
var _door_left_mesh: MeshInstance3D = null
var _door_right_mesh: MeshInstance3D = null
var _trigger: Area3D = null
var _door_mat: StandardMaterial3D = null

var _friendlies_inside: int = 0
var _is_open: bool = false
var _tw_left: Tween = null
var _tw_right: Tween = null


func is_gate() -> bool:
	return true


func _ready() -> void:
	_create_doors_and_trigger()
	super._ready()  # вызовет _build_geometry (наш override) → расставит двери


# --- Геометрия: арка вместо стены ---

func _build_geometry() -> void:
	if _mesh != null:
		_mesh.mesh = _build_gate_mesh()
	_rebuild_collision()  # сплошной клин — врага держит вся ячейка
	_position_doors()


## Арка: 2 пилона (на всю высоту) по краям ячейки + перемычка над проёмом.
func _build_gate_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mid := (inner_radius + outer_radius) * 0.5
	var half := deg_to_rad(sector_deg) * 0.5
	var door_half := half * DOORWAY_HALF_FRAC
	var y_bot := -height * 0.5
	var y_top := height * 0.5
	var lintel_y0 := y_top - height * LINTEL_FRAC
	# Боковые пилоны (на всю высоту).
	MeshLib.add_arc_slab(st, 0.0, -mid, inner_radius, outer_radius, -half, -door_half, y_bot, y_top, 4)
	MeshLib.add_arc_slab(st, 0.0, -mid, inner_radius, outer_radius, door_half, half, y_bot, y_top, 4)
	# Перемычка-арка над проёмом.
	MeshLib.add_arc_slab(st, 0.0, -mid, inner_radius, outer_radius, -door_half, door_half, lintel_y0, y_top, 6)
	return st.commit()


func _create_doors_and_trigger() -> void:
	_door_mat = StandardMaterial3D.new()
	_door_mat.albedo_color = Color(0.32, 0.2, 0.1, 1.0)  # тёмное дерево
	_door_mat.roughness = 0.9
	_door_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_door_left = Node3D.new()
	_door_right = Node3D.new()
	add_child(_door_left)
	add_child(_door_right)
	_door_left_mesh = MeshInstance3D.new()
	_door_right_mesh = MeshInstance3D.new()
	_door_left_mesh.material_override = _door_mat
	_door_right_mesh.material_override = _door_mat
	_door_left_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_door_right_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_door_left.add_child(_door_left_mesh)
	_door_right.add_child(_door_right_mesh)
	# Триггер «свой рядом» — включается на _activate_combat.
	_trigger = Area3D.new()
	_trigger.collision_layer = 0
	_trigger.collision_mask = Layers.FRIENDLY_UNIT | Layers.ACTORS  # гномы/солдаты + башня
	_trigger.monitoring = false
	add_child(_trigger)
	var ts := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = TRIGGER_RADIUS
	ts.shape = sph
	_trigger.add_child(ts)
	_trigger.body_entered.connect(_on_friendly_entered)
	_trigger.body_exited.connect(_on_friendly_exited)


## Створки: петли на внутренних краях пилонов, панель тянется к центру проёма
## (= origin блока). pivot.rotation.y = 0 — закрыто; ±OPEN_ANGLE — распахнуто.
func _position_doors() -> void:
	if _door_left == null or _door_right == null:
		return
	var mid := (inner_radius + outer_radius) * 0.5
	var c := Vector3(0.0, 0.0, -mid)
	var half := deg_to_rad(sector_deg) * 0.5
	var door_half := half * DOORWAY_HALF_FRAC
	var y_bot := -height * 0.5
	var lintel_y0 := height * 0.5 - height * LINTEL_FRAC
	var door_h := lintel_y0 - y_bot
	var door_cy := (lintel_y0 + y_bot) * 0.5
	var rh := c + Vector3(sin(door_half), 0.0, cos(door_half)) * mid
	var lh := c + Vector3(sin(-door_half), 0.0, cos(-door_half)) * mid
	var half_door := minf(rh.distance_to(Vector3.ZERO), lh.distance_to(Vector3.ZERO)) * 0.92
	_setup_door(_door_right, _door_right_mesh, rh, half_door, door_h, door_cy)
	_setup_door(_door_left, _door_left_mesh, lh, half_door, door_h, door_cy)
	_apply_door_angles(0.0)  # стартуем закрытыми


func _setup_door(pivot: Node3D, panel: MeshInstance3D, hinge: Vector3, dlen: float, dh: float, cy: float) -> void:
	pivot.position = Vector3(hinge.x, 0.0, hinge.z)
	pivot.rotation = Vector3.ZERO
	# Направление от петли к центру проёма (origin), по горизонтали.
	var dir := Vector3(-hinge.x, 0.0, -hinge.z)
	if dir.length() < 0.001:
		dir = Vector3(0.0, 0.0, 1.0)
	dir = dir.normalized()
	var box := BoxMesh.new()
	box.size = Vector3(DOOR_THICKNESS, dh, dlen)  # длинная ось — Z
	panel.mesh = box
	# Панель центрируется на полпути к центру, длинной осью вдоль dir.
	panel.position = Vector3(dir.x * dlen * 0.5, cy, dir.z * dlen * 0.5)
	panel.rotation = Vector3(0.0, atan2(dir.x, dir.z), 0.0)


func _apply_door_angles(t: float) -> void:
	# t = 0 закрыто, 1 распахнуто. Створки расходятся в разные стороны.
	if _door_right != null:
		_door_right.rotation.y = OPEN_ANGLE * t
	if _door_left != null:
		_door_left.rotation.y = -OPEN_ANGLE * t


# --- Боевое состояние: gate-слой, НЕ препятствие навмеша ---

func _activate_combat() -> void:
	if _destroyed:
		return
	_hp = hp_max
	Damageable.register(self)
	add_to_group(Enemy.TARGET_GROUP)
	# Лучники-скелеты не тратят стрелы на ворота (как палисад/стена).
	add_to_group(Enemy.MELEE_ONLY_TARGET_GROUP)
	# WALL_GATE_BLOCK: скелеты упираются (маска включает), гномы/башня проходят.
	# НЕ CAMP_OBSTACLE и НЕ navmesh_source → навмеш оставляет проём.
	collision_layer = Layers.WALL_GATE_BLOCK
	if _trigger != null:
		_trigger.monitoring = true


func on_picked_up() -> void:
	super.on_picked_up()
	if _trigger != null:
		_trigger.monitoring = false
	_friendlies_inside = 0
	_set_open(false)


# --- Open/close (визуал, по образцу WallGate) ---

func _on_friendly_entered(_body: Node3D) -> void:
	_friendlies_inside += 1
	if _friendlies_inside == 1:
		_set_open(true)


func _on_friendly_exited(_body: Node3D) -> void:
	_friendlies_inside = maxi(_friendlies_inside - 1, 0)
	if _friendlies_inside == 0:
		_set_open(false)


func _set_open(open: bool) -> void:
	if open == _is_open or _door_left == null:
		return
	_is_open = open
	var target := 1.0 if open else 0.0
	if _tw_left != null and _tw_left.is_valid():
		_tw_left.kill()
	if _tw_right != null and _tw_right.is_valid():
		_tw_right.kill()
	# Анимируем общий параметр через двери: tween по rotation.y каждой створки.
	_tw_right = create_tween()
	_tw_right.tween_property(_door_right, "rotation:y", OPEN_ANGLE * target, ANIMATE_TIME) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_tw_left = create_tween()
	_tw_left.tween_property(_door_left, "rotation:y", -OPEN_ANGLE * target, ANIMATE_TIME) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
