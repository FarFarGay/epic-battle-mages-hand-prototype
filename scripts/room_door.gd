class_name RoomDoor
extends StaticBody3D
## Дверь-заглушка комнаты: статичный барьер. Супер-рывок башни сносит её,
## разнося по физике ([ShatterEffect] — тот же язык осколков, что у врагов),
## открывает проём (rebake навмеша) и самоудаляется. Обычный рывок/каст не
## трогают — только супер-рывок (см. Tower._resolve_contacts, гейт _dash_is_super).

const NAV_GROUP := &"nav_region"
const NAVMESH_SOURCE_GROUP := &"navmesh_source"

## Цвет осколков (= цвет двери).
@export var shatter_color: Color = Color(0.46, 0.2, 0.13)
## Очагов осколков вдоль двери (по локальной X) — чтобы рассыпалась по всей ширине,
## а не одной кучей из центра.
@export var shatter_points: int = 6
## Кубиков в каждом очаге.
@export var fragments_per_point: int = 6
## Полуширина двери по локальной X (разброс очагов). Дверь 8м → ставим чуть меньше 4.
@export var half_width: float = 3.6

var _shattered: bool = false


## Снести дверь: осколки по физике + открыть проём + удалиться. Идемпотентно.
## hit_dir — направление удара (рывок башни): осколки летят ОТ башни, вперёд
## по ходу тарана (burst_dir в [ShatterEffect.spawn]). Zero = прежний веер.
func shatter(hit_dir: Vector3 = Vector3.ZERO) -> void:
	if _shattered:
		return
	_shattered = true
	# Снять с навмеша СРАЗУ: queue_free отложен до конца кадра, иначе rebake
	# ещё «видит» дверь как препятствие и проём не откроется.
	if is_in_group(NAVMESH_SOURCE_GROUP):
		remove_from_group(NAVMESH_SOURCE_GROUP)
	var scene := get_tree().current_scene
	var x_axis: Vector3 = global_transform.basis.x.normalized()
	for i in range(shatter_points):
		var t: float = 0.0
		if shatter_points > 1:
			t = lerpf(-half_width, half_width, float(i) / float(shatter_points - 1))
		var p: Vector3 = global_position + x_axis * t + Vector3.UP * 1.4
		ShatterEffect.spawn(scene, p, shatter_color, fragments_per_point, 2.0, hit_dir)
	EventBus.camera_shake.emit(0.35, global_position)
	# Проём открылся — перепечь навмеш (агенты/враги пойдут сквозь).
	var nav := get_tree().get_first_node_in_group(NAV_GROUP)
	if nav != null and nav.has_method(&"rebake"):
		nav.rebake()
	queue_free()
