class_name PipeSegment
extends Node3D
## Секция трубопровода (тайл): ПРЯМАЯ / УГОЛ / КРЕСТ. Геометрия — настоящие трубы
## (цилиндры-рукава от центра к каждому порту + хаб + фланцы на концах), строится
## кодом по [kind] (один путь для всех типов). Ставится рукой как стена, но снап
## идёт ПО КОНЦАМ ТРУБ (порты), не по центру — как труба-к-трубе.
##
## ПОРТЫ — открытые концы (центр ± ARM_LEN по осям). Их же используют снап
## ([HandPlaceAim._snap_pipe]) и связность сети ([OilCollector._recompute_network]):
## две трубы соединены, если их концы совпали. Коллектор/бур дают свои порты
## (трубные выступы) через тот же контракт `pipe_ports()` + группа [PORT_HOST_GROUP].

const GROUP := &"oil_pipe"
const PORT_HOST_GROUP := &"pipe_port_host"  # всё, у кого есть pipe_ports() (трубы/коллектор/бур)
const PIPE_Y := 0.5       # высота оси трубы над землёй (общая для труб/патрубков)
const RADIUS := 0.16      # тонкая труба — чтобы угол читался как гнутая, не квадрат
const ARM_LEN := 1.0      # центр → конец (порт); тайл = 2м

enum Kind { STRAIGHT, CORNER, CROSS }
@export var kind: Kind = Kind.STRAIGHT

static var _mat: StandardMaterial3D


## Локальные позиции концов (портов) по типу. Угол — два смежных конца (−X и +Z),
## поворотом MMB кроет все 4 ориентации (и «налево», и «направо»).
static func local_ports(k: int) -> Array:
	match k:
		Kind.STRAIGHT:
			return [Vector3(ARM_LEN, 0, 0), Vector3(-ARM_LEN, 0, 0)]
		Kind.CORNER:
			return [Vector3(-ARM_LEN, 0, 0), Vector3(0, 0, ARM_LEN)]
		Kind.CROSS:
			return [Vector3(ARM_LEN, 0, 0), Vector3(-ARM_LEN, 0, 0),
					Vector3(0, 0, ARM_LEN), Vector3(0, 0, -ARM_LEN)]
	return []


static func material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = Color(0.46, 0.48, 0.52, 1.0)
		_mat.metallic = 0.6
		_mat.roughness = 0.4
	return _mat


## Цилиндр-рукав от центра parent к локальному концу port_local + фланец на конце.
## Оси портов всегда вдоль X или Z — ориентируем цилиндр (ось Y) поворотом на 90°.
## mat=null → штатный металл; передаётся свой (полупрозрачный) для призрака.
static func add_tube(parent: Node3D, port_local: Vector3, radius: float, mat: StandardMaterial3D = null) -> void:
	if mat == null:
		mat = material()
	var length: float = port_local.length()
	var rot := Vector3(0, 0, PI / 2) if absf(port_local.x) >= absf(port_local.z) else Vector3(PI / 2, 0, 0)
	var arm := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = length
	arm.mesh = cyl
	arm.material_override = mat
	arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arm.position = port_local * 0.5 + Vector3(0, PIPE_Y, 0)
	arm.rotation = rot
	parent.add_child(arm)
	var flange := MeshInstance3D.new()
	var fc := CylinderMesh.new()
	fc.top_radius = radius * 1.7
	fc.bottom_radius = radius * 1.7
	fc.height = 0.08
	flange.mesh = fc
	flange.material_override = mat
	flange.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flange.position = port_local + Vector3(0, PIPE_Y, 0)
	flange.rotation = rot
	parent.add_child(flange)


func _ready() -> void:
	add_to_group(GROUP)
	add_to_group(PORT_HOST_GROUP)
	# Хаб в центре + рукав к каждому порту.
	var hub := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = RADIUS * 1.15
	s.height = RADIUS * 2.3
	hub.mesh = s
	hub.material_override = material()
	hub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hub.position = Vector3(0, PIPE_Y, 0)
	add_child(hub)
	for p in local_ports(kind):
		add_tube(self, p, RADIUS)


## Построить ПРИЗРАЧНУЮ (полупрозрачную) геометрию трубы данного типа в parent —
## для силуэта размещения ([HandPlaceAim]): игрок видит реальную форму (крест/угол)
## и её ориентацию (поворот родителя). Та же геометрия, что у настоящей трубы.
static func build_ghost(parent: Node3D, k: int, mat: StandardMaterial3D) -> void:
	var hub := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = RADIUS * 1.15
	s.height = RADIUS * 2.3
	hub.mesh = s
	hub.material_override = mat
	hub.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hub.position = Vector3(0, PIPE_Y, 0)
	parent.add_child(hub)
	for p in local_ports(k):
		add_tube(parent, p, RADIUS, mat)


## Мировые позиции концов (для снапа и связности).
func pipe_ports() -> Array:
	var out: Array = []
	for p in local_ports(kind):
		out.append(global_transform * p)
	return out
