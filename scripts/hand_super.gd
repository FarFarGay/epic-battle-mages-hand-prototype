class_name HandSuper
extends Node
## Координатор «супер-удара» (ковровой бомбардировки фаерболами). Отдельная
## ось от Physical/Magic — не равноправный equip, а одноразовый каст с
## QTE-предусловием:
##   1. Игрок копит шкалу «великой силы» в Camp (через damage по врагам).
##   2. На full + нажат Space → переход в SUPER-категорию + slow-mo +
##      QTE-overlay с паттерном из точек.
##   3. Прошёл QTE → возврат к нормальному времени, AIMING_TARGET (курсор
##      на земле). ПКМ ставит дождь фаерболов в эту точку.
##   4. Списывается полная шкала.
##   5. Провал QTE (отпустил рано / задел не ту / тайм-аут / ESC) →
##      возврат к нормальному времени, списывается половина шкалы.
##
## **Архитектурно: НЕ часть HandSpell**, чтобы не делить с Fireball/Firestorm
## единственный equipped-слот и не ломать ПКМ-семантику. SUPER — третья
## категория, перехватывает контроль на время каста и возвращает потом.

signal super_cast(at_position: Vector3)

const ACTION_TRIGGER := &"cast_super"
const ACTION_AIM_RELEASE := &"hand_action"  # ПКМ — ставит дождь

enum State { READY, AIMING_PATTERN, AIMING_TARGET, CASTING }

@export_group("QTE")
## Сколько точек должен пройти игрок в паттерне. 4 — баланс «не тривиально, но
## не муторно». Можно перенести в SpellSystem.SPELL_CATALOG[&"super"] на прокачку.
@export_range(2, 9) var pattern_length: int = 4
## Engine.time_scale во время AIMING_PATTERN. 0.15 = 6.67×slowdown — ощущается
## как «на грани остановки». 1.0 = без slow-mo (для дебага).
@export_range(0.05, 1.0) var pattern_time_scale: float = 0.15
@export_group("")

@export_group("Rain (ковровая бомбардировка)")
## Сколько фаерболов падает с неба за каст.
@export var rain_shot_count: int = 12
## Радиус, в котором сыпется дождь (вокруг target_pos игрока).
@export var rain_radius: float = 7.0
## Период между шотами в реальных секундах. 0.18 → 12 шотов за ~2.2с.
@export var rain_shot_interval: float = 0.18
## Урон одного шота (центр AOE, falloff линейный).
@export var rain_shot_damage: float = 25.0
## AOE-радиус каждого шота.
@export var rain_shot_radius: float = 2.5
## Высота старта над землёй — фаерболы «падают с неба». 30м даёт читаемое
## зрелищное падение, не слишком короткое.
@export var rain_launch_height: float = 30.0
## Mask AOE — та же что у обычных fireball'ов (Layers.MASK_HAND_SLAM).
@export_flags_3d_physics var rain_explode_mask: int = Layers.MASK_HAND_SLAM
## Knockback от каждого шота — слабее обычного fireball'а (12 vs 35),
## ковёр толкает не «прочь», а «прижимает».
@export var rain_knockback_force: float = 12.0
@export var rain_knockback_lift: float = 0.3
@export var rain_knockback_duration: float = 0.3
@export_group("")

@export_group("Visual / scenes")
@export var fireball_scene: PackedScene
@export var pattern_overlay_scene: PackedScene
## Куда добавлять снаряды. Если NodePath пуст — current_scene.
@export var effects_root_path: NodePath
@export_group("")

@export var debug_log: bool = true

var _hand: Hand
var _camp: Camp
var _state: State = State.READY
var _effects_root: Node = null
## CanvasLayer для overlay'а — создаётся лениво на первый каст.
var _overlay_canvas: CanvasLayer = null
var _overlay: SuperPatternOverlay = null
## Категория, в которой была рука перед началом каста — на завершении
## возвращаем (PHYSICAL→PHYSICAL, MAGIC→MAGIC).
var _pre_super_category: int = Hand.Category.PHYSICAL
## Запомненная позиция земли под курсором на момент успеха QTE — это «центр
## ковра». Игрок может ещё подвигать курсором; финальная цель определится
## именно нажатием ПКМ в AIMING_TARGET.
var _aim_target: Vector3 = Vector3.ZERO
## Серия шотов в CASTING-фазе (счётчик и тайминг).
var _shots_remaining: int = 0
var _next_shot_in: float = 0.0


func _ready() -> void:
	_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene


func setup(hand: Hand) -> void:
	_hand = hand


func _process(delta: float) -> void:
	# Серию ковра тикаем независимо от категории — игрок мог уже выйти из
	# CASTING (state == READY) сразу после первого шота, но ракеты должны
	# доспавниться по таймингу. Используем _shots_remaining как guard.
	if _shots_remaining > 0:
		_next_shot_in -= delta
		if _next_shot_in <= 0.0:
			_launch_one_rain_shot()
			_shots_remaining -= 1
			_next_shot_in = rain_shot_interval
			if _shots_remaining <= 0 and _state == State.CASTING:
				_state = State.READY

	_handle_input()


func _handle_input() -> void:
	match _state:
		State.READY:
			if Input.is_action_just_pressed(ACTION_TRIGGER):
				_try_start_cast()
		State.AIMING_TARGET:
			# В этой фазе мир в нормальном времени, рука обычно двигается.
			# ПКМ — ставит ковёр в точку курсора. Повторный Space — отмена.
			if Input.is_action_just_pressed(ACTION_AIM_RELEASE):
				_commit_rain()
			elif Input.is_action_just_pressed(ACTION_TRIGGER):
				_cancel_aim()
		_:
			pass  # AIMING_PATTERN: ввод обрабатывает overlay; CASTING: пассивное


func _try_start_cast() -> void:
	if not is_instance_valid(_camp):
		_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	if not is_instance_valid(_camp):
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Super] Camp не найден — каст невозможен")
		return
	if not _camp.is_super_ready():
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Super] шкала не полная (%.0f/%.0f)" % [_camp.get_super_charge(), _camp.get_super_charge_max()])
		return
	if _hand.is_holding():
		# Удерживаемый предмет блокирует каст (как и в Fireball/Firestorm).
		# Не ронять автоматически — игрок сам решит, когда отпускать.
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Super] рука занята — отпусти предмет")
		return
	# Запоминаем категорию для возврата (на провале QTE / завершении каста).
	_pre_super_category = _hand.active_category
	_hand.set_active_category(Hand.Category.SUPER)
	EventBus.super_cast_started.emit()
	_enter_aiming_pattern()


func _enter_aiming_pattern() -> void:
	_state = State.AIMING_PATTERN
	Engine.time_scale = pattern_time_scale
	_ensure_overlay()
	_overlay.start_pattern(pattern_length)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Super] QTE стартовал, time_scale=%.2f" % pattern_time_scale)


func _ensure_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		return
	if pattern_overlay_scene == null:
		push_error("[Hand:Super] pattern_overlay_scene не задан")
		return
	# CanvasLayer над gameplay-HUD'ом (gameplay_hud — обычно слой 0 или 1).
	# Слой 10 поверх всего.
	if _overlay_canvas == null or not is_instance_valid(_overlay_canvas):
		_overlay_canvas = CanvasLayer.new()
		_overlay_canvas.layer = 10
		_overlay_canvas.process_mode = Node.PROCESS_MODE_ALWAYS  # CanvasLayer вне time_scale
		get_tree().current_scene.add_child(_overlay_canvas)
	_overlay = pattern_overlay_scene.instantiate() as SuperPatternOverlay
	_overlay_canvas.add_child(_overlay)
	_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay.pattern_finished.connect(_on_pattern_finished)


func _on_pattern_finished(success: bool) -> void:
	# Возврат к нормальному времени до любых других переходов — UI и логика
	# дальше работают в обычном масштабе.
	Engine.time_scale = 1.0
	if success:
		# Запоминаем точку прицела в момент завершения QTE — игрок может ещё
		# подвигать курсор в AIMING_TARGET, но мы и без этого имеем валидный fallback.
		_aim_target = _hand.cursor_world_position()
		_aim_target.y -= _hand.hand_height
		_state = State.AIMING_TARGET
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Super] QTE OK — прицел, ПКМ для каста")
	else:
		# Провал — половина шкалы списывается, возвращаем категорию, всё.
		_camp.consume_super_charge(_camp.get_super_charge_max() * _camp.super_charge_fail_penalty)
		_finish_super(false)


func _commit_rain() -> void:
	# Игрок нажал ПКМ — ставит ковёр в текущую точку курсора (НЕ заранее
	# зафиксированную: куда смотрит сейчас, туда и сыпется).
	var target: Vector3 = _hand.cursor_world_position()
	target.y -= _hand.hand_height
	_aim_target = target
	# Полное списание шкалы — один каст = один полный ресурс.
	_camp.consume_super_charge(_camp.get_super_charge_max())
	_state = State.CASTING
	_shots_remaining = rain_shot_count
	_next_shot_in = 0.0  # первый шот сразу
	super_cast.emit(target)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Super] ковёр × %d @ (%.1f, %.1f, %.1f)" % [rain_shot_count, target.x, target.y, target.z])
	# Категорию возвращаем СРАЗУ — игрок может управлять рукой пока серия
	# летит. CASTING-фаза держится только для счётчика _shots_remaining.
	_finish_super(true)


func _cancel_aim() -> void:
	# Отмена в AIMING_TARGET. Правило: повторный Space без ПКМ — отказ от
	# каста, шкала остаётся нетронутой (QTE прошёл, но ничего не списываем).
	# Альтернатива «списать половину» — спросим у геймдизайнера если
	# понадобится. Сейчас бесплатная отмена выгодная UX-страховка.
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Super] прицел отменён — шкала сохранена")
	_finish_super(false)


func _finish_super(success: bool) -> void:
	if _hand.active_category == Hand.Category.SUPER:
		_hand.set_active_category(_pre_super_category)
	if _state != State.CASTING:
		_state = State.READY
	EventBus.super_cast_finished.emit(success)


func _launch_one_rain_shot() -> void:
	if fireball_scene == null:
		push_error("[Hand:Super] fireball_scene не задан")
		return
	# Каждый шот таргетит точку в `rain_radius` вокруг _aim_target — uniform
	# по площади (sqrt-jitter, как Firestorm).
	var angle: float = randf() * TAU
	var dist: float = sqrt(randf()) * rain_radius
	var target_pos: Vector3 = _aim_target + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
	# Стартовая точка — высоко над target. Небольшой horizontal jitter
	# чтобы фаерболы не падали строго вертикально (читаемее как «дождь»).
	var launch_jitter: Vector3 = Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0))
	var launch_pos: Vector3 = target_pos + Vector3.UP * rain_launch_height + launch_jitter

	var fireball := fireball_scene.instantiate() as Fireball
	if fireball == null:
		push_error("[Hand:Super] fireball_scene не инстанцируется как Fireball")
		return
	_effects_root.add_child(fireball)
	# Конфиг под «дождь»: короткий boost (фактически не нужен), homing сразу
	# вертикально вниз. Используем тот же setup-API что у одиночного fireball'а.
	fireball.setup(
		launch_pos,
		target_pos,
		0.05,    # boost_duration — почти 0
		0.0,    # boost_velocity_up
		0.0,    # boost_velocity_forward
		0.0,    # boost_gravity
		0.0,    # boost_drift_velocity
		18.0,   # homing_initial_speed — стартовая
		60.0,   # homing_acceleration — быстро разгоняется в падении
		45.0,   # homing_max_speed
		8.0,    # homing_drift_angle_deg — почти прямо
		8.0,    # homing_turn_rate — быстрая коррекция
		rain_shot_damage,
		rain_shot_radius,
		rain_explode_mask,
		rain_knockback_force,
		rain_knockback_lift,
		rain_knockback_duration,
	)
