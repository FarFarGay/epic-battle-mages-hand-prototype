class_name SparkBolt
extends Node3D
## Жёлтая искра-снаряд для заклинания [code]spark[/code].
##
## Поведение: летит в фиксированную точку под курсором (как Fireball/Frost-
## bolt), но НЕ AOE и НЕ homing на конкретного врага. На контакте с точкой
## делает sphere-scan в [impact_radius] и наносит damage **только первому**
## найденному врагу (single-target в точке падения). Если в радиусе никого —
## просто искрит и гаснет (можно бить в землю для эффекта).
##
## Полёт зигзагом: к direction-to-target добавляется sin-смещение по
## перпендикуляру в XZ. Высокая частота ([zigzag_frequency] ~9 Hz) — снаряд
## читается как «трескучая искра».
##
## Trail: GPUParticles3D-ребёнок [Trail] стрекает жёлтые квадраты позади —
## на _ready ставим emitting=true, на queue_free particles сами догаснут
## (lifetime короткий).

## Скорость снаряда (м/с). Быстро — игрок видит «мгновенный удар», но всё
## ещё успевает заметить полёт.
@export var speed: float = 35.0

## Урон на цели в точке попадания. Прописывается из [HandSpellSpark] на setup.
@export var damage: float = 35.0

## Радиус sphere-scan в точке impact'а. Берётся ПЕРВЫЙ найденный Enemy в
## радиусе — single-target. Маленький (1.5м) — игрок должен метко наводить;
## промах = «искра в землю».
@export var impact_radius: float = 1.5

## Амплитуда зигзага (м, поперечное отклонение).
@export var zigzag_amplitude: float = 1.2

## Частота зигзага (Гц).
@export var zigzag_frequency: float = 9.0

## Дистанция до target_pos, на которой считаем что снаряд «добрался».
@export var arrival_radius: float = 0.4

## Лайфтайм safety-cap (с).
@export var max_lifetime: float = 4.0

var _target_pos: Vector3 = Vector3.ZERO
var _elapsed: float = 0.0
var _effects_root: Node = null


## Caller (HandSpellSpark) задаёт start_pos, target_pos и damage. effects_root —
## куда спавнить FX на impact'е (current_scene или специальный root).
func setup(start_pos: Vector3, target_pos: Vector3, p_damage: float, effects_root: Node) -> void:
	global_position = start_pos
	_target_pos = target_pos
	damage = p_damage
	_effects_root = effects_root if effects_root != null else get_tree().current_scene
	# Look_at до первого тика для ориентации trail-particles.
	if (target_pos - start_pos).length_squared() > 0.0001:
		look_at(target_pos, Vector3.UP)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= max_lifetime:
		_explode()
		return
	var to_target: Vector3 = _target_pos - global_position
	# Игнорим Y при чек'е прибытия — снаряд может «зависнуть» по вертикали,
	# а нам важна точка на земле.
	var flat_dist_sq: float = to_target.x * to_target.x + to_target.z * to_target.z
	if flat_dist_sq <= arrival_radius * arrival_radius:
		_explode()
		return
	var dir: Vector3 = to_target.normalized()
	# Zigzag: perpendicular в XZ (cross с UP). Y-смещение опускаем — искра
	# держит высоту полёта.
	var side: Vector3 = dir.cross(Vector3.UP)
	if side.length_squared() > 0.0001:
		side = side.normalized()
	var wobble: float = sin(_elapsed * zigzag_frequency * TAU) * zigzag_amplitude
	var velocity: Vector3 = dir * speed + side * wobble * zigzag_frequency
	global_position += velocity * delta
	# Поворот в сторону движения — trail-particles ориентируются по -Z.
	if velocity.length_squared() > 0.0001:
		look_at(global_position + velocity, Vector3.UP)


## Точка падения: spark-FX + одна жертва (если в радиусе есть Enemy).
## Берём ПЕРВОГО подходящего по итерации группы (или ближайшего — без
## разницы, всё равно single-target). Логичный «ближайший» лучше читается
## дизайнерски: попал в зону → ударило того кто ближе всех к точке.
func _explode() -> void:
	# FX-выстрел искр в стороны: мгновенный pulse-sparks с малым радиусом.
	# Скорость одна со spread'ом fog-pulse (10 м/с) — единый визуальный темп.
	if _effects_root != null:
		AoeVisual.spawn_pulse_sparks(_effects_root, global_position, impact_radius, 10.0)
	var victim: Node3D = _find_nearest_enemy_in_radius()
	if victim != null and victim.has_method(&"take_damage"):
		victim.call(&"take_damage", damage)
	queue_free()


func _find_nearest_enemy_in_radius() -> Node3D:
	var best: Node3D = null
	var best_dist_sq: float = impact_radius * impact_radius
	for n in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(n):
			continue
		var e := n as Node3D
		if e == null:
			continue
		var dx: float = e.global_position.x - global_position.x
		var dz: float = e.global_position.z - global_position.z
		var d_sq: float = dx * dx + dz * dz
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			best = e
	return best
