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
## Число зубцов-делений по дуге стены (крепостной верх). Нечётное → по краям
## мерлоны (углы сплошные). Поднятых мерлонов = ceil(teeth/2).
@export var wall_teeth: int = 5
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

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _collision: CollisionShape3D = $CollisionShape3D


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
	if _mesh != null:
		_mesh.material_override = _make_blueprint_material()
		_set_build_progress(0.02)


func _process(delta: float) -> void:
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
		var root: Node = get_tree().current_scene
		if root != null:
			AoeVisual.spawn_dust(root, global_position)
		# Готовое здание становится разрушаемой целью и физическим препятствием —
		# скелеты атакуют его как палатку/пост, упираются как в палисад.
		_activate_combat()
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
func _activate_combat() -> void:
	if _destroyed:
		return
	_hp = hp_max
	Damageable.register(self)
	add_to_group(Enemy.TARGET_GROUP)
	collision_layer = Layers.CAMP_OBSTACLE | Layers.PALISADE_OBSTACLE
	if wall_thin:
		add_to_group(Enemy.MELEE_ONLY_TARGET_GROUP)
		add_to_group(&"navmesh_source")


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
	if _collision != null:
		# Грубый bounding-box под grab/rest свободного блока (точная форма для
		# монтажа не нужна — смонтированный блок заморожен и на слое MOUNTED_MODULE).
		var box := BoxShape3D.new()
		var depth := outer_radius - inner_radius
		var width := 2.0 * outer_radius * sin(deg_to_rad(sector_deg) * 0.5)
		box.size = Vector3(maxf(width, 0.2), height, maxf(depth, 0.2))
		_collision.shape = box
		_collision.position = Vector3.ZERO


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
	# Сплошное тело стены до уровня проёмов.
	_add_arc_box(st, c, -half, half, y_bottom, crenel_top)
	# Зубцы-мерлоны: чётные деления поднимаются до полной высоты.
	var teeth: int = maxi(1, wall_teeth)
	var step := (2.0 * half) / float(teeth)
	for i in range(teeth):
		if i % 2 == 0:
			var a0 := -half + float(i) * step
			# Лёгкое перекрытие с телом, чтобы не было копланарных граней.
			_add_arc_box(st, c, a0, a0 + step, crenel_top - 0.03, y_top)
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
	if _material == null:
		return
	_material.emission_energy_multiplier = HIGHLIGHT_EMISSION if value else BASE_EMISSION


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
