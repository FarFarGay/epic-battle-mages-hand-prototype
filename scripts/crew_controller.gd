extends Node3D
## ⭐⭐ ЭКИПАЖ ЛАДЬИ В БОЛЬШОМ МИРЕ (2026-08-11). Переносит модель данжа на
## уровень с башней: есть гномы, у гномов есть Ладья, в неё можно сесть и выйти.
##
## Суть одна и та же в обе стороны:
##   ЭКИПАЖ ВНУТРИ  → играешь башней (её штатный контроллер, рука, камера);
##   ЭКИПАЖ СНАРУЖИ → башня встала зданием, WASD ведёт ОТРЯД.
## Третьего состояния нет, и «отправить артель куда-то» тоже нет.
##
## ⚙ ПОЧЕМУ ОТДЕЛЬНЫЙ КОМПОНЕНТ, А НЕ dungeon_sandbox.gd НА КОРНЕ УРОВНЯ.
## Тот скрипт (7к строк) в _ready жёстко требует $Banner и $Camera3D и строит
## СВОЙ мир — комнаты, волны, сундуки, экран сбора. На level_rooms он падает на
## первой строке и тянет за собой весь данж. Здесь нужен только контроллер, а
## юниты и деформация строя УЖЕ общие: аддитивные поля живут в SoldierGnome
## (body_pull/steer_grip, дефолт «выкл»), желе — в Squad (jelly_*). Поэтому
## компонент компактный: ход тела + переключение владельца WASD.
##
## ⚙ ГНОМОВ НЕ СПАВНИТ. Собирает в отряд тех, кто уже есть в сцене (кем бы они
## ни были заспавнены — стартовым спавнером или переносом из подземелья). Так
## компонент не спорит за право рождать гномов и переживает смену источника.

const CREW_WIDGET_SCENE: PackedScene = preload("res://scenes/crew_widget.tscn")

## Стартуем с гномами ВНУТРИ: они приехали из подземелья в башне (DESIGN §2.2).
@export var start_crewed: bool = true
## Дистанция посадки по E — та же логика, что в ангаре интро.
@export var board_distance: float = 8.0

@export_group("Ход отряда (модель данжа)")
## Скорость точки строя и отзывчивость руления (1/с). Числа сняты с финальной
## настройки данжа — там они прошли три итерации фидбека, заново не подбираем.
@export var move_speed: float = 7.5
@export var handling: float = 10.0
## Множитель торможения, когда клавиши отпущены (<1 = докатывается).
@export var brake_mult: float = 0.6
## Пружина «гном → слот» и потолок её вклада (SoldierGnome.body_*).
@export var body_pull: float = 10.0
@export var body_pull_max: float = 6.0
## Мягкая сцепка якоря с фактическим центром отряда (1/с).
@export var anchor_pull: float = 3.0
## Скорость самих тел. Каталожная у мирных гномов ~2.2–2.4 м/с — под «ходит по
## делам», а не под управление отрядом: строй еле полз (замер 2.5 м/с при точке
## строя 7.5). Данж поднимает её ровно так же.
@export var unit_speed: float = 6.0
## Сцепление тел и вязкость хвоста строя (желе).
@export var unit_grip: float = 16.0
@export var grip_tail: float = 0.68
@export var formation_spacing: float = 1.35
@export_group("")

var _squad: Squad = null
var _tower: Node3D = null
var _rig: Node = null
var _widget: CanvasLayer = null
## Узел-цель камеры, когда рулим отрядом: камера следит за ним, а не за башней.
var _focus: Node3D = null
var _crewed: bool = true
var _vel: Vector3 = Vector3.ZERO
## Якорь тела — аналог center_body у Pathogenic. Слоты НЕЛЬЗЯ вешать прямо на
## центроид: слоты считаются от гномов, гномы тянутся к слотам, и контур сам
## себя разгоняет. Якорь эту петлю рвёт — его интегрирует ход, а не группа.
var _anchor: Vector3 = Vector3.INF
var _e_was_down: bool = false


func _ready() -> void:
	_focus = Node3D.new()
	_focus.name = "SquadFocus"
	add_child(_focus)
	_widget = CREW_WIDGET_SCENE.instantiate() as CanvasLayer
	add_child(_widget)
	_widget.connect(&"leave_requested", _on_leave_pressed)
	_widget.connect(&"rebuild_requested", _on_rebuild_pressed)
	# Пересборка состава живёт пока только в подземелье (там для неё есть
	# комната-предбанник). Гасим кнопку честно, а не делаем вид, что работает.
	_widget.call(&"set_rebuild_enabled", false)
	call_deferred(&"_late_setup")


## Отложенно: башня, риг и гномы могут ready'иться позже нас (порядок детей).
func _late_setup() -> void:
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	_tower = get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	_rig = get_tree().get_first_node_in_group(CameraRig.CAMERA_RIG_GROUP)
	_collect_squad()
	_set_crewed(start_crewed)


## Отряд = все живые гномы сцены. Строй — «черепаха» с мягким HOLD: стрельба
## приоритетнее марша (strict=false), как в данже.
func _collect_squad() -> void:
	_squad = Squad.new()
	_squad.hold_grid = true
	_squad.grid_spacing_scale = formation_spacing
	for n in get_tree().get_nodes_in_group(SoldierGnome.SOLDIER_GROUP):
		if n is SoldierGnome and is_instance_valid(n):
			_squad.add_member(n as SoldierGnome)
	var c: Vector3 = _squad.compute_center()
	_squad.command_hold(c if c != Vector3.INF else global_position, false)


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
		# Сел в кабину — снимаем режим экипажа: пусть снова живёт своей логикой,
		# если его когда-нибудь выпустят не через нас.
		m.set_crew_mode(not on)
		if on and _tower != null and is_instance_valid(_tower):
			g.global_position = _tower.global_position + Vector3(0.0, 4.5, 0.0)
	# Камера: за башней в кабине, за отрядом снаружи.
	if _rig != null and is_instance_valid(_rig):
		if on:
			_rig.call(&"clear_focus_override")
		else:
			_rig.call(&"set_focus_override", _focus)
	if _widget != null:
		_widget.visible = on
	_anchor = Vector3.INF
	_vel = Vector3.ZERO


func _on_leave_pressed() -> void:
	if not _crewed or _squad == null or _tower == null or not is_instance_valid(_tower):
		return
	_set_crewed(false)
	# Высаживаем кольцом вокруг корпуса — на землю, а не на origin башни:
	# у неё центр висит высоко (y≈5), гномы оказались бы в воздухе.
	var n: int = maxi(_squad.members.size(), 1)
	var i: int = 0
	var t: Vector3 = _tower.global_position
	for m in _squad.members:
		if not is_instance_valid(m):
			continue
		var a: float = TAU * float(i) / float(n)
		(m as Node3D).global_position = Vector3(
			t.x + cos(a) * 5.0, _ground_y(), t.z + sin(a) * 5.0)
		i += 1
	_squad.hold_position = Vector3(t.x, 0.0, t.z)
	EventBus.tutorial_hint.emit("Экипаж снаружи. WASD ведёт отряд, [E] у башни — вернуться", 5.0)


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


## Земля под отрядом. Уровень плоский на y=0, но берём от гнома, если он есть:
## так высадка не проваливается, если пол когда-нибудь сместят.
func _ground_y() -> float:
	for m in _squad.members:
		if is_instance_valid(m):
			return (m as Node3D).global_position.y
	return 0.0


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
	if _squad == null or _crewed:
		return
	# Состав Squad чистит сам по сигналу гибели члена — своего прохода не нужно.
	if _widget != null:
		_widget.call(&"set_crew", _squad.members)
	var c: Vector3 = _squad.compute_center()
	if c == Vector3.INF:
		return
	_focus.global_position = c
	var v: Vector2 = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	var has_input: bool = v.length_squared() > 0.0001
	var target := Vector3(v.x, 0.0, v.y) * move_speed if has_input else Vector3.ZERO
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
	# ⚠ УДЕРЖИВАЕМ РЕЖИМ СЛЕДОВАНИЯ. Мирный гном этого уровня живёт своей рабочей
	# логикой (ищет дерево, идёт в здание) и сам уходит из строя — тогда ветка
	# step_to_slot до него просто не доходит, и отряд плёлся рабочим шагом вместо
	# того, чтобы ехать (замер: 2.5 м/с при команде 7.5). Перекомандовываем ТОЛЬКО
	# на смене состояния, а не каждый кадр: command_hold шлёт сигнал.
	if _squad.state != Squad.State.HOLDING_POSITION:
		_squad.command_hold(_anchor, false)
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
		m.move_speed = unit_speed
		if not m.crew_mode:
			m.set_crew_mode(true)
		# Голова строя рулит жёстко, хвост вязче — тело перетекает за поворотом.
		m.steer_grip = lerpf(unit_grip, unit_grip * grip_tail, float(idx) / last)
		idx += 1
