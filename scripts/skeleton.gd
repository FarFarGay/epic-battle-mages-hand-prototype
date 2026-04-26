class_name Skeleton
extends Enemy
## Простой враг.
## Жизненный цикл базового FSM Enemy: APPROACH → WINDUP → STRIKE → COOLDOWN → APPROACH.
## Skeleton override'ит только конкретику: телеграф замаха (свечение) и сам strike (lunge + damage).
##
## Замах телеграфируется красной подсветкой через смену material_override.
## Удар (`_perform_strike`) — это **физический выпад через apply_knockback самому себе**:
## скелет реально летит в сторону цели, врезается в неё (тело CharacterBody3D
## блокируется тем же CharacterBody3D башни), отскакивает (через
## Enemy._bounce_off_target), и по пути отбрасывает соседей-скелетов
## (через Enemy._push_neighbor).
## Если получает knockback во время замаха — замах отменяется (Enemy._on_knockback
## сбрасывает FSM в APPROACH).
##
## Визуал — общеклассовый: два разделяемых StandardMaterial3D (normal/windup)
## создаются один раз на класс и переиспользуются всеми инстансами скелетов.
## Это позволяет GPU батчить отрисовку (50 скелетов → ~1 draw call на состояние
## вместо 50 уникальных материалов). Цвет тела/замаха задан константами ниже,
## per-instance тонкая настройка не предусмотрена.
##
## Таргетинг: AI каждый кадр перевыбирает ближайшую живую цель из набора
## (Enemy.get_active_target). Если изначальная цель умерла, а в наборе есть
## другие — скелет автоматически переключается. Если набор пуст или все
## мертвы — скелет останавливается.

const BODY_ALBEDO_COLOR := Color(0.88, 0.85, 0.78, 1.0)
const WINDUP_EMISSION_COLOR := Color(1.0, 0.2, 0.2, 1.0)
const WINDUP_EMISSION_INTENSITY := 1.5

@export_group("Strike (физический выпад)")
@export var lunge_speed: float = 8.0  # m/s в момент удара
@export var lunge_duration: float = 0.2  # секунды knockback'а на сам выпад
@export_group("")

@export_group("Shatter (рассыпание на смерти)")
@export var shatter_fragment_count: int = 7
@export var shatter_lifetime: float = 2.0
@export var shatter_color: Color = BODY_ALBEDO_COLOR
@export_group("")

static var _shared_normal_material: StandardMaterial3D
static var _shared_windup_material: StandardMaterial3D

@onready var _mesh: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	# Унаследованный _ready регистрирует Damageable/Pushable и подключает EventBus.
	# Без super._ready() всё это потерялось бы только для скелетов.
	super._ready()
	_ensure_shared_materials()
	if _mesh:
		# Все скелеты делят два материала на класс — никаких .duplicate() per-instance.
		# Переключение состояния = смена ссылки в material_override → GPU батчит.
		_mesh.material_override = _shared_normal_material


static func _ensure_shared_materials() -> void:
	if _shared_normal_material == null:
		var normal := StandardMaterial3D.new()
		normal.albedo_color = BODY_ALBEDO_COLOR
		_shared_normal_material = normal
	if _shared_windup_material == null:
		var windup := StandardMaterial3D.new()
		windup.albedo_color = BODY_ALBEDO_COLOR
		windup.emission_enabled = true
		windup.emission = WINDUP_EMISSION_COLOR
		windup.emission_energy_multiplier = WINDUP_EMISSION_INTENSITY
		_shared_windup_material = windup


func _on_state_enter(new_state: int) -> void:
	if new_state == AttackState.WINDUP:
		_set_glow(true)


func _on_state_exit(old_state: int) -> void:
	if old_state == AttackState.WINDUP:
		_set_glow(false)


func _perform_strike(_target: Node3D) -> void:
	# Перевыбираем цель — между _ai_step и _perform_strike та могла умереть.
	# Параметр _target тут не используем: он мог стать невалидным, и проверять
	# его freed-инстансом небезопасно. get_active_target сам пропускает мёртвых.
	var active := get_active_target()
	if not active:
		return
	# Урон — до выпада, чтобы логически «удар попал», даже если bounce-off
	# отбросит скелета на следующем кадре.
	Damageable.try_damage(active, attack_damage)
	_do_lunge(active)


func _do_lunge(target: Node3D) -> void:
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < VecUtil.EPSILON_SQ:
		return
	var dir := to_target.normalized()
	# Self-knockback ВНЕ публичного apply_knockback — иначе наш собственный
	# выпад вызвал бы _on_knockback хук, и подклассы, навешивающие на него
	# логику отмены состояний, словили бы свой же lunge.
	_apply_velocity_change(dir * lunge_speed, lunge_duration)


func _on_destroyed() -> void:
	# Прячем тело и спавним осколки. Осколки живут в _effects_root — переживают
	# queue_free самого скелета, который произойдёт в Enemy.take_damage сразу после.
	if _mesh:
		_mesh.visible = false
	if _effects_root:
		ShatterEffect.spawn(_effects_root, global_position, shatter_color,
			shatter_fragment_count, shatter_lifetime)


func _set_glow(active: bool) -> void:
	if not _mesh:
		return
	# Свап ссылки — никаких чтений/записей свойств материала. Материалы общие,
	# мутировать их per-state нельзя (поломались бы все остальные скелеты).
	_mesh.material_override = _shared_windup_material if active else _shared_normal_material
