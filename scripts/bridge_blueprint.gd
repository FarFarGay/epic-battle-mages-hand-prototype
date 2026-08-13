class_name BridgeBlueprint
extends CastleBlueprint
## ⭐ ЧЕРТЁЖ МОСТА (2026-08-13). Станок-чертёжник печатает лист, рука подбирает
## его ЛКМ, и ГДЕ ОТПУСТИЛ — там разворачивается мост. Так стройка осталась
## прерогативой башни (кладёт рука, из кабины), а у станка появилась работа:
## после переезда стройки в отдельный режим он печатал в пустоту.
##
## ⚠ ПОЧЕМУ НАСЛЕДНИК, А НЕ СВОЙ ПРЕДМЕТ. Язык чертежей в проекте один: «синька»
## печатается станком, светится, подсвечивается рукой, таскается как груз. Всё
## это уже написано в [CastleBlueprint] — свой предмет означал бы вторую копию
## того же визуала и той же обвязки Grabbable. Меняется РОВНО адрес доставки:
## у замка чертёж несут на верх башни (знание навсегда), у моста — в любую точку
## земли, и он тут же превращается в вещь.
##
## Разворачивается в ШТАТНУЮ плашку ([bridge_plank.gd]) — единственную в проекте,
## кто умеет резать проём в барьере пропасти и перепекать навмеш. Второй системы
## прохода через пропасть заводить нельзя, поэтому чертёж не «строит мост», а
## кладёт ту же самую доску.

const PLANK_SCENE: PackedScene = preload("res://scenes/bridge_plank.tscn")

## Ставить ли доску с авто-защёлком. true — упала над полосой пропасти и легла
## мостом сама, без второго захвата рукой: игрок уже сделал жест «положить сюда»,
## заставлять его повторять его же руками незачем.
@export var deploy_auto_snap: bool = true


## Доска на листе, а не кубик-башенка: силуэт обязан называть постройку.
func _model_size() -> Vector3:
	return Vector3(0.72, 0.07, 0.24)


## ⭐ ОТПУСТИЛ — ЗДЕСЬ И ВСТАЛ. Базовый чертёж ищет верх башни и молчит, если его
## рядом нет; у моста адрес — сама точка дропа, поэтому обработчик переопределён
## целиком, а не дополнен. Условие ровно одно: лист ещё не потрачен.
func _on_hand_released(item: Node3D, _velocity: Vector3) -> void:
	if item != self or _seated:
		return
	_seated = true
	_deploy()


## Разворот листа в доску: гасим лист, ставим плашку на ПОЛ под точкой дропа.
## Высоту берём лучом по террейну, а не текущим y листа: в руке он висит на
## высоте груди, и доска родилась бы в воздухе (та же грабля, что с высадкой
## экипажа на крышу башни).
func _deploy() -> void:
	freeze = true
	collision_layer = 0
	var root: Node = get_tree().current_scene
	if root == null or not is_instance_valid(root):
		queue_free()
		return
	var at: Vector3 = _ground_point(global_position)
	var plank := PLANK_SCENE.instantiate()
	# ⚠ auto_snap ВЫСТАВЛЯЕМ ДО add_child. Плашка заводит таймер опроса в своём
	# _ready и только если флаг уже стоит; add_child запускает _ready сразу, так
	# что флаг, поставленный после, опаздывает навсегда — доска ложится рядом с
	# пропастью и молча не открывает проход.
	if deploy_auto_snap and "auto_snap" in plank:
		plank.set(&"auto_snap", true)
	root.add_child(plank)
	if plank is Node3D:
		(plank as Node3D).global_position = at + Vector3.UP * 0.4
		# Доска ложится ПОПЕРЁК того, как стоял лист: игрок целится листом.
		(plank as Node3D).global_rotation = Vector3(0.0, global_rotation.y, 0.0)
	AoeVisual.spawn_pulse_sparks(root, at + Vector3.UP * 0.6, 1.6, 10.0)
	AoeVisual.spawn_dust(root, at)
	EventBus.camera_shake.emit(0.2, at)
	EventBus.tutorial_hint.emit(
			"Мост развёрнут. Лёг поперёк пропасти — проход открыт; лежит мимо — перетащи рукой", 5.0)
	queue_free()


## Пол под точкой: луч сверху вниз по слою террейна. Не нашли (дырка/за краем) —
## оставляем как есть, пусть падает физикой.
func _ground_point(from: Vector3) -> Vector3:
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(from.x, from.y + 6.0, from.z), Vector3(from.x, from.y - 20.0, from.z),
			Layers.TERRAIN)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return from
	return hit.position as Vector3
