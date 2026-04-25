class_name Enemy
extends CharacterBody3D
## Базовый класс врага. Подклассы реализуют конкретное поведение в _ai_step(delta).
##
## Контракт:
## - take_damage(amount) — общий «damageable»-интерфейс (как у Item).
## - apply_knockback(impulse, duration) — внешний толчок, на время отключает AI.
##   Подклассы могут реагировать через _on_knockback().
## - set_target(node) — кого преследовать; используется AI в подклассах.
##
## Сигналы:
## - damaged(amount), died — для UI / эффектов / счётчиков.
##
## Knockback-контакты (_resolve_knockback_contacts):
## - Если в knockback'е и врезались в _target — bounce-off (elastic).
## - Если в knockback'е и задели другого Enemy — толкаем его пропорциональным mini-knockback'ом.

signal damaged(amount: float)
signal died

@export var hp: float = 30.0
@export var move_speed: float = 4.0
@export var gravity: float = 20.0
@export var attack_range: float = 1.5
@export var attack_damage: float = 5.0
@export var attack_cooldown: float = 1.0
## Замедление knockback-скорости в секунду (lerp coefficient × delta).
@export var knockback_friction: float = 5.0

@export_group("Knockback contacts")
## Коэффициент отскока от _target при ударе в knockback'е (0 — без отскока, 1 — полный возврат).
@export_range(0.0, 1.5) var bounce_restitution: float = 0.6
## Доля собственной скорости, передаваемая соседу-Enemy при контакте в knockback'е.
@export_range(0.0, 1.0) var neighbor_push_factor: float = 0.5
@export var neighbor_push_duration: float = 0.15

@export_group("")

var _target: Node3D = null
var _attack_cooldown_remaining: float = 0.0
var _knockback_timer: float = 0.0
var _dying: bool = false


# --- Публичный API ---

func set_target(target: Node3D) -> void:
	_target = target


func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	hp -= amount
	damaged.emit(amount)
	if hp <= 0.0:
		_dying = true
		died.emit()
		queue_free()


func apply_knockback(impulse: Vector3, duration: float) -> void:
	# Заменяем горизонтальную скорость, вертикаль накладываем поверх.
	velocity.x = impulse.x
	velocity.z = impulse.z
	velocity.y = max(velocity.y, impulse.y)
	_knockback_timer = duration
	_on_knockback()


# --- Цикл ---

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	# Кулдаун аттаки тикает всегда (в т.ч. в knockback'е), иначе бэксайд цикла растёт.
	if _attack_cooldown_remaining > 0.0:
		_attack_cooldown_remaining = maxf(_attack_cooldown_remaining - delta, 0.0)

	if _knockback_timer > 0.0:
		_knockback_timer = maxf(_knockback_timer - delta, 0.0)
		# AI заглушен; сглаживаем горизонталь к нулю — knockback затухает.
		velocity.x = lerpf(velocity.x, 0.0, knockback_friction * delta)
		velocity.z = lerpf(velocity.z, 0.0, knockback_friction * delta)
	else:
		_ai_step(delta)

	# Запоминаем скорость ДО slide'а: после move_and_slide компонент в стенку
	# обнуляется, и без этого мы не сможем посчитать «как сильно врезались».
	var pre_slide_velocity := velocity
	move_and_slide()

	# Пост-slide: пока в knockback'е, разруливаем удары о цель и соседей.
	if _knockback_timer > 0.0:
		_resolve_knockback_contacts(pre_slide_velocity)


# Override в подклассах. Должен задать velocity.x/z; вертикалью занимается база.
func _ai_step(_delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0


# Виртуальный хук: вызывается, когда кто-то снаружи нанёс knockback.
# Подклассы могут сбросить локальное состояние (например, отменить замах атаки).
func _on_knockback() -> void:
	pass


# --- Knockback-контакты ---

func _resolve_knockback_contacts(pre_slide_velocity: Vector3) -> void:
	var bounced_off_target := false
	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		var collider := col.get_collider()
		if not bounced_off_target and _target and collider == _target:
			_bounce_off_target(col.get_normal(), pre_slide_velocity)
			bounced_off_target = true
		elif collider is Enemy and collider != self:
			_push_neighbor(collider as Enemy, col, pre_slide_velocity)


func _bounce_off_target(normal: Vector3, pre_slide_velocity: Vector3) -> void:
	# normal указывает ОТ цели на нас. Компонент pre_slide_velocity в направлении
	# (−normal), то есть «в цель», и есть скорость удара. После move_and_slide эта
	# компонента уже занулена, поэтому ДОБАВЛЯЕМ обратный импульс величины
	# pre_into * restitution — это и даёт упругий отскок.
	var into_dir := Vector3(-normal.x, 0.0, -normal.z)
	if into_dir.length_squared() < 0.0001:
		return
	into_dir = into_dir.normalized()
	var pre_into := pre_slide_velocity.dot(into_dir)
	if pre_into <= 0.0:
		return  # не врезались, а скользили вдоль — отскакивать не от чего
	velocity += -into_dir * pre_into * bounce_restitution


func _push_neighbor(other: Enemy, col: KinematicCollision3D, pre_slide_velocity: Vector3) -> void:
	var pre_horizontal_speed := Vector2(pre_slide_velocity.x, pre_slide_velocity.z).length()
	if pre_horizontal_speed < 0.5:
		return
	var push_dir := Vector3(-col.get_normal().x, 0.0, -col.get_normal().z)
	if push_dir.length_squared() < 0.0001:
		return
	push_dir = push_dir.normalized()
	other.apply_knockback(push_dir * pre_horizontal_speed * neighbor_push_factor, neighbor_push_duration)
