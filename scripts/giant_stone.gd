class_name GiantStone
extends Node3D
## AOE-снаряд гиганта-каменщика. Баллистика → impact в точке landing'а →
## взрыв с волной + урон/push в радиусе. Не наследует [Arrow] (тот single-target
## damage on body_entered) — здесь другая семантика: цель не объект, а **точка
## на земле**; на impact'е делаем sphere-query и damage'им всё в радиусе.
##
## Цикл жизни:
##   1. `setup(source, target)` — задаёт стартовую velocity баллистикой
##      (тот же [_compute_launch_velocity] что у Arrow, копипаст — не выносим
##      в shared util'ю, пока два места).
##   2. `_physics_process` — интегрирует velocity с gravity. На каждом тике
##      два детонатора:
##        - body_entered (HitArea.monitoring) — попали в Tower/палисад/гнома;
##        - y <= _target_pos.y — приземлились в землю мимо тел.
##      Любой из двух → [_explode] на текущей позиции.
##   3. `_explode` — spawn_explosion (ядро + огонь + дым) + spawn_expanding_ring
##      (волна), затем sphere-query через PhysicsShapeQuery → каждому
##      Damageable.try_damage + Pushable.try_push с radial-направлением.
##      queue_free.
##
## Камень — caller-driven damage. SkeletonGiantThrower рандомизирует
## damage в `arrow_damage_min..max` и пишет в [member damage] перед setup'ом.
## Параметры AOE (radius, knockback) — на стороне Stone'a через @export'ы,
## дизайнер крутит в .tscn.

@export var speed: float = 18.0
## Гравитация для камня. Выше чем у Arrow (6.0) — камень тяжелее, дуга круче.
## Дизайн: игрок видит крутую параболу, успевает прочитать «сейчас упадёт».
@export var gravity: float = 12.0
## Аварийная очистка если по какой-то причине ни body_entered, ни y-check не
## сработали (камень улетел в небо и не вернулся, edge case).
@export var lifetime: float = 5.0
## Радиус AOE-зоны impact'а. Damage + push применяется к Damageable/Pushable
## в этой сфере. 4м — Tower (2×2) гарантированно попадает + рядом стоящие
## защитники.
@export var aoe_radius: float = 4.0
## Маска объектов, по которым проходит AOE. Default = MASK_HOSTILE_PROJECTILE
## без TERRAIN (= 868): ACTORS (Tower) + CAMP_OBSTACLE (палатки) +
## MOUNTED_MODULE (турель) + FRIENDLY_UNIT (гномы/защитники) +
## PALISADE_OBSTACLE (стены). Терраин в маске не нужен — пол не damageable.
## Выражение вместо литерала — не дрейфует при переборке битов в Layers.
@export_flags_3d_physics var aoe_mask: int = Layers.MASK_HOSTILE_PROJECTILE & ~Layers.TERRAIN
## Скорость knockback'а в м/с. Радиальное направление от центра удара.
## 4.0 — заметный, но не катапультирует. Гномы получают это как push,
## защитник немного отлетит от Tower.
@export var knockback_speed: float = 4.0
@export var knockback_duration: float = 0.3
## Цвет expanding_ring'а на impact. Дефолт пыльно-оранжевый под камень.
## AoeArrow override'ит на фиолетовый (магическая стрела скелетов-лучников).
@export var explosion_ring_color: Color = Color(0.85, 0.55, 0.25, 0.9)
## Показывать big-explosion-визуал (ядро+огонь+дым+expanding_ring) на impact.
## Default true для камня. False = вообще никакого визуала. Для тонкого
## impact-эффекта стрелы — оставить true но включить impact_ring_only.
@export var show_explosion_visual: bool = true
## Если true — показываем ТОЛЬКО expanding_ring (тонкая impact-волна), без
## ядра/огня/дыма. AoeArrow: лёгкий puff на земле при попадании стрелы.
## Игнорируется если show_explosion_visual=false.
@export var impact_ring_only: bool = false
## Тряска камеры на прилёт (trauma 0..1, затухает по дистанции). 0 = без шейка —
## дефолт для лёгких стрел фоддера. Гигант-метатель ставит >0 (тяжёлый камень).
@export var shake_amount: float = 0.0
@export var debug_log: bool = false

## Damage задаётся caller'ом перед setup() — у разных гигантов может быть
## разный stone-damage (см. SkeletonGiantThrower.arrow_damage_min/max).
var damage: float = 50.0

## FogOfWar: камень в полёте рассеивает туман маленьким пятном — как стрела,
## выдаёт траекторию. Без этого камень летит в чёрной мгле и игрок видит
## только звук+импакт.
var fog_reveal_radius: float = 5.0

var _velocity: Vector3 = Vector3.ZERO
var _life: float = 0.0
var _consumed: bool = false
var _target_pos: Vector3 = Vector3.ZERO
## Отбит ли снаряд парированием башни (для телеметрии отражённого урона по врагу).
var _reflected: bool = false
## Кто выпустил снаряд — при отражении летит ОБРАТНО в него (а не в ближайшего).
var _shooter: Node3D = null


## Запомнить стрелка (для отражения «обратно в стрелка»). Зовёт спавнер снаряда.
func set_shooter(n: Node3D) -> void:
	_shooter = n

@onready var _hit_area: Area3D = $HitArea


func _ready() -> void:
	_hit_area.body_entered.connect(_on_body_entered)
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)
	# Отражаемый снаряд: тайминг-парирование башни может развернуть камень/стрелу
	# обратно в стрелка (см. Reflectable / Tower._tick_parry). GiantStone — только
	# вражеский снаряд (камень гиганта, AoeArrow лучника), игрок его не кастует.
	Reflectable.register(self)


## Вызывается caller'ом сразу после instantiate + add_child. source — точка
## выпуска (над головой гиганта), target — точка падения на земле (с
## inaccuracy applied на стороне caller'а).
func setup(source_position: Vector3, target_position: Vector3) -> void:
	global_position = source_position
	_target_pos = target_position
	_velocity = BallisticUtil.compute_launch_velocity(source_position, target_position, speed, gravity)
	# Warning при недостижимой баллистике (disc<0 в BallisticUtil → fallback
	# на прямой выстрел). Если попадаем сюда — баланс speed/gravity разошёлся
	# с attack_radius_max thrower'а: камень уронит гравитацией раньше цели.
	# Признак: |v.y| мал и равен направленной компоненте, а не реальному tan(α).
	var horizontal_dist: float = Vector2(target_position.x - source_position.x, target_position.z - source_position.z).length()
	var v_min_sq: float = gravity * horizontal_dist  # при dy=0 минимум |v|² = g·d
	if speed * speed < v_min_sq and horizontal_dist > 0.5:
		push_warning("[GiantStone] баллистика недостижима: speed=%.1f gravity=%.1f d=%.1f — fallback на прямой выстрел, камень упадёт раньше цели" % [
			speed, gravity, horizontal_dist,
		])
	_orient_along_velocity()
	if debug_log and LogConfig.master_enabled:
		print("[GiantStone:setup] src=(%.1f,%.2f,%.1f) tgt=(%.1f,%.2f,%.1f) v=(%.1f,%.2f,%.1f)" % [
			source_position.x, source_position.y, source_position.z,
			target_position.x, target_position.y, target_position.z,
			_velocity.x, _velocity.y, _velocity.z,
		])


func _orient_along_velocity() -> void:
	if _velocity.length_squared() < 0.0001:
		return
	var fwd := _velocity.normalized()
	var up := Vector3.UP
	if absf(fwd.dot(up)) > 0.99:
		up = Vector3.FORWARD
	look_at(global_position + fwd, up)


func _physics_process(delta: float) -> void:
	if _consumed:
		return
	_life += delta
	if _life >= lifetime:
		_explode(global_position)
		return
	_velocity.y -= gravity * delta
	global_position += _velocity * delta
	_orient_along_velocity()
	# Y-check: попали в землю мимо тел. _target_pos.y — высота landing-точки
	# (обычно 0, но если каменщик кидает в Tower'а на возвышении — тогда выше).
	# Срабатывает после первого падения ниже целевого уровня.
	if _velocity.y < 0.0 and global_position.y <= _target_pos.y:
		_explode(Vector3(global_position.x, _target_pos.y, global_position.z))


func _on_body_entered(body: Node) -> void:
	if _consumed:
		return
	if debug_log and LogConfig.master_enabled:
		print("[GiantStone:body_hit] body=%s pos=(%.1f,%.2f,%.1f)" % [
			body.name, global_position.x, global_position.y, global_position.z,
		])
	_explode(global_position)


## Детонация: визуал (взрыв + волна) + AOE damage/push в радиусе. Идемпотентна
## через _consumed (несколько body_entered + y-check могут попасть в один
## кадр).
func _explode(pos: Vector3) -> void:
	if _consumed:
		return
	_consumed = true
	global_position = pos
	if shake_amount > 0.0:
		EventBus.camera_shake.emit(shake_amount, pos)  # тяжёлый камень метателя; затухает по дистанции
	var root: Node = get_tree().current_scene
	if not is_instance_valid(root):
		queue_free()
		return
	# Визуал: ядро+огонь+дым (та же связка что у fireball/slam) + волна
	# (expanding_ring). Цвет волны — пыльно-оранжевый, отличается от
	# tower-recall (голубой) и slam-волны.
	if show_explosion_visual:
		if not impact_ring_only:
			AoeVisual.spawn_explosion(root, pos, aoe_radius)
		AoeVisual.spawn_expanding_ring(root, pos, aoe_radius * 1.15, 0.45,
			explosion_ring_color, 0.22)
	_apply_aoe(pos)
	if debug_log and LogConfig.master_enabled:
		print("[GiantStone:explode] pos=(%.1f,%.2f,%.1f) r=%.1f dmg=%.1f" % [
			pos.x, pos.y, pos.z, aoe_radius, damage,
		])
	queue_free()


## Sphere-AOE через [AoeDamage.apply_uniform] — damage + radial push всем
## в радиусе. Раньше эта логика жила локально (sphere-query + radius²-filter
## + damage/push цикл) — вынесена в shared util после code review.
func _apply_aoe(center: Vector3) -> void:
	var hits: Array[Node] = AoeDamage.apply_uniform(get_tree(), center, aoe_radius,
		aoe_mask, damage, knockback_speed, knockback_duration)
	# Телеметрия отражения: отбитый камень/стрела — сообщаем урон поражённым врагам
	# (мех ведёт счёт отражённого). apply_uniform бьёт равномерно (damage каждому).
	if _reflected:
		for h in hits:
			if h.has_method("note_reflected_damage"):
				h.note_reflected_damage(damage)


## Отражение тайминг-парированием башни: перекидываем баллистику в ближайшего
## врага и делаем AOE дружественным (бьёт ENEMIES, как снаряд игрока). Камень
## падает врагу под ноги (y-check) → взрыв накрывает стрелка. true если отражён.
func reflect(_reflector_pos: Vector3) -> bool:
	if _consumed:
		return false
	# Обратно в стрелка (если жив), иначе в ближайшего врага.
	var enemy: Node3D = Reflectable.resolve_reflect_target(get_tree(), global_position, _shooter)
	if enemy == null:
		return false
	var dest: Vector3 = Vector3(enemy.global_position.x, 0.0, enemy.global_position.z)
	_target_pos = dest
	_velocity = BallisticUtil.compute_launch_velocity(global_position, dest, speed, gravity)
	_reflected = true
	aoe_mask = Layers.MASK_HAND_SLAM                 # AOE теперь бьёт врагов
	explosion_ring_color = Color(0.5, 0.9, 1.0, 0.9)  # дружественный (отражён)
	if is_in_group(Reflectable.GROUP):
		remove_from_group(Reflectable.GROUP)
	add_to_group(&"player_projectile")
	_orient_along_velocity()
	return true
