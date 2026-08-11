extends Node3D
## ⭐⭐ ЭКИПАЖ ЛАДЬИ В БОЛЬШОМ МИРЕ. Модель подземелья ЦЕЛИКОМ переехала на
## уровень с башней: есть гномы, у гномов есть Ладья, в неё можно сесть и выйти.
##
##   ЭКИПАЖ ВНУТРИ  → играешь башней (её штатный контроллер, рука, камера);
##   ЭКИПАЖ СНАРУЖИ → башня встала зданием, WASD ведёт ОТРЯД.
## Третьего состояния нет. «Отправить артель», рабочие смены, карточки отрядов,
## найм гномов за золото — всего этого на уровне больше нет.
##
## ⚠ ПОЧЕМУ ЗДЕСЬ СПАВН (переделка 2026-08-11). Раньше гномов мира рождал
## GnomeSquadSpawner — ГРАЖДАНСКИХ рабочих лагеря: каталожная скорость ~2.2,
## рабочий AI (ищет дерево, прячется в здание), эскорт за башней, карточка в
## HUD. Сверху я навесил этот контроллер, и получилось два хозяина у одних тел:
## один вёл строй, другой уводил гнома работать. Отсюда и «бракованная залупа».
## Теперь источник ровно один — CrewKit, тот же, что в данже: те же сцены, те же
## модели, те же статы, те же кнопки. Никакой второй ветки для мира нет.
##
## Состав приезжает из подземелья (MatchConfig). Прямой запуск мира без данжа —
## дефолтный отряд из инспектора, чтобы сцена не открывалась пустой.

const CREW_WIDGET_SCENE: PackedScene = preload("res://scenes/crew_widget.tscn")

## Стартуем с гномами ВНУТРИ: они приехали из подземелья в башне (DESIGN §2.2).
@export var start_crewed: bool = true
## Дистанция посадки по E — та же логика, что в ангаре интро.
@export var board_distance: float = 8.0
## Радиус кольца высадки вокруг корпуса. Корпус башни — коробка 2×2 в основании,
## так что 5 м гарантированно выносит гномов из-под неё, а не на крышу.
@export var disembark_radius: float = 5.0

@export_group("Состав по умолчанию")
## Отряд для ПРЯМОГО запуска мира (из данжа никто не приехал). Числа — как в
## интро: тройка лучников и пара копейщиков.
@export var default_archers: int = 3
@export var default_pikemen: int = 2
@export var default_workers: int = 0
@export_group("")

@export_group("Ход отряда (модель данжа)")
## Скорость точки строя и отзывчивость руления (1/с). Числа — РОВНО ДАНЖЕВЫЕ
## (DungeonSandbox.wasd_speed/handling/brake): один и тот же отряд не должен
## ехать в двух эпизодах по-разному. Свои значения тут подбирать нельзя.
@export var move_speed: float = 10.0
@export var handling: float = 10.0
## Множитель торможения, когда клавиши отпущены (<1 = докатывается).
@export var brake_mult: float = 0.6
## Пружина «гном → слот» и потолок её вклада (SoldierGnome.body_*).
##
## ⚠ ПОТОЛОК СВЯЗАН СО СКОРОСТЬЮ ХОДА, это не «просто число». Поправка
## складывается с ходом тела: desired = body_velocity + corr. Обогнавший свой
## слот гном получает поправку НАЗАД, и она гасит ход: при ходе 7.5 и потолке 6
## оставалось 1.5 м/с — отряд полз, хотя команда была 7.5. Данжевая пара 10/6
## живёт, потому что тела (CrewKit, 8 м/с) успевают за точкой строя. Меняешь
## одно — проверяй второе замером, на глаз тут не видно.
@export var body_pull: float = 10.0
@export var body_pull_max: float = 6.0
## Мягкая сцепка якоря с фактическим центром отряда (1/с).
@export var anchor_pull: float = 3.0
## Сцепление тел и вязкость хвоста строя (желе). Скорость самих тел задаёт
## CrewKit — она общая с данжем.
@export var unit_grip: float = 16.0
@export var grip_tail: float = 0.68
@export var formation_spacing: float = 1.35
@export_group("")

@export_group("Кнопки отряда (модель данжа)")
## Полив лучников: сектор прицела (dot ≈ ±60°) и отдача в тело за выстрел.
@export var aim_dot: float = 0.5
@export var shot_recoil: float = 0.15
## Удар копейщиков вокруг строя: радиус, урон ЗА КАЖДОГО копейщика, отброс.
@export var super_radius: float = 6.5
@export var super_damage_per_gnome: float = 28.0
@export var super_knockback: float = 11.0
@export var super_hitstop: float = 0.08
@export var super_cooldown: float = 6.0
@export_group("")

var _squad: Squad = null
var _tower: Node3D = null
var _rig: Node = null
var _widget: CanvasLayer = null
## Узел-цель камеры, когда рулим отрядом: камера следит за ним, а не за башней.
## Он же — escort-якорь гномов (в данже эту роль играет баннер строя).
var _focus: Node3D = null
var _crewed: bool = true
var _vel: Vector3 = Vector3.ZERO
## Якорь тела — аналог center_body у Pathogenic. Слоты НЕЛЬЗЯ вешать прямо на
## центроид: слоты считаются от гномов, гномы тянутся к слотам, и контур сам
## себя разгоняет. Якорь эту петлю рвёт — его интегрирует ход, а не группа.
var _anchor: Vector3 = Vector3.INF
var _e_was_down: bool = false
## Куда «смотрит» строй: вдоль него Squad кладёт ряды (tail_dir).
var _facing: Vector3 = Vector3.FORWARD
## Рука башни: пока экипаж снаружи, она СПИТ. Без этого у игрока два хозяина
## одной ЛКМ — рука хватает ящик, а лучники в тот же клик поливают.
var _hand: Node = null
var _lmb_down: bool = false
var _space_down: bool = false
var _super_cd: float = 0.0


func _ready() -> void:
	_focus = Node3D.new()
	_focus.name = "SquadFocus"
	add_child(_focus)
	_widget = CREW_WIDGET_SCENE.instantiate() as CanvasLayer
	add_child(_widget)
	_widget.connect(&"leave_requested", _on_leave_pressed)
	_widget.connect(&"board_requested", _on_board_pressed)
	_widget.connect(&"rebuild_requested", _on_rebuild_pressed)
	# Пересборка состава живёт пока только в подземелье (там для неё есть
	# комната-предбанник). Гасим кнопку честно, а не делаем вид, что работает.
	_widget.call(&"set_rebuild_enabled", false)
	call_deferred(&"_late_setup")


## Отложенно: башня и риг могут ready'иться позже нас (порядок детей).
func _late_setup() -> void:
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	_tower = get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	_rig = get_tree().get_first_node_in_group(CameraRig.CAMERA_RIG_GROUP)
	_hand = _find_hand()
	_spawn_crew()
	_set_crewed(start_crewed)


## ⭐ ЭКИПАЖ. Состав — из подземелья, иначе дефолтный. Строй — «черепаха» с
## мягким HOLD: стрельба приоритетнее марша (strict=false), как в данже.
func _spawn_crew() -> void:
	_squad = Squad.new()
	_squad.id = 1
	_squad.soldier_type = CrewKit.ARCHER
	_squad.hold_grid = true
	_squad.grid_spacing_scale = formation_spacing
	var at: Vector3 = global_position
	if _tower != null and is_instance_valid(_tower):
		at = _tower.global_position
	var roster: Array[StringName] = _roster()
	var cfg: Dictionary = CrewKit.default_cfg()
	for i in range(roster.size()):
		var ang: float = TAU * float(i) / float(maxi(roster.size(), 1))
		var pos: Vector3 = _on_ground(at.x + cos(ang) * disembark_radius,
				at.z + sin(ang) * disembark_radius)
		var g := CrewKit.create_soldier(self, roster[i], pos, cfg, _focus)
		if g == null:
			continue
		# Гном мира — ВСЕГДА экипаж: рабочей логики лагеря (дерево, смены,
		# патрули) у него нет и включаться она не должна ни на кадр.
		g.set_crew_mode(true)
		_squad.add_member(g)
	_squad.command_hold(Vector3(at.x, 0.0, at.z), false)
	print("[Crew] экипаж: %d — %s" % [roster.size(), str(roster)])


## Кто именно приехал. Класс едет вместе с гномом и НЕ меняется (решение юзера):
## привёл лучников — у тебя лучники. Пусто → дефолт из инспектора.
func _roster() -> Array[StringName]:
	var carried: Array[StringName] = MatchConfig.consume_squad()
	if not carried.is_empty():
		var out: Array[StringName] = []
		for id in carried:
			if SoldierSystem != null and SoldierSystem.has_soldier(id):
				out.append(id)
		if not out.is_empty():
			return out
	var mix: Array[StringName] = []
	for i in range(default_pikemen):
		mix.append(&"pikeman")
	for i in range(default_archers):
		mix.append(CrewKit.ARCHER)
	for i in range(default_workers):
		mix.append(&"worker")
	return mix


# --- Посадка и высадка -------------------------------------------------------


func _set_crewed(on: bool) -> void:
	_crewed = on
	if _tower != null and is_instance_valid(_tower):
		# Башня без экипажа — здание: свой контроллер спит, коллизия жива.
		_tower.set_physics_process(on)
		_tower.set_process(on)
	for m in _squad.members if _squad != null else []:
		if not is_instance_valid(m):
			continue
		var g := m as Node3D
		g.visible = not on
		m.set_physics_process(not on)
		if m is CollisionObject3D:
			var co := m as CollisionObject3D
			if not co.has_meta(&"ride_layer"):
				co.set_meta(&"ride_layer", co.collision_layer)
				co.set_meta(&"ride_mask", co.collision_mask)
			if on:
				co.collision_layer = 0
				co.collision_mask = 0
			else:
				co.collision_layer = int(co.get_meta(&"ride_layer", co.collision_layer))
				co.collision_mask = int(co.get_meta(&"ride_mask", co.collision_mask))
		if on and _tower != null and is_instance_valid(_tower):
			g.global_position = _tower.global_position + Vector3(0.0, 4.5, 0.0)
	# ⭐ ОДИН ХОЗЯИН ВВОДА. Рука — инструмент Ладьи: экипаж вышел — рука спит.
	# Иначе ЛКМ делает два дела разом (рука хватает ящик, лучники поливают), а
	# это ровно та мешанина контроллеров, из-за которой всё и переделывалось.
	if _hand != null and is_instance_valid(_hand):
		_hand.set_process(on)
		_hand.set_physics_process(on)
		_hand.set_process_unhandled_input(on)
		(_hand as Node3D).visible = on
	# Камера: за башней в кабине, за отрядом снаружи.
	if _rig != null and is_instance_valid(_rig):
		if on:
			_rig.call(&"clear_focus_override")
		else:
			_rig.call(&"set_focus_override", _focus)
	# ⭐ ЭКРАН ПЕРЕКЛЮЧАЕТСЯ ВМЕСТЕ С УПРАВЛЕНИЕМ. Виджет экипажа виден ВСЕГДА —
	# он про гномов, а гномы есть в обоих режимах; меняются заголовок, главная
	# кнопка и подсказка. Башенный HUD (трей заклинаний, мана, супер, палитра
	# стройки) снаружи гаснет: это глаголы Ладьи, а не отряда.
	if _widget != null:
		_widget.visible = true
		_widget.call(&"set_crewed", on)
	var hud := get_tree().get_first_node_in_group(&"gameplay_hud")
	if hud != null and hud.has_method(&"set_crew_mode"):
		hud.call(&"set_crew_mode", on)
	_anchor = Vector3.INF
	_vel = Vector3.ZERO


func _on_leave_pressed() -> void:
	if not _crewed or _squad == null or _tower == null or not is_instance_valid(_tower):
		return
	_set_crewed(false)
	# Высаживаем кольцом вокруг корпуса, КАЖДОГО отдельным лучом на землю.
	# ⚠ Раньше высота бралась «от первого гнома» — а он в этот момент ещё сидит
	# в кабине на y≈7.5, и весь экипаж высаживался на крышу башни: висели в
	# воздухе и не падали (стоят на её же коллайдере). Высоту спрашиваем только
	# у ПОЛА, и только по той точке, куда реально ставим.
	var n: int = maxi(_squad.members.size(), 1)
	var i: int = 0
	var t: Vector3 = _tower.global_position
	for m in _squad.members:
		if not is_instance_valid(m):
			continue
		var a: float = TAU * float(i) / float(n)
		(m as Node3D).global_position = _on_ground(
				t.x + cos(a) * disembark_radius, t.z + sin(a) * disembark_radius)
		i += 1
	_squad.hold_position = Vector3(t.x, 0.0, t.z)
	EventBus.tutorial_hint.emit("Экипаж снаружи. WASD ведёт отряд, [E] у башни — вернуться", 5.0)


## Кнопка «Вернуться в башню» — тот же путь, что клавиша E, включая проверку
## дистанции. Далеко — говорим почему, а не молчим кнопкой, которая «не нажалась».
func _on_board_pressed() -> void:
	if _crewed or _squad == null or _tower == null or not is_instance_valid(_tower):
		return
	var c: Vector3 = _squad.compute_center()
	if c != Vector3.INF and Vector2(_tower.global_position.x - c.x,
			_tower.global_position.z - c.z).length() > board_distance:
		EventBus.tutorial_hint.emit("Слишком далеко от башни — подведи отряд к ней", 2.0)
		return
	_try_board()


func _on_rebuild_pressed() -> void:
	EventBus.tutorial_hint.emit("Пересобрать отряд можно пока только в подземелье", 3.0)


func _try_board() -> void:
	if _crewed or _squad == null or _tower == null or not is_instance_valid(_tower):
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		return
	if Vector2(_tower.global_position.x - c.x,
			_tower.global_position.z - c.z).length() > board_distance:
		return
	_set_crewed(true)
	EventBus.camera_shake.emit(0.35, _tower.global_position)
	EventBus.tutorial_hint.emit("Экипаж в кабине — Ладья твоя", 3.0)


## Базис руления = базис рига (он крутится только по Y, длина ввода сохраняется).
## Ровно тот же источник, что у башни: одна камера — одно «вперёд».
func _cam_basis() -> Basis:
	if _rig != null and is_instance_valid(_rig):
		return (_rig as Node3D).global_transform.basis
	return Basis()


## Рука башни в сцене (может отсутствовать в дев-сценах).
func _find_hand() -> Node:
	return get_tree().get_first_node_in_group(Hand.HAND_GROUP)


## Точка на ПОЛУ под (x, z): луч сверху вниз по слою террейна. Маска только
## TERRAIN — корпус башни и постройки лучу не мешают, иначе гном встал бы на
## крышу того, над чем оказался. Пол не найден (дырка/за краем) → y=0.
func _on_ground(x: float, z: float) -> Vector3:
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(x, 40.0, z), Vector3(x, -20.0, z), Layers.TERRAIN)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	var y: float = (hit.position as Vector3).y if not hit.is_empty() else 0.0
	# Полшага над полом: капсула гнома садится сама, а стартовать вплотную к
	# коллайдеру — верный способ провалиться сквозь него на первом кадре.
	return Vector3(x, y + 0.5, z)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if key.keycode != KEY_E:
		return
	if key.pressed and not _e_was_down:
		_e_was_down = true
		_try_board()
	elif not key.pressed:
		_e_was_down = false


# --- Ход отряда --------------------------------------------------------------


func _physics_process(delta: float) -> void:
	if _squad == null:
		return
	# Состав виджета обновляем В ОБОИХ режимах, ДО выхода по _crewed: сидя в
	# кабине игрок тоже смотрит на состав (и видит, когда пилота убило). Раньше
	# ветка стояла после выхода — в кабине заголовок так и висел «— 0».
	# Squad чистит мёртвых сам по сигналу, своего прохода не нужно.
	if _widget != null:
		_widget.call(&"set_crew", _squad.members)
		_widget.call(&"set_states", _ability_states())
		if not _crewed:
			_widget.call(&"set_hint", _hint_text())
	if _crewed:
		return
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		return
	_focus.global_position = c
	var v: Vector2 = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	var has_input: bool = v.length_squared() > 0.0001
	# ⚠ ХОД СЧИТАЕМ ОТ КАМЕРЫ, А НЕ ОТ МИРОВЫХ ОСЕЙ. Риг большого мира крутится
	# орбитой (СКМ), и его поворот разворачивает систему координат управления —
	# «вперёд» обязано оставаться «вглубь экрана». Мировые оси давали ровно то,
	# на что жаловался юзер: стоит камере отъехать по орбите, и WASD ведёт отряд
	# не туда, куда смотришь. Башня берёт тот же basis (Tower._camera_yaw_basis) —
	# два контроллера обязаны рулить одинаково, иначе посадка ощущается как
	# смена раскладки.
	var target: Vector3 = _cam_basis() * Vector3(v.x, 0.0, v.y) * move_speed \
			if has_input else Vector3.ZERO
	var rate: float = handling * (1.0 if has_input else brake_mult)
	_vel = _vel.lerp(target, 1.0 - exp(-rate * delta))
	var cf := Vector3(c.x, 0.0, c.z)
	# Якорь переинициализируем, если отряд от него сильно оторвало (телепорт,
	# застряли, высадка) — иначе он тянул бы строй обратно через полкарты.
	if _anchor == Vector3.INF or _anchor.distance_to(cf) > 8.0:
		_anchor = cf
	_anchor += _vel * delta
	_anchor = _anchor.lerp(cf, 1.0 - exp(-anchor_pull * delta))
	_squad.hold_position = _anchor
	# ⚠ ОРИЕНТАЦИЯ СТРОЯ ОБЯЗАТЕЛЬНА. Squad раскладывает ряды ПОПЕРЁК tail_dir;
	# оставишь его нулевым — сетка слотов вырождается, гномы дерутся за одни и те
	# же точки. Строй смотрит НА КУРСОР (черепаха передом к прицелу, как в данже),
	# а без курсора — по ходу. Слерпим плавно: резкий флип телепортирует слоты.
	var cursor: Vector3 = _cursor_ground_point()
	var look: Vector3 = Vector3.ZERO
	if cursor != Vector3.INF:
		var to_cur := Vector3(cursor.x - c.x, 0.0, cursor.z - c.z)
		# Мёртвая зона: курсор ПОВЕРХ отряда не должен вертеть строй. Без неё
		# дрожь мыши в паре сантиметров от центра перекладывает сетку слотов, и
		# гномы мечутся, будто управление сошло с ума.
		if to_cur.length_squared() > 6.25:
			look = to_cur.normalized()
	if look == Vector3.ZERO and _vel.length_squared() > 0.25:
		look = _vel.normalized()
	if look != Vector3.ZERO:
		_facing = look if _facing.length_squared() < 0.01 \
				else _facing.slerp(look, minf(1.0, delta * 3.5)).normalized()
		_squad.tail_dir = _facing
	# ⚠ УДЕРЖИВАЕМ РЕЖИМ СЛЕДОВАНИЯ. Отряд в этом уровне могут перехватить чужие
	# системы (директор волн реагирует на скелетов) и увести в оборонный патруль
	# с прогулочным шагом 1.2 м/с. Присваиваем ПОЛЕ, а не зовём command_hold:
	# без сигнала на каждый кадр.
	_squad.state = Squad.State.HOLDING_POSITION
	# Раздаём ход телам каждый кадр: новички подхватывают модель сами, без
	# отдельной инициализации (тот же приём, что в данже).
	var idx: int = 0
	var last: float = maxf(float(_squad.members.size() - 1), 1.0)
	for m in _squad.members:
		if not is_instance_valid(m):
			continue
		m.body_velocity = _vel
		m.body_pull = body_pull
		m.body_pull_max = body_pull_max
		if not m.crew_mode:
			m.set_crew_mode(true)
		# Тела смотрят на прицел и стоя, и на бегу — как в данже.
		m.face_override = _facing if look != Vector3.ZERO else Vector3.ZERO
		# Голова строя рулит жёстко, хвост вязче — тело перетекает за поворотом.
		m.steer_grip = lerpf(unit_grip, unit_grip * grip_tail, float(idx) / last)
		idx += 1
	_tick_commands(delta, c, cursor, look)


# --- Кнопки отряда -----------------------------------------------------------
# ⭐ ТА ЖЕ РАСКЛАДКА, ЧТО В ДАНЖЕ, И ТОТ ЖЕ СМЫСЛ КНОПКИ: кнопка называет не
# способность, а СЛОТ (SoldierGnome.bind_slot) — кто на неё назначен, тот по ней
# и работает. По умолчанию лучники на ЛКМ (полив по удержанию), копейщики на
# ПРОБЕЛЕ (удар вокруг строя).
#
# ⛔ ПКМ (каменный вал артели) сюда ПОКА не перенесён: у него в данже своя
# физика гребня, эхо-волна и тик — это отдельный кусок, а не пара строк. В мир
# артель штатно и не приезжает (в отряде лучники с копейщиками), так что кнопка
# просто молчит, а не врёт. Порт — следующим шагом.


func _tick_commands(delta: float, c: Vector3, cursor: Vector3, aim_dir: Vector3) -> void:
	_super_cd = maxf(_super_cd - delta, 0.0)
	var lmb: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var space: bool = Input.is_key_pressed(KEY_SPACE)
	if lmb and not _lmb_down:
		# ОЧЕРЕДЬ СТАРТУЕТ РАЗВЁРНУТОЙ: фазы раздаём на НАЖАТИИ, иначе первый
		# залп уходит тремя стрелами в один кадр — «бум» вместо «та-та-та».
		_stagger_archers()
		for m in _squad.members:
			if is_instance_valid(m) and m is ArcherSoldier:
				(m as ArcherSoldier).notify_trigger_pressed()
	_lmb_down = lmb
	if space and not _space_down:
		_spear_super(c)
	_space_down = space
	if cursor == Vector3.INF or aim_dir == Vector3.ZERO:
		return
	# Точка полива: ближайший к лучу курсора скелет, иначе точка на самом луче.
	var aim: Vector3 = Vector3.INF
	var to_cur := Vector3(cursor.x - c.x, 0.0, cursor.z - c.z)
	var tgt: Node3D = _ray_target(c, aim_dir)
	if tgt != null:
		aim = tgt.global_position
	else:
		aim = Vector3(c.x, 0.4, c.z) + aim_dir * minf(to_cur.length(), _archer_range())
	# СТЕНЫ ДЕРЖАТ ВЫСТРЕЛЫ: прицел обрезается по первой преграде на луче.
	var wall_hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(
			Vector3(c.x, 0.9, c.z), Vector3(aim.x, 0.9, aim.z),
			Layers.TERRAIN | Layers.WALL_GATE_BLOCK))
	if not wall_hit.is_empty():
		var wp: Vector3 = wall_hit.get("position", aim)
		aim = Vector3(wp.x, 0.4, wp.z) - aim_dir * 0.6
	for m in _squad.members:
		if not is_instance_valid(m) or not (m is ArcherSoldier):
			continue
		# fire_suppressed глушит АВТО-КОНУС («сам увидел — сам палит» ⛔): огонь
		# идёт только через try_suppressive_fire по прицелу игрока.
		m.fire_suppressed = true
		if _bind_held(m.bind_slot) and m.call(&"try_suppressive_fire", aim) \
				and shot_recoil > 0.0:
			_vel -= aim_dir * shot_recoil


## ⭐ ЧТО УМЕЕТ КАЖДЫЙ КЛАСС — прямо на его карточке: кнопка и готовность.
## Карточка молчит о том, чего в мире нет: вал артели и залп огневиков пока
## живут только в подземелье, и обещать их кнопкой нельзя — пишем честно.
func _ability_states() -> Dictionary:
	var spear: String = "ПРОБЕЛ — удар вокруг · %s" \
			% ("готов" if _super_cd <= 0.0 else "%.1fс" % _super_cd)
	# Лучник без отката, поэтому «горит» у него значит не «готов» (он готов
	# всегда), а «сейчас льёт»: подсветка на зажатой гашетке. Постоянно горящий
	# бордер был бы шумом — телеграф обязан что-то СООБЩАТЬ.
	return {
		CrewKit.ARCHER: {"line": "ЛКМ — полив", "armed": _lmb_down},
		&"pikeman": {"line": spear, "armed": _super_cd <= 0.0},
		&"worker": {"line": "вал — пока только в подземелье", "armed": false},
		&"fire_mage": {"line": "залп — пока только в подземелье", "armed": false},
	}


## Подсказка кнопок отряда: называем только то, что в ЭТОМ составе реально
## работает — обещать «удар вокруг» без копейщиков нельзя. Откат показываем
## цифрой: игрок должен видеть, ждать ему или жать.
func _hint_text() -> String:
	var archers: int = 0
	var pikemen: int = 0
	for m in _squad.members:
		if not is_instance_valid(m):
			continue
		if m is ArcherSoldier:
			archers += 1
		elif m.soldier_type == &"pikeman":
			pikemen += 1
	var parts: Array[String] = ["WASD — вести"]
	if archers > 0:
		parts.append("ЛКМ — полив")
	if pikemen > 0:
		parts.append("ПРОБЕЛ — удар (%s)"
				% ("готов" if _super_cd <= 0.0 else "%.1fс" % _super_cd))
	return "  ·  ".join(parts)


## Зажата ли кнопка слота. Нужна ИМЕННО удерживаемость: полив живёт, пока держишь.
func _bind_held(slot: int) -> bool:
	match slot:
		CrewKit.BIND_LKM:
			return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		CrewKit.BIND_SPACE:
			return Input.is_key_pressed(KEY_SPACE)
		CrewKit.BIND_RMB:
			return Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	return false


## Дальность полива — та же, что положил CrewKit при сборке лучника.
func _archer_range() -> float:
	return float(CrewKit.default_cfg().get("archer_range", 12.0))


## Цель полива: скелет в дальности от центра строя, в секторе прицела; из
## подходящих — ближайший к ЛУЧУ курсора. Курсор ведёт огонь как стик.
func _ray_target(c: Vector3, dir: Vector3) -> Node3D:
	var range_sq: float = _archer_range() * _archer_range()
	var best: Node3D = null
	var best_off: float = INF
	for sk in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if not is_instance_valid(sk) or not (sk is Node3D):
			continue
		var to := Vector3((sk as Node3D).global_position.x - c.x, 0.0,
				(sk as Node3D).global_position.z - c.z)
		var dsq: float = to.length_squared()
		if dsq > range_sq or dsq < 0.0001:
			continue
		if dir.dot(to / sqrt(dsq)) < aim_dot:
			continue
		var off: float = (to - dir * to.dot(dir)).length()
		if off < best_off:
			best_off = off
			best = sk as Node3D
	return best


## ОЧЕРЕДЬ, А НЕ ПОПКОРН: лучники разводятся по фазе внутри общего такта, и залп
## читается как пулемётная очередь, а не «кто когда».
func _stagger_archers() -> void:
	var archers: Array = []
	for m in _squad.members:
		if is_instance_valid(m) and m is ArcherSoldier:
			archers.append(m)
	if archers.size() < 2:
		return
	var cfg: Dictionary = CrewKit.default_cfg()
	var beat: float = (float(cfg.get("archer_cd_min", 0.64))
			+ float(cfg.get("archer_cd_max", 0.76))) * 0.5
	var step: float = beat / float(archers.size())
	for i in range(archers.size()):
		archers[i].set_fire_phase(step * float(i))


## ПРОБЕЛ: удар копейщиков ВОКРУГ строя. Урон масштабируется числом копейщиков —
## потерял половину отряда, потерял и половину удара.
func _spear_super(c: Vector3) -> void:
	if _super_cd > 0.0 or c == Vector3.INF:
		return
	var pikemen: int = 0
	for m in _squad.members:
		if is_instance_valid(m) and m.soldier_type == &"pikeman" \
				and m.bind_slot == CrewKit.BIND_SPACE:
			pikemen += 1
	if pikemen <= 0:
		EventBus.tutorial_hint.emit("Нет копейщиков — удар вокруг недоступен", 1.6)
		return
	_super_cd = super_cooldown
	AoeVisual.spawn_expanding_ring(get_tree().current_scene, Vector3(c.x, 0.05, c.z),
			super_radius, 0.28, Color(1.0, 0.55, 0.2, 0.9))
	EventBus.camera_shake.emit(0.5, c)
	var r_sq: float = super_radius * super_radius
	var dmg: float = super_damage_per_gnome * float(pikemen)
	for sk in get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP):
		if not is_instance_valid(sk) or not (sk is Node3D) or (sk as Node).is_queued_for_deletion():
			continue
		var to := Vector3((sk as Node3D).global_position.x - c.x, 0.0,
				(sk as Node3D).global_position.z - c.z)
		# Стена между строем и целью держит удар — сквозь стены не бьём.
		if to.length_squared() > r_sq or not _los_clear(c, (sk as Node3D).global_position):
			continue
		var dir: Vector3 = to.normalized() if to.length_squared() > 0.0001 \
				else Vector3(randf() - 0.5, 0.0, randf() - 0.5).normalized()
		Damageable.try_damage(sk, dmg, super_hitstop, dir, true)
		if is_instance_valid(sk) and not (sk as Node).is_queued_for_deletion() \
				and sk.has_method(&"apply_knockback"):
			sk.call(&"apply_knockback", dir * super_knockback + Vector3.UP * 2.0, 0.25)


func _los_clear(a: Vector3, b: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(a.x, 0.9, a.z), Vector3(b.x, 0.9, b.z),
			Layers.TERRAIN | Layers.WALL_GATE_BLOCK)
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## Точка под курсором на земле (y=0). Камеру берём активную — при высадке ею
## владеет риг отряда.
func _cursor_ground_point() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.INF
	var mp: Vector2 = get_viewport().get_mouse_position()
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(
			cam.project_ray_origin(mp), cam.project_ray_normal(mp))
	if hit == null:
		return Vector3.INF
	return hit
