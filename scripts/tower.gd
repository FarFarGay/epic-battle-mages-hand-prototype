class_name Tower
extends CharacterBody3D
## Башня — управляется WASD.
## Если башня тяжелее, чем встретившийся Item, она толкает его телом при движении.
## Имеет HP — враги наносят урон через take_damage(amount).

## Минимальная компонента intended_velocity в направлении врага, ниже которой
## считаем, что башня в эту сторону не едет — knockback не применяем.
const MIN_PUSH_VELOCITY := 0.1

signal damaged(amount: float)
signal destroyed

@export var move_speed: float = 8.0
@export var gravity: float = 20.0
@export var mass: float = 10.0
@export var hp: float = 1000.0

@export_group("Push Items")
@export var push_strength: float = 1.0

@export_group("Push Enemies")
## Множитель горизонтальной скорости, с которой башня сообщает врагу knockback.
## 1.0 — враг получает свою-же-скорость, 1.5 — чуть быстрее, чтобы выходить из-под башни.
@export var enemy_push_speed_factor: float = 1.5
## Длительность knockback'а врагу. Малое значение, потому что в контакте мы
## refresh'им knockback каждый физкадр.
@export var enemy_push_duration: float = 0.2

@export_group("")
## Высота, ниже которой считаем что башня провалилась под карту.
@export var fall_threshold: float = -10.0
@export var debug_log: bool = true

var _was_on_floor: bool = true
var _last_input_dir: Vector2 = Vector2.ZERO
var _was_stuck: bool = false
# Item -> "push" | "block": набор Item'ов, с которыми сейчас контакт.
# Используется для логов фронт-перехода (старт/смена/конец контакта).
var _contacts_last: Dictionary = {}
var _dying: bool = false

@onready var _floor_normal_threshold: float = cos(get_floor_max_angle())
@onready var _mesh: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	Damageable.register(self)
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	# Локальные сигналы остаются для тесно-связанных слушателей.
	damaged.connect(func(amount: float) -> void: EventBus.tower_damaged.emit(amount))
	destroyed.connect(func() -> void: EventBus.tower_destroyed.emit())


# --- Публичный API ---

func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	hp -= amount
	damaged.emit(amount)
	HitFlash.flash(_mesh)
	if debug_log and LogConfig.master_enabled:
		print("[Tower] получил %.1f урона, hp=%.1f" % [amount, hp])
	if hp <= 0.0:
		_dying = true
		# Замораживаем ввод/физику: WASD больше не двигает тело, slide-коллизии
		# не пересчитываются. Тело остаётся на месте с активной коллизией —
		# скелеты упираются в "стену", но дальнейшие take_damage становятся
		# no-op'ом через ранний return по _dying в начале функции.
		set_physics_process(false)
		velocity = Vector3.ZERO
		# Снимаем флаг damageable: AOE-эффекты (Slam, будущие spells) больше
		# не считают мёртвую башню целью. Сама стенка-коллизия остаётся.
		remove_from_group(Damageable.GROUP)
		destroyed.emit()
		if debug_log and LogConfig.master_enabled:
			print("[Tower] DEAD")
		# Не queue_free — game-over UI будет в следующих итерациях.


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	var input_dir := Vector2.ZERO
	input_dir.x = Input.get_axis("move_left", "move_right")
	input_dir.y = Input.get_axis("move_forward", "move_back")
	input_dir = input_dir.normalized()

	velocity.x = input_dir.x * move_speed
	velocity.z = input_dir.y * move_speed

	# Сохраняем скорость до слайда — после move_and_slide компонент в сторону
	# препятствия обнулится, и факт "шли в предмет" будет потерян.
	var intended_velocity := velocity

	move_and_slide()

	_resolve_contacts(intended_velocity)

	if debug_log and LogConfig.master_enabled:
		_debug_log(input_dir)


func _resolve_contacts(intended_velocity: Vector3) -> void:
	# Items — push с массовым ratio (mass-mediation вшита, единый Pushable
	# не даст условный mass-check). Kinematic-цели (враги) — простой Δv-push
	# через Pushable, без знания конкретного класса.
	var contacts_now: Dictionary = {}

	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		var collider := col.get_collider()
		if collider is Item:
			_push_item(collider as Item, col, intended_velocity, contacts_now)
		elif Pushable.is_pushable(collider) and collider is CharacterBody3D:
			_push_kinematic(collider as Node, col, intended_velocity)
			# В contacts_now kinematic'ов не записываем — для 50+ скелетов получится спам логов.

	if debug_log and LogConfig.master_enabled:
		_log_contact_transitions(contacts_now)
	_contacts_last = contacts_now


func _push_item(item: Item, col: KinematicCollision3D, intended_velocity: Vector3, contacts_now: Dictionary) -> void:
	if item.freeze:
		return
	# Подписка на tree_exited, чтобы не оставлять zombie-ключи в _contacts_last.
	# Используем флаг в meta — bind(item) делает Callable не-сравнимым через is_connected.
	if not item.has_meta(&"_tower_contact_hooked"):
		item.set_meta(&"_tower_contact_hooked", true)
		item.tree_exited.connect(_on_contact_item_exited.bind(item))
	if mass <= item.mass:
		contacts_now[item] = "block"
		return
	contacts_now[item] = "push"
	var push_dir: Vector3 = -col.get_normal()
	var v_into := intended_velocity.dot(push_dir)
	if v_into <= 0.0:
		return
	var item_v_into := item.linear_velocity.dot(push_dir)
	var v_diff := v_into - item_v_into
	if v_diff <= 0.0:
		return
	var ratio: float = clampf((mass - item.mass) / mass, 0.0, 1.0)
	item.apply_central_impulse(push_dir * v_diff * item.mass * ratio * push_strength)


func _push_kinematic(target: Node, col: KinematicCollision3D, intended_velocity: Vector3) -> void:
	var push_dir: Vector3 = -col.get_normal()
	var push_dir_h := VecUtil.horizontal(push_dir)
	if push_dir_h.length_squared() < VecUtil.EPSILON_SQ:
		return
	push_dir_h = push_dir_h.normalized()
	var v_into := intended_velocity.dot(push_dir_h)
	if v_into <= MIN_PUSH_VELOCITY:
		return  # башня не движется в эту сторону — нечего толкать
	Pushable.try_push(target, push_dir_h * v_into * enemy_push_speed_factor, enemy_push_duration)


func _on_contact_item_exited(item: Item) -> void:
	_contacts_last.erase(item)


func _log_contact_transitions(contacts_now: Dictionary) -> void:
	# Новые или изменившиеся контакты
	for item in contacts_now:
		if not is_instance_valid(item):
			continue
		var status: String = contacts_now[item]
		var prev: String = _contacts_last.get(item, "")
		if prev == status:
			continue
		if status == "push":
			print("[Tower] толкаем %s (mass=%.1f)" % [item.name, item.mass])
		else:
			print("[Tower] упёрлись в %s (mass=%.1f ≥ наша %.1f) — не толкнуть" % [item.name, item.mass, mass])
	# Контакты, которых больше нет
	for item in _contacts_last:
		if not contacts_now.has(item):
			if is_instance_valid(item):
				print("[Tower] контакт прекращён: %s" % item.name)


func _debug_log(input_dir: Vector2) -> void:
	var on_floor := is_on_floor()
	var is_moving := input_dir.length_squared() > 0.0
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var is_stuck := is_moving and horizontal_speed < move_speed * 0.1

	# Контакт с полом (фронт изменения)
	if _was_on_floor != on_floor:
		if on_floor:
			print("[Tower] приземление @ y=%.2f" % global_position.y)
		else:
			print("[Tower] оторвались от пола @ y=%.2f" % global_position.y)

	# Любое изменение ввода: старт / стоп / смена направления
	if input_dir != _last_input_dir:
		var p := global_position
		if _last_input_dir.is_zero_approx():
			print("[Tower] старт, input=%s, pos=(%.2f, %.2f, %.2f)" % [input_dir, p.x, p.y, p.z])
		elif input_dir.is_zero_approx():
			print("[Tower] стоп, pos=(%.2f, %.2f, %.2f)" % [p.x, p.y, p.z])
		else:
			print("[Tower] смена направления: %s → %s, pos=(%.2f, %.2f, %.2f)" % [_last_input_dir, input_dir, p.x, p.y, p.z])
		_last_input_dir = input_dir

	# Подозрительно: пытаемся идти, но скорость почти нулевая (фронт)
	if is_stuck and not _was_stuck:
		printerr("[Tower] застряли: input=%s, h_speed=%.2f" % [input_dir, horizontal_speed])

	# Коллизии со стенами (не пол, не Item, не kinematic-pushable —
	# Item уже залогирован в _push_item, kinematic'и (враги) спамили бы при толпе).
	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		var n := col.get_normal()
		if n.y > _floor_normal_threshold:
			continue
		var collider := col.get_collider()
		if collider is Item:
			continue
		if Pushable.is_pushable(collider) and collider is CharacterBody3D:
			continue
		var collider_name := str(collider.name) if collider else "?"
		print("[Tower] коллизия со стеной: %s, normal=(%.2f, %.2f, %.2f)" % [collider_name, n.x, n.y, n.z])

	# Провалились ниже карты
	if global_position.y < fall_threshold:
		printerr("[Tower] провалились ниже карты: y=%.2f" % global_position.y)

	_was_on_floor = on_floor
	_was_stuck = is_stuck
