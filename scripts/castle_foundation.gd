class_name CastleFoundation
extends Node3D
## Фундамент замка — ПРИВЯЗАННАЯ точка закладки (акт II «Долина»): замок не
## ставится из палитры, а закладывается ТОЛЬКО здесь. Рука вкладывает чертёж
## ([CastleBlueprint], его release-снап зовёт [seat]) → фундамент поглощает
## предмет и спавнит стройплощадку замка ([RoomBuildSite], building_id=PUMP) —
## дальше обычный путь стройки артелью (чит free_build достроит мгновенно).
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
const ROOM_BUILD_SITE := preload("res://scripts/room_build_site.gd")

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


## Вклад чертежа: доводка предмета в центр плиты, растворение, закладка стройки.
## Зовёт [CastleBlueprint._on_hand_released] — предмет уже заморожен и снят со слоёв.
func seat(blueprint: Node3D) -> void:
	if _used:
		return
	_used = true
	var tw := create_tween()
	tw.tween_property(blueprint, "global_position", global_position + Vector3.UP * 0.5, 0.3) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(blueprint, "scale", Vector3.ONE * 0.05, 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		if is_instance_valid(blueprint):
			blueprint.queue_free()
		if is_instance_valid(self):
			_commit_build())


## Закладка: FX + стройплощадка замка обычным путём (как рука в [HandPlaceAim._commit]).
func _commit_build() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var root_pos: Vector3 = CityGrid.snap(global_position, get_tree())
	AoeVisual.spawn_explosion(scene, root_pos + Vector3.UP * 0.5, 2.2)
	AoeVisual.spawn_pulse_sparks(scene, root_pos + Vector3.UP * 0.5, 3.0, 14.0)
	EventBus.camera_shake.emit(0.4, root_pos)
	var site := StaticBody3D.new()
	site.set_script(ROOM_BUILD_SITE)
	site.building_id = RoomBuildings.PUMP
	scene.add_child(site)
	site.global_position = root_pos
	EventBus.tutorial_hint.emit("🏰 Фундамент принял чертёж — замок встаёт!", 6.0)
	# Роль сыграна: плита исчезает, место занимает стройка замка.
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
	queue_free()
