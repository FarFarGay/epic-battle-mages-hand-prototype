extends Node
## Координатор визуального фидбэка squad XP. Сейчас держит только popup'ы
## («+N» в точке arrival орба к anchor'у).
##
## Регистрируется как autoload — глобальный слушатель EventBus. Autoload
## парсится до глобального class_name-registry, поэтому SquadXpPopup
## подгружаем явным `preload` (не через class_name).
##
## Сами popup'ы — Label3D в дереве `current_scene`, не потомки этого autoload'а
## (тот не Node3D, не имеет world transform).
##
## История (этап 49): была попытка добавить kill-trail-частицу — золотая
## искорка летит от трупа к ближайшему защитнику. Снято: визуально
## неотличимо от XpOrb (тот же золотой emissive шарик), игрок считывает
## частицу как «вот мой XP полетел в стрелка», а орб на земле — как
## что-то отдельное. Когнитивный диссонанс с реальной механикой
## (XP идёт через орб, частица была flavor). Один визуальный язык — один
## смысл: золотой шар = XP, и это орб на земле, который надо собрать.

const SquadXpPopupScene = preload("res://scripts/squad_xp_popup.gd")


func _ready() -> void:
	EventBus.squad_xp_gained_at.connect(_on_xp_gained)
	# Доход казны (горшочная монета доехала, гном продал бревно) — тот же попап,
	# текст с номиналом: доход читается в точке прихода (фидбек 2026-07-07).
	EventBus.coins_gained_at.connect(_on_coins_gained)


func _on_xp_gained(amount: int, world_position: Vector3) -> void:
	_spawn_popup("+%d" % amount, world_position)


func _on_coins_gained(amount: int, world_position: Vector3) -> void:
	_spawn_popup("+%d🥉" % amount, world_position)


func _spawn_popup(text: String, world_position: Vector3) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null or not is_instance_valid(scene):
		return
	var popup = SquadXpPopupScene.new()
	popup.text = text
	scene.add_child(popup)
	popup.global_position = world_position
