class_name FrostBolt
extends Fireball
## Снаряд-мороз. Наследует баллистику Fireball (boost + homing), добавляет
## post-impact frost-эффекты:
##  - **Hit-target hard freeze** — все Enemy в радиусе AOE взрыва получают
##    полную заморозку (slow_factor=0.0) на `hit_freeze_duration` секунд.
##    Это «прямое попадание» — награда за точность.
##  - **FrostPatch на земле** — синяя зона `patch_radius` метров живёт
##    `patch_duration` секунд, замедляет всех вошедших до 60% скорости
##    (slow_factor=0.4). Это soft cc для последующих волн.
##
## Damage базового Fireball НЕ применяется (в SpellSystem подаём damage=0)
## — Frost это контроль, не урон. Knockback тоже подавлен (force=0).
## Дизайнерское правило: «один эффект = один смысл», Frost vs Fireball
## не должны размываться.
##
## Параметры frost'а override'ятся из `SpellSystem.get_current_level_data(&"frost")`.

@export_group("Frost")
## Длительность hard-freeze для прямого попадания (попавшие в AOE-радиус
## в момент взрыва). 0.0 в slow_factor → стоят как столбы, не атакуют.
@export var hit_freeze_duration: float = 2.0
## Сцена FrostPatch — синяя зона на земле. Если null — patch не спавнится
## (только мгновенный freeze попавших).
@export var frost_patch_scene: PackedScene
## Радиус FrostPatch. Больше AOE-радиуса самой ракеты (это "пятно льда").
@export var patch_radius: float = 4.0
## Время жизни FrostPatch.
@export var patch_duration: float = 4.0
## Множитель скорости в FrostPatch'е. 0.4 = 60% slow.
@export var patch_slow_factor: float = 0.4
## Время раскрытия FrostPatch от 0 до полного `patch_radius`. Зона льда
## растёт постепенно — игрок видит как «холод расползается» от точки удара.
@export var patch_grow_duration: float = 1.0


## Опциональный override параметров frost'а (из HandSpellFrost после
## SpellSystem level-data resolution). Аналог [setup_burn] у Fireball.
func setup_frost(
	patch_scene: PackedScene,
	hit_freeze: float,
	p_radius: float,
	p_duration: float,
	p_slow_factor: float,
	p_grow_duration: float = 1.0,
) -> void:
	frost_patch_scene = patch_scene
	hit_freeze_duration = hit_freeze
	patch_radius = p_radius
	patch_duration = p_duration
	patch_slow_factor = p_slow_factor
	patch_grow_duration = p_grow_duration


## Post-impact hook от Fireball._explode. Применяем hard-freeze всем
## Enemy в радиусе AOE (поверх damage=0 из базы) + спавним FrostPatch.
func _on_post_explode(origin: Vector3) -> void:
	if hit_freeze_duration > 0.0:
		_apply_hit_freeze(origin)
	if frost_patch_scene != null:
		_spawn_frost_patch(origin)


## Скан всех Enemy в AOE-радиусе ракеты, hard-freeze на hit_freeze_duration.
## Дёшево: 1 кадр × кол-во врагов в зоне (~5-15 максимум).
func _apply_hit_freeze(origin: Vector3) -> void:
	var radius_sq: float = _radius * _radius
	var hits: int = 0
	for n in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(n):
			continue
		var enemy := n as Enemy
		if enemy == null:
			continue
		var dx: float = enemy.global_position.x - origin.x
		var dz: float = enemy.global_position.z - origin.z
		if dx * dx + dz * dz > radius_sq:
			continue
		enemy.apply_freeze(hit_freeze_duration, 0.0)
		hits += 1
	if LogConfig.master_enabled:
		print("[FrostBolt] hit-freeze: %d врагов заморожены на %.1fс" % [hits, hit_freeze_duration])


func _spawn_frost_patch(origin: Vector3) -> void:
	var fx_root: Node = get_parent()
	if fx_root == null:
		return
	var patch := frost_patch_scene.instantiate() as FrostPatch
	if patch == null:
		push_error("[FrostBolt] frost_patch_scene не инстанцируется как FrostPatch")
		return
	fx_root.add_child(patch)
	patch.global_position = origin
	patch.setup(patch_radius, patch_slow_factor, patch_duration, 0.25, 0.6, patch_grow_duration)
	if LogConfig.master_enabled:
		print("[FrostBolt:patch] spawn @ (%.1f,%.1f,%.1f) radius=%.1fм duration=%.1fс" % [
			origin.x, origin.y, origin.z, patch_radius, patch_duration,
		])
