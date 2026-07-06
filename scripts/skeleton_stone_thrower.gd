class_name SkeletonStoneThrower
extends SkeletonGiantThrower
## Скелет-камнеметатель — ranged-«бомбардир» размером с гиганта. В отличие от
## [SkeletonGiantThrower] (один тяжёлый камень) кидает РОССЫПЬ из ~30 мелких
## камней по дуге в зону башни: каждый камень падает в свою точку, каждая точка
## заранее отмечена на земле кольцом-маркером. Камни сыплются «росчерком» —
## стаггер по времени даёт эффект проходящего по площади залпа, а не мгновенной
## кучи. Уворачивается от магии игрока, но ХУЖЕ гиганта (короткий редкий рывок —
## по нему реально попасть). HP как у melee-гиганта. При гибели — мощный взрыв,
## бьющий башню и всё вокруг: его выгодно убивать ИЗДАЛЕКА.
##
## Архитектура: extends SkeletonGiantThrower ради готового Tower-приоритета
## (`_resolve_target`), GIANT_GROUP/FOG_REVEAL, knockback-резиста (.tscn) и
## shatter'а на смерти ([SkeletonArcher._on_destroyed]). Переиспользуем тот же
## снаряд [GiantStone] (stone_scene), но per-instance ужимаем его в «мелкий
## камень» (aoe/damage/visual). Телеграф-зону WINDUP'а наследуем как есть
## (один путь): broad-кольцо = вся опасная зона, точечные маркеры = места
## падения каждого камня. Override только: `_perform_strike` (залп вместо
## одного камня), `_ai_step` (рывок-уворот сверху), `_on_destroyed` (взрыв),
## material.

@export_group("Залп (россыпь мелких камней)")
## Сколько мелких камней в одном залпе.
@export var volley_count: int = 30
## Радиус разброса точек падения вокруг центра прицела (диск). Совпадает с
## telegraph_radius в .tscn — broad-кольцо WINDUP'а показывает ровно эту зону.
@export var volley_scatter_radius: float = 7.0
## За сколько секунд высыпается весь росчерк. Стаггер между камнями =
## volley_sweep_time / volley_count. 0 → все камни в один кадр.
@export var volley_sweep_time: float = 1.1
## AOE-радиус ОДНОГО мелкого камня (маленький — это «дробь», не валун гиганта).
@export var rock_aoe_radius: float = 1.6
@export var rock_damage_min: float = 5.0
@export var rock_damage_max: float = 9.0
## Визуальный масштаб mesh'а камня (giant_stone.tscn — сфера r=0.4; ×rock_scale).
@export var rock_scale: float = 0.6
## Гравитация камня — выше дефолтной, дуга круче (читается «сейчас упадёт»).
@export var rock_gravity: float = 14.0
## Цвет точечного кольца-маркера места падения камня.
@export var rock_marker_color: Color = Color(1.0, 0.5, 0.15, 0.85)

@export_group("Динамика (подход на позицию)")
## Доля move_speed на боковое (касательное) движение — обход цели. 0.4 —
## СПОКОЙНЫЙ шаг на позицию (фидбек 2026-07-07 «нечитаемый суетливый танец»:
## было 0.8 — вечно кружил, бой не читался).
@export var strafe_speed_factor: float = 0.4
## На сколько метров можно не дойти до выбранной дистанции, чтобы уже стрелять.
## Без допуска метатель доводил бы радиус идеально и «залипал».
@export var range_tolerance: float = 2.5
## Каждый цикл выбирает НОВУЮ дистанцию выстрела в [attack_radius_min,
## attack_radius_max] — поэтому не «подбирает одно расстояние». reposition_jitter
## — доп. случайный сдвиг формейшн-точки в метрах (диск), чтобы и угол менялся.
@export var reposition_jitter: float = 2.5

@export_group("Перезарядка (окно наказания)")
## После залпа метатель ПЕРЕЗАРЯЖАЕТСЯ: стоит на месте, ОСТЫВАЕТ (эмиссия
## гаснет — «разряжен») и НЕ уворачивается — окно возмездия, единый язык со
## станом гиганта («потух/посинел = бей сейчас»). 0 = выключено.
@export var reload_time: float = 4.0

@export_group("Уворот (хуже гиганта)")
## Радиус замечания player_projectile. Меньше гигантского (8) — реагирует поздно.
@export var dodge_detect_radius: float = 6.0
## Кулдаун уворота — длиннее гигантского (0.7): часто рывок ещё «не готов».
@export var dodge_cooldown: float = 1.6
## Скорость/длительность рывка. 9×0.16≈1.4м — короче гигантского (≈2.9м):
## single-target Искра нередко всё равно цепляет, AoE перекрывает гарантированно.
@export var dodge_dash_speed: float = 9.0
@export var dodge_dash_duration: float = 0.16

@export_group("Взрыв на смерти")
## Радиус смертельного взрыва. Большой — «убивай издалека».
@export var death_explosion_radius: float = 7.0
## Урон взрыва (единый по зоне). Сильный — выкос башни/гномов рядом.
@export var death_explosion_damage: float = 130.0
@export var death_explosion_knockback: float = 8.0
@export var death_explosion_shake: float = 0.7

## Shared material — пыльно-серый с горячей красно-оранжевой эмиссией: читается
## как «начинён камнями и вот-вот рванёт». Отличает от серо-каменного thrower'а.
static var _shared_stone_thrower_material: StandardMaterial3D
## Термо-сигналинг состояния (фидбек 2026-07-07 «нечитаемый»): WINDUP —
## РАСКАЛЁН (яркая эмиссия, «сейчас жахнет»); перезарядка — ПОТУХ (эмиссии нет,
## «разряжен, бей»); базовый — тлеет. Все shared (один draw-call на всех).
static var _shared_hot_material: StandardMaterial3D
static var _shared_dim_material: StandardMaterial3D

## Общий dash-механизм уворота: вектор скорости + остаток фазы + кулдаун.
var _dash_vec: Vector3 = Vector3.ZERO
var _dash_remaining: float = 0.0
var _dodge_cd: float = 0.0
## Остаток перезарядки после залпа: >0 → стоит потухший, не уворачивается.
var _reload_t: float = 0.0

## Выбранная на текущий цикл дистанция выстрела и сторона обхода (+1/-1).
## Пересчитываются при каждом входе в APPROACH (после выстрела) → метатель
## каждый раз встаёт на НОВЫЙ радиус и кружит в новую сторону.
var _desired_range: float = 0.0
var _strafe_sign: float = 1.0


func _ready() -> void:
	super._ready()
	_ensure_stone_thrower_material()
	if _mesh:
		_mesh.material_override = _shared_stone_thrower_material
	_pick_new_approach()


## Новая цель-дистанция выстрела + сторона обхода + сдвиг формейшн-точки.
## Зовётся на входе в APPROACH (каждый цикл) и в _ready (первый подход).
func _pick_new_approach() -> void:
	_desired_range = randf_range(attack_radius_min, attack_radius_max)
	_strafe_sign = 1.0 if randf() < 0.5 else -1.0
	# Сдвиг формейшн-точки в диске — меняет и угол подхода, не только радиус.
	if reposition_jitter > 0.0:
		var ang: float = randf() * TAU
		var r: float = sqrt(randf()) * reposition_jitter
		formation_offset = Vector3(cos(ang) * r, 0.0, sin(ang) * r)


## Override SkeletonArcher._on_state_enter: при входе в APPROACH берём новую
## дистанцию/сторону (super сохраняет windup-телеграф). Плюс термо-сигналинг:
## WINDUP раскаляет корпус («сейчас жахнет»), возврат в APPROACH тушит до тления
## (если не идёт перезарядка — та владеет материалом сама).
func _on_state_enter(new_state: int) -> void:
	super._on_state_enter(new_state)
	if new_state == AttackState.APPROACH:
		_pick_new_approach()
	if _mesh == null:
		return
	if new_state == AttackState.WINDUP:
		_ensure_thermo_materials()
		_mesh.material_override = _shared_hot_material
	elif new_state == AttackState.APPROACH and _reload_t <= 0.0:
		_mesh.material_override = _shared_stone_thrower_material


## Override SkeletonArcher._kite_to_range: вместо «дойти до полосы [min,max] и
## замереть» — подходим ДУГОЙ к выбранной _desired_range (радиаль к ошибке +
## касательный обход), и стреляем как только оказались в range_tolerance от неё.
## Так дистанция выстрела каждый раз разная, а путь — кружащий, не прямой.
func _kite_to_range(target: Node3D) -> void:
	var target_pos: Vector3 = target.global_position + formation_offset
	var to_target: Vector3 = target_pos - global_position
	to_target.y = 0.0
	var dist: float = to_target.length()
	if dist < 0.05:
		velocity.x = 0.0
		velocity.z = 0.0
		_enter_state(AttackState.WINDUP)
		return
	var radial: Vector3 = to_target / dist                       # ед. вектор к цели
	var tangential := Vector3(radial.z, 0.0, -radial.x) * _strafe_sign  # обход
	var err: float = dist - _desired_range
	if absf(err) <= range_tolerance:
		# На выбранном радиусе — стреляем (WINDUP остановит и зафиксирует прицел).
		velocity.x = 0.0
		velocity.z = 0.0
		_enter_state(AttackState.WINDUP)
		return
	# Иначе идём дугой: радиаль в сторону нужного радиуса + касательный обход.
	var radial_move: Vector3 = radial * signf(err)               # err>0 далеко→к цели
	var dir: Vector3 = radial_move + tangential * strafe_speed_factor
	if dir.length_squared() < 0.0001:
		dir = tangential
	dir = dir.normalized()
	var spd: float = move_speed if err > 0.0 else move_speed * retreat_speed_factor
	velocity.x = dir.x * spd
	velocity.z = dir.z * spd


static func _ensure_stone_thrower_material() -> void:
	if _shared_stone_thrower_material == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.5, 0.46, 0.42, 1.0)
		m.roughness = 0.9
		m.emission_enabled = true
		m.emission = Color(1.0, 0.4, 0.12, 1.0)
		m.emission_energy_multiplier = 0.7
		_shared_stone_thrower_material = m


static func _ensure_thermo_materials() -> void:
	if _shared_hot_material == null:
		var hot := StandardMaterial3D.new()
		hot.albedo_color = Color(0.55, 0.44, 0.38, 1.0)
		hot.roughness = 0.85
		hot.emission_enabled = true
		hot.emission = Color(1.0, 0.35, 0.05, 1.0)
		hot.emission_energy_multiplier = 3.0
		_shared_hot_material = hot
		var dim := StandardMaterial3D.new()
		dim.albedo_color = Color(0.42, 0.41, 0.4, 1.0)
		dim.roughness = 0.95
		_shared_dim_material = dim


## Override SkeletonGiantThrower._perform_strike: вместо одного валуна —
## РОССЫПЬ из volley_count мелких камней по диску volley_scatter_radius вокруг
## зафиксированной телеграфом точки. Сам высев — корутина `_spawn_volley`
## (fire-and-forget): стаггерит спавн по volley_sweep_time, чтобы камни сыпались
## росчерком. _telegraphed_aim здесь — центр зоны (его же показало broad-кольцо
## WINDUP'а); если телеграфа не было (knockback сбил WINDUP) — берём точку цели.
func _perform_strike(target: Node3D) -> void:
	if not is_instance_valid(target):
		_telegraphed_aim = Vector3.INF
		return
	if stone_scene == null:
		push_warning("SkeletonStoneThrower: stone_scene не задан")
		_telegraphed_aim = Vector3.INF
		return
	var center: Vector3
	if _telegraphed_aim != Vector3.INF:
		center = _telegraphed_aim
	else:
		center = Vector3(target.global_position.x, 0.0, target.global_position.z)
	_telegraphed_aim = Vector3.INF
	# Alarm-сигнал атаки лагеря — как у базового archer'а/thrower'а (один на залп).
	if not target.is_in_group(SoldierGnome.SOLDIER_GROUP):
		EventBus.skeleton_attacked_camp.emit(self, target, center)
	if debug_log and LogConfig.master_enabled:
		print("[StoneThrower:%s] ЗАЛП %d камней в зону (%.1f,%.1f) r=%.1f" % [
			name, volley_count, center.x, center.z, volley_scatter_radius,
		])
	_spawn_volley(center)
	_begin_reload()


## Перезарядка после залпа: корпус тухнет, метатель встаёт столбом — окно
## возмездия. Тикается в _ai_step (velocity 0, уворот выключен).
func _begin_reload() -> void:
	if reload_time <= 0.0:
		return
	_reload_t = reload_time
	_ensure_thermo_materials()
	if _mesh:
		_mesh.material_override = _shared_dim_material


## Корутина залпа: высевает volley_count камней со стаггером. Гард
## is_instance_valid(self) после каждого await — метатель мог погибнуть посреди
## росчерка (await резюмится на freed-инстансе, дальше доступ к полям упал бы).
func _spawn_volley(center: Vector3) -> void:
	var stagger: float = volley_sweep_time / float(maxi(volley_count, 1))
	for i in volley_count:
		if not is_instance_valid(self):
			return
		_spawn_one_rock(center)
		if stagger > 0.0:
			await get_tree().create_timer(stagger).timeout


## Один мелкий камень: ужатый per-instance [GiantStone] + точечный кольцо-маркер
## в точке падения. Точка — равномерно в диске volley_scatter_radius (sqrt(rand)
## — без сгущения к центру). Маркер живёт примерно столько, сколько камень летит.
func _spawn_one_rock(center: Vector3) -> void:
	var stone := stone_scene.instantiate() as GiantStone
	if stone == null:
		return
	if not is_instance_valid(_projectiles_root):
		_projectiles_root = get_tree().current_scene
	_projectiles_root.add_child(stone)
	stone.set_shooter(self)
	stone.damage = randf_range(rock_damage_min, rock_damage_max)
	stone.aoe_radius = rock_aoe_radius
	# Камни бьют и по обычным скелетам: к дефолтной маске (башня/гномы/палисад)
	# добавляем ENEMIES. Per-instance — общий giant_stone.tscn не трогаем, чтобы
	# не менять одиночного гиганта-каменщика.
	stone.aoe_mask = (Layers.MASK_HOSTILE_PROJECTILE & ~Layers.TERRAIN) | Layers.ENEMIES
	stone.gravity = rock_gravity
	stone.shake_amount = 0.0  # 30 шейков забили бы экран; трясёт только взрыв на смерти
	stone.debug_log = false
	var mesh := stone.get_node_or_null("MeshInstance3D") as Node3D
	if mesh != null:
		mesh.scale = Vector3.ONE * rock_scale  # на root нельзя: look_at снаряда стирает scale
	var ang: float = randf() * TAU
	var r: float = sqrt(randf()) * volley_scatter_radius
	var aim := Vector3(center.x + cos(ang) * r, 0.0, center.z + sin(ang) * r)
	var spawn: Vector3 = global_position + arrow_spawn_offset
	# Гарантия долёта: на оптим. дуге дальность = speed²/gravity, поэтому скорость
	# не ниже sqrt(gravity·d) с запасом. Иначе дальняя кромка россыпи (range+jitter+
	# scatter до ~45м) при фикс. arrow_speed=24 падала раньше цели — BallisticUtil
	# уходил в прямой выстрел (недолёт). Один путь: скорость растёт с дистанцией.
	var d: float = spawn.distance_to(aim)
	stone.speed = maxf(arrow_speed, sqrt(rock_gravity * d) * 1.06)
	stone.setup(spawn, aim)
	var root: Node = get_tree().current_scene
	if is_instance_valid(root):
		var flight: float = maxf(0.45, spawn.distance_to(aim) / maxf(stone.speed, 1.0) * 1.3)
		AoeVisual.spawn_ground_ring(root, aim, rock_aoe_radius, flight, rock_marker_color)


## Override SkeletonArcher._ai_step: сверху — перезарядка (стоит потухший, окно
## наказания) и короткий рывок-уворот от снарядов игрока, иначе обычная
## ranged-логика (kite → windup → залп). Рывок «хуже гиганта»: см. dodge_*.
func _ai_step(delta: float) -> void:
	# Перезарядка: столбом, без уворота — ритм «нагрелся → залп → остыл».
	if _reload_t > 0.0:
		_reload_t -= delta
		velocity.x = 0.0
		velocity.z = 0.0
		if _reload_t <= 0.0 and _mesh:
			_mesh.material_override = _shared_stone_thrower_material
		return
	if _dash_remaining > 0.0:
		_dash_remaining -= delta
		velocity.x = _dash_vec.x
		velocity.z = _dash_vec.z
		return
	_dodge_cd -= delta
	if _dodge_cd <= 0.0 and dodge_detect_radius > 0.0:
		var threat := _scan_threat()
		if threat != null:
			_start_evade(threat.global_position)
			_dodge_cd = dodge_cooldown
			return
	super._ai_step(delta)


## Ближайший player_projectile в dodge_detect_radius (порт из SkeletonGiant).
func _scan_threat() -> Node3D:
	var here: Vector3 = global_position
	var best: Node3D = null
	var best_d_sq: float = dodge_detect_radius * dodge_detect_radius
	for n in get_tree().get_nodes_in_group(&"player_projectile"):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var dx: float = node.global_position.x - here.x
		var dz: float = node.global_position.z - here.z
		var d_sq: float = dx * dx + dz * dz
		if d_sq < best_d_sq:
			best_d_sq = d_sq
			best = node
	return best


## Рывок-уворот вбок от снаряда (порт из SkeletonGiant, без «не под башню» —
## метатель стоит далеко, направление вбок безопасно).
func _start_evade(threat_pos: Vector3) -> void:
	var away: Vector3 = global_position - threat_pos
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
	away = away.normalized()
	var perp: Vector3 = away.cross(Vector3.UP).normalized()
	var dir: Vector3 = perp * 0.8 + away * 0.4
	if dir.length_squared() < 0.0001:
		dir = perp
	dir = dir.normalized()
	_dash_vec = dir * dodge_dash_speed
	_dash_remaining = dodge_dash_duration


## Override: смерть = shatter (super) + МОЩНЫЙ взрыв по башне и всему вокруг.
## Взрыв — единый AOE-урон в радиусе (маска как у GiantStone: башня, гномы,
## палисад; терраин исключён). Поэтому метателя выгодно убивать издалека.
func _on_destroyed() -> void:
	super._on_destroyed()
	# Отметить победу над камнеметателем — гномы-строители (Room6) откроют найм
	# лучников (см. их диалог, req thrower_defeated).
	var profile := get_tree().get_first_node_in_group(&"player_profile")
	if profile != null and profile.has_method(&"mark_stone_thrower_defeated"):
		profile.call(&"mark_stone_thrower_defeated")
	var pos: Vector3 = global_position
	var root: Node = _effects_root if is_instance_valid(_effects_root) else get_tree().current_scene
	if is_instance_valid(root):
		AoeVisual.spawn_explosion(root, pos, death_explosion_radius)
		AoeVisual.spawn_expanding_ring(root, pos, death_explosion_radius * 1.15, 0.5,
			Color(1.0, 0.5, 0.2, 0.9), 0.25)
	if death_explosion_shake > 0.0:
		EventBus.camera_shake.emit(death_explosion_shake, pos)
	# Та же маска, что у камней залпа: башня/гномы/палисад + ENEMIES — взрыв
	# косит и обычных скелетов рядом (симметрично атаке метателя).
	AoeDamage.apply_uniform(get_tree(), pos, death_explosion_radius,
		(Layers.MASK_HOSTILE_PROJECTILE & ~Layers.TERRAIN) | Layers.ENEMIES,
		death_explosion_damage, death_explosion_knockback, 0.3)
