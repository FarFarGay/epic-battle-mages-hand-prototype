class_name Skeleton
extends Enemy
## Простой враг.
## Жизненный цикл: APPROACH → (в attack_range) WINDUP → STRIKE → COOLDOWN → APPROACH.
##
## Замах телеграфируется красной подсветкой на собственном материале.
## Удар (`_strike`) — это **физический выпад через apply_knockback самому себе**:
## скелет реально летит в сторону цели, врезается в неё (тело CharacterBody3D
## блокируется тем же CharacterBody3D башни), отскакивает (через
## Enemy._bounce_off_target), и по пути отбрасывает соседей-скелетов
## (через Enemy._push_neighbor).
## Если получает knockback во время замаха — замах отменяется.

@export var windup_color: Color = Color(1.0, 0.2, 0.2, 1.0)
@export_range(0.0, 5.0) var windup_intensity: float = 1.5
@export var attack_windup: float = 0.4  # секунды от «замаха» до удара

@export_group("Strike (физический выпад)")
@export var lunge_speed: float = 8.0  # m/s в момент удара
@export var lunge_duration: float = 0.2  # секунды knockback'а на сам выпад
@export_group("")

var _material: StandardMaterial3D
var _in_windup: bool = false
var _windup_remaining: float = 0.0


func _ready() -> void:
	# Уникализируем материал: иначе emission поменяется одновременно у всех скелетов,
	# использующих общий `material_override` из skeleton.tscn (а их у нас 50+).
	var mesh := $MeshInstance3D as MeshInstance3D
	if mesh and mesh.material_override is StandardMaterial3D:
		_material = (mesh.material_override as StandardMaterial3D).duplicate()
		mesh.material_override = _material


func _ai_step(delta: float) -> void:
	if not _target or not is_instance_valid(_target):
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

	var to_target: Vector3 = _target.global_position - global_position
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
	# Урон — до выпада, потому что после apply_knockback velocity скелета
	# уйдёт в сторону цели и порядок не важен, но логически «удар попал».
	if _target and is_instance_valid(_target) and _target.has_method("take_damage"):
		_target.take_damage(attack_damage)
	_do_lunge()


func _do_lunge() -> void:
	if not _target or not is_instance_valid(_target):
		return
	var to_target: Vector3 = _target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
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
	if not _material:
		return
	if active:
		_material.emission_enabled = true
		_material.emission = windup_color
		_material.emission_energy_multiplier = windup_intensity
	else:
		_material.emission_enabled = false
