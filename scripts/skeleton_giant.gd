class_name SkeletonGiant
extends Skeleton
## Скелет-гигант — танк, прицеленный на Tower. ~5-8× hp обычного скелета,
## медленный, крупный mesh, большой AoE-strike. Игнорирует палатки/гномов
## пока башня жива — идёт строго к ней. Спавнится WaveDirector'ом каждые N
## волн (см. WaveDirector.giant_every_n_waves) как «боссовая» угроза, дающая
## волне фокусную точку напряжения.
##
## Архитектура: extends Skeleton, не Enemy. Гиганту нужна вся melee-логика
## базового скелета (lunge, AoE-strike, pose-tween, boids, target-load),
## изменяются только параметры (hp/speed/damage/range) через @export defaults
## в скрипте + override scene'ы; override `_scan_target` (Tower имеет приоритет)
## и виртуала `_target_still_valid` (разрешаем Tower в кэше — она не в
## TARGET_GROUP, base иначе сбрасывала бы кэш каждый тик и рандомизировала
## `_approach_angle`, заставляя гиганта вертеться вокруг башни на месте).

const GIANT_GROUP := &"skeleton_giant"

## Радиус рассеивания тумана вокруг гиганта. Дизайнерское решение 2026-05-19:
## гигант — это видимая, наводящая страх угроза, его надо видеть издалека.
## Стандартные скелеты прячутся в туман, гигант — выжигает его собой и
## всегда виден: туман теперь чисто визуальный (врагов не скрывает), а гигант
## ещё и выжигает дымку вокруг себя fog-stamp'ом — силуэт читается издалека.
## Радиус 9м чуть больше радиуса коллизии (1.5м) — пятно вокруг него видно
## издалека как «он рядом, готовься».
var fog_reveal_radius: float = 9.0

## Shared material для всех гигантов — переключает body на тёмный/багряный
## оттенок (отличие от обычного скелетного beige). Static, чтобы один draw-call
## на всех гигантов на сцене.
static var _shared_giant_material: StandardMaterial3D

## Отладочный таймер-лог: раз в DEBUG_LOG_INTERVAL секунд пишет полный snapshot
## (state/cached_target/lod/dist/velocity/position). Цель — увидеть в логе,
## почему гигант не двигается: нет ли цели, скипает ли AI-tick по LOD, в каком
## он FSM-состоянии, и не нулевая ли velocity. Чтобы выключить — поставить
## debug_giant_log=false в инспекторе сцены или master_enabled=false в LogConfig.
@export var debug_giant_log: bool = true
const DEBUG_LOG_INTERVAL: float = 0.5
var _debug_log_timer: float = 0.0


func _ready() -> void:
	super._ready()
	add_to_group(GIANT_GROUP)
	# FOG_REVEAL_GROUP: гигант рассеивает туман собой (см. fog_reveal_radius
	# выше). Двойной эффект: (1) игрок видит силуэт гиганта в тумане
	# издалека, (2) дымка вокруг него разрежена собственным stamp'ом.
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)
	# Override material — super._ready() переключил mesh на shared skeleton material.
	# Для гиганта используем свой shared, отличающийся цветом/эмиссией.
	_ensure_giant_material()
	if _mesh:
		_mesh.material_override = _shared_giant_material
	if debug_giant_log and LogConfig.master_enabled:
		var tower: Node = get_tree().get_first_node_in_group(Tower.GROUP)
		var t_valid := tower != null and is_instance_valid(tower)
		var t_dmg := t_valid and Damageable.is_damageable(tower)
		var p := global_position
		print("[SkeletonGiant:%d] SPAWN @ (%.1f, %.1f, %.1f) tower=%s valid=%s damageable=%s" % [
			get_instance_id(), p.x, p.y, p.z,
			tower.name if t_valid else "null", t_valid, t_dmg,
		])


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if not debug_giant_log or not LogConfig.master_enabled:
		return
	_debug_log_timer -= delta
	if _debug_log_timer > 0.0:
		return
	_debug_log_timer = DEBUG_LOG_INTERVAL
	var state_name: String = ["APPROACH", "WINDUP", "STRIKE", "COOLDOWN"][_state]
	var lod_name: String = ["NEAR", "MID", "FAR"][_lod_level]
	var ct := _cached_target
	var ct_name: String = "null"
	var ct_dist: float = -1.0
	var ct_pos := Vector3.ZERO
	if ct != null and is_instance_valid(ct):
		ct_name = ct.name
		ct_pos = ct.global_position
		ct_dist = (ct_pos - global_position).length()
	var v_h := Vector2(velocity.x, velocity.z).length()
	var p := global_position
	var nav_finished: String = "n/a"
	if _nav_agent != null:
		nav_finished = str(_nav_agent.is_navigation_finished())
	print(("[SkeletonGiant:%d] state=%s lod=%s vel_h=%.2f pos=(%.1f,%.1f) "
		+ "tgt=%s dist=%.1f tgt_pos=(%.1f,%.1f) path_around=%s nav_fin=%s "
		+ "kb=%s") % [
		get_instance_id(), state_name, lod_name, v_h, p.x, p.z,
		ct_name, ct_dist, ct_pos.x, ct_pos.z, _should_path_around, nav_finished,
		_knockback.is_active(),
	])


static func _ensure_giant_material() -> void:
	if _shared_giant_material == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.42, 0.38, 0.32, 1.0)
		m.roughness = 0.85
		m.emission_enabled = true
		m.emission = Color(0.9, 0.25, 0.18, 1.0)
		m.emission_energy_multiplier = 0.4
		_shared_giant_material = m


## Tower имеет абсолютный приоритет. Если её нет или она мертва — fallback
## на обычный skeleton-scan (палатки/гномы).
func _scan_target() -> Node3D:
	var tower: Node = get_tree().get_first_node_in_group(Tower.GROUP)
	if tower != null and is_instance_valid(tower) and _target_still_valid(tower as Node3D):
		return tower as Node3D
	return super._scan_target()


## Override Skeleton._target_still_valid: Tower не в TARGET_GROUP, но для
## гиганта это валидная цель пока башня damageable. Когда Tower умирает,
## она снимает себя с Damageable.GROUP (см. tower.gd:116) — фильтр
## автоматически отшибает мёртвую башню, и stale-check в _physics_process
## пересканит на палатки/гномов.
func _target_still_valid(target: Node3D) -> bool:
	if target.is_in_group(TARGET_GROUP):
		return true
	return target.is_in_group(Tower.GROUP) and Damageable.is_damageable(target)


## Override Skeleton._recompute_path_decision: гигант никогда не обходит
## препятствия — он танк, ломает что встретит. Дополнительно фикс stuck'а
## у Tower: башня в группе `navmesh_source` → навмеш выгрызает hole вокруг
## неё, ring-point на 2.21м от Tower попадает в дыру меша, nav-agent
## строит путь до edge'а меша и встаёт там (~4-5м от Tower, вне attack_range).
## Прямой путь обходит проблему.
func _recompute_path_decision() -> void:
	_should_path_around = false


## Танк-семантика knockback резистанса теперь живёт на Enemy.knockback_resistance
## (@export), значение 0.2 выставлено в skeleton_giant.tscn. Без override —
## база сама умножает impulse×resistance в apply_knockback.


## Override base _perform_strike: добавляет Tower в AoE-область удара. Базовый
## метод итерирует только TARGET_GROUP (палатки/гномы), Tower там нет —
## без этого гигант махал бы рядом с башней без эффекта.
func _perform_strike(target: Node3D) -> void:
	# Дополнительный удар по Tower'ам в радиусе. Использовать тот же STRIKE_RADIUS_FACTOR
	# как в Skeleton._perform_strike (через attack_range * 1.3).
	var strike_radius: float = attack_range * STRIKE_RADIUS_FACTOR
	for t in get_tree().get_nodes_in_group(Tower.GROUP):
		if not is_instance_valid(t):
			continue
		var node := t as Node3D
		if node == null:
			continue
		var d_sq: float = (node.global_position - global_position).length_squared()
		# Крупная цель шире — её центр дальше strike-радиуса, хотя гигант вплотную
		# к коллизии. Расширяем на reach-бонус, как базовый _perform_strike (иначе
		# гигант мог бы махать у крупной башни мимо центра). Симметрично Skeleton.
		var eff: float = strike_radius + target_reach_bonus(node)
		if d_sq <= eff * eff:
			Damageable.try_damage(node, attack_damage)
	# Передаём управление базе — обработка палаток/гномов в AoE + self-lunge.
	super._perform_strike(target)
