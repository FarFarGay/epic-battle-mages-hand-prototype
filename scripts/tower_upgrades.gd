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
## не вытаскивает). Активных стволов = min(окон, лучников внутри). Огонь — СПЕЛЛ
## «Арбалетный залп» ([HandSpellArbalest]): покупка среза анлочит карточку в трее
## (SpellSystem.unlock), выбирается цифрой как магия, ПКМ-клик → fire_volley(точка).
## Своего AI-прицела нет: залп идёт по ближайшему врагу у точки клика.

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
		"hint": "2 ствола + карточка «Залп» в трее магии (выбор цифрой, клик — залп). Стреляют, пока в башне спрятаны лучники («В башню»).",
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

@export_group("Arbalest volley (спелл по клику)")
## Радиус поиска цели вокруг точки клика: ближайший враг в кольце = цель залпа.
## Нет врага — болты ложатся в саму точку (промах читаем, как у Искры).
@export var designate_radius: float = 3.0
## Дальше этого от башни окна не достают (чуть выше лучника, 22.5 — это же башня).
@export var fire_range: float = 28.0
@export var bolt_damage_min: float = 10.0
@export var bolt_damage_max: float = 16.0
## Болт быстрее и настильнее стрелы лучника (22 м/с, грав. 6) — читается как арбалет.
@export var bolt_speed: float = 30.0
@export var bolt_gravity: float = 3.0
## Разброс точек прицела болтов залпа (м) — залп «веером», не в одну точку.
@export var volley_scatter: float = 0.5
@export_group("")
@export var debug_log: bool = true
## ЧИТ (тест): поставить ВСЕ срезы бесплатно на старте — смотреть визуал/стрельбу
## без фарма монет. Выключить перед билдом.
@export var debug_install_all: bool = false
## ЧИТ (тест): считать, что в башне спрятано столько лучников (поверх реальных) —
## арбалеты стреляют без найма/прятки экипажа. 0 = выкл.
@export var debug_fake_crew: int = 0

const BOLT_SCENE: PackedScene = preload("res://scenes/arrow.tscn")
## Id спелла в SpellSystem/трее — анлочится покупкой среза арбалета.
const VOLLEY_SPELL_ID := &"arbalest_volley"
## Период пересчёта экипажа (скан группы soldier) — HUD-трей опрашивает
## can_volley каждые ~0.1с, скан троттлим кэшем по msec.
const CREW_SCAN_INTERVAL_MSEC := 300
## Радиус вылета болта от оси башни (за гранью яруса-среза SLICE_RADIUS).
const MUZZLE_RADIUS := 1.6

var _installed: Dictionary = {}          # slice id → true
var _windows: int = 0                    # стволов всего (срез арбалета куплен → 2)
var _crew: int = 0                       # лучников спрятано в башне (кэш скана)
var _crew_scan_msec: int = 0             # когда кэш _crew считался (0 = никогда)

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
			# Карточка «Арбалетный залп» появляется в трее заклинаний (выбор цифрой,
			# каст ПКМ). Идемпотентно; spell_unlocked сам пересоберёт трей HUD'а.
			if SpellSystem != null:
				SpellSystem.unlock(VOLLEY_SPELL_ID)
	_build_slice_visual(id, data)
	if debug_log and LogConfig.master_enabled:
		print("[TowerUpgrades] установлен срез %s" % id)


## Лучников спрятано в башне сейчас (экипаж). Скан троттлится кэшем — HUD-трей
## дёргает can_volley каждые ~0.1с. debug_fake_crew добавляется поверх реальных.
func crew_count() -> int:
	var now: int = Time.get_ticks_msec()
	if _crew_scan_msec == 0 or now - _crew_scan_msec >= CREW_SCAN_INTERVAL_MSEC:
		_crew_scan_msec = now
		_crew = _count_hidden_archers() + debug_fake_crew
	return _crew


func window_count() -> int:
	return _windows


# --- Арбалетный залп (дёргает HandSpellArbalest по ПКМ-касту) ---

## Готовы ли окна стрелять: срез куплен И есть экипаж внутри. Слот трея тусклый,
## пока false (лучников надо спрятать в башню командой «В башню»).
func can_volley() -> bool:
	return _windows > 0 and crew_count() > 0


## Залп по точке клика: ближайший враг в designate_radius от точки (и в fire_range
## от башни) — цель; врага нет → болты в саму точку (читаемый промах, как у Искры).
## Стволов в залпе = min(окон, экипажа), каждый болт с разбросом volley_scatter.
## Возвращает false, если стрелять нечем (нет окон/экипажа) — каст отменяется.
func fire_volley(point: Vector3) -> bool:
	if _tower == null or not can_volley():
		return false
	var active: int = mini(_windows, crew_count())
	var target: Node3D = _pick_target(point)
	var aim: Vector3 = point
	if target != null:
		aim = target.global_position + Vector3.UP * 0.4
	for _i in range(active):
		var jitter := Vector3(randf_range(-volley_scatter, volley_scatter), 0.0,
			randf_range(-volley_scatter, volley_scatter))
		_fire_bolt(aim + jitter)
	EventBus.tower_fired.emit(aim)  # отдача башни — залп как выстрел
	return true


## Экипаж = лучники со статусом «спрятан в башне» (команда «В башню»). Любой отряд.
func _count_hidden_archers() -> int:
	var n: int = 0
	for s in get_tree().get_nodes_in_group(&"soldier"):
		if is_instance_valid(s) and s is ArcherSoldier \
				and s.has_method(&"is_hidden_in_tower") and s.call(&"is_hidden_in_tower"):
			n += 1
	return n


## Цель залпа: ближайший к точке клика враг в designate_radius, при этом в fire_range
## от башни. Через Enemy.ENEMY_GROUP — все типы одинаково ([[feedback_symmetric_interactions]]).
func _pick_target(point: Vector3) -> Node3D:
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
		var dx: float = node.global_position.x - point.x
		var dz: float = node.global_position.z - point.z
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
func _fire_bolt(aim: Vector3) -> void:
	var arrow := BOLT_SCENE.instantiate() as Arrow
	if arrow == null:
		return
	get_tree().current_scene.add_child(arrow)
	arrow.damage = randf_range(bolt_damage_min, bolt_damage_max)
	arrow.speed = bolt_speed
	arrow.gravity = bolt_gravity
	var h: float = float((SLICE_CATALOG[&"arbalest"] as Dictionary).get("height", 0.3))
	var dir: Vector3 = aim - _tower.global_position
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	var muzzle: Vector3 = _tower.global_position + Vector3(0.0, h, 0.0) + dir * MUZZLE_RADIUS
	arrow.setup(muzzle, aim)


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
