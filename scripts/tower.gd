extends CharacterBody3D
## Башня — управляется WASD.
## Если башня тяжелее, чем встретившийся Item, она толкает его телом при движении.

@export var move_speed: float = 8.0
@export var gravity: float = 20.0
@export var mass: float = 10.0
@export var push_strength: float = 1.0
@export var debug_log: bool = true

var _was_on_floor: bool = true
var _last_input_dir: Vector2 = Vector2.ZERO
var _was_stuck: bool = false
# Item -> "push" | "block": набор Item'ов, с которыми сейчас контакт.
# Используется для логов фронт-перехода (старт/смена/конец контакта).
var _contacts_last: Dictionary = {}


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

	_push_items(intended_velocity)

	if debug_log:
		_debug_log(input_dir)


func _push_items(intended_velocity: Vector3) -> void:
	var contacts_now: Dictionary = {}

	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		var collider := col.get_collider()
		if not (collider is Item):
			continue
		var item := collider as Item
		if item.freeze:
			continue

		if mass <= item.mass:
			contacts_now[item] = "block"
			continue

		contacts_now[item] = "push"
		var push_dir: Vector3 = -col.get_normal()
		var v_into := intended_velocity.dot(push_dir)
		if v_into <= 0.0:
			continue
		var item_v_into := item.linear_velocity.dot(push_dir)
		var v_diff := v_into - item_v_into
		if v_diff <= 0.0:
			continue
		var ratio: float = clampf((mass - item.mass) / mass, 0.0, 1.0)
		item.apply_central_impulse(push_dir * v_diff * item.mass * ratio * push_strength)

	if debug_log:
		_log_contact_transitions(contacts_now)
	_contacts_last = contacts_now


func _log_contact_transitions(contacts_now: Dictionary) -> void:
	# Новые или изменившиеся контакты
	for item in contacts_now:
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

	# Коллизии со стенами (не пол, не Item — Item уже залогирован в _push_items)
	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		var n := col.get_normal()
		if n.y > 0.7:
			continue
		var collider := col.get_collider()
		if collider is Item:
			continue
		var collider_name := str(collider.name) if collider else "?"
		print("[Tower] коллизия со стеной: %s, normal=(%.2f, %.2f, %.2f)" % [collider_name, n.x, n.y, n.z])

	# Провалились ниже карты
	if global_position.y < -10.0:
		printerr("[Tower] провалились ниже карты: y=%.2f" % global_position.y)

	_was_on_floor = on_floor
	_was_stuck = is_stuck
