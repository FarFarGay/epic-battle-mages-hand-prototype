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

@export var debug_log: bool = true

const ORB_SCENE := preload("res://scenes/xp_orb.tscn")
## Сколько XP даёт один орб на arrival. Совпадает с прежним
## `Camp.squad_xp_per_kill = 10`.
const XP_PER_KILL: int = 10
## Высота спавна орба над `enemy.global_position` (то есть над **центром
## капсулы скелета**, не над полом). Skeleton.tscn — CapsuleShape3D height=2,
## origin в центре капсулы → когда скелет стоит на полу, его global_position.y
## ≈ 1.0 (низ капсулы касается пола). +1.0 → орб появляется на y≈2.0 — над
## макушкой скелета и явно выше любой травы (~0.7м).
##
## Не используем абсолютную мировую Y: ground в `main.tscn` смещён по Y
## (origin.y=−0.5), а Y скелета меняется в knockback/lunge — относительный
## offset от трупа стабилен в любой момент смерти.
const SPAWN_OFFSET_Y: float = 1.0

## МАНА-КРИСТАЛЛ с ТЯЖЁЛОГО врага (super_dash_only: гигант/метатель; мех):
## жирная порция маны «выковырял из туши» — тяжёлый бой сам подкидывает топливо
## артиллерии. Не новая сущность: тот же XpOrb, просто крупный и ледяно-белый.
const MANA_PER_HEAVY_CRYSTAL: float = 40.0
static var _crystal_material: StandardMaterial3D


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
	# Позицию ставим ДО `add_child`: иначе `_ready` орба сработает на момент
	# добавления, ещё с дефолтной (0,0,0), и захватит `_base_y = 0`. Bobbing
	# тогда качается вокруг нуля и орб уходит под пол. Используем `.position`,
	# которая совпадает с `global_position` потому что parent (current_scene =
	# `Main`) — Node3D с identity transform.
	var enemy_pos: Vector3 = enemy.global_position
	orb.position = enemy_pos + Vector3.UP * SPAWN_OFFSET_Y
	tree.current_scene.add_child(orb)
	# ТЯЖЁЛЫЙ враг дополнительно роняет мана-кристалл (жирная порция).
	if enemy.is_in_group(&"super_dash_only") or enemy.is_in_group(EnemyMech.MECH_GROUP):
		_spawn_mana_crystal(tree, enemy_pos)
	if debug_log and LogConfig.master_enabled:
		print("[XpOrbSpawner] spawn: enemy=(%.2f, %.2f, %.2f) → orb=(%.2f, %.2f, %.2f), offset_y=%.2f" % [
			enemy_pos.x, enemy_pos.y, enemy_pos.z,
			orb.global_position.x, orb.global_position.y, orb.global_position.z,
			SPAWN_OFFSET_Y,
		])


## Мана-кристалл: XpOrb с жирной порцией маны; крупнее и ледяно-белый —
## отличим от синего мана-орба (один визуальный язык = один смысл).
func _spawn_mana_crystal(tree: SceneTree, pos: Vector3) -> void:
	var orb := ORB_SCENE.instantiate() as XpOrb
	if orb == null:
		return
	orb.amount = 0
	orb.mana_amount = MANA_PER_HEAVY_CRYSTAL
	orb.position = pos + Vector3.UP * (SPAWN_OFFSET_Y + 0.4)
	tree.current_scene.add_child(orb)
	orb.scale = Vector3.ONE * 1.7
	var mesh := orb.get_node_or_null(^"Mesh") as MeshInstance3D
	if mesh != null:
		if _crystal_material == null:
			_crystal_material = StandardMaterial3D.new()
			_crystal_material.albedo_color = Color(0.85, 0.95, 1.0)
			_crystal_material.emission_enabled = true
			_crystal_material.emission = Color(0.7, 0.9, 1.0)
			_crystal_material.emission_energy_multiplier = 3.0
		mesh.material_override = _crystal_material
