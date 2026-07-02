class_name RoomBuildSite
extends StaticBody3D
## Универсальная стройплощадка комнатного режима. Рука ставит её ([HandPlaceAim]),
## рабочий-гном с ресурсом «бьёт» её ударом (gnome_hit), докладывая по единице —
## единая модель «гном → точка → действие» (как мост/горшок/дерево). Набрали
## resources_needed доставок → спавним настоящее здание (scene из [RoomBuildings])
## на этом же трансформе и уходим. Generic: тип задаётся building_id.
##
## ХРУПКАЯ, как [ConstructionSite]: входит в skeleton_target — скелеты могут сорвать
## стройку (ресурсы потеряны, здание не появится). Урон через Damageable.
##
## Коллайдера НЕ держим: цель удара/урона работает через ГРУППЫ + global_position +
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
## сразу при установке, БЕЗ ресурсов и ожидания; false — обычная экономика (призрак ждёт
## доставки). Действует на МОМЕНТ установки: уже поставленные призраки не достраиваются
## задним числом при включении.
static var free_build := true

## Тип здания из [RoomBuildings]. Задаётся HandPlaceAim'ом ДО add_child.
@export var building_id: StringName = &""

var _data: Dictionary = {}
var _resource_type: int = 0
var _needed: int = 3
var _delivered: int = 0
var _hp: float = 35.0
var _complete: bool = false
var _destroyed: bool = false
var _ghost: MeshInstance3D = null
var _footprint: Vector3 = Vector3(2.0, 1.5, 0.3)


func _ready() -> void:
	_data = RoomBuildings.get_data(building_id)
	_resource_type = int(_data.get("resource_type", ResourcePile.ResourceType.WOOD))
	_needed = maxi(int(_data.get("resources_needed", 3)), 1)
	_hp = float(_data.get("site_hp", 35.0))
	_footprint = _data.get("footprint", _footprint)
	_spawn_ghost()
	Damageable.register(self)
	add_to_group(Layers.GNOME_STRIKE_TARGET_GROUP)  # area-клик рабочего → BUILD
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


## Полупрозрачный силуэт будущего здания — растёт по Y с прогрессом доставок.
func _spawn_ghost() -> void:
	_ghost = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = _footprint
	_ghost.mesh = box
	var mat := StandardMaterial3D.new()
	var color: Color = _data.get("ghost_color", Color(0.6, 0.8, 1.0, 0.4))
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost.material_override = mat
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ghost)
	_update_ghost_progress()


func _update_ghost_progress() -> void:
	if not is_instance_valid(_ghost):
		return
	# Силуэт «растёт из земли»: высота ∝ доле доставленного (мин 8%, чтобы было видно).
	var frac: float = clampf(float(_delivered) / float(_needed), 0.08, 1.0)
	_ghost.scale = Vector3(1.0, frac, 1.0)
	_ghost.position = Vector3(0.0, _footprint.y * 0.5 * frac, 0.0)


## Контракт strike-цели: докладывать может только рабочий С ношей (пустой сперва
## идёт к дереву/складу). Не рабочий — мимо.
func can_gnome_interact(gnome: Node) -> bool:
	if _complete or _destroyed:
		return false
	if not (gnome.has_method(&"is_worker") and gnome.is_worker()):
		return false
	return gnome.has_method(&"is_carrying") and gnome.is_carrying()


## Рабочий положил единицу: списываем ношу, растим силуэт. Набрали — здание готово.
func gnome_hit(gnome: Node) -> void:
	if _complete or _destroyed or gnome == null or not gnome.has_method(&"deliver_resource"):
		return
	if gnome.deliver_resource() < 0:
		return  # ресурса не оказалось (рассинхрон) — не засчитываем
	_delivered += 1
	_update_ghost_progress()
	if _delivered >= _needed:
		_finish()


## Стройка завершена: спавним настоящее здание на трансформе площадки, dust-пуф,
## перепекаем навмеш (новое здание режет проходимость), уходим.
func _finish() -> void:
	if _complete:
		return
	_complete = true
	remove_from_group(Layers.GNOME_STRIKE_TARGET_GROUP)
	remove_from_group(Layers.BUILD_SITE_GROUP)
	remove_from_group(SKELETON_TARGET_GROUP)
	var root: Node = get_tree().current_scene
	var scene_path: String = _data.get("scene", "")
	var impact_played := false
	if scene_path != "" and root != null:
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
	remove_from_group(Layers.GNOME_STRIKE_TARGET_GROUP)
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


## Красный flash силуэта при ударе (язык урона как у зданий/моста).
func _flash() -> void:
	if not is_instance_valid(_ghost):
		return
	var mat := _ghost.material_override as StandardMaterial3D
	if mat == null:
		return
	var orig: Color = mat.albedo_color
	mat.albedo_color = Color(1.0, 0.3, 0.25, orig.a)
	var tw := create_tween()
	tw.tween_property(mat, "albedo_color", orig, 0.18)


func _rebake_nav() -> void:
	var nav := get_tree().get_first_node_in_group(NAV_GROUP)
	if nav != null and nav.has_method(&"rebake"):
		get_tree().create_timer(0.05).timeout.connect(Callable(nav, "rebake"))
