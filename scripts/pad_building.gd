class_name PadBuilding
extends Node3D
## Полимино-постройка на площадке вокруг качалки (тетрис-фигура из клеток сетки). ОДНА
## модель для всех ролей: защита / атака / добыча — пока различаются только цветом
## (функции = Фаза 2: контур-стена + навмеш, радиус стрельбы, буст соседством). Снап и
## занятость клеток — через [OilGrid]. group pad_building. Ставится мгновенно рукой
## ([HandPlaceAim]); ПКМ сносит.

const GROUP := &"pad_building"

var building_id: StringName = &""
var _mask: Array = []        # Array[Vector2i] — клетки фигуры (локальные offset'ы)
var _role: StringName = &"defend"


## Задаётся ДО add_child (как RoomBuildSite) — _ready строит по маске.
func setup(id: StringName) -> void:
	building_id = id
	var d: Dictionary = RoomBuildings.get_data(id)
	_mask = d.get("cells", [])
	_role = d.get("role", &"defend")


func _ready() -> void:
	add_to_group(GROUP)
	_build()


## Куб на каждую клетку маски (локально, узел повёрнут на rot при установке). Визуал-
## заглушка Фазы 1 — без коллайдера/навмеша (стена = Фаза 2).
func _build() -> void:
	var s: float = OilGrid.CELL
	var col: Color = _role_color(_role)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.metallic = 0.1
	mat.roughness = 0.7
	for off in _mask:
		var o := off as Vector2i
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(s * 0.96, 1.4, s * 0.96)
		mi.mesh = box
		mi.material_override = mat
		mi.position = Vector3(o.x * s, 0.7, o.y * s)
		add_child(mi)


## Мировые клетки, занятые постройкой (для проверки наложения при размещении).
func occupied_cells() -> Array:
	return OilGrid.building_cells(global_position, _mask, rotation.y, get_tree())


func _role_color(r: StringName) -> Color:
	match r:
		&"attack":
			return Color(0.82, 0.4, 0.34)   # атака — красноватый
		&"mine":
			return Color(0.88, 0.68, 0.26)  # добыча — охра
	return Color(0.5, 0.58, 0.72)           # защита — серо-синий
