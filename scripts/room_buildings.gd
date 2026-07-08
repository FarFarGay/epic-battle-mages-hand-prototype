class_name RoomBuildings
extends RefCounted
## Каталог построек КОМНАТНОГО режима (level_rooms). Единая простая модель:
## рука тащит силуэт → клик ставит на точку (драг = поворот), площадка-воркер-хаул
## строит здание за ресурс, который гномы доставляют. Отменяет грид/кольца/секторы
## из [CampBuildings]. См. [[project_ebm_building_rework]].
##
## ID-константы зданий. Spawn/размещение — generic: [HandPlaceAim] читает footprint
## для силуэта, [RoomBuildSite] читает resource/needed/scene для стройки. Мост через
## пропасть — гибрид (2026-07-07): ДОСКА строится как здание за дерево (BRIDGE_PLANK,
## нельзя ставить НА пропасти), готовую доску рука перекладывает поперёк ([bridge_plank.gd]).

const WALL := &"wall"
const BRIDGE_PLANK := &"bridge_plank"
const WATCHTOWER := &"watchtower"
const PUMP := &"pump"  # качалка-замок: центр грид-города, строят гномы, ОДНА на отряд
const OIL_DRILL := &"oil_drill"
const PIPE_STRAIGHT := &"pipe_straight"
const PIPE_CORNER := &"pipe_corner"
const PIPE_CROSS := &"pipe_cross"
# Полимино-постройки площадки вокруг качалки (Фаза 1, см. [PadBuilding], [CityGrid]).
const PAD_MINE := &"pad_mine"
const PAD_WALL := &"pad_wall"
const PAD_WALL1 := &"pad_wall1"
const PAD_TOWER := &"pad_tower"
const PAD_HOUSE := &"pad_house"   # население/гномы (роль housing)
const PAD_STORE := &"pad_store"   # хранилище/экономика (роль storage)
const PAD_GATE := &"pad_gate"     # ворота: арка со створками в линии стены (роль gate)
const PAD_STAKES := &"pad_stakes" # колья: дешёвый 1-кл. заслон перед стеной (роль stakes)
const PAD_BARRACKS := &"pad_barracks"  # угловая казарма лучников (роль barracks)
const PAD_SPEARMEN := &"pad_spearmen"  # казарма копейщиков, T-форма (роль barracks)
const PAD_BARRACK := &"pad_barrack"    # барак: ёмкость казармы (ось «Гарнизон», +кап), роль barrack
const PAD_SMELTER := &"pad_smelter"    # плавильня: гном несёт руду → монеты (роль smelter)
const PAD_LINE := &"pad_line"          # линия переработки: Z-тетромино, металл шахты→плавильня (роль line)
const PAD_MINT := &"pad_mint"          # чеканный двор: чеканит монеты из металла (роль mint)
const PAD_BANK := &"pad_bank"          # гномий банк: помпезная крепость, монеты идут в казну (роль bank)
const PAD_INSTITUTE := &"pad_institute" # институт магии: льёт ману в башню + открывает магию (роль magic)
const PAD_MANA_CRYSTAL := &"pad_mana_crystal" # сапорт института: ×темп маны (роль mana_crystal)
const PAD_MANA_RUNE := &"pad_mana_rune"       # сапорт института: ×темп маны сильнее (роль mana_rune)
const PAD_UNLOAD := &"pad_unload"             # разгрузочная платформа 2×2: паркуй башню → трюм в казну (роль unload)
const PAD_DOCK := &"pad_dock"                 # верфь башни: клик → окно срезов-слоёв башни (роль dock)
const PAD_FIRE_LAB := &"pad_fire_lab"         # кафедра огня: открывает fireball+firestorm (роль spell_lab)
const PAD_ENGINEER_LAB := &"pad_engineer_lab" # инженерная гильдия: harpoon+mine_scatter (роль spell_lab)
const PAD_FROST_LAB := &"pad_frost_lab"       # кафедра льда: frost (роль spell_lab)

const CATALOG: Dictionary = {
	# Мостки: доска за МОНЕТЫ (единая валюта; рубка рощи = заработок, брёвна
	# продаются казне на сдаче у башни — soldier_gnome.WOOD_SALE_BRONZE). Цена ≈ 8
	# сданных брёвен. Готовый предмет — обычная плашка ([bridge_plank.gd]): рука
	# кладёт её поперёк пропасти. На самой пропасти блюпринт не ставится
	# (forbid_on_chasm) — стройка не умеет «через дыру», рука умеет.
	BRIDGE_PLANK: {
		"name": "Мостки",
		"menu_label": "🌉 Мостки",
		"scene": "res://scenes/bridge_plank.tscn",
		"footprint": Vector3(11.0, 0.8, 4.6),
		"build_time": 6.0,
		"cost": {ResourcePile.ResourceType.BRONZE: 30},
		"forbid_on_chasm": true,
		"site_hp": 35.0,
		"hint": "Сколоченная доска: готовую хватай рукой и клади поперёк пропасти",
		"ghost_color": Color(0.55, 0.38, 0.2, 0.45),
	},
	# ⚠ ВНЕ МЕНЮ (легаси, 2026-07-04): свободная стена-силуэт заменена грид-стенами
	# PAD_WALL/PAD_WALL1. Запись оставлена как референс размещения через footprint
	# (единственный живой пользователь этого пути — PUMP). Дизайн-решение об удалении
	# за геймдизайнером.
	WALL: {
		"name": "Стена",
		"menu_label": "🧱 Стена",
		# Магнитится к соседним стенам (центр+края) — лабиринт. Башня не магнитится.
		"snap_target": true,
		# Построенное здание = готовый сегмент частокола (DRY: блокировка скелетов,
		# навмеш, разрушаемость, melee-only target уже в нём).
		"scene": "res://scenes/palisade_segment.tscn",
		# Габариты силуэта/футпринта (локальный X — длина вдоль поворота). Длиннее
		# нативного сегмента — стена тянется на несколько метров, строим лабиринт.
		"footprint": Vector3(5.0, 1.5, 0.3),
		# Нативная длина сцены по X (palisade_segment = 2м). RoomBuildSite тянет
		# построенную стену scale.x = footprint.x / native, чтобы совпасть с силуэтом.
		"native_scene_length": 2.0,
		# Прочность стройплощадки (скелеты могут сорвать стройку).
		"site_hp": 35.0,
		"ghost_color": Color(0.6, 0.8, 1.0, 0.4),
	},
	# ⚠ ВНЕ МЕНЮ (легаси): свободный пост-лучник; в грид-городе гарнизон дают казармы.
	WATCHTOWER: {
		"name": "Сторожевая башня",
		"menu_label": "🗼 Сторожевая башня",
		"scene": "res://scenes/archer_post.tscn",
		"footprint": Vector3(1.8, 3.0, 1.8),
		"site_hp": 50.0,
		"ghost_color": Color(0.7, 0.6, 1.0, 0.45),
	},
	# Качалка-замок — ЦЕНТР грид-города. Строят гномы (стройплощадка+хаул, НЕ instant).
	# Ставится свободно (грида ещё нет — она его и задаёт); достроенная = Castle,
	# якорь нефте-решётки ([CityGrid]). Гейт «одна на отряд» — в gameplay_hud.
	PUMP: {
		"name": "Качалка-замок",
		"menu_label": "🏰 Качалка-замок (центр)",
		"hint": "Сердце города башни: якорит кварталы и даёт кров. Потеряешь ночью — потеряешь город.",
		"scene": "res://scenes/oil_collector.tscn",
		"footprint": Vector3(4.6, 4.0, 4.6),  # ~ диаметр коллектора
		"site_hp": 80.0,
		"ghost_color": Color(0.92, 0.82, 0.45, 0.45),
	},
	# ⚠ ВНЕ МЕНЮ (легаси нефтесети): бур на месторождение + трубы к коллектору.
	# Пивот к грид-городу увёл их из палитры; жилы теперь кормят ШАХТЫ. Дизайн-решение
	# о возврате/удалении нефтесети — за геймдизайнером ([[project_ebm_oil_rig_questline]]).
	OIL_DRILL: {
		"name": "Бур",
		"menu_label": "⛏ Бур (на месторождение)",
		# Ставится НА месторождение (OilDeposit); на достройке цепляется к залежи и
		# добывает, трубу к коллектору тянешь отдельно (см. oil_rig.gd).
		"scene": "res://scenes/oil_rig.tscn",
		"footprint": Vector3(2.4, 2.6, 2.4),
		"site_hp": 55.0,
		"ghost_color": Color(0.9, 0.5, 0.2, 0.45),
	},
	# Секции трубопровода: ставятся как стены (силуэт+снап+поворот MMB), но МГНОВЕННО
	# (instant — без стройплощадки/рабочих, длинную трассу не хаулить). Связь сети
	# считает Castle заливкой по смежным секциям (группа oil_pipe).
	PIPE_STRAIGHT: {
		"name": "Труба прямая",
		"menu_label": "━ Труба прямая",
		"pipe_kind": 0,
		"scene": "res://scenes/pipe_straight.tscn",
		"footprint": Vector3(2.0, 0.5, 0.5),
		"instant": true,
		"ghost_color": Color(0.5, 0.7, 1.0, 0.5),
	},
	PIPE_CORNER: {
		"name": "Труба угол",
		"menu_label": "┗ Труба угол",
		"pipe_kind": 1,
		"scene": "res://scenes/pipe_corner.tscn",
		"footprint": Vector3(2.0, 0.5, 2.0),
		"instant": true,
		"ghost_color": Color(0.5, 0.7, 1.0, 0.5),
	},
	PIPE_CROSS: {
		"name": "Труба крест",
		"menu_label": "╋ Труба крест",
		"pipe_kind": 2,
		"scene": "res://scenes/pipe_cross.tscn",
		"footprint": Vector3(2.0, 0.5, 2.0),
		"instant": true,
		"ghost_color": Color(0.5, 0.7, 1.0, 0.5),
	},
	# Полимино-фигуры площадки (Фаза 1): ставятся мгновенно рукой, занимают клетки
	# маски `cells` (offset'ы от якоря-клетки), `role` = защита/атака/добыча. Силуэт +
	# поворот MMB, нельзя за площадку/внахлёст. Логику ролей добавим Фазой 2.
	# Шахта: ставится ТОЛЬКО на клетку жилы ([OilDeposit]); на жилу ничего, кроме шахты,
	# не ставится (гейт в HandPlaceAim._pad_valid). Добыча в монеты по тиру жилы — отд. шаг.
	PAD_MINE: {
		"name": "Шахта",
		"menu_label": "⛏ Шахта (на жилу)",
		"hint": "Ставь на жилу — кормит казну башни. Ядро квартала.",
		"role": &"mine",
		"cells": [Vector2i(0, 0)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 30},
		"ghost_color": Color(0.88, 0.68, 0.26, 0.5),
	},
	PAD_WALL: {
		"name": "Стенка-брус",
		"menu_label": "▮ Стенка ▮▮▮",
		"hint": "Преграда для скелетов, 3 клетки. Стройте лабиринт.",
		"role": &"defend",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 20},
		"ghost_color": Color(0.5, 0.58, 0.72, 0.5),
	},
	PAD_WALL1: {
		"name": "Стенка (клетка)",
		"menu_label": "▪ Стенка (1 клетка)",
		"hint": "Преграда, 1 клетка — затыкать щели в стене.",
		"role": &"defend",
		"cells": [Vector2i(0, 0)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 5},
		"ghost_color": Color(0.5, 0.58, 0.72, 0.5),
	},
	# ⚠ ВНЕ МЕНЮ: грид-версия сторожевой башни не продаётся (роль attack без логики).
	PAD_TOWER: {
		"name": "Сторожевая башня",
		"menu_label": "🗼 Сторожевая башня",
		"role": &"attack",
		"cells": [Vector2i(0, 0)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 60},
		"ghost_color": Color(0.55, 0.6, 0.62, 0.5),
	},
	# Дом гномов — СОЦИАЛЬНЫЙ сапорт-универсал (прямой, 3 клетки): даёт НАСЕЛЕНИЕ (PadBuilding.HOUSING_POP)
	# И входит в квартал шахты осью «Объём». Сочетается со всеми категориями.
	PAD_HOUSE: {
		"name": "Дом гномов",
		"menu_label": "🏠 Дом гномов (+4 населения)",
		"hint": "+4 гнома: руки для шахт и войск башни. В квартале шахты — ось «Объём» (×монет).",
		"role": &"housing",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 80},
		"ghost_color": Color(0.6, 0.45, 0.3, 0.5),
	},
	PAD_UNLOAD: {
		"name": "Док города",
		"menu_label": "⚓ Док города",
		"hint": "Причал башни: паркуйся — мана института течёт, корпус чинится.",
		"role": &"unload",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		"cost": {ResourcePile.ResourceType.BRONZE: 30},
		"ghost_color": Color(0.95, 0.8, 0.35, 0.4),
	},
	# Верфь башни: платформа 2×2 без коллизии (башня может заезжать на плиту).
	# ЛКМ-клик по плите → меню СРЕЗОВ (TowerUpgrades.SLICE_CATALOG): грузовой ярус /
	# арбалетные окна / броня — за монеты. Заезд-триггер пробовали — вернули клик.
	PAD_DOCK: {
		"name": "Верфь башни",
		"menu_label": "🛠 Верфь башни",
		"hint": "Мастерская башни: клик по плите — обвесы-срезы (арбалеты, броня).",
		"role": &"dock",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		"instant": true,
		"hp": 120,
		"cost": {ResourcePile.ResourceType.BRONZE: 100},
		"ghost_color": Color(0.85, 0.7, 0.4, 0.5),
	},
	# ⚠ ВНЕ МЕНЮ: склад 2×2 без функции (кап трюма теперь растит срез башни на верфи).
	PAD_STORE: {
		"name": "Склад",
		"menu_label": "📦 Склад (2×2)",
		"role": &"storage",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 90},
		"ghost_color": Color(0.55, 0.45, 0.3, 0.5),
	},
	# Ворота: арка со створками в линии стены (пилоны по ±X стыкуются со стенами, проём
	# по Z для прохода). Поворот MMB. Проходимость гномов — Фаза 2 (вместе с барьером стен).
	PAD_GATE: {
		"name": "Ворота",
		"menu_label": "🚪 Ворота (3)",
		"hint": "Проём в линии стены для прохода своих.",
		"role": &"gate",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 50},
		"ghost_color": Color(0.5, 0.58, 0.72, 0.5),
	},
	# Колья — дешёвый 1-клеточный ЗАСЛОН перед стеной: низкие деревянные колья-препятствие. Как стена
	# (DEFENSE, melee_only-щит → дальники целят дальше), но мало HP и дёшево — сакрифициальная первая
	# линия: melee-натиск ломает колья ПЕРЕД стеной, выигрываешь время. Ставится свободно (перед стеной).
	PAD_STAKES: {
		"name": "Колья",
		"menu_label": "🔻 Колья (заслон)",
		"hint": "Дешёвый заслон перед стеной: melee ломает колья первыми. Низкое HP.",
		"role": &"stakes",
		"cells": [Vector2i(0, 0)],
		"instant": true,
		"hp": 40,
		"cost": {ResourcePile.ResourceType.BRONZE: 10},
		"ghost_color": Color(0.6, 0.45, 0.28, 0.5),
	},
	# Угловая казарма лучников: L-бастион периметра (стены стыкуются к концам), боевой
	# ход с зубцами + стяг. Функция (плодит лучников / стрельба) — Фаза 2.
	PAD_BARRACKS: {
		"name": "Казарма лучников",
		"menu_label": "🏹 Казарма лучников (угол)",
		"hint": "Найм лучников за золото: гарнизонят стены, «В башню» — сажает на борт.",
		"role": &"barracks",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 100},
		"ghost_color": Color(0.5, 0.6, 0.7, 0.5),
		"banner_color": Color(0.28, 0.46, 0.7),  # синий стяг — лучники
		"corner_tower": true,  # башня венчает угол → лучники выходят на стены (гарнизон)
		# Казарма = кнопка найма за золото: клик → стол торга под этот тип отряда.
		# corner_tower → нанятые лучники гарнизонят стены; иначе мобильный отряд.
		"squad_type": &"archer_squad",
	},
	# Казарма копейщиков: T-тетромино (4 клетки), красный стяг. Найм мобильного отряда.
	PAD_SPEARMEN: {
		"name": "Казарма копейщиков",
		"menu_label": "🛡 Казарма копейщиков (стена)",
		"hint": "Отрезок стены: 3 копейщика на боевом ходу колют скелетов. Зов как лучников (F).",
		"role": &"barracks",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],  # ПРЯМАЯ как кусок стены
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 100},
		"ghost_color": Color(0.7, 0.55, 0.5, 0.5),
		"banner_color": Color(0.72, 0.3, 0.26),  # красный стяг — копейщики
		"squad_type": &"pikeman",
		"spear_garrison": true,  # гарнизон копейщиков на клетках-постах (стеновой отрезок), НЕ мобильный
	},
	# Барак — ЁМКОСТЬ казармы: стоя в её зоне-соседстве поднимает ВМЕСТИМОСТЬ гарнизона ИМЕННО этой
	# казармы (HIRE_CAP_PER_BARRACK). НАСЕЛЕНИЕ не даёт — солдат всё равно надо заселить из домов.
	# Категория DEFENSE. Несколько бараков складываются.
	PAD_BARRACK: {
		"name": "Барак",
		"menu_label": "⛺ Барак (+1 боец)",
		"hint": "В зону казармы (лучники/копейщики) → +1 боец в гарнизон. Снабжение — из домов.",
		"role": &"barrack",
		"cells": [Vector2i(0, 0)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 60},
		"ghost_color": Color(0.6, 0.62, 0.5, 0.5),
	},
	# ⚠ ВНЕ МЕНЮ (легаси конвейера): линия шахта→плавильня вырезана — сапорты работают
	# соседством квартала, металл не «течёт». Дизайн-решение об удалении за геймдизайнером.
	PAD_LINE: {
		"name": "Линия переработки",
		"menu_label": "▰ Линия переработки (Z)",
		"role": &"line",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(2, 1)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 10},
		"ghost_color": Color(0.6, 0.7, 0.85, 0.5),
	},
	# Плавильня-САПОРТ (1 клетка): кладётся в ПЛОТ-силуэт квартала шахты. Бонус — за РАЗНЫЕ типы в
	# плоте × заполнение (см. pad_building), размер сапорта свободен → компактная, как была.
	PAD_SMELTER: {
		"name": "Плавильня",
		"menu_label": "🔥 Плавильня (×скорость)",
		"hint": "Ось «Скорость» квартала. Берёт 1 гнома на смену (нет гнома — ось не работает).",
		"role": &"smelter",
		"cells": [Vector2i(0, 0)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 20},
		"ghost_color": Color(0.95, 0.55, 0.25, 0.5),
	},
	# Чеканный двор-САПОРТ (Г-форма, 4 клетки: длинное верхнее плечо + одна вниз слева):
	# вплотную к ШАХТЕ → ускоряет добычу (один сапорт = один бонус; форма крупнит квартал).
	PAD_MINT: {
		"name": "Чеканный двор",
		"menu_label": "🪙 Чеканный двор (+номинал)",
		"hint": "Ось «Номинал» квартала (монета на тир выше). Берёт 1 гнома на смену.",
		"role": &"mint",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 20},
		"ghost_color": Color(0.95, 0.78, 0.25, 0.5),
	},
	# Гномий банк: помпезная крепость. ПАРКОВАН под сапорт ЗАМКА (не добычи) — из меню убран.
	PAD_BANK: {
		"name": "Гномий банк",
		"menu_label": "🏛 Гномий банк (→ казна)",
		"role": &"bank",
		"cells": [Vector2i(0, 0), Vector2i(1, 0)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 40},
		"ghost_color": Color(1.0, 0.85, 0.35, 0.5),
	},
	# Институт магии (1 кл., роль magic): башня мага с кристаллом. Льёт ману в башню (MANA_INSTITUTE_RATE)
	# И открывает доступ к магическим/сапорт-постройкам (группа magic_institute, см. _magic_unlocked).
	PAD_INSTITUTE: {
		"name": "Институт магии",
		"menu_label": "🔮 Институт магии (+мана)",
		"hint": "Мана-жила башни: заряжает её у дока города. Открывает магию.",
		"role": &"magic",
		"cells": [Vector2i(0, 0)],
		"instant": true,
		"hp": 120,
		"cost": {ResourcePile.ResourceType.BRONZE: 100},
		"ghost_color": Color(0.6, 0.5, 1.0, 0.5),
	},
	# Кафедра Волшебных свитков — САПОРТ Института магии, L-форма (4 кл.): в его зону-соседство →
	# ×темп добычи маны (PadBuilding.MANA_MULT_CRYSTAL). Анлок: нужен институт (_magic_unlocked).
	PAD_MANA_CRYSTAL: {
		"name": "Кафедра Волшебных свитков",
		"menu_label": "📜 Кафедра свитков (×темп)",
		"hint": "Сапорт института: ×темп маны. Ставь в зону института магии.",
		"role": &"mana_crystal",
		"cells": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(2, 1)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 50},
		"ghost_color": Color(0.5, 0.7, 1.0, 0.5),
	},
	# Осколок звёздной руды — САПОРТ Института магии (1 кл., на башенке): ×темп маны сильнее
	# (MANA_MULT_RUNE), дороже. Анлок: нужен институт.
	PAD_MANA_RUNE: {
		"name": "Осколок звёздной руды",
		"menu_label": "🌟 Осколок звёздной руды (×темп)",
		"hint": "Сапорт института: ×темп маны (сильнее). Ставь в зону института магии.",
		"role": &"mana_rune",
		"cells": [Vector2i(0, 0)],
		"instant": true,
		"cost": {ResourcePile.ResourceType.BRONZE: 80},
		"ghost_color": Color(0.6, 0.45, 1.0, 0.5),
	},
	# КАФЕДРЫ-ШКОЛЫ (2026-07-07, «хочешь пушку — построй завод»): постройка
	# открывает ВЕТКУ заклинаний (SpellSystem.unlock на завершении, см.
	# PadBuilding._unlock_lab_spells). Магазин заклинаний УМЕР — цена спелла =
	# цена постройки. Гейт: нужен институт (_magic_unlocked), как у сапортов.
	# Здание на ШКОЛУ, не на спелл — каталог не пухнет, новые спеллы падают
	# в существующие ветки. Дальше по модели: кафедры производят МОДУЛИ на
	# корпус башни (лодаут рукой) — этап 3.
	PAD_FIRE_LAB: {
		"name": "Кафедра огня",
		"menu_label": "🔥 Кафедра огня (шар+шквал)",
		"hint": "Школа огня: открывает Огненный шар и Огненный шквал. Требует институт.",
		"role": &"spell_lab",
		"spells": [&"fireball", &"firestorm"],
		"cells": [Vector2i(0, 0), Vector2i(1, 0)],
		"instant": true,
		"hp": 100,
		"cost": {ResourcePile.ResourceType.BRONZE: 120},
		"ghost_color": Color(1.0, 0.5, 0.2, 0.5),
	},
	PAD_ENGINEER_LAB: {
		"name": "Инженерная гильдия",
		"menu_label": "⚙ Инженерная гильдия (турель+мины)",
		"hint": "Школа железа: открывает Мины и КУЁТ Гарпунную турель — клик по зданию (40🥉), аппарат ставится рукой на башню. Требует институт.",
		"role": &"spell_lab",
		"spells": [&"mine_scatter"],
		"cells": [Vector2i(0, 0), Vector2i(1, 0)],
		"instant": true,
		"hp": 100,
		"cost": {ResourcePile.ResourceType.BRONZE: 120},
		"ghost_color": Color(0.7, 0.75, 0.8, 0.5),
	},
	PAD_FROST_LAB: {
		"name": "Кафедра льда",
		"menu_label": "❄ Кафедра льда (мороз)",
		"hint": "Школа льда: открывает Мороз (заморозка + ледяное пятно). Требует институт.",
		"role": &"spell_lab",
		"spells": [&"frost"],
		"cells": [Vector2i(0, 0)],
		"instant": true,
		"hp": 100,
		"cost": {ResourcePile.ResourceType.BRONZE: 90},
		"ghost_color": Color(0.45, 0.8, 1.0, 0.5),
	},
}


## Запись каталога или пустой Dictionary для неизвестного id.
static func get_data(id: StringName) -> Dictionary:
	return CATALOG.get(id, {})
