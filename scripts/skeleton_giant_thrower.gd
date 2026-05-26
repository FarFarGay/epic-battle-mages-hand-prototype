class_name SkeletonGiantThrower
extends SkeletonArcher
## Гигант-каменщик — ranged-танк. Кидает тяжёлые камни в Tower с дистанции.
## Аналог melee-гиганта ([SkeletonGiant]), но дальний боец: стоит на 25-35м
## от башни, медленно замахивается, бросает камень. Игнорирует палатки/гномов
## пока Tower жива — фокус-цель.
##
## Архитектура: extends SkeletonArcher (kite-логика, FSM, баллистический
## проджектайл через [Arrow.setup]). Override:
## - `_resolve_target` — Tower имеет приоритет над любым другим target'ом;
##   base'овый archer фильтрует forced_target через TARGET_GROUP, Tower там
##   нет — это место и фиксим.
## - `apply_knockback` — резистанс ×0.2 (как у [SkeletonGiant]). Танк не
##   сбивается со штриха стрелами защитников / slam'ом игрока.
## - Материал — болотно-зелёный с emission, отличает от багряного melee-гиганта
##   и фиолетового обычного archer'а.
##
## Camera: тот же GIANT_GROUP что и у melee-гиганта — карточка чита/HUD'ов
## считает обоих «гигантами» в одной группе. FOG_REVEAL_GROUP — рассеивает
## туман собой (как melee-гигант), игрок видит угрозу издалека.

const GIANT_GROUP := &"skeleton_giant"

## Радиус рассеивания тумана вокруг каменщика. 9м — чуть больше радиуса
## коллизии (0.75м), пятно вокруг него видно издалека как «он рядом».
var fog_reveal_radius: float = 9.0

## Shared material для всех каменщиков-гигантов — один draw-call на всех
## thrower'ов на сцене. Болотно-зелёный, чтобы отличать от багряного
## SkeletonGiant и фиолетового SkeletonArcher.
static var _shared_thrower_material: StandardMaterial3D


## Активный pose-tween scale-punch'а на damage. Kill'ается при следующем
## punch'е, чтобы они не накладывались, и mesh не «застрял» в раздутом масштабе.
var _hit_punch_tween: Tween = null


func _ready() -> void:
	super._ready()
	add_to_group(GIANT_GROUP)
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)
	_ensure_thrower_material()
	if _mesh:
		_mesh.material_override = _shared_thrower_material
	# Visual feedback на damage. Enemy/SkeletonArcher только emit'ит damaged
	# в EventBus — без визуала игроку кажется что урон не приходит, хотя hp
	# падает. Добавляем hit-flash (per-target дешёвый duplicate материала на
	# 0.08с) + scale-punch (squash, как у Skeleton). На WINDUP punch скипаем —
	# иначе perturbит «coiled-поза замаха» нет смысла, у нас pose-tween'ов
	# нет, но дальше может появиться.
	damaged.connect(_on_self_damaged)


func _on_self_damaged(_amount: float) -> void:
	if _mesh == null or not is_instance_valid(_mesh):
		return
	HitFlash.flash(_mesh)
	if _hit_punch_tween != null and _hit_punch_tween.is_valid():
		_hit_punch_tween.kill()
	_hit_punch_tween = create_tween()
	_hit_punch_tween.set_trans(Tween.TRANS_QUAD)
	_hit_punch_tween.tween_property(_mesh, "scale", Vector3.ONE * 1.18, 0.06).set_ease(Tween.EASE_OUT)
	_hit_punch_tween.tween_property(_mesh, "scale", Vector3.ONE, 0.14).set_ease(Tween.EASE_IN)
	if debug_log and LogConfig.master_enabled:
		print("[GiantThrower:%s] DAMAGED -%.1f → hp=%.1f" % [name, _amount, hp])


static func _ensure_thrower_material() -> void:
	if _shared_thrower_material == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.32, 0.42, 0.28, 1.0)
		m.roughness = 0.85
		m.emission_enabled = true
		m.emission = Color(0.4, 0.65, 0.25, 1.0)
		m.emission_energy_multiplier = 0.4
		_shared_thrower_material = m


## Override SkeletonArcher._resolve_target: Tower имеет абсолютный приоритет
## пока damageable. base archer фильтрует _forced_target через TARGET_GROUP,
## Tower там нет — без этого override'а каменщик stalk'ал бы ближайшую
## палатку вместо башни. После смерти Tower (снимает себя с Damageable.GROUP)
## — fallback на super (cached scan / forced / base get_active_target).
func _resolve_target() -> Node3D:
	var tower: Node = get_tree().get_first_node_in_group(Tower.GROUP)
	if tower != null and is_instance_valid(tower) and Damageable.is_damageable(tower):
		return tower as Node3D
	return super._resolve_target()


## Танк-семантика knockback резистанса теперь на Enemy.knockback_resistance
## (@export), значение 0.2 в skeleton_giant_thrower.tscn. Без override.


## Сцена снаряда-камня ([GiantStone]). Переопределяем стрелу archer'а
## другим типом снаряда — AOE-камень с волной импакта вместо AoeArrow.
## Если null — `_perform_strike` no-op'ит с push_warning.
##
## telegraph_radius/color/_telegraphed_aim/_on_state_enter теперь в [SkeletonArcher]
## базе — Thrower тюнит параметры через .tscn (telegraph_radius=4.0,
## telegraph_color = красно-оранжевый).
@export var stone_scene: PackedScene = null


## Override SkeletonArcher._perform_strike: вместо single-target стрелы
## кидаем GiantStone (AOE-камень с волной от impact'а). Параметры baseline'а
## archer'а (arrow_damage_min/max, arrow_speed, arrow_spawn_offset) переиспользуем
## под камень — это те же роли, просто другой снаряд. arrow_scene игнорируем,
## используем stone_scene.
##
## EventBus.skeleton_attacked_camp emit'им как обычный archer — defender'ы
## слышат «бросок» и реагируют (так же, как на тетиву обычного archer'а).
func _perform_strike(target: Node3D) -> void:
	if not is_instance_valid(target):
		_telegraphed_aim = Vector3.INF
		return
	if stone_scene == null:
		push_warning("SkeletonGiantThrower: stone_scene не задан")
		_telegraphed_aim = Vector3.INF
		return
	var stone := stone_scene.instantiate() as GiantStone
	if stone == null:
		push_warning("SkeletonGiantThrower: stone_scene не инстанцируется как GiantStone")
		_telegraphed_aim = Vector3.INF
		return
	if not is_instance_valid(_projectiles_root):
		_projectiles_root = get_tree().current_scene
	_projectiles_root.add_child(stone)
	stone.damage = randf_range(arrow_damage_min, arrow_damage_max)
	stone.speed = arrow_speed
	var spawn: Vector3 = global_position + arrow_spawn_offset
	# Если телеграф зафиксировал aim в WINDUP — используем его. Fallback на
	# текущую позицию цели (например, WINDUP пропустили knockback'ом и
	# _on_state_enter не отработал).
	var aim: Vector3
	if _telegraphed_aim != Vector3.INF:
		aim = _telegraphed_aim
	else:
		aim = target.global_position
		aim.y = 0.0  # fallback: тот же ground-level что и в _enter_windup
	_telegraphed_aim = Vector3.INF
	stone.debug_log = debug_log
	stone.setup(spawn, aim)
	if not target.is_in_group(DefenderGnome.DEFENDER_GROUP):
		EventBus.skeleton_attacked_camp.emit(self, target, target.global_position)
	if debug_log and LogConfig.master_enabled:
		var d: float = global_position.distance_to(aim)
		print("[GiantThrower:%s] STRIKE: камень spawn=(%.1f,%.1f,%.1f) → aim=(%.1f,%.1f,%.1f) dist=%.1fм dmg=%.1f speed=%.1f" % [
			name, spawn.x, spawn.y, spawn.z, aim.x, aim.y, aim.z, d, stone.damage, stone.speed,
		])
