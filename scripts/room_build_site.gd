class_name RoomBuildSite
extends StaticBody3D
## Универсальная стройплощадка комнатного режима. Рука ставит её ([HandPlaceAim]),
## дальше здание ВОЗВОДИТСЯ САМО за build_time (дизайн 2026-07-03: гномы в стройке
## НЕ участвуют — артель только чинит башню; доставка ресурсов вырезана). Призрак
## растёт по таймеру; истёк → спавним настоящее здание на этом же трансформе:
## сцену из каталога (замок/стена-брус) ИЛИ полимино-PadBuilding по маске "cells"
## (кварталы/стены/ворота — ЕДИНЫЙ путь стройки, ставятся с «печатью»).
##
## ХРУПКАЯ, как [ConstructionSite]: входит в skeleton_target — скелеты могут сорвать
## стройку (монеты потеряны, здание не появится). Урон через Damageable.
##
## Коллайдера НЕ держим: цель урона работает через ГРУППЫ + global_position +
## Damageable (как у ConstructionSite), физически блокировать недострой не нужно.

signal damaged(amount: float)
signal destroyed

const NAV_GROUP := &"nav_region"
const SKELETON_TARGET_GROUP := &"skeleton_target"
## Группа snap-целей стен: и площадки-чертежи, и достроенные стены. HandPlaceAim
## магнитит силуэт к их краям/центру. Член несёт meta "wall_half_len" (полудлина
## по миру) и ориентацию через global_transform.basis.x. См. [[project_ebm_building_rework]].
const WALL_SNAP_GROUP := &"wall_snap"

## FX «печати» установки достроенного здания (падение+сквош+пыль+рябь+тряска).
const PlaceFx = preload("res://scripts/place_impact_fx.gd")

## Рантайм-тумблер (чит «Бесплатная стройка» в Журнале): true — площадка достраивается
## сразу при установке, без ожидания; false — самостройка за build_time (призрак растёт
## по таймеру). Действует на МОМЕНТ установки: уже поставленные призраки не достраиваются
## задним числом при включении.
static var free_build := true

## Время самостройки, если в каталоге нет явного "build_time".
const BUILD_TIME_DEFAULT := 4.0
## Полимино: базовое время + добавка за клетку (большой квартал возводится дольше).
const BUILD_TIME_BASE_CELLS := 1.6
const BUILD_TIME_PER_CELL := 0.8
## Высота куба-призрака полимино-клетки (у полимино нет footprint из каталога).
const GHOST_CELL_HEIGHT := 2.0


## Время самостройки по записи каталога: явный "build_time" > полимино по числу
## клеток > дефолт. Static — этим же пользуется карточка палитры (⏱ в цене).
static func build_time_for(data: Dictionary) -> float:
	if data.has("build_time"):
		return maxf(float(data["build_time"]), 0.1)
	var cells: Array = data.get("cells", [])
	if not cells.is_empty():
		return BUILD_TIME_BASE_CELLS + BUILD_TIME_PER_CELL * float(cells.size())
	return BUILD_TIME_DEFAULT

## Тип здания из [RoomBuildings]. Задаётся HandPlaceAim'ом ДО add_child.
@export var building_id: StringName = &""

var _data: Dictionary = {}
var _build_time: float = BUILD_TIME_DEFAULT
var _elapsed: float = 0.0
var _hp: float = 35.0
var _complete: bool = false
var _destroyed: bool = false
## Части призрака (полимино — куб на клетку; прочее — один бокс) + ОБЩИЙ материал
## (flash урона красит все части разом).
var _ghost_parts: Array[MeshInstance3D] = []
var _ghost_mat: StandardMaterial3D = null
var _footprint: Vector3 = Vector3(2.0, 1.5, 0.3)


func _ready() -> void:
	_data = RoomBuildings.get_data(building_id)
	_build_time = build_time_for(_data)
	_hp = float(_data.get("site_hp", 35.0))
	_footprint = _data.get("footprint", _footprint)
	_spawn_ghost()
	Damageable.register(self)
	add_to_group(Layers.BUILD_SITE_GROUP)
	add_to_group(SKELETON_TARGET_GROUP)             # скелеты могут сорвать стройку
	# Snap-цель ТОЛЬКО для стен (snap_target): к чертежу магнитится следующий силуэт
	# (лабиринт). Башня и прочее не магнитятся.
	if _data.get("snap_target", false):
		add_to_group(WALL_SNAP_GROUP)
		set_meta(&"wall_half_len", _footprint.x * 0.5)
	# Бесплатный режим: достроить сразу (deferred — HandPlaceAim ставит трансформ
	# ПОСЛЕ add_child, иначе здание появится в (0,0,0)).
	if free_build:
		call_deferred(&"_finish")


## Самостройка: призрак растёт сам по таймеру, истёк — здание готово.
func _process(delta: float) -> void:
	if _complete or _destroyed or free_build:
		return
	_elapsed += delta
	_update_ghost_progress()
	if _elapsed >= _build_time:
		_finish()


## Полупрозрачный силуэт будущего здания — растёт по Y с прогрессом самостройки.
## Полимино — куб на каждую клетку маски (та же геометрия, что у будущего здания);
## прочее — один бокс по footprint из каталога.
func _spawn_ghost() -> void:
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.albedo_color = _data.get("ghost_color", Color(0.6, 0.8, 1.0, 0.4))
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var cells: Array = _data.get("cells", [])
	if cells.is_empty():
		_add_ghost_part(Vector3.ZERO, _footprint)
	else:
		var s: float = CityGrid.CELL
		for off in cells:
			var o := off as Vector2i
			_add_ghost_part(Vector3(o.x * s, 0.0, o.y * s), Vector3(s * 0.92, GHOST_CELL_HEIGHT, s * 0.92))
	_update_ghost_progress()


func _add_ghost_part(base_xz: Vector3, size: Vector3) -> void:
	var box := BoxMesh.new()
	box.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.material_override = _ghost_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	mi.position = base_xz  # y выставит _update_ghost_progress (рост из земли)
	mi.set_meta(&"h", size.y)
	_ghost_parts.append(mi)


func _update_ghost_progress() -> void:
	# Силуэт «растёт из земли»: высота ∝ прошедшему времени (мин 8%, чтобы было видно).
	var frac: float = clampf(_elapsed / maxf(_build_time, 0.01), 0.08, 1.0)
	for mi in _ghost_parts:
		if not is_instance_valid(mi):
			continue
		var h: float = float(mi.get_meta(&"h", 1.5))
		mi.scale = Vector3(1.0, frac, 1.0)
		mi.position.y = h * 0.5 * frac


## Клетки, занимаемые строящимся ПОЛИМИНО — резерв грида, чтобы второй силуэт не
## наложить на недострой (HandPlaceAim._occupied_cells сканирует BUILD_SITE_GROUP).
## Не-полимино (замок/стена-брус вне грида) → пусто.
func occupied_cells() -> Array:
	if not _data.has("cells"):
		return []
	return CityGrid.building_cells(global_position, _data.get("cells", []), rotation.y, get_tree())


## Стройка завершена: спавним настоящее здание на трансформе площадки, dust-пуф,
## перепекаем навмеш (новое здание режет проходимость), уходим.
func _finish() -> void:
	if _complete:
		return
	_complete = true
	remove_from_group(Layers.BUILD_SITE_GROUP)
	remove_from_group(SKELETON_TARGET_GROUP)
	var root: Node = get_tree().current_scene
	var scene_path: String = _data.get("scene", "")
	var impact_played := false
	# ПОЛИМИНО (кварталы/стены/ворота): здание строится КОДОМ по маске, не сценой.
	if _data.has("cells") and root != null:
		var pb := PadBuilding.new()
		pb.setup(building_id)
		root.add_child(pb)
		pb.global_position = global_position
		pb.rotation.y = rotation.y
		pb.flash_quarter_links()  # закрыл грань квартала → импульс к продюсеру
		PadBuilding.refresh_walls(get_tree())  # стены дотянутся до новой постройки
		pb.play_place_impact()  # «печать» ПОСЛЕ refresh (top_level-чанки стен уже собраны)
		impact_played = true
	elif scene_path != "" and root != null:
		var ps := load(scene_path) as PackedScene
		if ps != null:
			var building := ps.instantiate()
			root.add_child(building)
			if building is Node3D:
				var b := building as Node3D
				b.global_position = global_position
				b.rotation.y = rotation.y
				# Нативная сцена 2м по X — тянем до длины из каталога (совпасть с силуэтом).
				var native_len: float = float(_data.get("native_scene_length", 0.0))
				if native_len > 0.0:
					b.scale = Vector3(_footprint.x / native_len, 1.0, 1.0)
				# Достроенная стена тоже snap-цель — следующий силуэт магнитится к ней.
				if _data.get("snap_target", false):
					b.add_to_group(WALL_SNAP_GROUP)
					b.set_meta(&"wall_half_len", _footprint.x * 0.5)
				# «Печать» установки: пыль/рябь/тряску даёт она (scale стены захватывается
				# КАК базовый — восстановление в растянутый, не в ONE).
				PlaceFx.play(b, _footprint.x * 0.5 + 0.7)
				impact_played = true
	if root != null and not impact_played:
		AoeVisual.spawn_dust(root, global_position)
	_rebake_nav()
	queue_free()


## Стройку сорвали (скелеты разбили площадку). Здание НЕ появляется. Из групп
## выходим СРАЗУ до emit (queue_free отложен — [[reference_godot_queue_free_deferred]]).
func _fail() -> void:
	if _destroyed:
		return
	_destroyed = true
	remove_from_group(Layers.BUILD_SITE_GROUP)
	remove_from_group(SKELETON_TARGET_GROUP)
	remove_from_group(Damageable.GROUP)
	destroyed.emit()
	queue_free()


# --- Damageable (скелеты бьют стройплощадку) ---

func take_damage(amount: float) -> void:
	if _complete or _destroyed or amount <= 0.0:
		return
	_hp -= amount
	damaged.emit(amount)
	_flash()
	if _hp <= 0.0:
		_fail()


## Красный flash силуэта при ударе (язык урона как у зданий/моста). Материал
## общий на все части призрака — красится весь недострой разом.
func _flash() -> void:
	if _ghost_mat == null:
		return
	var orig: Color = _data.get("ghost_color", Color(0.6, 0.8, 1.0, 0.4))
	_ghost_mat.albedo_color = Color(1.0, 0.3, 0.25, orig.a)
	var tw := create_tween()
	tw.tween_property(_ghost_mat, "albedo_color", orig, 0.18)


func _rebake_nav() -> void:
	var nav := get_tree().get_first_node_in_group(NAV_GROUP)
	if nav != null and nav.has_method(&"rebake"):
		get_tree().create_timer(0.05).timeout.connect(Callable(nav, "rebake"))
