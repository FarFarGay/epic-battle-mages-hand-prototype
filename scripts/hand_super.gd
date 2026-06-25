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

@export_group("Carrier (носитель из башни)")
## Высота burst-точки НАД _aim_target. Carrier поднимается над землёй,
## разделяется тут на маленькие фаерболы, те уже сами падают вниз.
@export var carrier_burst_height: float = 12.0
## Вертикальный offset launch'а от Tower'а — как у Fireball'а.
@export var carrier_launch_offset_y: float = 3.0

## Carrier boost-фаза («оттяг» из башни — короткий вертикальный взлёт +
## slight forward + sway). Те же параметры что у Fireball, чуть жирнее
## по vertical-velocity для драматичности.
@export var carrier_boost_duration: float = 0.22
@export var carrier_boost_velocity_up: float = 9.0
@export var carrier_boost_velocity_forward: float = 1.5
@export var carrier_boost_gravity: float = 12.0
@export var carrier_boost_drift_velocity: float = 3.5

## Carrier homing-фаза (полёт в burst_pos с drift'ом — «как ракета
## шатается, потом разрывается»). Скорости подняты: initial 12, accel 60,
## max 48 — carrier долетает заметно бодрее, без потери «оттяга» в boost'е.
@export var carrier_homing_initial_speed: float = 12.0
@export var carrier_homing_acceleration: float = 60.0
@export var carrier_homing_max_speed: float = 48.0
@export_range(0.0, 80.0) var carrier_homing_drift_angle_deg: float = 35.0
## turn_rate чуть выше (3.5 vs 2.5) — на большей скорости длинный drift
## уводил бы carrier далеко в сторону, корректировка короче.
@export_range(1.0, 30.0) var carrier_homing_turn_rate: float = 3.5
## Радиус визуала взрыва carrier'а в момент разделения (AoeVisual.spawn_explosion:
## core-вспышка + fire-партиклы + smoke). Не AOE-урон — чисто визуал. 4м
## выглядит читаемо на высоте burst'а ≈ ground+12.
@export var carrier_burst_visual_radius: float = 4.0
@export_group("")

@export_group("Payload (маленькие снаряды после разделения)")
## Сколько маленьких снарядов вылетает на burst'е.
@export var payload_count: int = 12
## Радиус разлёта payload-target'ов вокруг _aim_target по земле.
@export var payload_radius: float = 7.0
## Урон одного payload'а в центре AOE. Balance v3 — пропорционально
## Fireball L0 35 dmg (×1.38 от исходных 25).
@export var payload_damage: float = 35.0
## AOE-радиус каждого payload'а. 4.0 — большой нахлёст между соседними
## взрывами, реально «массовый удар»: цели в эпицентре получают damage от
## нескольких payload'ов сразу, на краю — один-два.
@export var payload_radius_aoe: float = 4.0
## Mask AOE.
@export_flags_3d_physics var payload_explode_mask: int = Layers.MASK_HAND_SLAM
## Knockback одного payload'а — слабее обычного fireball'а.
@export var payload_knockback_force: float = 12.0
@export var payload_knockback_lift: float = 0.3
@export var payload_knockback_duration: float = 0.3
## Случайный разброс launch-позиции каждого payload'а вокруг burst-точки
## (по xz). Нулевой — все вылетают строго из burst, ненулевой — небольшой
## визуальный «взрыв» точки разделения.
@export var payload_launch_scatter: float = 1.0
## Максимальная случайная задержка перед спавном каждого payload'а
## (секунды). 0 = все вылетают одновременно. >0 = разлёт «вразнобой» с
## импактами в окне [t, t+max_delay+flight_time]. 0.4 → импакты в ~0.4с
## друг от друга, ощущение «не одна дробина, а очередь».
@export var payload_max_delay: float = 0.4
## Per-payload random multiplier для homing_acceleration / homing_max_speed.
## Каждый payload получает factor ∈ [1-jitter; 1+jitter]. 0.25 → ±25%, что
## заметно меняет время полёта между ними (хаотичность).
@export_range(0.0, 0.6) var payload_speed_jitter: float = 0.25
## Lead-time перед спавном payload'а: ground-warning ring появляется сразу
## (показывает «куда упадёт»), payload спавнится через этот промежуток.
## 0 = warning + fireball одновременно (без telegraph'а).
@export var payload_warning_lead_time: float = 0.3
## Сколько живёт ground-warning под payload'ом (секунды). ≈ lead_time +
## flight_time, чтобы кольцо угасало к моменту импакта.
@export var payload_warning_duration: float = 1.0
## Цвет warning-кольца под payload'ом. Огненно-красный — отличается от
## aim_indicator'а (золотой) и читается как «опасно».
@export var payload_warning_color: Color = Color(1.0, 0.35, 0.15, 0.85)
@export_group("")

@export_group("Payload trajectory")
## Короткая boost-фаза payload'а перед HOMING. Carrier уже разделился — все
## velocity-параметры boost'а нулевые (payload летит почти вертикально вниз
## под собственной homing-логикой). boost_duration ненулевой только чтобы
## Fireball не упал в первом тике в init-state'е.
@export var payload_boost_duration: float = 0.05
## Стартовая скорость homing-фазы payload'а. Меньше carrier_homing_initial
## (12) — payload «выпадает», не «выстреливает».
@export var payload_homing_initial_speed: float = 14.0
## Базовое ускорение payload'а. На каст ×[1-jitter, 1+jitter] из
## [member payload_speed_jitter] — разные времена полёта между payload'ами.
@export var payload_homing_acceleration_base: float = 55.0
## Базовый max_speed payload'а (с jitter'ом).
@export var payload_homing_max_speed_base: float = 42.0
## Drift-угол homing'а payload'а, рандом per-payload в диапазоне [min, max]
## градусов. Маленький разброс (4-14°) → почти-прямые трассы вниз, без
## большого изгиба как у обычного fireball'а (45°).
@export_range(0.0, 80.0) var payload_drift_angle_deg_min: float = 4.0
@export_range(0.0, 80.0) var payload_drift_angle_deg_max: float = 14.0
## Turn_rate homing'а payload'а, рандом per-payload [min, max]. Выше чем у
## fireball'а (3.5), потому что drift маленький — коррекция к target'у
## должна быть быстрой.
@export_range(1.0, 30.0) var payload_turn_rate_min: float = 8.0
@export_range(1.0, 30.0) var payload_turn_rate_max: float = 14.0
@export_group("")

@export_group("Aim indicator")
## Радиус ground-кольца в фазе AIMING_TARGET. Совпадает с payload_radius —
## показывает зону разлёта payload'ов вокруг точки прицела.
@export var aim_indicator_radius_match: bool = true
## Цвет ring'а в AIMING_TARGET.
@export var aim_indicator_color: Color = Color(1.0, 0.7, 0.15, 0.95)
@export_group("")

@export_group("Visual / scenes")
## Сцена носителя (большой снаряд из башни до точки разделения).
@export var carrier_scene: PackedScene
## Сцена payload-фаербола. Та же fireball.tscn что и у обычной магии.
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
## Запомненная позиция земли под курсором на момент успеха QTE — это «центр
## ковра». Игрок может ещё подвигать курсором; финальная цель определится
## именно нажатием ПКМ в AIMING_TARGET.
var _aim_target: Vector3 = Vector3.ZERO
## Постоянный ground-ring под курсором в AIMING_TARGET (визуализация
## bombing zone). Создаётся в _on_pattern_finished(true), двигается каждый
## кадр в _process, освобождается в _commit_rain / _cancel_aim / _finish_super(false).
var _aim_indicator: MeshInstance3D = null
## Балансовые параметры фиксируются на _try_start_cast / _commit_rain — те же
## значения используются на всех этапах одного каста (QTE → carrier → burst →
## payloads). Если игрок кастует ещё раз — резолвятся заново. @export'ы — fallback.
var _resolved_payload_count: int = 0
var _resolved_payload_damage: float = 0.0
var _resolved_payload_radius: float = 0.0
var _resolved_payload_radius_aoe: float = 0.0
var _resolved_pattern_length: int = 0


func _ready() -> void:
	_camp = get_tree().get_first_node_in_group(Camp.CAMP_GROUP) as Camp
	if not effects_root_path.is_empty():
		_effects_root = get_node_or_null(effects_root_path)
	if _effects_root == null:
		_effects_root = get_tree().current_scene


func setup(hand: Hand) -> void:
	_hand = hand


func _process(_delta: float) -> void:
	# AIMING_TARGET: indicator сидит на земле под курсором, обновляется каждый
	# кадр. Mesh уже выше пола на 0.05м (см. spawn_ground_ring), Y берём из
	# курсорной точки минус hand_height — это ground под курсором.
	if _state == State.AIMING_TARGET and is_instance_valid(_aim_indicator):
		var ground: Vector3 = _hand.cursor_world_position()
		ground.y -= _hand.hand_height
		_aim_indicator.global_position = ground + Vector3.UP * 0.05

	_handle_input()


func _handle_input() -> void:
	# Если рука сейчас в SQUAD_AIM / BUILD_AIM (команду squad'у даём / выбираем
	# точку постройки) — Super-каст заглушаем.
	if _hand != null and (
			_hand.active_category == Hand.Category.SQUAD_AIM
			or _hand.active_category == Hand.Category.BUILD_AIM):
		return
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
	# Великий удар временно недоступен (single source of truth — SpellSystem).
	if SpellSystem != null and not SpellSystem.is_unlocked(&"super"):
		return
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
	# Резолвим балансовые параметры из SpellSystem с fallback'ом на @export.
	# Один раз на каст, дальше используются _resolved_*.
	var lvl: Dictionary = SpellSystem.get_current_level_data(&"super") if SpellSystem != null else {}
	_resolved_payload_count = int(lvl.get("payload_count", payload_count))
	_resolved_payload_damage = float(lvl.get("payload_damage", payload_damage))
	_resolved_payload_radius = float(lvl.get("payload_radius", payload_radius))
	_resolved_payload_radius_aoe = float(lvl.get("payload_radius_aoe", payload_radius_aoe))
	_resolved_pattern_length = int(lvl.get("pattern_length", pattern_length))
	# Hand.push_category сохранит предыдущую категорию в стек; pop_category на
	# завершении каста (_finish_super) её вернёт.
	_hand.push_category(Hand.Category.SUPER)
	_enter_aiming_pattern()


func _enter_aiming_pattern() -> void:
	_state = State.AIMING_PATTERN
	Engine.time_scale = pattern_time_scale
	_ensure_overlay()
	_overlay.start_pattern(_resolved_pattern_length)
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
	# Рука/камп могли исчезнуть за время slow-mo QTE (reload сцены, свёртка) —
	# валидируем перед деревом, иначе дереф freed-ноды.
	if not is_instance_valid(_hand):
		_finish_super(false)
		return
	if success:
		# Запоминаем точку прицела в момент завершения QTE — игрок может ещё
		# подвигать курсор в AIMING_TARGET, но мы и без этого имеем валидный fallback.
		_aim_target = _hand.cursor_world_position()
		_aim_target.y -= _hand.hand_height
		_state = State.AIMING_TARGET
		_spawn_aim_indicator()
		if debug_log and LogConfig.master_enabled:
			print("[Hand:Super] QTE OK — прицел, ПКМ для каста")
	else:
		# Провал — половина шкалы списывается, возвращаем категорию, всё.
		if is_instance_valid(_camp):
			_camp.consume_super_charge(_camp.get_super_charge_max() * _camp.super_charge_fail_penalty)
		_finish_super(false)


func _spawn_aim_indicator() -> void:
	_clear_aim_indicator()
	if _effects_root == null:
		return
	# duration=0 → AoeVisual возвращает mesh без auto-fade, мы сами владеем.
	_aim_indicator = AoeVisual.spawn_ground_ring(
		_effects_root,
		_aim_target,
		_resolved_payload_radius if aim_indicator_radius_match else _resolved_payload_radius_aoe,
		0.0,
		aim_indicator_color,
	)


func _clear_aim_indicator() -> void:
	if is_instance_valid(_aim_indicator):
		_aim_indicator.queue_free()
	_aim_indicator = null


func _commit_rain() -> void:
	# Игрок нажал ПКМ — ставит каст в текущую точку курсора (НЕ заранее
	# зафиксированную: куда смотрит сейчас, туда и сыпется).
	if not is_instance_valid(_hand):
		_finish_super(false)
		return
	var target: Vector3 = _hand.cursor_world_position()
	target.y -= _hand.hand_height
	_aim_target = target
	_clear_aim_indicator()
	# Полное списание шкалы — один каст = один полный ресурс.
	if is_instance_valid(_camp):
		_camp.consume_super_charge(_camp.get_super_charge_max())
	_state = State.CASTING
	super_cast.emit(target)
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Super] carrier @ burst-target=(%.1f, %.1f, %.1f)" % [target.x, target.y, target.z])
	_spawn_carrier(target)
	EventBus.tower_fired.emit(target)  # отдача: carrier выходит из башни (1 раз; payload'ы — из неба)
	EventBus.camera_shake.emit(0.6, target)  # супер — сильное событие; трясём по дистанции до точки удара
	# Категорию возвращаем СРАЗУ — игрок может управлять рукой пока carrier
	# летит и payload'ы падают. CASTING-state держится через _on_carrier_burst
	# (закроется обратно в READY после burst'а).
	_finish_super(true)


func _cancel_aim() -> void:
	# Отмена в AIMING_TARGET. Правило: повторный Space без ПКМ — отказ от
	# каста, шкала остаётся нетронутой (QTE прошёл, но ничего не списываем).
	# Альтернатива «списать половину» — спросим у геймдизайнера если
	# понадобится. Сейчас бесплатная отмена выгодная UX-страховка.
	_clear_aim_indicator()
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Super] прицел отменён — шкала сохранена")
	_finish_super(false)


func _finish_super(_success: bool) -> void:
	# На любой выход (success/fail/cancel) — indicator не должен повиснуть.
	# _commit_rain и _cancel_aim уже зовут _clear_aim_indicator явно, тут
	# подстраховка для путей, которые могли бы пропустить.
	_clear_aim_indicator()
	# Страховка: slow-mo QTE не должен залипнуть глобально (краш/нестандартный выход
	# из AIMING_PATTERN оставил бы Engine.time_scale=0.15 на всю игру).
	Engine.time_scale = 1.0
	if is_instance_valid(_hand) and _hand.active_category == Hand.Category.SUPER:
		_hand.pop_category()
	if _state != State.CASTING:
		_state = State.READY


func _spawn_carrier(target_pos: Vector3) -> void:
	if carrier_scene == null:
		push_error("[Hand:Super] carrier_scene не задан")
		return
	if _effects_root == null:
		return
	# Tower-launch helper живёт в HandSpell (там tower-cache); используем тот
	# же контракт — single source of truth для «откуда летят снаряды».
	if not is_instance_valid(_hand) or _hand.spell_actions == null:
		return
	var launch_pos: Vector3 = _hand.spell_actions.tower_launch_position(carrier_launch_offset_y, _hand)
	var burst_pos: Vector3 = target_pos + Vector3.UP * carrier_burst_height
	var carrier := carrier_scene.instantiate() as SuperCarrier
	if carrier == null:
		push_error("[Hand:Super] carrier_scene не инстанцируется как SuperCarrier")
		return
	# add_child ДО setup — setup делает `global_position = launch_pos`, который
	# требует ноду в SceneTree (иначе returns Transform3D() и позиция не ставится,
	# warning «!is_inside_tree() is true»).
	_effects_root.add_child(carrier)
	carrier.add_to_group(&"player_projectile")  # EnemyMech уклоняется от снарядов игрока
	carrier.setup(
		launch_pos,
		burst_pos,
		carrier_boost_duration,
		carrier_boost_velocity_up,
		carrier_boost_velocity_forward,
		carrier_boost_gravity,
		carrier_boost_drift_velocity,
		carrier_homing_initial_speed,
		carrier_homing_acceleration,
		carrier_homing_max_speed,
		carrier_homing_drift_angle_deg,
		carrier_homing_turn_rate,
	)
	# bind ground-target — на burst'е знать, куда payload'ы должны падать.
	carrier.burst.connect(_on_carrier_burst.bind(target_pos))


func _on_carrier_burst(burst_position: Vector3, ground_target: Vector3) -> void:
	# Carrier долетел и эмитит сигнал. Spawn'им N payload-фаерболов с
	# random-задержками — импакты ложатся «очередью», а не один-в-один.
	if fireball_scene == null:
		push_error("[Hand:Super] fireball_scene не задан")
		_state = State.READY
		return
	if not is_instance_valid(_effects_root):
		_state = State.READY
		return
	if debug_log and LogConfig.master_enabled:
		print("[Hand:Super] burst @ (%.1f, %.1f, %.1f) → %d payloads" % [burst_position.x, burst_position.y, burst_position.z, _resolved_payload_count])
	# Воздушный взрыв в точке разделения — core-вспышка + fire/smoke частицы.
	# Тот же AoeVisual.spawn_explosion что у обычных fireball'ов; payload'ы
	# сразу же вылетают «из огня».
	AoeVisual.spawn_explosion(_effects_root, burst_position, carrier_burst_visual_radius)
	for i in range(_resolved_payload_count):
		var delay: float = randf() * payload_max_delay if payload_max_delay > 0.0 else 0.0
		if delay <= 0.0:
			_spawn_one_payload(burst_position, ground_target)
		else:
			# Без await: timer.timeout одноразовый, лямбда захватывает burst-точку.
			# Carrier к этому моменту уже queue_free'нут, но _effects_root
			# обычно current_scene и переживёт.
			get_tree().create_timer(delay).timeout.connect(
				_spawn_one_payload.bind(burst_position, ground_target),
				CONNECT_ONE_SHOT,
			)
	# Carrier отыграл свою роль — серия запущена. Закрываем state сразу,
	# fireball'ы дальше живут сами по таймерам.
	if _state == State.CASTING:
		_state = State.READY


func _spawn_one_payload(burst_position: Vector3, ground_target: Vector3) -> void:
	# Сцена могла перезагрузиться за время задержки — guard.
	if not is_instance_valid(_effects_root):
		return
	if fireball_scene == null:
		return
	# uniform-по-площади distribution в круге _resolved_payload_radius
	var angle: float = randf() * TAU
	var dist: float = sqrt(randf()) * _resolved_payload_radius
	var payload_target: Vector3 = ground_target + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)

	# Telegraph: ground-warning ring сразу в landing point. Размер = AOE
	# радиусу одного payload'а, так игрок видит реальную зону поражения.
	# Ring сам fade'ит за payload_warning_duration (lead + flight).
	AoeVisual.spawn_ground_ring(
		_effects_root,
		payload_target,
		_resolved_payload_radius_aoe,
		payload_warning_duration,
		payload_warning_color,
	)

	# Lead-time перед фактическим spawn'ом fireball'а — игрок успевает
	# прочесть warning. await suspend'ит coroutine, остальные payload'ы
	# спавнятся параллельно (см. callers с random delay).
	if payload_warning_lead_time > 0.0:
		await get_tree().create_timer(payload_warning_lead_time).timeout
	# Сцена могла перезагрузиться за время await'а.
	if not is_instance_valid(_effects_root):
		return

	# Launch — в burst-точке + scatter (для визуального разлёта)
	var launch_jitter: Vector3 = Vector3(
		randf_range(-payload_launch_scatter, payload_launch_scatter),
		0.0,
		randf_range(-payload_launch_scatter, payload_launch_scatter),
	)
	var payload_launch: Vector3 = burst_position + launch_jitter

	var fireball := fireball_scene.instantiate() as Fireball
	if fireball == null:
		return
	_effects_root.add_child(fireball)
	fireball.add_to_group(&"player_projectile")  # EnemyMech уклоняется от снарядов игрока
	# Per-payload jitter: разные accel/max_speed дают разные времена полёта
	# и траектории — импакты «вразнобой» даже если delay одинаковый.
	var jitter_lo: float = 1.0 - payload_speed_jitter
	var jitter_hi: float = 1.0 + payload_speed_jitter
	var accel_factor: float = randf_range(jitter_lo, jitter_hi)
	var max_speed_factor: float = randf_range(jitter_lo, jitter_hi)
	# Конфиг payload'а: drift и turn_rate тоже слегка варьируются — каждый
	# летит немного по-своему, но в целом почти-вертикально.
	fireball.setup(
		payload_launch,
		payload_target,
		payload_boost_duration,
		0.0,                                            # boost_velocity_up — payload не «стреляет», падает
		0.0,                                            # boost_velocity_forward
		0.0,                                            # boost_gravity
		0.0,                                            # boost_drift_velocity
		payload_homing_initial_speed,
		payload_homing_acceleration_base * accel_factor,
		payload_homing_max_speed_base * max_speed_factor,
		randf_range(payload_drift_angle_deg_min, payload_drift_angle_deg_max),
		randf_range(payload_turn_rate_min, payload_turn_rate_max),
		_resolved_payload_damage,
		_resolved_payload_radius_aoe,
		payload_explode_mask,
		payload_knockback_force,
		payload_knockback_lift,
		payload_knockback_duration,
	)
	# Хитстоп: атаки башни морозят весомых целей; per-enemy рефрактор не даёт
	# рою payload'ов застан-локать босса (см. HitStop).
	fireball.set_hitstop(HitStop.HEAVY)
	fireball.shake_amount = 0.1  # payload-серия: мелкий шейк на снаряд, копится в кучу
