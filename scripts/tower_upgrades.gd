class_name TowerUpgrades
extends Node3D
## Срезы-слои башни (покупаются на ВЕРФИ — PadBuilding role dock, окно в GameplayHud).
## Башня = здание из слоёв: каждый купленный срез добавляет видимый ярус на корпус и
## меняет характеристики САМОЙ башни — тех же чисел, что уже есть (кап трюма склада,
## max_hp, стволы). Ребёнок Tower (tower.tscn), визуал срезов кладёт в ../VisualRoot —
## ярусы наследуют motion-fx/крен/шаттер смерти вместе с корпусом.
##
## АРБАЛЕТНЫЕ ОКНА — железо без экипажа: стреляют только пока внутри башни спрятаны
## лучники (карточка отряда → «🏰 В башню», существующий hide_in_tower; F спрятанных
## не вытаскивает). Активных стволов = min(окон, лучников внутри). Огонь — ПО УКАЗУ
## РУКИ: враг в кольце DESIGNATE_RADIUS вокруг курсора → окна поливают болтами
## (пулемётный темп), курсор ушёл с врагов → тишина. Никакого своего AI-прицела.

const GROUP := &"tower_upgrades"

## Каталог срезов. Декларативный, как RoomBuildings.CATALOG: верфь-окно (GameplayHud)
## рисует карточки отсюда, install() читает эффект по ключам. cost — монеты (GoldBank).
## v1: каждый срез покупается ОДИН раз (лодаут/замена слоёв — следующая итерация).
## Числа — тест-значения.
const SLICE_CATALOG: Dictionary = {
	&"hold": {
		"name": "Грузовой ярус",
		"hint": "Трюм башни вместительнее: +30 к капу каждого материала.",
		"icon_color": Color(0.85, 0.66, 0.32, 1.0),
		"cost": {ResourcePile.ResourceType.SILVER: 5},
		"cap_bonus": 30,
		"height": -1.4,  # локальный Y яруса на корпусе (тело башни: −3…+3)
	},
	&"arbalest": {
		"name": "Арбалетные окна",
		"hint": "2 ствола. Стреляют, пока в башне спрятаны лучники («В башню»), по врагу у курсора руки.",
		"icon_color": Color(0.55, 0.6, 0.72, 1.0),
		"cost": {ResourcePile.ResourceType.SILVER: 8},
		"windows": 2,
		"height": 0.3,
	},
	&"hull": {
		"name": "Бронированный корпус",
		"hint": "Стальной пояс: +500 к прочности башни.",
		"icon_color": Color(0.62, 0.68, 0.78, 1.0),
		"cost": {ResourcePile.ResourceType.SILVER: 6},
		"hp_bonus": 500.0,
		"height": 1.5,
	},
}

@export_group("Arbalest fire (по указу руки)")
## Радиус «указки» вокруг курсора руки: враг в этом кольце = цель окон. Тот же
## масштаб, что кольцо squad-aim (3.5) — единый язык «рука указывает область».
@export var designate_radius: float = 3.0
## Дальше этого от башни окна не достают (чуть выше лучника, 22.5 — это же башня).
@export var fire_range: float = 28.0
## Темп ОДНОГО ствола (сек между болтами). 2 ствола × 0.45с ≈ 4.4 болта/сек — «пулемёт».
@export var bolt_cooldown: float = 0.45
@export var bolt_damage_min: float = 10.0
@export var bolt_damage_max: float = 16.0
## Болт быстрее и настильнее стрелы лучника (22 м/с, грав. 6) — читается как арбалет.
@export var bolt_speed: float = 30.0
@export var bolt_gravity: float = 3.0
@export_group("")
@export var debug_log: bool = true
## ЧИТ (тест): поставить ВСЕ срезы бесплатно на старте — смотреть визуал/стрельбу
## без фарма монет. Выключить перед билдом.
@export var debug_install_all: bool = false
## ЧИТ (тест): считать, что в башне спрятано столько лучников (поверх реальных) —
## арбалеты стреляют без найма/прятки экипажа. 0 = выкл.
@export var debug_fake_crew: int = 0

const BOLT_SCENE: PackedScene = preload("res://scenes/arrow.tscn")
## Цвета кольца-указки: нейтральное (арбалеты слушают руку) / цель захвачена.
## Язык HandSquadAim (голубой/красный) — «указ руки» везде выглядит одинаково.
const RING_COLOR := Color(0.4, 0.85, 1.0, 0.45)
const RING_COLOR_LOCKED := Color(1.0, 0.25, 0.25, 0.95)
## Период пересчёта экипажа (скан группы soldier) — не каждый кадр.
const CREW_SCAN_INTERVAL := 0.3
## Радиус вылета болта от оси башни (за гранью яруса-среза SLICE_RADIUS).
const MUZZLE_RADIUS := 1.6

var _installed: Dictionary = {}          # slice id → true
var _windows: int = 0                    # стволов всего (срез арбалета куплен → 2)
var _bolt_cd: Array[float] = []          # личный кулдаун каждого ствола
var _crew: int = 0                       # лучников спрятано в башне (кэш скана)
var _crew_scan_t: float = 0.0
var _hand: Hand = null
var _aim_ring: MeshInstance3D = null

@onready var _tower: Tower = get_parent() as Tower
@onready var _visual_root: Node3D = get_node_or_null("../VisualRoot") as Node3D


func _ready() -> void:
	add_to_group(GROUP)
	# Бут-принт: ловит «мёртвую» ноду при ручной правке .tscn (script= забыт → тишина).
	if debug_log and LogConfig.master_enabled:
		print("[TowerUpgrades] готов (башня=%s, визуал=%s)" % [_tower != null, _visual_root != null])
	if debug_install_all:
		# Deferred: склад (TowerStore) может быть ниже по дереву — кап трюма
		# применится после того, как вся сцена ready.
		call_deferred(&"_debug_install_all")


func _debug_install_all() -> void:
	for id in SLICE_CATALOG:
		install(id)


# --- Публичный API (верфь-окно в GameplayHud) ---

func is_installed(id: StringName) -> bool:
	return _installed.has(id)


## Установить срез: применить эффект к башне + нарастить видимый ярус. Оплата —
## на вызывающем (верфь списывает монеты ДО install). Повторная установка — no-op.
func install(id: StringName) -> void:
	if _installed.has(id) or not SLICE_CATALOG.has(id):
		return
	var data: Dictionary = SLICE_CATALOG[id]
	_installed[id] = true
	match id:
		&"hold":
			var store: Node = get_tree().get_first_node_in_group(Layers.TOWER_STORE_GROUP)
			if store != null and store.has_method(&"add_cap_bonus"):
				store.call(&"add_cap_bonus", int(data.get("cap_bonus", 0)))
		&"hull":
			if _tower != null:
				_tower.add_max_hp(float(data.get("hp_bonus", 0.0)))
		&"arbalest":
			_windows += int(data.get("windows", 0))
			_bolt_cd.resize(_windows)
			for i in range(_windows):
				_bolt_cd[i] = float(i) * 0.15  # стартовый разнос стволов
	_build_slice_visual(id, data)
	if debug_log and LogConfig.master_enabled:
		print("[TowerUpgrades] установлен срез %s" % id)


## Лучников спрятано в башне сейчас (для строки «экипаж N» в верфи).
func crew_count() -> int:
	return _crew


func window_count() -> int:
	return _windows


# --- Арбалеты: огонь по указу руки ---

func _physics_process(delta: float) -> void:
	if _windows <= 0 or _tower == null:
		return
	_crew_scan_t -= delta
	if _crew_scan_t <= 0.0:
		_crew_scan_t = CREW_SCAN_INTERVAL
		_crew = _count_hidden_archers() + debug_fake_crew
	var active: int = mini(_windows, _crew)
	for i in range(_bolt_cd.size()):
		_bolt_cd[i] = maxf(_bolt_cd[i] - delta, 0.0)
	if active <= 0:
		_clear_ring()
		return
	var cursor: Vector3 = _cursor_ground()
	if cursor == Vector3.INF:
		_clear_ring()
		return
	var target: Node3D = _pick_target(cursor)
	_update_ring(cursor, target != null)
	if target == null:
		return
	for i in range(active):
		if _bolt_cd[i] <= 0.0:
			_fire_bolt(target)
			_bolt_cd[i] = bolt_cooldown * randf_range(0.9, 1.15)


## Экипаж = лучники со статусом «спрятан в башне» (команда «В башню»). Любой отряд.
func _count_hidden_archers() -> int:
	var n: int = 0
	for s in get_tree().get_nodes_in_group(&"soldier"):
		if is_instance_valid(s) and s is ArcherSoldier \
				and s.has_method(&"is_hidden_in_tower") and s.call(&"is_hidden_in_tower"):
			n += 1
	return n


## Наземная точка курсора руки (как в HandSquadAim). Vector3.INF если руки нет.
func _cursor_ground() -> Vector3:
	if _hand == null or not is_instance_valid(_hand):
		_hand = get_tree().get_first_node_in_group(Hand.HAND_GROUP) as Hand
	if _hand == null:
		return Vector3.INF
	var p: Vector3 = _hand.cursor_world_position()
	p.y -= _hand.hand_height
	return p


## Цель: ближайший к КУРСОРУ враг в designate_radius, при этом в fire_range от башни.
## Через Enemy.ENEMY_GROUP — все типы одинаково ([[feedback_symmetric_interactions]]).
func _pick_target(cursor: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = designate_radius * designate_radius
	var range_sq: float = fire_range * fire_range
	var tower_pos: Vector3 = _tower.global_position
	for n in get_tree().get_nodes_in_group(Enemy.ENEMY_GROUP):
		if not is_instance_valid(n):
			continue
		var node := n as Node3D
		if node == null:
			continue
		var dx: float = node.global_position.x - cursor.x
		var dz: float = node.global_position.z - cursor.z
		var d: float = dx * dx + dz * dz
		if d >= best_d:
			continue
		var tx: float = node.global_position.x - tower_pos.x
		var tz: float = node.global_position.z - tower_pos.z
		if tx * tx + tz * tz > range_sq:
			continue
		best_d = d
		best = node
	return best


## Болт из окна: вылет с грани корпуса на стороне цели, высота — ярус арбалета.
## Переиспользуем Arrow (баллистика/урон/трейл), только быстрее и настильнее.
func _fire_bolt(target: Node3D) -> void:
	var arrow := BOLT_SCENE.instantiate() as Arrow
	if arrow == null:
		return
	get_tree().current_scene.add_child(arrow)
	arrow.damage = randf_range(bolt_damage_min, bolt_damage_max)
	arrow.speed = bolt_speed
	arrow.gravity = bolt_gravity
	var h: float = float((SLICE_CATALOG[&"arbalest"] as Dictionary).get("height", 0.3))
	var dir: Vector3 = target.global_position - _tower.global_position
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	var muzzle: Vector3 = _tower.global_position + Vector3(0.0, h, 0.0) + dir * MUZZLE_RADIUS
	var aim: Vector3 = target.global_position + Vector3.UP * 0.4
	arrow.setup(muzzle, aim)


## Кольцо-указка у курсора: видно, пока арбалеты слушают руку; краснеет на захвате.
func _update_ring(cursor: Vector3, locked: bool) -> void:
	if _aim_ring == null or not is_instance_valid(_aim_ring):
		_aim_ring = AoeVisual.spawn_ground_ring(
			get_tree().current_scene, cursor, designate_radius, 0.0, RING_COLOR)
	_aim_ring.global_position = cursor + Vector3.UP * 0.05
	var mat := _aim_ring.material_override as StandardMaterial3D
	if mat != null:
		var c: Color = RING_COLOR_LOCKED if locked else RING_COLOR
		mat.albedo_color = c
		mat.emission = Color(c.r, c.g, c.b, 1.0)


func _clear_ring() -> void:
	if is_instance_valid(_aim_ring):
		_aim_ring.queue_free()
	_aim_ring = null


func _exit_tree() -> void:
	_clear_ring()


# --- Визуал срезов (ярусы на корпусе) ---

## Радиус яруса-среза: чуть шире корпуса (r≈1.24 у выпеченной модели) — срез «надет»
## на башню и читается кольцом, не квадратной полкой.
const SLICE_RADIUS := 1.42
## Граней у яруса — как у корпуса башни (16-гранный цилиндр): срез ПО ФОРМЕ башни.
const SLICE_FACETS := 16

## Ярус на корпусе башни: гранёный цилиндр в форме корпуса + цветной обод-метка типа
## + деталь по типу среза. Кладём в VisualRoot — наследует bob/крен/отдачу корпуса и
## исчезает вместе с ним при смерти башни.
func _build_slice_visual(id: StringName, data: Dictionary) -> void:
	if _visual_root == null:
		return
	var root := Node3D.new()
	root.name = "Slice_%s" % id
	_visual_root.add_child(root)
	var y: float = float(data.get("height", 0.0))
	var color: Color = data.get("icon_color", Color.GRAY)
	match id:
		&"hold":
			# Деревянный грузовой ярус: бочковатое кольцо + два обруча-стяжки.
			_slice_tier(root, y, 0.8, Color(0.5, 0.4, 0.26))
			_slice_band(root, y - 0.28, Color(0.36, 0.28, 0.18), false)
			_slice_band(root, y + 0.28, Color(0.36, 0.28, 0.18), false)
			_slice_band(root, y, color, true)  # цветная метка типа
		&"arbalest":
			# Каменный ярус в цвет корпуса + 4 бойницы-окна по сторонам света.
			_slice_tier(root, y, 0.75, Color(0.52, 0.54, 0.6))
			_slice_band(root, y - 0.32, color, true)
			for a in range(4):
				var ang: float = float(a) * TAU / 4.0
				var dir := Vector3(cos(ang), 0.0, sin(ang))
				# Тёмная прорезь чуть утоплена в грань + узкий козырёк над ней.
				var slot := _slice_box(root, Vector3(0.42, 0.4, 0.16),
					dir * (SLICE_RADIUS - 0.02) + Vector3(0, y, 0), Color(0.07, 0.07, 0.09))
				slot.rotation.y = -ang + PI * 0.5  # плоскостью наружу, по грани
				var visor := _slice_box(root, Vector3(0.5, 0.08, 0.22),
					dir * (SLICE_RADIUS + 0.02) + Vector3(0, y + 0.26, 0), Color(0.4, 0.42, 0.48))
				visor.rotation.y = -ang + PI * 0.5
		&"hull":
			# Броневой ярус: стальное кольцо потолще + тёмные канты сверху/снизу.
			_slice_tier(root, y, 0.85, color)
			_slice_band(root, y - 0.36, Color(0.32, 0.35, 0.42), false)
			_slice_band(root, y + 0.36, Color(0.32, 0.35, 0.42), false)


## Гранёное кольцо-ярус по форме корпуса (16-гранный цилиндр радиуса SLICE_RADIUS).
func _slice_tier(parent: Node3D, y: float, h: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = SLICE_RADIUS
	cm.bottom_radius = SLICE_RADIUS
	cm.height = h
	cm.radial_segments = SLICE_FACETS
	mi.mesh = cm
	mi.material_override = _slice_mat(color, false)
	parent.add_child(mi)
	mi.position = Vector3(0, y, 0)
	return mi


## Тонкий обод поверх яруса: цветная метка типа среза (glow) или тёмный кант (без).
func _slice_band(parent: Node3D, y: float, color: Color, glow: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = SLICE_RADIUS + 0.05
	cm.bottom_radius = SLICE_RADIUS + 0.05
	cm.height = 0.1
	cm.radial_segments = SLICE_FACETS
	mi.mesh = cm
	mi.material_override = _slice_mat(color, glow)
	parent.add_child(mi)
	mi.position = Vector3(0, y, 0)
	return mi


func _slice_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _slice_mat(color, false)
	parent.add_child(mi)
	mi.position = pos
	return mi


func _slice_mat(color: Color, glow: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.2
	mat.roughness = 0.7
	if glow:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 0.9
	return mat
