extends Node
## Autoload, отвечающий за спавн `XpOrb` на смерть врага. Подписан на
## `EventBus.enemy_destroyed`, спавнит орб в позиции трупа в `current_scene`.
##
## Архитектурно: Skeleton'у не нужно знать про XP, EnemySpawner — про орбы.
## Один autoload-листенер замыкает все enemy_destroyed → XpOrb-спавны.
##
## Если в будущем появятся разные типы врагов (boss'ы, special) с разной
## наградой — добавить override XP на самом Enemy и читать его здесь
## (типа `if "xp_drop" in enemy: amount = enemy.xp_drop`). Сейчас все враги
## дают одинаковую сумму.
##
## Сцена орба и величина XP — `preload`/`const`, потому что autoload не
## привязан к .tscn-инстансу и @export-поля у него не редактируются из
## инспектора. Если потребуется балансить — менять прямо в этом файле.

const ORB_SCENE := preload("res://scenes/xp_orb.tscn")
## Сколько XP даёт один орб на arrival. Совпадает с прежним
## `Camp.squad_xp_per_kill = 10`.
const XP_PER_KILL: int = 10
## Высота над трупом, на которой орб спавнится (и от которой `_base_y`
## отсчитывает bobbing ±bobbing_amplitude=0.15). Должна быть выше верхушек
## травы, иначе орб утопает визуально и кажется будто «уходит под землю».
## Трава GrassField ~0.7м высотой, sphere radius 0.2 — берём 1.2 чтобы низ
## sphere в нижней фазе bobbing'а (1.2 − 0.15 − 0.2 = 0.85м) был явно над
## верхушками травы. Должна совпадать с `XpOrb.magnet_target_offset_y`,
## иначе на полёте орб уйдёт ниже и нырнёт в траву.
const SPAWN_OFFSET_Y: float = 1.2


func _ready() -> void:
	EventBus.enemy_destroyed.connect(_on_enemy_destroyed)


func _on_enemy_destroyed(enemy: Node3D) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var orb := ORB_SCENE.instantiate() as XpOrb
	if orb == null:
		push_warning("XpOrbSpawner: ORB_SCENE не инстанцируется как XpOrb")
		return
	orb.amount = XP_PER_KILL
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		# Сцена ещё не готова (теоретически возможно при ранних emit'ах) —
		# тихо пропускаем, чтобы не утечь дочерней нодой.
		orb.queue_free()
		return
	tree.current_scene.add_child(orb)
	# Спавним там, где умер скелет, поднимая над полом на SPAWN_OFFSET_Y.
	# Берём X/Z с трупа, Y задаём абсолютной высотой над землёй (а не +offset
	# к skel.y, иначе при нестабильной Y-позиции скелета — на ходу, в
	# knockback'е, под анимацией смерти — орб мог появиться ниже травы).
	# Карта плоская, ground.y=0 — `SPAWN_OFFSET_Y` в мировых координатах = OK.
	var spawn_pos: Vector3 = enemy.global_position
	spawn_pos.y = SPAWN_OFFSET_Y
	orb.global_position = spawn_pos
