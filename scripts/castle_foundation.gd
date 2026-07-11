class_name CastleFoundation
extends Node3D
## Фундамент замка — ПРИВЯЗАННАЯ точка закладки (акт II «Долина»): замок
## закладывается ТОЛЬКО здесь. ПИВОТ 2026-07-11: чертёж ([CastleBlueprint])
## больше не вкладывается в плиту — он кладётся на ВЕРХ БАШНИ (learned), после
## чего карточка «Замок» из панели стройки размещается рукой; силуэт ЛИПНЕТ к
## этой плите ([HandPlaceAim] — вне её красный запрет), commit зовёт [consume].
## После закладки фундамент ИСЧЕЗАЕТ (фидбек 2026-07-07 — раньше плита
## оставалась постаментом).
##
## Визуал — УЗЛЫ СЦЕНЫ castle_foundation.tscn (Plate + Ring): фундамент виден
## во вьюпорте редактора, дизайнер двигает его мышкой ([[feedback_ui_editor_tweakable]]).
## Скрипт только пульсирует кольцом и ведёт логику закладки.
##
## Позиция ноды должна лежать на клетке грида ([CityGrid], клетка 2м) — снап
## при закладке подстрахует, но жилы вокруг ставь по сетке GridAnchor.

const GROUP := &"castle_foundation"

## Цвет пульс-кольца ожидающего фундамента (в тон «синьки» чертежа).
@export var glow_color: Color = Color(0.4, 0.65, 1.0)

var _used: bool = false
var _ring_mat: StandardMaterial3D = null
var _pulse_tween: Tween = null


func _ready() -> void:
	add_to_group(GROUP)
	_ring_mat = ($Ring as MeshInstance3D).material_override as StandardMaterial3D
	if _ring_mat != null:
		_ring_mat.albedo_color = glow_color
		_ring_mat.emission = glow_color
		_pulse_tween = create_tween().set_loops()
		_pulse_tween.tween_property(_ring_mat, "emission_energy_multiplier", 2.4, 1.1) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_pulse_tween.tween_property(_ring_mat, "emission_energy_multiplier", 0.8, 1.1) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func is_used() -> bool:
	return _used


## Плита приняла ЗАКЛАДКУ замка (рука поставила карточку «Замок», [HandPlaceAim._commit]):
## FX + роль сыграна — фундамент исчезает, место занимает стройка замка.
func consume() -> void:
	if _used:
		return
	_used = true
	var scene: Node = get_tree().current_scene
	if scene != null:
		AoeVisual.spawn_explosion(scene, global_position + Vector3.UP * 0.5, 2.2)
		AoeVisual.spawn_pulse_sparks(scene, global_position + Vector3.UP * 0.5, 3.0, 14.0)
	EventBus.camera_shake.emit(0.4, global_position)
	EventBus.tutorial_hint.emit("🏰 Фундамент принял закладку — замок встаёт!", 6.0)
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
	queue_free()
