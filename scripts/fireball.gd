class_name Fireball
extends Node3D
## Снаряд-фаербол. Двухфазная траектория «ракета»:
##   1. **Boost** — короткий всплеск вверх + чуть вперёд, баллистика с
##      собственной gravity. Создаёт стартовую дугу из башни.
##   2. **Homing** — прямой полёт на target_pos с плавным набором скорости
##      (current_speed += acceleration × delta, кап на max_speed). Чем
##      ближе к цели, тем быстрее снаряд — эффект «ускоряется перед
##      попаданием».
##
## Не Area3D, не RigidBody — обычный Node3D, симуляция вручную в
## `_physics_process`. Это упрощает: не нужно настраивать collision_layer/
## mask для broad-phase коллизий со скелетами (нам нужен только AOE-shape-query
## в момент взрыва, а не контакт-driven detection).
##
## Параметры считает HandSpellFireball через setup() — здесь только
## симуляция и AOE.

const HIT_PROXIMITY_SQ: float = 0.36  # 0.6м² — взрываемся на подлёте к target
## Safety lifetime: если что-то пошло не так и снаряд не упал, он не
## останется в сцене навсегда.
const SAFETY_LIFETIME: float = 6.0

## Эмитится в _explode перед queue_free. Используется коллерами, которым
## нужно спавнить что-то на месте удара (например, HandSpellMineScatter
## ставит Mine'у в точке приземления). origin — позиция взрыва, radius —
## радиус AOE (для подсказки про зону действия).
signal hit(origin: Vector3, radius: float)

## Тип импакт-VFX. false (дефолт) — полный fire-explosion (spawn_explosion):
## ядро + огненные частицы + дым. true — серая пыль (spawn_dust) без огня.
## Mine Scatter использует true: мины врезаются в землю, не взрываются —
## визуально это «пуф пыли», не «бах огня».
@export var impact_uses_dust: bool = false

enum Phase { BOOST, HOMING }

var _target_pos: Vector3
var _velocity: Vector3
var _phase: int = Phase.BOOST
var _current_speed: float = 0.0  # для HOMING-фазы

# Boost-фаза
var _boost_duration: float
var _boost_gravity: float

# Homing-фаза
var _homing_initial_speed: float
var _homing_acceleration: float
var _homing_max_speed: float
## Угол начального drift'а в homing'е (radians). Velocity на старте
## homing-фазы поворачивается на этот угол вокруг UP относительно
## desired-direction, затем slerp'ом возвращается к цели через
## _homing_turn_rate. Создаёт характерный «крюк» в полёте.
var _homing_drift_angle: float = 0.0
## Скорость возврата к target-direction (exp-decay rate). 5.0 — за ~0.5с
## velocity почти совпадает с desired. Меньше — длиннее drift.
var _homing_turn_rate: float = 5.0

# AOE / damage
var _damage: float
var _radius: float
var _explode_mask: int
var _knockback_force: float
var _knockback_lift: float
var _knockback_duration: float
var _exploded: bool = false
var _age: float = 0.0

# Параметры остаточного горения. Передаются HandSpellFireball'ом через
# setup_burn — отдельным сеттером, чтобы основной setup() не разрастался
# до 14 параметров. Если scene == null — burn не спавнится.
var _burn_patch_scene: PackedScene = null
var _burn_radius: float = 1.5
var _burn_damage_per_tick: float = 8.0
var _burn_tick_interval: float = 0.5
var _burn_duration: float = 3.0

# Максимальный радиус fog-pulse на импакте. Дефолт = _radius × 7
# (мелкие шоты огненного шквала → ~10м). Большой одиночный файрбол
# (HandSpellFireball) переопределяет через setup_fog_pulse() (12м).
# -1.0 = sentinel «не задан, использовать дефолт».
# Кол-во тиков и grow вычисляется автоматически из FogOfWar.PULSE_SPREAD_SPEED
# (общая скорость с spark-частицами).
var _fog_pulse_max_radius: float = -1.0

## Взрываться при пересечении объекта по пути (а не только у точки цели).
## Включается через set_collide_in_flight. Луч по _flight_collision_mask из
## прошлой позиции в новую каждый кадр → взрыв в точке первого попадания.
var _collide_in_flight: bool = false
## Маска «преграды» для столкновения в полёте (см. set_collide_in_flight).
var _flight_collision_mask: int = 0

## Отражён ли снаряд тайминг-парированием башни (см. reflect). После отражения
## он дружественный: homing ведёт ЖИВОГО врага _reflect_target, маски бьют ENEMIES,
## а retarget() от меха игнорируется (мех больше им не управляет).
var _reflected: bool = false
var _reflect_target: Node3D = null
## Кто выпустил снаряд (мех/скелет). При отражении летит ОБРАТНО в него (а не в
## ближайшего врага). Ставит стрелок при спавне через set_shooter.
var _shooter: Node3D = null


## Запомнить стрелка (для отражения «обратно в стрелка»). Зовёт спавнер снаряда.
func set_shooter(n: Node3D) -> void:
	_shooter = n


## Свойство для FogOfWar.FOG_REVEAL_GROUP — в полёте снаряд светит вокруг,
## рассеивая туман. История: 14→26→40→55→32→8м. Концепция эволюционировала:
## вначале хотелось «широкий коридор видимости» (55м), но дизайнер
## переосмыслил — ракета не освещает половину карты, а РАЗРЕЗАЕТ темноту
## тонкой линией; драматичная вспышка происходит на ИМПАКТЕ (×12 множитель в
## pulse_reveal ниже), а не в полёте. Тонкий 8м-трейл читается как «росчерк
## огня», импакт — как «взрыв света».
var fog_reveal_radius: float = 8.0


func _ready() -> void:
	# Туман: ракета в полёте — мобильный источник света, рассеивает мглу
	# вдоль траектории. После _explode queue_free снимает узел из группы.
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)


## Конфиг ракеты. Вызывает HandSpellFireball.on_press после instantiate'а.
## Boost-фаза создаёт стартовую дугу (выскакивает из башни вверх + slight
## forward, gravity пригибает). Homing-фаза тянет напрямую к target с
## растущей скоростью — current_speed = initial → max через acceleration.
func setup(
	launch_pos: Vector3,
	target_pos: Vector3,
	boost_duration: float,
	boost_velocity_up: float,
	boost_velocity_forward: float,
	boost_gravity: float,
	boost_drift_velocity: float,
	homing_initial_speed: float,
	homing_acceleration: float,
	homing_max_speed: float,
	homing_drift_angle_deg: float,
	homing_turn_rate: float,
	damage: float,
	radius: float,
	explode_mask: int,
	knockback_force: float,
	knockback_lift: float,
	knockback_duration: float,
) -> void:
	global_position = launch_pos
	_target_pos = target_pos
	_boost_duration = boost_duration
	_boost_gravity = boost_gravity
	_homing_initial_speed = homing_initial_speed
	_homing_acceleration = homing_acceleration
	_homing_max_speed = homing_max_speed
	_homing_turn_rate = homing_turn_rate
	_damage = damage
	_radius = radius
	_explode_mask = explode_mask
	_knockback_force = knockback_force
	_knockback_lift = knockback_lift
	_knockback_duration = knockback_duration

	# Drift-угол homing'а: random ± от заданной амплитуды. Знак случайный —
	# фаербол уводит то влево, то вправо при каждом касте.
	_homing_drift_angle = deg_to_rad(randf_range(-homing_drift_angle_deg, homing_drift_angle_deg))
	if LogConfig.master_enabled:
		print("[Fireball:setup] launch=(%.1f,%.1f,%.1f) target=(%.1f,%.1f,%.1f) radius=%.1f damage=%.1f" % [
			launch_pos.x, launch_pos.y, launch_pos.z,
			target_pos.x, target_pos.y, target_pos.z,
			radius, damage,
		])

	var dx: float = target_pos.x - launch_pos.x
	var dz: float = target_pos.z - launch_pos.z
	var horizontal_dist_sq: float = dx * dx + dz * dz
	var dir_xz: Vector3 = Vector3(dx, 0.0, dz).normalized() if horizontal_dist_sq > 0.01 else Vector3.ZERO
	# Стартовая скорость boost'а: вверх + чуть вперёд + случайный sway вбок
	# (perpendicular к forward через cross UP). Sway даёт «дрожь» при взлёте,
	# каждый каст уходит чуть в свою сторону. Амплитуда ±boost_drift_velocity.
	var perp_xz: Vector3 = dir_xz.cross(Vector3.UP).normalized() if dir_xz.length_squared() > 0.01 else Vector3(1.0, 0.0, 0.0)
	var sway: float = randf_range(-1.0, 1.0) * boost_drift_velocity
	_velocity = Vector3.UP * boost_velocity_up + dir_xz * boost_velocity_forward + perp_xz * sway
	_phase = Phase.BOOST


## Опциональный override максимального радиуса fog-pulse. Без вызова —
## дефолт = _radius × 7 (подходит для мелких шотов огненного шквала).
## Длительность раскрытия вычисляется автоматически из
## FogOfWar.PULSE_SPREAD_SPEED — фронт тумана движется с фиксированной
## скоростью м/с, ticks = radius/speed.
func setup_fog_pulse(max_radius: float) -> void:
	_fog_pulse_max_radius = max_radius


## Включает столкновение в полёте: снаряд взрывается на первом объекте по пути,
## а не только у точки цели. flight_mask — что СЧИТАЕТСЯ преградой (отдельно от
## _explode_mask = что задевает AOE): для меха — MASK_HOSTILE_PROJECTILE (башня/
## стены/лагерь), для игрока — MASK_FRIENDLY_PROJECTILE (враги/земля, НЕ свои —
## иначе рванул бы сразу в гуще своих у башни). flight_mask<0 → берём _explode_mask.
func set_collide_in_flight(enabled: bool, flight_mask: int = -1) -> void:
	_collide_in_flight = enabled
	_flight_collision_mask = flight_mask if flight_mask >= 0 else _explode_mask


## Опциональный конфиг остаточного горения после взрыва. Если scene не
## передана (или null) — burn не спавнится. Параметры BurnPatch.setup() —
## один-в-один.
func setup_burn(scene: PackedScene, radius: float, damage_per_tick: float, tick_interval: float, duration: float) -> void:
	_burn_patch_scene = scene
	_burn_radius = radius
	_burn_damage_per_tick = damage_per_tick
	_burn_tick_interval = tick_interval
	_burn_duration = duration


## Live-перенацеливание: обновляет точку, к которой тянет homing-фаза. Дефолтный
## фаербол это НЕ зовёт (летит в зафиксированную точку каста) — нужно для
## «вдогонку»-ракет меха, которые ведут движущуюся башню каждый кадр. После
## отражения игнорируется — снарядом управляет reflect-homing, не мех.
func retarget(pos: Vector3) -> void:
	if _reflected:
		return
	_target_pos = pos


## Отражение тайминг-парированием башни: разворачиваем снаряд в ближайшего врага
## и делаем его дружественным (AOE бьёт ENEMIES, в полёте детонирует о врага).
## homing после этого ведёт ЖИВОГО врага (_reflect_target) — «обратно в стрелка».
## Возвращает true, если отражён (нашёлся враг для самонаведения).
func reflect(_reflector_pos: Vector3) -> bool:
	if _exploded or _reflected:
		return false
	# Обратно в стрелка (если жив), иначе в ближайшего врага.
	var enemy: Node3D = Reflectable.resolve_reflect_target(get_tree(), global_position, _shooter)
	if enemy == null:
		return false
	_reflected = true
	_reflect_target = enemy
	_explode_mask = Layers.MASK_HAND_SLAM            # AOE теперь бьёт врагов
	_flight_collision_mask = Layers.MASK_FRIENDLY_PROJECTILE  # детонирует о врага в полёте
	_collide_in_flight = true
	# Если ещё в boost-дуге — сразу в homing, чтобы развернуться немедленно.
	if _phase == Phase.BOOST:
		_phase = Phase.HOMING
		_current_speed = maxf(_homing_initial_speed, _velocity.length())
	var to: Vector3 = enemy.global_position - global_position
	to.y = 0.0
	if to.length_squared() > 0.001:
		_velocity = to.normalized() * maxf(_current_speed, _homing_initial_speed)
	_target_pos = Vector3(enemy.global_position.x, 0.0, enemy.global_position.z)
	# Снимаемся с «отражаемых» (нельзя дважды) и встаём в снаряды игрока — мех
	# теперь уворачивается от собственного отражённого фаербола.
	if is_in_group(Reflectable.GROUP):
		remove_from_group(Reflectable.GROUP)
	add_to_group(&"player_projectile")
	return true


func _physics_process(delta: float) -> void:
	if _exploded:
		return
	_age += delta
	if _age > SAFETY_LIFETIME:
		# Аварийная очистка: если что-то пошло не так и snaряд завис, не
		# держим его в сцене вечно. Без AOE — это safety, не нормальный
		# исход.
		queue_free()
		return

	# Позиция до движения — для сегмент-луча столкновения в полёте.
	var prev_pos: Vector3 = global_position

	if _phase == Phase.BOOST:
		# Стартовая дуга: gravity пригибает velocity.y. По истечении
		# boost_duration — переход в HOMING с initial drift-angle.
		_velocity.y -= _boost_gravity * delta
		global_position += _velocity * delta
		if _age >= _boost_duration:
			_phase = Phase.HOMING
			_current_speed = _homing_initial_speed
			# Стартовое направление homing'а: target-dir повёрнутая на
			# случайный drift-angle вокруг UP. Фаербол стартует «мимо», и
			# slerp в loop'е ниже плавно докручивает к цели — характерный
			# «крюк», который читается как импактный drift.
			var to_target_init: Vector3 = _target_pos - global_position
			if to_target_init.length_squared() > 0.001:
				var desired_init: Vector3 = to_target_init.normalized()
				var drift_basis := Basis(Vector3.UP, _homing_drift_angle)
				_velocity = (drift_basis * desired_init) * _current_speed
			if LogConfig.master_enabled:
				print("[Fireball:boost->homing] age=%.2fс pos=(%.1f,%.1f,%.1f) dist_to_target=%.1fм" % [
					_age, global_position.x, global_position.y, global_position.z,
					to_target_init.length(),
				])
	else:
		# Homing: speed растёт линейно (acceleration), direction плавно
		# slerp'ится к target. Decay = 1-exp(-rate*dt) даёт frame-rate
		# independent смягчение. Малый rate (~5) — длинный drift; большой
		# (~20) — быстрый коррекшен и почти прямой полёт.
		_current_speed = minf(_current_speed + _homing_acceleration * delta, _homing_max_speed)
		# Отражённый снаряд ведёт ЖИВОГО врага (точка на земле под ним) — «обратно
		# в стрелка», даже если тот движется. Враг исчез — летим в последнюю точку.
		if _reflected and is_instance_valid(_reflect_target):
			_target_pos = Vector3(_reflect_target.global_position.x, 0.0, _reflect_target.global_position.z)
		var to_target: Vector3 = _target_pos - global_position
		var distance: float = to_target.length()
		if distance < 0.001:
			_explode()
			return
		var desired_dir: Vector3 = to_target / distance
		var current_dir: Vector3 = _velocity.normalized() if _velocity.length_squared() > 0.001 else desired_dir
		var decay: float = 1.0 - exp(-_homing_turn_rate * delta)
		var new_dir: Vector3 = current_dir.slerp(desired_dir, decay).normalized()
		_velocity = new_dir * _current_speed
		global_position += _velocity * delta

	# Столкновение в полёте: луч из прошлой позиции в новую. Первое попадание
	# по _flight_collision_mask → взрыв в точке контакта. Проверяем ДО proximity/
	# y-pierce, чтобы преграда на линии огня детонировала снаряд раньше цели.
	if _collide_in_flight and _check_flight_collision(prev_pos, global_position):
		return

	# Ориентация: local +X по направлению velocity. Капля (scale.x>1) и
	# хвост-партиклы спавнятся через `local_coords=false` в world space —
	# ориентация нужна только для визуала самого ядра.
	_orient_along_velocity()

	# Триггер взрыва: либо подлетели к target близко (3D-proximity), либо
	# пробили target.y вниз (страховка на случай overshoot'а в HOMING).
	var to_target_3d: Vector3 = _target_pos - global_position
	if to_target_3d.length_squared() <= HIT_PROXIMITY_SQ:
		if LogConfig.master_enabled:
			print("[Fireball:trigger] proximity age=%.2fс dist=%.2fм" % [_age, to_target_3d.length()])
		_explode()
		return
	if _phase == Phase.HOMING and global_position.y <= _target_pos.y:
		if LogConfig.master_enabled:
			print("[Fireball:trigger] y-pierce age=%.2fс y=%.2f target_y=%.2f" % [_age, global_position.y, _target_pos.y])
		_explode()


func _orient_along_velocity() -> void:
	var dir_xz: Vector3 = Vector3(_velocity.x, 0.0, _velocity.z)
	if dir_xz.length_squared() < 0.01:
		return
	dir_xz = dir_xz.normalized()
	var up: Vector3 = Vector3.UP
	var right: Vector3 = dir_xz.cross(up).normalized()
	var tx_basis := Basis()
	tx_basis.x = dir_xz
	tx_basis.y = up
	tx_basis.z = right
	global_transform.basis = tx_basis


## Луч-сегмент из from в to по _flight_collision_mask. На попадании — взрыв в
## точке контакта (origin в _explode клампится к hit.y через _target_pos.y).
## Возвращает true если детонировал.
func _check_flight_collision(from: Vector3, to: Vector3) -> bool:
	if from.distance_squared_to(to) < 1e-8:
		return false
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var q := PhysicsRayQueryParameters3D.create(from, to, _flight_collision_mask)
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return false
	global_position = hit.position
	_target_pos.y = hit.position.y
	_explode()
	return true


func _xz_distance_sq(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return dx * dx + dz * dz


## AOE-урон + push в радиусе. По образцу HandPhysicalSlam._perform_slam:
## broad-phase PhysicsShapeQuery + per-target иммунитет + FAR-fallback по
## группе SKELETON_GROUP (FAR-скелеты с CollisionShape.disabled=true в
## broad-phase не попадают).
func _explode() -> void:
	if _exploded:
		return
	_exploded = true
	var origin := global_position
	# Y центра взрыва клампим к target.y — чтобы AOE применялся на земле,
	# а не в воздухе если шар по proximity сработал чуть раньше.
	origin.y = _target_pos.y

	var space := get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = _radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), origin)
	query.collision_mask = _explode_mask
	query.collide_with_bodies = true
	var results := space.intersect_shape(query, 32)

	var radius_sq: float = _radius * _radius
	# Per-target иммунитет в рамках одного взрыва: цель, прошедшая broad-phase,
	# не должна повторно прийти из FAR-fallback'а — иначе двойной damage.
	var affected_set: Array[Node] = []
	var affected: int = 0
	for r in results:
		var collider = r.collider
		if not is_instance_valid(collider):
			continue
		if not Damageable.is_damageable(collider):
			continue
		if Layers.is_hand_immune(collider):
			continue
		# Horizontal-only distance: взрыв на ground'е, центр капсулы скелета
		# на y≈0.9 — 3D distance отъедал бы 0.9м horizontal-радиуса.
		if _xz_distance_sq((collider as Node3D).global_position, origin) > radius_sq:
			continue
		_apply_aoe(collider, origin)
		affected_set.append(collider)
		affected += 1

	# FAR-fallback: скелеты вне broad-phase (LOD FAR). Тот же паттерн что и
	# в HandPhysicalSlam._perform_slam.
	var far_hits: int = 0
	for n in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		var skel := n as Skeleton
		if skel == null:
			continue
		if skel in affected_set:
			continue
		if skel.get_lod_level() != Skeleton.LodLevel.FAR:
			continue
		if Layers.is_hand_immune(skel):
			continue
		if _xz_distance_sq(skel.global_position, origin) > radius_sq:
			continue
		_apply_aoe(skel, origin)
		far_hits += 1

	if LogConfig.master_enabled:
		print("[Fireball] взрыв @ (%.1f, %.1f, %.1f), задело: %d (FAR: %d)" % [origin.x, origin.y, origin.z, affected + far_hits, far_hits])

	# Сигнал для коллеров, которые спавнят что-то на месте удара (Mine
	# Scatter использует — ставит Mine'у в origin). Эмитим ДО visual'ов
	# и queue_free, чтобы слушатель видел консистентное состояние.
	hit.emit(origin, _radius)
	# Override-точка для подклассов (FrostBolt применяет freeze к hit-target'ам,
	# спавнит FrostPatch). Вызывается ДО спавна burn_patch / визуалов —
	# подкласс может полностью пропустить burn (не задав scene) и подставить
	# свой patch-аналог.
	_on_post_explode(origin)
	# Визуалы взрыва. Спавним в parent (effects_root, обычно current_scene) —
	# не в self, иначе на queue_free() ниже визуалы тоже умрут до окончания
	# tween'а. parent живёт всё время сцены.
	var fx_root: Node = get_parent()
	if fx_root != null:
		if impact_uses_dust:
			AoeVisual.spawn_dust(fx_root, origin)
		else:
			AoeVisual.spawn_explosion(fx_root, origin, _radius)
		# Fog reveal: импакт-вздох тумана. Радиус: дефолт _radius × 7 (мелкие
		# шоты шквала), override через setup_fog_pulse (большой файрбол → 12м).
		# Pulse стартует с размера trail'а (8м у фаербола в полёте) — иначе
		# первые 0.8с pulse «прячется» внутри ещё-прокрашенной trail-зоны и
		# игрок видит «паузу» перед расширением.
		# Длительность раскрытия = (max − start) / PULSE_SPREAD_SPEED — фронт
		# движется со скоростью PULSE_SPREAD_SPEED м/с (общая со spark'ами).
		var pulse_radius: float = _fog_pulse_max_radius if _fog_pulse_max_radius > 0.0 else _radius * 7.0
		var pulse_start: float = fog_reveal_radius  # размер trail'а на момент импакта
		var speed: float = FogOfWar.PULSE_SPREAD_SPEED
		var grow_distance: float = maxf(pulse_radius - pulse_start, 0.5)
		var grow_ticks: int = maxi(1, int(ceil(grow_distance / speed / 0.1)))
		var total_ticks: int = grow_ticks + 1  # +1 финальный тик на полном радиусе
		if LogConfig.master_enabled:
			print("[Fireball:fog-pulse] origin=(%.1f,%.1f,%.1f) start=%.1fм→max=%.1fм speed=%.1fм/с ticks=%d grow=%d" % [
				origin.x, origin.y, origin.z, pulse_start, pulse_radius, speed, total_ticks, grow_ticks,
			])
		FogOfWar.pulse_reveal(origin, pulse_radius, total_ticks, grow_ticks, pulse_start)
		# Искры-разлёт «горения» только до радиуса damage'а. Скорость совпадает
		# с скоростью фронта тумана — визуально оба фронта движутся синхронно,
		# но искры останавливаются на _radius (damage-зона), туман продолжает
		# расширяться до pulse_radius за тот же интервал времени.
		AoeVisual.spawn_pulse_sparks(fx_root, origin, _radius, speed)
		# Остаточное горение: статичная зона на месте взрыва, тикает damage
		# через `_burn_duration` секунд. Спавним только если scene задана —
		# чтобы можно было выключить burn полностью одним полем (null).
		if _burn_patch_scene != null:
			var patch := _burn_patch_scene.instantiate() as BurnPatch
			if patch != null:
				fx_root.add_child(patch)
				patch.global_position = origin
				patch.setup(
					_burn_radius,
					_burn_damage_per_tick,
					_burn_tick_interval,
					_burn_duration,
					_explode_mask,
				)
				if LogConfig.master_enabled:
					print("[Fireball:burn] spawn @ (%.1f,%.1f,%.1f) radius=%.1fм duration=%.1fс" % [
						origin.x, origin.y, origin.z, _burn_radius, _burn_duration,
					])

	queue_free()


## Override-точка для подклассов. Базовая реализация ничего не делает.
## FrostBolt использует для freeze hit-target'ов + спавна FrostPatch.
func _on_post_explode(_origin: Vector3) -> void:
	pass


func _apply_aoe(target: Node, origin: Vector3) -> void:
	if not is_instance_valid(target):
		return
	var to_target: Vector3 = (target as Node3D).global_position - origin
	var horizontal_dist: float = Vector2(to_target.x, to_target.z).length()
	# Falloff: sqrt-curve (раньше linear). Меньше «обрыв» на средней дистанции:
	# на 50% радиуса остаётся 71% damage'а (vs 50% при linear), на 75% — 50%
	# (vs 25%). Удар крайней цели всё ещё проседает (на 90% радиуса — 32%),
	# но уже не «обнуляется» за пределами burn-зоны.
	var falloff_linear: float = clampf(1.0 - horizontal_dist / _radius, 0.0, 1.0)
	var falloff: float = sqrt(falloff_linear)
	if falloff <= 0.0:
		return
	var horizontal_dir: Vector3 = VecUtil.horizontal(to_target)
	if horizontal_dir.length_squared() < VecUtil.EPSILON_SQ:
		horizontal_dir = Vector3.UP
	else:
		horizontal_dir = horizontal_dir.normalized() + Vector3.UP * _knockback_lift
		horizontal_dir = horizontal_dir.normalized()
	var velocity_change: Vector3 = horizontal_dir * _knockback_force * falloff
	Pushable.try_push(target, velocity_change, _knockback_duration)
	var dealt: float = _damage * falloff
	Damageable.try_damage(target, dealt)
	# Телеметрия отражения: если этот снаряд отбит парированием — сообщаем цели
	# (мех ведёт счёт отражённого урона). Duck-typing, без связки с EnemyMech.
	if _reflected and dealt > 0.0 and target.has_method("note_reflected_damage"):
		target.note_reflected_damage(dealt)
