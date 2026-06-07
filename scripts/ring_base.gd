class_name RingBase
extends Node3D
## Октагон-кольцо mount-слотов вокруг ядра лагеря (Harvester). На развёртке
## лагеря 8 слотов встают по октагону на земле вокруг харвестера; игрок хватает
## блок-модуль рукой (любой `CampModule` — пока турель, далее палатка-жизнь и т.д.)
## и отпускает у слота — модуль защёлкивается. Это переиспользует готовую
## механику `MountSlot`/`CampModule` (grab→release-snap), кольцо лишь расставляет
## и включает/выключает слоты по фазам лагеря.
##
## Слот пустой → светится октагон-пад-маркер (куда ставить). Слот занят →
## маркер гаснет. На свёртке лагеря слоты выключаются: стоящие модули падают
## на землю как свободные RigidBody (забираются рукой отдельно — базу целиком
## с собой не тащим, см. дизайн «забираешь палатки/ресурсы, не всю крепость»).
##
## Связки/бонусы соседства, типы блоков (турель/палатка/стена), стена-периметр,
## HP блоков и починка гномами — следующие итерации. Здесь — только сама
## механика установки в кольцо.

## Радиус кольца слотов от центра. Меньше deploy_radius палаток (8м) — блоки
## сидят между ядром-харвестером и внешним кольцом палаток. Харвестер — центр
## конструкции и композиции; кольцо отодвинуто, оставляя вокруг ядра дворик.
@export var ring_radius: float = 5.5
## Радиус защёлки каждого слота. Узкий: шаг между соседними слотами октагона
## ≈ 0.77×ring_radius (для r=5 ≈ 3.8м), 1.6 не даёт перехватывать чужой блок.
@export var snap_radius: float = 1.6
## Сколько слотов в кольце. 8 = октагон (тематично — как OctagonTurret).
@export var slot_count: int = 8
## Доп. вертикальный сдвиг точки слота. По умолчанию 0 — слоты чистые позиции,
## весь подъём задаёт сам модуль (CampModule.mount_lift = его полувысота).
@export var module_lift: float = 0.0
## Цвет октагон-пада пустого слота.
@export var marker_color: Color = Color(0.45, 0.85, 1.0, 0.5)
@export var debug_log: bool = true

var _slots: Array[MountSlot] = []
var _markers: Array[MeshInstance3D] = []
var _active: bool = false


func _ready() -> void:
	_build_slots()


## Создаёт слоты + октагон-пад-маркеры один раз. Слоты стартуют выключенными —
## кольца нет, пока лагерь не развёрнут.
func _build_slots() -> void:
	for i in range(slot_count):
		var slot := MountSlot.new()
		slot.name = "RingSlot%d" % i
		slot.snap_radius = snap_radius
		slot.module_offset = Vector3(0.0, module_lift, 0.0)
		# Блоки-сегменты разворачиваются гранью наружу → смыкаются в кольцо.
		slot.align_rotation = true
		slot.debug_log = debug_log
		slot.enabled = false
		add_child(slot)
		var marker := _make_marker()
		marker.visible = false
		slot.add_child(marker)
		# bind(i) добавляет индекс ПОСЛЕ штатного аргумента сигнала (module).
		slot.module_attached.connect(_on_slot_attached.bind(i))
		slot.module_detached.connect(_on_slot_detached.bind(i))
		_slots.append(slot)
		_markers.append(marker)


## Плоский октагон-пад на земле — маркер «сюда можно поставить блок».
func _make_marker() -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.9
	mesh.bottom_radius = 0.9
	mesh.height = 0.06
	mesh.radial_segments = 8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = marker_color
	mat.emission_enabled = true
	mat.emission = Color(marker_color.r, marker_color.g, marker_color.b)
	mat.emission_energy_multiplier = 0.6
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = Vector3(0.0, 0.03, 0.0)
	return mi


## Развернуть кольцо вокруг центра (позиция харвестера, Y — пол). Слоты встают
## по октагону, включаются, пустые подсвечиваются.
func deploy(center: Vector3) -> void:
	_active = true
	var n := _slots.size()
	for i in range(n):
		var angle := float(i) * TAU / float(maxi(n, 1))
		_slots[i].global_position = Vector3(
			center.x + cos(angle) * ring_radius,
			center.y,
			center.z + sin(angle) * ring_radius,
		)
		# Слот смотрит -Z на центр: смонтированный блок встаёт гранью наружу
		# (ширина — тангенциально), 8 блоков смыкаются в октагон-кольцо.
		_slots[i].look_at(center, Vector3.UP)
		_slots[i].enabled = true
		_markers[i].visible = not _slots[i].is_occupied()
	if debug_log and LogConfig.master_enabled:
		print("[RingBase] кольцо развёрнуто: %d слотов r=%.1f @ (%.1f, %.1f)" % [n, ring_radius, center.x, center.z])


## Свернуть кольцо: слоты выключаются (стоящие модули падают на землю), маркеры
## гаснут. Зеркалит выключение CenterMountSlot в Camp._finalize_pack.
func pack() -> void:
	_active = false
	for i in range(_slots.size()):
		_slots[i].enabled = false
		_markers[i].visible = false
	if debug_log and LogConfig.master_enabled:
		print("[RingBase] кольцо свёрнуто")


func _on_slot_attached(_module: Node, idx: int) -> void:
	if idx >= 0 and idx < _markers.size():
		_markers[idx].visible = false


func _on_slot_detached(_module: Node, idx: int) -> void:
	if idx >= 0 and idx < _markers.size() and _active:
		_markers[idx].visible = true
