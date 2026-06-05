class_name Tower
extends CharacterBody3D
## Башня — управляется WASD.
## Если башня тяжелее, чем встретившийся Item, она толкает его телом при движении.
## Имеет HP — враги наносят урон через take_damage(amount).

## Минимальная компонента intended_velocity в направлении врага, ниже которой
## считаем, что башня в эту сторону не едет — knockback не применяем.
const MIN_PUSH_VELOCITY := 0.1

## Группа для дискаверинга башни без NodePath. HandSpellFireball спавнит
## фаербол из позиции башни (Tower не один в сцене теоретически — если
## когда-то появится мульти-башня, get_first_node_in_group вернёт первого,
## фаербол всё равно стартует из «какой-то» башни — приемлемо для прототипа).
const GROUP := &"tower"

signal damaged(amount: float)
signal destroyed
## Текущий HP изменился (например, после take_damage). Используется HUD'ом
## для отрисовки полоски здоровья. Стартовый emit идёт из _ready.
signal health_changed(current: float, maximum: float)
## Текущая мана изменилась — потрачена касто́м или восстановлена реген'ом.
## HUD рисует полоску маны, hand_spell_fireball.gd дёргает try_consume_mana.
signal mana_changed(current: float, maximum: float)

@export var move_speed: float = 8.0
@export var gravity: float = 20.0
@export var mass: float = 10.0
## Максимум HP. Текущее значение в `hp`, сетится в _ready = max_hp. Урон —
## через take_damage(amount). Смерть при hp ≤ 0.
@export var max_hp: float = 1000.0

@export_group("Mana")
## Максимум маны. Магические действия (Fireball и т.п.) тратят её через
## try_consume_mana. Физика руки (Slam/Flick/grab) маны не требует.
@export var max_mana: float = 100.0
## Скорость регенерации маны, единиц в секунду. 10 даёт ~10с до полного
## реcтора после 4 кастов фаербола (cost=25 каждый).
@export var mana_regen_rate: float = 10.0

@export_group("Push Items")
@export var push_strength: float = 1.0

@export_group("Push Enemies")
## Множитель горизонтальной скорости, с которой башня сообщает врагу knockback.
## 1.0 — враг получает свою-же-скорость, 1.5 — чуть быстрее, чтобы выходить из-под башни.
@export var enemy_push_speed_factor: float = 1.5
## Длительность knockback'а врагу. Малое значение, потому что в контакте мы
## refresh'им knockback каждый физкадр.
@export var enemy_push_duration: float = 0.2

@export_group("Dash (рывок, Space)")
## Скорость броска (м/с) — заметно выше move_speed. Рывок перекрывает обычное
## движение на dash_duration.
@export var dash_speed: float = 22.0
## Длительность активной фазы рывка (сек). dash_speed × dash_duration ≈ путь
## (22 × 0.24 ≈ 5.3м).
@export var dash_duration: float = 0.24
## Кулдаун между рывками (сек).
@export var dash_cooldown: float = 0.8
## Трейл: спавнить after-image-призраки во время рывка. Сам визуал рывка (наклон/
## стретч/призраки) — общий с врагом-мехом, см. [DashFx] (тюнинг там).
@export var dash_trail_enabled: bool = true

@export_group("")
## Высота, ниже которой считаем что башня провалилась под карту.
@export var fall_threshold: float = -10.0
@export var debug_log: bool = true

var _was_on_floor: bool = true
var _last_input_dir: Vector2 = Vector2.ZERO
var _was_stuck: bool = false
## Рывок (Space): остаток активной фазы, кулдаун, зафиксированное направление.
var _dash_timer: float = 0.0
var _dash_cd: float = 0.0
var _dash_dir: Vector2 = Vector2.ZERO
## Сглаженная интенсивность dash-визуала (наклон/стретч): плавно 0↔1 — нет рывка
## в самом эффекте при старте/конце рывка. Таймер спавна призраков трейла.
var _dash_fx: float = 0.0
var _dash_ghost_t: float = 0.0
## Замедление от вражеского темпорального поля (SlowField): фактор скорости (1 =
## норма, <1 = медленнее) и время действия (мс). Сильнейшее перекрывает, пока
## активно; рефрешится полем каждый тик, пока башня внутри.
var _slow_factor: float = 1.0
var _slow_until_msec: int = 0
## Knockback от тарана врага-меха: вектор отброса (XZ) и время действия (мс). Пока
## активен — перебивает ввод и рывок (башню отбрасывает, управление возвращается
## по затуханию). Зеркало Enemy-knockback, но на игрока.
var _kb_vel: Vector3 = Vector3.ZERO
var _kb_until_msec: int = 0
# Item -> "push" | "block": набор Item'ов, с которыми сейчас контакт.
# Используется для логов фронт-перехода (старт/смена/конец контакта).
var _contacts_last: Dictionary = {}
var _dying: bool = false

## Текущий HP. Init = max_hp в _ready. Меняется только через take_damage.
var hp: float = 0.0
## Текущая мана. Init = max_mana в _ready. Регенерится в _physics_process,
## тратится через try_consume_mana.
var mana: float = 0.0

@onready var _floor_normal_threshold: float = cos(get_floor_max_angle())
@onready var _mesh: MeshInstance3D = $VisualRoot/MeshInstance3D
@onready var _visual_root: Node3D = $VisualRoot

## Motion-feedback в caravan-mode. Tower — большое тяжёлое здание, эффекты
## мелкие (амплитуды ≈половина палаточных), но дают «вес» при езде. На
## stationary tower (стоит, lend не двигается) speed_norm ≈ 0 → fx гаснет.
var _motion_fx: SegmentMotionFx = null
var _visual_base_y: float = 0.0
var _visual_base_basis: Basis = Basis()


func _ready() -> void:
	add_to_group(GROUP)
	Damageable.register(self)
	# Источник геометрии для NavMesh — башня препятствие, гномы её обходят.
	add_to_group(&"navmesh_source")
	hp = max_hp
	mana = max_mana
	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	# Локальные сигналы остаются для тесно-связанных слушателей.
	destroyed.connect(func() -> void: EventBus.tower_destroyed.emit())
	health_changed.connect(func(current: float, maximum: float) -> void: EventBus.tower_health_changed.emit(current, maximum))
	mana_changed.connect(func(current: float, maximum: float) -> void: EventBus.tower_mana_changed.emit(current, maximum))
	# Стартовый sync HUD'у: emit'им текущие значения после connect'а — HUD
	# подписывается на EventBus в своём _ready, поэтому даже если он ready'ится
	# раньше Tower'а, сначала возьмёт snapshot через get_first_node_in_group.
	health_changed.emit(hp, max_hp)
	mana_changed.emit(mana, max_mana)
	# Motion-fx: bobbing/tilt/squash-stretch на VisualRoot.
	if _visual_root != null:
		_visual_base_y = _visual_root.position.y
		_visual_base_basis = _visual_root.basis
		_motion_fx = SegmentMotionFx.new()
		# Мелкие амплитуды — башня тяжёлая, не картон. Низкая частота bob'а
		# (1.5 Гц) даёт «медленный шаг» здания.
		_motion_fx.bob_amplitude = 0.04
		_motion_fx.bob_frequency = 1.5
		# Заметнее вытягивается при движении (запрос на «импакт»); dash добавляет
		# сверху свой сильный стретч/наклон (см. _process).
		_motion_fx.stretch_factor = 0.09
		_motion_fx.ss_response = 4.5
		_motion_fx.speed_reference = move_speed
		_motion_fx.reset(global_position)


# --- Публичный API ---

func take_damage(amount: float) -> void:
	if _dying or amount <= 0.0:
		return
	hp -= amount
	damaged.emit(amount)
	health_changed.emit(maxf(hp, 0.0), max_hp)
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


## Пытается списать ману. Возвращает true если хватило (и mana уменьшилась
## на amount). Иначе false — caller отказывается от действия. Mana не идёт
## в минус.
func try_consume_mana(amount: float) -> bool:
	if amount <= 0.0:
		return true
	if _dying or mana < amount:
		return false
	mana -= amount
	mana_changed.emit(mana, max_mana)
	return true


## Замедление от вражеского темпорального поля (SlowField зовёт каждый тик, пока
## башня внутри). factor: 1 = норма, 0.45 ≈ «вдвое медленнее». Сильнейшее (меньший
## factor) перекрывает, пока активно; until продлевается. Скейлит ходьбу И рывок
## (см. _physics_process). На мёртвой башне — no-op.
func apply_movement_slow(factor: float, duration: float) -> void:
	if _dying:
		return
	var now: int = Time.get_ticks_msec()
	var f: float = clampf(factor, 0.05, 1.0)
	if now < _slow_until_msec:
		_slow_factor = minf(_slow_factor, f)
	else:
		_slow_factor = f
	_slow_until_msec = maxi(_slow_until_msec, now + int(duration * 1000.0))


## Отброс от тарана врага-меха. vel — горизонтальная скорость отброса (м/с),
## duration — сколько перебивать управление (сек). На мёртвой башне — no-op.
func apply_knockback(vel: Vector3, duration: float) -> void:
	if _dying:
		return
	_kb_vel = Vector3(vel.x, 0.0, vel.z)
	_kb_until_msec = Time.get_ticks_msec() + int(duration * 1000.0)


## Сейчас ли башня под замедлением темпорального поля (для меха: «окно наказания»
## — пока поймана, стреляем бодрее).
func is_movement_slowed() -> bool:
	return Time.get_ticks_msec() < _slow_until_msec


func _process(delta: float) -> void:
	if _motion_fx == null or _visual_root == null:
		return
	var fx: Dictionary = _motion_fx.tick(global_position, delta)
	var vbasis: Basis = _visual_base_basis * (fx["basis"] as Basis)
	# Dash-juice (общий с врагом-мехом, см. DashFx): наклон вперёд + вытягивание
	# вдоль рывка поверх motion_fx. _dash_fx плавно 0↔1 (нет щелчка). World-space
	# (башня не вращается) — домножаем слева.
	var target_fx: float = 1.0 if _dash_timer > 0.0 else 0.0
	_dash_fx = lerpf(_dash_fx, target_fx, 1.0 - exp(-DashFx.FX_RATE * delta))
	var dir: Vector3 = Vector3(_dash_dir.x, 0.0, _dash_dir.y)
	vbasis = DashFx.dash_basis(dir, _dash_fx) * vbasis
	_visual_root.position.y = _visual_base_y + (fx["bob_y"] as float)
	_visual_root.basis = vbasis
	# Трейл: призраки с интервалом, пока идёт рывок.
	if _dash_fx > 0.005 and dash_trail_enabled:
		_dash_ghost_t -= delta
		if _dash_ghost_t <= 0.0:
			_dash_ghost_t = DashFx.GHOST_INTERVAL
			DashFx.spawn_ghost(get_tree().current_scene, _mesh, dir)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	# Регенерация маны: только до max_mana, эмитим только когда реально
	# изменилось (внутри cap), чтобы не дёргать HUD каждый кадр на full mana.
	if not _dying and mana < max_mana:
		var prev: float = mana
		mana = minf(mana + mana_regen_rate * delta, max_mana)
		if mana != prev:
			mana_changed.emit(mana, max_mana)

	var input_dir := Vector2.ZERO
	input_dir.x = Input.get_axis("move_left", "move_right")
	input_dir.y = Input.get_axis("move_forward", "move_back")
	input_dir = input_dir.normalized()
	# Запоминаем последнее направление движения — для рывка «стоя».
	if input_dir != Vector2.ZERO:
		_last_input_dir = input_dir

	# Рывок (Space): короткий бросок с кулдауном в направлении движения (или в
	# последнее, если стоим). Перекрывает обычную скорость на dash_duration.
	_dash_cd = maxf(_dash_cd - delta, 0.0)
	if _dash_timer <= 0.0 and _dash_cd <= 0.0 and not _dying and Input.is_action_just_pressed("dash"):
		var ddir := input_dir if input_dir != Vector2.ZERO else _last_input_dir
		if ddir != Vector2.ZERO:
			_dash_dir = ddir
			_dash_timer = dash_duration
			_dash_cd = dash_cooldown
			_dash_ghost_t = 0.0  # первый призрак трейла — сразу

	# Knockback от тарана меха перебивает всё: пока активен — башню отбрасывает
	# (ввод/рывок игнорируются), сила затухает, потом управление возвращается.
	if Time.get_ticks_msec() < _kb_until_msec:
		velocity.x = _kb_vel.x
		velocity.z = _kb_vel.z
		_dash_timer = maxf(_dash_timer - delta, 0.0)  # не копим рывок под отбросом
		_kb_vel = _kb_vel.lerp(Vector3.ZERO, 1.0 - exp(-8.0 * delta))
	else:
		# Замедление от вражеского темпорального поля (SlowField): скейлит И ходьбу,
		# И рывок (рывок «ослаблен» — короче, но не выключен). Истёкло → factor=1.
		var slow: float = 1.0
		if Time.get_ticks_msec() < _slow_until_msec:
			slow = _slow_factor
		else:
			_slow_factor = 1.0

		if _dash_timer > 0.0:
			_dash_timer -= delta
			velocity.x = _dash_dir.x * dash_speed * slow
			velocity.z = _dash_dir.y * dash_speed * slow
		else:
			velocity.x = input_dir.x * move_speed * slow
			velocity.z = input_dir.y * move_speed * slow

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
