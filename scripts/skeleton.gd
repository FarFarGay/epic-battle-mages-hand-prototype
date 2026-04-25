class_name Skeleton
extends Enemy
## Простой враг.
## Жизненный цикл: APPROACH → (в attack_range) WINDUP → STRIKE → COOLDOWN → APPROACH.
##
## Замах телеграфируется красной подсветкой через смену material_override.
## Удар (`_strike`) — это **физический выпад через apply_knockback самому себе**:
## скелет реально летит в сторону цели, врезается в неё (тело CharacterBody3D
## блокируется тем же CharacterBody3D башни), отскакивает (через
## Enemy._bounke_off_target), и по пути отбрасывает соседей-скелетов
## (через Enemy._push_neighbor).
## Если получает knockback во время замаха — замах отменяется.
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

@export var attack_windup: float = 0.4  # секунды от «замаха» до удара

@export_group("Strike (физический выпад)")
@export var lunge_speed: float = 8.0  # m/s в момент удара
@export var lunge_duration: float = 0.2  # секунды knockback'а на сам выпад
@export_group("")

static var _shared_normal_material: StandardMaterial3D
static var _shared_windup_material: StandardMaterial3D

var _in_windup: bool = false
var _windup_remaining: float = 0.0


func _ready() -> void:
	# Унаследованный _ready подключает damaged/destroyed к EventBus.
	# Без super._ready() подключение потерялось бы только для скелетов.
	super._ready()
	_ensure_shared_materials()
	var mesh := $MeshInstance3D as MeshInstance3D
	if not mesh:
		return
	# Все скелеты делят два материала на класс — никаких .duplicate() per-instance.
	# Переключение состояния = смена ссылки в material_override → GPU батчит.
	mesh.material_override = _shared_normal_material


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


func _ai_step(delta: float) -> void:
	var target := get_active_target()
	if not target:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	if _in_windup:
		velocity.x = 0.0
		velocity.z = 0.0
		_windup_remaining = maxf(_windup_remaining - delta, 0.0)
		if _windup_remaining <= 0.0:
			_strike()
		return

	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	var dist := to_target.length()

	if dist > attack_range:
		var dir := to_target.normalized()
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		if _attack_cooldown_remaining <= 0.0:
			_start_windup()


func _start_windup() -> void:
	_in_windup = true
	_windup_remaining = attack_windup
	_set_glow(true)


func _strike() -> void:
	_in_windup = false
	_set_glow(false)
	_attack_cooldown_remaining = attack_cooldown
	# Перевыбираем цель — между _ai_step и _strike могла умереть и/или появиться ближе другая.
	var target := get_active_target()
	# Урон — до выпада, потому что после apply_knockback velocity скелета
	# уйдёт в сторону цели и порядок не важен, но логически «удар попал».
	if target and target.has_method("take_damage"):
		target.take_damage(attack_damage)
	_do_lunge()


func _do_lunge() -> void:
	var target := get_active_target()
	if not target:
		return
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < VecUtil.EPSILON_SQ:
		return
	var dir := to_target.normalized()
	# Самостоятельный knockback в сторону цели. Дальше move_and_slide толкает
	# скелета вперёд → коллизия с башней → bounce-off в Enemy._resolve_knockback_contacts.
	apply_knockback(dir * lunge_speed, lunge_duration)


func _on_knockback() -> void:
	# Сбили в замахе — отмена. Скелет должен снова подойти и зарядиться.
	if _in_windup:
		_in_windup = false
		_windup_remaining = 0.0
		_set_glow(false)


func _set_glow(active: bool) -> void:
	var mesh := $MeshInstance3D as MeshInstance3D
	if not mesh:
		return
	# Свап ссылки — никаких чтений/записей свойств материала. Материалы общие,
	# мутировать их per-state нельзя (поломались бы все остальные скелеты).
	mesh.material_override = _shared_windup_material if active else _shared_normal_material
