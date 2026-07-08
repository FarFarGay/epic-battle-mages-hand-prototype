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
	# Срез «Грузовое основание» (+кап трюма) УБРАН из каталога 2026-07-07: трюм в
	# живом пути всегда пуст (дерево продаётся на сдаче, руду никто не возит) —
	# покупка была «в никуда». Код install() понимает cap_bonus — вернуть = вернуть
	# запись (git). Оживление трюма рудой вылазок — дизайн-кандидат (SPEC).
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
## Очередь: сколько быстрых залпов на один каст (клик → burst_count залпов).
@export var burst_count: int = 4
## Пауза между залпами очереди (сек). 4 × 0.12с ≈ очередь за треть секунды.
@export var burst_interval: float = 0.12
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
## Радиус вылета болта от оси башни (чуть за гранью корпуса BODY_RADIUS).
const MUZZLE_RADIUS := 1.3

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


## ОЧЕРЕДЬ: burst_count быстрых залпов по точке. Первый сразу (false = стрелять
## нечем, каст отменяется), остальные по таймерам. Каждый залп заново ищет цель
## у точки — очередь «ведёт» врага, пока он крутится возле клика. WeakRef в
## лямбдах — без «Lambda capture freed», если башня погибнет посреди очереди.
func fire_burst(point: Vector3) -> bool:
	if not fire_volley(point):
		return false
	var ref: WeakRef = weakref(self)
	for i in range(1, maxi(burst_count, 1)):
		get_tree().create_timer(burst_interval * float(i)).timeout.connect(func() -> void:
			var me: TowerUpgrades = ref.get_ref() as TowerUpgrades
			if me != null and me.is_inside_tree():
				me.fire_volley(point))
	return true


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
	for s in get_tree().get_nodes_in_group(SoldierGnome.SOLDIER_GROUP):
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


# --- Визуал срезов: СИЛУЭТ БАШНИ НЕ МЕНЯЕТСЯ (декор заподлицо на корпусе) ---

## Башня — ЛАДЬЯ: тело вращения по профилю «радиус-по-высоте» (юбка → ствол с
## сужением → перехват шеи → воротник). Декор обязан считать радиус НА СВОЕЙ
## высоте — иначе висит в воздухе у сужений. КОПИЯ tools/bake_tower.gd::_profile();
## при перевыпечке модели синхронизировать. (x = локальный Y, y = радиус.)
const BODY_PROFILE: Array = [
	Vector2(-3.00, 1.16), Vector2(-2.60, 1.16), Vector2(-2.42, 0.96),
	Vector2(-2.30, 0.92), Vector2(0.55, 0.80), Vector2(1.25, 0.86),
	Vector2(1.45, 0.76), Vector2(1.72, 1.02), Vector2(2.25, 1.22),
	Vector2(2.48, 1.20),
]
## Граней тела вращения (bake_tower.LATHE_SIDES) — грань-центры на (i+0.5)·11.25°.
const BODY_FACETS := 32
## Родной каменный материал башни (кирпич, triplanar — ложится на любую форму без
## UV). Цоколь основания из него сливается с корпусом.
const STONE_MAT: Material = preload("res://models/materials/tower_stone.tres")

## Заплатки брони: (грань 0..31, локальный Y, ширина, высота) — вразнобой по стволу,
## вперемешку с открытым камнем. Y держим на пологих участках профиля (ствол,
## −2.2…+1.3) — на крутых (юбка/шея/воротник) пластина отрывалась бы от стены.
## Фиксированный список — детерминированный вид.
const HULL_PATCHES: Array = [
	[1, -1.9, 0.46, 0.56], [4, 0.6, 0.4, 0.5], [6, -0.5, 0.5, 0.62],
	[9, 1.0, 0.38, 0.44], [11, -1.3, 0.42, 0.52], [14, 0.1, 0.48, 0.58],
	[17, -2.1, 0.4, 0.48], [19, 0.9, 0.44, 0.56], [22, -0.9, 0.38, 0.46],
	[25, 0.75, 0.42, 0.5], [27, -1.6, 0.48, 0.6], [30, 0.35, 0.4, 0.52],
	[2, 1.2, 0.36, 0.42], [12, -2.0, 0.44, 0.5],
]

## Декор среза на корпусе башни. Кладём в VisualRoot — наследует bob/крен/отдачу
## корпуса и гибнет вместе с ним.
func _build_slice_visual(id: StringName, data: Dictionary) -> void:
	if _visual_root == null:
		return
	var root := Node3D.new()
	root.name = "Slice_%s" % id
	_visual_root.add_child(root)
	var y: float = float(data.get("height", 0.0))
	match id:
		&"hold":
			# ОСНОВАНИЕ ЧУТЬ ПОШИРЕ: конус-цоколь поверх юбки ладьи (юбка: r=1.16 до
			# y=−2.6; цоколь низ 1.42 → верх 1.19, накрывает её целиком). Родной
			# камень — силуэт меняется только у земли. Ворота-люки складов — на
			# стволе над юбкой.
			var plinth := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 1.19
			cm.bottom_radius = 1.42
			cm.height = 0.55
			cm.radial_segments = BODY_FACETS
			plinth.mesh = cm
			plinth.material_override = STONE_MAT
			root.add_child(plinth)
			plinth.position = Vector3(0, y, 0)
			for a in range(4):
				var f: int = a * 8 + 4  # между окнами арбалета (те на a*8)
				_body_facet_box(root, f, -2.0, Vector3(0.46, 0.5, 0.05), Color(0.5, 0.4, 0.26), 0.02)
				_body_facet_box(root, f, -2.0, Vector3(0.46, 0.06, 0.05), Color(0.34, 0.27, 0.18), 0.035)
		&"arbalest":
			# ТОЛЬКО ОКНА: бойница-щель со стальной рамой заподлицо на гранях корпуса
			# по 4 сторонам света. Никаких колец/ярусов — силуэт нетронут.
			for a in range(4):
				var f: int = a * 8
				_body_facet_box(root, f, y, Vector3(0.3, 0.5, 0.05), Color(0.42, 0.45, 0.52), 0.02)   # рама
				_body_facet_box(root, f, y, Vector3(0.14, 0.4, 0.06), Color(0.06, 0.06, 0.08), 0.035)  # щель
		&"hull":
			# ЗАПЛАТКИ: стальные пластины вразнобой по всему корпусу, вперемешку с
			# открытым камнем. Каждая заподлицо на своей грани, на крупных — заклёпки.
			var steel: Color = data.get("icon_color", Color(0.62, 0.68, 0.78))
			for p in HULL_PATCHES:
				var arr := p as Array
				var f: int = int(arr[0])
				var py: float = float(arr[1])
				var w: float = float(arr[2])
				var h: float = float(arr[3])
				_body_facet_box(root, f, py, Vector3(w, h, 0.04), steel, 0.02)
				if w >= 0.44:  # крупная пластина — пара заклёпок по вертикали
					for dy in [-h * 0.32, h * 0.32]:
						_body_facet_box(root, f, py + dy, Vector3(0.07, 0.07, 0.05), Color(0.3, 0.33, 0.4), 0.035)


## Радиус корпуса-ладьи на высоте y (lerp по BODY_PROFILE). Ниже юбки/выше
## воротника — крайние значения.
func _body_radius_at(y: float) -> float:
	var prev: Vector2 = BODY_PROFILE[0]
	if y <= prev.x:
		return prev.y
	for i in range(1, BODY_PROFILE.size()):
		var cur: Vector2 = BODY_PROFILE[i]
		if y <= cur.x:
			var t: float = (y - prev.x) / maxf(cur.x - prev.x, 0.0001)
			return lerpf(prev.y, cur.y, t)
		prev = cur
	return prev.y


## Декор-бокс НА ГРАНИ КОРПУСА башни: плоскостью наружу, по центру грани facet
## (0..31), на радиусе профиля ДЛЯ ЭТОЙ ВЫСОТЫ (ладья сужается — константный радиус
## вешал декор в воздух). proud — выступ из плоскости грани (≈0.02-0.04 = заподлицо).
## Угловая конвенция как у пекаря (x=cos, z=sin); центр грани — на полшага 11.25°.
func _body_facet_box(parent: Node3D, facet: int, y: float, size: Vector3, color: Color, proud: float) -> MeshInstance3D:
	var ang: float = (float(facet) + 0.5) * TAU / float(BODY_FACETS)
	var dir := Vector3(cos(ang), 0.0, sin(ang))
	var dist: float = _body_radius_at(y) * cos(PI / float(BODY_FACETS)) - size.z * 0.5 + proud
	var mi := _slice_box(parent, size, dir * dist + Vector3(0, y, 0), color)
	mi.rotation.y = atan2(dir.x, dir.z)
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
