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
## в скрипте + override scene'ы; и override `_scan_target` — Tower имеет
## приоритет над любым другим target'ом.
##
## **Tower targeting hack**: Tower НЕ в TARGET_GROUP (=skeleton_target). Базовая
## skeleton-логика при stale-check'е (line ~1123) выбрасывает не-в-TARGET_GROUP
## цели из кэша. Гигант перезагружает Tower обратно через `_scan_target` на
## следующем тике — получается eternal-rebind с минимальным overhead'ом.
## Для редкого юнита (1-2 на карте) это приемлемее, чем рефакторить базу.

const GIANT_GROUP := &"skeleton_giant"

## Радиус рассеивания тумана вокруг гиганта. Дизайнерское решение 2026-05-19:
## гигант — это видимая, наводящая страх угроза, его надо видеть издалека.
## Стандартные скелеты прячутся в туман, гигант — выжигает его собой и
## всегда виден через `_update_enemy_visibility` (visibility у его позиции
## всегда выше threshold'а из-за самостоятельного fog-stamp'а).
## Радиус 9м чуть больше радиуса коллизии (1.5м) — пятно вокруг него видно
## издалека как «он рядом, готовься».
var fog_reveal_radius: float = 9.0

## Shared material для всех гигантов — переключает body на тёмный/багряный
## оттенок (отличие от обычного скелетного beige). Static, чтобы один draw-call
## на всех гигантов на сцене.
static var _shared_giant_material: StandardMaterial3D


func _ready() -> void:
	super._ready()
	add_to_group(GIANT_GROUP)
	# FOG_REVEAL_GROUP: гигант рассеивает туман собой (см. fog_reveal_radius
	# выше). Двойной эффект: (1) игрок видит силуэт гиганта в тумане
	# издалека, (2) сам гигант не скрывается _update_enemy_visibility'ом,
	# т.к. visibility у его позиции всегда >threshold от собственного stamp'а.
	add_to_group(FogOfWar.FOG_REVEAL_GROUP)
	# Override material — super._ready() переключил mesh на shared skeleton material.
	# Для гиганта используем свой shared, отличающийся цветом/эмиссией.
	_ensure_giant_material()
	if _mesh:
		_mesh.material_override = _shared_giant_material


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
	if tower != null and is_instance_valid(tower) and Damageable.is_damageable(tower):
		return tower as Node3D
	return super._scan_target()


## Override base get_active_target: базовая проверяет TARGET_GROUP и
## возвращает null если Tower (она не в TARGET_GROUP). Гиганту нужно
## разрешить Tower как валидную активную цель — добавляем проверку
## членства в `&"tower"` группе.
func get_active_target() -> Node3D:
	if _cached_target == null:
		return null
	if not is_instance_valid(_cached_target):
		return null
	if _cached_target.is_in_group(TARGET_GROUP) or _cached_target.is_in_group(Tower.GROUP):
		return _cached_target
	return null


## Override base _perform_strike: добавляет Tower в AoE-область удара. Базовый
## метод итерирует только TARGET_GROUP (палатки/гномы), Tower там нет —
## без этого гигант махал бы рядом с башней без эффекта.
func _perform_strike(target: Node3D) -> void:
	# Дополнительный удар по Tower'ам в радиусе. Использовать тот же STRIKE_RADIUS_FACTOR
	# как в Skeleton._perform_strike (через attack_range * 1.3).
	var strike_radius: float = attack_range * STRIKE_RADIUS_FACTOR
	var strike_radius_sq: float = strike_radius * strike_radius
	for t in get_tree().get_nodes_in_group(Tower.GROUP):
		if not is_instance_valid(t):
			continue
		var node := t as Node3D
		if node == null:
			continue
		var d_sq: float = (node.global_position - global_position).length_squared()
		if d_sq <= strike_radius_sq:
			Damageable.try_damage(node, attack_damage)
	# Передаём управление базе — обработка палаток/гномов в AoE + self-lunge.
	super._perform_strike(target)
