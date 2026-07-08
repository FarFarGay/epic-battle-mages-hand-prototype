class_name PadBuilding
extends StaticBody3D
## Полимино-постройка на площадке вокруг качалки (тетрис-фигура из клеток сетки). ОДНА
## модель для всех ролей: защита / атака / добыча — пока различаются только цветом
## (функции = Фаза 2: контур-стена + навмеш, радиус стрельбы, буст соседством). Снап и
## занятость клеток — через [CityGrid]. group pad_building. Ставится мгновенно рукой
## ([HandPlaceAim]); ПКМ сносит.

const GROUP := &"pad_building"
## ЛКМ-захват рукой (то же действие, что у домика гномов) — клик по казарме = найм,
## клик по плавильне = ручная чеканка.
const ACTION_GRAB := &"hand_grab"
## Фолбэк типа отряда казармы, если в каталоге забыли squad_type (единая точка —
## раньше литерал был размазан по трём местам).
const DEFAULT_SQUAD_TYPE := &"archer_squad"

var building_id: StringName = &""
var _mask: Array = []        # Array[Vector2i] — клетки фигуры (локальные offset'ы)
var _role: StringName = &"defend"
## ЭКОНОМИКА-КВАРТАЛ по СОСЕДСТВУ (2026-06-30, контур-силуэт убран). ШАХТА (active, role mine)
## образует квартал, когда ВСЕ её грани (орто-соседние клетки) заняты САПОРТАМИ. Каждый ТИП сапорта
## крутит СВОЮ ось добычи (не общий множитель — разные параметры): ПЛАВИЛЬНЯ → СКОРОСТЬ (×темп),
## ЧЕКАННЫЙ ДВОР → НОМИНАЛ (платит монетой на тир выше: бронза→серебро→золото), ДОМ ГНОМОВ →
## ОБЪЁМ (×монет за выплату). Оси бинарны (тип есть/нет среди соседей). ПРАВИЛО КАТЕГОРИЙ: считаются
## только PRODUCTION/SOCIAL-сапорты. Все грани заняты → вспышка «собран» (fill 100%).
const MINE_RATE := 1.0          # базовая добыча шахты соло, монет/сек (без сапортов)
const MINE_SPEED_MULT := 2.0    # ПЛАВИЛЬНЯ (скорость): ×темп добычи, пока есть в зоне
const MINE_VOLUME_MULT := 2     # ДОМ ГНОМОВ (объём): ×монет за выплату, пока есть в зоне
                                # ЧЕКАННЫЙ ДВОР (номинал): монета на тир выше — см. _upgraded_coin
## НАСЕЛЕНИЕ (supply-пул, автолоад Population): СНАБЖЕНИЕ дают ДОМ и ЗАМОК (тела для всего — рабочие,
## солдаты, шахты); армия и работающие шахты слоты занимают. Дом дополнительно = ось «Объём» у шахты.
const HOUSING_POP := 4  # дом гномов → +слотов населения (он же ось «Объём» шахты — двойная роль)
const MINE_POP_DEMAND := 1  # работающая шахта на жиле занимает столько слотов (иначе простой)
## Ось «Гарнизон»: каждый барак в зоне-соседстве казармы даёт +1 БОЙЦА в её гарнизон (лучник ИЛИ
## копейщик — идентично, обе role barracks). НАСЕЛЕНИЕ барак НЕ даёт — бойца надо «заселить» из домов.
const HIRE_CAP_PER_BARRACK := 1
## Институт магии (role magic): тикает ману в башню (restore_mana) и открывает магические постройки.
## Это ПРОДЮСЕР квартала (как шахта): сапорты на гранях ускоряют ману (множители перемножаются).
const MANA_INSTITUTE_RATE := 3.0  # базовая мана/сек в башню (соло, без сапортов). Тюнится.
## Радиус кормления маной ОТ ИНСТИТУТА (XZ): башня ближе — мана течёт, дальше —
## нет. Заменил док-гейт с фоллбеком «нет дока → кормим глобально» (дыра: без
## построенного дока мана хуярила через всю карту). Одно правило, видимое глазами.
const INSTITUTE_FEED_RADIUS := 18.0
## «Защёлк» полного квартала: ВСЕ грани продюсера закрыты сапортами → комбо-множитель
## ТЕМПА поверх осей (шахта — монет/сек, институт — маны/сек). Один на всех продюсеров.
const FULL_QUARTER_BONUS := 1.5
# КЛИК-УРОВНИ зданий (Clash) СДЕЛАНЫ И ВЫПИЛЕНЫ 2026-07-07: дублировали
# полимино-квартал — второй путь к тому же множителю выработки. Прокачка
# продюсера = ТОЛЬКО квартал (оси граней + защёлк). Из Clash взят СБОР:
# шахта копит добычу видимой стопкой, собираешь башней/кликом (см. _tick_mine).
## FX «печати» установки: падение+сквош+пыль+рябь+тряска (см. play_place_impact).
const PlaceFx = preload("res://scripts/place_impact_fx.gd")
## Разгрузочная платформа: радиус парковки башни (XZ от центра платформы).
## Сдача ОДНОМОМЕНТНАЯ (заехал-сдал-поехал): монеты в казну сразу всей суммой,
## чанки-визуал вылетают волной, растянутой на UNLOAD_WAVE_SPREAD секунд.
const UNLOAD_RADIUS := 6.0
const UNLOAD_CHECK_INTERVAL := 0.25  # частота опроса «башня рядом и трюм не пуст?»
const UNLOAD_WAVE_SPREAD := 1.0      # разброс задержек чанков волны, сек
const MANA_MULT_CRYSTAL := 1.5    # Кафедра Волшебных свитков в зоне → ×темп
const MANA_MULT_RUNE := 2.0       # Осколок звёздной руды в зоне → ×темп (сильнее/дороже)
const MANA_MULT_HOUSE := 1.5      # Дом гномов в зоне → ×темп (соц-универсал, как «Объём» у шахты)
var _vein: OilDeposit = null  # жила под шахтой
var _mine_accum: float = 0.0  # дробный накопитель добычи (единицы целые)
var _quarter_was_full: bool = false  # был ли плот полностью заполнен в прошлый тик (вспышка единожды на завершение)
var _ind_flash_tween: Tween = null   # авто-скрытие плашки после flash_indicator (kill при повторе)
var _unload_cd: float = 0.0          # кулдаун очередной единицы разгрузки (платформа)
## Плавильня-сапорт: ровный дым (флавор «работает»).
var _smoke: GPUParticles3D = null
## Маркеры buff-слотов квартала (грани продюсера) — показываются в РЕЖИМЕ СТРОЙКИ (HandPlaceAim):
## пустая грань = открытый слот «займи для баффа», занятая сапортом = зелёная. Лениво, top_level,
## перекраска live в _process. Только у продюсеров (есть _plot_support_roles).
var _slot_ghost: Node3D = null
const SLOT_OPEN_COLOR := Color(0.55, 0.8, 1.0, 0.22)    # открытый слот — занять для баффа
const SLOT_FILLED_COLOR := Color(0.4, 1.0, 0.5, 0.5)    # занят сапортом — буфает
## Индикатор осей квартала над шахтой (плашка) — показывается при наведении руки (hover, см.
## set_highlighted). Видно, какие оси активны: скорость/номинал/объём. Реализован как 2D-панель
## (StyleBox + emoji-иконки) в SubViewport → Sprite3D-билборд (иконки в 2D рендерятся надёжно).
var _quarter_indicator: Sprite3D = null
var _quarter_indicator_vp: SubViewport = null
var _ind_title: Label = null
var _ind_rows: Array = []  # строки-Label плашки (наполняются per-role в _refresh_quarter_indicator)
## Всплывашка «+N» прибыли над шахтой + салют на каждую золотую (агрегируем, не чаще INTERVAL).
const POPUP_INTERVAL := 0.7
const POPUP_LIFETIME := 2.8
var _recv_amount: int = 0
var _recv_coin: int = ResourcePile.ResourceType.BRONZE  # каким номиналом платит шахта (двор поднимает тир)
var _popup_cd: float = 0.0

## Damageable-контракт (Фаза 2): постройку можно атаковать. Скелеты бьют по группе
## skeleton_target (по ноде), магия/слэм игрока — по коллайдеру (StaticBody=сам). HP по роли;
## смерть → шаттер + снос с грида + пересборка стен/гарнизона. См. [[feedback_enemy_fx_universal]].
signal damaged(amount: float)
signal destroyed
var _hp: float = 0.0
var _dead: bool = false


## Задаётся ДО add_child (как RoomBuildSite) — _ready строит по маске.
func setup(id: StringName) -> void:
	building_id = id
	var d: Dictionary = RoomBuildings.get_data(id)
	_mask = d.get("cells", [])
	_role = d.get("role", &"defend")


func _ready() -> void:
	add_to_group(GROUP)
	# Физика+урон: постройка = препятствие на CAMP_OBSTACLE (блокирует скелетов И башню,
	# ловит магию/слэм игрока) + цель скелетов. Damageable-нода = сам StaticBody (коллайдер).
	collision_layer = Layers.CAMP_OBSTACLE
	collision_mask = 0
	Damageable.register(self)
	add_to_group(Enemy.TARGET_GROUP)
	if is_wall() or is_gate() or is_stakes():
		add_to_group(Enemy.MELEE_ONLY_TARGET_GROUP)  # стена/ворота/колья — щит: дальники целят экономику/башню
	_hp = _role_hp()
	set_process(false)  # тикает только добытчик (нефть) и казарма (клик найма)
	# Казарма = кнопка найма за золото: hover-подсветка руки + ЛКМ-клик → стол торга.
	if is_barracks():
		add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)
		set_process(true)
	# Плавильня/двор/банк НЕ тикают сами: они работают как сапорты-соседи квартала
	# шахты (_tick_mine у шахты читает их роли). Легаси конвейера (группа smelter,
	# доставка руды гномами, свои set_process) вычищено 2026-07-04 — веток в _process
	# у этих ролей не было, тики крутились вхолостую.
	# Институт магии — тикает ману в башню + метит «магия открыта» (анлок) + hover-индикатор маны.
	if is_magic():
		add_to_group(&"magic_institute")
		add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)  # наведение руки → плашка маны/множителей
		set_process(true)
	# Кафедра Волшебных свитков — кликабельна: ЛКМ открывает магазин заклинаний (покупка за монеты).
	if is_scroll_dept():
		add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)
		set_process(true)
	# Кафедра-школа (spell_lab): построил → ветка заклинаний открыта. Deferred:
	# на момент _ready трей HUD мог ещё не подписаться на spell_unlocked.
	if is_spell_lab():
		call_deferred(&"_unlock_lab_spells")
		# Гильдия инженеров дополнительно КУЁТ аппараты кликом (модульная система).
		if building_id == RoomBuildings.PAD_ENGINEER_LAB:
			add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)
			set_process(true)
	# Верфь башни: платформа без коллизии (башня может заезжать на плиту), но меню
	# срезов открывается ЛКМ-КЛИКОМ по плите (заезд-триггер пробовали — неудобно).
	if is_dock():
		collision_layer = 0
		add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)
		set_process(true)
	# Разгрузочная платформа: тикает конверсию трюма, пока башня припаркована рядом.
	# КОЛЛИЗИИ НЕТ (плита не должна блокировать заезд башни — та ходит физикой);
	# урон/цель скелетов работают через группы, как у RoomBuildSite без коллайдера.
	if is_unload():
		collision_layer = 0
		set_process(true)
	# Отложенно: HandPlaceAim ставит global-трансформ ПОСЛЕ add_child (нужен стене для
	# мировых клеток и поиска соседей).
	call_deferred(&"_build")


func is_wall() -> bool:
	return _role == &"defend"


func is_attack() -> bool:
	return _role == &"attack"


## Разгрузочная платформа 2×2: башня паркуется рядом → трюм (склад) конвертится в монеты.
func is_unload() -> bool:
	return _role == &"unload"


func is_gate() -> bool:
	return _role == &"gate"


func is_stakes() -> bool:
	return _role == &"stakes"


func is_magic() -> bool:
	return _role == &"magic"


func is_barracks() -> bool:
	return _role == &"barracks"


func is_smelter() -> bool:
	return _role == &"smelter"


func is_line() -> bool:
	return _role == &"line"


func is_mint() -> bool:
	return _role == &"mint"


func is_bank() -> bool:
	return _role == &"bank"


func is_scroll_dept() -> bool:
	return _role == &"mana_crystal"  # Кафедра Волшебных свитков (сапорт института + магазин заклинаний)


## Кафедра-школа заклинаний (огонь/инженерия/лёд): постройка = анлок ветки.
func is_spell_lab() -> bool:
	return _role == &"spell_lab"


## Центр футпринта в локальных координатах (стопка монет, FX).
func _footprint_center() -> Vector3:
	var s: float = CityGrid.CELL
	var ctr := Vector3.ZERO
	for off in _mask:
		ctr += Vector3(float((off as Vector2i).x) * s, 0.0, float((off as Vector2i).y) * s)
	return ctr / float(_mask.size())


## Открыть заклинания своей школы (каталог RoomBuildings, ключ "spells").
## SpellSystem.unlock идемпотентен — вторая кафедра той же школы безвредна.
## Знание НЕ отбирается при сносе кафедры (модель «город = тыл»: локальная
## потеря — производство модулей/зарядов, не выученное).
func _unlock_lab_spells() -> void:
	var d: Dictionary = RoomBuildings.get_data(building_id)
	var names: Array[String] = []
	for id in d.get("spells", []):
		if SpellSystem != null and not SpellSystem.is_unlocked(id):
			SpellSystem.unlock(id)
			var sd: Dictionary = SpellSystem.get_spell_data(id)
			names.append(str(sd.get("name", id)))
	if not names.is_empty():
		EventBus.tutorial_hint.emit("✨ Школа открыта: %s — в трее заклинаний" % ", ".join(names), 6.0)


## Верфь башни: клик → окно срезов-слоёв башни (TowerUpgrades, покупка за монеты).
func is_dock() -> bool:
	return _role == &"dock"


## Роль постройки — для правил сочетаемости (connects) и поиска сапортов.
func get_role() -> StringName:
	return _role


## Пересобрать все стены (защита) — зовётся при установке/сносе любой постройки, чтобы
## стены дотянулись до новых соседей (или отвязались от снесённых). Порядок не важен.
static func refresh_walls(tree: SceneTree) -> void:
	for b in tree.get_nodes_in_group(GROUP):
		if not is_instance_valid(b) or b.is_queued_for_deletion():
			continue
		# Стены И ворота зависят от соседей (рукава/нахлёст) → пересобираем оба.
		if (b.has_method(&"is_wall") and b.call(&"is_wall")) or (b.has_method(&"is_gate") and b.call(&"is_gate")):
			b.call(&"_build")
	# Структура изменилась (стройка/снос) → гарнизонные лучники пересчитывают пост сразу:
	# падают со снесённой стены/казармы (→ плечо / замок) или лезут на достроенную стену.
	for s in tree.get_nodes_in_group(SoldierGnome.SOLDIER_GROUP):
		if is_instance_valid(s) and s.has_method(&"garrison_world_changed"):
			s.call(&"garrison_world_changed")


## Проходимые клетки боевого хода (стена/ворота/казарма) — по ним ходят лучники.
static func walkable_set(tree: SceneTree) -> Dictionary:
	var out: Dictionary = {}
	for b in tree.get_nodes_in_group(GROUP):
		if not is_instance_valid(b) or b.is_queued_for_deletion() or not b.has_method(&"occupied_cells"):
			continue
		var ok: bool = (b.has_method(&"is_wall") and b.call(&"is_wall")) \
			or (b.has_method(&"is_gate") and b.call(&"is_gate")) \
			or (b.has_method(&"is_barracks") and b.call(&"is_barracks"))
		if ok:
			for c in b.call(&"occupied_cells"):
				out[c] = true
	return out


## Мировая точка на ВЕРХУ боевого хода для клетки (туда встаёт/идёт лучник).
static func cell_top(cell: Vector2i, tree: SceneTree) -> Vector3:
	var w := CityGrid.cell_to_world(cell, tree)
	return Vector3(w.x, _WALL_H, w.z)


## Маршрут вдоль боевого хода СТРОГО ПО ПРЯМОЙ от start в сторону first_dir. Без поворотов
## на углах: лучник плеча ходит только по своей линии (плечо + соосная стена), не заворачивая
## в кольцо стен и не пересекая башню/чужое плечо. Кончилась прямая walkable — стоп.
static func wall_route(tree: SceneTree, start: Vector2i, first_dir: Vector2i, maxn: int = 24) -> Array:
	var walk := walkable_set(tree)
	var route: Array = []
	var cur := start
	for _k in maxn:
		if not walk.has(cur):
			break
		route.append(cell_top(cur, tree))
		cur += first_dir  # только прямо, никаких поворотов
	return route


## Визуал по роли: добытчик — квадратная башенка-замок; защита — серая каменная стена
## с зубцами; атака — серая сторожевая башня. Коллайдера нет (Фаза 2).
func _build() -> void:
	for ch in get_children():
		ch.free()  # перестройка: чистим прежний визуал
	# Оверлей хинта стыковки ушёл вместе с детьми; без сброса state
	# set_connection_hint(тот же state) молча не пересоздаст его.
	_conn_overlay = null
	_conn_state = 0
	match _role:
		&"unload":
			_build_unload_pad()
		&"dock":
			_build_dock()
		&"mine":
			_build_tower()
			_setup_mine()
		&"defend":
			_build_wall()
		&"attack":
			_build_watchtower()
		&"housing":
			_build_house()
		&"storage":
			_build_store()
		&"gate":
			_build_gate()
		&"stakes":
			_build_stakes()
		&"barracks":
			_build_barracks()
		&"barrack":
			_build_barrack()
		&"smelter":
			_build_smelter()
		&"line":
			_build_line()
		&"mint":
			_build_mint()
		&"bank":
			_build_bank()
		&"magic":
			_build_institute()
		&"mana_crystal":
			_build_mana_crystal()
		&"mana_rune":
			_build_mana_rune()
		&"spell_lab":
			_build_spell_lab()
		_:
			var mat := _solid(_role_color(_role), 0.1, 0.7)
			var s: float = CityGrid.CELL
			for off in _mask:
				var o := off as Vector2i
				_box(Vector3(s * 0.96, 1.4, s * 0.96), Vector3(o.x * s, 0.7, o.y * s), mat, true)
	_build_collider()  # коллайдер по футпринту (после очистки детей в начале _build)
	# Перестройка снесла детей → стопка монет шахты пересоздаётся под текущее значение.
	_stack_root = null
	_stack_coins_shown = -1
	if _role == &"mine":
		_refresh_stack_visual()


## Коллайдер-бокс на каждую клетку футпринта (StaticBody = сам узел). Локальные позиции по
## маске → следуют за rotation узла, совпадают с occupied_cells и визуалом. Высота с запасом,
## чтобы башня/скелеты упирались. Зовётся из _build (пересобирается при каждой перестройке).
func _build_collider() -> void:
	var s: float = CityGrid.CELL
	var h := 2.4
	for off in _mask:
		var o := off as Vector2i
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(s * 0.96, h, s * 0.96)
		cs.shape = box
		cs.position = Vector3(o.x * s, h * 0.5, o.y * s)
		add_child(cs)


## HP по роли: стены/ворота толще (барьер), казарма/банк крепкие, экономика мягче. Каталог
## может переопределить полем "hp". Баланс — плейсхолдер.
func _role_hp() -> float:
	var by_catalog = RoomBuildings.get_data(building_id).get("hp", 0)
	if int(by_catalog) > 0:
		return float(by_catalog)
	match _role:
		&"defend", &"gate":
			return 140.0
		&"barracks", &"bank":
			return 100.0
		&"attack", &"smelter":
			return 80.0
		&"mine", &"mint":
			return 60.0
		_:
			return 60.0


## Reach-контракт ([Enemy.target_reach_bonus], направленный вариант): здание —
## не точка. Скелет должен замахиваться у ГРАНИ футпринта: у стены-бруса
## (3 клетки, origin в торцевой якорь-клетке) центр-дистанция не срабатывала —
## скелеты упирались в коллайдер БЕЗ атак и телеграфа (фидбек 2026-07-07).
## Бонус = |атакующий→origin| − |атакующий→ближайшая точка футпринта| (XZ,
## в локальных осях — поворот узла учитывается to_local автоматически).
func get_attack_reach_bonus_from(from_pos: Vector3) -> float:
	if _mask.is_empty():
		return 0.0
	var l: Vector3 = to_local(from_pos)
	var half: float = CityGrid.CELL * 0.5
	var min_x: float = INF
	var max_x: float = -INF
	var min_z: float = INF
	var max_z: float = -INF
	for c in _mask:
		var cc := c as Vector2i
		min_x = minf(min_x, cc.x * CityGrid.CELL - half)
		max_x = maxf(max_x, cc.x * CityGrid.CELL + half)
		min_z = minf(min_z, cc.y * CityGrid.CELL - half)
		max_z = maxf(max_z, cc.y * CityGrid.CELL + half)
	var px: float = clampf(l.x, min_x, max_x)
	var pz: float = clampf(l.z, min_z, max_z)
	var d_box: float = Vector2(l.x - px, l.z - pz).length()
	var d_origin: float = Vector2(l.x, l.z).length()
	return maxf(0.0, d_origin - d_box)


## Damageable-контракт: приём урона (скелеты — по группе, магия/слэм — по коллайдеру).
func take_damage(amount: float) -> void:
	if _dead or amount <= 0.0:
		return
	_hp -= amount
	damaged.emit(amount)
	_flash_hit()
	_update_distress()
	if _hp <= 0.0:
		_die()


## Цвет hit-flash'а. По нему же отличаем «наш флеш ещё гаснет» от РОДНОГО
## свечения здания (кристалл института и т.п.) — родное не трогаем.
const _FLASH_COLOR := Color(1.0, 0.4, 0.3)

## Hit-flash на приём урона (универсальный FX, как у врагов): здание МИГАЕТ —
## двойной пульс вспышка→притух→вспышка→погас (~0.35с; фидбек 2026-07-07:
## одиночное затухание не читалось как «мигание») + крошка-пыль.
func _flash_hit() -> void:
	var mats: Array = []
	for ch in get_children():
		var mi := ch as MeshInstance3D
		if mi == null:
			continue
		var mat := mi.material_override as StandardMaterial3D
		if mat == null or mats.has(mat):
			continue
		if mat.emission_enabled and not mat.emission.is_equal_approx(_FLASH_COLOR):
			continue  # родное свечение здания — не глушим флешем
		mats.append(mat)
	if mats.is_empty():
		return
	for m in mats:
		var mat := m as StandardMaterial3D
		mat.emission_enabled = true
		mat.emission = _FLASH_COLOR
	var apply := func(v: float) -> void:
		for m in mats:
			(m as StandardMaterial3D).emission_energy_multiplier = v
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = create_tween()
	_flash_tween.tween_method(apply, 2.4, 0.2, 0.1)
	_flash_tween.tween_method(apply, 0.2, 1.8, 0.08)
	_flash_tween.tween_method(apply, 1.8, 0.0, 0.16)
	# Крошка от удара (throttle — осада лупит десятками ударов в секунду).
	var now: int = Time.get_ticks_msec()
	if now - _hit_dust_msec >= 400:
		_hit_dust_msec = now
		var scene := get_tree().current_scene
		if scene != null:
			AoeVisual.spawn_dust(scene, to_global(_mask_center()) + Vector3(0, 0.7, 0))


var _flash_tween: Tween = null


var _hit_dust_msec: int = 0
var _distress_smoke: GPUParticles3D = null


## Телеграф «зданию плохо»: ниже 35% HP над зданием встаёт дым-столб — виден
## издалека и постоянно, в отличие от мгновенного флеша. Умирает со зданием.
func _update_distress() -> void:
	if _dead or _distress_smoke != null:
		return
	var max_hp: float = _role_hp()
	if max_hp <= 0.0 or _hp / max_hp > 0.35:
		return
	_distress_smoke = AoeVisual.make_smoke_emitter(0.7)
	add_child(_distress_smoke)
	_distress_smoke.position = _mask_center() + Vector3(0, 1.4, 0)


## Смерть: СРАЗУ выходим из групп цели/Damageable (queue_free отложен — иначе скелеты/AOE
## ещё кадр целят труп), эмитим destroyed, шаттер, сносим, пересобираем стены/гарнизон.
func _die() -> void:
	if _dead:
		return
	_dead = true
	remove_from_group(Enemy.TARGET_GROUP)
	remove_from_group(Enemy.MELEE_ONLY_TARGET_GROUP)
	remove_from_group(Damageable.GROUP)
	remove_from_group(GROUP)
	destroyed.emit()
	var tree := get_tree()
	var scene := tree.current_scene if tree != null else null
	if scene != null and is_instance_valid(scene):
		# Взрыв масштабируется размером здания (клетки маски): будка ~1.6, стена-брус ~2.6.
		var boom_r: float = clampf(1.2 + 0.45 * float(_mask.size()), 1.6, 3.0)
		ShatterEffect.building_explosion(scene, to_global(_mask_center()) + Vector3(0, 0.6, 0),
			_role_color(_role), boom_r, 12)
	queue_free()
	# Структура изменилась → стены/ворота пересобираются, гарнизон пересчитывает пост.
	# Этот узел уже вышел из GROUP выше, так что refresh_walls его не трогает.
	if tree != null:
		PadBuilding.refresh_walls(tree)


const _WALL_STONE := Color(0.56, 0.55, 0.52)  # тёплый камень
const _WALL_TRIM := Color(0.4, 0.39, 0.38)
const _WALL_TH := 1.2    # ширина стены = ширине зданий (CELL − 2·_STREET), боевой ход
const _WALL_H := 1.6     # высота стены (верх = дорожка-walkway)
const _MERLON := 0.34    # зубец
const _MERLON_H := 0.5

# Общая палитра/метрики полировки визуала зданий.
const _STONE_DARK := Color(0.33, 0.31, 0.3)   # цоколь/фундамент
const _WOOD := Color(0.46, 0.3, 0.17)         # дерево (крыши/ящики)
const _WOOD_DARK := Color(0.28, 0.18, 0.1)    # тёмное дерево (балки/двери)
const _BASE_H := 0.28                          # высота цоколя-фундамента
## Отступ блочных зданий от края клетки (улица между зданиями = 2·_STREET). Чтобы гномы
## проходили. Клетки ОДНОГО здания сливаются (отступ только по ВНЕШНИМ граням).
const _STREET := 0.4


## Слитный инсет-слой по маске: на каждую клетку коробка, ужатая по ВНЕШНИМ граням на
## margin (где нет соседней клетки маски) → здание стоит с улицей вокруг, но цельным
## массивом внутри. y — центр по Y, h — высота.
func _solid_shape(y: float, h: float, mat: StandardMaterial3D, margin: float) -> void:
	var s: float = CityGrid.CELL
	var half: float = s * 0.5
	var ms: Dictionary = {}
	for off in _mask:
		ms[off as Vector2i] = true
	for off in _mask:
		var o := off as Vector2i
		var xn: float = half if ms.has(o + Vector2i(-1, 0)) else half - margin
		var xp: float = half if ms.has(o + Vector2i(1, 0)) else half - margin
		var zn: float = half if ms.has(o + Vector2i(0, -1)) else half - margin
		var zp: float = half if ms.has(o + Vector2i(0, 1)) else half - margin
		_box(Vector3(xn + xp, h, zn + zp),
			Vector3(float(o.x) * s + (xp - xn) * 0.5, y, float(o.y) * s + (zp - zn) * 0.5), mat, true)


## Крепостная стена (защита): ТОНКИЙ ряд по центру клетки. Каждая клетка = столб-узел +
## рукава к соседним клеткам маски (как трубы) → прямая и угол выходят тонкими и
## стыкуются. Зубцы шагом 1м (центр клетки + «свои» границы к соседям) — единый узор.
func _build_wall() -> void:
	var tree := get_tree()
	var stone := _solid(_WALL_STONE, 0.05, 0.95)
	var trim := _solid(_WALL_TRIM, 0.05, 0.95)
	var half: float = CityGrid.CELL * 0.5
	var mine := CityGrid.building_cells(global_position, _mask, rotation.y, tree)
	var mineset: Dictionary = {}
	for c in mine:
		mineset[c] = true
	# Соединяемся со стенами (встык) и со сторожевыми башнями (нахлёст). К добыче/дому/
	# складу/замку НЕ тянемся (примыкаем лишь краем).
	var walls: Dictionary = {}
	var towers: Dictionary = {}
	for b in tree.get_nodes_in_group(GROUP):
		if b == self or not is_instance_valid(b) or b.is_queued_for_deletion() or not b.has_method(&"occupied_cells"):
			continue
		# Ворота — тоже «стеновой» сосед: пилоны доходят до границы, стена встаёт встык.
		if (b.has_method(&"is_wall") and b.call(&"is_wall")) or (b.has_method(&"is_gate") and b.call(&"is_gate")):
			for c in b.call(&"occupied_cells"):
				walls[c] = true
		elif (b.has_method(&"is_attack") and b.call(&"is_attack")) or (b.has_method(&"is_barracks") and b.call(&"is_barracks")):
			for c in b.call(&"occupied_cells"):
				towers[c] = true
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var eo: float = _WALL_TH * 0.5 - _MERLON * 0.5  # вынос зубца к краю дорожки
	var mtop: float = _WALL_H + _MERLON_H * 0.5
	for wc in mine:
		var cell := wc as Vector2i
		var ctr := CityGrid.cell_to_world(cell, tree)
		# Узел-площадка (плоский верх = дорожка боевого хода).
		_wb(ctr + Vector3(0, _WALL_H * 0.5, 0), Vector3(_WALL_TH, _WALL_H, _WALL_TH), stone)
		var arms := 0
		for d in dirs:
			var nb: Vector2i = cell + d
			var to_wall: bool = mineset.has(nb) or walls.has(nb)
			var to_tower: bool = towers.has(nb)
			if not (to_wall or to_tower):
				continue
			arms += 1
			var ln: float = half if to_wall else half + 0.5  # к башне — с нахлёстом
			var ac := ctr + Vector3(d.x * ln * 0.5, _WALL_H * 0.5, d.y * ln * 0.5)
			var size := Vector3(ln, _WALL_H, _WALL_TH) if d.x != 0 else Vector3(_WALL_TH, _WALL_H, ln)
			_wb(ac, size, stone)
			# Зубцы по ОБЕИМ кромкам рукава (перпендикулярно его оси), шаг 1м между клетками.
			var perp := Vector2i(d.y, d.x)
			for side in [-1.0, 1.0]:
				_wb(ctr + Vector3(d.x * 0.5 + float(perp.x) * side * eo, mtop, d.y * 0.5 + float(perp.y) * side * eo),
					Vector3(_MERLON, _MERLON_H, _MERLON), trim)
		# Одиночная стена без соседей — зубцы по 4 углам площадки.
		if arms == 0:
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					_wb(ctr + Vector3(sx * eo, mtop, sz * eo), Vector3(_MERLON, _MERLON_H, _MERLON), trim)


## Куб В МИРОВЫХ координатах (top_level — не зависит от трансформа узла-стены). Стена
## строится по мировым клеткам, поэтому фиксируем меши абсолютно.
func _wb(world_pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.top_level = true
	add_child(mi)
	mi.global_position = world_pos


## Сторожевая башня (атака, 1 клетка): узкая СЕРАЯ каменная башня + площадка-парапет с
## зубцами наверху (туда «сядет» лучник в Фазе 2). Цвет как у стены.
func _build_watchtower() -> void:
	var stone := _solid(_WALL_STONE, 0.05, 0.9)
	var dark := _solid(_STONE_DARK, 0.1, 0.9)
	var trim := _solid(_WALL_TRIM, 0.1, 0.9)
	var bw: float = CityGrid.CELL - 2.0 * _STREET  # ширина с отступом (улицы)
	_layer(_BASE_H * 0.5, bw, _BASE_H, dark)                                      # цоколь
	var bh := 2.6
	_box(Vector3(bw - 0.1, bh, bw - 0.1), Vector3(0, _BASE_H + bh * 0.5, 0), stone, true)  # ствол
	_box(Vector3(bw + 0.06, 0.22, bw + 0.06), Vector3(0, _BASE_H + bh, 0), stone, true)    # площадка
	_battlements(bw * 0.5, _BASE_H + bh + 0.11, trim)                            # зубцы


## Ворота: арка со створками в линии стены. Пилоны по локальным ±X доходят до границы
## клетки (стена стыкуется встык), проём по Z — для прохода. Поворот MMB. Локально, узел
## повёрнут трансформом. Проходимость гномов — Фаза 2 (с барьером стен).
func _build_gate() -> void:
	var stone := _solid(_WALL_STONE, 0.05, 0.9)
	var trim := _solid(_WALL_TRIM, 0.1, 0.9)
	var wood := _solid(_WOOD, 0.0, 0.95)
	var s: float = CityGrid.CELL
	var half: float = s * 0.5
	var minx := 999
	var maxx := -999
	for off in _mask:
		minx = mini(minx, (off as Vector2i).x)
		maxx = maxi(maxx, (off as Vector2i).x)
	var x0: float = float(minx) * s - half  # внешний левый край
	var x1: float = float(maxx) * s + half  # внешний правый край
	var cxc: float = float((minx + maxx) / 2) * s  # центр СРЕДНЕЙ клетки = центр арки
	var lp: float = cxc - half  # левая граница средней клетки (левый пилон)
	var rp: float = cxc + half  # правая граница
	var pt := 0.5
	var pd := _WALL_TH  # глубина = ширине стены (боевой ход единой ширины)
	var ph := 2.8
	var eo: float = _WALL_TH * 0.5 - _MERLON * 0.5
	# Концы ворот примыкают к зданиям как стены: к башне/казарме за краем — с нахлёстом.
	var tree := get_tree()
	var base := CityGrid.world_to_cell(global_position, tree)
	var over := _overlap_cells(tree)
	var ext_l := 0.5 if over.has(base + CityGrid.rotate_offset(Vector2i(minx - 1, 0), rotation.y)) else 0.0
	var ext_r := 0.5 if over.has(base + CityGrid.rotate_offset(Vector2i(maxx + 1, 0), rotation.y)) else 0.0
	# Боковые отростки стены (широкие, с двусторонними зубцами) — от краёв к пилонам.
	_gate_wall(x0 - ext_l, lp, _WALL_H, stone, trim)
	_gate_wall(rp, x1 + ext_r, _WALL_H, stone, trim)
	# Пилоны арки по краям СРЕДНЕЙ клетки.
	_box(Vector3(pt, ph, pd), Vector3(lp + pt * 0.5, ph * 0.5, 0), stone, true)
	_box(Vector3(pt, ph, pd), Vector3(rp - pt * 0.5, ph * 0.5, 0), stone, true)
	# Арка-перемычка над проёмом средней клетки + зубцы по обеим кромкам.
	_box(Vector3(s, 0.5, pd), Vector3(cxc, ph + 0.25, 0), stone, true)
	for mx in [-0.6, 0.0, 0.6]:
		for side in [-1.0, 1.0]:
			_box(Vector3(_MERLON, _MERLON_H, _MERLON), Vector3(cxc + mx, ph + 0.5 + _MERLON_H * 0.5, side * eo), trim, true)
	# Створки: проём в 1 клетку (две половинки), закрыты; проход — Фаза 2.
	var open_w: float = s - pt * 2.0
	for sx in [-1.0, 1.0]:
		_box(Vector3(open_w * 0.5 * 0.92, 2.0, 0.14), Vector3(cxc + sx * open_w * 0.25, 1.0, 0), wood, true)


## Мировые клетки построек, к которым стена/ворота примыкают С НАХЛЁСТОМ (башни, казармы).
func _overlap_cells(tree: SceneTree) -> Dictionary:
	var out: Dictionary = {}
	for b in tree.get_nodes_in_group(GROUP):
		if b == self or not is_instance_valid(b) or b.is_queued_for_deletion() or not b.has_method(&"occupied_cells"):
			continue
		if (b.has_method(&"is_attack") and b.call(&"is_attack")) or (b.has_method(&"is_barracks") and b.call(&"is_barracks")):
			for c in b.call(&"occupied_cells"):
				out[c] = true
	return out


## Отрезок боковой стены ворот [xa..xb] вдоль локального X: тонкий каменный блок + зубцы.
func _gate_wall(xa: float, xb: float, h: float, stone: StandardMaterial3D, trim: StandardMaterial3D) -> void:
	var w: float = xb - xa
	if w <= 0.01:
		return
	_box(Vector3(w, h, _WALL_TH), Vector3((xa + xb) * 0.5, h * 0.5, 0), stone, true)
	var eo: float = _WALL_TH * 0.5 - _MERLON * 0.5
	var n := int(round(w))
	for i in n:
		var mx: float = xa + 0.5 + float(i)
		for side in [-1.0, 1.0]:
			_box(Vector3(_MERLON, _MERLON_H, _MERLON), Vector3(mx, h + _MERLON_H * 0.5, side * eo), trim, true)


## Угловая казарма лучников: L-тело (слитное), боевой ход с зубцами по ВНЕШНЕМУ периметру
## и стяг на угловой клетке. Серый камень (фортификация) + синий стяг = лучники.
func _build_barracks() -> void:
	# Казарма копейщиков — прямой стеновой отрезок (продолжение стены): чистый боевой ход + стяг.
	if RoomBuildings.get_data(building_id).get("spear_garrison", false):
		_build_spear_barracks()
		return
	var stone := _solid(_WALL_STONE, 0.05, 0.9)
	var trim := _solid(_WALL_TRIM, 0.1, 0.9)  # зубцы в цвет стеновых — стена = продолжение
	var bc: Color = RoomBuildings.get_data(building_id).get("banner_color", Color(0.28, 0.46, 0.7))
	var banner := _solid(bc, 0.0, 0.8)  # цвет стяга = тип бойцов (лучники/копейщики)
	var s: float = CityGrid.CELL
	var half: float = s * 0.5
	var bh := _WALL_H  # высота как у стены → стена ровно продолжает казарму
	var top: float = bh
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var maskset: Dictionary = {}
	for off in _mask:
		maskset[off as Vector2i] = true
	# БЕЗ цоколя — основа от земли, как у стены (стена идёт продолжением казармы).
	_solid_shape(bh * 0.5, bh, stone, _STREET)
	# Зубцы боевого хода по ВНЕШНИМ граням: по 2 на грань, отступив от углов, + крышка на
	# выпуклом углу (две смежные внешние грани) — чтобы в углах не было свалки.
	var edge: float = half - _STREET - _MERLON * 0.5
	var my: float = top + _MERLON_H * 0.5
	for off in _mask:
		var o := off as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		for d in dirs:
			if maskset.has(o + d):
				continue
			var perp := Vector2i(d.y, d.x)
			for t in [-0.42, 0.42]:
				_box(Vector3(_MERLON, _MERLON_H, _MERLON),
					c + Vector3(float(d.x) * edge + float(perp.x) * t, my, float(d.y) * edge + float(perp.y) * t), trim, true)
		for cx in [-1.0, 1.0]:
			for cz in [-1.0, 1.0]:
				if not maskset.has(o + Vector2i(int(cx), 0)) and not maskset.has(o + Vector2i(0, int(cz))):
					_box(Vector3(_MERLON, _MERLON_H, _MERLON), c + Vector3(cx * edge, my, cz * edge), trim, true)
	# Угловая клетка (≥2 соседа в маске) — древко со стягом.
	var corner := _corner_local()
	var pole := _solid(_WOOD_DARK, 0.0, 0.9)
	var cc := Vector3(corner.x * s, 0.0, corner.y * s)
	var flag_base: float = top
	# Лучники: БАШНЯ венчает угол казармы (с неё лучники выходят на стены — Фаза 2).
	if RoomBuildings.get_data(building_id).get("corner_tower", false):
		var tw := 1.0
		var th := 1.9
		_box(Vector3(tw, th, tw), cc + Vector3(0, top + th * 0.5, 0), stone, true)            # ствол
		_box(Vector3(tw + 0.18, 0.2, tw + 0.18), cc + Vector3(0, top + th, 0), stone, true)   # площадка
		_battlements((tw + 0.18) * 0.5, top + th + 0.1, trim)                                 # зубцы
		flag_base = top + th + 0.2
	# Стяг (цвет = тип бойцов): на верхушке башни (лучники) или на основе (прочие).
	var px := Vector3(corner.x * s, flag_base, corner.y * s)
	_box(Vector3(0.09, 1.3, 0.09), px + Vector3(0, 0.65, 0), pole, true)       # древко
	_box(Vector3(0.5, 0.08, 0.08), px + Vector3(0, 1.2, 0), pole, true)        # поперечина
	_box(Vector3(0.45, 0.6, 0.05), px + Vector3(0, 0.85, 0), banner, true)     # полотнище


## Барак — лёгкая КАМЕННАЯ ПРИСТРОЙКА (сапорт казармы, 1 клетка): цоколь + каменное тело ниже
## стены + наклонный деревянный скат (лин-ту) + тёмная дверь. Читается как пристройка к стене.
## Барак — каменная ПРИСТРОЙКА СТЕНОВОГО ТИПА к казарме (тот же камень _WALL_STONE + зубцы как на стене),
## с деревянным лин-ту скатом сзади (это жильё, прислонённое к стене). Читается как продолжение
## укреплений казармы → визуально «улучшение казармы», а не отдельный домик.
func _build_barrack() -> void:
	var s: float = CityGrid.CELL
	var stone := _solid(_WALL_STONE, 0.05, 0.9)   # ТОТ ЖЕ камень, что у стены/казармы
	var dark := _solid(_STONE_DARK, 0.1, 0.9)
	var wood := _solid(_WOOD, 0.0, 0.8)
	var bw: float = s - 2.0 * _STREET             # ширина тела (как у блочных зданий)
	_solid_shape(_BASE_H * 0.5, _BASE_H, dark, _STREET)             # цоколь-фундамент
	var bh: float = _WALL_H                        # тело ВРОВЕНЬ со стеной (стеновой тип)
	_solid_shape(_BASE_H + bh * 0.5, bh, stone, _STREET)           # каменное тело = высота стены
	var top: float = _BASE_H + bh
	# Зубцы по ФРОНТУ (как парапет стены) — связывает барак со стеной казармы визуально.
	var n := 3
	for i in range(n):
		var fx: float = -bw * 0.5 + bw * (float(i) + 0.5) / float(n)
		_box(Vector3(_MERLON, _MERLON_H, _MERLON),
			Vector3(fx, top + _MERLON_H * 0.5, bw * 0.5 - _MERLON * 0.5), stone, true)
	# Лин-ту крыша (деревянный скат) сзади — жильё, прислонённое к стене.
	var roof := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(bw + 0.16, 0.1, bw * 0.72)
	roof.mesh = bm
	roof.material_override = wood
	roof.position = Vector3(0.0, top + 0.16, -bw * 0.16)
	roof.rotation.x = deg_to_rad(-20.0)
	add_child(roof)
	# Дверь (тёмное дерево) на фронте (+Z) под зубцами.
	_box(Vector3(0.42, 0.7, 0.08), Vector3(0.0, _BASE_H + 0.35, bw * 0.5 + 0.02),
		_solid(_WOOD_DARK, 0.0, 0.8), true)


## Колья — ряд заострённых деревянных кольев на низком земляном валу. Заслон перед стеной: дёшево,
## мало HP. Колья наклонены остриём наружу (к +Z) и разной высоты — грубый частокол.
func _build_stakes() -> void:
	var s: float = CityGrid.CELL
	var wood := _solid(_WOOD, 0.0, 0.85)
	var dark := _solid(_WOOD_DARK, 0.0, 0.9)
	var span: float = s - 2.0 * _STREET
	# Низкий земляной/деревянный вал-основание.
	_box(Vector3(span, 0.2, 0.55), Vector3(0.0, 0.1, 0.0), dark, true)
	# Ряд кольев: заострённые цилиндры (top_radius=0), наклон остриём наружу, чередуем высоту/смещение.
	var n := 5
	for i in range(n):
		var t: float = float(i) / float(maxi(n - 1, 1))
		var fx: float = -span * 0.5 + 0.18 + (span - 0.36) * t
		var h: float = 0.85 + (0.18 if i % 2 == 0 else 0.0)
		var stake := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0
		cm.bottom_radius = 0.085
		cm.height = h
		cm.radial_segments = 6
		stake.mesh = cm
		stake.material_override = wood if i % 2 == 0 else dark
		stake.position = Vector3(fx, 0.2 + h * 0.42, 0.06)
		stake.rotation.x = deg_to_rad(-26.0)  # остриём наружу (к врагу, +Z)
		add_child(stake)


## Институт магии: ЗАМКОВАЯ БАШНЯ как у шахты (_build_tower, цвет из _role_color magic) + парящий
## волшебный кристалл-ромб наверху (emission). Тикает ману в башню, открывает магические постройки.
func _build_institute() -> void:
	_build_tower()  # тот же замковый турель, что у шахты, но синевато-серый камень мага
	# Парящий кристалл-ромб над зубцами (две пирамидки основаниями): верх остриём вверх, низ — вниз.
	var crystal := _solid(Color(0.6, 0.5, 1.0), 0.0, 0.35)
	crystal.emission_enabled = true
	crystal.emission = Color(0.5, 0.4, 1.0)
	crystal.emission_energy_multiplier = 2.6
	var cy: float = _BASE_H + 2.0 + 1.15  # над коробом (bh=2.0) и зубцами
	var ch := 0.6
	var cr := 0.3
	_cone(cr, ch, Vector3(0.0, cy + ch * 0.5, 0.0), crystal)          # верхняя половина (остриё вверх)
	var lower := MeshInstance3D.new()                                 # нижняя половина (остриё вниз)
	var lcm := CylinderMesh.new()
	lcm.top_radius = 0.0
	lcm.bottom_radius = cr
	lcm.height = ch
	lower.mesh = lcm
	lower.material_override = crystal
	lower.position = Vector3(0.0, cy - ch * 0.5, 0.0)
	lower.rotation.x = deg_to_rad(180.0)
	add_child(lower)


## Кафедра Волшебных свитков (сапорт института, ×темп), L-форма: каменный зал по всей фигуре +
## рулоны-свитки (горизонтальные цилиндры пергамента) на клетках + светящаяся руна по центру.
func _build_mana_crystal() -> void:
	var s: float = CityGrid.CELL
	var stone := _solid(Color(0.47, 0.46, 0.58), 0.1, 0.8)      # светлый камень кафедры
	var dark := _solid(Color(0.28, 0.28, 0.4), 0.1, 0.85)
	var parch := _solid(Color(0.86, 0.8, 0.62), 0.0, 0.7)       # пергамент свитков
	var glow := _solid(Color(0.55, 0.6, 1.0), 0.0, 0.4)
	glow.emission_enabled = true
	glow.emission = Color(0.45, 0.5, 1.0)
	glow.emission_energy_multiplier = 2.2
	_solid_shape(_BASE_H * 0.5, _BASE_H, dark, _STREET)          # цоколь по всей L
	var bh := 0.85
	_solid_shape(_BASE_H + bh * 0.5, bh, stone, _STREET)         # тело-зал по всей L
	var top: float = _BASE_H + bh
	# Свитки-рулоны (горизонтальные пергаментные цилиндры) поверх каждой клетки L.
	for off in _mask:
		var o := off as Vector2i
		var scroll := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.1
		cm.bottom_radius = 0.1
		cm.height = s - 2.0 * _STREET - 0.25
		scroll.mesh = cm
		scroll.material_override = parch
		scroll.position = Vector3(float(o.x) * s, top + 0.12, float(o.y) * s)
		scroll.rotation.z = deg_to_rad(90.0)  # лежит горизонтально
		add_child(scroll)
	# Светящаяся руна-кристалл (конус) по центру фигуры — флавор магии.
	var ctr := Vector3.ZERO
	for off in _mask:
		ctr += Vector3(float((off as Vector2i).x) * s, 0.0, float((off as Vector2i).y) * s)
	ctr /= float(_mask.size())
	_cone(0.16, 0.6, ctr + Vector3(0.0, top + 0.45, 0.0), glow)


## Кафедра-школа (spell_lab): каменный зал + светящаяся сфера-горн в цвет школы
## (ghost_color каталога) — «здесь куют заклинания этой стихии».
func _build_spell_lab() -> void:
	var d: Dictionary = RoomBuildings.get_data(building_id)
	var school_c: Color = d.get("ghost_color", Color(0.6, 0.5, 1.0, 0.5))
	school_c.a = 1.0
	var stone := _solid(Color(0.4, 0.4, 0.5), 0.1, 0.8)
	var dark := _solid(Color(0.26, 0.26, 0.36), 0.1, 0.85)
	var glow := _solid(school_c, 0.0, 0.4)
	glow.emission_enabled = true
	glow.emission = school_c
	glow.emission_energy_multiplier = 2.6
	_solid_shape(_BASE_H * 0.5, _BASE_H, dark, _STREET)   # цоколь по футпринту
	var bh := 1.0
	_solid_shape(_BASE_H + bh * 0.5, bh, stone, _STREET)  # зал
	# Сфера-горн школы по центру фигуры.
	var s: float = CityGrid.CELL
	var ctr := Vector3.ZERO
	for off in _mask:
		ctr += Vector3(float((off as Vector2i).x) * s, 0.0, float((off as Vector2i).y) * s)
	ctr /= float(_mask.size())
	var orb := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.32
	sm.height = 0.64
	orb.mesh = sm
	orb.material_override = glow
	orb.position = ctr + Vector3(0.0, _BASE_H + bh + 0.35, 0.0)
	add_child(orb)


## Осколок звёздной руды (сапорт института, ×темп сильнее): гранёный сияющий шард на каменной БАШЕНКЕ
## (цоколь + столб + карниз + зубцы). Шард бело-голубой с сильным emission — «звёздная руда».
func _build_mana_rune() -> void:
	var stone := _solid(Color(0.34, 0.34, 0.46), 0.1, 0.8)
	var dark := _solid(Color(0.24, 0.24, 0.34), 0.1, 0.85)
	var shard := _solid(Color(0.78, 0.82, 1.0), 0.0, 0.3)        # звёздная руда — бело-голубое сияние
	shard.emission_enabled = true
	shard.emission = Color(0.66, 0.73, 1.0)
	shard.emission_energy_multiplier = 3.2
	# Башенка: цоколь + узкий столб + карниз + зубцы.
	var bw := 0.78
	_box(Vector3(bw + 0.14, _BASE_H, bw + 0.14), Vector3(0.0, _BASE_H * 0.5, 0.0), dark, true)  # цоколь
	var bh := 1.4
	_box(Vector3(bw, bh, bw), Vector3(0.0, _BASE_H + bh * 0.5, 0.0), stone, true)               # столб
	_box(Vector3(bw + 0.1, 0.12, bw + 0.1), Vector3(0.0, _BASE_H + bh, 0.0), dark, true)        # карниз
	_battlements(bw * 0.5, _BASE_H + bh + 0.06, dark)                                           # зубцы
	# Осколок-шард над башенкой (ромб: верхнее длинное остриё + короткое нижнее), сильное сияние.
	var cy: float = _BASE_H + bh + 0.62
	var sh := 0.78
	var sr := 0.22
	_cone(sr, sh, Vector3(0.0, cy + sh * 0.5, 0.0), shard)        # длинное верхнее остриё
	var low := MeshInstance3D.new()                              # короткое нижнее остриё
	var lcm := CylinderMesh.new()
	lcm.top_radius = 0.0
	lcm.bottom_radius = sr
	lcm.height = sh * 0.6
	low.mesh = lcm
	low.material_override = shard
	low.position = Vector3(0.0, cy - sh * 0.3, 0.0)
	low.rotation.x = deg_to_rad(180.0)
	add_child(low)


## Плавильня: каменная печь с раскалённым устьем (emission) + труба-дымоход.
## Работает как САПОРТ-СОСЕД квартала шахты (ось «Скорость», см. _tick_mine) —
## доставка руды гномами вырезана вместе с конвейером.
func _build_smelter() -> void:
	# ЕДИНОЕ жёлтое здание (под цвет шахты/линии): сплошной массив по всей фигуре + один
	# остроконечный шпиль по центру, раскалённое устье у земли, дым из вершины при работе.
	var yellow := _solid(Color(0.86, 0.66, 0.26), 0.2, 0.6)   # охра — как шахта/линия
	var dark := _solid(Color(0.5, 0.38, 0.16), 0.2, 0.7)      # тёмный карниз/острие
	var glow := _solid(Color(1.0, 0.55, 0.15), 0.0, 0.6)
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.5, 0.12)
	glow.emission_energy_multiplier = 2.0
	var s: float = CityGrid.CELL
	var bw: float = s - 2.0 * _STREET
	# Центр фигуры — над ним шпиль/дым (плита тела сливает все клетки в один массив).
	var ctr := Vector3.ZERO
	for off in _mask:
		ctr += Vector3((off as Vector2i).x * s, 0.0, (off as Vector2i).y * s)
	ctr /= float(_mask.size())
	var bh := 2.6
	_solid_shape(bh * 0.5, bh, yellow, _STREET)                          # единое тело
	_solid_shape(bh + 0.08, 0.16, dark, _STREET)                         # карниз по верху
	var spire_h := 1.5
	_cone(bw * 0.5, spire_h, ctr + Vector3(0, bh + spire_h * 0.5 + 0.16, 0), dark)  # шпиль
	_box(Vector3(bw * 0.45, 0.7, 0.22), ctr + Vector3(0, 0.6, bw * 0.4), glow, true)  # зев
	# Дым из вершины шпиля — РОВНЫЙ (сапорт работает, пока стоит). Реюз эффекта костра POI.
	_smoke = _build_smoke()
	_smoke.position = ctr + Vector3(0, bh + spire_h + 0.36, 0)
	_smoke.emitting = true
	add_child(_smoke)


## Конус (остриё шпиля) — CylinderMesh с нулевым верхом.
func _cone(radius: float, height: float, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = radius
	cm.height = height
	mi.mesh = cm
	mi.material_override = mat
	mi.position = pos
	add_child(mi)


## Дым плавильни — GPUParticles3D на тех же ресурсах, что костёр POI (smoke_material/mesh).
## Плавильня-сапорт дымит ровно (emitting ставит вызывающий _build_smelter).
func _build_smoke() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 12
	p.lifetime = 2.95
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh := load("res://resources/smoke_mesh.tres")
	if mesh != null:
		p.draw_pass_1 = mesh
	var mat = load("res://resources/smoke_material.tres")
	if mat != null:
		p.material_override = mat
	var pm := ParticleProcessMaterial.new()
	pm.particle_flag_rotate_y = true
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.18
	pm.angle_min = -90.0
	pm.angle_max = 90.0
	pm.gravity = Vector3(0.05, 2.0, 0.0)
	pm.scale_min = 0.4
	pm.scale_max = 0.4
	pm.lifetime_randomness = 0.09
	pm.hue_variation_min = 0.0
	pm.hue_variation_max = 0.02
	p.process_material = pm
	p.emitting = false
	return p


## Чеканный двор-САПОРТ: каменный двор + статичная золотая монета на крыше (ускоряет шахту
## рядом, см. _count_support_neighbors). 1 клетка.
func _build_mint() -> void:
	var stone := _solid(Color(0.55, 0.5, 0.42), 0.1, 0.8)     # каменный двор
	var gold := _solid(Color(0.95, 0.78, 0.25), 0.5, 0.35)    # золото карниза/монеты
	gold.emission_enabled = true
	gold.emission = Color(1.0, 0.82, 0.3)
	gold.emission_energy_multiplier = 0.6
	var bh := 1.7
	_solid_shape(bh * 0.5, bh, stone, _STREET)               # тело-двор (единый массив)
	_solid_shape(bh + 0.08, 0.16, gold, _STREET)             # золотой карниз
	# Статичная монета-эмблема на крыше.
	var bw: float = CityGrid.CELL - 2.0 * _STREET
	var coin := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = bw * 0.3
	cm.bottom_radius = bw * 0.3
	cm.height = 0.18
	coin.mesh = cm
	coin.material_override = gold
	coin.position = _mask_center() + Vector3(0, bh + 0.2, 0)
	add_child(coin)


## Центр фигуры в локальных координатах (над ним ставим шпиль/купол/индикатор).
func _mask_center() -> Vector3:
	var s: float = CityGrid.CELL
	var c := Vector3.ZERO
	for off in _mask:
		c += Vector3((off as Vector2i).x * s, 0.0, (off as Vector2i).y * s)
	return c / float(_mask.size())


## Гномий банк: ПОМПЕЗНАЯ крепость — массивный донжон + 4 угловые башенки с золотыми
## остриями + золотой купол по центру (индикатор: светится ярче, пока банк принимает монеты).
func _build_bank() -> void:
	var stone := _solid(Color(0.5, 0.49, 0.5), 0.1, 0.8)      # светлый парадный камень
	var trim := _solid(Color(0.36, 0.35, 0.36), 0.1, 0.85)    # тёмный цоколь/карниз
	var gold := _solid(Color(1.0, 0.82, 0.3), 0.6, 0.3)       # золото купола/остриёв
	gold.emission_enabled = true
	gold.emission = Color(1.0, 0.85, 0.35)
	gold.emission_energy_multiplier = 0.6
	var s: float = CityGrid.CELL
	var bw: float = s - 2.0 * _STREET
	var ctr := _mask_center()
	# Цоколь + массивное тело + карниз — единый парадный массив по всей фигуре.
	_solid_shape(_BASE_H * 0.5, _BASE_H, trim, _STREET * 0.5)
	var bh := 2.4
	_solid_shape(_BASE_H + bh * 0.5, bh, stone, _STREET)
	_solid_shape(_BASE_H + bh + 0.1, 0.2, trim, _STREET * 0.7)
	# Угловые башенки по габаритам фигуры с золотыми остриями (помпезность).
	var minx := 9999.0; var maxx := -9999.0; var minz := 9999.0; var maxz := -9999.0
	for off in _mask:
		var o := off as Vector2i
		minx = minf(minx, o.x * s); maxx = maxf(maxx, o.x * s)
		minz = minf(minz, o.y * s); maxz = maxf(maxz, o.y * s)
	var q: float = s * 0.5 - _STREET
	var th := bh + 0.9
	for cx in [minx - q, maxx + q]:
		for cz in [minz - q, maxz + q]:
			_box(Vector3(0.5, th, 0.5), Vector3(cx, _BASE_H + th * 0.5, cz), stone, true)
			_cone(0.34, 0.7, Vector3(cx, _BASE_H + th + 0.35, cz), gold)
	# Золотой купол по центру — индикатор работы (ярче, пока банк принимает монеты).
	var dome := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = bw * 0.32
	sm.height = bw * 0.5
	dome.mesh = sm
	dome.material_override = gold
	dome.position = ctr + Vector3(0, _BASE_H + bh + 0.2 + bw * 0.16, 0)
	add_child(dome)


## Линия переработки: плоская «труба»-конвейер по форме фигуры — низкая металлическая плита
## (клетки сливаются) + тёмный жёлоб по центру. Лежит на полу, по ней «течёт» металл.
func _build_line() -> void:
	# Конвейер переработки = просто СПЛОШНАЯ ЖЁЛТАЯ СТЕНА (под цвет шахты). По ней металл
	# течёт к плавильне. Тёмная канавка поверху читается как «поток».
	var yellow := _solid(Color(0.86, 0.66, 0.26), 0.2, 0.6)   # охра — как шахта
	var groove := _solid(Color(0.5, 0.38, 0.16), 0.2, 0.7)    # тёмная канавка-поток
	var trim := _solid(Color(0.7, 0.52, 0.2), 0.2, 0.65)      # зубцы (темнее охры)
	_solid_shape(_WALL_H * 0.5, _WALL_H, yellow, _STREET)     # тело стены
	_solid_shape(_WALL_H + 0.04, 0.1, groove, _STREET + 0.18) # канавка по верху
	# Зубцы по верху — крепостной парапет по краям каждой клетки фигуры.
	var s: float = CityGrid.CELL
	var edge: float = s * 0.5 - _STREET - _MERLON * 0.5
	var mtop: float = _WALL_H + _MERLON_H * 0.5
	for off in _mask:
		var o := off as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				_box(Vector3(_MERLON, _MERLON_H, _MERLON), c + Vector3(sx * edge, mtop, sz * edge), trim, true)


## Угловая клетка фигуры (≥2 соседа в маске → изгиб L) — на ней стяг/башня + узел гарнизона.
func _corner_local() -> Vector2i:
	var maskset: Dictionary = {}
	for off in _mask:
		maskset[off as Vector2i] = true
	var corner := _mask[0] as Vector2i
	for off in _mask:
		var o := off as Vector2i
		var nb := 0
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if maskset.has(o + d):
				nb += 1
		if nb >= 2:
			corner = o
	return corner


## Геометрия постов гарнизона: мировой угол, наземная точка у казармы, верх башни и
## мировые направления рукавов (плечи L). Один источник для спавна и раздачи постов.
func _garrison_posts() -> Dictionary:
	var tree := get_tree()
	var corner_local := _corner_local()
	var maskset: Dictionary = {}
	for off in _mask:
		maskset[off as Vector2i] = true
	var base := CityGrid.world_to_cell(global_position, tree)
	var corner_world := base + CityGrid.rotate_offset(corner_local, rotation.y)
	var ground := CityGrid.cell_to_world(corner_world, tree)  # наземная точка у казармы
	var tower_pos := ground
	tower_pos.y = _WALL_H + 1.9 + 0.22  # верх башни (площадка)
	var arms: Array = []
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if maskset.has(corner_local + d):
			arms.append(CityGrid.rotate_offset(d, rotation.y))
	return {&"corner_world": corner_world, &"ground": ground, &"tower_pos": tower_pos, &"arms": arms}


## Клик по казарме → стол торга под её тип отряда (НАЙМ ЗА ЗОЛОТО). Колбэк адресный:
## на оплату казарма САМА спавнит/доливает отряд (а не broadcast спавнеру), чтобы тут же
## раздать посты гарнизона лучникам. Тип — из каталога (archer_squad / pikeman).
func _open_hire() -> void:
	var tree := get_tree()
	var trade := tree.get_first_node_in_group(&"trade_ui")
	if trade == null or not trade.has_method(&"open"):
		return
	var stype: StringName = RoomBuildings.get_data(building_id).get("squad_type", DEFAULT_SQUAD_TYPE)
	# count_fn — счёт живых ИМЕННО этой казармы. cap_fn — эффективный кап = min(база типа, живые +
	# свободные военные слоты НАСЕЛЕНИЯ), иначе торг гейтил бы «Артель полна» без учёта населения.
	trade.call(&"open", stype, Callable(self, &"_on_hired"), Callable(self, &"_my_squad_count"), Callable(self, &"_my_hire_cap"))


## Сколько живых бойцов уже в отряде ЭТОЙ казармы (для гейта найма в торге).
func _my_squad_count() -> int:
	var sp := get_tree().get_first_node_in_group(&"squad_spawner")
	if sp != null and sp.has_method(&"owner_squad_count"):
		return int(sp.call(&"owner_squad_count", self))
	return 0


## Эффективный кап найма ЭТОЙ казармы для гейта торга = ДВА предела разом:
## • ось ГАРНИЗОНА (локально): база типа + бараки в зоне-соседстве (hire_cap_bonus) — сколько держит ЭТА казарма;
## • НАСЕЛЕНИЕ (глобально): свободные военные слоты общего пула — есть ли вообще снабжение.
## cap = min(гарнизон, живые + снабжение). Уперлись в любой → торг «Артель полна» (строй барак ИЛИ социалку).
func _my_hire_cap() -> int:
	var stype: StringName = RoomBuildings.get_data(building_id).get("squad_type", DEFAULT_SQUAD_TYPE)
	var base: int = int(SoldierSystem.get_squad_cap(stype)) if SoldierSystem != null else 0
	var garrison: int = base + hire_cap_bonus()
	var pop_room: int = int(Population.military_room()) if Population != null else garrison
	return mini(garrison, _my_squad_count() + pop_room)


## Ось «Гарнизон»: каждый барак в зоне-соседстве казармы поднимает её кап найма на HIRE_CAP_PER_BARRACK.
## Барак при этом ОСТАЁТСЯ соц-зданием (даёт +население глобально) — симметрия дому (ось + население).
## Зовётся торгом (_my_hire_cap) и спавнером (cap_bonus). Не казарма → 0.
func hire_cap_bonus() -> int:
	if _role != &"barracks":
		return 0
	return int(_quarter_status()["support_count"]) * HIRE_CAP_PER_BARRACK


## → раздаём посты гарнизона стен; копейщики → мобильный отряд за башней (спавнер сам escort).
## Спавнер держит отряд НА КАЗАРМУ → повторный найм доливает павших ЭТОЙ казармы (cap гасит перебор).
func _on_hired(unit_type: StringName, want: int) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var spawner := tree.get_first_node_in_group(&"squad_spawner")
	if spawner == null or not spawner.has_method(&"request_squad_for"):
		return
	# Добор до капа клампит сам request_squad_for (per-barracks). Стол торга и так гасит
	# «Купить» на full → сюда обычно приходим лишь при недоборе.
	var data: Dictionary = RoomBuildings.get_data(building_id)
	var spear: bool = data.get("spear_garrison", false)
	# Точка спавна: копейщики — у самой казармы-стены; лучники — у угла бастиона.
	var ground: Vector3 = _spear_ground() if spear else _garrison_posts()[&"ground"]
	var members: Array = spawner.call(&"request_squad_for", self, unit_type, want, ground)
	if members.is_empty():
		return
	# Раздаём посты ВСЕМУ отряду (не только новичкам-добору) — иначе при доливе павших новичок
	# дублирует пост, а уцелевшие держат старые. Лучники → бастион (угол+рукава); копейщики → клетки-стена.
	var sq = members[0].get(&"_squad")
	var all: Array = sq.members if sq != null else members
	if data.get("corner_tower", false):
		_assign_garrison(all, _garrison_posts())
	elif spear:
		_assign_spear_garrison(all)


## Раздаём ВСЕМ живым лучникам отряда посты по индексу: 0 → башня (branch ZERO), 1/2 →
## рукава-стены; отряд в МЯГКИЙ hold → гарнизон (ArcherSoldier._grn_should_garrison),
## перебивая escort спавнера. «За башней» (escort) снимает; F-возврат ставит обратно.
func _assign_garrison(members: Array, posts: Dictionary) -> void:
	var corner_world: Vector2i = posts[&"corner_world"]
	var ground: Vector3 = posts[&"ground"]
	var tower_pos: Vector3 = posts[&"tower_pos"]
	var arms: Array = posts[&"arms"]
	# Чистый список живых — индекс поста = позиция в отряде (стабильно при доборе).
	var living: Array = []
	for a in members:
		if is_instance_valid(a) and a.has_method(&"assign_garrison"):
			living.append(a)
	for i in living.size():
		# 0 → башня (branch ZERO); 1/2 → рукава (если есть; иначе тоже башня).
		var branch: Vector2i = Vector2i.ZERO
		if i > 0 and arms.size() > 0:
			branch = arms[(i - 1) % arms.size()]
		living[i].call(&"assign_garrison", corner_world, branch, tower_pos, ground.y)
	# Дефолт казармы — мягкий hold → гарнизон стен (перебивает escort спавнера).
	if living.size() > 0:
		var sq = living[0].get(&"_squad")
		if sq != null:
			sq.command_hold(ground, false)


## Казарма копейщиков = стеновой отрезок: визуал = чистая стена (боевой ход + зубцы + стыковка со
## стенами встык, walkable-верх для маршрута лучников) + красный стяг на центральной клетке.
func _build_spear_barracks() -> void:
	_build_wall()  # переиспускаем стену: продолжение линии, боевой ход, зубцы, коннект к соседям
	var s: float = CityGrid.CELL
	var bc: Color = RoomBuildings.get_data(building_id).get("banner_color", Color(0.72, 0.3, 0.26))
	var pole := _solid(_WOOD_DARK, 0.0, 0.85)
	var flag := _solid(bc, 0.0, 0.7)
	# Центр фигуры (локально) — туда стяг.
	var c := Vector2.ZERO
	for off in _mask:
		c += Vector2(float((off as Vector2i).x), float((off as Vector2i).y))
	c /= float(maxi(_mask.size(), 1))
	var cx: float = c.x * s
	var cz: float = c.y * s
	var ph := 1.4
	var base_y: float = _WALL_H + _MERLON_H
	_box(Vector3(0.08, ph, 0.08), Vector3(cx, base_y + ph * 0.5, cz), pole, false)            # древко
	_box(Vector3(0.5, 0.34, 0.04), Vector3(cx + 0.29, base_y + ph - 0.25, cz), flag, false)   # полотнище


## Посты копейщиков = верх боевого хода КАЖДОЙ клетки казармы (PadBuilding.cell_top, высота _WALL_H).
func _spear_posts() -> Array:
	var tree := get_tree()
	var out: Array = []
	for c in occupied_cells():
		out.append(PadBuilding.cell_top(c as Vector2i, tree))
	return out


## Наземная точка у казармы копейщиков (спавн отряда; копейщики потом взлетают на посты).
func _spear_ground() -> Vector3:
	var tree := get_tree()
	var cells := occupied_cells()
	if cells.is_empty():
		return global_position
	return CityGrid.cell_to_world(cells[0] as Vector2i, tree)


## Раздаём копейщикам посты — по 1 на клетку (cells[i]→posts[i]); перебор (барак) циклит. Отряд в
## МЯГКИЙ hold → гарнизон (SpearmanSoldier._grn_should_garrison), перебивая escort спавнера.
func _assign_spear_garrison(members: Array) -> void:
	var posts: Array = _spear_posts()
	var cells: Array = occupied_cells()
	if posts.is_empty():
		return
	var ground: Vector3 = _spear_ground()
	var living: Array = []
	for a in members:
		if is_instance_valid(a) and a.has_method(&"assign_post"):
			living.append(a)
	for i in living.size():
		var idx: int = i % posts.size()
		living[i].call(&"assign_post", posts[idx], cells[idx] as Vector2i, ground.y)
	if living.size() > 0:
		var sq = living[0].get(&"_squad")
		if sq != null:
			sq.command_hold(ground, false)  # мягкий hold → гарнизон на постах


## СЛИТНЫЙ корпус по форме фигуры: на каждую клетку — корпус НА ВСЮ КЛЕТКУ (клетки
## смыкаются в одну массу) + крыша-плита с лёгким свесом (плиты сливаются в одну крышу).
## Так дом/склад выглядят единым зданием по полимино, а не набором модулей.
func _build_compound(body: StandardMaterial3D, roof: StandardMaterial3D, body_h: float, roof_h: float) -> void:
	var dark := _solid(_STONE_DARK, 0.1, 0.92)
	var m := _STREET  # инсет от краёв клетки → улицы между зданиями
	_solid_shape(_BASE_H * 0.5, _BASE_H, dark, m)                         # цоколь
	_solid_shape(_BASE_H + body_h * 0.5, body_h, body, m)                 # тело
	var top: float = _BASE_H + body_h
	_solid_shape(top + 0.04, 0.08, dark, m)                               # карниз-поясок
	_solid_shape(top + 0.08 + roof_h * 0.5, roof_h, roof, m)              # крыша-плита


## Дом гномов (население): слитный каменный корпус + коричневая крыша; труба и дверь —
## единичный декор на крайней клетке (не на каждую).
func _build_house() -> void:
	var stone := _solid(Color(0.6, 0.58, 0.55), 0.05, 0.9)
	var roof := _solid(_WOOD, 0.0, 0.95)
	var dark := _solid(_WOOD_DARK, 0.0, 0.9)
	var body_h := 1.5
	_build_compound(stone, roof, body_h, 0.4)
	var s: float = CityGrid.CELL
	var top: float = _BASE_H + body_h
	var roof_top: float = top + 0.08 + 0.4
	var face: float = s * 0.5 - _STREET  # внешняя грань (инсет)
	var bw: float = s - 2.0 * _STREET    # ширина здания в клетке
	var f := _mask[0] as Vector2i
	for off in _mask:
		var o := off as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		_box(Vector3(bw * 0.95, 0.12, 0.26), c + Vector3(0, roof_top, 0), dark, true)       # конёк по крыше
		if o != f:
			_box(Vector3(0.5, 0.5, 0.12), c + Vector3(0, _BASE_H + 0.95, face), dark, true)  # окно
	var fc := Vector3(f.x * s, 0.0, f.y * s)
	_box(Vector3(0.42, 0.9, 0.42), fc + Vector3(0.4, roof_top + 0.4, 0.4), dark, true)      # труба
	_box(Vector3(0.75, 1.0, 0.14), fc + Vector3(0, _BASE_H + 0.5, face), dark, true)        # дверь


## Склад (хранилище): слитный каменный корпус + дощатая крыша + ящики поверх.
func _build_store() -> void:
	var stone := _solid(Color(0.55, 0.54, 0.52), 0.05, 0.9)
	var wood := _solid(_WOOD, 0.0, 0.95)
	var dark := _solid(_WOOD_DARK, 0.0, 0.9)
	var body_h := 1.4
	_build_compound(stone, wood, body_h, 0.3)
	var s: float = CityGrid.CELL
	var top: float = _BASE_H + body_h + 0.08 + 0.3  # верх крыши
	var f := _mask[0] as Vector2i
	var fc := Vector3(f.x * s, 0.0, f.y * s)
	_box(Vector3(1.0, 1.1, 0.14), fc + Vector3(0, _BASE_H + 0.55, s * 0.5 - _STREET), dark, true)  # ворота склада
	for i in _mask.size():
		var o := _mask[i] as Vector2i
		var c := Vector3(o.x * s, 0.0, o.y * s)
		# По ящику на клетку, со смещением — читается как разбросанный груз, не модули.
		var off := Vector3(0.35 if i % 2 == 0 else -0.35, 0.3, -0.3 if i % 2 == 0 else 0.35)
		_box(Vector3(0.6, 0.6, 0.6), c + off + Vector3(0, top, 0), wood, true)


## Квадратная башенка-замок (добытчик): каменный короб в цвет роли + зубцы по верху —
## стилистически как угловые башни качалки. Без коллайдера (Фаза 2).
func _build_tower() -> void:
	var body := _solid(_role_color(_role), 0.12, 0.82)
	var dark := _solid(_STONE_DARK, 0.1, 0.9)
	var trim := _solid(Color(0.4, 0.38, 0.4), 0.2, 0.85)
	var bw: float = CityGrid.CELL - 2.0 * _STREET  # ширина с отступом (улицы)
	_layer(_BASE_H * 0.5, bw + 0.06, _BASE_H, dark)                                   # цоколь
	var bh := 2.0
	_box(Vector3(bw, bh, bw), Vector3(0, _BASE_H + bh * 0.5, 0), body, true)          # короб
	_box(Vector3(bw + 0.12, 0.14, bw + 0.12), Vector3(0, _BASE_H + bh, 0), trim, true)  # карниз
	_battlements(bw * 0.5, _BASE_H + bh + 0.07, trim)                                # зубцы


## Добыча: привязка к жиле под шахтой (гейт размещения гарантирует, что шахта на жиле).
func _setup_mine() -> void:
	var tree := get_tree()
	var veins := OilDeposit.cell_map(tree)
	for wc in occupied_cells():
		if veins.has(wc as Vector2i):
			_vein = veins[wc as Vector2i]
			break
	add_to_group(Hand.PICKUP_HIGHLIGHT_GROUP)  # наведение руки → индикатор осей квартала (set_highlighted)
	set_process(true)


## Роли сапортов, которые закрывают квартал ЭТОГО продюсера (обобщённо). Шахта (PRODUCTION-ядро) →
## плавильня/двор/дом; казарма (DEFENSE-ядро) → барак. Пусто → здание не продюсер (нет квартала).
func _plot_support_roles() -> Dictionary:
	match _role:
		&"mine":
			return {&"smelter": true, &"mint": true, &"housing": true}
		&"barracks":
			return {&"barrack": true}  # ось «Гарнизон»: барак в зоне-соседстве → +кап этой казармы
		&"magic":
			# сапорты ускоряют ману; дом гномов (соц-универсал) работает на магию так же, как на шахту
			return {&"mana_crystal": true, &"mana_rune": true, &"housing": true}
		_:
			return {}


## Вклад в кап НАСЕЛЕНИЯ (supply-пул, автолоад Population): соц-постройки дают слоты. Прочее — 0.
func pop_provided() -> int:
	match _role:
		&"housing":
			return HOUSING_POP
		_:
			return 0  # барак населения НЕ даёт — он ёмкость казармы (см. hire_cap_bonus)


## Сколько слотов населения требует это PRODUCTION-здание, когда работает (гном на смену). Шахта на
## жиле — MINE_POP_DEMAND; плавильня/двор — 1 (рабочее место). Прочее — 0. Population комплектует
## остатком пула; без слота шахта простаивает, а плавильня/двор не дают свою ось (см. _quarter_status).
func pop_demand() -> int:
	match _role:
		&"mine":
			return MINE_POP_DEMAND if (_vein != null and is_instance_valid(_vein)) else 0
		&"smelter", &"mint":
			return 1
		&"magic", &"mana_crystal", &"mana_rune":
			return 1  # магия не исключение: институт + сапорты берут гнома (как шахта/плавильня)
		_:
			return 0


## Приоритет комплектования гномами при нехватке: 0 = раньше (ПРОДЮСЕР — шахта/институт держим),
## 1 = позже (сапорты — лишь усиление; их ось гаснет первой). Population сортирует по нему.
func pop_priority() -> int:
	return 0 if (_role == &"mine" or _role == &"magic") else 1


## Институт магии: льёт ману в башню (restore_mana капится на max) — но только
## пока башня У ПРИЧАЛА (док-плита, «город кормит башню через пуповину»;
## пивот 2026-07-07: в поле мана ТОЛЬКО с орбов убитых). Нет ни одной док-плиты
## в сцене — фоллбек на глобальный поток (чит-пути не софтлочим).
## Сапорты на гранях (Кристалл маны / Рунный обелиск) перемножают темп — по примеру квартала шахты.
func _tick_institute(delta: float) -> void:
	var tower := get_tree().get_first_node_in_group(&"tower")
	if tower == null or not is_instance_valid(tower) or not tower.has_method(&"restore_mana"):
		return
	# НАСЕЛЕНИЕ: без укомплектованного гнома институт ПРОСТАИВАЕТ — как шахта (магия не исключение).
	if Population != null and not Population.is_staffed(self):
		return
	# Мана течёт ТОЛЬКО в радиусе от института (INSTITUTE_FEED_RADIUS по XZ).
	# Был док-гейт с фоллбеком «нет дока → глобальный поток» — дыра: без
	# построенного дока институт кормил через всю карту.
	var t3d := tower as Node3D
	if t3d == null:
		return
	var fdx: float = t3d.global_position.x - global_position.x
	var fdz: float = t3d.global_position.z - global_position.z
	if fdx * fdx + fdz * fdz > INSTITUTE_FEED_RADIUS * INSTITUTE_FEED_RADIUS:
		return
	# Полный бак — НЕ кормим и луч НЕ рисуем («пополняется при полном» = враньё).
	if float(tower.get(&"mana")) >= float(tower.get(&"max_mana")):
		return
	# Пуповина видна: пока город кормит башню маной, от института к ней бежит
	# синий импульс (реюз PlaceFx.link_pulse). Кулдаун — не спам.
	_mana_beam_cd -= delta
	if _mana_beam_cd <= 0.0:
		_mana_beam_cd = 1.1
		PlaceFx.link_pulse(get_tree().current_scene,
			global_position + Vector3.UP * 1.5,
			Vector3(t3d.global_position.x, 2.0, t3d.global_position.z),
			Color(0.4, 0.65, 1.0))
	var st := _quarter_status()
	# Фидбэк «квартал СОБРАН» — симметрично шахте: вспышка единожды на переходе к 100%.
	var full: bool = float(st["fill"]) >= 0.999
	if full and not _quarter_was_full:
		_play_quarter_fx()
	_quarter_was_full = full
	tower.call(&"restore_mana", MANA_INSTITUTE_RATE * _mana_mult(st) * delta)


## Множитель темпа маны от сапортов в зоне института (перемножение, как оси шахты). Соло → 1.0.
## Кафедра/Осколок дают ось только УКОМПЛЕКТОВАННЫЕ гномом (staffed_roles); дом гномов — соц, без гнома.
## Принимает готовый _quarter_status (не пересчитывает) + «защёлк» полного квартала сверху.
func _mana_mult(st: Dictionary) -> float:
	var roles: Dictionary = st["staffed_roles"]
	var mult := 1.0
	if roles.has(&"mana_crystal"):
		mult *= MANA_MULT_CRYSTAL
	if roles.has(&"mana_rune"):
		mult *= MANA_MULT_RUNE
	if roles.has(&"housing"):
		mult *= MANA_MULT_HOUSE
	return mult * _full_quarter_mult(st)


## --- Clash-сбор: стопка добычи на крыше шахты (2026-07-07) ---
## Кап стопки в бронзовом эквиваленте; полна → добыча встаёт до сбора.
const MINE_STACK_CAP_BRONZE := 60
## Радиус автосбора башней (XZ): подъехал — стопка сама всасывается.
const MINE_COLLECT_RADIUS := 4.5
const COIN_ORB_SCENE := preload("res://scenes/xp_orb.tscn")
## Несобранная добыча (бронза). Копится в _tick_mine, забирается _collect_stack.
var _stack_bronze: int = 0
var _stack_root: Node3D = null
var _stack_coins_shown: int = -1


## Бронзовый эквивалент монеты номинала (двор чеканит серебро → ×10 ценность).
func _coin_bronze_value(coin_type: int) -> int:
	match coin_type:
		ResourcePile.ResourceType.GOLD:
			return 100
		ResourcePile.ResourceType.SILVER:
			return 10
		_:
			return 1


## Сбор стопки: башня вплотную (MINE_COLLECT_RADIUS) или ЛКМ-клик по шахте.
func _tick_mine_collect() -> void:
	if _stack_bronze <= 0:
		return
	var collect: bool = _clicked_on_self()
	if not collect:
		var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
		if tower != null and is_instance_valid(tower):
			var dx: float = tower.global_position.x - global_position.x
			var dz: float = tower.global_position.z - global_position.z
			collect = dx * dx + dz * dz <= MINE_COLLECT_RADIUS * MINE_COLLECT_RADIUS
	if collect:
		_collect_stack()


## Забрать стопку: веер монет-орбов летит к башне, каждый на arrival кладёт
## монеты в казну (попап «+N🥉» и салют на золотую — штатные у XpOrb).
func _collect_stack() -> void:
	var total: int = _stack_bronze
	if total <= 0:
		return
	_stack_bronze = 0
	_refresh_stack_visual()
	var root: Node = get_tree().current_scene
	var tower := get_tree().get_first_node_in_group(&"tower")
	var ctr: Vector3 = to_global(_footprint_center())
	if root == null or tower == null or not is_instance_valid(tower):
		# Фоллбек без сцены/башни: кредит напрямую, без полёта.
		var bank := get_tree().get_first_node_in_group(GoldBank.GROUP)
		if bank != null and bank.has_method(&"add_coin"):
			bank.call(&"add_coin", ResourcePile.ResourceType.BRONZE, total)
		return
	var n: int = clampi(total / 10 + 1, 2, 6)
	var base: int = total / n
	var rem: int = total % n
	for i in range(n):
		var share: int = base + (1 if i < rem else 0)
		if share <= 0:
			continue
		var orb := COIN_ORB_SCENE.instantiate() as XpOrb
		if orb == null:
			continue
		orb.amount = 0
		orb.mana_amount = 0.0
		orb.gold_amount = share
		orb.position = ctr + Vector3(randf_range(-0.5, 0.5), 2.2 + randf_range(0.0, 0.5), randf_range(-0.5, 0.5))
		root.add_child(orb)
		# Форс-магнит к башне сразу: монеты веером стягиваются, не ждут касания.
		if orb.has_method(&"_activate_magnet_to_tower"):
			orb.call(&"_activate_magnet_to_tower", tower)
	AoeVisual.spawn_pulse_sparks(root, ctr + Vector3.UP * 2.2, 1.2, 10.0)


## Стопка монет на крыше: 1 «монета» ≈ 10 бронзы, до 8 в столбике. Перестраиваем
## только при смене числа монет (не каждый тик).
func _refresh_stack_visual() -> void:
	var coins: int = clampi(int(ceil(float(_stack_bronze) / 10.0)), 0, 8)
	if coins == _stack_coins_shown:
		return
	_stack_coins_shown = coins
	if _stack_root != null and is_instance_valid(_stack_root):
		_stack_root.queue_free()
	_stack_root = null
	if coins <= 0:
		return
	_stack_root = Node3D.new()
	add_child(_stack_root)
	var gold := _solid(Color(1.0, 0.85, 0.35), 0.5, 0.35)
	gold.emission_enabled = true
	gold.emission = Color(1.0, 0.8, 0.3)
	gold.emission_energy_multiplier = 1.2
	var ctr: Vector3 = _footprint_center()
	for i in range(coins):
		var c := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.28
		cm.bottom_radius = 0.28
		cm.height = 0.09
		c.mesh = cm
		c.material_override = gold
		c.position = ctr + Vector3(randf_range(-0.06, 0.06), 2.25 + float(i) * 0.11, randf_range(-0.06, 0.06))
		c.rotation.y = randf() * TAU
		_stack_root.add_child(c)


## Шаг добычи: шахта копит добычу СТОПКОЙ на крыше (Clash-сбор). Каждый ТИП сапорта в зоне крутит СВОЮ ось:
## ПЛАВИЛЬНЯ → ×СКОРОСТЬ темпа; ДОМ → ×ОБЪЁМ монет за выплату; ДВОР → НОМИНАЛ монеты на тир выше.
## Заполнение зоны на 100% → вспышка «собран».
func _tick_mine(delta: float) -> void:
	if _vein == null or not is_instance_valid(_vein):
		return
	# НАСЕЛЕНИЕ: без укомплектованного слота (Population) шахта ПРОСТАИВАЕТ — не копит/не платит.
	# Военный приоритет: если солдат столько, что на шахты слотов не осталось — добыча встаёт.
	if Population != null and not Population.is_staffed(self):
		return
	# Стопка полна — добыча встаёт (Clash: полный коллектор стоит, ЗАБЕРИ).
	if _stack_bronze >= MINE_STACK_CAP_BRONZE:
		return
	var st := _quarter_status()
	var roles: Dictionary = st["roles"]
	var staffed: Dictionary = st["staffed_roles"]  # ось работает, только если у сапорта есть гном
	var fill: float = st["fill"]
	# Оси сапортов: плавильня/двор — рабочие места, ось активна лишь с гномом (staffed_roles).
	# Дом — социальный (гнома не требует) → ось «Объём» по факту постройки (он в staffed_roles всегда).
	var speed: float = MINE_SPEED_MULT if staffed.has(&"smelter") else 1.0   # плавильня → скорость
	var volume: int = MINE_VOLUME_MULT if staffed.has(&"housing") else 1     # дом → объём
	var coin: int = _upgraded_coin(_vein.coin_type()) if staffed.has(&"mint") else _vein.coin_type()  # двор → номинал
	# Фидбэк «квартал СОБРАН»: вспышка ЕДИНОЖДЫ при 100% заполнения зоны (по всей зоне).
	var full: bool = fill >= 0.999
	if full and not _quarter_was_full:
		_play_quarter_fx()
	_quarter_was_full = full
	# «Защёлк»: полный квартал крутит темп сверх осей — комбо за полный сет.
	_mine_accum += MINE_RATE * speed * _full_quarter_mult(st) * delta
	var whole := int(_mine_accum)
	if whole < 1:
		return
	_mine_accum -= float(whole)
	var pay: int = whole * volume
	# CLASH-СБОР (2026-07-07, «нет тактильности»): добыча НЕ капает в казну сама —
	# копится ВИДИМОЙ стопкой монет на крыше (бронзовый эквивалент номинала; двор
	# сохраняет своё ×10 через ценность). Забираешь башней вплотную или ЛКМ-кликом
	# (_tick_mine_collect) — веер монет-орбов летит к башне, казна звенит попапами.
	_stack_bronze = mini(_stack_bronze + pay * _coin_bronze_value(coin), MINE_STACK_CAP_BRONZE)
	_refresh_stack_visual()


## Разгрузка трюма: башня в радиусе и трюм не пуст → сдаём ВСЁ ОДНОМОМЕНТНО.
## Монеты падают в казну сразу всей суммой (GoldBank.smelt_yield: дерево→бронза,
## камень→серебро, железо→золото; салюты на золотые — штатные банковские), а
## визуал — ВОЛНА чанков от башни к замку: каждый со случайной задержкой в окне
## UNLOAD_WAVE_SPREAD и разбросом точек вылета/прилёта («растянутая куча»).
## Игрок может уезжать сразу — деньги уже в казне, чанки долетят сами.
## Темп тихого ремонта корпуса башни в доке (hp/с).
const DOCK_REPAIR_RATE := 12.0

## Прошлое состояние парковки — плашка только на переходе «встал в док».
var _docked_prev: bool = false
## Кулдаун синего импульса «институт кормит башню» (виден только в доке).
var _mana_beam_cd: float = 0.0


## Сервисы дока (город обслуживает башню у причала): плашка на входе + ремонт.
## Мана института гейтится доком на стороне института ([_tick_institute]).
func _tick_dock_services(docked: bool) -> void:
	if docked != _docked_prev:
		_docked_prev = docked
		if docked:
			EventBus.tutorial_hint.emit("⚓ Башня в доке: мана течёт, корпус чинится", 5.0)
	if not docked:
		return
	var tower := get_tree().get_first_node_in_group(&"tower")
	if tower != null and is_instance_valid(tower) and tower.has_method(&"repair"):
		tower.call(&"repair", DOCK_REPAIR_RATE * UNLOAD_CHECK_INTERVAL)


## Башня жива и припаркована на этой плите (XZ ≤ UNLOAD_RADIUS)? Единая
## проверка дока: трюм, мана института ([_tick_institute]) и ремонт корпуса.
func is_tower_docked() -> bool:
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	if tower == null or not is_instance_valid(tower):
		return false
	# Мёртвая башня остаётся в группе tower (труп держит камера), но из Damageable
	# выходит — труп, припаркованный на плите, не обслуживаем.
	if not Damageable.is_damageable(tower):
		return false
	var dx: float = tower.global_position.x - global_position.x
	var dz: float = tower.global_position.z - global_position.z
	return dx * dx + dz * dz <= UNLOAD_RADIUS * UNLOAD_RADIUS


## Хоть одна док-плита сцены с припаркованной башней? Гейт «город кормит башню
## только в доке» — читает институт (мана) и HUD.
static func is_tower_docked_any(tree: SceneTree) -> bool:
	for n in tree.get_nodes_in_group(&"pad_building"):
		var p := n as PadBuilding
		if p != null and is_instance_valid(p) and p.is_unload() and p.is_tower_docked():
			return true
	return false


## Есть ли в сцене вообще док-плиты (для фоллбека институтской маны).
static func has_dock_pads(tree: SceneTree) -> bool:
	for n in tree.get_nodes_in_group(&"pad_building"):
		var p := n as PadBuilding
		if p != null and is_instance_valid(p) and p.is_unload():
			return true
	return false


func _tick_unload(delta: float) -> void:
	_unload_cd -= delta
	if _unload_cd > 0.0:
		return
	_unload_cd = UNLOAD_CHECK_INTERVAL
	var docked: bool = is_tower_docked()
	_tick_dock_services(docked)
	if not docked:
		return
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	var store: Node = get_tree().get_first_node_in_group(Layers.TOWER_STORE_GROUP)
	var bank: Node = get_tree().get_first_node_in_group(GoldBank.GROUP)
	if store == null or bank == null or not bank.has_method(&"smelt_yield"):
		return
	# Забираем всё и сразу платим; чанки копим списком по единице (для волны).
	var chunks: Array = []
	for type in [ResourcePile.ResourceType.WOOD, ResourcePile.ResourceType.STONE,
			ResourcePile.ResourceType.IRON, ResourcePile.ResourceType.SILVER,
			ResourcePile.ResourceType.GOLD]:
		var n: int = int(store.call(&"get_amount", type))
		if n <= 0 or not bool(store.call(&"take", type, n)):
			continue
		var pair: Array = bank.call(&"smelt_yield", type)
		bank.call(&"add_coin", pair[0], int(pair[1]) * n)
		for _i in range(n):
			chunks.append(type)
	if chunks.is_empty():
		return
	chunks.shuffle()  # цвета волны вперемешку, не «сначала всё дерево»
	# Y башни игнорируем (origin y≈5 — [[reference_ebm_tower_origin_y5]]).
	var from := Vector3(tower.global_position.x, 0.0, tower.global_position.z)
	var castle := get_tree().get_first_node_in_group(&"castle") as Node3D
	var to: Vector3 = castle.global_position if (castle != null and is_instance_valid(castle)) else global_position
	for type in chunks:
		var tw := create_tween()  # node-bound: платформа снесена → волна гаснет
		tw.tween_interval(randf() * UNLOAD_WAVE_SPREAD + 0.02)
		tw.tween_callback(_spawn_cargo_chunk.bind(int(type), from, to))


## Один чанк волны разгрузки: link_pulse от точки у башни (случайный разброс —
## «куча», не струна) к замку, цвет материала.
func _spawn_cargo_chunk(type: int, from: Vector3, to: Vector3) -> void:
	if not is_inside_tree():
		return
	var f := from + Vector3(randf_range(-1.3, 1.3), 0.0, randf_range(-1.3, 1.3))
	var t := to + Vector3(randf_range(-0.9, 0.9), 0.0, randf_range(-0.9, 0.9))
	PlaceFx.link_pulse(get_tree().current_scene, f, t, _cargo_chunk_color(type))


## Цвет чанка разгрузки по материалу (язык материала, не боя).
func _cargo_chunk_color(type: int) -> Color:
	match type:
		ResourcePile.ResourceType.WOOD:
			return Color(0.6, 0.4, 0.22)
		ResourcePile.ResourceType.STONE:
			return Color(0.66, 0.66, 0.66)
		ResourcePile.ResourceType.IRON:
			return Color(0.55, 0.62, 0.75)
		ResourcePile.ResourceType.SILVER:
			return Color(0.85, 0.88, 0.95)
		_:
			return Color(0.98, 0.82, 0.3)  # золото


## Визуал верфи башни: стальная плита на весь футпринт 2×2 (башня заезжает — без
## коллизии, см. _ready) + янтарный посадочный квадрат + 4 угловых крана-стойки с
## фонарями. Тот же язык, что разгрузочная платформа, но металл/выше — «стапель».
func _build_dock() -> void:
	var s: float = CityGrid.CELL
	var metal := _solid(Color(0.48, 0.53, 0.6), 0.5, 0.45)
	var glow := _solid(Color(0.95, 0.75, 0.35), 0.3, 0.4)
	glow.emission_enabled = true
	glow.emission = Color(0.95, 0.75, 0.35)
	glow.emission_energy_multiplier = 1.1
	# Центроид маски (2×2 → центр между клетками): плита кроет весь футпринт.
	var cx: float = 0.0
	var cz: float = 0.0
	for off in _mask:
		cx += float((off as Vector2i).x)
		cz += float((off as Vector2i).y)
	cx = cx / float(maxi(_mask.size(), 1)) * s
	cz = cz / float(maxi(_mask.size(), 1)) * s
	_box(Vector3(s * 2.0, 0.14, s * 2.0), Vector3(cx, 0.07, cz), metal, false)
	_box(Vector3(s * 1.2, 0.05, s * 1.2), Vector3(cx, 0.17, cz), glow, false)
	# Угловые краны-стойки: высокая мачта + стрела к центру + фонарь на верхушке.
	for dx in [-1.0, 1.0]:
		for dz in [-1.0, 1.0]:
			var px: float = cx + dx * (s - 0.2)
			var pz: float = cz + dz * (s - 0.2)
			_box(Vector3(0.26, 2.4, 0.26), Vector3(px, 1.2, pz), metal, true)
			_box(Vector3(0.8, 0.18, 0.18) if absf(dx) > 0.0 else Vector3(0.18, 0.18, 0.8),
				Vector3(px - dx * 0.45, 2.3, pz), metal, true)
			_box(Vector3(0.3, 0.3, 0.3), Vector3(px, 2.55, pz), glow, true)


## Визуал разгрузочной платформы: плоская плита на весь футпринт 2×2 + светящийся
## посадочный квадрат + угловые маячки. Без коллизии (см. _ready) — башня заезжает.
func _build_unload_pad() -> void:
	var s: float = CityGrid.CELL
	var plate := _solid(Color(0.5, 0.42, 0.3), 0.1, 0.8)
	var glow := _solid(Color(0.95, 0.8, 0.35), 0.3, 0.4)
	glow.emission_enabled = true
	glow.emission = Color(0.95, 0.8, 0.35)
	glow.emission_energy_multiplier = 1.2
	# Центроид маски (2×2 → центр между клетками): плита кроет весь футпринт.
	var cx: float = 0.0
	var cz: float = 0.0
	for off in _mask:
		cx += float((off as Vector2i).x)
		cz += float((off as Vector2i).y)
	cx = cx / float(maxi(_mask.size(), 1)) * s
	cz = cz / float(maxi(_mask.size(), 1)) * s
	_box(Vector3(s * 2.0, 0.14, s * 2.0), Vector3(cx, 0.07, cz), plate, false)
	_box(Vector3(s * 1.2, 0.05, s * 1.2), Vector3(cx, 0.17, cz), glow, false)
	for dx in [-1.0, 1.0]:
		for dz in [-1.0, 1.0]:
			_box(Vector3(0.22, 1.1, 0.22), Vector3(cx + dx * (s - 0.2), 0.55, cz + dz * (s - 0.2)), glow, true)


## Клетки квартала продюсера = ВСЕ грани (орто-соседство футпринта в паде). Контур-силуэт убран —
## квартал = заполни соседние клетки сапортами; каждый ТИП сапорта баффает продюсера по-своему.
func _plot_cells_ordered() -> Array:
	return _adjacent_free_cells()


## Клетки орто-соседства футпринта (в паде, не свои) — зона квартала для многоклеточного продюсера
## (казарма). Барак, чья клетка попала сюда, засчитан. Порядок стабилен (для перекраски плиток).
func _adjacent_free_cells() -> Array:
	var tree := get_tree()
	var own := occupied_cells()
	var ownset: Dictionary = {}
	for c in own:
		ownset[c as Vector2i] = true
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var seen: Dictionary = {}
	var out: Array = []
	for c in own:
		for d in dirs:
			var nb: Vector2i = (c as Vector2i) + d
			if ownset.has(nb) or seen.has(nb):
				continue
			if not CityGrid.in_pad(nb, tree):
				continue  # за падом — не зона
			seen[nb] = true
			out.append(nb)
	return out


## Set клеток квартала (грани продюсера) — для проверки попадания сапорта в зону.
func _plot_world_cells() -> Dictionary:
	var out: Dictionary = {}
	for c in _plot_cells_ordered():
		out[c] = true
	return out


## Показать/скрыть маркеры buff-слотов квартала (граней продюсера). Зовётся HandPlaceAim в режиме
## стройки — игрок видит, какие грани занять для макс. баффа. Только у продюсеров; лениво, перекраска.
func set_quarter_slots_visible(v: bool) -> void:
	if _plot_support_roles().is_empty():
		return  # не продюсер — слотов нет
	if v and (_slot_ghost == null or not is_instance_valid(_slot_ghost)):
		_build_slot_ghost()
	if _slot_ghost != null and is_instance_valid(_slot_ghost):
		_slot_ghost.visible = v
		if v:
			_refresh_slot_ghost()


## Маркеры-плитки по клеткам-граням квартала. top_level + позиции по CityGrid.cell_to_world (грид-
## абсолют, не наследует трансформ продюсера). У каждой плитки свой материал (красим по заполнению).
func _build_slot_ghost() -> void:
	var tree := get_tree()
	var cells := _plot_cells_ordered()
	if cells.is_empty():
		return
	var s: float = CityGrid.CELL
	var tile: float = s - 2.0 * _STREET
	_slot_ghost = Node3D.new()
	_slot_ghost.name = "QuarterSlots"
	_slot_ghost.top_level = true
	add_child(_slot_ghost)
	for c in cells:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = SLOT_OPEN_COLOR
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var plane := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(tile, tile)
		plane.mesh = pm
		plane.material_override = mat
		var wpos: Vector3 = CityGrid.cell_to_world(c as Vector2i, tree)
		plane.position = Vector3(wpos.x, wpos.y + 0.06, wpos.z)
		_slot_ghost.add_child(plane)


## Перекрасить маркеры по заполнению: занятая сапортом грань → зелёная, свободная → открытый слот.
func _refresh_slot_ghost() -> void:
	if _slot_ghost == null or not is_instance_valid(_slot_ghost):
		return
	var cells := _plot_cells_ordered()
	var covered: Dictionary = _quarter_status().get("covered", {})
	var kids := _slot_ghost.get_children()
	for i in range(min(kids.size(), cells.size())):
		var tile := kids[i] as MeshInstance3D
		if tile == null:
			continue
		var m := tile.material_override as StandardMaterial3D
		if m == null:
			continue
		m.albedo_color = SLOT_FILLED_COLOR if covered.has(cells[i]) else SLOT_OPEN_COLOR


## Статус квартала-силуэта (обобщён по продюсеру через _plot_support_roles): `roles` = set ролей
## сапортов в плоте (шахта → оси по smelter/mint/housing); `support_count` = ШТУК зданий-сапортов в
## плоте (казарма → кап найма ×N); `fill` = доля заполнения (вспышка/подсветка); `covered` = клетки.
## ПРАВИЛО КАТЕГОРИЙ: сапорт квартала = только роли из _plot_support_roles (барак не лезет в квартал
## шахты, плавильня — в квартал казармы; стены/прочее не считаются нигде).
func _quarter_status() -> Dictionary:
	var plot := _plot_world_cells()
	var capacity: int = plot.size()
	var support_roles := _plot_support_roles()
	if capacity == 0 or support_roles.is_empty():
		return {"roles": {}, "staffed_roles": {}, "fill": 0.0, "covered": {}, "support_count": 0}
	var covered: Dictionary = {}       # клетки плота, закрытые сапортами этого квартала
	var roles: Dictionary = {}         # set ролей сапортов, попавших в плот (по факту постройки)
	var staffed_roles: Dictionary = {} # set ролей, чей сапорт УКОМПЛЕКТОВАН гномом → ось реально работает
	var count: int = 0                 # ШТУК зданий-сапортов в плоте
	for b in get_tree().get_nodes_in_group(GROUP):
		if b == self or not is_instance_valid(b) or not b.has_method(&"occupied_cells") or not b.has_method(&"get_role"):
			continue
		var r: StringName = b.call(&"get_role")
		if not support_roles.has(r):
			continue  # не сапорт этого квартала (другая категория/роль)
		var in_plot := false
		for c in b.call(&"occupied_cells"):
			if plot.has(c):
				covered[c] = true
				in_plot = true
		if in_plot:
			roles[r] = true
			count += 1
			# Производственный сапорт (pop_demand>0: плавильня/двор) даёт ось ТОЛЬКО с гномом-сменой.
			# Соц-сапорт (дом, pop_demand=0) гнома не требует — ось по факту постройки.
			var needs_gnome: bool = b.has_method(&"pop_demand") and int(b.call(&"pop_demand")) > 0
			if (not needs_gnome) or (Population != null and Population.is_staffed(b)):
				staffed_roles[r] = true
	return {"roles": roles, "staffed_roles": staffed_roles, "fill": float(covered.size()) / float(capacity), "covered": covered, "support_count": count}


## Множитель «защёлка»: полный квартал (fill=100%) → FULL_QUARTER_BONUS, иначе 1.0.
func _full_quarter_mult(st: Dictionary) -> float:
	return FULL_QUARTER_BONUS if float(st["fill"]) >= 0.999 else 1.0


## «Печать» установки (зовёт HandPlaceAim после финального трансформа): падение+сквош+
## пыль+рябь+тряска. Радиус — по дальней клетке маски. refresh_walls этот метод НЕ зовёт:
## перестройка соседа ≠ новая постройка (иначе стены прыгали бы от каждой установки рядом).
func play_place_impact() -> void:
	var r: float = 0.0
	for off in _mask:
		r = maxf(r, Vector2(off as Vector2i).length())
	PlaceFx.play(self, r * CityGrid.CELL + CityGrid.CELL * 0.7)


## Линк-пульсы кварталов после установки ЭТОГО здания (обе стороны):
## - я САПОРТ, закрывший грань продюсера → импульс от меня к нему + его плашка на 2.5с;
## - я ПРОДЮСЕР, и сапорты уже стоят на моих гранях → импульс от каждого ко мне.
## Зовётся ДО play_place_impact (позиции ещё наземные, не поднятые падением).
func flash_quarter_links() -> void:
	var my_cells: Dictionary = {}
	for c in occupied_cells():
		my_cells[c] = true
	var root: Node = get_tree().current_scene
	for p in get_tree().get_nodes_in_group(GROUP):
		if p == self or not is_instance_valid(p) or not (p is PadBuilding):
			continue
		var other := p as PadBuilding
		if other._plot_support_roles().has(_role) and _cells_hit(other._plot_world_cells(), my_cells):
			PlaceFx.link_pulse(root, global_position, other.global_position, _role_color(_role))
			other.flash_indicator()
		elif _plot_support_roles().has(other._role) and _cells_hit(_plot_world_cells(), _cells_set_of(other)):
			PlaceFx.link_pulse(root, other.global_position, global_position, _role_color(other._role))
			flash_indicator()


func _cells_hit(zone: Dictionary, cells: Dictionary) -> bool:
	for c in cells:
		if zone.has(c):
			return true
	return false


func _cells_set_of(b: PadBuilding) -> Dictionary:
	var out: Dictionary = {}
	for c in b.occupied_cells():
		out[c] = true
	return out


## Показать плашку осей на sec секунд БЕЗ наведения руки (фидбэк «грань закрыта»).
## Повторный вызов продлевает: прежний таймер убивается (паттерн _pose_tween).
func flash_indicator(sec: float = 2.5) -> void:
	if not (_role == &"mine" or _role == &"barracks" or _role == &"magic"):
		return
	_set_quarter_indicator_visible(true)
	if _ind_flash_tween != null and _ind_flash_tween.is_valid():
		_ind_flash_tween.kill()
	_ind_flash_tween = create_tween()
	_ind_flash_tween.tween_interval(sec)
	_ind_flash_tween.tween_callback(_set_quarter_indicator_visible.bind(false))


## Клетки для FX-вспышки = шахта + ЗАКРЫТЫЕ сапортами клетки плота (реально собранный квартал),
## а НЕ весь пустой силуэт — иначе вспышка моргала большой пустой областью на каждый новый тип.
func _quarter_cells() -> Array:
	var out: Array = occupied_cells()  # шахта
	for c in _quarter_status().get("covered", {}):
		out.append(c)
	return out


## Фидбэк «квартал собран»: ВЕСЬ квартал (все здания + площадка под ними) ярко мигает разом —
## жёлтый полупрозрачный столб по каждой клетке квартала, гаснет тваном. Зовётся при росте
## числа сапортов (см. _tick_mine).
func _play_quarter_fx() -> void:
	var tree := get_tree()
	var scene := tree.current_scene if tree != null else null
	if scene == null or not is_instance_valid(scene):
		return
	var cells := _quarter_cells()
	if cells.is_empty():
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.92, 0.45, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var flash := Node3D.new()
	scene.add_child(flash)
	var s: float = CityGrid.CELL
	for cell in cells:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(s * 0.98, 3.4, s * 0.98)
		mi.mesh = bm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.top_level = true
		flash.add_child(mi)
		mi.global_position = CityGrid.cell_to_world(cell as Vector2i, tree) + Vector3(0, 1.7, 0)
	# Яркая вспышка → гаснет за 0.5с, затем самоудаление.
	var tw := flash.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.5)
	tw.tween_callback(flash.queue_free)


func _process(delta: float) -> void:
	# Маркеры buff-слотов (грани продюсера) — live-перекраска, пока показаны (режим стройки).
	if _slot_ghost != null and is_instance_valid(_slot_ghost) and _slot_ghost.visible:
		_refresh_slot_ghost()
	if is_magic():
		_tick_institute(delta)
	if _role == &"mine":
		_tick_mine(delta)
		_tick_mine_collect()  # сбор стопки: башня вплотную или ЛКМ-клик
		# Live-обновление индикатора осей, пока наведено (hover) — поспел за достройкой сапорта.
		if _quarter_indicator != null and is_instance_valid(_quarter_indicator) and _quarter_indicator.visible:
			_refresh_quarter_indicator()
		# Всплывашка «+прибыль» над шахтой (агрегируем добытое, не чаще интервала).
		if _popup_cd > 0.0:
			_popup_cd -= delta
		if _recv_amount > 0 and _popup_cd <= 0.0:
			_spawn_profit_popup(_recv_coin, _recv_amount)  # номинал = чем реально платили (двор поднимает)
			_recv_amount = 0
			_popup_cd = POPUP_INTERVAL
	if is_barracks():
		_tick_hire_click()
		# Live-обновление плашки-индикатора казармы (гарнизон/кап), пока наведено.
		if _quarter_indicator != null and is_instance_valid(_quarter_indicator) and _quarter_indicator.visible:
			_refresh_quarter_indicator()
	if is_scroll_dept():
		_tick_scroll_click()
	if is_dock():
		_tick_dock_click()
	if is_unload():
		_tick_unload(delta)
	if building_id == RoomBuildings.PAD_ENGINEER_LAB:
		_tick_forge_click()


## Номинал на тир выше (чеканный двор-сапорт). Лесенка тиров — единая, в GoldBank.
func _upgraded_coin(coin_type: int) -> int:
	return GoldBank.next_tier(coin_type)


## Emoji-иконка номинала монеты (для плашки-индикатора).
func _coin_emoji(coin_type: int) -> String:
	match coin_type:
		ResourcePile.ResourceType.SILVER:
			return "🥈"
		ResourcePile.ResourceType.GOLD:
			return "🥇"
		_:
			return "🥉"


## Имя номинала монеты для UI-индикаторов.
func _coin_name(coin_type: int) -> String:
	match coin_type:
		ResourcePile.ResourceType.SILVER:
			return "серебро"
		ResourcePile.ResourceType.GOLD:
			return "золото"
		_:
			return "бронза"


## Цвет номинала монеты (бронза/серебро/золото) — единый для индикаторов и всплывашек.
func _coin_color(coin_type: int) -> Color:
	match coin_type:
		ResourcePile.ResourceType.SILVER:
			return Color(0.85, 0.87, 0.92)
		ResourcePile.ResourceType.GOLD:
			return Color(0.98, 0.80, 0.25)
		_:
			return Color(0.80, 0.50, 0.22)  # бронза


## Всплывашка прибыли над банком: «+N» (реюз [SquadXpPopup], поднимается+тает) + плоская
## монета-иконка цвета номинала рядом с числом. Показывает, что и сколько зачислено в казну.
func _spawn_profit_popup(coin_type: int, amount: int) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null or not is_instance_valid(scene):
		return
	var col := _coin_color(coin_type)
	var popup := SquadXpPopup.new()
	popup.text = "+%d" % amount
	popup.lifetime = POPUP_LIFETIME  # дольше живёт → одновременно видно несколько в столбик
	popup.drift = 0.5                # вихляет вбок как дымок, а не строго вверх
	scene.add_child(popup)
	popup.global_position = to_global(_mask_center()) + Vector3(0, 2.2, 0)
	popup.modulate = col  # цвет числа = номинал (fade в _process двигает только альфу)
	# Плоская монетка-иконка цвета номинала слева от числа (едет вместе со всплывашкой).
	var icon := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.18
	cm.bottom_radius = 0.18
	cm.height = 0.05
	icon.mesh = cm
	var mat := _solid(col, 0.6, 0.3)
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 0.9
	icon.material_override = mat
	icon.position = Vector3(-0.5, 0.0, 0.0)
	popup.add_child(icon)


## Небольшой фейерверк над банком: одноразовый GPUParticles3D-залп — мелкие РАЗНОЦВЕТНЫЕ
## искры (радуга по hue) с ТРЕЙЛАМИ разлетаются шаром и опадают. Зовётся на КАЖДУЮ новую
## золотую монету в казне; сам себя освобождает по таймеру. Параметр coin_type не используем
## (фейерверк нарочно радужный — праздник, не номинал).
func _spawn_firework(_coin_type: int) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null or not is_instance_valid(scene):
		return
	var life := 1.3
	var fw := GPUParticles3D.new()
	fw.amount = 28
	fw.lifetime = life
	fw.one_shot = true
	fw.explosiveness = 1.0           # все искры разом → хлопок
	fw.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fw.trail_enabled = true          # нативные трейлы за искрами
	fw.trail_lifetime = 0.35
	# Мелкая искра (≈вдвое меньше прежних осколков 0.25), цвет — из частицы, без освещения.
	var bm := BoxMesh.new()
	bm.size = Vector3(0.12, 0.12, 0.12)
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.vertex_color_use_as_albedo = true
	dmat.emission_enabled = true
	dmat.emission = Color(1, 1, 1)
	dmat.emission_energy_multiplier = 1.2
	bm.material = dmat
	fw.draw_pass_1 = bm
	# Шаровой разлёт + гравитация (арка вниз); радуга через широкую вариацию оттенка.
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0                # во все стороны
	pm.initial_velocity_min = 4.0
	pm.initial_velocity_max = 8.0
	pm.gravity = Vector3(0, -7.0, 0)
	pm.scale_min = 0.7
	pm.scale_max = 1.2
	pm.color = Color(1.0, 0.25, 0.25)  # насыщенная база → hue-вариация даёт полный спектр
	pm.hue_variation_min = -1.0
	pm.hue_variation_max = 1.0
	# Затухание альфы к концу жизни.
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var gtex := GradientTexture1D.new()
	gtex.gradient = grad
	pm.color_ramp = gtex
	fw.process_material = pm
	scene.add_child(fw)
	fw.global_position = to_global(_mask_center()) + Vector3(0, 3.2, 0)  # над крышей/куполом
	fw.restart()
	# Самоочистка после залпа+трейлов (WeakRef — без «Lambda capture freed» на смене сцены).
	var ref: WeakRef = weakref(fw)
	tree.create_timer(life + 0.6).timeout.connect(func() -> void:
		var n: Node = ref.get_ref()
		if n != null and n.is_inside_tree():
			n.queue_free())


## Валидный ЛКМ-клик по футпринту ЭТОГО здания. Единый гейт для найма/чеканки:
## модалка закрыта, нажат hand_grab, рука НЕ в aim-режиме (команда/стройка/супер), НЕ над
## HUD и ничего не держит, и курсорная клетка в occupied_cells. Иначе клик-команды aim'ов
## и клики по HUD рядом со зданием паразитно дёргали бы стол. Точность по клеткам.
func _clicked_on_self() -> bool:
	var tree := get_tree()
	var trade := tree.get_first_node_in_group(&"trade_ui")
	if trade != null and trade.has_method(&"is_open") and trade.call(&"is_open"):
		return false
	if not Input.is_action_just_pressed(ACTION_GRAB):
		return false
	var hand := tree.get_first_node_in_group(Hand.HAND_GROUP) as Hand
	if hand == null:
		return false
	if hand.is_in_aim_mode() or hand.is_pointer_over_ui() or hand.is_holding():
		return false
	var cell := CityGrid.world_to_cell(hand.cursor_world_position(), tree)
	return cell in occupied_cells()


## ЛКМ по футпринту казармы → ПАНЕЛЬ КАЗАРМЫ в HUD (нанять / призвать / на стену).
## Стол найма открывается из панели (open_hire), не напрямую.
func _tick_hire_click() -> void:
	if _clicked_on_self():
		EventBus.barracks_panel_requested.emit(self)


## Открыть стол найма этой казармы (зовёт кнопка «Нанять» панели казармы в HUD).
func open_hire() -> void:
	_open_hire()


## Отряд этой казармы (или null, если ещё не нанимали) — для панели казармы.
func my_squad() -> Squad:
	var sp := get_tree().get_first_node_in_group(&"squad_spawner")
	if sp != null and sp.has_method(&"owner_squad"):
		return sp.call(&"owner_squad", self)
	return null


## Эффективный кап гарнизона этой казармы (публично для панели казармы в HUD).
func hire_cap() -> int:
	return _my_hire_cap()


## Цена ковки Гарпунной турели в гильдии инженеров (клик по зданию).
const FORGE_MODULE_COST_BRONZE := 40


## ЛКМ по Гильдии инженеров → ВЫКОВАТЬ аппарат: списываем монеты, модуль-вещь
## выпадает перед зданием (дальше рука несёт его к башне). Модульная система:
## «кафедры производят вещи, рука ставит».
func _tick_forge_click() -> void:
	if not _clicked_on_self():
		return
	var bank := get_tree().get_first_node_in_group(GoldBank.GROUP)
	if bank == null or not bank.has_method(&"try_spend"):
		return
	if not bank.call(&"try_spend", FORGE_MODULE_COST_BRONZE):
		EventBus.tutorial_hint.emit("Ковка турели: не хватает монет (нужно %d🥉)" % FORGE_MODULE_COST_BRONZE, 3.0)
		return
	var root: Node = get_tree().current_scene
	if root == null:
		return
	var ctr: Vector3 = to_global(_footprint_center())
	# Выпадает в сторону башни (в открытое место), на землю.
	var out := Vector3.FORWARD
	var tower := get_tree().get_first_node_in_group(&"tower") as Node3D
	if tower != null and is_instance_valid(tower):
		out = VecUtil.horizontal(tower.global_position - ctr)
		out = out.normalized() if out.length() > 0.1 else Vector3.FORWARD
	var module := HarpoonModule.new()
	module.position = Vector3(ctr.x, 0.4, ctr.z) + out * 2.2
	root.add_child(module)
	AoeVisual.spawn_pulse_sparks(root, module.global_position + Vector3.UP * 0.5, 1.0, 10.0)
	EventBus.camera_shake.emit(0.2, ctr)
	EventBus.tutorial_hint.emit("⚙ Турель выкована! Схвати рукой и поднеси к башне", 4.0)


## ЛКМ по Кафедре Волшебных свитков. МАГАЗИН ЗАКЛИНАНИЙ УМЕР (2026-07-07):
## заклинания открывают КАФЕДРЫ-ШКОЛЫ постройкой (role spell_lab, «хочешь
## пушку — построй завод»). Клик оставлен как подсказка-редирект.
func _tick_scroll_click() -> void:
	if _clicked_on_self():
		EventBus.tutorial_hint.emit("Заклинания открывают КАФЕДРЫ-ШКОЛЫ (🔮 Магия в палитре): огонь / инженерия / лёд", 5.0)


## ЛКМ по плите верфи → HUD открывает окно срезов башни (ловит tower_dock_requested).
func _tick_dock_click() -> void:
	if _clicked_on_self():
		EventBus.tower_dock_requested.emit()


## Контракт hover-подсветки (Hand._update_pickup_highlight): наводим руку → казарма/шахта
## светится emission'ом. Тоггл по всем мешам фигуры (материалы per-instance из _build).
## Для ШАХТЫ дополнительно показываем/скрываем индикатор осей квартала.
func set_highlighted(value: bool) -> void:
	for ch in get_children():
		var mi := ch as MeshInstance3D
		if mi == null:
			continue
		var mat := mi.material_override as StandardMaterial3D
		if mat == null:
			continue
		mat.emission_enabled = value
		mat.emission = Color(0.55, 0.7, 1.0)
		mat.emission_energy_multiplier = 0.5 if value else 0.0
	if _role == &"mine" or _role == &"barracks" or _role == &"magic":
		_set_quarter_indicator_visible(value)  # шахта → оси; казарма → гарнизон; институт → мана


## Показать/скрыть индикатор осей квартала над шахтой (при наведении руки). Лениво строится.
## SubViewport рендерит только пока видно (UPDATE_ALWAYS), иначе DISABLED — не жрёт кадр впустую.
func _set_quarter_indicator_visible(v: bool) -> void:
	if v and (_quarter_indicator == null or not is_instance_valid(_quarter_indicator)):
		_build_quarter_indicator()
	if _quarter_indicator != null and is_instance_valid(_quarter_indicator):
		_quarter_indicator.visible = v
		if _quarter_indicator_vp != null and is_instance_valid(_quarter_indicator_vp):
			_quarter_indicator_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if v else SubViewport.UPDATE_DISABLED
		if v:
			_refresh_quarter_indicator()


## Плашка-индикатор = 2D-панель (StyleBox чёрный α + строки осей с emoji-иконками) в SubViewport,
## показанная на Sprite3D-билборде над шахтой. Строки-значения хранятся в _ind_* для _refresh.
func _build_quarter_indicator() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(470, 196)  # широкая — влезает самая длинная строка (номинал + подсказка)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	_quarter_indicator_vp = vp
	# Плашка: PanelContainer на весь вьюпорт, чёрный полупрозрачный StyleBox со скруглением.
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.62)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(14)
	panel.add_theme_stylebox_override(&"panel", sb)
	vp.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override(&"separation", 4)
	panel.add_child(vb)
	_ind_title = Label.new()
	_ind_title.add_theme_font_size_override(&"font_size", 26)
	_ind_title.add_theme_color_override(&"font_color", Color(0.85, 0.9, 1.0))
	vb.add_child(_ind_title)
	_ind_rows = []
	for _i in range(6):  # уровень + оси шахты + защёлк (6) и гарнизон казармы (≤2, лишние прячем)
		_ind_rows.append(_make_indicator_row(vb))
	# Sprite3D-билборд с текстурой вьюпорта над шахтой.
	_quarter_indicator = Sprite3D.new()
	_quarter_indicator.texture = vp.get_texture()
	_quarter_indicator.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_quarter_indicator.no_depth_test = true
	_quarter_indicator.shaded = false
	_quarter_indicator.pixel_size = 0.005  # 470×0.005 ≈ 2.35 м ширина плашки над шахтой
	_quarter_indicator.position = Vector3(0, 3.6, 0)
	add_child(_quarter_indicator)


## Строка индикатора (Label, 24pt, белая) в VBox — возвращает её для наполнения в _refresh.
func _make_indicator_row(vb: VBoxContainer) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override(&"font_size", 24)
	l.add_theme_color_override(&"font_color", Color.WHITE)
	vb.add_child(l)
	return l


## Наполнить плашку под роль продюсера: шахта → оси добычи, казарма → гарнизон/кап.
func _refresh_quarter_indicator() -> void:
	if _ind_title == null or not is_instance_valid(_ind_title):
		return
	if _role == &"barracks":
		_refresh_barracks_indicator()
	elif _role == &"magic":
		_refresh_magic_indicator()
	else:
		_refresh_mine_indicator()


## Строки плашки ИНСТИТУТА МАГИИ: оси-сапорты (×темп) + дом + итоговая мана/сек. Состояния как у шахты:
## ×N работает / ⏸ нет гнома (построено, смены нет) / — не построено; сам институт без гнома → простой.
func _refresh_magic_indicator() -> void:
	_ind_title.text = "ИНСТИТУТ МАГИИ"
	var st := _quarter_status()
	var roles: Dictionary = st["roles"]            # построено в зоне
	var on: Dictionary = st["staffed_roles"]       # реально работает (есть гном; дом — без гнома)
	var crystal_val: String = "×%s" % MANA_MULT_CRYSTAL if on.has(&"mana_crystal") else ("⏸ нет гнома" if roles.has(&"mana_crystal") else "—  (кафедра свитков)")
	var rune_val: String = "×%s" % MANA_MULT_RUNE if on.has(&"mana_rune") else ("⏸ нет гнома" if roles.has(&"mana_rune") else "—  (осколок зв. руды)")
	var house_val: String = "×%s" % MANA_MULT_HOUSE if on.has(&"housing") else "—  (дом гномов)"
	var staffed: bool = Population == null or Population.is_staffed(self)
	# _mana_mult уже включает «защёлк» полного квартала.
	var quarter_on: bool = _full_quarter_mult(st) > 1.0
	var quarter_val: String = "×%s  СОБРАН!" % FULL_QUARTER_BONUS if quarter_on else "—  (заполни все грани)"
	var rate: float = MANA_INSTITUTE_RATE * _mana_mult(st)
	var last: String = "✨ %s маны/сек" % String.num(rate, 1)
	if not staffed:
		last = "🚨 ТРЕВОГА — простой" if (Population != null and Population.alarm_active) else "⏸ Нет населения — простой"
	_apply_indicator_rows([
		"📜 Кафедра    %s" % crystal_val,
		"🌟 Осколок    %s" % rune_val,
		"🏠 Дом          %s" % house_val,
		"⚡ Квартал     %s" % quarter_val,
		last,
	])
	if _ind_rows.size() >= 5 and is_instance_valid(_ind_rows[4]):
		var col: Color = Color(1.0, 0.5, 0.4) if not staffed else Color(0.7, 0.7, 1.0)
		(_ind_rows[4] as Label).add_theme_color_override(&"font_color", col)


## Строки плашки ШАХТЫ: каждая ось — значение или «—  (что построить)»; внизу итоговая добыча.
func _refresh_mine_indicator() -> void:
	_ind_title.text = "КВАРТАЛ ШАХТЫ"
	var st := _quarter_status()
	var roles: Dictionary = st["roles"]            # построено в зоне
	var on: Dictionary = st["staffed_roles"]       # реально работает (есть гном-смена)
	var speed_on: bool = on.has(&"smelter")
	var vol_on: bool = on.has(&"housing")
	var mint_on: bool = on.has(&"mint")
	var base_coin: int = _vein.coin_type() if (_vein != null and is_instance_valid(_vein)) else ResourcePile.ResourceType.BRONZE
	var coin: int = _upgraded_coin(base_coin) if mint_on else base_coin
	var rate: float = MINE_RATE * (MINE_SPEED_MULT if speed_on else 1.0) * float(MINE_VOLUME_MULT if vol_on else 1)
	# Каждая ось: ×значение (работает) / ⏸ нет гнома (построено, но без смены) / — (не построено).
	var speed_val: String = "×%s" % MINE_SPEED_MULT if speed_on else ("⏸ нет гнома" if roles.has(&"smelter") else "—  (плавильня)")
	var mint_val: String
	if mint_on:
		mint_val = "%s %s" % [_coin_emoji(coin), _coin_name(coin)]
	elif roles.has(&"mint"):
		mint_val = "%s %s  (⏸ нет гнома)" % [_coin_emoji(coin), _coin_name(coin)]
	else:
		mint_val = "%s %s  (двор +тир)" % [_coin_emoji(coin), _coin_name(coin)]
	# «Защёлк»: полный квартал крутит темп сверх осей (учтён в rate ниже).
	var quarter_mult: float = _full_quarter_mult(st)
	rate *= quarter_mult
	var quarter_val: String = "×%s  СОБРАН!" % FULL_QUARTER_BONUS if quarter_mult > 1.0 else "—  (заполни все грани)"
	# Укомплектована ли САМА шахта: без слота простаивает (Population, военный приоритет).
	var staffed: bool = Population == null or Population.is_staffed(self)
	var last_row: String = "≈ %s %s/сек" % [String.num(rate, 1), _coin_emoji(coin)]
	if not staffed:
		last_row = "🚨 ТРЕВОГА — простой" if (Population != null and Population.alarm_active) else "⏸ Нет населения — простой"
	# Стопка на крыше: сколько лежит несобранного (Clash-сбор).
	var stack_row: String = "💰 Стопка      %d🥉 из %d  (подъедь/кликни)" % [_stack_bronze, MINE_STACK_CAP_BRONZE] \
		if _stack_bronze > 0 else "💰 Стопка      —  (копится)"
	_apply_indicator_rows([
		"🔥 Скорость   %s" % speed_val,
		"🪙 Номинал    %s" % mint_val,
		"🏠 Объём       %s" % ("×%d" % MINE_VOLUME_MULT if vol_on else "—  (дом гномов)"),
		"⚡ Квартал     %s" % quarter_val,
		stack_row,
		last_row,
	])
	if _ind_rows.size() >= 6 and is_instance_valid(_ind_rows[5]):
		var col: Color = Color(1.0, 0.5, 0.4) if not staffed else Color(1.0, 0.9, 0.4)
		(_ind_rows[5] as Label).add_theme_color_override(&"font_color", col)


## Строки плашки КАЗАРМЫ: «Гарнизон живых/кап» + разбивка оси гарнизона (база+бараки) + снабжение пула.
func _refresh_barracks_indicator() -> void:
	_ind_title.text = "КАЗАРМА"
	var stype: StringName = RoomBuildings.get_data(building_id).get("squad_type", DEFAULT_SQUAD_TYPE)
	var base: int = int(SoldierSystem.get_squad_cap(stype)) if SoldierSystem != null else 0
	var bonus: int = hire_cap_bonus()
	var living: int = _my_squad_count()
	var cap: int = _my_hire_cap()
	var pop_room: int = int(Population.military_room()) if Population != null else 0
	_apply_indicator_rows([
		"🛡 Гарнизон   %d / %d" % [living, cap],
		"⛺ Кап: %d база + %d барак(и)" % [base, bonus],
		"👥 Снабжение своб:  %d" % pop_room,
	])


## Записать тексты в строки плашки (по индексу), лишние строки спрятать. Цвет — белый (шахта
## потом перекрашивает строку добычи в жёлтый).
func _apply_indicator_rows(texts: Array) -> void:
	for i in range(_ind_rows.size()):
		var l := _ind_rows[i] as Label
		if l == null or not is_instance_valid(l):
			continue
		if i < texts.size():
			l.visible = true
			l.text = String(texts[i])
			l.add_theme_color_override(&"font_color", Color.WHITE)
		else:
			l.visible = false


## Мировые клетки, занятые постройкой (для проверки наложения при размещении).
func occupied_cells() -> Array:
	return CityGrid.building_cells(global_position, _mask, rotation.y, get_tree())


# --- Категории зданий + сочетаемость (единая таксономия для превью и квартала-баффа) ---

## Роль-ФИЛЛЕР квартала (сапорт любого продюсера): плавильня/двор/дом — шахте; барак — казарме.
## Номинальный эффект роли на НАСЕЛЕНИЕ для подписи в палитре (иконка 👥±N): ДОМ даёт слоты (+),
## PRODUCTION БЕРЁТ гнома на смену (−). Барак — 0 (он ёмкость, не население, см. garrison_for_role).
static func pop_for_role(role: StringName) -> int:
	match role:
		&"housing":
			return HOUSING_POP
		&"mine":
			return -MINE_POP_DEMAND
		&"smelter", &"mint", &"magic", &"mana_crystal", &"mana_rune":
			return -1  # магия берёт гнома (как добыча) → 👥 -1 на карточке
		_:
			return 0


## Прибавка к ВМЕСТИМОСТИ казармы для подписи карточки (иконка 🛡+N): барак. Прочее — 0.
static func garrison_for_role(role: StringName) -> int:
	return HIRE_CAP_PER_BARRACK if role == &"barrack" else 0


## Категория роли: PRODUCTION (шахта/плавильня/двор), DEFENSE (стены/ворота/казармы),
## STATE (замок/банк), SOCIAL (дом гномов — универсал), NONE (прочее). Здания «сочетаются»
## (часть одного квартала) ⇔ одна категория ИЛИ одно из них SOCIAL.
enum Category { NONE, PRODUCTION, DEFENSE, STATE, SOCIAL, MAGIC }

static func category(role: StringName) -> int:
	match role:
		&"mine", &"smelter", &"mint":
			return Category.PRODUCTION
		&"defend", &"gate", &"attack", &"barracks", &"barrack", &"stakes":
			return Category.DEFENSE  # барак — ёмкость казармы; колья — заслон (оба военные)
		&"bank", &"pump", &"unload":
			return Category.STATE
		&"housing":
			return Category.SOCIAL
		&"magic", &"mana_crystal", &"mana_rune":
			return Category.MAGIC  # институт магии + его сапорты (квартал маны)
		_:
			return Category.NONE


## Сочетаются ли две роли (часть одного квартала): одна категория, либо одно SOCIAL (универсал).
static func connects(role_a: StringName, role_b: StringName) -> bool:
	var ca := category(role_a)
	var cb := category(role_b)
	if ca == Category.NONE or cb == Category.NONE:
		return false
	return ca == cb or ca == Category.SOCIAL or cb == Category.SOCIAL


## Превью-подсветка стыковки соседа при наведении силуэта: 0=off, 1=соединится (зелёный),
## 2=касается, но не соединится (красный). Отдельный полупрозрачный ОВЕРЛЕЙ по футпринту —
## НЕ трогаем материалы здания (иначе сброс убил бы собственное свечение плавильни/двора/
## банка). Гард по смене состояния — не пере-создаём оверлей каждый кадр.
var _conn_overlay: Node3D = null
var _conn_state: int = 0

func set_connection_hint(state: int) -> void:
	if state == _conn_state:
		return
	_conn_state = state
	if _conn_overlay != null and is_instance_valid(_conn_overlay):
		_conn_overlay.queue_free()
	_conn_overlay = null
	if state == 0:
		return
	var col := Color(0.3, 1.0, 0.4, 0.4) if state == 1 else Color(1.0, 0.35, 0.3, 0.4)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_conn_overlay = Node3D.new()
	add_child(_conn_overlay)
	var s: float = CityGrid.CELL
	for off in _mask:
		var o := off as Vector2i
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(s * 0.9, 2.8, s * 0.9)
		mi.mesh = bm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(o.x * s, 1.4, o.y * s)
		_conn_overlay.add_child(mi)


func _solid(c: Color, metallic: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metallic
	m.roughness = rough
	return m


func _box(size: Vector3, pos: Vector3, mat: StandardMaterial3D, shadow: bool) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Горизонтальный СЛОЙ по всем клеткам фигуры (цоколь / карниз): на каждую клетку плита
## стороной side, высотой h, центром по Y = y. Плиты смыкаются в единый поясок здания.
func _layer(y: float, side: float, h: float, mat: StandardMaterial3D) -> void:
	var s: float = CityGrid.CELL
	for off in _mask:
		var o := off as Vector2i
		_box(Vector3(side, h, side), Vector3(o.x * s, y, o.y * s), mat, true)


## Зубцы (мерлоны) по периметру верха башни — как у угловых башен качалки.
func _battlements(half: float, top_y: float, mat: StandardMaterial3D) -> void:
	var n := 3
	var mw := 0.34
	var mh := 0.45
	var step := (half * 2.0) / float(n)
	for i in n:
		var o: float = -half + step * (float(i) + 0.5)
		var y: float = top_y + mh * 0.5
		_box(Vector3(mw, mh, mw), Vector3(o, y, half), mat, true)
		_box(Vector3(mw, mh, mw), Vector3(o, y, -half), mat, true)
		_box(Vector3(mw, mh, mw), Vector3(half, y, o), mat, true)
		_box(Vector3(mw, mh, mw), Vector3(-half, y, o), mat, true)


func _role_color(r: StringName) -> Color:
	match r:
		&"attack":
			return Color(0.82, 0.4, 0.34)   # атака — красноватый
		&"mine":
			return Color(0.88, 0.68, 0.26)  # добыча — охра
		&"magic":
			return Color(0.42, 0.44, 0.6)   # институт — синевато-серый камень мага
		&"stakes":
			return _WOOD                    # колья — дерево (шаттер коричневый)
	return Color(0.5, 0.58, 0.72)           # защита — серо-синий
