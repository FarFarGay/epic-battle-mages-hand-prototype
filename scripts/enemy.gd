class_name Enemy
extends CharacterBody3D
## Базовый класс врага. Подклассы реализуют конкретный strike в _perform_strike(target).
##
## FSM (минимальный): APPROACH → WINDUP → STRIKE → COOLDOWN → APPROACH.
## Базовая реализация в _ai_step рулит переходами и таймером _state_timer.
## Подкласс override'ит _perform_strike(target) — там и удар, и любые телеграфы
## (через _on_state_enter/_on_state_exit, если нужно).
##
## Базовые константы вынесены ниже:
## - MIN_NEIGHBOR_PUSH_SPEED — порог скорости, ниже которого
##   knockback не передаётся соседу (контакт «соскользнул», а не «врезался»).
##
## Контракт:
## - take_damage(amount) — общий «damageable»-интерфейс (через Damageable.register).
## - apply_push(velocity_change, duration) — общий «pushable»-интерфейс.
## - apply_knockback(impulse, duration) — внешний толчок, на время отключает AI.
##   Подклассы могут реагировать через _on_knockback().
## - set_target(node) / set_targets(array) — цель → набор целей; AI выбирает
##   ближайшую валидную через get_active_target() (мёртвые автоматически
##   пропускаются, ручная чистка не нужна).
##
## Сигналы:
## - damaged(amount), destroyed — для UI / эффектов / счётчиков.
##
## Knockback-контакты (_resolve_knockback_contacts):
## - Если в knockback'е и врезались в активную цель — bounce-off (elastic).
## - Если в knockback'е и задели другого Enemy — толкаем его пропорциональным mini-knockback'ом.

signal damaged(amount: float)
signal destroyed

const MIN_NEIGHBOR_PUSH_SPEED := 0.5

enum AttackState { APPROACH, WINDUP, STRIKE, COOLDOWN }

@export var hp: float = 30.0
@export var move_speed: float = 4.0
@export var gravity: float = 20.0
@export var attack_range: float = 1.5
@export var attack_damage: float = 5.0
@export var attack_cooldown: float = 1.0
@export var attack_windup: float = 0.4
## Замедление knockback-скорости в секунду (lerp coefficient × delta).
@export var knockback_friction: float = 5.0

@export_group("Knockback contacts")
## Коэффициент отскока от активной цели при ударе в knockback'е (0 — без отскока, 1 — полный возврат).
@export_range(0.0, 1.5) var bounce_restitution: float = 0.6
## Доля собственной скорости, передаваемая соседу-Enemy при контакте в knockback'е.
@export_range(0.0, 1.0) var neighbor_push_factor: float = 0.5
@export var neighbor_push_duration: float = 0.15

@export_group("Effects")
## Куда складывать визуальные эффекты смерти (осколки и т.п.). Пусто → current_scene.
@export_node_path("Node") var effects_root_path: NodePath

@export_group("")

var _targets: Array[Node3D] = []
var _state: int = AttackState.APPROACH
var _state_timer: float = 0.0
var _knockback := KnockbackState.new()
var _dying: bool = false

var _effects_root: Node = null


func _ready() -> void:
	# Подклассы, override'ящие _ready, ОБЯЗАНЫ звать super._ready(), иначе
	# damageable/pushable-регистрация и re-emit на EventBus не подключатся.
	# Self-доку по слоям: layer=Layers.ENEMIES, mask=Layers.MASK_SKELETON
	# (значения литералами в .tscn — Godot хранит маски как ints).
	Damageable.register(self)
	Pushable.register(self)
	# Группы выставлены прямо выше — assert один раз в _ready, а не каждый
	# физкадр на каждом враге (был spam в editor-сборке при 50 скелетах).
	assert(is_in_group(Damageable.GROUP), "Enemy: Damageable не зарегистрирован")
	assert(is_in_group(Pushable.GROUP), "Enemy: Pushable не зарегистрирован")
	_knockback.friction = knockback_friction
	# _effects_root: явный path → ноду; пустой/неразрешённый → fallback на
	# current_scene с warning'ом, чтобы tihaja поломка эффектов смерти не пряталась.
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
		if _effects_root == null:
			push_warning("Enemy: effects_root_path не разрешился, fallback на current_scene")
	if _effects_root == null:
		_effects_root = get_tree().current_scene
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	# Локальные сигналы остаются для тесно-связанных слушателей.
	damaged.connect(func(amount: float) -> void: EventBus.enemy_damaged.emit(self, amount))
	destroyed.connect(func() -> void: EventBus.enemy_destroyed.emit(self))


# --- Публичный API ---

## Назначить набор кандидатов в цели. Самая близкая из живых выбирается каждый кадр.
func set_targets(targets: Array[Node3D]) -> void:
	_targets = targets


## Удобная обёртка для случая «одна цель» — оборачивает в массив.
func set_target(target: Node3D) -> void:
	var new_targets: Array[Node3D] = []
	if target:
		new_targets.append(target)
	_targets = new_targets


## Возвращает ближайшую валидную цель, либо null. Невалидные (queue_free)
## пропускаются, поэтому ручная чистка списка не нужна.
func get_active_target() -> Node3D:
	var nearest: Node3D = null
	var nearest_dist_sq := INF
	for t in _targets:
		if not is_instance_valid(t):
			continue
		var d_sq: float = (t.global_position - global_position).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = t
	return nearest


func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	hp -= amount
	damaged.emit(amount)
	if hp <= 0.0:
		_dying = true
		destroyed.emit()
		_on_destroyed()
		queue_free()


func apply_knockback(impulse: Vector3, duration: float) -> void:
	# Внешний knockback: заменяем горизонтальную скорость, вертикаль накладываем
	# поверх, и дёргаем _on_knockback хук (подкласс может сбить замах и т.п.).
	_apply_velocity_change(impulse, duration)
	_on_knockback()


## Pushable-контракт: делегат к apply_knockback.
func apply_push(velocity_change: Vector3, duration: float) -> void:
	apply_knockback(velocity_change, duration)


## Низкоуровневая запись velocity + knockback-таймера БЕЗ хука _on_knockback.
## Используется подклассами для self-knockback (lunge), чтобы свой же удар
## не сбивал собственное FSM-состояние через хук.
func _apply_velocity_change(impulse: Vector3, duration: float) -> void:
	velocity = KnockbackState.compose(velocity, impulse)
	_knockback.start(duration)


# --- Цикл ---

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	# Кулдаун-таймер (после удара) тикает всегда, даже в knockback'е, иначе
	# самонанесённый lunge-knockback искусственно удлинял бы атак-цикл.
	if _state == AttackState.COOLDOWN and _state_timer > 0.0:
		_state_timer = maxf(_state_timer - delta, 0.0)

	_knockback.tick(delta)
	if _knockback.is_active():
		# AI заглушен; horizon decays к нулю — knockback затухает.
		velocity = _knockback.apply_friction(velocity, delta)
	else:
		_ai_step(delta)

	# Запоминаем скорость ДО slide'а: после move_and_slide компонент в стенку
	# обнуляется, и без этого мы не сможем посчитать «как сильно врезались».
	var pre_slide_velocity := velocity
	move_and_slide()

	# Пост-slide: пока в knockback'е, разруливаем удары о цель и соседей.
	if _knockback.is_active():
		_resolve_knockback_contacts(pre_slide_velocity)


# Базовый FSM: APPROACH → WINDUP → STRIKE → COOLDOWN → APPROACH.
# Подклассы override'ят _perform_strike; обычно _ai_step переопределять не надо.
func _ai_step(delta: float) -> void:
	var target := get_active_target()
	if not target:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	# Кулдаун тикается выше (даже в knockback'е); WINDUP — только тут.
	if _state == AttackState.WINDUP and _state_timer > 0.0:
		_state_timer = maxf(_state_timer - delta, 0.0)

	match _state:
		AttackState.APPROACH:
			_approach_target(target)
		AttackState.WINDUP:
			velocity.x = 0.0
			velocity.z = 0.0
			if _state_timer <= 0.0:
				_enter_state(AttackState.STRIKE)
				_perform_strike(target)
				_enter_state(AttackState.COOLDOWN)
		AttackState.STRIKE:
			# Транзитное состояние; обычно сразу переключается в COOLDOWN
			# в той же ветке выше. Если подкласс задержался — едем по инерции.
			pass
		AttackState.COOLDOWN:
			velocity.x = 0.0
			velocity.z = 0.0
			if _state_timer <= 0.0:
				_enter_state(AttackState.APPROACH)


func _approach_target(target: Node3D) -> void:
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
		_enter_state(AttackState.WINDUP)


func _enter_state(new_state: int) -> void:
	_on_state_exit(_state)
	_state = new_state
	match new_state:
		AttackState.WINDUP:
			_state_timer = attack_windup
		AttackState.COOLDOWN:
			_state_timer = attack_cooldown
		_:
			_state_timer = 0.0
	_on_state_enter(new_state)


# Виртуальный: конкретный удар. Урон цели + любые физические выпады.
func _perform_strike(_target: Node3D) -> void:
	pass


# Виртуальные хуки для телеграфа замаха и т.п.
func _on_state_enter(_new_state: int) -> void:
	pass


func _on_state_exit(_old_state: int) -> void:
	pass


# Виртуальный хук: вызывается, когда кто-то снаружи нанёс knockback.
# В WINDUP сбиваем замах → APPROACH. В COOLDOWN таймер кулдауна сохраняется
# (тикает в _physics_process), не сбрасываем. STRIKE транзитное.
func _on_knockback() -> void:
	if _state == AttackState.WINDUP:
		_on_state_exit(_state)
		_state = AttackState.APPROACH
		_state_timer = 0.0


# Виртуальный хук: вызывается ровно перед queue_free на смерти, после destroyed.emit.
# Подклассы могут спавнить визуальные эффекты смерти (осколки, частицы) — они
# добавляются в _effects_root и переживают самого врага.
func _on_destroyed() -> void:
	pass


# --- Knockback-контакты ---

func _resolve_knockback_contacts(pre_slide_velocity: Vector3) -> void:
	var active := get_active_target()
	var target_normal_sum := Vector3.ZERO
	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		var collider := col.get_collider()
		if active and collider == active:
			target_normal_sum += col.get_normal()
		elif collider is Enemy and collider != self:
			_push_neighbor(collider as Enemy, col, pre_slide_velocity)
	if target_normal_sum.length_squared() > 0.0:
		_bounce_off_target(target_normal_sum.normalized(), pre_slide_velocity)


func _bounce_off_target(normal: Vector3, pre_slide_velocity: Vector3) -> void:
	# normal указывает ОТ цели на нас. Компонент pre_slide_velocity в направлении
	# (−normal), то есть «в цель», и есть скорость удара. После move_and_slide эта
	# компонента уже занулена, поэтому ДОБАВЛЯЕМ обратный импульс величины
	# pre_into * restitution — это и даёт упругий отскок.
	var into_dir := VecUtil.horizontal(-normal)
	if into_dir.length_squared() < VecUtil.EPSILON_SQ:
		return
	into_dir = into_dir.normalized()
	var pre_into := pre_slide_velocity.dot(into_dir)
	if pre_into <= 0.0:
		return  # не врезались, а скользили вдоль — отскакивать не от чего
	velocity += -into_dir * pre_into * bounce_restitution


func _push_neighbor(other: Enemy, col: KinematicCollision3D, pre_slide_velocity: Vector3) -> void:
	var pre_horizontal_speed := Vector2(pre_slide_velocity.x, pre_slide_velocity.z).length()
	if pre_horizontal_speed < MIN_NEIGHBOR_PUSH_SPEED:
		return
	var push_dir := VecUtil.horizontal(-col.get_normal())
	if push_dir.length_squared() < VecUtil.EPSILON_SQ:
		return
	push_dir = push_dir.normalized()
	Pushable.try_push(other, push_dir * pre_horizontal_speed * neighbor_push_factor, neighbor_push_duration)
