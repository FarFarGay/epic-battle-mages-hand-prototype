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
## другим типом снаряда — AOE-камень с волной импакта вместо single-target
## стрелы. Если null — `_perform_strike` no-op'ит с push_warning.
@export var stone_scene: PackedScene = null
## Радиус AOE-зоны импакта камня. Должен совпадать с aoe_radius в самой
## GiantStone-сцене — иначе telegraph ring (этот radius) и реальный взрыв
## разойдутся, что обманет игрока. Дублируется здесь, чтобы дизайнер мог
## крутить из инспектора thrower'а; sync со stone'ом — ответственность
## дизайнера.
@export var telegraph_radius: float = 4.0
## Цвет telegraph-кольца на земле. Красно-оранжевый — «опасность», читается
## как «сюда упадёт камень».
@export var telegraph_color: Color = Color(1.0, 0.3, 0.15, 0.9)

## Зафиксированная точка прицеливания на entering WINDUP. На STRIKE камень
## кидается ровно туда — иначе inaccuracy рандомизировался бы между
## телеграфом и выпуском, и кольцо обманывало бы. Vector3.INF = «не
## зафиксировано» (init / после strike). Не Node3D — целевая точка
## фиксирована во ВРЕМЕНИ (момент начала windup'а), не в пространстве:
## Tower может уехать WASD'ом за 1.2с windup'а, камень всё равно полетит
## в зафиксированную точку. Это и есть «телеграф» — игрок видит куда
## упадёт ДО выпуска, и может убрать Tower.
var _telegraphed_aim: Vector3 = Vector3.INF


## Override Enemy._on_state_enter: при entering WINDUP — фиксируем aim
## (target.global_position + inaccuracy offset) и спавним ground ring
## на земле под этой точкой. Игрок видит зону «сейчас сюда прилетит»
## за attack_windup секунд до выпуска камня. Ring auto-fade'ится за
## attack_windup (см. AoeVisual.spawn_ground_ring), к моменту STRIKE
## он уже погаснет — органичный «countdown».
##
## inaccuracy применяется ОДИН РАЗ в WINDUP (а не повторно в STRIKE
## как у обычного archer'а), потому что иначе real-impact ушёл бы от
## telegraph'а: дизайнерский антипаттерн «телеграф обманул».
func _on_state_enter(new_state: int) -> void:
	super._on_state_enter(new_state)
	if new_state == AttackState.WINDUP:
		_enter_windup()
	elif new_state == AttackState.STRIKE:
		if debug_log and LogConfig.master_enabled:
			print("[GiantThrower:%s] STRIKE → бросаю камень" % name)
	elif new_state == AttackState.COOLDOWN:
		if debug_log and LogConfig.master_enabled:
			print("[GiantThrower:%s] COOLDOWN" % name)


func _enter_windup() -> void:
	var target: Node3D = _resolve_target()
	if target == null:
		_telegraphed_aim = Vector3.INF
		if debug_log and LogConfig.master_enabled:
			print("[GiantThrower:%s] WINDUP без target → отмена" % name)
		return
	var aim: Vector3 = target.global_position
	if arrow_inaccuracy_radius > 0.0:
		var angle: float = randf() * TAU
		var r: float = sqrt(randf()) * arrow_inaccuracy_radius
		aim.x += cos(angle) * r
		aim.z += sin(angle) * r
	# Камень падает на ЗЕМЛЮ, не в центр Tower'а (y=3). AOE через sphere-query
	# накроет Tower'а сверху — её BoxShape 2×6×2 с центром на y=3, нижний край
	# на y=0, попадает в sphere radius=4 из landing point (0,0,Tower.xz).
	# Если aim.y оставить на Tower.y=3, импакт случится на высоте 3м над землёй,
	# взрыв ÷ туман-планы (1.5 / 3 / 4.5м) визуально перекроет — выглядит как
	# «врезался в туман». Семантика: «камень упал на ЗЕМЛЮ рядом с башней».
	aim.y = 0.0
	_telegraphed_aim = aim
	var root: Node = get_tree().current_scene
	if is_instance_valid(root):
		AoeVisual.spawn_ground_ring(root, aim, telegraph_radius, attack_windup, telegraph_color)
	if debug_log and LogConfig.master_enabled:
		var d: float = global_position.distance_to(aim)
		print("[GiantThrower:%s] WINDUP target=%s aim=(%.1f,%.1f) dist=%.1fм windup=%.1fс" % [
			name, target.name, aim.x, aim.z, d, attack_windup,
		])


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
