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
	# Спавним там, где умер скелет, поднимая над полом. base_y у орба =
	# точка спавна, и bobbing колеблется ±bobbing_amplitude=0.15. Чтобы
	# нижняя сторона sphere (radius=0.2) не уходила под Ground даже в
	# нижней фазе, нужно: spawn_y - amplitude - radius ≥ 0 → spawn_y ≥ 0.35.
	# Берём 0.7 с запасом (~0.55..0.85 диапазон центра, ~0.35..0.65 для низа
	# сферы) — комфортно над травой, орб всегда читается visually.
	orb.global_position = enemy.global_position + Vector3.UP * 0.7
