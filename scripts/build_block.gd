class_name BuildBlock
extends CampModule
## Пустая нефункциональная болванка-блок — для отработки САМОГО процесса
## строительства (схватил рукой → поднёс к слоту кольца → защёлкнулся гранью
## наружу). Геймплея нет: ни стрельбы, ни HP, ни производства. Позже на её место
## въедут конкретные здания, HP+разрушение, починка гномами, связки.
##
## Форма — толстый сектор-«кусок пирога» (кольцевой сектор): внутренний радиус
## inner_radius, внешний outer_radius, высота height. При установке в грид
## (BuildGrid) блок через conform_to_cell принимает форму ЯЧЕЙКИ (кольцо/сегмент),
## грид ставит его лицом к ядру → секторы смыкаются в кольцо построек.
##
## Меш генерится процедурно вокруг точки центра кольца, лежащей в локале на
## -Z*mid (mid = (inner+outer)/2). Грид/слот через look_at смотрит -Z на центр,
## блок встаёт на радиусе mid → сектор ложится точно в ячейку.
##
## Свободный (не установленный) блок имеет компактную форму по умолчанию — она
## перезаписывается conform_to_cell в момент установки.
##
## Наследует от CampModule весь grab/mount-контракт; здесь только геометрия+визуал.

@export_group("Room shape")
## Внутренний/внешний радиус и угол — форма СВОБОДНОГО блока (компактная). При
## установке в грид перезаписываются под ячейку через conform_to_cell.
@export var inner_radius: float = 1.5
@export var outer_radius: float = 3.0
@export var sector_deg: float = 40.0
## Высота стен комнаты. Низкие, чтобы не возвышаться над харвестером.
@export var height: float = 1.6
## Тесселяция дуги (сегментов на сектор). Больше = глаже скругление.
@export var arc_segments: int = 6
## Класс размера блока = кольцо грида, куда он встаёт: 0 = большой (внутреннее
## кольцо, крупные ячейки), 1 = средний, 2 = малый. Грид пускает блок ТОЛЬКО в
## ячейки этого кольца. Свободная форма (inner/outer/sector выше) задаётся под
## размер этого кольца, чтобы блок «уже большой/средний» лёжа в поле.
@export var ring_tier: int = 0
## Стена-режим: тонкий блок — радиально занимает не всю ячейку, а тонкую ленту
## у внешнего края (wall_thickness). Заметно тоньше блока-комнаты.
@export var wall_thin: bool = false
## Радиальная толщина стены (если wall_thin).
@export var wall_thickness: float = 0.45
## Арк-длина периода «мерлон+проём» (м) крепостного верха. Шаг зубцов задаётся
## метрически (а не числом) → одинаковая ширина мерлонов в разных кольцах, и
## центры мерлонов ложатся на КРАЯ сегмента: крайние мерлоны — половинки, у двух
## соседних стен складываются в цельный зубец на стыке (ровный гребень без шва).
@export var wall_merlon_arc: float = 1.0
## Высота зубца как доля от height (на сколько мерлон выше проёма-крене́ля).
@export var wall_tooth_frac: float = 0.35
@export_group("")

## Тип здания из каталога CampBuildings (генератор/казарма/портал/стена). Грид
## читает его для подсчёта генераторов и стоимости. Пусто = безымянная болванка.
var building_id: StringName = &""
## Сколько СЕГМЕНТОВ кольца занимает здание (вдоль кольца): 1 = обычное,
## 2 = двойное (двойная стена). Грид ищет ряд из стольких ячеек.
var footprint: int = 1

## Стройка завершена — грид слушает, чтобы пересчитать генераторы (харвестер
## стартует только по ГОТОВЫМ генераторам).
signal built

## Damageable-контракт: эмитятся при уроне / разрушении. Грид слушает destroyed,
## чтобы освободить ячейку и пересчитать генераторы.
signal damaged(amount: float)
signal destroyed

## Прочность готового здания (HP). Берётся из каталога в configure(). Скелеты
## бьют здание как палатку/пост (Damageable + skeleton_target-группа). Урон
## считается только ПОСЛЕ постройки (во время подъёма-силуэта здание неуязвимо).
@export var hp_max: float = 100.0
var _hp: float = 0.0
var _destroyed: bool = false

## Готово ли здание (false пока идёт стройка-подъём). Генератор считается только
## когда built.
var is_built: bool = true
var _building: bool = false
var _build_t: float = 0.0
var _build_dur: float = 0.0

## Оплачено ли здание. Стоимость списывается ОДИН раз при первой установке;
## после этого здание можно поднять рукой и переставить в другую ячейку грида
## БЕСПЛАТНО (BuildGrid._charge_building пропускает оплату для purchased). Также
## защищает от удаления при неудачном релизе (см. BuildGrid._on_hand_released).
var purchased: bool = false

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _collision: CollisionShape3D = $CollisionShape3D
## Доп. CollisionShape3D под-клинья для широких дуг (стена на много ячеек):
## один convex на всю дугу «замостил» бы внутренность сектора. Пересобираются
## в _rebuild_collision при каждой смене формы.
var _collision_extra: Array[CollisionShape3D] = []
## Макс. угол одного под-клина коллизии (град). Дугу шире режем на части.
const MAX_WEDGE_DEG := 45.0

## Модель-ТЕЛО здания (из каталога "model", напр. паровая машина генератора в
## форме грид-клина). null если у здания своей модели нет (тогда тело = сектор-
## меш). Когда модель есть — она ЗАМЕНЯЕТ сектор как тело: сектор-меш виден только
## синим силуэтом во время стройки, а на готовом здании прячется. _gear —
## крутящийся узел внутри; _model_mats — per-instance дубли материалов для
## hit-flash / подсветки (общие .tres не мутируем).
var _machine: Node3D = null
var _gear: Node3D = null
var _model_mats: Array[StandardMaterial3D] = []
## Оригинальные emission-параметры дублей (по индексу с _model_mats): {enabled,
## emission, mult} — чтобы flash/подсветка восстанавливали базу (венты светятся).
var _model_mat_orig: Array = []
## Скорость вращения шестерни-маховика (рад/с) когда здание построено.
const GEAR_SPEED := 1.6


## Настроить блок под здание из каталога: класс размера, цвет, тонкая-стена.
## Вызывает Camp при спавне здания в руку. Геометрия под ячейку придёт позже,
## в conform_to_cell на установке.
func configure(id: StringName) -> void:
	building_id = id
	var d: Dictionary = CampBuildings.get_data(id)
	ring_tier = int(d.get("ring_tier", ring_tier))
	module_color = d.get("color", module_color)
	wall_thin = bool(d.get("thin", false))
	footprint = maxi(1, int(d.get("footprint", 1)))
	hp_max = float(d.get("hp", hp_max))
	_apply_visual()
	# Опциональная модель-тело здания (паровая машина генератора и т.п.). Если
	# задана — заменяет сектор как тело блока: прячем сектор-меш (он останется
	# только силуэтом стройки), показываем модель.
	var model_path: String = d.get("model", "")
	if model_path != "":
		_spawn_machine(model_path)
		if _mesh != null:
			_mesh.visible = false


## Инстансит модель-тело здания в начало координат блока (модель построена в той
## же системе, что и сектор: центрирована по Y, изогнута под клин). Кэширует узел
## "Gear" для вращения и дублирует материалы дочерних мешей под hit-flash/подсветку.
func _spawn_machine(path: String) -> void:
	var scene := load(path) as PackedScene
	if scene == null:
		return
	_machine = scene.instantiate() as Node3D
	if _machine == null:
		return
	add_child(_machine)
	_machine.position = Vector3.ZERO
	_gear = _machine.get_node_or_null("Gear") as Node3D
	# Per-instance дубли материалов — чтобы flash/подсветка не мутировали общие .tres.
	for mi in _machine.find_children("*", "MeshInstance3D", true, false):
		var src := (mi as MeshInstance3D).material_override
		if src is StandardMaterial3D:
			var dup: StandardMaterial3D = (src as StandardMaterial3D).duplicate()
			(mi as MeshInstance3D).material_override = dup
			_model_mats.append(dup)
			_model_mat_orig.append({
				"enabled": dup.emission_enabled,
				"emission": dup.emission,
				"mult": dup.emission_energy_multiplier,
			})


func _ready() -> void:
	super._ready()
	_build_geometry()
	_apply_visual()
	# Низ комнаты на земле. Слоты теперь чистые позиции (module_offset=0), весь
	# подъём — здесь: меш центрирован по Y (±height/2), значит origin держим на
	# height/2 над точкой слота.
	mount_lift = height * 0.5


## Принять форму ячейки грида (вызывает BuildGrid при установке): перестроить
## сектор-меш под кольцо/сегмент и пересчитать подъём. Поворот лицом к ядру и
## позицию задаёт сам грид.
func conform_to_cell(p_inner: float, p_outer: float, p_sector_deg: float) -> void:
	if wall_thin:
		# Тонкая лента у внешнего края ячейки — стена тоньше комнаты.
		inner_radius = maxf(p_inner, p_outer - wall_thickness)
		outer_radius = p_outer
	else:
		inner_radius = p_inner
		outer_radius = p_outer
	sector_deg = p_sector_deg
	_build_geometry()
	mount_lift = height * 0.5


## Цвет силуэта-чертежа во время стройки (синий полупрозрачный, как старый каркас).
const BLUEPRINT_COLOR := Color(0.5, 0.8, 1.0, 0.45)

## Запустить стройку: вместо здания показываем СИНИЙ ПОЛУПРОЗРАЧНЫЙ силуэт его
## формы, который растёт снизу вверх за dur секунд; на финише — пуфф частиц
## (тот же spawn_dust) и появляется настоящее здание. Грид зовёт после установки.
func start_construction(dur: float) -> void:
	_build_dur = maxf(dur, 0.01)
	_build_t = 0.0
	_building = true
	is_built = false
	# Во время стройки тело = синий силуэт сектора (растёт), модель скрыта.
	if _machine != null:
		_machine.visible = false
	if _mesh != null:
		_mesh.visible = true
		_mesh.material_override = _make_blueprint_material()
		_set_build_progress(0.02)


func _process(delta: float) -> void:
	# Шестерня машины крутится на готовом здании (генератор «работает»).
	if _gear != null and is_built and not _building:
		_gear.rotate_object_local(Vector3.UP, GEAR_SPEED * delta)
	if not _building:
		return
	_build_t += delta
	var f: float = clampf(_build_t / _build_dur, 0.0, 1.0)
	_set_build_progress(maxf(f, 0.02))
	if f >= 1.0:
		_building = false
		is_built = true
		# Возвращаем настоящий материал и полную форму.
		if _mesh != null:
			_mesh.scale.y = 1.0
			_mesh.position.y = 0.0
			_mesh.material_override = _material
		# Готово: если у здания есть модель-тело — она заменяет сектор (силуэт
		# прячем, показываем модель). Иначе тело остаётся сектором.
		if _machine != null:
			_mesh.visible = false
			_machine.visible = true
		var root: Node = get_tree().current_scene
		if root != null:
			AoeVisual.spawn_dust(root, global_position)
		# Готовое здание становится разрушаемой целью и физическим препятствием —
		# скелеты атакуют его как палатку/пост, упираются как в палисад.
		_activate_combat()
		# Готовое здание снова можно схватить рукой и переставить (во время
		# стройки оно было вне Grabbable — см. BuildGrid._place_run).
		Grabbable.register(self)
		built.emit()


## Сделать построенное здание боевым объектом: разрушаемая цель скелетов +
## физическое препятствие. Зовётся ОДИН раз на завершении стройки (силуэт-фаза
## неуязвима). По образцу PalisadeSegment/ArcherPost:
##   - Damageable.register + skeleton_target → скелеты агрятся и бьют.
##   - Стена (wall_thin) → ещё melee_only_target (ranged её игнорят — стрелять
##     в стену бесполезно) + navmesh_source (юниты огибают). Здания-комнаты —
##     обычная цель (лучники тоже могут обстреливать).
##   - collision_layer = CAMP_OBSTACLE|PALISADE_OBSTACLE: скелет (MASK_SKELETON)
##     и башня упираются как в стену. Смонтированный слой (MOUNTED_MODULE) при
##     этом перекрываем — здание стоит на земле, ложных контактов с башней нет.
## Это ворота? База — нет; GateBlock переопределяет на true. Грид различает
## ворота (другой слой, навмеш-проём, замена сегмента стены) через этот метод,
## не ссылаясь на класс GateBlock по имени (избегаем class-cache при типизации).
func is_gate() -> bool:
	return false


func _activate_combat() -> void:
	if _destroyed:
		return
	_hp = hp_max
	Damageable.register(self)
	add_to_group(Enemy.TARGET_GROUP)
	collision_layer = Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE
	# Любое готовое здание — препятствие навмеша: гномы/скелеты огибают его,
	# между зданиями остаются проходы-«улицы» (BuildGrid дёргает ребейк через
	# Camp.buildings_changed). Слой CAMP_OBSTACLE уже в маске навмеша (mask=33).
	add_to_group(&"navmesh_source")
	if wall_thin:
		add_to_group(Enemy.MELEE_ONLY_TARGET_GROUP)


## Здание поднято рукой для переноса (BuildGrid зовёт на захвате). Снимаем боевое
## состояние: пока здание в руке/в полёте, скелеты не должны его бить, и оно не
## препятствие. Combat вернётся сам при завершении переустановки (_activate_combat
## в конце стройки). Идемпотентно (повторный захват loose-блока безопасен).
## collision_layer уже сброшен на ITEMS в CampModule.detach_from_slot.
func on_picked_up() -> void:
	is_built = false
	remove_from_group(Enemy.TARGET_GROUP)
	remove_from_group(Enemy.MELEE_ONLY_TARGET_GROUP)
	remove_from_group(&"navmesh_source")
	remove_from_group(Damageable.GROUP)


## На время стройки силуэт приподнят над землёй на BUILD_LIFT, чтобы НЕ врезаться
## в пульсирующий пад ячейки (тот лежит на pad_y≈0.06). Пад читается как
## светящаяся площадка-основание, из которой растёт силуэт. На финише
## (_process, f>=1) блок садится на землю (position.y=0), пад уже гасится гридом.
const BUILD_LIFT := 0.12

## Высота силуэта = доля f, растёт от земли вверх (меш центрирован по Y, потому
## компенсируем позицию, чтобы низ оставался на земле + BUILD_LIFT над падом).
func _set_build_progress(f: float) -> void:
	if _mesh == null:
		return
	_mesh.scale.y = f
	_mesh.position.y = (f - 1.0) * height * 0.5 + BUILD_LIFT


func _make_blueprint_material() -> StandardMaterial3D:
	var bp := StandardMaterial3D.new()
	bp.albedo_color = BLUEPRINT_COLOR
	bp.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bp.emission_enabled = true
	bp.emission = Color(BLUEPRINT_COLOR.r, BLUEPRINT_COLOR.g, BLUEPRINT_COLOR.b)
	bp.emission_energy_multiplier = 0.5
	bp.cull_mode = BaseMaterial3D.CULL_DISABLED
	return bp


func _build_geometry() -> void:
	if _mesh != null:
		_mesh.mesh = _build_wall_mesh() if wall_thin else _build_sector_mesh()
	_rebuild_collision()


## Коллизия ПО ФОРМЕ СЕКТОРА из под-клиньев (convex). Один convex на всю дугу
## «замостил» бы внутренность (тонкая стена на пол-кольца → заполненный сектор/
## диск), поэтому дугу режем на куски ≤ MAX_WEDGE_DEG — каждый узкий клин
## повторяет форму. Радиальные торцы совпадают с гранями ячейки → в «улицы» не
## лезет; внутр. дуга мостится хордой (лёгкий бугор внутрь), внешняя — сэмплится.
func _rebuild_collision() -> void:
	for ex in _collision_extra:
		if is_instance_valid(ex):
			ex.queue_free()
	_collision_extra.clear()
	if _collision == null:
		return
	var c := Vector3(0.0, 0.0, -(inner_radius + outer_radius) * 0.5)
	var half := deg_to_rad(sector_deg) * 0.5
	var n_sub: int = maxi(1, int(ceil(sector_deg / MAX_WEDGE_DEG)))
	for i in range(n_sub):
		var a0: float = -half + (float(i) / float(n_sub)) * (2.0 * half)
		var a1: float = -half + (float(i + 1) / float(n_sub)) * (2.0 * half)
		var cs: CollisionShape3D
		if i == 0:
			cs = _collision
		else:
			cs = CollisionShape3D.new()
			add_child(cs)
			_collision_extra.append(cs)
		cs.shape = _build_wedge_convex(c, a0, a1)
		cs.position = Vector3.ZERO


## Convex-клин одной угловой под-дуги [a0,a1] (тот же локальный фрейм, что и меш).
func _build_wedge_convex(c: Vector3, a0: float, a1: float) -> ConvexPolygonShape3D:
	var hy := height * 0.5
	var pts := PackedVector3Array()
	for ea in [a0, a1]:
		var p_in: Vector3 = c + Vector3(sin(ea), 0.0, cos(ea)) * inner_radius
		pts.append(Vector3(p_in.x, hy, p_in.z))
		pts.append(Vector3(p_in.x, -hy, p_in.z))
	var osegs := 4
	for i in range(osegs + 1):
		var a: float = a0 + (float(i) / float(osegs)) * (a1 - a0)
		var p_out: Vector3 = c + Vector3(sin(a), 0.0, cos(a)) * outer_radius
		pts.append(Vector3(p_out.x, hy, p_out.z))
		pts.append(Vector3(p_out.x, -hy, p_out.z))
	var cv := ConvexPolygonShape3D.new()
	cv.points = pts
	return cv


## Кольцевой сектор, экструдированный по высоте. Центр кольца — в локале (0,0,-mid),
## origin блока (0,0,0) лежит на mid-радиусе. -Z = к центру (после look_at слота).
func _build_sector_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mid := (inner_radius + outer_radius) * 0.5
	var c := Vector3(0.0, 0.0, -mid)
	var half := deg_to_rad(sector_deg) * 0.5
	var up := Vector3(0.0, height * 0.5, 0.0)
	var segs: int = maxi(2, arc_segments)
	for i in range(segs):
		var t0 := -half + (float(i) / float(segs)) * (2.0 * half)
		var t1 := -half + (float(i + 1) / float(segs)) * (2.0 * half)
		# Радиаль на угле t: (sin t, 0, cos t); t=0 → +Z (наружу через origin).
		var d0 := Vector3(sin(t0), 0.0, cos(t0))
		var d1 := Vector3(sin(t1), 0.0, cos(t1))
		var pi0 := c + d0 * inner_radius
		var po0 := c + d0 * outer_radius
		var pi1 := c + d1 * inner_radius
		var po1 := c + d1 * outer_radius
		var n_out := (d0 + d1).normalized()           # радиаль наружу (среднее по грани)
		_quad(st, pi0 + up, po0 + up, po1 + up, pi1 + up, Vector3.UP)    # верх
		_quad(st, pi1 - up, po1 - up, po0 - up, pi0 - up, Vector3.DOWN)  # низ
		_quad(st, po0 - up, po1 - up, po1 + up, po0 + up, n_out)         # внешняя стена
		_quad(st, pi1 - up, pi0 - up, pi0 + up, pi1 + up, -n_out)        # внутренняя стена
	# Радиальные торцы (боковые стены) на крайних углах — нормаль по касательной.
	var dA := Vector3(sin(-half), 0.0, cos(-half))
	var dB := Vector3(sin(half), 0.0, cos(half))
	var piA := c + dA * inner_radius
	var poA := c + dA * outer_radius
	var piB := c + dB * inner_radius
	var poB := c + dB * outer_radius
	var nA := Vector3(-cos(half), 0.0, -sin(half))    # торец смотрит «назад» по углу
	var nB := Vector3(cos(half), 0.0, -sin(half))     # торец смотрит «вперёд» по углу
	_quad(st, piA - up, poA - up, poA + up, piA + up, nA)
	_quad(st, poB - up, piB - up, piB + up, poB + up, nB)
	return st.commit()


## Стена с крепостным верхом: сплошная нижняя часть на всю дугу + чередующиеся
## мерлоны-зубцы сверху (между ними проёмы-крене́ли). Тонкая (inner..outer).
func _build_wall_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := Vector3(0.0, 0.0, -(inner_radius + outer_radius) * 0.5)
	var half := deg_to_rad(sector_deg) * 0.5
	var y_bottom := -height * 0.5
	var y_top := height * 0.5
	var crenel_top := y_top - height * clampf(wall_tooth_frac, 0.05, 0.9)
	# Сплошное тело стены до уровня проёмов (на всю дугу — соседние тела смыкаются).
	_add_arc_box(st, c, -half, half, y_bottom, crenel_top)
	# Мерлоны с метрически-выровненным шагом: центры на -half + k·T (k=0..m),
	# где T подобран так, что период ≈ wall_merlon_arc по арк-длине. Крайние
	# мерлоны (k=0, k=m) обрезаны краем сегмента → ПОЛОВИНКИ: у двух соседних
	# стен они складываются в цельный зубец на стыке. Мерлон = ±T/4 вокруг центра
	# (половина периода — зубец, половина — проём).
	var mid_r := (inner_radius + outer_radius) * 0.5
	var arc_len := 2.0 * half * mid_r
	var m := maxi(1, int(round(arc_len / maxf(wall_merlon_arc, 0.2))))
	var t_step := (2.0 * half) / float(m)
	var hw := t_step * 0.25
	for k in range(m + 1):
		var center := -half + float(k) * t_step
		var a0 := maxf(center - hw, -half)
		var a1 := minf(center + hw, half)
		if a1 - a0 > 0.0001:
			# Лёгкое перекрытие с телом, чтобы не было копланарных граней.
			_add_arc_box(st, c, a0, a1, crenel_top - 0.03, y_top)
	return st.commit()


## Тонкая дуговая коробка (кольцевой сектор-слэб) inner..outer × [a0,a1] × [y0,y1]
## с явными нормалями наружу. Используется для тела стены и каждого зубца.
func _add_arc_box(st: SurfaceTool, c: Vector3, a0: float, a1: float, y0: float, y1: float) -> void:
	var yb := Vector3(0.0, y0, 0.0)
	var yt := Vector3(0.0, y1, 0.0)
	var segs: int = maxi(1, int(ceil((a1 - a0) / deg_to_rad(8.0))))
	for i in range(segs):
		var t0 := a0 + (a1 - a0) * float(i) / float(segs)
		var t1 := a0 + (a1 - a0) * float(i + 1) / float(segs)
		var d0 := Vector3(sin(t0), 0.0, cos(t0))
		var d1 := Vector3(sin(t1), 0.0, cos(t1))
		var pi0 := c + d0 * inner_radius
		var po0 := c + d0 * outer_radius
		var pi1 := c + d1 * inner_radius
		var po1 := c + d1 * outer_radius
		var n_out := (d0 + d1).normalized()
		_quad(st, pi0 + yt, po0 + yt, po1 + yt, pi1 + yt, Vector3.UP)
		_quad(st, pi1 + yb, po1 + yb, po0 + yb, pi0 + yb, Vector3.DOWN)
		_quad(st, po0 + yb, po1 + yb, po1 + yt, po0 + yt, n_out)
		_quad(st, pi1 + yb, pi0 + yb, pi0 + yt, pi1 + yt, -n_out)
	# Торцы на краях дуги — нормаль по касательной наружу.
	var dA := Vector3(sin(a0), 0.0, cos(a0))
	var dB := Vector3(sin(a1), 0.0, cos(a1))
	var piA := c + dA * inner_radius
	var poA := c + dA * outer_radius
	var piB := c + dB * inner_radius
	var poB := c + dB * outer_radius
	var nA := Vector3(-cos(a0), 0.0, sin(a0))
	var nB := Vector3(cos(a1), 0.0, -sin(a1))
	_quad(st, piA + yb, poA + yb, poA + yt, piA + yt, nA)
	_quad(st, poB + yb, piB + yb, piB + yt, poB + yt, nB)


## Квад из 2 треугольников с ЯВНОЙ нормалью наружу (не полагаемся на winding —
## generate_normals давал вывернутые грани при двусторонней отрисовке).
func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c2: Vector3, d: Vector3, n: Vector3) -> void:
	st.set_normal(n)
	st.add_vertex(a)
	st.set_normal(n)
	st.add_vertex(b)
	st.set_normal(n)
	st.add_vertex(c2)
	st.set_normal(n)
	st.add_vertex(a)
	st.set_normal(n)
	st.add_vertex(c2)
	st.set_normal(n)
	st.add_vertex(d)


## Уникальный материал на инстанс. Лёгкое собственное свечение цветом здания —
## чтобы читалось и ночью (харвестер/орбы светятся, а тусклый ночной свет здания
## добивает в тёмное). cull выключен: двусторонняя отрисовка процедурного меша.
const BASE_EMISSION := 0.45
const HIGHLIGHT_EMISSION := 1.2

func _apply_visual() -> void:
	if _mesh == null:
		return
	_material = StandardMaterial3D.new()
	_material.albedo_color = module_color
	_material.roughness = 0.85
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.emission_enabled = true
	_material.emission = module_color
	_material.emission_energy_multiplier = BASE_EMISSION
	_mesh.material_override = _material


## Подсветка при наведении руки: не гасим базовое свечение (иначе на un-highlight
## здание потемнело бы), а лишь усиливаем энергию emission.
func set_highlighted(value: bool) -> void:
	# Модель-тело: подсвечиваем дубли её материалов (восстанавливаем базу с учётом
	# светящихся вентов через сохранённые оригиналы).
	if not _model_mats.is_empty():
		for i in _model_mats.size():
			var m: StandardMaterial3D = _model_mats[i]
			if value:
				m.emission_enabled = true
				m.emission = highlight_color
				m.emission_energy_multiplier = HIGHLIGHT_INTENSITY
			else:
				var o: Dictionary = _model_mat_orig[i]
				m.emission_enabled = o["enabled"]
				m.emission = o["emission"]
				m.emission_energy_multiplier = o["mult"]
		return
	if _material == null:
		return
	_material.emission_energy_multiplier = HIGHLIGHT_EMISSION if value else BASE_EMISSION


## Красный блик «нельзя» — для отказа (например, не хватает ресурсов на следующую
## ячейку стены при прокрутке). Переиспользует damage-flash (тот же красный пульс).
func flash_reject() -> void:
	_flash_damage()


# --- Damageable (готовое здание) ---

## Damageable-контракт. Урон проходит только по ГОТОВОМУ зданию (во время
## стройки-силуэта _hp=0, но take_damage гейтит на is_built — силуэт неуязвим).
func take_damage(amount: float) -> void:
	if _destroyed or not is_built or amount <= 0.0:
		return
	_hp -= amount
	damaged.emit(amount)
	_flash_damage()
	if LogConfig.master_enabled:
		print("[BuildBlock:%s] урон %.1f, hp=%.1f/%.1f" % [str(building_id), amount, maxf(_hp, 0.0), hp_max])
	if _hp <= 0.0:
		_die()


## Разрушение. Из групп-целей выходим СРАЗУ до emit (queue_free отложен на конец
## кадра — см. [[reference_godot_queue_free_deferred]]), чтобы AoE-цепочки и скан
## скелетов не били труп. Грид слушает destroyed → освобождает ячейку.
func _die() -> void:
	if _destroyed:
		return
	_destroyed = true
	remove_from_group(Enemy.TARGET_GROUP)
	remove_from_group(Enemy.MELEE_ONLY_TARGET_GROUP)
	remove_from_group(&"navmesh_source")
	var root: Node = get_tree().current_scene
	if root != null:
		AoeVisual.spawn_dust(root, global_position)
	destroyed.emit()
	queue_free()


## Красный flash при ударе — по образцу PalisadeSegment/ArcherPost. Модифицирует
## per-instance _material (создан в _apply_visual), tween возвращает к базе.
func _flash_damage() -> void:
	# Модель-тело: красный flash по дублям её материалов, возврат к базе (венты
	# возвращаются к своему свечению через сохранённые оригиналы).
	if not _model_mats.is_empty():
		for i in _model_mats.size():
			var m: StandardMaterial3D = _model_mats[i]
			var o: Dictionary = _model_mat_orig[i]
			m.emission_enabled = true
			m.emission = Color(1.0, 0.2, 0.2, 1.0)
			m.emission_energy_multiplier = 2.5
			var tw := create_tween()
			tw.tween_property(m, "emission", o["emission"], 0.18)
			tw.parallel().tween_property(m, "emission_energy_multiplier", float(o["mult"]), 0.18)
		return
	if _material == null:
		return
	if not _material.emission_enabled:
		_material.emission_enabled = true
	var orig_emission: Color = _material.emission
	var orig_mult: float = _material.emission_energy_multiplier
	_material.emission = Color(1.0, 0.2, 0.2, 1.0)
	_material.emission_energy_multiplier = 2.5
	var tween := create_tween()
	tween.tween_property(_material, "emission", orig_emission, 0.18)
	tween.parallel().tween_property(_material, "emission_energy_multiplier", orig_mult, 0.18)
