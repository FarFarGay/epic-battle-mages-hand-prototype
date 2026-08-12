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
## Состав приезжает из подземелья (MatchConfig) — вместе с КНОПКАМИ, на которые
## игрок их поставил, и со всей добычей забега (монеты, карточки, свитки,
## чертежи), см. _consume_haul. Прямой запуск мира без данжа — дефолтный отряд
## из инспектора, чтобы сцена не открывалась пустой.

const CREW_WIDGET_SCENE: PackedScene = preload("res://scenes/crew_widget.tscn")
## ⭐ ТЕ ЖЕ КАРТОЧКИ, ЧТО В ДАНЖЕ (scenes/squad_cards.tscn). Не «такие же» —
## ТЕ ЖЕ: один узел, одна разметка, один код. Свои рисовать нельзя.
const SQUAD_CARDS_SCENE: PackedScene = preload("res://scenes/squad_cards.tscn")
## Горящая земля карточки «Выжженная земля» — ШТАТНЫЙ пятак, тот же, что у
## фаербола и залпа огневиков (MageVolley.BURN_PATCH_SCENE). Своего огня у
## копейщиков нет и заводить его нельзя.
const BURN_PATCH_SCENE: PackedScene = preload("res://scenes/burn_patch.tscn")

## Стартуем с гномами ВНУТРИ: они приехали из подземелья в башне (DESIGN §2.2).
@export var start_crewed: bool = true
## Дистанция посадки по E — та же логика, что в ангаре интро.
@export var board_distance: float = 8.0
## Радиус кольца высадки вокруг корпуса. Корпус башни — коробка 2×2 в основании,
## так что 5 м гарантированно выносит гномов из-под неё, а не на крышу.
@export var disembark_radius: float = 5.0

@export_group("Состав по умолчанию")
## Отряд для ПРЯМОГО запуска мира (из данжа никто не приехал). Числа — РАЗМЕРЫ
## ГРУПП из подземелья (DungeonSandbox.GROUP_SIZES): лучники 3, копейщики 2,
## артель 2, огневики 2. Классы едут из данжа ВСЕ ЧЕТЫРЕ и работают в мире так
## же, как там, поэтому и дефолт держит все четыре — иначе прямой запуск мира
## показывал бы обрезанный отряд, которого в игре не бывает.
@export var default_archers: int = 3
@export var default_pikemen: int = 2
@export var default_workers: int = 2
@export var default_fire_mages: int = 2
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
## Каменный вал артели (ПКМ) — те же данжевые числа, что в StoneWave. Ручки
## продублированы здесь, чтобы баланс мира можно было крутить из инспектора, но
## СЧИТАЕТ вал общий узел: своей копии физики гребня у мира нет.
@export var wave_cooldown: float = 14.0
@export var wave_speed: float = 13.0
@export var wave_range: float = 20.0
@export var wave_half_width: float = 1.9
@export var wave_damage_per_gnome: float = 45.0
@export var wave_knockback: float = 14.0
## Отдача запуска: пинок точки строя ПРОТИВ хода вала (м/с). Работает через
## инерцию handling; 0 = выкл.
@export var wave_recoil: float = 7.0
@export var wave_hitstop: float = 0.06
@export var wave_travel_shake: float = 1.2
## Залп огневиков (та же ПКМ) — числа из данжа, считает общий узел MageVolley.
@export var volley_cooldown: float = 5.0
@export var volley_direct_damage: float = 30.0
@export var volley_direct_radius: float = 1.0
@export var volley_aoe_damage: float = 10.0
@export var volley_aoe_radius: float = 2.6
@export var volley_burn_damage_per_tick: float = 4.0
@export var volley_burn_tick_interval: float = 0.5
@export var volley_burn_duration: float = 3.0
@export_group("")

## ⭐ КАРТОЧКИ-НАХОДКИ ЗАБЕГА (id → сколько раз взята). Приезжают из подземелья
## тем же каналом, что и тела, и работают наверху ПО ТЕМ ЖЕ ФОРМУЛАМ (решение
## юзера 2026-08-11: «карточка = выучка отряда»). Носитель класса — единственный,
## кто их держит: погиб последний артельщик — «Эхо в камне» ушло с ним, потому
## что каждый эффект гейтится живыми носителями своего глагола.
var _haul_cards: Dictionary = {}
## Сборка экипажа С УЧЁТОМ карточек лучников. Держим полем, а не считаем на
## месте: цифры нужны и рождению гнома, и прицелу (_archer_range), и разводке
## очереди (_stagger_archers) — три копии формулы разъехались бы на первой же
## правке. Заполняется до спавна, в _consume_haul.
var _cfg: Dictionary = CrewKit.default_cfg()
var _squad: Squad = null
var _tower: Node3D = null
var _rig: Node = null
var _widget: CanvasLayer = null
## Ряд карточек классов — общий узел с данжем (SquadCards).
var _cards: Control = null
## Стартовый состав по классам: знаменатель «живых из скольких» на карточках.
var _start_counts: Dictionary = {}
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
var _rmb_down: bool = false
var _super_cd: float = 0.0
## Каменный вал артели и залп огневиков (оба на ПКМ) — ОБЩИЕ узлы с
## подземельем, не копии.
var _wave: StoneWave = null
var _volley: MageVolley = null


func _ready() -> void:
	_focus = Node3D.new()
	_focus.name = "SquadFocus"
	add_child(_focus)
	_widget = CREW_WIDGET_SCENE.instantiate() as CanvasLayer
	add_child(_widget)
	# Ряд карточек кладём в тот же CanvasLayer виджета: Control'у нужен слой, а
	# заводить второй ради одного узла незачем. Разметка (низ по центру) —
	# из самой сцены карточек, здесь её не переопределяем.
	_cards = SQUAD_CARDS_SCENE.instantiate() as Control
	_widget.add_child(_cards)
	_widget.connect(&"leave_requested", _on_leave_pressed)
	_widget.connect(&"board_requested", _on_board_pressed)
	_widget.connect(&"rebuild_requested", _on_rebuild_pressed)
	# Пересборка состава живёт пока только в подземелье (там для неё есть
	# комната-предбанник). Гасим кнопку честно, а не делаем вид, что работает.
	_widget.call(&"set_rebuild_enabled", false)
	_setup_squad_abilities()
	call_deferred(&"_late_setup")


## ⭐ ВАЛ И ЗАЛП — ТЕ ЖЕ УЗЛЫ, ЧТО В ДАНЖЕ (stone_wave.gd / mage_volley.gd). Не
## «такие же»: гребень, эхо, фаерболы и урон считает один код на оба эпизода.
## Здесь только числа из инспектора и то, чем мир отличается — рокот уходит в
## риг камеры, а топить в мире нечего (лёд — химия ледника, не общая).
func _setup_squad_abilities() -> void:
	_wave = StoneWave.new()
	_wave.name = "StoneWave"
	add_child(_wave)
	_wave.cooldown = wave_cooldown
	_wave.speed = wave_speed
	_wave.travel_range = wave_range
	_wave.half_width = wave_half_width
	_wave.damage_per_gnome = wave_damage_per_gnome
	_wave.knockback = wave_knockback
	_wave.recoil = wave_recoil
	_wave.hitstop = wave_hitstop
	_wave.travel_shake = wave_travel_shake
	# Карточки хижины («Эхо», «Обвал», уширение) проставляются НА ЗАПУСКЕ вала
	# (_stone_wave): на этом кадре добыча забега ещё не разобрана.
	_wave.center_provider = func() -> Vector3:
		return _squad.compute_center() if _squad != null else Vector3.INF
	_wave.crew_provider = func() -> int:
		return _alive_artel()
	_wave.rumble.connect(_on_wave_rumble)
	_volley = MageVolley.new()
	_volley.name = "MageVolley"
	add_child(_volley)
	_volley.cooldown = volley_cooldown
	_volley.direct_damage = volley_direct_damage
	_volley.direct_radius = volley_direct_radius
	_volley.aoe_damage = volley_aoe_damage
	_volley.aoe_radius = volley_aoe_radius
	_volley.burn_damage_per_tick = volley_burn_damage_per_tick
	_volley.burn_tick_interval = volley_burn_tick_interval
	_volley.burn_duration = volley_burn_duration


## Рокот катящегося вала: у мира травмой камеры заведует риг, и у длящегося
## события свой потолок — иначе дрожь полёта забила бы разовые удары.
func _on_wave_rumble(amount: float, at: Vector3) -> void:
	if _rig != null and is_instance_valid(_rig) and _rig.has_method(&"add_rumble"):
		_rig.call(&"add_rumble", amount, at, 0.6)


## Отложенно: башня и риг могут ready'иться позже нас (порядок детей).
func _late_setup() -> void:
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	_tower = get_tree().get_first_node_in_group(Tower.GROUP) as Node3D
	_rig = get_tree().get_first_node_in_group(CameraRig.CAMERA_RIG_GROUP)
	_hand = _find_hand()
	# ⚠ ДОБЫЧА РАЗБИРАЕТСЯ ДО СПАВНА. Карточки лучников уходят в статы при
	# РОЖДЕНИИ (CrewKit кладёт дальность и темп в stats один раз), так что
	# порядок тут не косметический: разбери haul после — и привезённый
	# «Барабанный темп» не подействовал бы до конца заезда.
	_consume_haul()
	_spawn_crew()
	_set_crewed(start_crewed)


## ⭐ ПРИЁМ ДОБЫЧИ ЗАБЕГА (2026-08-11). Раньше из данжа выезжали только тела, и
## всё, что игрок собрал руками, умирало вместе со сценой. Теперь одним куском:
## монеты — в казну, карточки — в отряд на этот заезд, свитки и чертежи — в
## профиль насовсем.
##
## Зовём РОВНО ОДИН РАЗ за загрузку сцены: consume_haul чистит источник, и
## второй вызов молча вернул бы нули (а не удвоил бы добычу).
func _consume_haul() -> void:
	var haul: Dictionary = MatchConfig.consume_haul()
	_haul_cards = (haul.get("cards", {}) as Dictionary).duplicate()
	_apply_archer_cards()
	_bank_haul_coins(int(haul.get("coins", 0)))
	_bank_haul_xp(int(haul.get("xp", 0)))
	_store_permanent_haul(haul.get("scrolls", []) as Array,
			haul.get("blueprints", []) as Array)


## Карточки лучников — в сборку экипажа. Формулы ДОСЛОВНО данжевые
## (DungeonSandbox: темп ×0.8ⁿ, дальность +4 м за карту): у одного и того же
## отряда в двух эпизодах не может быть двух разных прибавок.
func _apply_archer_cards() -> void:
	_cfg = CrewKit.default_cfg()
	var rate: float = pow(0.8, float(_card(&"arch_rate")))
	_cfg["archer_range"] = float(_cfg["archer_range"]) + 4.0 * float(_card(&"arch_range"))
	_cfg["archer_cd_min"] = float(_cfg["archer_cd_min"]) * rate
	_cfg["archer_cd_max"] = float(_cfg["archer_cd_max"]) * rate


## Сколько раз взята карточка (0 = нет). Единственная точка чтения — как в
## данже: места применения спрашивают ЗДЕСЬ, а не хранят копии множителей.
func _card(id: StringName) -> int:
	return int(_haul_cards.get(id, 0))


## Монеты забега — в казну. Монета данжа = 1 бронза (единая валюта), поэтому
## идём ТЕМ ЖЕ путём, что продажа бревна у башни (SoldierGnome, WOOD_SALE_BRONZE):
## GoldBank в группе + add_coin. Прямой CampEconomy.add_resource — другая, лагерная
## ветка учёта, и деньги по ней в одометр казны не попадают.
func _bank_haul_coins(coins: int) -> void:
	if coins <= 0:
		return
	var bank := get_tree().get_first_node_in_group(GoldBank.GROUP)
	if bank == null or not bank.has_method(&"add_coin"):
		return
	bank.call(&"add_coin", ResourcePile.ResourceType.BRONZE, coins)
	EventBus.tutorial_hint.emit("Из подземелья привезли %d🥉 — в казну" % coins, 4.0)


## Опыт, не потраченный в хижинах, — в ЕДИНЫЙ котёл башни и гномов (профиль,
## user://tower_profile.cfg). Копится между заездами: на него пойдут улучшения
## базы и крупные улучшения гномов, открывающие новые типы для тренировки.
##
## ⚠ Тратить пока НЕЧЕМ — мета-магазина нет. Показываем цифру подсказкой, чтобы
## накопление было ВИДНЫМ: молча растущее число в сейве игрок не считает
## наградой, а забег обязан читаться как вклад во что-то.
func _bank_haul_xp(amount: int) -> void:
	if amount <= 0:
		return
	var prof := get_tree().get_first_node_in_group(&"player_profile")
	if prof == null or not prof.has_method(&"add_xp"):
		return
	prof.call(&"add_xp", amount)
	EventBus.tutorial_hint.emit("Опыт отряда: +%d (всего %d)"
			% [amount, int(prof.get(&"xp"))], 4.0)


## Свитки и чертежи — в профиль НАСОВСЕМ (user://tower_profile.cfg). Пишет сам
## PlayerProfile: он же сохраняет на диск и он же рассказывает игроку, что
## выучено — своей подсказки здесь не надо, иначе о находке скажут дважды.
## Профиля нет (дев-запуск сцены без него) — молча пропускаем: терять добычу
## обидно, но падать на старте мира хуже.
func _store_permanent_haul(scrolls: Array, blueprints: Array) -> void:
	if scrolls.is_empty() and blueprints.is_empty():
		return
	var prof := get_tree().get_first_node_in_group(&"player_profile")
	if prof == null:
		return
	for s in scrolls:
		prof.call(&"learn_scroll", StringName(String(s)))
	for b in blueprints:
		prof.call(&"grant_blueprint", StringName(String(b)))


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
	var roster: Array[Dictionary] = _roster()
	# Полный состав на старте — знаменатель карточек («Живых: 2 / 3»). Потери
	# должны быть ВИДНЫ, а для этого надо помнить, сколько было.
	_start_counts.clear()
	var classes: Array[StringName] = []
	for entry in roster:
		var id: StringName = entry["cls"]
		_start_counts[id] = int(_start_counts.get(id, 0)) + 1
		classes.append(id)
	for i in range(roster.size()):
		var ang: float = TAU * float(i) / float(maxi(roster.size(), 1))
		var pos: Vector3 = _on_ground(at.x + cos(ang) * disembark_radius,
				at.z + sin(ang) * disembark_radius)
		var g := CrewKit.create_soldier(self, roster[i]["cls"], pos, _cfg, _focus)
		if g == null:
			continue
		# ⭐ КНОПКА ПРИЕХАЛА ВМЕСТЕ С ГНОМОМ. CrewKit ставит слот по ДЕФОЛТНОЙ
		# раскладке класса — для собранного в данже отряда это враньё: игрок мог
		# посадить лучников на ПКМ, и молча вернуть их на ЛКМ значит потерять его
		# расклад на выходе. Перебиваем сразу после рождения.
		g.bind_slot = int(roster[i]["bind"])
		# Карточка «Щитобой» — поверх готового тела: множитель стрелы живёт у
		# самого лучника (стрела читает его через shooter_ref), в cfg сборки его нет.
		if g is ArcherSoldier:
			(g as ArcherSoldier).shield_damage_mult = 1.0 + 2.0 * float(_card(&"arch_shieldbreak"))
		# Гном мира — ВСЕГДА экипаж: рабочей логики лагеря (дерево, смены,
		# патрули) у него нет и включаться она не должна ни на кадр.
		g.set_crew_mode(true)
		_squad.add_member(g)
	_squad.command_hold(Vector3(at.x, 0.0, at.z), false)
	print("[Crew] экипаж: %d — %s" % [roster.size(), str(classes)])


## Кто именно приехал: по элементу {"cls", "bind"} на гнома. Класс едет вместе с
## гномом и НЕ меняется (решение юзера): привёл лучников — у тебя лучники;
## кнопка едет с ним же (MatchConfig.next_squad). Пусто → дефолт из инспектора,
## и там слот берётся штатной раскладкой класса — расклада-то ещё не было.
func _roster() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in MatchConfig.consume_squad():
		if not (e is Dictionary):
			continue
		var cls := StringName((e as Dictionary).get("cls", &""))
		# Класса нет в каталоге — гнома пропускаем: CrewKit на нём всё равно
		# упрётся в отсутствующую сцену, а отряд поедет дальше.
		if SoldierSystem == null or not SoldierSystem.has_soldier(cls):
			continue
		out.append({
			"cls": cls,
			"bind": int((e as Dictionary).get("bind", CrewKit.default_bind_for(cls))),
		})
	if not out.is_empty():
		return out
	var mix: Array[Dictionary] = []
	for i in range(default_pikemen):
		mix.append(_default_entry(&"pikeman"))
	for i in range(default_archers):
		mix.append(_default_entry(CrewKit.ARCHER))
	for i in range(default_workers):
		mix.append(_default_entry(&"worker"))
	for i in range(default_fire_mages):
		mix.append(_default_entry(&"fire_mage"))
	return mix


func _default_entry(cls: StringName) -> Dictionary:
	return {"cls": cls, "bind": CrewKit.default_bind_for(cls)}


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
	#
	# ⚠ ГАСИМ ПОДДЕРЕВО, А НЕ УЗЕЛ. set_process(false) на Hand усыпляет ТОЛЬКО
	# сам Hand, а кнопки опрашивает не он: HandPhysical (ЛКМ хватает / ПКМ слэм)
	# и HandSpell (ПКМ каст) — его ДЕТИ, у каждого свой _process, и он продолжал
	# крутиться. Снаружи это значило два хозяина у одной кнопки: ПКМ разом катит
	# вал артели и кастует заклинание башни. process_mode = DISABLED
	# распространяется вниз по дереву — это и есть «рука спит» целиком.
	if _hand != null and is_instance_valid(_hand):
		(_hand as Node).process_mode = Node.PROCESS_MODE_INHERIT if on \
				else Node.PROCESS_MODE_DISABLED
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
	EventBus.tutorial_hint.emit(
			"Экипаж снаружи. WASD — ход · ЛКМ — полив · ПРОБЕЛ — удар · ПКМ — вал · [E] у башни — вернуться",
			5.0)


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
	if _cards != null:
		(_cards as SquadCards).refresh(_card_data())
	# Откаты тикают и в кабине: запущенный перед посадкой камень обязан
	# докатиться, а не зависнуть в воздухе на полпути.
	if _wave != null:
		_wave.tick(delta)
	if _volley != null:
		_volley.tick(delta)
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
# ⭐ ПКМ ПЕРЕНЕСЁН ЦЕЛИКОМ 2026-08-11 — но не копией: физика гребня уехала в
# общий узел StoneWave, залп огневиков — в MageVolley, и оба эпизода вешают ОДНИ
# И ТЕ ЖЕ узлы. Набор команд экипажа в данже и снаружи теперь совпадает, а
# править способность по-прежнему надо в одном месте.


func _tick_commands(delta: float, c: Vector3, cursor: Vector3, aim_dir: Vector3) -> void:
	_super_cd = maxf(_super_cd - delta, 0.0)
	var lmb: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var space: bool = Input.is_key_pressed(KEY_SPACE)
	var rmb: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if rmb and not _rmb_down:
		_press_rmb(c, cursor)
	_rmb_down = rmb
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


## Данные для карточек — ровно тот же формат, что собирает данж. Отличается
## только источник цифр: там инспектор сцены, здесь стартовый состав.
##
## Все четыре класса работают в мире так же, как в данже, поэтому каждый обещает
## свою кнопку. Ветка «прочее» осталась на случай класса, который приедет из
## подземелья раньше, чем его глагол.
func _card_data() -> Dictionary:
	var counts := {}
	for m in _squad.members:
		if is_instance_valid(m):
			counts[m.soldier_type] = int(counts.get(m.soldier_type, 0)) + 1
	var data := {}
	for id in _start_counts:
		var alive: int = int(counts.get(id, 0))
		var armed: bool = false
		var line: String = ""
		if id == &"pikeman":
			armed = alive > 0 and _super_cd <= 0.0 and not _crewed
			line = "[ПРОБЕЛ] готов" if _super_cd <= 0.0 else "[ПРОБЕЛ] %.1fс" % _super_cd
		elif id == CrewKit.ARCHER:
			# У лучника нет отката, поэтому «горит» значит не «готов» (он готов
			# всегда), а «сейчас льёт». Вечно горящая рамка была бы шумом.
			armed = alive > 0 and _lmb_down and not _crewed
			line = "[ЛКМ] полив"
		elif id == &"worker":
			var wave_cd: float = _wave.cooldown_left() if _wave != null else 0.0
			armed = alive > 0 and wave_cd <= 0.0 and not _crewed
			line = "[ПКМ] готов" if wave_cd <= 0.0 else "[ПКМ] %.1fс" % wave_cd
		elif id == &"fire_mage":
			var fire_cd: float = _volley.cooldown_left() if _volley != null else 0.0
			armed = alive > 0 and fire_cd <= 0.0 and not _crewed
			line = "[ПКМ] готов" if fire_cd <= 0.0 else "[ПКМ] %.1fс" % fire_cd
		else:
			line = "только в подземелье"
		data[id] = {
			"alive": alive, "total": int(_start_counts[id]), "armed": armed,
			# В кабине кнопок отряда нет — строку способности гасим, а не врём ею.
			"line": line if not _crewed else " ",
		}
	return data


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


## Дальность полива — та же, что положил CrewKit при сборке лучника (значит, с
## карточкой «Дальний глаз»: иначе прицел обрезал бы выстрелы там, где стрелок
## уже достаёт).
func _archer_range() -> float:
	return float(_cfg.get("archer_range", 12.0))


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
	# Такт берём из СБОРКИ ЭТОГО отряда: «Барабанный темп» ускорил стрельбу —
	# должна сжаться и очередь, иначе фазы разъедутся с реальным откатом.
	var beat: float = (float(_cfg.get("archer_cd_min", 0.64))
			+ float(_cfg.get("archer_cd_max", 0.76))) * 0.5
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
	# ⚠ ЭКСПОРТ = БАЗА, КАРТОЧКА = НАДБАВКА. Числа инспектора не трогаем: они
	# балансная точка отсчёта, а находка забега живёт ровно один заезд.
	var radius: float = _super_radius()
	_super_cd = _super_cooldown()
	AoeVisual.spawn_expanding_ring(get_tree().current_scene, Vector3(c.x, 0.05, c.z),
			radius, 0.28, Color(1.0, 0.55, 0.2, 0.9))
	EventBus.camera_shake.emit(0.5, c)
	var r_sq: float = radius * radius
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
	# Карточка «Выжженная земля»: на месте удара остаётся горящее пятно (те же
	# 0.8 радиуса и 5 с, что в данже).
	if _card(&"pike_burn") > 0:
		_spawn_burn(c, radius * 0.8, 5.0)


## Радиус удара вокруг с карточкой «Шире размах» (+2 м за каждую).
func _super_radius() -> float:
	return super_radius + 2.0 * float(_card(&"pike_radius"))


## Откат удара с карточкой «Второе дыхание». Пол 1.5 с — данжевый, и он не про
## баланс, а про то, чтобы кнопка не выродилась в спам.
func _super_cooldown() -> float:
	return maxf(super_cooldown - 2.0 * float(_card(&"pike_cd")), 1.5)


## Горящее пятно штатным BurnPatch — тот же узел и те же параметры прожига, что
## у залпа огневиков. Маска бьёт по врагам обоих видов (обычные и мёрзлые).
func _spawn_burn(pos: Vector3, radius: float, duration: float) -> void:
	var bp := BURN_PATCH_SCENE.instantiate() as Node3D
	if bp == null:
		return
	add_child(bp)
	bp.global_position = Vector3(pos.x, 0.05, pos.z)
	if bp.has_method(&"setup"):
		bp.call(&"setup", radius, 7.0, 0.5, duration, Layers.ENEMIES | Layers.COLD_ENEMY)


## ПКМ: работает КТО НА КНОПКЕ — та же модель, что в данже (_press_bind). По
## умолчанию там артель (каменный вал) и огневики (залп); стоят оба класса —
## срабатывают оба, у каждого свой откат.
func _press_rmb(c: Vector3, cursor: Vector3) -> void:
	if c == Vector3.INF or cursor == Vector3.INF:
		return
	var artel: int = _alive_artel()
	var mages: Array = _bound_mages()
	if artel <= 0 and mages.is_empty():
		EventBus.tutorial_hint.emit("На ПКМ никого нет — нужна артель или огневики", 1.6)
		return
	if artel > 0:
		_stone_wave(c, cursor)
	if not mages.is_empty():
		_fire_volley(c, cursor, mages)


## Каменный вал по прицелу. Направление фиксируется на запуске, вал не
## подруливает — целиться надо заранее.
func _stone_wave(c: Vector3, cursor: Vector3) -> void:
	if _wave == null or not _wave.is_ready():
		return
	# Карточки артели читаются НА ЗАПУСКЕ, как в данже: узел вала общий, свои
	# копии множителей ни один эпизод не держит.
	_wave.wide_cards = _card(&"artel_wide")
	_wave.burst_cards = _card(&"artel_burst")
	_wave.echo_cards = _card(&"artel_echo")
	var dir := Vector3(cursor.x - c.x, 0.0, cursor.z - c.z)
	if not _wave.launch(c, dir):
		return
	EventBus.camera_shake.emit(0.5, c)
	# Отдача: строй отшатывается от собственного залпа (через инерцию _vel).
	_vel -= dir.normalized() * wave_recoil


## Залп огневиков в точку курсора. Топить в мире нечего (лёд — химия ледника),
## поэтому сигнал взрыва здесь никто не слушает: остаются урон и горящая земля.
func _fire_volley(c: Vector3, cursor: Vector3, mages: Array) -> void:
	if _volley == null or not _volley.fire(mages, cursor):
		return
	EventBus.camera_shake.emit(0.2, c)


## Живые артельщики НА КНОПКЕ ПКМ: вал катят только те, кто на неё назначен —
## как копейщики на ПРОБЕЛЕ. Урон вала считается от этого числа в момент удара.
func _alive_artel() -> int:
	var n: int = 0
	for m in _squad.members if _squad != null else []:
		if is_instance_valid(m) and m.soldier_type == &"worker" \
				and m.bind_slot == CrewKit.BIND_RMB:
			n += 1
	return n


## Живые огневики на кнопке ПКМ — по снаряду с каждого.
func _bound_mages() -> Array:
	var out: Array = []
	for m in _squad.members if _squad != null else []:
		if is_instance_valid(m) and m.soldier_type == &"fire_mage" \
				and m.bind_slot == CrewKit.BIND_RMB:
			out.append(m)
	return out


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
