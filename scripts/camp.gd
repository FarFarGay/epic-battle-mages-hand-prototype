class_name Camp
extends Node3D
## Лагерь — модуль каравана+развёртки. Цепочка палаток-RigidBody3D
## (frozen=true в норме — Camp двигает их через global_position) следует за
## башней (CARAVAN_FOLLOWING) и по hold-инпуту разворачивается в кольцо
## вокруг точки остановки башни (DEPLOYED). На физический удар (Slam, Flick,
## магия) палатка снимается с freeze, эмиттит CampPart.is_torn_off=true,
## Camp пропускает её в follow-логике — она физически летает и кувыркается.
##
## Состояния:
## - CARAVAN_FOLLOWING — палатки тянутся «змейкой» за башней. Hold R с условием
##   «башня стоит» ≥ deploy_duration разворачивает лагерь.
## - DEPLOYED — палатки lerp'ом смещаются на точки кольца радиуса deploy_radius
##   вокруг _deploy_anchor. Hold R ≥ pack_duration сворачивает (без
##   stationary-проверки).
##
## Коллизии: палатки всегда на слое CampObstacle (6, бит 5). Tower.mask=15
## (Terrain | Items | Actors | Projectiles, без CAMP_OBSTACLE и без ENEMIES) →
## башня проходит сквозь палатки и сквозь скелетов в любом состоянии.
## Skeleton.mask=39 (Terrain | Items | Actors | CAMP_OBSTACLE; см.
## `Layers.MASK_SKELETON`) → скелеты упираются в палатки и в каравне, и в
## развёрнутом лагере. Никакого рантайм-toggle коллизии нет.
##
## Зависит только от Tower через target_path. Локальные сигналы deployed/packed
## ре-эмитятся в EventBus для UI / звука / статистики.
##
signal deployed(anchor: Vector3)
signal packed

## CARAVAN_FOLLOWING — палатки тянутся за башней, гномы IN_TENT.
## DEPLOYED — палатки в кольце вокруг anchor'а, гномы бродят и собирают ресурсы.
## PACKING_RETURNING — пользователь начал свёртку, гномы возвращаются в палатки;
##                     сами палатки пока не двигаются — ждут гномов. Когда все
##                     гномы IN_TENT — переход в CARAVAN_FOLLOWING.
enum State { CARAVAN_FOLLOWING, DEPLOYED, PACKING_RETURNING }

## Режим сбора: WORK — гномы работают как обычно (SEARCHING → собирают по
## приоритету), ALARM — все gatherer'ы возвращаются в палатки (request_return).
## DefenderGnome НЕ затрагивается режимом — защитники всегда снаружи и
## продолжают защищать (у них собственный override request_return, который мы
## специально пропускаем). Режим имеет смысл только в DEPLOYED — в каравне
## гномы и так в палатках, в PACKING — уже идут домой.
enum CollectionMode { WORK, ALARM }

@export_node_path("Node3D") var target_path: NodePath

@export_group("Caravan composition")
## Сцена палатки — будет инстанцироваться по tent_count раз в _ready.
## Каждая палатка самостоятельная сущность (Tent.tscn + camp_part.gd):
## Damageable, может быть уничтожена, имеет свой shatter-эффект на смерть.
@export var tent_scene: PackedScene
## Сколько палаток в караване. Меняется в инспекторе — спавнится при старте.
## Можно ставить любое разумное количество; layout цепочки автоматически
## распределится через part_gap. На развёртку угол кольца считается как
## TAU / tent_count, так что любое число работает.
@export var tent_count: int = 4
## «Уже развёрнутый» лагерь: на _ready стартуем сразу в DEPLOYED-состоянии,
## anchor = собственная global_position (не нужна башня). Палатки сразу
## едут в кольцо вокруг лагеря, гномы выходят бродить и собирать.
## R-toggle отключён — такой лагерь не сворачивается. Используется для
## статических поселений на POI (карта-локация без следования за башней).
@export var start_deployed: bool = false
@export_group("")

## Группа целей для скелетов (см. Skeleton.TARGET_GROUP). Camp ставит/убирает
## tower в эту группу в зависимости от состояния: в каравне tower уязвим
## для агро, в развёрнутом лагере — нет (скелеты переключаются на палатки
## и гномов вокруг костра).
const SKELETON_TARGET_GROUP := &"skeleton_target"

## ID-константы апгрейдов отряда. Используются в has_upgrade() и в каталоге
## UPGRADE_CATALOG (для UI/модала).
const UPGRADE_KITING := &"kiting"
const UPGRADE_LONG_DRAW := &"long_draw"

## ID-константы построек лагеря. Отдельный namespace от squad-апгрейдов:
## юнит-апгрейды берутся за очко уровня (одноразово на id), постройки —
## за ресурсы (BUILDING_NEW_TENT можно строить многократно). См.
## CAMP_BUILDING_CATALOG ниже.
const BUILDING_NEW_TENT := &"new_tent"
const BUILDING_WATCH_BELL := &"watch_bell"
const BUILDING_PALISADE := &"palisade"
const BUILDING_ARCHER_POST := &"archer_post"

## Каталог апгрейдов отряда — id → отображаемые поля. JournalPanel читает
## name/description/level чтобы построить карточки. Эффекты применяются на
## стороне DefenderGnome через has_upgrade(id) — тут только метаданные.
##
## `level` — минимальный squad_level, при котором апгрейд можно выбрать.
## Конвенция дизайнера: первые два апгрейда доступны на уровне 1, дальше
## по одному на уровень. Незакрытый банк выборов копится — игрок может
## дойти до 3-го уровня и потом купить старый апгрейд первого.
const UPGRADE_CATALOG: Dictionary = {
	UPGRADE_KITING: {
		"name": "Манёвр уклонения",
		"description": "Лучники стреляют на ходу и пятятся от близких скелетов, удерживая дистанцию.",
		"level": 1,
	},
	UPGRADE_LONG_DRAW: {
		"name": "Усиленное натяжение",
		"description": "Дальность стрельбы +5 метров. Лучники открывают огонь раньше.",
		"level": 1,
	},
}


## Каталог построек лагеря — id → {name, description, cost, packed_only,
## repeatable}. JournalPanel читает чтобы построить карточки, Camp.try_build
## применяет эффект через _apply_building.
##
## - cost: Dictionary[ResourcePile.ResourceType (int) → int]. Списывается
##   атомарно через try_spend.
## - packed_only: true → постройка только в State.CARAVAN_FOLLOWING (свёрнут).
##   Дизайнерское правило: палатки строятся только в свёрнутом лагере, в
##   развёрнутом — нет (см. project_ebm_camp_progression).
## - repeatable: true → можно купить много раз (новые палатки). false →
##   одноразово (для будущих watchtower / orb_magnet).
const CAMP_BUILDING_CATALOG: Dictionary = {
	BUILDING_NEW_TENT: {
		"name": "Новая палатка",
		"description": "Добавляет ещё одну палатку в кольцо лагеря — +жителей, +лучник, +собиратели.",
		"cost": {
			ResourcePile.ResourceType.WOOD: 20,
			ResourcePile.ResourceType.STONE: 10,
			ResourcePile.ResourceType.FOOD: 5,
		},
		"deployed_only": true,
		"repeatable": true,
	},
	BUILDING_WATCH_BELL: {
		"name": "Сторожевой колокол",
		"description": "Гном-сторож замечает врагов в радиусе и зовёт двух защитников из лагеря. Колокол можно поставить где угодно — например, у источника ресурсов.",
		"cost": {
			ResourcePile.ResourceType.WOOD: 12,
			ResourcePile.ResourceType.IRON: 5,
		},
		"deployed_only": true,
		"repeatable": true,
		"requires_gatherer": true,
		"requires_aim": true,
		# Preview-радиус aim-кольца. Совпадает с WatchBell.alarm_radius (7.5м).
		# Если синхронизировать со сценой нужно динамически — в будущем
		# прочитаем из инстанса при aim_start; пока константа достаточна.
		"aim_radius": 7.5,
	},
	BUILDING_PALISADE: {
		"name": "Деревянный частокол",
		"description": "Дешёвые сегменты стены 2м длиной. Скелеты ломают их, но тратят на это время — защитники успевают стрелять. Рисуй ломаную линию: ЛКМ ставит точки, ПКМ — построить, Esc — отмена.",
		# brush_mode → стоимость per-segment, total зависит от длины линии.
		# UI рисует «N wood / сегмент» вместо обычного total.
		"cost_per_segment": {ResourcePile.ResourceType.WOOD: 2},
		"deployed_only": true,
		"repeatable": true,
		"brush_mode": true,
		# Длина одного сегмента в метрах. Совпадает с BoxMesh.size.x в
		# palisade_segment.tscn (2м). Polyline AB длиной N разбивается на
		# floor(N / segment_length) сегментов.
		"segment_length": 2.0,
	},
	BUILDING_ARCHER_POST: {
		"name": "Стрелковый пост",
		"description": "Стационарный лучник на башенке. Видит дальше обычного защитника, но только в направлении взгляда — конус света медленно сканирует сектор. Игрок выбирает направление при установке: короткий клик — наружу от лагеря, drag — точное направление.",
		"cost": {
			ResourcePile.ResourceType.WOOD: 8,
			ResourcePile.ResourceType.IRON: 3,
		},
		"deployed_only": true,
		"repeatable": true,
		# Изымает 1 свободного гнома (как watch_bell). Пост — это не палатка, а
		# самостоятельное здание с встроенным лучником; гном «исчезает» из
		# каравана пока пост стоит. На свёртке/разрушении гном возвращается
		# обратно spawn'ом gatherer'а на месте поста (см. _on_archer_post_destroyed).
		"requires_gatherer": true,
		"requires_aim": true,
		# direction-aim mode (drag для направления, короткий клик → наружу от
		# лагеря). См. HandBuildAim — этот флаг переводит start_aim в
		# direction-aim flow с generic dispatch.
		"requires_direction": true,
		# Preview-кольцо размером с площадку поста, ~1.5м.
		"aim_radius": 1.5,
	},
}


@export_group("POI deploy gate")
## Если true — деплой возможен ТОЛЬКО когда башня в радиусе safe_radius
## хотя бы одной POI-зоны (см. [QuestActor.safe_radius] и группу `poi_zone`).
## Hold R вне POI игнорируется (счётчик _deploy_hold не накапливается).
## Anchor лагеря защёлкивается на позицию POI, а не на текущую позицию
## башни — палатки кольцом строятся симметрично вокруг костра.
##
## Геймдизайнерская идея: POI = костёр = единственное место «осесть».
## Между POI караван едет, защитники в палатках, никаких атак волной —
## фоновые скелеты могут увидеть и накинуться, но это редкие стычки.
##
## false — старое поведение (deploy где угодно, anchor=tower.position).
## Полезно для отладки и потенциально для «лагерь без POI» режимов.
@export var require_poi: bool = true
@export_group("")

## Decay-коэффициент (log-rate) экспоненциального следования палаток.
## Чем выше — тем быстрее палатка догоняет точку-цель. Не зависит от dt.
@export var follow_speed: float = 4.0
## Расстояние между палатками в цепочке и между башней и parts[0].
@export var part_gap: float = 2.5
## Дистанция «башня ↔ Harvester» и «Harvester ↔ первая палатка» в каравне.
## Больше part_gap, потому что Harvester крупнее палатки и должен иметь
## визуальное «дыхание» вокруг себя — иначе в строю всё налезает кучей.
@export var harvester_gap: float = 4.5
## Базовое расстояние между гномами-followers в цепочке. Меньше part_gap —
## гномы идут плотнее палаток, как «толпа за караваном». Реальный gap
## раздёргивается per-гном через gnome_chain_gap_variance.
@export var gnome_chain_gap: float = 1.2
## Разброс forward-смещения per-гном (доля gnome_chain_gap). 0.3 = ±30%,
## фактический gap гнома в диапазоне [0.7, 1.3] × gnome_chain_gap.
## 0 = ровная очередь.
@export var gnome_chain_gap_variance: float = 0.35
## Максимум lateral-смещения per-гном перпендикулярно цепочке (метры).
## 0.7м — гномы рассыпаются полосой шириной до 1.4м, не идут ниткой.
## 0 = идеально ровная линия.
@export var gnome_chain_jitter: float = 0.7
## За этим порогом ведущая палатка перестаёт двигаться (башня «ушла далеко»).
@export var follow_max_distance: float = 30.0
## Cap на скорость палатки в caravan-follow (м/с). Без cap'а exp_decay при
## большой дистанции (Tower ушёл далеко: после halt-resume или free-placement
## вне строя) даёт пропорциональный дистанции «рывок» — палатка визуально
## ускоряется. Cap делает движение равномерным: в обычных кадрах exp-step
## ≪ max_step (палатка близко к цели), cap не активируется; на больших
## разрывах step клампится — палатка догоняет с постоянной скоростью.
## Дефолт 10 м/с — чуть выше Tower.move_speed=8, чтобы догонять, но не
## телепортироваться.
@export var caravan_max_speed: float = 10.0
## Радиус «зоны каравана» — куда игрок может рукой вернуть палатку в строй.
## В CARAVAN_FOLLOWING зона измеряется от башни, в DEPLOYED — от _deploy_anchor.
## Если игрок аккуратно (тихий release) поставил палатку В этой зоне →
## Camp пересортирует _parts по позиции и втянет её в строй. Если ВНЕ зоны →
## palatка просто стоит на месте, Camp её не таскает (но и гномы IN_TENT
## остаются в ней — никого не убивает). Чтобы вернуть палатку в строй,
## её надо подобрать ещё раз и поставить ближе чем placement_zone_radius.
@export var placement_zone_radius: float = 15.0
## Секунды зажатой R + неподвижности башни для развёртки.
@export var deploy_duration: float = 3.0
## Секунды зажатой R для свёртки (stationary не требуется).
@export var pack_duration: float = 4.0
## Таймаут после _start_pack: если за это время не все гномы дошли домой
## (застряли вне reach'а, ушли далеко, рука держит их с RETURNING_TO_TENT
## пропуская _tick_returning, и т.п.) — форсированно завершаем свёртку.
## Без таймаута Camp залипал в PACKING_RETURNING вечно: один зависший гном
## (например, упавший с обрыва или застрявший в коллизии скелета)
## блокировал весь караван от движения.
@export var pack_timeout: float = 12.0
## Радиус кольца, на которое расставляются палатки вокруг anchor.
@export var deploy_radius: float = 8.0
## Порог смещения цели за кадр, ниже которого считаем её неподвижной.
@export var stationary_threshold: float = 0.01

@export_group("Gnomes")
## Сцена обычного гнома-собирателя. Спавнится на каждую палатку
## (gnomes_per_tent − defenders_per_tent) раз — это «жители-собиратели»,
## ищут ResourcePile и носят к anchor лагеря.
@export var gnome_scene: PackedScene
## Сцена защитника-лучника (DefenderGnome). Спавнится на каждую палатку
## defenders_per_tent раз — стоят у лагеря и стреляют в скелетов.
## Если null — защитники не спавнятся, на их слоты подставятся обычные гномы.
@export var defender_scene: PackedScene
## Сцена сторожевого колокола (WatchBell). Спавнится через BUILDING_WATCH_BELL.
## Если null — постройка watch_bell молча провалится.
@export var watch_bell_scene: PackedScene
## Сцена маркера обороны (DefenseMarker). Спавнится через BUILDING_DEFENSE_MARKER.
## Если null — постройка молча fail'ит на _build_defense_marker (push_warning).
@export var defense_marker_scene: PackedScene
## Сцена сегмента деревянного частокола. Спавнится множественно через
## BUILDING_PALISADE / try_build_palisade_line. Если null — постройка молча
## провалится.
@export var palisade_segment_scene: PackedScene
## Сцена столбика частокола — короткий 0.4×1.5×0.4 столбик. Спавнится на
## каждом vertex'е ломаной для перекрытия углов и дробных хвостов. Тот же
## скрипт что и сегмент (общий hp/damage/группы). Если null — стыки
## остаются открытыми.
@export var palisade_post_scene: PackedScene
## Сцена стрелкового поста (ArcherPost). Спавнится через BUILDING_ARCHER_POST.
## Если null — постройка молча провалится.
@export var archer_post_scene: PackedScene
## Радиус «зоны строительства» от центра развёрнутого лагеря. Постройки,
## требующие интерактивного выбора места (флаг `requires_aim` в каталоге),
## не ставятся за пределами этого круга. Преимущественно для сторожевого
## колокола: 30м даёт прикрыть и палатки, и ближайшие ResourceZone, но не
## весь плейн. Дизайнер тюнит в инспекторе.
@export var build_radius: float = 30.0
## Радиус «лагеря» для размобилизации отряда. Кнопка «Распустить» в HUD
## активна, только если ВСЕ живые члены отряда в этом радиусе от deploy_anchor.
## Дизайнерское правило: размобилизация — это лагерное действие, на марше
## или в эскорте недоступна. Чуть больше deploy_radius (8м) — даёт юниту
## слот защитника (deploy_radius+~4м снаружи) тоже распуститься.
@export var dismiss_radius: float = 12.0
## Радиус «зоны вызова» вокруг башни. Все recall-команды (Q-recall отрядов,
## кнопка «За башней», R-pack лагеря) гейтятся этой зоной: цели вне радиуса
## не реагируют. Это даёт игроку:
##   - оставить лагерь и уйти только с солдатами (R вне зоны → no-pack);
##   - не вызывать одинокого копейщика через всю карту (Q игнорит дальних).
@export var recall_zone_radius: float = 20.0
## Скорость распространения «волны вызова» (м/с). Команда юнитам срабатывает
## не мгновенно, а когда фронт волны до них долетает: ближний копейщик
## срывается раньше, дальний — позже. Визуально HUD рисует расширяющееся
## кольцо. На radius=30, speed=25 → волна доходит до края за 1.2с.
@export var recall_wave_speed: float = 25.0

@export_group("Collection orders")
## Стартовый приоритет сбора по типам ресурсов. Ключи — ResourcePile.ResourceType
## (int), значения — относительные веса (нормализуются при первом set'е и
## после init'а: weights / sum). Гном при выборе ближайшего pile делит
## реальную дистанцию на weight типа — высокий weight «приближает» pile,
## нулевой полностью отключает. Дефолт: равномерно (по 1.0 каждому из 4 типов).
@export var initial_collection_priority_wood: float = 1.0
@export var initial_collection_priority_stone: float = 1.0
@export var initial_collection_priority_iron: float = 1.0
@export var initial_collection_priority_food: float = 1.0
## Радиус поиска ресурсов от deploy_anchor. Гном игнорирует кучи дальше этой
## дистанции — лагерь работает в «своём кругу», а не сканирует всю карту.
## Хочешь дальше — двигай лагерь.
##
## С 2026-05-16 уменьшен 50→30м (в две итерации): на тестовой карте при 50м
## все 4 ResourceZone попадали в радиус, и при истощении ближних (12-17м)
## гномы шли к дальним (~32м) — игрок воспринимал это как «через всю карту».
## Первая попытка с 20м оказалась слишком тесной — wood/food zones имеют
## центры ~30м и ближайшие кучи в них на ~20м от anchor'а, обрезались
## строгим > сравнением. 30м совпадает с build_radius (что застроишь — то
## и гномы добывают), захватывает близкие куски всех 4 зон, при этом
## ограничивает шатание по карте.
@export var gather_radius: float = 30.0
## Масштаб stock-балансировки. Эффективный вес типа = base_weight / (1 + stock/SCALE)².
## При stock=SCALE вес делится на 4 (квадратичный штраф). Меньше SCALE →
## агрессивнее переключение, дефицит выкуривает гномов туда быстрее. Больше →
## план «инерционнее».
##
## История значений:
## - 30 (исходное): на тестовой карте при стоках 15-20 камня дерево всё ещё
##   проигрывало по cost'у, т.к. камень оказался геометрически ближе к лагерю.
##   Игрок жаловался «План Равномерно, а собирают только железо/камень».
## - 12 (2026-05-15): при stock=15 вес режется в 5×, ratio дерево/камень
##   ≈2.8 → дерево выигрывает если не дальше 1.69× камня. Покрывает
##   реалистичные размещения куч на карте с zone'ами.
@export var stock_balance_scale: float = 12.0
@export_group("")

@export_group("Anchor drop zone")
## Радиус Area3D в центре развёрнутого лагеря, в которой брошенные рукой
## ResourcePile засчитываются целиком (все units разом). Активна только в
## DEPLOYED — в каравне «центра» нет. ~2.5м примерно равно deploy_radius/3,
## хорошо отделяет «центр» от «кольца» палаток.
@export var anchor_drop_radius: float = 2.5
@export_group("")

@export_group("Harvester")
## Сцена Harvester'а — звено каравана между башней и палатками. Спавнится
## в _ready, на _start_deploy ставится на _deploy_anchor (= центр POI) и
## начинает добычу золота. На свёртке возвращается в строй каравана.
## Если null — лагерь работает без харвестера: gold не добывается, цепочка
## tower→tents[0] остаётся как раньше.
@export var harvester_scene: PackedScene
@export_group("")

@export_group("Squad XP / upgrades")
## Кривая порогов уровней. squad_level_xp_curve[N] = XP, нужный для уровня N+1.
## Дойдя до индекса >= size — больше уровней не дают (всё, апгрейды кончились).
## Дефолт «5×geometric» — 50, 120, 250, 500, 1000: к концу 1900 XP = 190 убийств
## по 10 XP, что соответствует ~10-15 минутам активного боя.
@export var squad_level_xp_curve: Array[int] = [50, 120, 250, 500, 1000]
## Дальность стрельбы +N метров для апгрейда long_draw. Прибавляется к
## attack_radius защитника через DefenderGnome.effective_attack_radius().
@export var upgrade_long_draw_bonus: float = 5.0
## Дистанция, на которой kiting-апгрейд переходит в режим «пятиться» —
## близкий враг → defender отступает спиной, продолжая стрелять. Дальше
## порога — обычный stand-and-shoot.
@export var kite_threshold_distance: float = 6.0
@export_group("")

@export_group("Super charge (великая сила)")
## Полная шкала «великой силы». Накопление 1:1 от нанесённого damage'у врагам
## (HandSpell, HandPhysical, defender'ы, башня — всё подаёт через
## EventBus.enemy_damaged). 100 = ~3-4 убитых скелета (hp=30 ea).
@export var super_charge_max: float = 100.0
## Доля шкалы, списываемой при провале QTE. 0.5 = «потерял половину» —
## промежуточная цена за неудачу (полный каст списывает 100%).
@export_range(0.0, 1.0) var super_charge_fail_penalty: float = 0.5
@export_group("")

@export_group("")
@export var debug_log: bool = true

var _tower: Node3D
var _state: State = State.CARAVAN_FOLLOWING
## Палатки каравана. Тип Node3D (а не RigidBody3D), потому что после tear-off
## (apply_push на CampPart) палатка остаётся в массиве несколько кадров до
## фактического `_remove_torn_part` — но сама follow-логика её уже пропускает
## через `(part as CampPart).is_torn_off()`. Также удобнее, если когда-то
## появятся не-RB палатки.
var _parts: Array[Node3D] = []
## Звено каравана между башней и палатками — отдельная сущность, добывает
## золото в DEPLOYED. Спавнится в _ready если harvester_scene задан. Двигается
## Camp'ом в _update_caravan_follow (как палатки), деплоится на _deploy_anchor
## в _start_deploy. Может быть null — лагерь продолжит работать без него.
var _harvester: Harvester
## Таймер удержания R в CARAVAN_FOLLOWING (для развёртки).
var _deploy_hold: float = 0.0
## Таймер удержания R в DEPLOYED (для свёртки).
var _pack_hold: float = 0.0
var _deploy_anchor: Vector3 = Vector3.ZERO
var _deployed_targets: Array[Vector3] = []
## Часы PACKING_RETURNING: тикают с момента _start_pack. По достижении
## pack_timeout — _finalize_pack принудительно, даже если кто-то не дома.
var _pack_elapsed: float = 0.0
## Позиция башни на прошлом кадре — для эпсилон-чека неподвижности.
var _last_target_pos: Vector3 = Vector3.INF
## Гномы лагеря — gnomes_per_tent × количество палаток. Создаются в _ready.
var _gnomes: Array[Gnome] = []
## Активные сторожевые колокола, построенные через [BUILDING_WATCH_BELL].
## Camp подписан на каждый на `bell_alarmed` (диспатч защитников) и `destroyed`
## (респавн gatherer'а на месте). Удаляются на destroy.
var _bells: Array[WatchBell] = []
## Активные стрелковые посты (ArcherPost), построенные через
## BUILDING_ARCHER_POST. Camp подписан на каждый на `destroyed` (респавн
## gatherer'а на месте, как с колоколом) и на pack — вычищает массив через
## _dismantle_archer_posts(). Гном считается «внутри поста», пока пост стоит.
var _archer_posts: Array[ArcherPost] = []
## Активные маркеры обороны, построенные через BUILDING_DEFENSE_MARKER.
## На спавн маркера: 3 ближайших защитника назначаются на слоты (через
## defender.assign_to_marker). На marker.destroyed: все назначенные
## освобождаются (release_from_marker), возвращаются к свободному патрулю.
var _defense_markers: Array[DefenseMarker] = []
## Бездомные гномы (выкинутые из палатки), идут за караваном в общей цепочке
## за палатками. Порядок = порядок регистрации (раньше eject'нутые — ближе к
## палаткам). Слот в цепочке = индекс в массиве. Регистрируются из
## Gnome.enter_following_caravan, снимаются на death через unregister.
## Используется в get_chain_target_for_follower.
var _caravan_followers: Array[Gnome] = []
## XP отряда защитников. Накапливается через `add_squad_xp(amount, position)` —
## зовётся `XpOrb` на arrival к anchor'у лагеря. Сами орбы дропают скелеты
## на смерть (через `XpOrbSpawner`-autoload, см. `EventBus.enemy_destroyed`).
var _squad_xp: int = 0
## Текущий уровень отряда. Считается по squad_level_xp_curve: пока _squad_xp
## дотягивает до следующего порога — _squad_level++ + emit squad_leveled_up.
var _squad_level: int = 0
## Сколько уровней «висит» в очереди на выбор апгрейда. Игрок может догнать
## уровни быстрее чем закрыть модал — тогда модал откроется снова после grant.
var _pending_upgrade_choices: int = 0
## Шкала «великой силы». 0..super_charge_max. Накопление через
## `_on_enemy_damaged` подписку на EventBus.enemy_damaged. Списание полное
## при успешном супер-касте, частичное (super_charge_fail_penalty) при провале QTE.
var _super_charge: float = 0.0
## Активные отряды солдат. Пополняется через recruit_squad, убирается на
## squad.disbanded (все члены погибли). UI (gameplay_hud) подписан на
## EventBus.squad_created/changed/disbanded.
var _squads: Array[Squad] = []
## Counter для уникального Squad.id — увеличивается при каждом recruit_squad.
var _next_squad_id: int = 0
## Активные апгрейды отряда. DefenderGnome читает has_upgrade(id) на каждом
## тике, эффекты применяются динамически (новые защитники после смерти/
## reset_population автоматически в курсе).
var _active_upgrades: Array[StringName] = []
## Центральный mount-slot для модулей (turret и т. д.). В фазе CARAVAN он
## выключен и невидим — «центра лагеря» не существует. На развёртке слот
## переезжает в anchor и активируется; на свёртке — выключается, что
## размонтирует всё что на нём стояло (модуль остаётся лежать на земле).
@onready var _center_slot: MountSlot = get_node_or_null("CenterMountSlot") as MountSlot
## Area3D в центре развёрнутого лагеря, ловит брошенные рукой ResourcePile.
## Создаётся в _ready, monitoring=false. На _start_deploy ставится на anchor
## и включается; на _start_pack — выключается. Polling каждый кадр через
## _consume_piles_in_drop_zone — так ловим и кучи, которые пролежали под
## рукой и были отпущены уже внутри зоны (body_entered не сработал бы).
var _anchor_drop_zone: Area3D = null

## Текущий режим сбора (см. CollectionMode). Меняется через set_collection_mode
## (хоткеи C / V в _handle_input, или из API). HUD рисует индикатор.
var _collection_mode: CollectionMode = CollectionMode.WORK

## Караван «остановлен на месте» в State.CARAVAN_FOLLOWING. Палатки не
## двигаются за башней (`_update_caravan_follow` ранний return), но и не
## разворачиваются — гномы остаются IN_TENT. Tower продолжает кататься
## независимо. Toggle через Q (`caravan_halt_toggle`) или
## `set_caravan_halted(value)`. Имеет смысл только в CARAVAN_FOLLOWING —
## в DEPLOYED палатки и так стоят, в PACKING_RETURNING ждут гномов.
## Сбрасывается при _start_deploy (если каким-то образом игрок развернёт),
## чтобы не остаться в halted после возврата в caravan.
var _caravan_halted: bool = false
## Нормализованные веса приоритета сбора по типам, sum=1.0. Дефолт ставится
## в _init_collection_priority из @export'ов. Меняется через set_collection_priority
## (Journal-вкладка «План»). Гном читает get_collection_priority_weight.
var _collection_priority: Dictionary = {}

## Публичный геттер anchor'а — гномы читают, чтобы знать, куда нести ресурс.
var deploy_anchor: Vector3:
	get:
		return _deploy_anchor

# Логирование (фронт-триггеры, чтобы не спамить каждый кадр).
var _was_holding_stationary: bool = false
var _was_out_of_range: bool = false

# Кеш _find_poi_for_deploy — _handle_input зовётся каждый кадр на зажатой R
# (60Гц), и в каждом вызове мы делаем `get_tree().get_nodes_in_group(POI_GROUP)`
# + distance²-проход. Группа маленькая (3-7 POI), но Array-аллокация
# 60 раз/сек на одну фичу — лишний шум. TTL 0.1с: за это время башня успеет
# проехать ≤ 0.8м (move_speed≈8м/с), и пограничный «вошёл/вышел из safe_radius»
# случай задержится максимум на 100мс — игроком не читается.
const POI_CACHE_TTL_SEC: float = 0.1
var _poi_cache: Node3D = null
var _poi_cache_time_msec: int = -1000000


## Группа для JournalPanel и других UI-autoload'ов: один публичный handle на
## get_first_node_in_group('camp'), без знания о конкретном Camp-инстансе.
const CAMP_GROUP := &"camp"


func _ready() -> void:
	add_to_group(CAMP_GROUP)
	if not target_path.is_empty():
		_tower = get_node_or_null(target_path) as Node3D
	if not _tower and not start_deployed:
		push_warning("Camp: target_path не разрешился, башня не задана")

	_spawn_tents()
	_spawn_harvester()
	_spawn_gnomes()
	_build_anchor_drop_zone()
	_init_collection_priority()

	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	deployed.connect(func(anchor: Vector3) -> void: EventBus.camp_deployed.emit(anchor))
	packed.connect(func() -> void: EventBus.camp_packed.emit())

	# Башня может погибнуть — обнуляем ссылку, чтобы караван не follow'ил мёртвый
	# (но всё ещё существующий статикой) Tower-меш. _update_caravan_follow и
	# stationary-чек уже null-safe, ничего больше делать не нужно.
	EventBus.tower_destroyed.connect(_on_tower_destroyed)

	# Шкала «великой силы»: накапливается по нанесённому damage'у врагам.
	# enemy_damaged эмитится re-emit'ом из Enemy.damaged → Skeleton наследует.
	# 1 hp damage = 1 charge; full bar (super_charge_max) разрешает супер-каст.
	EventBus.enemy_damaged.connect(_on_enemy_damaged)
	EventBus.super_charge_changed.emit(_super_charge, super_charge_max)

	# Static-режим: сразу стартуем в DEPLOYED. Anchor = собственная позиция
	# Camp (не башни, которой нет). Палатки переедут с линии (где их поставил
	# _spawn_tents) в кольцо вокруг anchor через _exp_decay в _update_deployed.
	if start_deployed:
		_start_deploy()
	else:
		# В каравне tower сам по себе является целью для скелетов: фоновые
		# wander-скелеты, увидев караван глазами, идут к башне и атакуют её.
		# Когда лагерь развернётся — _start_deploy уберёт tower из группы
		# (агро переключится на палатки), а на _finalize_pack — вернёт.
		_set_tower_aggro(true)
		# Палатки тоже атакуемы в каравне — скелеты, увидев караван глазами,
		# идут на ближайшую цель (tower или палатку). Раньше было «уязвимы
		# только в DEPLOYED», но геймдизайнер просил, чтобы караван был
		# полноценной целью: tower + палатки. Бронируются только в
		# PACKING_RETURNING (см. _start_pack).
		_set_parts_vulnerable(true)


## Спавнит палатки по tent_scene × tent_count. Линейная цепочка позади башни:
## первая в локальном (0,0,0), каждая следующая на part_gap метров левее по X.
## Y берётся из самой сцены палатки (Tent.tscn ставит её на пол через свой
## меш-размер; camp_part.set_vulnerable управляет уязвимостью).
##
## Каждая палатка — самостоятельный инстанс с собственным CampPart-скриптом.
## Подписываемся на destroyed, чтобы синхронно вычищать обе структуры
## (_parts и _deployed_targets) при гибели — иначе индексы сдвинутся
## и оставшиеся палатки в DEPLOYED поедут к чужим точкам кольца.
func _spawn_tents() -> void:
	if tent_scene == null:
		push_warning("Camp: tent_scene не задан — палатки не спавнятся")
		return
	if tent_count <= 0:
		return
	for i in range(tent_count):
		_spawn_one_tent()


## Спавнит одну палатку в конец цепочки (`_parts.size()` = новый индекс).
## Используется и при инициализации (`_spawn_tents` × tent_count), и для
## run-time строительства (`_build_new_tent`). Палатка ставится «за башней»
## вдоль -X в позиции, которую заняла бы N-я в полностью построенной
## цепочке — follow exp_decay подтянет в строй за следующие кадры.
##
## Возвращает инстанс палатки (или null, если не получилось инстанцировать).
func _spawn_one_tent() -> Node3D:
	if tent_scene == null:
		push_warning("Camp: tent_scene не задан")
		return null
	# Tent — RigidBody3D с freeze=true (после смены StaticBody → RB на 2026-05-03):
	# на freeze палатка ведёт себя как кинематическое тело, Camp двигает её
	# через global_position. На apply_push freeze снимается, палатка летит.
	var tent := tent_scene.instantiate() as Node3D
	if tent == null:
		push_warning("Camp: tent_scene не инстанцируется как Node3D")
		return null
	var index: int = _parts.size()
	tent.name = "Tent%d" % (index + 1)
	add_child(tent)
	# Цепочка позади башни вдоль -X. Y оставляем тот, что задал tent.tscn
	# (transform.y=0.75 — половина высоты, чтобы стояла на полу).
	var leader_xz: Vector3 = _tower.global_position if _tower != null else global_position
	tent.global_position = Vector3(
		leader_xz.x - float(index + 1) * part_gap,
		tent.global_position.y,
		leader_xz.z,
	)
	_parts.append(tent)
	if tent is CampPart:
		(tent as CampPart).destroyed.connect(_on_part_destroyed.bind(tent))
	return tent


## Спавнит Harvester как звено каравана сразу за башней. Если сцена не задана —
## лагерь работает без харвестера (no-op в follow и deploy/pack).
func _spawn_harvester() -> void:
	if harvester_scene == null:
		return
	var h := harvester_scene.instantiate() as Harvester
	if h == null:
		push_warning("Camp: harvester_scene не инстанцируется как Harvester")
		return
	h.name = "Harvester"
	add_child(h)
	var leader_xz: Vector3 = _tower.global_position if _tower != null else global_position
	# Ставим за башней на harvester_gap (больше part_gap — Harvester крупнее).
	# Y оставляем из сцены — Harvester сам ставится на пол через свой базовый меш.
	h.global_position = Vector3(
		leader_xz.x - harvester_gap,
		h.global_position.y,
		leader_xz.z,
	)
	h.bind_economy(economy)
	_harvester = h


func _spawn_gnomes() -> void:
	if gnome_scene == null and defender_scene == null:
		if debug_log and LogConfig.master_enabled:
			print("[Camp] ни gnome_scene, ни defender_scene не заданы — никого не спавним")
		return
	for tent in _parts:
		if not (tent is CampPart):
			continue
		var part := tent as CampPart
		var total: int = part.gnomes_per_tent
		# defenders_per_tent клампим до total — защитников не больше жителей.
		var defender_n: int = clampi(part.defenders_per_tent, 0, total)
		var gatherer_n: int = total - defender_n
		# Сначала защитники (если их сцена задана), потом собиратели.
		# Каждый получает позицию палатки + setup(camp, tent) — гном привязан
		# именно к этой палатке (RETURNING_TO_TENT идёт сюда же).
		for i in range(defender_n):
			_spawn_one_gnome(defender_scene, tent, "defender")
		for i in range(gatherer_n):
			_spawn_one_gnome(gnome_scene, tent, "gatherer")


## Инстанцирует одну сцену гнома, привязывает к палатке. Используется
## и для защитников (defender_scene), и для собирателей (gnome_scene).
## Если сцена null или не инстанцируется как Gnome — push_warning и null.
## Возвращает спавненного гнома (или null) — caller'у может потребоваться
## дёрнуть enter_deployed на нём (run-time постройка в DEPLOYED).
func _spawn_one_gnome(scene: PackedScene, tent: Node3D, role: String) -> Gnome:
	if scene == null:
		push_warning("Camp: сцена для роли '%s' не задана — пропуск" % role)
		return null
	var gnome := scene.instantiate() as Gnome
	if gnome == null:
		push_warning("Camp: сцена для роли '%s' не инстанцируется как Gnome" % role)
		return null
	add_child(gnome)
	gnome.global_position = tent.global_position
	gnome.setup(self, tent)
	# Скелет может убить гнома — выкидываем из _gnomes, иначе claim-чек
	# и _all_gnomes_home будут спотыкаться об invalid-инстансы.
	gnome.destroyed.connect(_on_gnome_destroyed.bind(gnome))
	_gnomes.append(gnome)
	return gnome


## Публичный геттер списка гномов лагеря. CampPart использует, чтобы найти
## своих жильцов IN_TENT при tear-off (eject + damage). Возвращает internal
## ссылку — caller'ы должны не мутировать массив, только итерировать.
func get_gnomes() -> Array[Gnome]:
	return _gnomes


## Публичный геттер ссылки на башню. Бездомные гномы (FOLLOWING_CARAVAN) идут
## за ней. Может быть null если target_path не разрешился или Tower уничтожена.
func get_tower() -> Node3D:
	return _tower


## Цель магнита XP-орба, выбирается по позиции орба:
##  - орб внутри build_radius от _deploy_anchor И лагерь DEPLOYED И Harvester
##    жив → летит к Harvester'у (визуально орбы сходятся к буровой);
##  - иначе → летит к Tower (она движется, орб её преследует и доезжает с ней
##    обратно в лагерь, где уже зачислится через arrival).
## Может вернуть null если ни Harvester'а, ни Tower'а нет — XpOrb на null-target
## queue_free'ится без кредита.
func get_xp_magnet_target(orb_position: Vector3) -> Node3D:
	if _state == State.DEPLOYED and _harvester != null and is_instance_valid(_harvester):
		var dx: float = orb_position.x - _deploy_anchor.x
		var dz: float = orb_position.z - _deploy_anchor.z
		if dx * dx + dz * dz <= build_radius * build_radius:
			return _harvester
	return _tower


## Регистрация гнома в цепочке-каравана как нового хвостового звена. Вызывается
## из Gnome.enter_following_caravan. Идемпотентна (повторный register тот же
## гном не дублирует). Слот = индекс в массиве, считается лениво в
## get_chain_target_for_follower.
func register_caravan_follower(g: Gnome) -> void:
	if g != null and not _caravan_followers.has(g):
		_caravan_followers.append(g)


## Считает гномов, у которых указанная палатка — _home_tent. Сравнивается с
## CampPart.gnomes_per_tent для определения вакансий: бездомные гномы из
## цепочки могут «заселиться» в палатку с occupancy < capacity. Сложность
## O(N_gnomes) на вызов — но Gnome._tick_following_caravan вызывает редко
## (раз в ~1с с jitter'ом), не на каждом физкадре.
func get_tent_occupancy(tent: CampPart) -> int:
	var n := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g.get_home_tent() == tent:
			n += 1
	return n


## Ищет ближайшую к гному живую non-torn / non-in-hand палатку, где есть
## свободное место (occupancy < gnomes_per_tent). Возвращает null если
## вакансий нет — гном остаётся в FOLLOWING_CARAVAN и продолжает идти за
## караваном. Не учитывает дистанцию-cap: даже далёкая палатка с местом
## лучше, чем пешее путешествие за башней навечно.
##
## В PACKING_RETURNING вакансии не выдаём: иначе гном, только что
## переведённый в FOLLOWING_CARAVAN из-за свёртки, тут же займёт место в
## палатке → state RETURNING_TO_TENT → _all_gnomes_home false → pack ждёт
## его прибытия. Во время свёртки все out-of-tent гномы должны оставаться
## в колонне.
func find_tent_with_vacancy_for(g: Gnome) -> CampPart:
	if _state == State.PACKING_RETURNING:
		return null
	var best: CampPart = null
	var best_dist_sq := INF
	var g_pos := g.global_position
	for part in _parts:
		if not is_instance_valid(part) or not (part is CampPart):
			continue
		var cp := part as CampPart
		if cp.is_torn_off() or cp.is_in_hand():
			continue
		if get_tent_occupancy(cp) >= cp.gnomes_per_tent:
			continue
		var d_sq := cp.global_position.distance_squared_to(g_pos)
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			best = cp
	return best


## Снятие гнома с цепочки. Вызывается из Gnome.take_damage при смерти.
## После erase индексы оставшихся followers сдвигаются — их слоты становятся
## ближе к палаткам в следующем кадре. Это естественно: умер передний — задний
## подтянулся. Стабильность порядка между смертями сохраняется.
func unregister_caravan_follower(g: Gnome) -> void:
	_caravan_followers.erase(g)


## Позиция-цель в цепочке для гнома-follower'а. Цепочка звеньев:
##   tower → active tents (по _parts, skip torn_off/in_hand/outside_caravan)
##         → followers (по _caravan_followers, до slot-1)
## Target = leader.pos - dir × gap + perp × side + dir × forward, где dir =
## (leader.pos − me).normalized(), perp — горизонтальная нормаль к dir.
## Per-гном random side/forward (g.get_caravan_chain_offset()) делает строй
## не ниткой, а полосой шириной gnome_chain_jitter×2 с раздёрганным gap.
##
## Gap считается plотным `gnome_chain_gap` (меньше tent-gap), чтобы гномы
## шли тесной толпой, а не редкой очередью.
##
## В DEPLOYED-режиме цепочка не имеет смысла (палатки в кольце) — возвращаем
## позицию башни, чтобы гном просто шёл к ней.
func get_chain_target_for_follower(g: Gnome) -> Vector3:
	if _tower == null:
		return global_position
	if _state != State.CARAVAN_FOLLOWING:
		return _tower.global_position
	var slot := _caravan_followers.find(g)
	if slot < 0:
		return _tower.global_position
	var leader_pos := _last_chain_link_before_follower(slot)
	var to_leader := leader_pos - g.global_position
	to_leader.y = 0.0
	if to_leader.length_squared() < VecUtil.EPSILON_SQ:
		return g.global_position
	var dir := to_leader.normalized()
	var offset: Vector2 = g.get_caravan_chain_offset()
	# perp: 90° поворот dir на Y-плоскости (правая сторона относительно
	# направления к лидеру). offset.x ± этой нормали → разлёт по бокам.
	var perp := Vector3(dir.z, 0.0, -dir.x)
	# offset.y > 0 → ближе к лидеру (target смещается на +dir), < 0 — дальше.
	# Сжимаем в [−1, 1] × gnome_chain_gap × variance, чтобы reasonable bound.
	var forward_shift: float = clampf(offset.y, -1.0, 1.0) * gnome_chain_gap * gnome_chain_gap_variance
	var side_shift: float = clampf(offset.x, -1.0, 1.0) * gnome_chain_jitter
	return leader_pos - dir * gnome_chain_gap + dir * forward_shift + perp * side_shift


## Позиция предыдущего звена для follower'а с указанным slot-индексом. Сначала
## ищем в followers (от slot-1 вниз), беря первый is_instance_valid. Если все
## впереди-стоящие followers невалидны — спускаемся к последней активной
## палатке. Если палаток в строю нет — лидер = башня.
func _last_chain_link_before_follower(follower_slot: int) -> Vector3:
	for i in range(follower_slot - 1, -1, -1):
		var prev := _caravan_followers[i]
		if is_instance_valid(prev):
			return prev.global_position
	for i in range(_parts.size() - 1, -1, -1):
		var part := _parts[i]
		if not is_instance_valid(part):
			continue
		if part is CampPart:
			var cp := part as CampPart
			if not cp.is_in_caravan() or cp.is_in_hand():
				continue
		return part.global_position
	return _tower.global_position


## Уведомление от CampPart, что её только что аккуратно поставили рукой
## (тихий release без impulse). Логика зависит от состояния лагеря:
##
## **CARAVAN_FOLLOWING**: zone-snap. В зоне → `_reorder_parts_by_position`
## вставляет палатку в новый слот строя. Вне зоны → mark_outside_caravan,
## стоит на месте до следующего pickup. Зона проверяется однократно здесь,
## не каждый кадр в follow (баг 2026-05-04: «выбивает четвёртую»).
##
## **DEPLOYED / PACKING_RETURNING**: free-placement. Палатка остаётся ровно
## там, где её опустили — никакого snap'а в ring-слот. Это даёт игроку
## свободу перестраивать лагерь под местность. На _finalize_pack Camp
## вернёт все палатки в строй через restore_to_caravan + reorder.
func notify_part_settled(part: CampPart) -> void:
	if _state == State.DEPLOYED or _state == State.PACKING_RETURNING:
		part.mark_outside_caravan()
		if debug_log and LogConfig.master_enabled:
			print("[Camp] %s оставлена в лагере на свободном месте" % part.name)
		return
	var leader_pos := _leader_pos_for_zone()
	var zone_sq := placement_zone_radius * placement_zone_radius
	if (part.global_position - leader_pos).length_squared() > zone_sq:
		part.mark_outside_caravan()
		if debug_log and LogConfig.master_enabled:
			print("[Camp] %s оставлена вне зоны (dist > %.1f), стоит вне строя" % [part.name, placement_zone_radius])
		return
	_reorder_parts_by_position()


## Leader-позиция для зоны установки и follow-фильтра. CARAVAN — башня,
## DEPLOYED/PACKING — anchor.
func _leader_pos_for_zone() -> Vector3:
	if _state == State.CARAVAN_FOLLOWING and _tower != null:
		return _tower.global_position
	return _deploy_anchor


## Сортирует _parts по distance до leader'а. Палатки в строю (is_in_caravan)
## впереди, torn_off / outside_caravan — в конце (Camp их всё равно skip'ает
## в follow). _deployed_targets перестраиваются под новое количество
## активных палаток в DEPLOYED-режимах.
func _reorder_parts_by_position() -> void:
	var leader_pos: Vector3 = _leader_pos_for_zone()
	_parts.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		var a_active := not (a is CampPart) or (a as CampPart).is_in_caravan()
		var b_active := not (b is CampPart) or (b as CampPart).is_in_caravan()
		if a_active != b_active:
			# Активные впереди (true перед false в sort_custom).
			return a_active
		return a.global_position.distance_squared_to(leader_pos) < b.global_position.distance_squared_to(leader_pos)
	)
	if _state == State.DEPLOYED or _state == State.PACKING_RETURNING:
		_rebuild_deployed_targets()


## Пересчитывает _deployed_targets[i] под текущий порядок _parts. Считаем
## количество активных (не torn_off) палаток как N, делим круг на N
## секторов и расставляем targets по углам. Torn_off палатки не получают
## target — они всё равно skip'аются в _update_deployed.
func _rebuild_deployed_targets() -> void:
	_deployed_targets.clear()
	var active_count := 0
	for part in _parts:
		if part is CampPart and not (part as CampPart).is_in_caravan():
			continue
		active_count += 1
	if active_count == 0:
		return
	var idx := 0
	for part in _parts:
		if part is CampPart and not (part as CampPart).is_in_caravan():
			# Placeholder — _update_deployed skip'ает по индексу, i должен
			# совпадать с _parts. Используем текущую позицию палатки.
			_deployed_targets.append(part.global_position)
			continue
		var angle := float(idx) * TAU / float(active_count)
		var part_y: float = part.global_position.y
		_deployed_targets.append(Vector3(
			_deploy_anchor.x + cos(angle) * deploy_radius,
			part_y,
			_deploy_anchor.z + sin(angle) * deploy_radius,
		))
		idx += 1


## Считает живых гномов-собирателей (исключая защитников). Используется HUD'ом.
func gatherer_count() -> int:
	# Gatherer = гном НЕ в DEFENDER_GROUP и НЕ в SOLDIER_GROUP. Defender'ы
	# привязаны к палатке и не собирают; soldier'ы мобилизованы через recruit
	# и тоже не собирают.
	var n := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g.is_in_group(DefenderGnome.DEFENDER_GROUP):
			continue
		if g.is_in_group(SoldierGnome.SOLDIER_GROUP):
			continue
		n += 1
	return n


## Считает живых гномов-защитников (DefenderGnome).
func defender_count() -> int:
	var n := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g.is_in_group(DefenderGnome.DEFENDER_GROUP):
			n += 1
	return n


## Считает защитников, назначенных на DefenseMarker (формация). Используется
## HUD'ом для отображения «в строю: M» — игрок понимает, сколько ещё свободно
## под новый маркер (каждое «На защиту» забирает 3 ближайших свободных).
func defenders_in_formation_count() -> int:
	var n := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		var def := g as DefenderGnome
		if def == null:
			continue
		if def.is_in_formation_slot():
			n += 1
	return n


## Считает живых солдат заданного типа (или всех если type_filter == &"").
## Используется UI журнала (вкладка «Армия») и squad-системой.
func soldier_count(type_filter: StringName = &"") -> int:
	var n := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if not g.is_in_group(SoldierGnome.SOLDIER_GROUP):
			continue
		if type_filter == &"":
			n += 1
		else:
			var s := g as SoldierGnome
			if s != null and s.soldier_type == type_filter:
				n += 1
	return n


## Публичный геттер halted-флага. HUD/Journal могут читать для индикатора.
func is_caravan_halted() -> bool:
	return _caravan_halted


## Публичный setter — переключает «остановку» каравана. Безопасен в любом
## состоянии: вне CARAVAN_FOLLOWING вызов no-op (флаг можно ставить в true,
## но `_update_caravan_follow` для других стейтов и не вызывается). Идемпотентен.
func set_caravan_halted(value: bool) -> void:
	if _caravan_halted == value:
		return
	_caravan_halted = value
	if debug_log and LogConfig.master_enabled:
		print("[Camp] караван %s" % ("остановлен" if value else "снова в пути"))


## Считает живые палатки. «Уровень лагеря» в HUD = это число.
func tent_count_alive() -> int:
	var n := 0
	for p in _parts:
		if is_instance_valid(p):
			n += 1
	return n


## Реальный центр лагеря для расчётов на стороне (например WaveDirector
## смотрит безопасную зону вокруг лагеря). global_position самого узла Camp
## **не двигается** когда игрок ведёт Tower — двигаются только дочерние
## палатки. Поэтому центр считаем как среднее живых палаток. Если палаток
## не осталось — fallback на tower.global_position (caravan следует за
## башней) или собственную позицию узла.
func current_center() -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for part in _parts:
		if not is_instance_valid(part):
			continue
		sum += part.global_position
		n += 1
	if n > 0:
		return sum / float(n)
	if _tower != null:
		return _tower.global_position
	return global_position


## Ближайшая живая палатка к точке. WaveDirector использует для назначения
## aggro-цели волне: 10 скелетов получают forced_target = эту палатку.
## Возвращает null если все палатки разрушены — лагерь больше не валидная
## цель, и вся волна идёт мимо. Оторванные (torn_off) палатки не считаются
## легитимной целью каравана — волна идёт на стационарные палатки лагеря.
func nearest_part_to(pos: Vector3) -> Node3D:
	var nearest: Node3D = null
	var nearest_dist_sq := INF
	for part in _parts:
		if not is_instance_valid(part):
			continue
		if part is CampPart and (part as CampPart).is_torn_off():
			continue
		var d_sq: float = (part.global_position - pos).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = part
	return nearest


## True если у лагеря есть хотя бы одна живая палатка — иначе он больше не
## валидная цель (все палатки разрушены).
func has_alive_parts() -> bool:
	for part in _parts:
		if is_instance_valid(part):
			return true
	return false


## --- Squad XP / upgrades ---

## Добавляет XP отряду (этап 49 — заменяет старый `credit_kill`). Зовётся из
## `XpOrb.MAGNETIZED → arrival`: орб коснулся anchor'а, кредит зачислен.
## Старая модель «стрелок шлёт credit при kill» удалена — XP теперь приходит
## через осязаемый объект-орб, который игрок видит на земле.
##
## Накручивает `_squad_xp`, проверяет уровни, эмитит сигналы.
##
## `at_position` — мировая координата прибытия орба (для popup'а «+N»).
## Используем именно её, а не позицию трупа — иначе popup появлялся бы там,
## где скелет умер, а не там, где собрался XP. Связь действия и feedback'а
## должна совпадать с положением игрока внимания: караван собрал → popup
## над караваном.
##
## Идемпотентность по «уровень за один XP-инкремент»: while-цикл на случай
## большого инкремента (например орб-bonus, если когда-нибудь появится).
func add_squad_xp(amount: int, at_position: Vector3 = Vector3.ZERO) -> void:
	if amount <= 0:
		return
	_squad_xp += amount
	# Popup-сигнал ПЕРВЫМ — слушатели всплывашки получают сырое значение
	# инкремента, ещё до bar-обновления.
	EventBus.squad_xp_gained_at.emit(amount, at_position)
	EventBus.squad_xp_changed.emit(_squad_xp, _squad_level)
	while _squad_level < squad_level_xp_curve.size() and _squad_xp >= squad_level_xp_curve[_squad_level]:
		_squad_level += 1
		_pending_upgrade_choices += 1
		if debug_log and LogConfig.master_enabled:
			print("[Camp:Squad] уровень %d достигнут (XP=%d, в очереди выбор: %d)" % [_squad_level, _squad_xp, _pending_upgrade_choices])
		EventBus.squad_leveled_up.emit(_squad_level)
		EventBus.pending_upgrade_choices_changed.emit(_pending_upgrade_choices)


## True если отряд получил указанный апгрейд. Используется DefenderGnome'ом
## для гейтинга поведения (kiting, long_draw — см. UPGRADE_CATALOG).
func has_upgrade(id: StringName) -> bool:
	return _active_upgrades.has(id)


## Игрок выбрал апгрейд из модала. Идемпотентно: повторный grant того же id
## не дублирует. Уменьшает счётчик ожидающих выборов; если ещё есть pending
## уровни без выбора — модал должен подхватить и показаться снова.
func grant_upgrade(id: StringName) -> void:
	if has_upgrade(id):
		return
	if not UPGRADE_CATALOG.has(id):
		push_warning("Camp.grant_upgrade: неизвестный id %s" % id)
		return
	_active_upgrades.append(id)
	_pending_upgrade_choices = max(0, _pending_upgrade_choices - 1)
	if debug_log and LogConfig.master_enabled:
		print("[Camp:Squad] апгрейд %s применён" % id)
	EventBus.squad_upgrade_granted.emit(id)
	EventBus.pending_upgrade_choices_changed.emit(_pending_upgrade_choices)


## Список апгрейдов, ещё не выбранных отрядом. Модал использует чтобы
## показать карточки (берёт первые 2 случайных из этого списка).
func available_upgrades() -> Array[StringName]:
	var result: Array[StringName] = []
	for id in UPGRADE_CATALOG.keys():
		if not has_upgrade(id):
			result.append(id)
	return result


## --- Soldiers / Squads (мобилизация gatherer'ов) ---

## Найти до `count` gatherer'ов для мобилизации. Сначала IN_TENT (отдыхающие —
## не отрывают таскающего груз), потом любых остальных. Возвращает массив
## фактически найденных (может быть короче запрошенного count'а — caller
## сам решает что делать).
func _find_idle_gatherers(count: int) -> Array[Gnome]:
	var found: Array[Gnome] = []
	if count <= 0:
		return found
	# Первый проход — приоритет IN_TENT
	for g in _gnomes:
		if found.size() >= count:
			break
		if not is_instance_valid(g):
			continue
		if g.is_in_group(DefenderGnome.DEFENDER_GROUP):
			continue
		if g.is_in_group(SoldierGnome.SOLDIER_GROUP):
			continue
		if g._state == Gnome.State.IN_TENT:
			found.append(g)
	# Второй проход — добираем любыми остальными
	if found.size() < count:
		for g in _gnomes:
			if found.size() >= count:
				break
			if not is_instance_valid(g):
				continue
			if g.is_in_group(DefenderGnome.DEFENDER_GROUP):
				continue
			if g.is_in_group(SoldierGnome.SOLDIER_GROUP):
				continue
			if found.has(g):
				continue
			found.append(g)
	return found


## Минимум gatherer'ов, которых лагерь оставляет себе при призыве — по одному
## на каждую живую палатку. Дизайнерское правило: армию строим излишком, нельзя
## опустошить лагерь и оставить экономику без сборщиков. UI расшифровывает
## нехватку через `get_recruit_reserve()`.
const RECRUIT_RESERVE_PER_TENT: int = 1


## Сколько gatherer'ов должно остаться в лагере после любого призыва —
## зависит от числа живых палаток. Падает до 0 если все палатки разрушены
## (лагерь всё равно не recruit-валиден в этом случае, но getter честный).
func get_recruit_reserve() -> int:
	return tent_count_alive() * RECRUIT_RESERVE_PER_TENT


## True если игрок может прямо сейчас призвать отряд заданного типа:
## - лагерь развёрнут (recruit — лагерное действие, симметрично dismiss)
## - id есть в SoldierSystem.SOLDIER_CATALOG
## - в лагере свободных gatherer'ов >= squad_size + reserve (по 1 на палатку)
## - на складе хватает ресурсов на cost
## Используется UI журнала для disabled-состояния кнопки.
func can_recruit_squad(soldier_type: StringName) -> bool:
	if SoldierSystem == null:
		return false
	if not is_deployed():
		return false
	var data: Dictionary = SoldierSystem.get_soldier_data(soldier_type)
	if data.is_empty():
		return false
	if not economy.can_afford(data.get("cost", {})):
		return false
	var squad_size: int = SoldierSystem.get_squad_size(soldier_type)
	return gatherer_count() >= squad_size + get_recruit_reserve()


## Призвать отряд заданного типа. Создаёт Squad-объект и заполняет его
## squad_size солдатами. Каждый солдат — конвертированный gatherer.
## Возвращает Squad или null при провале.
##
## Диспатч по gnome_class из каталога: &"defender" → DefenderGnome flow
## (без Squad, round-robin по палаткам), иначе → SoldierGnome flow (Squad).
func recruit_squad(soldier_type: StringName) -> Squad:
	if SoldierSystem == null:
		return null
	if not is_deployed():
		# Защита от UI-обхода/гонки. Recruit — лагерное действие, в каравне
		# юниты появляться из ниоткуда не должны (как и dismiss'ить нельзя).
		return null
	var data: Dictionary = SoldierSystem.get_soldier_data(soldier_type)
	if data.is_empty():
		push_warning("Camp.recruit_squad: неизвестный тип %s" % soldier_type)
		return null
	if data.get("gnome_class", &"") == &"defender":
		_recruit_defenders(soldier_type, data)
		# Defender-flow не возвращает Squad — defender'ы присоединяются к
		# общему пулу (DEFENDER_GROUP), не группируются как отряд.
		return null
	var cost: Dictionary = data.get("cost", {})
	if not economy.can_afford(cost):
		return null
	var squad_size: int = SoldierSystem.get_squad_size(soldier_type)
	# Дублируем reserve-чек: UI должен был отфильтровать, но если recruit_squad
	# вызвали мимо (читы / горячая клавиша / гонка) — гейт здесь же.
	if gatherer_count() < squad_size + get_recruit_reserve():
		return null
	var gatherers: Array[Gnome] = _find_idle_gatherers(squad_size)
	if gatherers.size() < squad_size:
		return null
	var scene: PackedScene = data.get("scene", null)
	if scene == null:
		push_error("Camp.recruit_squad: scene не задан в каталоге для %s" % soldier_type)
		return null
	# Списываем cost атомарно. После economy.try_spend rollback — через
	# economy.add_resource если что-то пойдёт не так дальше (instantiate'ы провалятся).
	if not economy.try_spend(cost):
		return null

	# Создаём Squad-объект ДО спавна солдат — каждый soldier при setup_soldier
	# получит ссылку через squad.add_member.
	var squad := Squad.new()
	squad.id = _next_squad_id
	_next_squad_id += 1
	squad.soldier_type = soldier_type
	squad.icon_color = data.get("icon_color", Color.WHITE)
	# Дефолтная команда: HOLDING_POSITION на центре gatherers'ов — там, где
	# их позвали. Игрок получает «5 лучников стоят и стреляют», без сюрпризов.
	var center: Vector3 = Vector3.ZERO
	for g in gatherers:
		center += g.global_position
	center /= float(gatherers.size())
	squad.command_hold(center)

	var stats: Dictionary = data.get("stats", {})
	var spawned: int = 0
	for gatherer in gatherers:
		var soldier := scene.instantiate() as SoldierGnome
		if soldier == null:
			push_error("Camp.recruit_squad: scene не инстанцируется как SoldierGnome")
			continue
		add_child(soldier)
		soldier.setup_soldier(soldier_type, stats, self, gatherer.global_position)
		_gnomes.erase(gatherer)
		gatherer.queue_free()
		_gnomes.append(soldier)
		squad.add_member(soldier)
		spawned += 1

	if spawned == 0:
		# Полный провал спавна — возвращаем cost.
		for type in cost:
			economy.add_resource(type, int(cost[type]))
		return null

	# Регистрируем squad. Подписка на disbanded — сами убираемся когда все
	# юниты погибли.
	squad.charge_max = float(data.get("charge_max", squad.charge_max))
	_squads.append(squad)
	squad.disbanded.connect(_on_squad_disbanded.bind(squad), CONNECT_ONE_SHOT)
	squad.members_changed.connect(_on_squad_changed.bind(squad))
	squad.state_changed.connect(_on_squad_changed.bind(squad))
	_spawn_squad_charge_marker(squad)

	if debug_log and LogConfig.master_enabled:
		print("[Camp] призван %s, gatherer'ов: %d, солдат: %d" % [str(squad), gatherer_count(), soldier_count()])
	EventBus.camp_buildings_changed.emit()
	EventBus.squad_created.emit(squad)
	return squad


## Defender-вариант рекрута: конвертит N gatherer'ов в N DefenderGnome'ов и
## распределяет их round-robin по живым палаткам. В отличие от SoldierGnome-
## flow не создаёт Squad-объект — защитники работают индивидуально через
## tent-привязку, DEFENDER_GROUP и AI (cone-vision/bell-alarm/DefenseMarker).
##
## Все гейты (deployed, can_afford, gatherer_count + reserve) валидируются
## здесь же — мимо UI вызов (читы/гонка) безопасен. На любой ошибке после
## economy.try_spend — rollback ресурсов через economy.add_resource.
func _recruit_defenders(soldier_type: StringName, data: Dictionary) -> void:
	var cost: Dictionary = data.get("cost", {})
	if not economy.can_afford(cost):
		return
	var squad_size: int = SoldierSystem.get_squad_size(soldier_type)
	if gatherer_count() < squad_size + get_recruit_reserve():
		return
	var gatherers: Array[Gnome] = _find_idle_gatherers(squad_size)
	if gatherers.size() < squad_size:
		return
	var scene: PackedScene = data.get("scene", null)
	if scene == null:
		push_error("Camp._recruit_defenders: scene не задан в каталоге для %s" % soldier_type)
		return
	# Список живых палаток — round-robin'им новых защитников между ними,
	# чтобы периметр рос равномерно. Если все палатки умерли (но gatherer'ы
	# почему-то ещё есть) — призыв отменяется: бездомных защитников не плодим.
	var tents: Array = []
	for p in _parts:
		if is_instance_valid(p):
			tents.append(p)
	if tents.is_empty():
		return
	if not economy.try_spend(cost):
		return

	var spawned: int = 0
	for i in range(gatherers.size()):
		var gatherer: Gnome = gatherers[i]
		var tent: Node3D = tents[i % tents.size()]
		var defender := scene.instantiate() as DefenderGnome
		if defender == null:
			push_error("Camp._recruit_defenders: scene не инстанцируется как DefenderGnome")
			continue
		add_child(defender)
		defender.global_position = gatherer.global_position
		defender.setup(self, tent)
		# КРИТИЧНО: setup() через override _enter_in_tent гонит DefenderGnome'а
		# в FOLLOWING_CARAVAN — там _active_tick идёт в caravan-ветку и
		# игнорирует _assigned_marker. Без enter_deployed() рекрутированный
		# защитник назначался в формацию, но не шёл на слот.
		# Рекрут гейтится is_deployed(), поэтому enter_deployed безопасен.
		defender.enter_deployed()
		defender.destroyed.connect(_on_gnome_destroyed.bind(defender))
		_gnomes.erase(gatherer)
		gatherer.queue_free()
		_gnomes.append(defender)
		spawned += 1

	if spawned == 0:
		# Все instantiate'ы провалились — rollback cost'а.
		for type in cost:
			economy.add_resource(type, int(cost[type]))
		return

	if debug_log and LogConfig.master_enabled:
		print("[Camp] призваны защитники (×%d), всего: %d" % [spawned, defender_count()])
	EventBus.camp_buildings_changed.emit()


## Размер «партии» расформирования защитников. Симметрично squad_size при
## рекруте (3 = 1 squad). UI-кнопка «Расформировать» отзывает столько за клик.
const DEFENDER_DISBAND_BATCH: int = 3
## Доля возврата ресурсов рекрута при расформировании. 0.5 = половина wood/iron
## возвращается на склад. Дизайнерское решение (2026-05-15): рекрут не должен
## быть «безответным» — игрок боится тратить gnome'ов на дорогих защитников,
## если их нельзя откатить. 50% — компромисс: возврат есть, но потеря
## ощутимая (нельзя бесконечно туда-сюда оптимизировать).
const DEFENDER_DISBAND_REFUND_RATIO: float = 0.5


## True если игрок может прямо сейчас расформировать защитника (кнопка
## активна). Достаточно одного защитника — расформируем сколько есть.
## Лагерь должен быть DEPLOYED — конвертация в gatherer'а без палатки
## бессмысленна.
func can_disband_defenders() -> bool:
	return is_deployed() and defender_count() > 0


## Расформировать партию защитников: до DEFENDER_DISBAND_BATCH ближайших к
## центру лагеря конвертируются обратно в gatherer'ов. Если защитник был на
## маркере или отвечал на колокол — освобождаем перед конвертацией.
##
## Приоритет: сначала свободные (не в формации), потом из формации. Игрок
## таким образом сохраняет активную защиту, расформировывая «лишних».
##
## Refund: 50% от cost рекрута, пропорционально числу расформированных.
## Для 3 защитников из cost {WOOD:6, IRON:4} возвращается 3 wood + 2 iron.
## Возвращает количество расформированных (0 если кнопку нажали мимо гейта).
func disband_defender_squad() -> int:
	if not can_disband_defenders():
		return 0
	# Собираем кандидатов; сортируем сначала по «не в формации», потом по
	# дистанции до anchor'а. Так первые 3 — это «свободные ближайшие», что
	# минимально ломает текущую оборону.
	var candidates: Array[DefenderGnome] = []
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		var def := g as DefenderGnome
		if def != null:
			candidates.append(def)
	if candidates.is_empty():
		return 0
	var center: Vector3 = _deploy_anchor
	candidates.sort_custom(func(a: DefenderGnome, b: DefenderGnome) -> bool:
		var a_in: bool = a.is_in_formation_slot()
		var b_in: bool = b.is_in_formation_slot()
		if a_in != b_in:
			return not a_in  # не-в-формации идут первыми
		var da: float = (Vector3(a.global_position.x, center.y, a.global_position.z) - center).length_squared()
		var db: float = (Vector3(b.global_position.x, center.y, b.global_position.z) - center).length_squared()
		return da < db
	)
	var n: int = mini(candidates.size(), DEFENDER_DISBAND_BATCH)
	var converted: int = 0
	for i in range(n):
		var def: DefenderGnome = candidates[i]
		if not is_instance_valid(def):
			continue
		# Отвязка от маркера/колокола обязательна — иначе после queue_free
		# у маркера останется висячая ссылка через slot_idx, у колокола —
		# зачёт «отвечает». release_*_from_* идемпотентны (no-op если не
		# был назначен), безопасны для unconditional-вызова.
		def.release_from_marker()
		def.release_from_bell()
		var pos: Vector3 = def.global_position
		var tent: CampPart = _pick_tent_for_new_gatherer()
		if tent == null:
			continue
		var gatherer := _spawn_one_gnome(gnome_scene, tent, "gatherer")
		if gatherer != null:
			gatherer.global_position = pos
			# В DEPLOYED — сразу выходим в SEARCHING (симметрично dismiss_squad).
			# Без этого новый gatherer сидел бы IN_TENT и не работал бы.
			if _state == State.DEPLOYED:
				gatherer.enter_deployed()
		_gnomes.erase(def)
		def.queue_free()
		converted += 1

	# Refund пропорционально converted. Округление floor — игрок не получает
	# за остатки (1 защитник: 6×0.5×1/3 = 1 wood, 4×0.5×1/3 = 0.67 → 0 iron).
	if converted > 0 and SoldierSystem != null:
		var data: Dictionary = SoldierSystem.get_soldier_data(&"defender")
		var cost: Dictionary = data.get("cost", {})
		var squad_size: int = SoldierSystem.get_squad_size(&"defender")
		if squad_size > 0:
			for type in cost:
				var refund_amt: int = int(float(cost[type]) * DEFENDER_DISBAND_REFUND_RATIO * float(converted) / float(squad_size))
				if refund_amt > 0:
					economy.add_resource(type, refund_amt)

	if debug_log and LogConfig.master_enabled:
		print("[Camp] расформированы защитники (×%d), осталось: %d" % [converted, defender_count()])
	EventBus.camp_buildings_changed.emit()
	return converted


## Сколько юнитов указанного типа сейчас в лагере. Универсальный геттер для
## UI журнала: для defender-каталога считает defender_count(), для остальных —
## soldier_count(id). Без него UI пришлось бы branch'ить по gnome_class в
## журнале — а это деталь реализации каталога, журнал не должен в неё лезть.
func get_recruit_count(soldier_type: StringName) -> int:
	if SoldierSystem == null:
		return 0
	var data: Dictionary = SoldierSystem.get_soldier_data(soldier_type)
	if data.is_empty():
		return 0
	if data.get("gnome_class", &"") == &"defender":
		return defender_count()
	return soldier_count(soldier_type)


## Дебаг-чит: спавнит отряд указанного типа МИМО всех ограничений
## (deployed-чек, наличие gatherer'ов, cost ресурсов). Юниты появляются
## кольцом ~2м вокруг центра лагеря (anchor если развёрнут, иначе башня).
## Вызывается из JournalPanel → «Читы». Возвращает null если тип
## неизвестен или scene не инстанцируется.
func cheat_summon_squad(soldier_type: StringName) -> Squad:
	if SoldierSystem == null:
		return null
	var data: Dictionary = SoldierSystem.get_soldier_data(soldier_type)
	if data.is_empty():
		push_warning("Camp.cheat_summon_squad: неизвестный тип %s" % soldier_type)
		return null
	var scene: PackedScene = data.get("scene", null)
	if scene == null:
		push_error("Camp.cheat_summon_squad: scene не задан в каталоге для %s" % soldier_type)
		return null
	var squad_size: int = SoldierSystem.get_squad_size(soldier_type)
	# X/Z — логический центр (anchor / башня / лагерь). Y — берём от самого
	# Camp'а: он на земле, в отличие от Tower (origin ~3м над землёй) или
	# anchor'а (наследует POI/tower y, тоже может висеть). Иначе юниты
	# спавнились бы в воздухе и никуда не падали — squad-positioning
	# управляет только X/Z, гравитация без принудительного velocity.y не
	# подтянет вниз.
	var raw_center: Vector3 = _deploy_anchor if _state == State.DEPLOYED else (
		_tower.global_position if is_instance_valid(_tower) else global_position
	)
	var center := Vector3(raw_center.x, global_position.y, raw_center.z)

	var squad := Squad.new()
	squad.id = _next_squad_id
	_next_squad_id += 1
	squad.soldier_type = soldier_type
	squad.icon_color = data.get("icon_color", Color.WHITE)
	squad.command_hold(center)

	var stats: Dictionary = data.get("stats", {})
	var spawned: int = 0
	for i in range(squad_size):
		var soldier := scene.instantiate() as SoldierGnome
		if soldier == null:
			push_error("Camp.cheat_summon_squad: scene не инстанцируется как SoldierGnome")
			continue
		# Спавн кольцом ~2м вокруг центра — чтобы не наслаивались в одной точке.
		var angle: float = TAU * float(i) / float(squad_size)
		var spawn_pos: Vector3 = center + Vector3(cos(angle) * 2.0, 0.0, sin(angle) * 2.0)
		add_child(soldier)
		soldier.setup_soldier(soldier_type, stats, self, spawn_pos)
		_gnomes.append(soldier)
		squad.add_member(soldier)
		spawned += 1

	if spawned == 0:
		return null

	squad.charge_max = float(data.get("charge_max", squad.charge_max))
	_squads.append(squad)
	squad.disbanded.connect(_on_squad_disbanded.bind(squad), CONNECT_ONE_SHOT)
	squad.members_changed.connect(_on_squad_changed.bind(squad))
	squad.state_changed.connect(_on_squad_changed.bind(squad))
	_spawn_squad_charge_marker(squad)

	if debug_log and LogConfig.master_enabled:
		print("[Camp] CHEAT: призван %s (×%d) у центра (%.1f, %.1f, %.1f)" % [
			str(squad), spawned, center.x, center.y, center.z,
		])
	EventBus.camp_buildings_changed.emit()
	EventBus.squad_created.emit(squad)
	return squad


func _on_squad_disbanded(squad: Squad) -> void:
	_squads.erase(squad)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] отряд %s распущен (все погибли)" % str(squad))
	EventBus.squad_disbanded.emit(squad)


func _on_squad_changed(squad: Squad) -> void:
	EventBus.squad_changed.emit(squad)


## Спавнит [SquadChargeMarker] над центром только что созданного отряда.
## Маркер сам подписывается на squad.charge_changed / disbanded — Camp его
## дальше не отслеживает. Лежит как ребёнок current_scene'а: лагерь не
## должен таскать маркер при свёртке/деплое (отряд — самостоятельная
## RTS-сущность, маркер летает за ним по миру).
func _spawn_squad_charge_marker(squad: Squad) -> void:
	if squad == null:
		return
	var scene_root: Node = get_tree().current_scene
	if not is_instance_valid(scene_root):
		return
	var marker := SquadChargeMarker.new()
	marker.name = "SquadChargeMarker_%d" % squad.id
	scene_root.add_child(marker)
	marker.setup(squad)


## Все активные squad'ы. UI читает для построения панели карточек.
func get_squads() -> Array[Squad]:
	return _squads


## Команда: указать squad'у удерживать точку. UI зовёт когда игрок
## завершил attack-aim (ПКМ в нужной точке).
func command_squad_hold(squad: Squad, pos: Vector3) -> void:
	if squad == null:
		return
	if not _squads.has(squad):
		return
	squad.command_hold(pos)


## Команда: squad переходит в эскорт-режим (следует за башней).
func command_squad_escort(squad: Squad) -> void:
	if squad == null:
		return
	if not _squads.has(squad):
		return
	squad.command_escort()


## Команда: squad защищает лагерь (кольцо вокруг anchor'а). Доп. слой обороны
## поверх штатных DefenderGnome'ов. Доступна и в каравне, но визуально юниты
## пойдут к башне (fallback в SoldierGnome._resolve_squad_center).
func command_squad_defend(squad: Squad) -> void:
	if squad == null:
		return
	if not _squads.has(squad):
		return
	squad.command_defend()


## True если ВСЕ живые члены отряда в зоне dismiss_radius от deploy_anchor.
## Дополнительно гейтит state DEPLOYED — в каравне/свёртке dismiss запрещён
## (как и recruit): призыв и размобилизация — лагерные действия. Гном-сцена
## должна быть задана (иначе конвертить нечего).
func can_dismiss_squad(squad: Squad) -> bool:
	if squad == null or not _squads.has(squad):
		return false
	if gnome_scene == null:
		return false
	if not is_deployed():
		return false
	if squad.count_alive() == 0:
		return false
	var r_sq: float = dismiss_radius * dismiss_radius
	for m in squad.members:
		if not is_instance_valid(m):
			continue
		var dx: float = m.global_position.x - _deploy_anchor.x
		var dz: float = m.global_position.z - _deploy_anchor.z
		if dx * dx + dz * dz > r_sq:
			return false
	return true


## True если лагерь сейчас развёрнут (палатки в кольце, anchor валиден).
## Используется как guard для recruit/dismiss и других «лагерных» действий.
func is_deployed() -> bool:
	return _state == State.DEPLOYED


## Распустить отряд: каждый солдат конвертируется обратно в gatherer'а на
## своей текущей позиции. Гейтится через `can_dismiss_squad` — если хоть
## один член далеко от лагеря, no-op (UI кнопка disabled заранее).
##
## Конверсия: spawn нового gatherer'а в позиции солдата → soldier.queue_free
## + erase из _gnomes. Squad disband'ится через явный `remove_member` (на
## queue_free destroyed-сигнал не фронтит, авто-чистка в squad не сработала бы).
##
## Возвращает true если хоть один солдат конвертирован.
func dismiss_squad(squad: Squad) -> bool:
	if not can_dismiss_squad(squad):
		return false
	var converted: int = 0
	for soldier in squad.members.duplicate():
		if not is_instance_valid(soldier):
			continue
		var pos: Vector3 = soldier.global_position
		var tent: CampPart = _pick_tent_for_new_gatherer()
		var gatherer := _spawn_one_gnome(gnome_scene, tent, "gatherer")
		if gatherer != null:
			gatherer.global_position = pos
			# В DEPLOYED — сразу выходим в SEARCHING, иначе сидели бы в IN_TENT.
			# В CARAVAN-фазе оставляем как есть: setup → IN_TENT → старт следующей
			# свёртки/развёртки выведет наружу нормальным путём.
			if _state == State.DEPLOYED:
				gatherer.enter_deployed()
		_gnomes.erase(soldier)
		squad.remove_member(soldier)
		soldier.queue_free()
		converted += 1
	if debug_log and LogConfig.master_enabled:
		print("[Camp] отряд %s распущен (%d солдат → gatherer)" % [str(squad), converted])
	EventBus.camp_buildings_changed.emit()
	return converted > 0


## Палатка для нового gatherer'а: первая с вакансией (occupancy < capacity);
## fallback — любая живая. Используется в dismiss_squad. Если палаток вообще
## нет (странный случай — лагерь без CampPart'ов) — null.
func _pick_tent_for_new_gatherer() -> CampPart:
	var fallback: CampPart = null
	for p in _parts:
		if not (p is CampPart):
			continue
		var part := p as CampPart
		if not is_instance_valid(part):
			continue
		if fallback == null:
			fallback = part
		if get_tent_occupancy(part) < part.gnomes_per_tent:
			return part
	return fallback


## Tower-getter для squad'ов (target_for_member использует tower_pos в эскорт-режиме).
func get_tower_position() -> Vector3:
	if is_instance_valid(_tower):
		return _tower.global_position
	return global_position


## --- Super charge (великая сила) ---

## Хендлер EventBus.enemy_damaged. amount — фактически нанесённый damage.
## 1 hp = 1 charge (clamp на max). Когда шкала впервые становится full —
## слушатели сигнала видят это и могут переключить визуал HUD'а («горит»).
func _on_enemy_damaged(_enemy: Node3D, amount: float) -> void:
	if amount <= 0.0:
		return
	add_super_charge(amount)


## Прирастает к шкале силы. Внешний путь — для случаев когда нужно начислить
## не через damage (квест-награда, чит). Damage идёт через _on_enemy_damaged.
func add_super_charge(amount: float) -> void:
	if amount <= 0.0:
		return
	var prev: float = _super_charge
	_super_charge = clampf(_super_charge + amount, 0.0, super_charge_max)
	if not is_equal_approx(prev, _super_charge):
		EventBus.super_charge_changed.emit(_super_charge, super_charge_max)


## Текущая шкала и максимум — для HUD'а / SuperSpell координатора.
func get_super_charge() -> float:
	return _super_charge


func get_super_charge_max() -> float:
	return super_charge_max


## True если шкала full и можно начать каст.
func is_super_ready() -> bool:
	return _super_charge >= super_charge_max


## Списать шкалу. После успешного каста — `consume_super_charge(super_charge_max)`
## (полное); после провала QTE — `consume_super_charge(super_charge_max * super_charge_fail_penalty)`.
func consume_super_charge(amount: float) -> void:
	if amount <= 0.0:
		return
	_super_charge = maxf(_super_charge - amount, 0.0)
	EventBus.super_charge_changed.emit(_super_charge, super_charge_max)


## Сколько уровней висят в очереди на выбор апгрейда (банк выборов).
## JournalPanel читает чтобы пересчитать бэйдж и активность кнопок «выбрать».
func get_pending_upgrade_choices() -> int:
	return _pending_upgrade_choices


func get_squad_xp() -> int:
	return _squad_xp


func get_squad_level() -> int:
	return _squad_level


## --- Resources (фаза 2 ресурсной экономики) ---

## Ресурсная экономика выделена в [CampEconomy] (scripts/camp_economy.gd):
## хранит пул, делает атомарную трату/проверку, эмитит EventBus.resources_changed.
## Один инстанс на Camp. Доступ снаружи: `camp.economy.add_resource/get_resource/
## try_spend/can_afford`. Внутри camp.gd — `economy.X` (см. рекруты/постройки).
var economy: CampEconomy = CampEconomy.new()


## --- Camp buildings (фаза 3) ---

## Проверяет, можно ли сейчас построить указанную постройку. Возвращает ""
## если можно; иначе — короткое описание причины (для UI-кнопки/тултипа).
## Ресурсный чек НЕ проверяется здесь, только условия состояния и каталога —
## цена обновляется чаще ресурсов и UI и так перерисовывается на каждом
## resources_changed; смешивать «не хватает дерева» с «нельзя пока в походе»
## плохо для UX (разные причины — разные сообщения).
func can_build_reason(id: StringName) -> String:
	var data: Dictionary = CAMP_BUILDING_CATALOG.get(id, {})
	if data.is_empty():
		return "неизвестная постройка"
	if data.get("deployed_only", false) and _state != State.DEPLOYED:
		return "только в развёрнутом лагере"
	# requires_gatherer: проверка наличия свободного gatherer'а на момент
	# вызова. Списывается уже в try_build после успешного try_spend, до
	# _apply_building — это часть «оплаты» постройки.
	if data.get("requires_gatherer", false) and _find_free_gatherer() == null:
		return "нужен 1 свободный гном"
	return ""


## True если world-точка в радиусе [build_radius] от центра развёрнутого
## лагеря. Используется HandBuildAim'ом (визуал + блок ПКМ вне зоны) и
## Camp.try_build (страховочная валидация). В свёрнутом лагере (нет
## _deploy_anchor) всегда false — постройки доступны только в DEPLOYED.
func is_in_build_zone(world_pos: Vector3) -> bool:
	if _state != State.DEPLOYED:
		return false
	var dx: float = world_pos.x - _deploy_anchor.x
	var dz: float = world_pos.z - _deploy_anchor.z
	return (dx * dx + dz * dz) <= (build_radius * build_radius)


## Текущий центр зоны строительства (для визуального индикатора). В DEPLOYED —
## _deploy_anchor; в других состояниях — Vector3.INF (sentinel «нет зоны»).
func build_zone_center() -> Vector3:
	if _state != State.DEPLOYED:
		return Vector3.INF
	return _deploy_anchor


## Ищет первого живого gatherer'а (Gnome без DEFENDER_GROUP). null если нет.
## Используется в can_build_reason / try_build для построек с требованием
## «1 гном» как часть стоимости.
func _find_free_gatherer() -> Gnome:
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g.is_in_group(DefenderGnome.DEFENDER_GROUP):
			continue
		return g
	return null


## Изымает одного gatherer'а из лагеря (queue_free). Используется как часть
## стоимости постройки. Возвращает true если изъят, false если не нашёлся.
func _consume_gatherer() -> bool:
	var g := _find_free_gatherer()
	if g == null:
		return false
	# Если гном сидел в палатке, ничего особого делать не нужно — Gnome
	# сам не подписан на палатку, queue_free убирает его из дерева, IN_TENT
	# state молча истечёт с инстансом.
	_gnomes.erase(g)
	g.queue_free()
	return true


## Атомарная попытка построить. Проверяет состояние → ресурсы → списывает →
## применяет эффект. Возвращает Dictionary {"success": bool, "reason": String}.
##
## На успехе — ресурсы списаны, эффект применён, EventBus.camp_buildings_changed
## эмитится для реактивного UI. На неудаче — ничего не меняется.
##
## Если apply падает после try_spend — это ошибка кода (push_error), ресурсы
## уже списаны и не восстанавливаются. Простой rollback пока не нужен —
## единственный handler (новая палатка) почти не падает (instantiate() мог бы
## не сработать только при null tent_scene, но это уже отлавливается на первом
## вызове в _ready).
func try_build(id: StringName, params: Dictionary = {}) -> Dictionary:
	var reason := can_build_reason(id)
	if reason != "":
		return {"success": false, "reason": reason}
	var data: Dictionary = CAMP_BUILDING_CATALOG.get(id, {})
	var cost: Dictionary = data.get("cost", {})
	if not economy.can_afford(cost):
		return {"success": false, "reason": "не хватает ресурсов"}
	if not economy.try_spend(cost):
		# Race с другим вызовом try_build в один кадр — теоретически возможно,
		# фактически в одном потоке нет; страхуем чтобы не разойтись с can_afford.
		return {"success": false, "reason": "не хватает ресурсов"}
	# Гном-стоимость списывается ПОСЛЕ ресурсов, ПЕРЕД apply'ем. Если до сюда
	# дошли, can_build_reason уже проверил _find_free_gatherer — но между
	# can_build_reason и сюда теоретически gatherer мог умереть (race с
	# волной скелетов). Проверяем ещё раз, на провале — rollback ресурсов.
	if data.get("requires_gatherer", false):
		if not _consume_gatherer():
			for type in cost:
				economy.add_resource(type, int(cost[type]))
			return {"success": false, "reason": "нужен 1 свободный гном"}
	if not _apply_building(id, params):
		push_error("Camp.try_build: apply провалился для id=%s после успешного списания" % id)
		return {"success": false, "reason": "ошибка постройки"}
	if debug_log and LogConfig.master_enabled:
		print("[Camp:Build] %s построено" % id)
	EventBus.camp_buildings_changed.emit()
	return {"success": true, "reason": ""}


## Применяет эффект постройки по id. Вынесен в отдельную функцию (а не switch
## внутри try_build) — каждая постройка получит свой _build_X метод с
## специфичными параметрами (палатки, башни, апгрейды). Возвращает true на
## успех, false при ошибке инстанцирования.
func _apply_building(id: StringName, params: Dictionary) -> bool:
	match id:
		BUILDING_NEW_TENT:
			return _build_new_tent()
		BUILDING_WATCH_BELL:
			return _build_watch_bell(params)
		BUILDING_ARCHER_POST:
			return _build_archer_post(params)
	push_error("Camp._apply_building: нет handler для id=%s" % id)
	return false


## Атомарная попытка построить ломаную из сегментов частокола вдоль массива
## vertex'ов. Polyline-аналог [try_build] для brush-mode построек.
##
## Vertices — точки в мировых координатах (XZ, Y игнорируется — все сегменты
## ставятся на земле через _deploy_anchor.y). Между каждой парой соседних
## vertex'ов рассчитывается N сегментов = floor(length / segment_length),
## ставятся равномерно с поворотом перпендикулярно сегменту.
##
## Атомарность: сначала считаем total_cost, проверяем `can_afford` + все
## сегменты в build_zone, потом списываем и спавним. Частичная постройка
## исключена: либо всё, либо ничего (с понятной reason).
##
## Возвращает Dictionary { success: bool, reason: String, segments_built: int }.
func try_build_palisade_line(vertices: Array) -> Dictionary:
	var data: Dictionary = CAMP_BUILDING_CATALOG.get(BUILDING_PALISADE, {})
	if data.is_empty() or not data.get("brush_mode", false):
		return {"success": false, "reason": "палисад не в каталоге", "segments_built": 0}
	if _state != State.DEPLOYED:
		return {"success": false, "reason": "только в развёрнутом лагере", "segments_built": 0}
	if vertices.size() < 2:
		return {"success": false, "reason": "линия слишком короткая", "segments_built": 0}
	if palisade_segment_scene == null:
		return {"success": false, "reason": "palisade scene не задан", "segments_built": 0}

	# Считаем позиции и rotation'ы всех будущих сегментов. Линия разбивается на
	# pairs vertex'ов; каждая pair — на N сегментов вдоль направления pair'а.
	var segment_length: float = float(data.get("segment_length", 2.0))
	var segments: Array = []  # каждый элемент: {pos: Vector3, rot_y: float}
	for i in range(vertices.size() - 1):
		var a: Vector3 = vertices[i]
		var b: Vector3 = vertices[i + 1]
		a.y = _deploy_anchor.y
		b.y = _deploy_anchor.y
		var dir: Vector3 = b - a
		var length: float = dir.length()
		if length < 0.5:
			continue  # слишком короткий отрезок — пропускаем
		# count = ceil(length / segment_length): на длине 8.5м с segment_length=2
		# было бы 4 сегмента и 0.5м хвост; теперь 5 сегментов с шагом 1.7м,
		# соседние перекрываются на 0.3м. На углах post'у на vertex'е остаётся
		# закрывать только разворот направления, а не дробный хвост.
		var count: int = int(ceil(length / segment_length))
		if count <= 0:
			continue
		# step = length / count: равномерное распределение от a до b. Длина шага
		# ≤ segment_length, сегменты перекрываются (или касаются впритык при
		# точном кратном).
		var step_length: float = length / float(count)
		var step: Vector3 = dir.normalized() * step_length
		# Yaw сегмента: локальная ось +X (длина BoxMesh.size.x) должна быть
		# направлена вдоль dir. В Godot после rotation.y = θ локальный +X
		# отображается в (cos θ, 0, -sin θ). Чтобы это совпало с dir = (dx, 0, dz):
		# cos θ = dx, sin θ = -dz → θ = atan2(-dz, dx). Иначе сегменты встают
		# перпендикулярно линии и между ними остаются дыры размером с длину
		# сегмента.
		var rot_y: float = atan2(-dir.z, dir.x)
		# Распределяем count сегментов начиная с a + step/2 (центр первого
		# сегмента на полпути от a) с шагом step.
		for j in range(count):
			var center: Vector3 = a + step * (float(j) + 0.5)
			segments.append({"pos": center, "rot_y": rot_y})

	if segments.is_empty():
		return {"success": false, "reason": "линия слишком короткая", "segments_built": 0}

	# Все сегменты должны быть в build_zone — иначе откатываем ВСЁ.
	for seg in segments:
		if not is_in_build_zone(seg["pos"]):
			return {"success": false, "reason": "часть линии вне зоны строительства", "segments_built": 0}

	# Total cost = N × cost_per_segment.
	var cost_per: Dictionary = data.get("cost_per_segment", {})
	var total_cost: Dictionary = {}
	for type in cost_per:
		total_cost[type] = int(cost_per[type]) * segments.size()
	if not economy.can_afford(total_cost):
		return {"success": false, "reason": "не хватает ресурсов", "segments_built": 0}
	if not economy.try_spend(total_cost):
		# Race — теоретически между can_afford и try_spend; в однопоточном
		# Godot не случится, но страховка.
		return {"success": false, "reason": "не хватает ресурсов", "segments_built": 0}

	# Spawn'им. На этом этапе всё списано, провалов быть не должно — если
	# instantiate падает, логируем (но мы уже за деньги).
	var built: int = 0
	var parent: Node = get_tree().current_scene
	for seg in segments:
		var inst := palisade_segment_scene.instantiate() as PalisadeSegment
		if inst == null:
			push_error("Camp.try_build_palisade_line: scene не инстанцируется как PalisadeSegment")
			continue
		parent.add_child(inst)
		inst.global_position = seg["pos"]
		inst.rotation.y = seg["rot_y"]
		# При разрушении сегмента — debounced re-bake. Без этого скелеты
		# пробивают дыру в стене, но navmesh остаётся целым → гномы и сами
		# скелеты не видят новый проход. Debounce 0.3с защищает от шквала
		# (волна ломает 5 сегментов в одном кадре → 1 bake, не 5).
		inst.destroyed.connect(_on_palisade_segment_destroyed)
		built += 1
	# Corner-posts: на каждом vertex'е спавним короткий столбик. Закрывает
	# треугольную щель на внешней стороне углов (соседние сегменты под разным
	# углом не стыкуются плотно) и дробные хвосты (последний сегмент линии
	# может кончаться раньше vertex'а на ≤ segment_length метров — пустота
	# заглушается постом). Бесплатные — игрок уже платит per-segment.
	var posts: int = 0
	if palisade_post_scene != null:
		for v in vertices:
			var post: Node3D = palisade_post_scene.instantiate() as Node3D
			if post == null:
				continue
			parent.add_child(post)
			post.global_position = Vector3(v.x, _deploy_anchor.y, v.z)
			posts += 1
	if debug_log and LogConfig.master_enabled:
		print("[Camp:Palisade] построено %d сегментов + %d столбиков" % [built, posts])
	# Re-bake NavMesh — палисад добавил препятствия на слое CAMP_OBSTACLE,
	# гномам нужен новый путь вокруг. Async, гномы продолжают по старому
	# пути ≈100-300мс пока bake не закончится.
	_rebake_navmesh()
	EventBus.camp_buildings_changed.emit()
	return {"success": true, "reason": "", "segments_built": built}


## Зовёт async re-bake у NavigationRegion3D в сцене. Если region не найден
## (например, в dev-scene без navmesh'а) — silent skip. Duck-typing через
## has_method, чтобы не таскать class_name NavRegionBaker — class_cache
## после нового class_name требует editor-pass, иначе «Could not find type».
func _rebake_navmesh() -> void:
	var region: Node = get_tree().get_first_node_in_group(&"nav_region")
	if region != null and region.has_method(&"rebake"):
		region.rebake()


## Debounced rebake — несколько разрушений палисадов в одном кадре дают
## один bake через 0.3с. Без debounce'а волна на 5 сегментов давала бы
## 5 sync bake'ов = 0.5-1.5с лагов.
var _palisade_rebake_pending: bool = false
const PALISADE_REBAKE_DEBOUNCE: float = 0.3


func _on_palisade_segment_destroyed() -> void:
	if _palisade_rebake_pending:
		return
	_palisade_rebake_pending = true
	get_tree().create_timer(PALISADE_REBAKE_DEBOUNCE).timeout.connect(_do_palisade_rebake)


func _do_palisade_rebake() -> void:
	_palisade_rebake_pending = false
	_rebake_navmesh()


## Прямой приказ «занять линию обороны». Не постройка — тактический маркер,
## аналог «Иди сюда» для squad'ов, но в рамках лагеря (для defender'ов).
## Без cost, без can_build_reason, без try_spend. Минимальные ограничения:
## лагерь должен быть DEPLOYED и position в build_zone.
##
## Спавнит DefenseMarker, назначает 3 ближайших свободных защитника. На
## marker.destroyed — освобождает их обратно.
## Спавнит DefenseMarker и привязывает к нему `slot_count` ближайших
## свободных защитников. slot_count = 0 → дефолт (DefenseMarker.DEFAULT_SLOT_COUNT).
## HUD пробрасывает выбранное значение через HandBuildAim.
func place_defense_formation(world_pos: Vector3, facing: Vector3, slot_count: int = 0) -> bool:
	if _state != State.DEPLOYED:
		if LogConfig.master_enabled:
			print("[Camp] defense formation отменена — лагерь не развёрнут")
		return false
	if not is_in_build_zone(world_pos):
		if LogConfig.master_enabled:
			print("[Camp] defense formation отменена — вне build_radius")
		return false
	if defense_marker_scene == null:
		push_warning("Camp: defense_marker_scene не задан")
		return false
	var marker := defense_marker_scene.instantiate() as DefenseMarker
	if marker == null:
		push_error("Camp.place_defense_formation: scene не инстанцируется как DefenseMarker")
		return false
	get_tree().current_scene.add_child(marker)
	# 0 как «не задано» → дефолт. Положительные → ровно как игрок попросил.
	var effective_count: int = slot_count if slot_count > 0 else DefenseMarker.DEFAULT_SLOT_COUNT
	marker.setup(world_pos, facing, effective_count)
	marker.destroyed.connect(_on_defense_marker_destroyed.bind(marker))
	_defense_markers.append(marker)
	_assign_defenders_to_marker(marker)
	if LogConfig.master_enabled:
		print("[Camp] Defense formation @ (%.1f, %.1f) face=(%.2f, %.2f) slots=%d, markers=%d" % [
			world_pos.x, world_pos.z, facing.x, facing.z, effective_count, _defense_markers.size(),
		])
	return true


## Подбирает marker.slot_count ближайших защитников к позиции маркера,
## ещё не назначенных в формацию, и привязывает их. Свободные = те у кого
## is_in_formation_slot() == false. Если защитников меньше нужного — занимаем
## сколько есть, остальные слоты остаются пустыми.
func _assign_defenders_to_marker(marker: DefenseMarker) -> void:
	# Собираем кандидатов: живые defender'ы без assignment'а.
	var candidates: Array[DefenderGnome] = []
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		var def := g as DefenderGnome
		if def == null:
			continue
		if def.is_in_formation_slot():
			continue
		candidates.append(def)
	# Сортируем по дистанции до маркера (XZ). Берём первые slot_count.
	var mp: Vector3 = marker.global_position
	candidates.sort_custom(func(a: DefenderGnome, b: DefenderGnome) -> bool:
		var da: float = (Vector3(a.global_position.x, mp.y, a.global_position.z) - mp).length_squared()
		var db: float = (Vector3(b.global_position.x, mp.y, b.global_position.z) - mp).length_squared()
		return da < db
	)
	var n: int = mini(candidates.size(), marker.slot_count)
	for i in range(n):
		candidates[i].assign_to_marker(marker, i)
	if LogConfig.master_enabled:
		print("[Camp] DefenseMarker assignment: %d из %d свободных защитников назначено (нужно %d)" % [
			n, candidates.size(), marker.slot_count,
		])


## Массово отзывает всех защитников с маркеров — destroy всех DefenseMarker'ов.
## Каждый marker.destroy() триггерит _on_defense_marker_destroyed, который
## освобождает assigned-защитников. По сигналу destroyed маркер queue_free'нется.
##
## Вызывается из HUD «Патруль»-кнопки. Сам список _defense_markers очищается
## через chain _on_defense_marker_destroyed.erase(marker).
func disband_all_defense_markers() -> void:
	# Копируем список — destroy() триггерит _on_defense_marker_destroyed,
	# который erase'ит из _defense_markers (модификация во время итерации).
	var snapshot: Array[DefenseMarker] = _defense_markers.duplicate()
	for marker in snapshot:
		if is_instance_valid(marker):
			marker.destroy()


## Marker queue_free'нулся (или destroy()'нулся явно). Освобождаем
## всех защитников, которые на нём были — обратно к свободному патрулю.
func _on_defense_marker_destroyed(marker: DefenseMarker) -> void:
	_defense_markers.erase(marker)
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		var def := g as DefenderGnome
		if def == null:
			continue
		if def._assigned_marker == marker:
			def.release_from_marker()


## Эффект BUILDING_WATCH_BELL: спавнит WatchBell в `params.position`, привязывает
## уже-изъятого gatherer'а как гарнизон (флаг — на destroy респавним), подписывает
## Camp на alarm/destroyed сигналы. Если позиция не задана — fail.
func _build_watch_bell(params: Dictionary) -> bool:
	if watch_bell_scene == null:
		push_warning("Camp: watch_bell_scene не задан, постройка колокола невозможна")
		return false
	var pos: Vector3 = params.get("position", Vector3.INF)
	if pos == Vector3.INF:
		push_warning("Camp._build_watch_bell: position не задана")
		return false
	# Страховочная валидация зоны (HandBuildAim уже фильтрует ПКМ вне zone,
	# но через скрипт можно вызвать с любой position). Вне build_radius — fail.
	if not is_in_build_zone(pos):
		push_warning("Camp._build_watch_bell: position вне build_radius — отказ")
		return false
	var bell := watch_bell_scene.instantiate() as WatchBell
	if bell == null:
		push_error("Camp._build_watch_bell: scene не инстанцируется как WatchBell")
		return false
	# Якорь в current_scene чтобы пережить возможный queue_free Camp'а
	# (на P-restart Camp.reset_population колокол НЕ удаляет — это автономное
	# здание, не часть лагеря; см. _bells).
	get_tree().current_scene.add_child(bell)
	bell.global_position = pos
	# Маркер «гном внутри» — мы уже его queue_free'нули, физически отдельного
	# инстанса нет. На destroy респавним нового gatherer'а на месте колокола.
	bell.set_garrison(bell)  # self-ref как truthy маркер
	bell.bell_alarmed.connect(_on_bell_alarmed)
	bell.destroyed.connect(_on_bell_destroyed.bind(bell))
	_bells.append(bell)
	return true


## Скелет вошёл в alarm-зону колокола. Помощь = 2 ближайших к колоколу
## защитника из лагеря. Защитники сами управляют таймером (продлевают
## пока в зоне есть враги; release после linger-периода после очищения,
## см. DefenderGnome.BELL_LINGER_SECONDS). Явный release происходит на
## bell.destroyed (см. _on_bell_destroyed).
const BELL_RESPONSE_COUNT: int = 2

func _on_bell_alarmed(world_pos: Vector3) -> void:
	# Резолв колокола обратно по позиции — Camp хранит _bells, ищем тот,
	# чья global_position совпадает (epsilon для float). Альтернатива —
	# передавать bell в сигнале, но Vector3 проще для будущих внешних слушателей.
	var bell: WatchBell = null
	for b in _bells:
		if not is_instance_valid(b):
			continue
		if b.global_position.distance_squared_to(world_pos) < 0.01:
			bell = b
			break
	if bell == null:
		return
	var defenders: Array = []
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if not g.is_in_group(DefenderGnome.DEFENDER_GROUP):
			continue
		defenders.append(g)
	if defenders.is_empty():
		if debug_log and LogConfig.master_enabled:
			print("[Camp:Bell] alarm @ (%.1f, %.1f) — нет живых защитников" % [world_pos.x, world_pos.z])
		return
	# Сортируем по дистанции до колокола (xz). Берём первые N.
	defenders.sort_custom(func(a: Node3D, b2: Node3D) -> bool:
		var da: float = (a.global_position - world_pos).length_squared()
		var db: float = (b2.global_position - world_pos).length_squared()
		return da < db
	)
	var n: int = mini(BELL_RESPONSE_COUNT, defenders.size())
	for i in range(n):
		var d := defenders[i] as DefenderGnome
		if d != null:
			d.respond_to_bell(bell)
	if debug_log and LogConfig.master_enabled:
		print("[Camp:Bell] alarm @ (%.1f, %.1f) — %d защитник(а) на помощь" % [
			world_pos.x, world_pos.z, n,
		])


## Колокол разрушен. Спавним gatherer'а на его позиции (как «гном выскочил из
## развалин»), он бежит в лагерь по обычному gatherer-flow'у (RETURNING_TO_TENT
## → IN_TENT). По дороге его могут убить — это часть дизайна.
func _on_bell_destroyed(bell: WatchBell) -> void:
	_bells.erase(bell)
	# Отзываем только тех защитников, кто отвечал НА ЭТОТ КОНКРЕТНЫЙ bell.
	# Если на сцене несколько колоколов, разрушение одного не должно сбрасывать
	# защитников, отвечающих на другой.
	for g in _gnomes:
		if is_instance_valid(g) and g is DefenderGnome:
			var d := g as DefenderGnome
			if d.is_responding_to_bell(bell):
				d.release_from_bell()
	if bell.get_garrison() == null:
		return
	if gnome_scene == null:
		return
	var spawn_pos: Vector3 = bell.global_position
	# Выбираем палатку-«дом» для нового gatherer'а — first alive part. Если
	# лагерь свернут или нет палаток, gnome всё равно создаём, но без home_tent
	# он зависнет (gatherer-flow ожидает _home_tent). Лучше fail-fast в этом
	# случае, чтобы не плодить «зомби-гнома».
	var tent: Node3D = null
	for p in _parts:
		# tent_count_alive в Camp использует только is_instance_valid —
		# уничтоженные палатки queue_free'нутся и выпадают из _parts через
		# _on_part_destroyed (см. Camp подписку на CampPart.destroyed).
		if is_instance_valid(p):
			tent = p
			break
	if tent == null:
		if debug_log and LogConfig.master_enabled:
			print("[Camp:Bell] разрушен, но палаток нет — гном не возрождён")
		return
	var gnome := _spawn_one_gnome(gnome_scene, tent, "gatherer") as Gnome
	if gnome == null:
		return
	gnome.global_position = spawn_pos
	# В DEPLOYED новый gatherer должен искать ресурс / бежать в палатку;
	# enter_deployed() ставит его в SEARCHING. На пути в лагерь его могут
	# убить — это часть дизайна (вырвался из развалин, бежит домой).
	if _state == State.DEPLOYED:
		gnome.enter_deployed()
	if debug_log and LogConfig.master_enabled:
		print("[Camp:Bell] разрушен, гном-сторож выжил и бежит в лагерь")


## Эффект BUILDING_ARCHER_POST: спавнит стационарный стрелковый пост в
## `params.position`, ориентированный по `params.facing_dir`. Гном уже изъят
## из лагеря (через _consume_gatherer в try_build, как у колокола); пост сам
## является стрелком, поэтому отдельную единицу не спавним. На разрушение —
## респавн gatherer'а на месте поста (см. _on_archer_post_destroyed).
func _build_archer_post(params: Dictionary) -> bool:
	if archer_post_scene == null:
		push_warning("Camp: archer_post_scene не задан — пост не строится")
		return false
	var pos: Vector3 = params.get("position", Vector3.INF)
	var facing: Vector3 = params.get("facing_dir", Vector3.FORWARD)
	if pos == Vector3.INF:
		push_warning("Camp._build_archer_post: position не задана")
		return false
	if not is_in_build_zone(pos):
		push_warning("Camp._build_archer_post: position вне build_radius — отказ")
		return false
	var post := archer_post_scene.instantiate() as ArcherPost
	if post == null:
		push_error("Camp._build_archer_post: scene не инстанцируется как ArcherPost")
		return false
	# Якорь в current_scene (как WatchBell) — пост переживёт queue_free Camp'а
	# и не двигается с лагерем. Setup ставит позицию + direction.
	get_tree().current_scene.add_child(post)
	post.setup(pos, facing, self)
	post.destroyed.connect(_on_archer_post_destroyed.bind(post))
	_archer_posts.append(post)
	if debug_log and LogConfig.master_enabled:
		print("[Camp:ArcherPost] построен @ (%.1f, %.1f) face=(%.2f, %.2f)" % [
			pos.x, pos.z, facing.x, facing.z,
		])
	return true


## Пост разрушен (скелетами или магией) ИЛИ демонтирован при свёртке. В обоих
## случаях: освобождаем «застрявшего» гнома — спавним gatherer'а на месте
## поста, чтобы он добрался до палатки (или продолжил караван, если PACKING).
##
## Симметрично _on_bell_destroyed: ресурсы НЕ возвращаются (постройка
## потрачена), но гном-«гарнизон» жив.
func _on_archer_post_destroyed(post: ArcherPost) -> void:
	_archer_posts.erase(post)
	if gnome_scene == null:
		return
	var spawn_pos: Vector3 = post.global_position if is_instance_valid(post) else _deploy_anchor
	# Выбираем «дом» для возвращающегося гнома — first alive tent. Если палаток
	# нет (теоретически возможно при синхронном уничтожении лагеря) — гном не
	# спавнится, как в bell-flow'е.
	var tent: Node3D = null
	for p in _parts:
		if is_instance_valid(p):
			tent = p
			break
	if tent == null:
		if debug_log and LogConfig.master_enabled:
			print("[Camp:ArcherPost] разрушен, но палаток нет — гном не возрождён")
		return
	var gnome := _spawn_one_gnome(gnome_scene, tent, "gatherer") as Gnome
	if gnome == null:
		return
	gnome.global_position = spawn_pos
	# В DEPLOYED — gatherer-flow, в PACKING — request_return сам подключится через
	# _start_pack-цикл (но мы спавним ПОСЛЕ _start_pack, поэтому дёргаем
	# request_return на месте).
	if _state == State.DEPLOYED:
		gnome.enter_deployed()
	elif _state == State.PACKING_RETURNING:
		gnome.request_return()
	if debug_log and LogConfig.master_enabled:
		print("[Camp:ArcherPost] разрушен/демонтирован, гном-стрелок возвращается в лагерь")


## Демонтаж всех активных постов. Вызывается из _start_pack: посты — мобильная
## экипировка лагеря, при свёртке исчезают (см. дизайн-выбор «сворачивается
## вместе с лагерем»). Каждый destroy триггерит _on_archer_post_destroyed,
## который возвращает гнома обратно через spawn'а gatherer'а на месте.
func _dismantle_archer_posts() -> void:
	# Копируем массив — destroy() триггерит _on_archer_post_destroyed, который
	# erase'ит из _archer_posts (модификация во время итерации иначе багает).
	var snapshot: Array[ArcherPost] = _archer_posts.duplicate()
	for post in snapshot:
		if is_instance_valid(post):
			post.take_damage(post.hp_max * 2.0)


## Эффект BUILDING_NEW_TENT: спавнит новую палатку и заселяет её жителями
## (по defaults из tent.tscn — gnomes_per_tent / defenders_per_tent).
## Доступно только в DEPLOYED (гарантировано can_build_reason'ом).
##
## В DEPLOYED палатки расставлены кольцом. Новая встаёт на anchor (центр),
## кольцо пересчитывается на N+1 слотов через _rebuild_deployed_targets,
## follow-tick подтянет к её target'у на новом кольце за следующие кадры.
## Гномы новой палатки сразу получают enter_deployed() — как и обычные при
## развёртке (выходят из IN_TENT в SEARCHING, ищут ресурс).
func _build_new_tent() -> bool:
	var tent: Node3D = _spawn_one_tent()
	if tent == null:
		return false
	# В DEPLOYED ставим на центр — _spawn_one_tent поставил «за башней» (как
	# для каравана), это плохо для развёрнутого лагеря. Follow подвезёт до
	# слота на кольце.
	if _state == State.DEPLOYED:
		tent.global_position = Vector3(
			_deploy_anchor.x,
			tent.global_position.y,
			_deploy_anchor.z,
		)
		_rebuild_deployed_targets()
	if tent is CampPart:
		var part := tent as CampPart
		var defender_n: int = clampi(part.defenders_per_tent, 0, part.gnomes_per_tent)
		var gatherer_n: int = part.gnomes_per_tent - defender_n
		var new_gnomes: Array[Gnome] = []
		for i in range(defender_n):
			var g := _spawn_one_gnome(defender_scene, tent, "defender")
			if g != null:
				new_gnomes.append(g)
		for i in range(gatherer_n):
			var g := _spawn_one_gnome(gnome_scene, tent, "gatherer")
			if g != null:
				new_gnomes.append(g)
		# В DEPLOYED новые гномы должны сразу выйти на сбор, как и
		# существующие — иначе сидели бы в палатке до следующего deploy'я.
		if _state == State.DEPLOYED:
			for g in new_gnomes:
				g.enter_deployed()
	return true


## --- Anchor drop zone (бросок ресурса рукой в центр лагеря) ---

## Создаёт Area3D в центре лагеря — ловит брошенные рукой ResourcePile.
## Layer=0 (сама ничего не блокирует), mask=Items (видит pile-ы). Зона —
## SphereShape3D радиусом anchor_drop_radius. Monitoring=false до первого
## _start_deploy.
func _build_anchor_drop_zone() -> void:
	_anchor_drop_zone = Area3D.new()
	_anchor_drop_zone.name = "AnchorDropZone"
	_anchor_drop_zone.collision_layer = 0
	_anchor_drop_zone.collision_mask = Layers.ITEMS
	_anchor_drop_zone.monitoring = false
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = anchor_drop_radius
	col.shape = sphere
	_anchor_drop_zone.add_child(col)
	add_child(_anchor_drop_zone)


## --- Collection orders (план + alarm/work) ---

## Инициализирует _collection_priority из @export'ов через set_collection_priority
## (нормализация автоматом). Зовётся в _ready после _spawn_gnomes — чтобы первый
## emit имел слушателей (HUD/Journal к этому моменту уже подключились).
func _init_collection_priority() -> void:
	var weights: Dictionary = {
		ResourcePile.ResourceType.WOOD: initial_collection_priority_wood,
		ResourcePile.ResourceType.STONE: initial_collection_priority_stone,
		ResourcePile.ResourceType.IRON: initial_collection_priority_iron,
		ResourcePile.ResourceType.FOOD: initial_collection_priority_food,
	}
	set_collection_priority(weights)


## Назначает новые приоритеты сбора. weights — Dictionary[int, float] по
## типам ресурсов; будут нормализованы к сумме 1.0. Все ключи — ResourcePile.ResourceType.
##
## Если сумма весов ≤ 0 (всё нули) — fallback на равномерное распределение,
## иначе гномы вообще не смогут собирать. Это страховка от случайного preset'а
## «всё по 0».
func set_collection_priority(weights: Dictionary) -> void:
	var total: float = 0.0
	for w in weights.values():
		total += maxf(float(w), 0.0)
	_collection_priority.clear()
	if total <= 0.0:
		# Fallback: равномерно по 4 типам.
		var fallback_keys: Array = [
			ResourcePile.ResourceType.WOOD,
			ResourcePile.ResourceType.STONE,
			ResourcePile.ResourceType.IRON,
			ResourcePile.ResourceType.FOOD,
		]
		for k in fallback_keys:
			_collection_priority[k] = 0.25
	else:
		for k in weights:
			_collection_priority[k] = maxf(float(weights[k]), 0.0) / total
	EventBus.collection_priority_changed.emit(_collection_priority.duplicate())


## Эффективный вес типа с учётом stock-балансировки: дефицитные типы
## получают приоритет. base = нормализованный вес плана (0..1), затем
## делится на (1 + stock_текущий / stock_balance_scale)². **Квадратичный**
## penalty — линейный был слишком слаб против distance² в _find_nearest_pile.
## С 20 камня и 1 деревом линейная формула давала ratio ~1.6, а камень был
## чуть ближе чем дерево → гном всё равно шёл к камню. Квадратичная даёт
## ratio ~2.7, дерево побеждает.
##
## Пример с планом «Равномерно» (base=0.25 для всех):
##   stock=0:  eff = 0.25 (нейтрально, идёт к ближайшему)
##   stock=15: eff = 0.25/1.5² = 0.111 (вес упал в 2.25×)
##   stock=30: eff = 0.25/2² = 0.0625 (в 4×)
##   stock=60: eff = 0.25/3² = 0.028 (в 9×)
##
## Решает дизайнерскую проблему «План Равномерно, а собирают только
## железо/камень» — формула d²/w² сводилась к чистой дистанции при равных
## весах. Теперь типы с высоким stock сильно отодвигаются по cost'у даже
## при коротком фактическом расстоянии.
##
## Незаданный тип → 0 → pile никогда не выбирается (правильно для
## явно отключенного сбора).
func get_collection_priority_weight(type: int) -> float:
	var base: float = float(_collection_priority.get(type, 0.0))
	if base <= 0.0 or stock_balance_scale <= 0.0:
		return base
	var stock: float = float(economy.get_resource(type))
	var factor: float = 1.0 + stock / stock_balance_scale
	return base / (factor * factor)


## Стохастический выбор типа для сбора. Возвращает type из ResourcePile.ResourceType
## (WOOD/STONE/IRON/FOOD) пропорционально эффективным весам, или -1 если все
## веса нулевые. Используется гномом как **первый шаг** target-selection:
##   1. Гном получает тип через pick_collection_type (отдельно от географии).
##   2. Ищет ближайшую кучу выбранного типа в gather_radius.
##   3. Если куч нет — fallback на weighted-distance по всем типам.
##
## Зачем разделять. Прежний путь d²/w² смешивал тип и дистанцию: даже с
## stock-балансировкой география побеждала, если кучи нужного типа физически
## дальше ближайших (wood:stone eff 0.195:0.111 ratio 1.76, но stone-куча в
## 1.5× ближе → побеждала). Стохастический pick делает выбор типа независимым
## от карты: «Равномерно» с base=0.25 каждый — гном с 25% шансом пойдёт за
## деревом независимо от расположения кучи.
##
## Stock'и читаются через get_collection_priority_weight (квадратичный
## penalty уже встроен). Веса нормализуются здесь повторно — sum может не = 1.0
## из-за разного stock-штрафа.
func pick_collection_type() -> int:
	var total: float = 0.0
	var pairs: Array = []
	for t in [
		ResourcePile.ResourceType.WOOD,
		ResourcePile.ResourceType.STONE,
		ResourcePile.ResourceType.IRON,
		ResourcePile.ResourceType.FOOD,
	]:
		var w: float = get_collection_priority_weight(t)
		if w > 0.0:
			pairs.append([t, w])
			total += w
	if total <= 0.0:
		return -1
	var r: float = randf() * total
	var acc: float = 0.0
	for entry in pairs:
		acc += entry[1]
		if r <= acc:
			return int(entry[0])
	# Floating-point fallback на последний элемент (теоретически недостижим).
	return int(pairs[pairs.size() - 1][0])


func get_collection_priority() -> Dictionary:
	# Копия — чтобы caller не мог мутировать внутреннее состояние.
	# Возвращает БАЗОВЫЙ план (без stock-балансировки) — UI показывает план
	# как задал игрок. Эффективные веса (с учётом stock) — через
	# get_collection_priority_weight.
	return _collection_priority.duplicate()


func get_collection_mode() -> int:
	return _collection_mode


## Переключает режим сбора. WORK — все gatherer'ы возвращаются к работе
## (enter_deployed → SEARCHING). ALARM — все gatherer'ы → request_return
## (бегут в палатки → IN_TENT, скрыты, неуязвимы).
##
## DefenderGnome пропускается в обоих случаях: они снаружи всегда и в WORK,
## и в ALARM (продолжают защищать периметр). Режим имеет эффект только в
## DEPLOYED — в каравне/при свёртке гномы и так в палатках или идут туда.
func set_collection_mode(mode: int) -> void:
	if _collection_mode == mode:
		return
	_collection_mode = mode
	EventBus.collection_mode_changed.emit(mode)
	if debug_log and LogConfig.master_enabled:
		var mode_label: String = "WORK" if mode == CollectionMode.WORK else "ALARM"
		print("[Camp] режим сбора: %s" % mode_label)
	if _state != State.DEPLOYED:
		return
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g is DefenderGnome:
			continue
		match mode:
			CollectionMode.WORK:
				g.enter_deployed()
			CollectionMode.ALARM:
				g.request_return()


## Проходит по overlapping_bodies зоны и пожирает каждую годную ResourcePile.
## Игнорирует freeze=true (рука держит — жалко вырывать из-под пальцев).
## consume_all возвращает все units, кредитуем в тип ресурса pile'а.
##
## Polling (а не body_entered) специально: ловит случай «рука держит pile в
## зоне, потом отпускает» — body_entered тут не сработал бы (pile уже был
## внутри). Стоимость polling'а пренебрежима — overlapping обычно 0-1
## объект, зона маленькая.
func _consume_piles_in_drop_zone() -> void:
	if _anchor_drop_zone == null or not _anchor_drop_zone.monitoring:
		return
	for body in _anchor_drop_zone.get_overlapping_bodies():
		if not is_instance_valid(body):
			continue
		var pile := body as ResourcePile
		if pile == null:
			continue
		if pile.freeze:
			continue
		if pile.units <= 0 or pile.is_queued_for_deletion():
			continue
		# Запоминаем тип и позицию ДО consume_all — после queue_free свойства не достать.
		var type: int = int(pile.resource_type)
		var fx_pos: Vector3 = pile.global_position
		var amount: int = pile.consume_all()
		if amount > 0:
			economy.add_resource(type, amount)
			ResourceFx.pulse(fx_pos, ResourcePile.color_for_type(type))
			if debug_log and LogConfig.master_enabled:
				print("[Camp] поглощён pile (type=%d, units=%d)" % [type, amount])


## Воскрешает гномов лагеря: вычищает оставшихся, заспавнивает новых на
## уцелевших палатках. Палатки не восстанавливаются — пользователь явно
## просил «воскресить гномов» (rebalance после волн); если палатка уже
## уничтожена, её жители безвозвратно потеряны вместе с ней. Используется
## WaveDirector'ом при рестарте кампании (P).
func reset_population() -> void:
	# Копия — _gnomes мутируется через _on_gnome_destroyed на queue_free.
	for gnome in _gnomes.duplicate():
		if is_instance_valid(gnome):
			gnome.queue_free()
	_gnomes.clear()
	_spawn_gnomes()
	# Если лагерь уже DEPLOYED — новые гномы должны выйти бродить, иначе
	# останутся IN_TENT и не будут собирать ресурсы / отстреливать скелетов.
	if _state == State.DEPLOYED:
		for g in _gnomes:
			if is_instance_valid(g):
				g.enter_deployed()
	if debug_log and LogConfig.master_enabled:
		print("[Camp] популяция сброшена (гномов: %d)" % _gnomes.size())


func _on_part_destroyed(part: Node3D) -> void:
	# Удаляем по индексу, чтобы синхронно обрезать _deployed_targets — иначе
	# после смерти палатки [i] оставшиеся палатки поедут к чужим точкам кольца
	# (каждая палатка читает _deployed_targets[i] по своему индексу в _parts).
	var idx := _parts.find(part)
	if idx == -1:
		return
	_parts.remove_at(idx)
	if idx < _deployed_targets.size():
		_deployed_targets.remove_at(idx)
	# Переназначаем сиротских гномов на ближайшую живую палатку. Без этого
	# гном с _home_tent → freed-инстансом застревает: при request_return
	# _tick_returning видит null tent и сразу _enter_in_tent на текущей
	# позиции (становится невидим где-то в поле), а в CARAVAN_FOLLOWING
	# IN_TENT-приклейка к null'у не работает — он не двигается с караваном.
	# Если живых палаток вообще не осталось — просто оставляем _home_tent=null,
	# гномы продолжают жить на местах (Camp всё равно невалиден для волн).
	_reassign_orphan_gnomes(part)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] палатка %s уничтожена (осталось: %d)" % [part.name, _parts.size()])


## Гномы, чей home_tent был только что разрушен, получают новую ближайшую
## живую палатку как home. Если живых палаток нет — гном переходит в
## FOLLOWING_CARAVAN (идёт за башней без дома). До этого orphan мог сидеть
## IN_TENT с freed-ссылкой и телепортироваться по последней позиции мёртвой
## палатки — теперь он явно «бездомный» с активным state.
func _reassign_orphan_gnomes(dead_tent: Node3D) -> void:
	var reassigned := 0
	var stranded := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g.get_home_tent() != dead_tent:
			continue
		var new_home := _nearest_alive_tent_to(g.global_position)
		if new_home != null:
			g.set_home_tent(new_home)
			reassigned += 1
		else:
			# Живых палаток нет — становится бездомным, идёт за башней.
			# IN_TENT гномы тоже нужно «выпустить» — просто set state.
			g.enter_following_caravan()
			stranded += 1
	if (reassigned > 0 or stranded > 0) and debug_log and LogConfig.master_enabled:
		print("[Camp] осиротели после смерти %s: на новые палатки %d, бездомных %d" % [dead_tent.name, reassigned, stranded])


## Ближайшая живая палатка к точке. Используется при переназначении
## гномов-сирот после гибели их home_tent. Оторванные (torn_off) палатки
## пропускаются — переназначать сироту на летающую палатку бессмысленно.
func _nearest_alive_tent_to(pos: Vector3) -> Node3D:
	var nearest: Node3D = null
	var nearest_dist_sq := INF
	for part in _parts:
		if not is_instance_valid(part):
			continue
		if part is CampPart and (part as CampPart).is_torn_off():
			continue
		var d_sq: float = (part.global_position - pos).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = part
	return nearest


func _on_gnome_destroyed(gnome: Gnome) -> void:
	_gnomes.erase(gnome)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] гном %s убит (осталось: %d)" % [gnome.name, _gnomes.size()])


func _on_tower_destroyed() -> void:
	if debug_log and LogConfig.master_enabled:
		print("[Camp] башня уничтожена — караван останавливается")
	# Башня умирает → больше не цель ни для кого. group-membership чистить
	# не обязательно (нода freed → вышла из всех групп автоматически), но
	# делаем явно на случай если EventBus.tower_destroyed эмитится перед
	# фактическим queue_free.
	_set_tower_aggro(false)
	_tower = null


## Управление tower-aggro для скелетов: tower уязвим (в группе skeleton_target)
## только в каравне. В DEPLOYED осада идёт на палатки/гномов вокруг костра,
## tower сам по себе не цель. После _finalize_pack возвращаем — караван снова
## в движении, фоновые скелеты могут аггриться через vision.
##
## Tower может быть null (target_path не задан, или _on_tower_destroyed уже
## обнулил) — тогда no-op. is_inside_tree-чек защищает от попытки добавить
## в группу ноду, которую только что freed (group API падает на freed-инстансе).
func _set_tower_aggro(active: bool) -> void:
	if _tower == null or not is_instance_valid(_tower):
		return
	if not _tower.is_inside_tree():
		return
	if active:
		if not _tower.is_in_group(SKELETON_TARGET_GROUP):
			_tower.add_to_group(SKELETON_TARGET_GROUP)
	else:
		if _tower.is_in_group(SKELETON_TARGET_GROUP):
			_tower.remove_from_group(SKELETON_TARGET_GROUP)


func _process(delta: float) -> void:
	_handle_input(delta)
	_handle_collection_input()
	_handle_halt_input()
	match _state:
		State.CARAVAN_FOLLOWING:
			_update_caravan_follow(delta)
		State.DEPLOYED:
			_update_deployed(delta)
		State.PACKING_RETURNING:
			# Палатки стоят на местах развёртки, гномы возвращаются.
			# Когда все дома — финализируем pack. Если кто-то завис (схвачен
			# рукой, застрял в коллизии, упал с обрыва) — таймаут спасает
			# караван от вечного простоя.
			_update_deployed(delta)
			_pack_elapsed += delta
			if _all_gnomes_home():
				_finalize_pack()
			elif _pack_elapsed >= pack_timeout:
				if debug_log and LogConfig.master_enabled:
					var stuck := _count_gnomes_not_home()
					print("[Camp] свёртка форсированно завершена (таймаут %.1fс, %d гномов не дома)" % [pack_timeout, stuck])
				_finalize_pack()
	# Polling брошенных в anchor куч. monitoring=false → метод сразу выходит.
	# Polling важнее body_entered: ловит случай «рука держит pile в зоне →
	# отпускает (freeze стал false) → нет нового entered-события».
	_consume_piles_in_drop_zone()
	if _tower != null:
		_last_target_pos = _tower.global_position


## Гном «готов к движению каравана» если он либо в палатке (IN_TENT, едет
## внутри), либо уже встроился в колонну за палатками (FOLLOWING_CARAVAN).
## После правок 2026-05-06: gatherer'ы при `request_return` идут в свою палатку
## (`RETURNING_TO_TENT`), сидя в палатке считаются домом; защитники сразу в
## колонну (`FOLLOWING_CARAVAN`) через override `DefenderGnome.request_return`.
## Если кто-то завис в `RETURNING_TO_TENT` дольше `pack_timeout` — `_update_deployed`
## форсированно завершает свёртку через `_finalize_pack`.
func _all_gnomes_home() -> bool:
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g.is_home() or g.is_following_caravan():
			continue
		return false
	return true


## Считает живых гномов, которые НЕ готовы к движению каравана. Используется
## в логе таймаута свёртки — без этого «застрял на N гномов» в логе не покажется.
func _count_gnomes_not_home() -> int:
	var n := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g.is_home() or g.is_following_caravan():
			continue
		n += 1
	return n


# --- Дележ куч между гномами ---

## True, если кучу уже нацелил какой-то гном (≠ exclude_gnome). Гном-сканер
## пропускает claimed-кучи, чтобы каждый нашёл «своё».
func is_pile_claimed(pile: ResourcePile, exclude_gnome: Gnome = null) -> bool:
	if not is_instance_valid(pile):
		return false
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g == exclude_gnome:
			continue
		if g.get_assigned_pile() == pile:
			return true
	return false


# --- Ввод / переходы состояний ---

## Edge-trigger хоткеи C / V для команд гномам. Отдельно от _handle_input
## (который про camp_toggle и start_deployed-gate'ом блокируется для
## статичных POI-лагерей) — команды гномам нужны и в статичных лагерях.
func _handle_collection_input() -> void:
	if Input.is_action_just_pressed("gnome_collect"):
		set_collection_mode(CollectionMode.WORK)
	elif Input.is_action_just_pressed("gnome_alarm"):
		set_collection_mode(CollectionMode.ALARM)


## Edge-trigger Q. Три независимых эффекта:
##   1. В CARAVAN_FOLLOWING переключает halted-флаг (caravan stop/resume).
##   2. Squad-toggle: если хоть один отряд в зоне сейчас в ESCORT — все
##      escort-отряды тормозятся (HOLD-soft на текущей позиции). Иначе —
##      все в зоне переключаются в ESCORT.
##   3. Команда применяется к каждому отряду НЕ мгновенно, а когда «волна
##      вызова» доходит до его центра (delay = dist / recall_wave_speed).
##      Визуал — расширяющееся кольцо в HUD. Отряды ВНЕ зоны игнорируются
##      сразу (волна до них не долетит).
func _handle_halt_input() -> void:
	if not Input.is_action_just_pressed("caravan_halt_toggle"):
		return
	if not is_instance_valid(_tower):
		return

	var origin: Vector3 = _tower.global_position
	var wave_duration: float = recall_zone_radius / maxf(recall_wave_speed, 0.001)
	# Pulse'им волну всегда (даже без отрядов) — игроку полезно увидеть
	# границу зоны для навигации.
	EventBus.recall_zone_pulsed.emit(origin, recall_zone_radius, wave_duration)

	# Halt-toggle каравана: гейт по recall-зоне + delay по приходу волны.
	# Если центр каравана вне зоны вызова — Q его не касается вообще:
	# волна туда не долетит, лагерь не «слышит» приказ. Иначе capture'ом
	# фиксируем target_halted (на mash'е каждое нажатие имеет свой target)
	# и применяем когда фронт волны до camp'а доходит.
	if not start_deployed and _state == State.CARAVAN_FOLLOWING:
		var camp_center: Vector3 = current_center()
		var dx_c: float = camp_center.x - origin.x
		var dz_c: float = camp_center.z - origin.z
		if dx_c * dx_c + dz_c * dz_c <= recall_zone_radius * recall_zone_radius:
			var camp_dist: float = sqrt(dx_c * dx_c + dz_c * dz_c)
			var camp_delay: float = camp_dist / maxf(recall_wave_speed, 0.001)
			var target_halted: bool = not _caravan_halted
			if camp_delay <= 0.001:
				set_caravan_halted(target_halted)
			else:
				var t := get_tree().create_timer(camp_delay)
				t.timeout.connect(func() -> void:
					set_caravan_halted(target_halted)
				)

	var any_escorting_in_zone: bool = false
	var in_zone_squads: Array = []
	var ignored: int = 0
	for squad in _squads:
		if is_squad_in_recall_zone(squad):
			in_zone_squads.append(squad)
			if squad.state == Squad.State.ESCORTING_TOWER:
				any_escorting_in_zone = true
		else:
			ignored += 1
			EventBus.squad_recall_ignored.emit(squad)

	for squad in in_zone_squads:
		var center: Vector3 = _squad_alive_center(squad)
		var dist: float = (center - origin).length()
		var delay: float = dist / maxf(recall_wave_speed, 0.001)
		if any_escorting_in_zone:
			if squad.state == Squad.State.ESCORTING_TOWER:
				_schedule_squad_command(squad, delay, &"hold")
		else:
			_schedule_squad_command(squad, delay, &"escort")

	if debug_log and LogConfig.master_enabled and (in_zone_squads.size() + ignored) > 0:
		var verb: String = "стоп" if any_escorting_in_zone else "вызов"
		print("[Camp] Q (%s): отрядов в зоне %d, проигнорировано %d, волна %.2fс" % [
			verb, in_zone_squads.size(), ignored, wave_duration,
		])


## Назначает команду squad'у с задержкой по delay (волна вызова). Если
## delay≈0 — выполняется немедленно. Если позже — через SceneTree.create_timer.
## На fire'е проверяет валидность и членство в _squads — squad мог быть
## disbanded между нажатием Q и приходом волны.
##
## kind = &"escort" → command_escort; &"hold" → command_hold(center, false).
## Center пересчитывается на момент fire'а (не на момент Q-нажатия): юнит
## мог сдвинуться за это время.
func _schedule_squad_command(squad: Squad, delay: float, kind: StringName) -> void:
	if delay <= 0.001:
		_apply_wave_command(squad, kind)
		return
	var timer := get_tree().create_timer(delay)
	timer.timeout.connect(func() -> void:
		if not _squads.has(squad):
			return
		_apply_wave_command(squad, kind)
	)


func _apply_wave_command(squad: Squad, kind: StringName) -> void:
	if squad == null or not _squads.has(squad):
		return
	if kind == &"escort":
		squad.command_escort()
	elif kind == &"hold":
		squad.command_hold(_squad_alive_center(squad), false)


## Среднее живых членов squad'а. Используется для HOLD-soft на Q-стопе и
## для is_squad_in_recall_zone. Возвращает global_position камп'а если
## членов нет (deg-fallback, не должно случаться при squad с count_alive > 0).
func _squad_alive_center(squad: Squad) -> Vector3:
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for m in squad.members:
		if not is_instance_valid(m):
			continue
		sum += m.global_position
		n += 1
	if n == 0:
		return global_position
	return sum / float(n)


## True если центр отряда (среднее живых членов) в `recall_zone_radius` от
## башни. UI и Q-recall гейтятся этим. Если башня уничтожена — false (нет
## точки отсчёта, recall невозможен).
func is_squad_in_recall_zone(squad: Squad) -> bool:
	if not is_instance_valid(_tower):
		return false
	if squad == null or squad.count_alive() == 0:
		return false
	var sum: Vector3 = Vector3.ZERO
	var n: int = 0
	for m in squad.members:
		if not is_instance_valid(m):
			continue
		sum += m.global_position
		n += 1
	if n == 0:
		return false
	var center: Vector3 = sum / float(n)
	var dx: float = center.x - _tower.global_position.x
	var dz: float = center.z - _tower.global_position.z
	return dx * dx + dz * dz <= recall_zone_radius * recall_zone_radius


## True если башня в зоне вызова от anchor'а развёрнутого лагеря — нужно
## для R-pack: pack тикает только если игрок не увёл башню слишком далеко.
## Иначе игрок мог бы свернуть лагерь и заставить палатки нестись через
## всю карту за башней.
func is_tower_in_camp_recall_zone() -> bool:
	if not is_instance_valid(_tower):
		return false
	if _state != State.DEPLOYED:
		# Pack-gate имеет смысл только в DEPLOYED. Для других state'ов
		# зону трактуем как «в любом случае true» (мы не блокируем то, что
		# никто и не пытается сделать).
		return true
	var dx: float = _tower.global_position.x - _deploy_anchor.x
	var dz: float = _tower.global_position.z - _deploy_anchor.z
	return dx * dx + dz * dz <= recall_zone_radius * recall_zone_radius


func _handle_input(delta: float) -> void:
	# Static-camp (start_deployed=true) не реагирует на R — он не сворачивается.
	# Поселения на POI остаются развёрнутыми всю игру.
	if start_deployed:
		return
	if not Input.is_action_pressed("camp_toggle"):
		if _deploy_hold > 0.0 and debug_log and LogConfig.master_enabled and _was_holding_stationary:
			print("[Camp] отсчёт прерван (отпущена R)")
		_deploy_hold = 0.0
		_pack_hold = 0.0
		_was_holding_stationary = false
		return

	match _state:
		State.CARAVAN_FOLLOWING:
			# Halted: deploy заблокирован. Игрок должен сначала возобновить
			# караван (Q), потом удерживать R на стационарной башне для
			# развёртки. Иначе семантика «стоп» смешалась бы с deploy и
			# случайное удержание R на остановленном караване разворачивало
			# бы лагерь без явного намерения.
			if _caravan_halted:
				if _was_holding_stationary and debug_log and LogConfig.master_enabled:
					print("[Camp] отсчёт прерван (караван остановлен)")
				_deploy_hold = 0.0
				_was_holding_stationary = false
				return
			# Стационарность башни — необходимое условие. POI-gate (если
			# require_poi=true) — второе. Оба должны быть true, чтобы
			# счётчик отсчёта развёртки тикал.
			var poi := _find_poi_for_deploy()
			var poi_ok: bool = (not require_poi) or (poi != null)
			if _is_tower_stationary() and poi_ok:
				if not _was_holding_stationary:
					if debug_log and LogConfig.master_enabled:
						if poi != null:
							print("[Camp] начат отсчёт развёртки (POI: %s)" % poi.name)
						else:
							print("[Camp] начат отсчёт развёртки")
					_was_holding_stationary = true
				_deploy_hold += delta
				if _deploy_hold >= deploy_duration:
					_start_deploy()
			else:
				if _was_holding_stationary and debug_log and LogConfig.master_enabled:
					if not _is_tower_stationary():
						print("[Camp] отсчёт прерван (башня поехала)")
					else:
						print("[Camp] отсчёт прерван (вышли из POI)")
				_deploy_hold = 0.0
				_was_holding_stationary = false
		State.DEPLOYED:
			# Pack-gate: башня должна быть в recall-зоне лагеря. Иначе игрок
			# увёл её далеко и хочет «оставить лагерь» — pack не должен
			# срабатывать (палатки не понесутся за башней через всю карту).
			if not is_tower_in_camp_recall_zone():
				if _pack_hold > 0.0 and debug_log and LogConfig.master_enabled:
					print("[Camp] отсчёт свёртки прерван (башня вне зоны вызова — лагерь остаётся)")
				_pack_hold = 0.0
				return
			_pack_hold += delta
			if _pack_hold >= pack_duration:
				_start_pack()
		State.PACKING_RETURNING:
			# Во время сбора отсчёт не накапливается — гномам нужно дойти.
			pass


func _is_tower_stationary() -> bool:
	if _tower == null:
		return false
	if _last_target_pos == Vector3.INF:
		return false
	var d := _tower.global_position - _last_target_pos
	d.y = 0.0
	return d.length() < stationary_threshold


## Возвращает ближайший POI, в радиус которого попадает башня. Если башни нет
## или POI не найдено — null. Используется и в _handle_input как gate-чек,
## и в _start_deploy как источник якоря.
##
## "Ближайший" — на случай перекрытия safe_radius'ов соседних POI: лагерь
## защёлкивается на тот, к которому башня ближе. Без этого первый POI в
## группе бы выигрывал, и игрок не смог бы выбрать более далёкий.
##
## Кеширование: `_handle_input` дёргает функцию каждый кадр на зажатой R (60Гц),
## и `get_tree().get_nodes_in_group` каждый раз аллоцирует Array. TTL 0.1с
## срезает 6× нагрузку и не вносит видимой задержки на gate-переходах.
## Кеш инвалидируется и по freed-инстансу — POI могут уничтожиться (хотя
## сейчас не уничтожаются — но если когда-нибудь POI станут разрушаемыми,
## защита уже на месте).
func _find_poi_for_deploy() -> Node3D:
	var now_msec: int = Time.get_ticks_msec()
	var cache_age_msec: int = now_msec - _poi_cache_time_msec
	if cache_age_msec < int(POI_CACHE_TTL_SEC * 1000.0):
		if _poi_cache == null or is_instance_valid(_poi_cache):
			return _poi_cache
	_poi_cache_time_msec = now_msec

	if _tower == null:
		_poi_cache = null
		return null
	var tower_pos := _tower.global_position
	var nearest: Node3D = null
	var nearest_dist_sq := INF
	for poi in get_tree().get_nodes_in_group(QuestActor.POI_GROUP):
		if not is_instance_valid(poi):
			continue
		if not poi.has_method("is_within_safe_radius"):
			continue
		if not poi.is_within_safe_radius(tower_pos):
			continue
		var poi_node := poi as Node3D
		if poi_node == null:
			continue
		var d_sq: float = (poi_node.global_position - tower_pos).length_squared()
		if d_sq < nearest_dist_sq:
			nearest_dist_sq = d_sq
			nearest = poi_node
	_poi_cache = nearest
	return nearest


func _start_deploy() -> void:
	_state = State.DEPLOYED
	# Страховка: halted имеет смысл только в CARAVAN_FOLLOWING. Если каким-то
	# образом deploy случился (например, через будущий программный API), флаг
	# должен обнулиться — иначе после _finalize_pack караван останется халтнут
	# без явного намерения игрока.
	_caravan_halted = false
	# Anchor: позиция POI (если рядом с костром) > позиция башни > собственная.
	# POI-snap даёт визуально центрированный лагерь на костре, не «рядом с ним
	# со смещением, где башня случайно остановилась».
	var poi := _find_poi_for_deploy()
	if poi != null:
		_deploy_anchor = poi.global_position
	elif _tower != null:
		_deploy_anchor = _tower.global_position
	else:
		_deploy_anchor = global_position
	_deployed_targets.clear()
	var count := _parts.size()
	for i in range(count):
		var angle := float(i) * TAU / float(maxi(count, 1))
		var part_y: float = _parts[i].global_position.y
		var target := Vector3(
			_deploy_anchor.x + cos(angle) * deploy_radius,
			part_y,
			_deploy_anchor.z + sin(angle) * deploy_radius,
		)
		_deployed_targets.append(target)
	_deploy_hold = 0.0
	_pack_hold = 0.0
	_was_holding_stationary = false
	if debug_log and LogConfig.master_enabled:
		print("[Camp] лагерь развёрнут @ (%.1f, %.1f, %.1f)" % [_deploy_anchor.x, _deploy_anchor.y, _deploy_anchor.z])
	deployed.emit(_deploy_anchor)
	# Палатки уязвимы (как и в каравне сейчас — см. _ready/_finalize_pack).
	# В DEPLOYED это идентично, в каравне они тоже atакуемы скелетами,
	# единственное исключение — PACKING_RETURNING (бронь см. _start_pack).
	_set_parts_vulnerable(true)
	# Tower уходит из аггро-цели — скелеты переключаются на палатки/гномов.
	# Если игрок свернёт лагерь, _finalize_pack вернёт tower в группу.
	_set_tower_aggro(false)
	# Гномы выходят бродить — каждый из своей палатки (setup() в _spawn_one_gnome
	# привязал их к конкретному tent'у). Harvester для гномов — не дом, просто
	# объект в центре кольца.
	for g in _gnomes:
		if is_instance_valid(g):
			g.enter_deployed()
	# Центральный слот для модулей переезжает в anchor и активируется.
	# Y берём с пола, а не с anchor'а: anchor — позиция башни (y≈3, центр меша),
	# а модуль должен стоять на земле, а не висеть в воздухе.
	if _center_slot:
		var ground_y: float = 0.0
		if not _parts.is_empty():
			ground_y = _ground_y_at(_parts[0], _deploy_anchor)
		_center_slot.global_position = Vector3(_deploy_anchor.x, ground_y, _deploy_anchor.z)
		_center_slot.enabled = true
	# Anchor drop zone: переехала на anchor, начинает пожирать брошенные кучи.
	if _anchor_drop_zone != null:
		_anchor_drop_zone.global_position = Vector3(_deploy_anchor.x, _deploy_anchor.y + 0.5, _deploy_anchor.z)
		_anchor_drop_zone.monitoring = true
	# Harvester встаёт ровно на anchor (= центр POI, между палатками кольца) и
	# начинает качать золото. Y берём с пола, как у _center_slot — иначе он
	# повиснет на высоте башни (anchor.y ≈ 3, центр Tower-меша).
	if _harvester != null:
		var harv_ground_y: float = 0.0
		if not _parts.is_empty():
			harv_ground_y = _ground_y_at(_parts[0], _deploy_anchor)
		_harvester.deploy_on(Vector3(_deploy_anchor.x, harv_ground_y, _deploy_anchor.z))


func _start_pack() -> void:
	# Сначала зовём гномов домой; финальный переход в CARAVAN — после прихода всех.
	_state = State.PACKING_RETURNING
	_deploy_hold = 0.0
	_pack_hold = 0.0
	_pack_elapsed = 0.0
	_was_holding_stationary = false
	# Палатки сразу неуязвимы — игрок начал свёртку, тент бронируется.
	# Гномы остаются целью, пока не дойдут до своих палаток (они сами выходят
	# из skeleton_target в _enter_in_tent). На _finalize_pack бронь снимается.
	_set_parts_vulnerable(false)
	# Anchor drop zone выключается со старта свёртки — кучи, брошенные во время
	# свёртывания, не должны засчитываться (лагерь уже не «принимает»).
	if _anchor_drop_zone != null:
		_anchor_drop_zone.monitoring = false
	# Стрелковые посты — мобильная экипировка лагеря, при свёртке демонтируются.
	# Каждый пост возвращает «застрявшего» гнома (spawn gatherer'а на месте),
	# который сразу получит request_return ниже по циклу (или прямо из
	# _on_archer_post_destroyed: PACKING_RETURNING-ветка).
	_dismantle_archer_posts()
	if debug_log and LogConfig.master_enabled:
		print("[Camp] свёртка инициирована — ждём гномов")
	# Harvester снимается с POI — gold-tick останавливается. Двигаться обратно
	# в строй будет уже из _update_caravan_follow после _finalize_pack.
	if _harvester != null:
		_harvester.pack_to_caravan()
	for g in _gnomes:
		if is_instance_valid(g):
			g.request_return()


func _finalize_pack() -> void:
	_state = State.CARAVAN_FOLLOWING
	if debug_log and LogConfig.master_enabled:
		print("[Camp] лагерь свёрнут (все гномы дома)")
	# Слот выключается → модуль с него отпадает (остаётся стоять на земле,
	# где был лагерь — игрок может подобрать рукой и поставить заново).
	if _center_slot:
		_center_slot.enabled = false
	# Tower снова цель скелетов в каравне — фоновые wander'ы могут увидеть
	# караван и накинуться. Симметрично _start_deploy, который убирает.
	_set_tower_aggro(true)
	# Палатки также возвращаются в категорию целей — в каравне атакуемы.
	# Бронь снимается, _set_parts_vulnerable(false) был выставлен в _start_pack.
	_set_parts_vulnerable(true)
	# Возвращаем в строй ВСЕ палатки, независимо от того, как они стояли в
	# развёрнутом лагере (ring-слот / свободно расставленные игроком).
	# torn_off обломки restore'ом не затрагиваются — они физически утеряны.
	# Reorder по distance до Tower → ближайшая к башне становится первой
	# в цепочке (передняя в формации). _update_caravan_follow дальше плавно
	# вытянет всех в линию через exp_decay.
	for p in _parts:
		if p is CampPart:
			(p as CampPart).restore_to_caravan()
	_reorder_parts_by_position()
	packed.emit()


## Хелпер: разом ставит/убирает _vulnerable у всех живых палаток.
## set_vulnerable у CampPart сам управляет членством в SKELETON_TARGET_GROUP
## и приёмом урона. Используется в _ready (caravan-стартом), _start_deploy,
## _start_pack, _finalize_pack — вместо четырёхкратного дублирования цикла.
func _set_parts_vulnerable(value: bool) -> void:
	for p in _parts:
		if p is CampPart:
			(p as CampPart).set_vulnerable(value)


# --- Движение палаток ---

func _update_caravan_follow(delta: float) -> void:
	if _tower == null or _parts.is_empty():
		return
	# Halted: палатки замораживаются на текущих позициях, башня едет дальше.
	# Гномы IN_TENT в каравне и так не двигаются — не нужно их трогать.
	if _caravan_halted:
		return

	# Harvester (если есть и не на POI) едет первым звеном за башней. Палатки
	# дальше следуют за ним вместо башни. После _finalize_pack харвестер сам
	# is_deployed()=false — этим же путём встраивается обратно в строй.
	var harvester_in_caravan: bool = _harvester != null and not _harvester.is_deployed()
	if harvester_in_caravan:
		_move_harvester_to_caravan(delta)

	# Виртуальная цепочка: только палатки, которыми Camp реально может управлять.
	# Skip'аются: torn_off (живут по физике), in_hand (Hand двигает), вне строя
	# (флаг _outside_caravan, ставится в notify_part_settled при release вне
	# placement-зоны и сбрасывается при следующем pickup). distance-фильтра
	# здесь НЕТ — он каждый кадр выкидывал бы из строя «отстающие» палатки
	# когда tower уезжает быстрее цепочки.
	var active_parts: Array[Node3D] = []
	for part in _parts:
		if not is_instance_valid(part):
			continue
		if part is CampPart:
			var cp := part as CampPart
			if not cp.is_in_caravan() or cp.is_in_hand():
				continue
		active_parts.append(part)
	if active_parts.is_empty():
		return

	# Лидер для проверки «башня ушла слишком далеко» — Tower, а не Harvester:
	# follow_max_distance — это видимость самой башни, не звена-харвестера.
	var lead_dist: float = active_parts[0].global_position.distance_to(_tower.global_position)
	var leader_too_far := lead_dist > follow_max_distance

	if debug_log and LogConfig.master_enabled and leader_too_far != _was_out_of_range:
		if leader_too_far:
			print("[Camp] башня вне зоны видимости (dist=%.1f)" % lead_dist)
		else:
			print("[Camp] башня вернулась в зону видимости (dist=%.1f)" % lead_dist)
		_was_out_of_range = leader_too_far

	# Звено-лидер для первой палатки: Harvester (если в каравне) или сама башня.
	var first_leader: Node3D = _harvester if harvester_in_caravan else _tower
	for i in range(active_parts.size()):
		var part := active_parts[i]
		var leader_pos: Vector3 = first_leader.global_position if i == 0 else active_parts[i - 1].global_position

		# Ведущая палатка стоит, если башня ушла за порог. Остальные всё равно
		# подтягиваются к своему (стоящему) лидеру — цепочка собирается.
		if i == 0 and leader_too_far:
			continue

		var to_leader := leader_pos - part.global_position
		to_leader.y = 0.0
		if to_leader.length_squared() < VecUtil.EPSILON_SQ:
			continue
		var dir := to_leader.normalized()
		# gap зависит от того, кто ведёт это звено: если первая палатка идёт
		# за Harvester'ом — берём harvester_gap (он крупнее, нужно дыхание).
		# Остальные звенья — обычный part_gap между палатками.
		var link_gap: float = harvester_gap if (i == 0 and harvester_in_caravan) else part_gap
		var target_pos := leader_pos - dir * link_gap
		# Y: ground + half-height — палатка стоит ровно на полу, не утопает.
		# Без offset palatka.center на ground_y → её нижняя сторона уходит
		# под пол на половину высоты (визуально незаметно из-за толщины
		# Ground'а, но математически некорректно).
		var part_offset_y: float = (part as CampPart).floor_offset_y() if part is CampPart else 0.0
		target_pos.y = _ground_y_at(part, target_pos) + part_offset_y
		var step_pos := _exp_decay_capped(part.global_position, target_pos, follow_speed, caravan_max_speed, delta)
		_move_part_kinematic(part, step_pos)


## Двигает Harvester'а одной exp-decay-итерацией к точке «за башней на part_gap».
## Используется только в IN_CARAVAN — на _start_deploy Harvester телепортируется
## на anchor и сам себя не двигает. Y тянется к ground_y, чтобы не висел в
## воздухе если башня едет по уклону.
func _move_harvester_to_caravan(delta: float) -> void:
	var to_leader := _tower.global_position - _harvester.global_position
	to_leader.y = 0.0
	if to_leader.length_squared() < VecUtil.EPSILON_SQ:
		return
	var dir := to_leader.normalized()
	var target_pos: Vector3 = _tower.global_position - dir * harvester_gap
	target_pos.y = _ground_y_at(_harvester, target_pos)
	_harvester.global_position = _exp_decay_capped(
		_harvester.global_position, target_pos, follow_speed, caravan_max_speed, delta
	)


func _update_deployed(delta: float) -> void:
	# Добыча золота вынесена в Harvester (он сам тикает в DEPLOYED). Здесь
	# только движение палаток к ring-целям + (через _process) гномы.
	for i in range(_parts.size()):
		if i >= _deployed_targets.size():
			break
		var part := _parts[i]
		# Skip правило симметрично caravan-follow: torn_off, in_hand,
		# _outside_caravan. Distance-фильтра нет — однократная проверка
		# происходит в notify_part_settled при release.
		if part is CampPart:
			var cp := part as CampPart
			if not cp.is_in_caravan() or cp.is_in_hand():
				continue
		var step_pos := _exp_decay(part.global_position, _deployed_targets[i], follow_speed, delta)
		_move_part_kinematic(part, step_pos)


# --- Helpers ---

## Покадрово стабильное смягчение к target. decay — log-rate (чем больше, тем быстрее).
static func _exp_decay(current: Vector3, target: Vector3, decay: float, delta: float) -> Vector3:
	return target + (current - target) * exp(-decay * delta)


## Двигает PhysicsBody3D (палатку) к target_pos с проверкой collision'ов через
## PhysicsServer3D.body_test_motion. Палатка — RigidBody3D с freeze=true,
## позиционируется kinematic-стилем (direct global_position assignment). Без
## body_test_motion она бы сквозила палисады (collision detection не работает
## для прямого присвоения координат). С test_motion: если на пути препятствие,
## останавливаемся на safe-fraction motion'а, иначе доезжаем до target.
static func _move_part_kinematic(part: Node3D, target_pos: Vector3) -> void:
	var body := part as PhysicsBody3D
	if body == null:
		part.global_position = target_pos
		return
	var motion: Vector3 = target_pos - part.global_position
	if motion.length_squared() < 1e-6:
		return
	var params := PhysicsTestMotionParameters3D.new()
	params.from = part.global_transform
	params.motion = motion
	var result := PhysicsTestMotionResult3D.new()
	var collided: bool = PhysicsServer3D.body_test_motion(body.get_rid(), params, result)
	if collided:
		var safe: float = result.get_collision_safe_fraction()
		part.global_position += motion * safe
	else:
		part.global_position = target_pos


## Capped exp_decay: тот же exp-шаг, но длина шага ограничена max_speed × delta.
## На малых дистанциях (обычный follow в строю) cap неактивен — поведение
## идентично _exp_decay. На больших разрывах (после halt-resume, выкинутая
## палатка) шаг ограничен — палатка догоняет равномерно, без визуального
## ускорения пропорционально дистанции.
static func _exp_decay_capped(current: Vector3, target: Vector3, decay: float, max_speed: float, delta: float) -> Vector3:
	var step := (target - current) * (1.0 - exp(-decay * delta))
	var max_step: float = max_speed * delta
	if step.length_squared() > max_step * max_step:
		step = step.normalized() * max_step
	return current + step


## Y под точкой target_pos через raycast по слою TERRAIN. Если raycast пуст —
## возвращаем текущую Y палатки (не дёргаем по высоте).
func _ground_y_at(part: Node3D, target_pos: Vector3) -> float:
	var space := part.get_world_3d().direct_space_state
	if space == null:
		return part.global_position.y
	var from := target_pos + Vector3.UP * 5.0
	var to := target_pos + Vector3.DOWN * 50.0
	var query := PhysicsRayQueryParameters3D.create(from, to, Layers.TERRAIN)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return part.global_position.y
	return (hit.position as Vector3).y
