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
## FREE — «жизнь лагеря» (idle): гномы у костров / бродят, НЕ собирают (дефолт
## на развёртке). WORK — добыча. ALARM — в палатки. FREE=0 первым: дефолт лагеря.
enum CollectionMode { FREE, WORK, ALARM }

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

@export_group("Idle camp life (FREE mode)")
## Сцена костра (campfire.tscn). По одному спавнится у каждой палатки на
## развёртке; гном-разжигатель доходит и поджигает. Если не задана — idle-жизнь
## работает без костров (все гномы — бродяги).
@export var campfire_scene: PackedScene
## Доля гномов, садящихся у костров (остальные бродят по лагерю). 0.7 = ~70%.
@export_range(0.0, 1.0) var fire_slot_ratio: float = 0.7
## Смещение костра от палатки в сторону anchor'а (костёр между палаткой и
## центром лагеря, чтобы кольцо костров смотрело внутрь).
@export var campfire_offset: float = 3.0
## Радиус кольца слотов вокруг костра, на котором рассаживаются гномы.
@export var fire_slot_radius: float = 1.2
## Сколько слотов (мест) у одного костра.
@export var fire_slots_per_fire: int = 6
@export_group("")

@export_group("Construction (build time)")
## Сцена стройплощадки (construction_site.tscn). Если не задана — постройки
## возводятся мгновенно (старое поведение, graceful fallback).
@export var construction_site_scene: PackedScene
## Базовое время возведения здания, сек. Может быть переопределено на конкретную
## постройку полем `build_time` в CAMP_BUILDING_CATALOG.
@export var build_time: float = 2.5
## Задержка старта между сегментами палисада — даёт «волну» стройки вдоль линии.
@export var palisade_segment_stagger: float = 0.15
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

## ID-константы построек лагеря. Re-export'ятся из [CampBuildings] для
## удобства callsite'ов (Camp.BUILDING_NEW_TENT короче CampBuildings.NEW_TENT
## и был исходным API). Каталог тоже re-exported ниже.
const BUILDING_NEW_TENT := CampBuildings.NEW_TENT
const BUILDING_PALISADE := CampBuildings.PALISADE
const BUILDING_ARCHER_POST := CampBuildings.ARCHER_POST

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


## Каталог построек лагеря. Данные живут в [CampBuildings.CATALOG] — этот
## алиас сохраняется для обратной совместимости callsite'ов
## (JournalPanel / HandBuildAim / Camp.try_build всё ещё читают
## `Camp.CAMP_BUILDING_CATALOG`).
const CAMP_BUILDING_CATALOG: Dictionary = CampBuildings.CATALOG


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
## Дистанция «башня ↔ Harvester» в caravan'е. Больше part_gap, потому что
## Harvester крупнее палатки.
@export var harvester_gap: float = 4.5
## Дистанция «Harvester ↔ первая палатка» в caravan'е. Отдельный параметр
## (вместо переиспользования part_gap) — Harvester сзади имеет drill и
## выпуклости, ему нужен свой буфер до соседней палатки. Если в строю нет
## Harvester'а — этот параметр не используется (первая палатка идёт за
## tower'ом через part_gap).
@export var harvester_to_part_gap: float = 4.0
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
## Cap на скорость палатки в caravan-follow (м/с). Используется в
## deployed-mode для подтяжки палаток в ring-формацию через exp_decay.
## Snake-trail в caravan-mode игнорирует cap (скорость = скорости tower'а).
@export var caravan_max_speed: float = 10.0

## Шаг snake-trail. Tower записывает свою позицию в [_tower_trail] когда
## смещается на ≥ этого значения в XZ. Меньше → плавнее следование (но
## дороже sample-проход и больше памяти); больше → угловатость поворотов.
## 0.1м даёт ~10 точек на метр пути — на скорости 8 м/с это 80
## точек/сек, sample каждого сегмента — линейный проход ~30-100 точек.
@export var trail_sample_step: float = 0.1
## Запас длины trail сверх суммы gap'ов каравана. Точек хватает чтобы
## сегменты не «упирались в хвост trail'а» когда tower резко тормозит и
## стартует. 5м запаса с шагом 0.1 = +50 точек, копейки.
@export var trail_buffer_extra: float = 5.0

## Smoothing rate (1/с) для caravan-следования: фактическая позиция
## сегмента lerp'ается к snake-target через exp-decay со скоростью этого
## значения. 0 → чистый snake (точный snap к trail-точке). Высокое (25)
## → лёгкая «инерция»: сегмент отстаёт от target'а на ~40мс, повороты
## выглядят «жирнее», убираются резкие углы. Слишком низкое (<10) уже
## размывает snake-feel.
@export var trail_smoothing: float = 22.0
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
## Сцена обычного гнома-собирателя. Палаток больше нет — спавнится
## initial_gnome_count раз с домом = башня (живут в башне до установки харвестера).
@export var gnome_scene: PackedScene
## Сколько гномов-собирателей создать на старте (живут в башне). Раньше было
## tent_count × gnomes_per_tent; теперь явное число.
@export var initial_gnome_count: int = 8
## Сцена блока-здания (BuildBlock). Меню постройки спавнит её в руку и
## конфигурит под выбранное здание (Camp.spawn_building_into_hand).
@export var build_block_scene: PackedScene
## Сколько генераторов даёт ОПТИМАЛЬНУЮ (полную) скорость добычи золота.
## Меньше — добыча идёт, но медленнее (линейно от min_generators_to_mine);
## больше — прироста нет (потолок на полной скорости харвестера).
@export var generators_required: int = 4
## Минимум генераторов, чтобы добыча вообще началась (0 → стоит).
@export var min_generators_to_mine: int = 1
## Доля полной скорости добычи на минимуме генераторов. От неё скорость линейно
## растёт до 1.0 на generators_required. 0.4 → 1-й генератор качает на 40% темпа.
@export_range(0.0, 1.0) var min_generator_yield_frac: float = 0.4
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
## Сцена ворот в частоколе ([WallGate]). Спавнится через BUILDING_WALL_GATE,
## заменяет ≥2 сегмента палисада на едином участке стены. Если null —
## постройка молча провалится.
@export var wall_gate_scene: PackedScene
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
## XP отряда за КАЖДОЕ убийство врага — начисляется напрямую (EventBus.enemy_destroyed),
## НЕЗАВИСИМО от сбора орбов. Орбы теперь дают только ману (см. XpOrb). 0 = выкл.
@export var squad_xp_per_kill: int = 10
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
## EventBus.enemy_damaged). 3000 = ~100 убитых скелетов (hp=30 ea) по урону —
## супер ультра-редкий, приберегаемый на критический момент приём.
@export var super_charge_max: float = 3000.0
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
## Костры idle-жизни (campfire.tscn), по одному на палатку. Индекс СИНХРОНЕН
## с _parts/_deployed_targets: _campfires[i] — костёр палатки _parts[i].
## Спавнятся в _start_deploy, убираются в _start_pack / _on_part_destroyed.
var _campfires: Array[Node3D] = []
## Активные стройплощадки (construction_site.tscn) — здания в процессе возведения.
## Убираются на свёртке лагеря (_start_pack); каждая сама queue_free'ится на
## завершении/разрушении и erase'ится через destroyed-сигнал.
var _construction_sites: Array[Node] = []
## Часы PACKING_RETURNING: тикают с момента _start_pack. По достижении
## pack_timeout — _finalize_pack принудительно, даже если кто-то не дома.
var _pack_elapsed: float = 0.0
## Позиция башни на прошлом кадре — для эпсилон-чека неподвижности.
var _last_target_pos: Vector3 = Vector3.INF
## Гномы лагеря — gnomes_per_tent × количество палаток. Создаются в _ready.
var _gnomes: Array[Gnome] = []
## Активные стрелковые посты (ArcherPost), построенные через
## BUILDING_ARCHER_POST. Camp подписан на каждый на `destroyed` (респавн
## gatherer'а на месте) и на pack — вычищает массив через
## _dismantle_archer_posts(). Гном считается «внутри поста», пока пост стоит.
var _archer_posts: Array[ArcherPost] = []
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
## Полярный грид строительства вокруг харвестера (ядра). Создаётся программно в
## _ready (как _anchor_drop_zone). На развёртке встаёт в anchor и показывает
## ячейки, на свёртке гасит и роняет блоки. Механика установки/связности — в BuildGrid.
var _build_grid: BuildGrid = null
## Area3D в центре развёрнутого лагеря, ловит брошенные рукой ResourcePile.
## Создаётся в _ready, monitoring=false. На _start_deploy ставится на anchor
## и включается; на _start_pack — выключается. Polling каждый кадр через
## _consume_piles_in_drop_zone — так ловим и кучи, которые пролежали под
## рукой и были отпущены уже внутри зоны (body_entered не сработал бы).
var _anchor_drop_zone: Area3D = null

## Текущий режим сбора (см. CollectionMode). Меняется через set_collection_mode
## (хоткеи C / V в _handle_input, или из API). HUD рисует индикатор.
var _collection_mode: CollectionMode = CollectionMode.FREE

## Караван «остановлен на месте» в State.CARAVAN_FOLLOWING. Палатки не
## двигаются за башней (`_update_caravan_follow` ранний return), но и не
## разворачиваются — гномы остаются IN_TENT. Tower продолжает кататься
## независимо. Toggle через Q (`caravan_halt_toggle`) или
## `set_caravan_halted(value)`. Имеет смысл только в CARAVAN_FOLLOWING —
## в DEPLOYED палатки и так стоят, в PACKING_RETURNING ждут гномов.
## Сбрасывается при _start_deploy (если каким-то образом игрок развернёт),
## чтобы не остаться в halted после возврата в caravan.
var _caravan_halted: bool = false
## Подмодуль: нормализованные веса приоритета сбора по типам (sum=1.0).
## Дефолт ставится в _init_collection_priority из @export'ов. Меняется через
## set_collection_priority (Journal-вкладка «План»). Гном читает
## get_collection_priority_weight (он применяет stock-балансировку поверх
## базовых весов из плана).
var _plan: CampCollectionPlan = CampCollectionPlan.new()

## Публичный геттер anchor'а — гномы читают, чтобы знать, куда нести ресурс.
var deploy_anchor: Vector3:
	get:
		return _deploy_anchor

# Логирование (фронт-триггеры, чтобы не спамить каждый кадр).
var _was_holding_stationary: bool = false
var _was_out_of_range: bool = false

# Snake-trail: история позиций Tower'а для caravan-following. Head=index 0
# (новейшая записанная точка), tail = старейшая. Каждый сегмент каравана
# (Harvester, палатки, гномы-followers) занимает точку на накопленной
# дистанции от tower'а — это даёт snake-like следование «по тому же пути»
# вместо exp_decay-рывков пропорциональных дистанции.
var _tower_trail: Array[Vector3] = []

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

## Радиус кольца спавна юнитов вокруг центра в [method cheat_summon_squad].
## Достаточно чтобы не наслаивались в одной точке, мало чтобы остаться
## внутри камп-зоны.
const CHEAT_SQUAD_SPAWN_RADIUS: float = 2.0

## Множитель урона при принудительном демонтаже структуры (archer post,
## etc.). 2× hp_max — гарантия kill'а в один take_damage'е даже если
## где-то есть mitigation (там нет, но защитнее).
const FORCED_DEMOLISH_DAMAGE_MULT: float = 2.0


func _ready() -> void:
	add_to_group(CAMP_GROUP)
	if not target_path.is_empty():
		_tower = get_node_or_null(target_path) as Node3D
	if not _tower and not start_deployed:
		push_warning("Camp: target_path не разрешился, башня не задана")

	# Палаток больше нет — гномы живут в башне (_spawn_gnomes привязывает дом к _tower).
	_spawn_harvester()
	_spawn_gnomes()
	_build_anchor_drop_zone()
	_build_build_grid()
	# Seed snake-trail синтетической линейкой за tower'ом, чтобы первый
	# кадр _update_caravan_follow не сдвигал палатки рывком к (0,0,0).
	_seed_tower_trail()
	# Re-emit изменений плана сбора в EventBus (гномы слушают через EventBus,
	# не через прямую ссылку на Camp — autoload-стиль). Подписка ДО _init,
	# чтобы первый emit при инициализации тоже долетел.
	_plan.weights_changed.connect(func(weights: Dictionary) -> void:
		EventBus.collection_priority_changed.emit(weights)
	)
	_init_collection_priority()

	# Re-emit на глобальный EventBus — для UI / звука / статистики.
	deployed.connect(func(anchor: Vector3) -> void: EventBus.camp_deployed.emit(anchor))
	packed.connect(func() -> void: EventBus.camp_packed.emit())

	# Башня может погибнуть — обнуляем ссылку, чтобы караван не follow'ил мёртвый
	# (но всё ещё существующий статикой) Tower-меш. _update_caravan_follow и
	# stationary-чек уже null-safe, ничего больше делать не нужно.
	EventBus.tower_destroyed.connect(_on_tower_destroyed)

	# Ядро (харвестер) может погибнуть — обнуляем ссылку, чтобы пересчёт добычи
	# не дёргал freed-ноду. Поражение матча эмитит MatchGoal (слушает тот же сигнал).
	EventBus.harvester_destroyed.connect(_on_harvester_destroyed)

	# Шкала «великой силы»: накапливается по нанесённому damage'у врагам.
	# enemy_damaged эмитится re-emit'ом из Enemy.damaged → Skeleton наследует.
	# 1 hp damage = 1 charge; full bar (super_charge_max) разрешает супер-каст.
	EventBus.enemy_damaged.connect(_on_enemy_damaged)
	EventBus.super_charge_changed.emit(_super_charge, super_charge_max)

	# XP отряда — напрямую за каждое убийство (независимо от сбора орбов; орбы
	# теперь только мана). Попап «+N» появляется над трупом.
	EventBus.enemy_destroyed.connect(_on_enemy_killed)

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
	if gnome_scene == null:
		if debug_log and LogConfig.master_enabled:
			print("[Camp] gnome_scene не задана — никого не спавним")
		return
	# Палаток нет — гномы живут В БАШНЕ. Дом каждого гнома = _tower: IN_TENT
	# прячет его у башни (невидим, неуязвим), request_return (тревога) возвращает
	# туда же. До первой установки харвестера сидят в башне; на deploy выходят.
	var home: Node3D = _tower if _tower != null else self
	for i in range(initial_gnome_count):
		_spawn_one_gnome(gnome_scene, home, "gatherer")


## Инстанцирует одну сцену гнома, привязывает к палатке.
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


## Считает живых гномов-собирателей. Soldier'ы (pikeman, archer_squad)
## мобилизованы через recruit_squad и не собирают, поэтому исключаются.
func gatherer_count() -> int:
	var n := 0
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g.is_in_group(SoldierGnome.SOLDIER_GROUP):
			continue
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
## Палаток больше нет — структурная цель волны это ядро базы: харвестер (если
## жив), иначе башня. WaveDirector назначает forced_target на неё; гномы снаружи
## и так в SKELETON_TARGET_GROUP и берутся broad-phase'ом.
func nearest_part_to(_pos: Vector3) -> Node3D:
	if _harvester != null and is_instance_valid(_harvester):
		return _harvester
	if _tower != null and is_instance_valid(_tower):
		return _tower
	return null


## True пока жива база — харвестер или башня (палаток больше нет).
func has_alive_parts() -> bool:
	if _harvester != null and is_instance_valid(_harvester):
		return true
	return _tower != null and is_instance_valid(_tower)


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
	# Гейт здания-производителя: казарма нужного типа должна быть построена.
	var req: StringName = data.get("requires_building", &"")
	if req != &"" and not has_built_building(req):
		return false
	if not economy.can_afford(data.get("cost", {})):
		return false
	var squad_size: int = SoldierSystem.get_squad_size(soldier_type)
	return gatherer_count() >= squad_size + get_recruit_reserve()


## True если в гриде есть хотя бы одно ПОСТРОЕННОЕ здание заданного типа.
## Гейт найма: казарма-производитель должна стоять, чтобы призвать её отряд.
func has_built_building(id: StringName) -> bool:
	return _build_grid != null and _build_grid.count_built(id) > 0


## Призвать отряд заданного типа. Создаёт Squad-объект и заполняет его
## squad_size солдатами. Каждый солдат — конвертированный gatherer.
## Возвращает Squad или null при провале.
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
	# Гейт здания-производителя (дублируем can_recruit_squad на случай обхода UI).
	var req: StringName = data.get("requires_building", &"")
	if req != &"" and not has_built_building(req):
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

	# Отряд ПРОИЗВОДИТСЯ У КАЗАРМЫ-производителя (req-здание): спавним кольцом
	# вокруг неё, дефолтная команда — HOLD в её центре. Гном-сборщики при этом
	# «расходуются» (replacement_gatherers), но солдаты появляются у казармы.
	var center: Vector3 = _recruit_origin(req, gatherers)
	var spawn_positions: Array[Vector3] = []
	for i in range(gatherers.size()):
		var ang: float = TAU * float(i) / float(gatherers.size())
		spawn_positions.append(center + Vector3(
			cos(ang) * RECRUIT_SPAWN_RADIUS, 0.0, sin(ang) * RECRUIT_SPAWN_RADIUS))
	var squad := _build_and_register_squad(soldier_type, data, spawn_positions, center, gatherers)
	if squad == null:
		# Полный провал спавна — возвращаем cost (gatherer'ы НЕ конвертированы,
		# на them rollback не нужен).
		for type in cost:
			economy.add_resource(type, int(cost[type]))
		return null

	if debug_log and LogConfig.master_enabled:
		print("[Camp] призван %s, gatherer'ов: %d, солдат: %d" % [str(squad), gatherer_count(), soldier_count()])
	return squad


## Радиус кольца спавна солдат вокруг точки производства (у казармы).
const RECRUIT_SPAWN_RADIUS := 1.6

## Точка производства отряда: центр (X/Z) построенной казармы-производителя на
## уровне земли лагеря. Фоллбэк (req пуст / казармы вдруг нет) — центр сборщиков.
func _recruit_origin(req: StringName, gatherers: Array[Gnome]) -> Vector3:
	if req != &"" and _build_grid != null:
		var b: BuildBlock = _build_grid.find_built(req)
		if b != null and is_instance_valid(b):
			return Vector3(b.global_position.x, global_position.y, b.global_position.z)
	var c: Vector3 = Vector3.ZERO
	if gatherers.size() > 0:
		for g in gatherers:
			c += g.global_position
		c /= float(gatherers.size())
	return c


## Сколько юнитов указанного типа сейчас в лагере. Геттер для UI журнала.
func get_recruit_count(soldier_type: StringName) -> int:
	if SoldierSystem == null:
		return 0
	var data: Dictionary = SoldierSystem.get_soldier_data(soldier_type)
	if data.is_empty():
		return 0
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
	# Спавн кольцом вокруг центра — чтобы не наслаивались в одной точке.
	var spawn_positions: Array[Vector3] = []
	for i in range(squad_size):
		var angle: float = TAU * float(i) / float(squad_size)
		spawn_positions.append(center + Vector3(
			cos(angle) * CHEAT_SQUAD_SPAWN_RADIUS,
			0.0,
			sin(angle) * CHEAT_SQUAD_SPAWN_RADIUS,
		))
	var squad := _build_and_register_squad(soldier_type, data, spawn_positions, center, [])
	if squad == null:
		return null

	if debug_log and LogConfig.master_enabled:
		print("[Camp] CHEAT: призван %s у центра (%.1f, %.1f, %.1f)" % [
			str(squad), center.x, center.y, center.z,
		])
	return squad


func _on_squad_disbanded(squad: Squad) -> void:
	_squads.erase(squad)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] отряд %s распущен (все погибли)" % str(squad))
	EventBus.squad_disbanded.emit(squad)


func _on_squad_changed(squad: Squad) -> void:
	EventBus.squad_changed.emit(squad)


## Общий путь для recruit_squad и cheat_summon_squad. Создаёт Squad-объект,
## инстанцирует scene.instantiate × spawn_positions.size(), регистрирует squad
## в _squads + сигналы, спавнит charge-marker, эмитит EventBus.camp_buildings_changed
## и squad_created. Возвращает Squad (или null если ни одного юнита не удалось
## спавнить — caller сам решает rollback ресурсов).
##
## - `spawn_positions` — одна позиция на юнита (1:1 длины с фактическим
##   `squad_size`). Кольцо/линия/одиночные точки — на стороне caller'а.
## - `command_center` — для дефолтного `squad.command_hold(center)`.
## - `replacement_gatherers` — если непустой и длина = spawn_positions, КАЖДЫЙ
##   спавненный соldier «заменяет» gatherer'а: gatherer уходит из `_gnomes`
##   и queue_free()'ится. Для recruit-flow (gatherer→soldier). Для cheat-flow
##   передавайте `[]` — солдаты просто добавляются к `_gnomes` без замен.
##
## Подписки на disbanded/members_changed/state_changed — CONNECT_ONE_SHOT
## только для disbanded; остальные эмитятся многократно (Squad перекомандуют).
func _build_and_register_squad(
	soldier_type: StringName,
	data: Dictionary,
	spawn_positions: Array[Vector3],
	command_center: Vector3,
	replacement_gatherers: Array[Gnome],
) -> Squad:
	var scene: PackedScene = data.get("scene", null)
	if scene == null:
		push_error("Camp._build_and_register_squad: scene не задан для %s" % soldier_type)
		return null
	var has_replacements: bool = replacement_gatherers.size() == spawn_positions.size()
	var squad := Squad.new()
	squad.id = _next_squad_id
	_next_squad_id += 1
	squad.soldier_type = soldier_type
	squad.icon_color = data.get("icon_color", Color.WHITE)
	squad.command_hold(command_center)
	var stats: Dictionary = data.get("stats", {})
	var spawned: int = 0
	for i in range(spawn_positions.size()):
		var soldier := scene.instantiate() as SoldierGnome
		if soldier == null:
			push_error("Camp._build_and_register_squad: scene не инстанцируется как SoldierGnome для %s" % soldier_type)
			continue
		add_child(soldier)
		soldier.setup_soldier(soldier_type, stats, self, spawn_positions[i])
		if has_replacements:
			var gatherer: Gnome = replacement_gatherers[i]
			if is_instance_valid(gatherer):
				_gnomes.erase(gatherer)
				gatherer.queue_free()
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
	EventBus.camp_buildings_changed.emit()
	EventBus.squad_created.emit(squad)
	return squad


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


## Команда: squad защищает лагерь — кольцо вокруг anchor'а с patrol'ом по
## периметру. Доступна ТОЛЬКО когда отряд физически в зоне строительства —
## защищать лагерь не имеет смысла «с другого конца карты». UI гейтит
## кнопку через [is_squad_in_build_zone], тут — серверный дубль на случай
## race'а / прямого вызова.
func command_squad_defend(squad: Squad) -> void:
	if squad == null:
		return
	if not _squads.has(squad):
		return
	if not is_squad_in_build_zone(squad):
		if LogConfig.master_enabled:
			print("[Camp] defend отклонён: squad#%d вне зоны строительства" % squad.id)
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
			# В DEPLOYED — выходим согласно режиму (FREE: idle / WORK: сбор / ALARM).
			# В CARAVAN-фазе оставляем как есть: setup → IN_TENT → старт следующей
			# свёртки/развёртки выведет наружу нормальным путём.
			if _state == State.DEPLOYED:
				_apply_mode_to_one(gatherer)
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


## Хендлер EventBus.enemy_destroyed: XP отряда за убийство, напрямую (не через
## сбор орбов). Попап «+N» над трупом. Орбы при этом дают только ману.
func _on_enemy_killed(enemy: Node3D) -> void:
	if squad_xp_per_kill <= 0:
		return
	var pos: Vector3 = enemy.global_position if (enemy != null and is_instance_valid(enemy)) else global_position
	add_squad_xp(squad_xp_per_kill, pos)


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


## Ищет первого живого gatherer'а (Gnome без SOLDIER_GROUP). null если нет.
## Используется в can_build_reason / try_build для построек с требованием
## «1 гном» как часть стоимости.
func _find_free_gatherer() -> Gnome:
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g.is_in_group(SoldierGnome.SOLDIER_GROUP):
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
	# Pre-apply валидация: проверка которая требует params (position/facing).
	# Делается ДО списания ресурсов — иначе на неудачную постройку игрок
	# терял бы 15 wood. Используется ворот'ами (нужна стена под gate-zone),
	# можно расширить на будущие постройки с param-driven constraints.
	var params_reason := _pre_apply_validation(id, params)
	if params_reason != "":
		return {"success": false, "reason": params_reason}
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
	# Возведение через стройплощадку (время + прогресс): реальный _apply_building
	# откладывается до завершения. Ресурсы/гном уже списаны (commit). Сорвут
	# стройку скелеты — здание не появится (см. ConstructionSite). camp_buildings_changed
	# эмитится по факту появления здания (в колбэке), не на старте.
	var site_pos: Vector3 = params.get("position", _deploy_anchor)
	var on_complete := func() -> void:
		if _apply_building(id, params):
			EventBus.camp_buildings_changed.emit()
			if debug_log and LogConfig.master_enabled:
				print("[Camp:Build] %s построено" % id)
		else:
			push_warning("Camp.try_build: apply провалился для id=%s на завершении стройки" % id)
	_spawn_construction_site(site_pos, _build_time_for(id), on_complete, 0.0, str(id))
	if debug_log and LogConfig.master_enabled:
		print("[Camp:Build] %s — стройка началась" % id)
	return {"success": true, "reason": ""}


# --- Стройплощадки (время возведения) ---

## Время возведения для постройки id. CAMP_BUILDING_CATALOG[id].build_time
## переопределяет общий build_time, если задано.
func _build_time_for(id: StringName) -> float:
	var data: Dictionary = CAMP_BUILDING_CATALOG.get(id, {})
	return float(data.get("build_time", build_time))


## Ставит стройплощадку на pos: показывает прогресс dur секунд, по завершении
## зовёт on_complete (спавн настоящего здания). start_delay>0 — для «волны»
## палисада. Если construction_site_scene не задана / сцена не резолвится —
## graceful fallback: строим сразу (старое мгновенное поведение).
func _spawn_construction_site(pos: Vector3, dur: float, on_complete: Callable, start_delay: float, label: String, light_fx: bool = false) -> void:
	var scene_root: Node = get_tree().current_scene
	if construction_site_scene == null or not is_instance_valid(scene_root):
		if on_complete.is_valid():
			on_complete.call()
		return
	var site := construction_site_scene.instantiate() as ConstructionSite
	if site == null:
		push_warning("Camp: construction_site_scene не инстанцируется как ConstructionSite")
		if on_complete.is_valid():
			on_complete.call()
		return
	scene_root.add_child(site)
	site.setup(pos, dur, on_complete, start_delay, label, light_fx)
	_construction_sites.append(site)
	# tree_exited (не destroyed) — erase и на завершении (_complete), и на сломе
	# (_fail), и на despawn'е. destroyed шлётся только при сломе → копились бы
	# freed-ссылки от достроенных.
	site.tree_exited.connect(func() -> void: _construction_sites.erase(site))


## Убирает все незавершённые стройплощадки (свёртка лагеря). Ресурсы уже
## потрачены — не возвращаем (как и при разрушении стройки скелетами).
func _despawn_construction_sites() -> void:
	for s in _construction_sites:
		if is_instance_valid(s):
			s.queue_free()
	_construction_sites.clear()


## Применяет эффект постройки по id. Вынесен в отдельную функцию (а не switch
## внутри try_build) — каждая постройка получит свой _build_X метод с
## специфичными параметрами (палатки, башни, апгрейды). Возвращает true на
## успех, false при ошибке инстанцирования.
func _apply_building(id: StringName, params: Dictionary) -> bool:
	match id:
		BUILDING_NEW_TENT:
			return _build_new_tent()
		BUILDING_ARCHER_POST:
			return _build_archer_post(params)
		CampBuildings.WALL_GATE:
			return _build_wall_gate(params)
	push_error("Camp._apply_building: нет handler для id=%s" % id)
	return false


## Параметрическая валидация (требует params, поэтому не в can_build_reason).
## Возвращает причину failure или "" если всё OK. Сейчас используется только
## воротами (проверка наличия стены под gate-zone); расширяется по мере того
## как появляются другие постройки с param-driven constraints.
func _pre_apply_validation(id: StringName, params: Dictionary) -> String:
	match id:
		CampBuildings.WALL_GATE:
			var pos: Vector3 = params.get("position", Vector3.INF)
			var facing: Vector3 = params.get("facing_dir", Vector3.FORWARD)
			if pos == Vector3.INF:
				return "ошибка прицеливания"
			var walls: Array = find_palisade_walls_under_gate(pos, facing)
			if walls.size() < 2:
				return "стена под воротами короче 4м (нужно ≥2 сегмента)"
	return ""


## Ищет сегменты палисада (PalisadeSegment.is_post=false) под зоной ворот:
## зона = pos ± facing × GATE_WALL_MATCH_HALF_WIDTH (вдоль оси ворот) ×
## ± perp_h × GATE_WALL_MATCH_PERP (поперёк). Возвращает **до 2 ближайших
## по abs(along) сегментов** — те, которые ворота физически перекрывают.
## Если в зоне больше 2 (например ворота посажены ровно на центр сегмента
## и захватывают и левого, и правого соседа), берём 2 ближайших, остальные
## оставляем — иначе получалась бы дыра шире ворот. HandBuildAim снапит
## позицию в середину между двумя соседями, чтобы always-2.
##
## GATE_WALL_MATCH_HALF_WIDTH должен совпадать с [WallGate.GATE_WIDTH]/2
## (4.0 / 2 = 2.0) — литерал т.к. constant cross-class не считается
## constant expression в GDScript. Публичный — HandBuildAim вызывает для
## превью валидности перед самой постройкой.
const GATE_WALL_MATCH_PERP: float = 1.0
const GATE_WALL_MATCH_HALF_WIDTH: float = 2.0
func find_palisade_walls_under_gate(pos: Vector3, facing: Vector3) -> Array:
	var facing_h := Vector3(facing.x, 0.0, facing.z)
	if facing_h.length_squared() < 0.0001:
		return []
	facing_h = facing_h.normalized()
	var perp_h := facing_h.cross(Vector3.UP).normalized()
	# Собираем кандидатов с along-distance, потом сортируем и берём 2 ближайших.
	var candidates: Array = []
	for node in get_tree().get_nodes_in_group(PalisadeSegment.PALISADE_WALL_GROUP):
		if not is_instance_valid(node):
			continue
		var seg: PalisadeSegment = node as PalisadeSegment
		if seg == null:
			continue
		var to_seg: Vector3 = seg.global_position - pos
		to_seg.y = 0.0
		var along: float = to_seg.dot(facing_h)
		var perp: float = to_seg.dot(perp_h)
		if absf(along) <= GATE_WALL_MATCH_HALF_WIDTH and absf(perp) <= GATE_WALL_MATCH_PERP:
			candidates.append({"seg": seg, "abs_along": absf(along)})
	candidates.sort_custom(func(a, b): return a["abs_along"] < b["abs_along"])
	var out: Array = []
	for i in range(mini(2, candidates.size())):
		out.append(candidates[i]["seg"])
	return out


## Эффект BUILDING_WALL_GATE: удаляет найденные сегменты палисада, спавнит
## ворота в найденную ось. Вызывается после успешной [_pre_apply_validation],
## поэтому валидность стены гарантирована.
func _build_wall_gate(params: Dictionary) -> bool:
	if wall_gate_scene == null:
		push_warning("Camp._build_wall_gate: wall_gate_scene не задан")
		return false
	var pos: Vector3 = params.get("position", Vector3.INF)
	var facing: Vector3 = params.get("facing_dir", Vector3.FORWARD)
	if pos == Vector3.INF:
		push_error("Camp._build_wall_gate: position не задан")
		return false
	var walls: Array = find_palisade_walls_under_gate(pos, facing)
	if walls.size() < 2:
		# Должно было отвалиться в _pre_apply_validation — но защита от race
		# (палатка/стена могла рухнуть между валидацией и applу).
		push_warning("Camp._build_wall_gate: стена пропала между валидацией и apply")
		return false
	# Удаляем сегменты под зоной ворот.
	for seg in walls:
		if is_instance_valid(seg):
			seg.queue_free()
	# Спавним ворота. Якорь в current_scene — ворота переживут queue_free
	# Camp'а и не двигаются с лагерем (как ArcherPost / PalisadeSegment).
	var gate := wall_gate_scene.instantiate() as WallGate
	if gate == null:
		push_error("Camp._build_wall_gate: scene не инстанцируется как WallGate")
		return false
	get_tree().current_scene.add_child(gate)
	gate.global_position = Vector3(pos.x, _deploy_anchor.y, pos.z)
	# Ориентация: локальная +X ворот вдоль facing (= оси стены). look_at не
	# подходит — он крутит -Z; используем atan2 прямо.
	var facing_h := Vector3(facing.x, 0.0, facing.z).normalized()
	gate.rotation.y = atan2(-facing_h.z, facing_h.x)
	if debug_log and LogConfig.master_enabled:
		print("[Camp:WallGate] построены @ (%.1f, %.1f) face=(%.2f, %.2f), удалено %d сегментов" % [
			pos.x, pos.z, facing.x, facing.z, walls.size(),
		])
	# Re-bake NavMesh — ворота добавили препятствие на слое CAMP_OBSTACLE,
	# гномам нужен новый путь (через ворота для своих и так свободно).
	_rebake_navmesh()
	return true


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

	# Возведение ВОЛНОЙ: на каждый сегмент — стройплощадка со staggered стартом
	# (segment i стартует через i × palisade_segment_stagger). Реальный сегмент
	# появляется по завершении его площадки (_spawn_one_palisade_segment), которая
	# сама пере-sync'ит posts и запросит navmesh-rebake. Ресурсы уже списаны
	# (commit); сорванные стройплощадки = потерянные сегменты.
	for i in range(segments.size()):
		var seg: Dictionary = segments[i]
		var seg_pos: Vector3 = seg["pos"]
		var seg_rot: float = seg["rot_y"]
		var on_done := func() -> void:
			_spawn_one_palisade_segment(seg_pos, seg_rot)
		# light_fx=true: палисад строится десятками — без dust/колец, чтобы не
		# топить FPS. Растущий каркас остаётся индикатором.
		_spawn_construction_site(seg_pos, build_time, on_done, float(i) * palisade_segment_stagger, "palisade", true)
	if debug_log and LogConfig.master_enabled:
		print("[Camp:Palisade] стройка началась: %d сегментов (волна)" % segments.size())
	return {"success": true, "reason": "", "segments_built": segments.size()}


## Спавнит ОДИН сегмент палисада (по завершении его стройплощадки). Сразу
## пере-sync'ит posts и запрашивает debounced navmesh-rebake — стена
## «достраивается» волной, posts и проходы догоняют по мере готовности.
func _spawn_one_palisade_segment(pos: Vector3, rot_y: float) -> void:
	if palisade_segment_scene == null:
		return
	var parent: Node = get_tree().current_scene
	if not is_instance_valid(parent):
		return
	var inst := palisade_segment_scene.instantiate() as PalisadeSegment
	if inst == null:
		push_error("Camp._spawn_one_palisade_segment: scene не инстанцируется как PalisadeSegment")
		return
	parent.add_child(inst)
	inst.global_position = pos
	inst.rotation.y = rot_y
	inst.destroyed.connect(_on_palisade_segment_destroyed.bind(inst))
	_sync_palisade_posts(null)
	_request_debounced_rebake()
	EventBus.camp_buildings_changed.emit()


## Debounced navmesh-rebake (общий для build-волны и разрушений). Несколько
## событий за окно PALISADE_REBAKE_DEBOUNCE дают один bake.
func _request_debounced_rebake() -> void:
	# Каждый запрос отодвигает дедлайн (trailing) — см. _do_palisade_rebake.
	_palisade_rebake_due_msec = Time.get_ticks_msec() + int(PALISADE_REBAKE_DEBOUNCE * 1000.0)
	if _palisade_rebake_pending:
		return
	_palisade_rebake_pending = true
	get_tree().create_timer(PALISADE_REBAKE_DEBOUNCE).timeout.connect(_do_palisade_rebake)


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
## Дедлайн trailing-debounce'а (Time.get_ticks_msec). Каждый запрос отодвигает —
## bake срабатывает, когда поток запросов (волна стройки/сломов) утих.
var _palisade_rebake_due_msec: int = 0
const PALISADE_REBAKE_DEBOUNCE: float = 0.3


func _on_palisade_segment_destroyed(dying: Node) -> void:
	# Полный re-sync posts'ов: после смерти сегмента пересчитываем все
	# endpoint'ы всех уцелевших стен и ставим post РОВНО на каждом
	# «обнажённом» (= не разделённом с другой стеной на той же оси). Это
	# идемпотентно и устраняет «миграции» постов между дырами — каждый раз
	# результат тот же, что и при первой постройке + всех текущих сломов.
	if is_instance_valid(dying):
		var seg := dying as PalisadeSegment
		if seg != null and not seg.is_post:
			_sync_palisade_posts(seg)
	# Debounced re-bake navmesh'а (trailing — волна сломов даёт один bake).
	_request_debounced_rebake()


## Радиус «совпадение позиций». 0.4м с запасом — соседние сегменты с
## non-2м step_length чуть-чуть overlap'аются, их endpoint'ы не точно
## совпадают (~0.33м mismatch); 0.4м ловит обе пары как «один stitch».
const PALISADE_POST_MATCH_EPS_SQ: float = 0.4 * 0.4
## Half-length сегмента (длина mesh'а 2м, центр в середине).
const PALISADE_SEGMENT_HALF: float = 1.0


## Debug-лог sync'а — выводит targets/existing/removed/added. Включается
## при диагностике жалоб «пост остался не там где надо». По умолчанию
## выключен (на каждом ударе по палисаду 20+ строк лога — шумно).
var _palisade_sync_debug: bool = false


## Re-sync постов от текущего состояния стен. Алгоритм:
##   1. Для каждой стены 2 endpoint'а (center ± axis × 1м).
##   2. Для каждого endpoint'а считаем сколько endpoint'ов ДРУГИХ сегментов
##      попадают в радиус EPS.
##   3. Если 0 матчей → обнажённый endpoint → пост.
##      Если ≥1 матч с РАЗНОЙ осью → угол → пост (закрывает щель).
##      Если ≥1 матч с той же осью (collinear) → прямой стык → пост не нужен.
##   4. Удаляем посты не на target'ах, добавляем на target'ах где нет.
##
## Идемпотентно. Должно запускаться И на build, И на destroy.
func _sync_palisade_posts(exclude: PalisadeSegment) -> void:
	# Шаг 1: собираем сегменты + endpoint'ы.
	var segs: Array = []
	for node in get_tree().get_nodes_in_group(PalisadeSegment.PALISADE_WALL_GROUP):
		if not is_instance_valid(node) or node == exclude:
			continue
		var s: PalisadeSegment = node as PalisadeSegment
		if s == null:
			continue
		var ax: Vector3 = s.global_transform.basis.x
		ax.y = 0.0
		if ax.length_squared() < 0.0001:
			continue
		ax = ax.normalized()
		segs.append({
			"axis": ax,
			"ep1": s.global_position + ax * PALISADE_SEGMENT_HALF,
			"ep2": s.global_position - ax * PALISADE_SEGMENT_HALF,
		})
	# Шаг 2+3: для каждой endpoint'а находим матчи в других сегментах.
	var targets: Array[Vector3] = []
	for i in range(segs.size()):
		var my_axis: Vector3 = segs[i]["axis"]
		var my_eps: Array[Vector3] = [segs[i]["ep1"], segs[i]["ep2"]]
		for ep in my_eps:
			var matching_axes: Array[Vector3] = []
			for j in range(segs.size()):
				if j == i:
					continue
				var other_ep1: Vector3 = segs[j]["ep1"]
				var other_ep2: Vector3 = segs[j]["ep2"]
				if _pos_close(ep, other_ep1) or _pos_close(ep, other_ep2):
					matching_axes.append(segs[j]["axis"])
			var should_have_post: bool = false
			if matching_axes.is_empty():
				should_have_post = true  # обнажённый endpoint
			else:
				# Любой не-collinear matching → угол.
				for ax in matching_axes:
					if absf(my_axis.dot(ax)) < 0.97:
						should_have_post = true
						break
			if not should_have_post:
				continue
			# Дедуп: один target на позицию.
			var dup: bool = false
			for t in targets:
				if _pos_close(t, ep):
					dup = true
					break
			if not dup:
				targets.append(ep)
	# Шаг 4: применить targets к существующим постам.
	var existing: Array = []
	for node in get_tree().get_nodes_in_group(PalisadeSegment.PALISADE_VERTEX_GROUP):
		if not is_instance_valid(node):
			continue
		existing.append(node)
	# Debug-log: вывод состояния sync'а.
	if _palisade_sync_debug and LogConfig.master_enabled:
		print("[Palisade:Sync] segs=%d targets=%d existing=%d (exclude=%s)" % [
			segs.size(), targets.size(), existing.size(),
			str(exclude.name) if is_instance_valid(exclude) else "none",
		])
		for i in range(targets.size()):
			print("  target[%d] = (%.2f, %.2f)" % [i, targets[i].x, targets[i].z])
		for i in range(existing.size()):
			var ep := (existing[i] as Node3D).global_position
			print("  existing[%d] = (%.2f, %.2f)" % [i, ep.x, ep.z])
	# Удаляем посты не на target'ах.
	var removed: int = 0
	for post in existing:
		var n: Node3D = post as Node3D
		var keep: bool = false
		for t in targets:
			if _pos_close(n.global_position, t):
				keep = true
				break
		if not keep:
			if _palisade_sync_debug and LogConfig.master_enabled:
				print("  REMOVE post @ (%.2f, %.2f)" % [n.global_position.x, n.global_position.z])
			n.queue_free()
			removed += 1
	# Добавляем посты на target'ах где нет.
	var added: int = 0
	if palisade_post_scene == null:
		if _palisade_sync_debug and LogConfig.master_enabled:
			print("  → final: removed=%d added=0 (no scene)" % removed)
		return
	for t in targets:
		var has_post: bool = false
		for post in existing:
			if not is_instance_valid(post):
				continue
			if _pos_close((post as Node3D).global_position, t):
				has_post = true
				break
		if has_post:
			continue
		var new_post: Node3D = palisade_post_scene.instantiate() as Node3D
		if new_post == null:
			continue
		get_tree().current_scene.add_child(new_post)
		new_post.global_position = Vector3(t.x, _deploy_anchor.y, t.z)
		added += 1
		if _palisade_sync_debug and LogConfig.master_enabled:
			print("  ADD post @ (%.2f, %.2f)" % [t.x, t.z])
	if _palisade_sync_debug and LogConfig.master_enabled:
		print("  → final: removed=%d added=%d" % [removed, added])


## Helper: близость 2 точек по XZ (ignore Y) в радиусе [PALISADE_POST_MATCH_EPS].
func _pos_close(a: Vector3, b: Vector3) -> bool:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return dx * dx + dz * dz < PALISADE_POST_MATCH_EPS_SQ


func _do_palisade_rebake() -> void:
	# Trailing: пока приходят запросы (due в будущем) — переарм, не bake'аем.
	# Так волна стройки/сломов даёт ОДИН bake в конце, а не десятки подряд.
	if Time.get_ticks_msec() < _palisade_rebake_due_msec:
		get_tree().create_timer(PALISADE_REBAKE_DEBOUNCE).timeout.connect(_do_palisade_rebake)
		return
	_palisade_rebake_pending = false
	_rebake_navmesh()


## Общий гейт для garrison-зданий (archer_post): scene есть, position
## задана и попадает в build_radius. Возвращает true если можно строить.
## Лог-tag нужен только для warning'ов («Camp._build_X: …»).
func _validate_garrison_build(scene: PackedScene, pos: Vector3, log_tag: String) -> bool:
	if scene == null:
		push_warning("Camp.%s: scene не задан" % log_tag)
		return false
	if pos == Vector3.INF:
		push_warning("Camp.%s: position не задана" % log_tag)
		return false
	if not is_in_build_zone(pos):
		push_warning("Camp.%s: position вне build_radius — отказ" % log_tag)
		return false
	return true


## Спавнит gatherer'а в указанной точке (на destroy garrison-здания: гном
## «выскочил из развалин» и бежит в палатку). Find first alive tent → новый
## Gnome → set pos → entry-state по текущему Camp.state. null если палаток
## нет или gnome_scene не задан. Используется bell/archer_post-on_destroy,
## симметрично: оба теряют гарнизон, оба возвращают gatherer'а в лагерь.
func _respawn_garrison_gatherer(spawn_pos: Vector3, log_tag: String) -> Gnome:
	if gnome_scene == null:
		return null
	var tent: Node3D = null
	for p in _parts:
		if is_instance_valid(p):
			tent = p
			break
	if tent == null:
		if debug_log and LogConfig.master_enabled:
			print("[Camp:%s] разрушен, но палаток нет — гном не возрождён" % log_tag)
		return null
	var gnome := _spawn_one_gnome(gnome_scene, tent, "gatherer") as Gnome
	if gnome == null:
		return null
	gnome.global_position = spawn_pos
	# В DEPLOYED — по текущему режиму (FREE: idle / WORK: сбор / ALARM: домой),
	# в PACKING — догоняет караван.
	if _state == State.DEPLOYED:
		_apply_mode_to_one(gnome)
	elif _state == State.PACKING_RETURNING:
		gnome.request_return()
	return gnome


## Эффект BUILDING_ARCHER_POST: спавнит стационарный стрелковый пост в
## `params.position`, ориентированный по `params.facing_dir`. Гном уже изъят
## из лагеря (через _consume_gatherer в try_build, как у колокола); пост сам
## является стрелком, поэтому отдельную единицу не спавним. На разрушение —
## респавн gatherer'а на месте поста (см. _on_archer_post_destroyed).
func _build_archer_post(params: Dictionary) -> bool:
	var pos: Vector3 = params.get("position", Vector3.INF)
	var facing: Vector3 = params.get("facing_dir", Vector3.FORWARD)
	if not _validate_garrison_build(archer_post_scene, pos, "_build_archer_post"):
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
	var spawn_pos: Vector3 = post.global_position if is_instance_valid(post) else _deploy_anchor
	var gnome := _respawn_garrison_gatherer(spawn_pos, "ArcherPost")
	if gnome != null and debug_log and LogConfig.master_enabled:
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
			post.take_damage(post.hp_max * FORCED_DEMOLISH_DAMAGE_MULT)


## Эффект BUILDING_NEW_TENT: спавнит новую палатку и заселяет её
## gnomes_per_tent собирателями. Доступно только в DEPLOYED (гарантировано
## can_build_reason'ом).
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
		# Костёр для новой палатки. _spawn_one_tent добавил её в конец _parts —
		# append в конец _campfires держит индексы синхронными (нужно
		# _on_part_destroyed). Существующие костры остаются на месте (кольцо чуть
		# расширилось, лёгкий дрифт — допустимо для рантайм-постройки).
		var new_idx: int = _parts.size() - 1
		if new_idx >= 0 and new_idx < _deployed_targets.size():
			_campfires.append(_make_campfire_for(_parts[new_idx], _deployed_targets[new_idx]))
	if tent is CampPart:
		var part := tent as CampPart
		var new_gnomes: Array[Gnome] = []
		for i in range(part.gnomes_per_tent):
			var g := _spawn_one_gnome(gnome_scene, tent, "gatherer")
			if g != null:
				new_gnomes.append(g)
		# В DEPLOYED выводим наружу по текущему режиму. В FREE — перераздаём
		# idle-жизнь всем (новый костёр + новые гномы встроятся в распределение).
		if _state == State.DEPLOYED:
			if _collection_mode == CollectionMode.FREE:
				_assign_idle_life()
			else:
				for g in new_gnomes:
					_apply_mode_to_one(g)
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


## Создаёт полярный грид строительства вокруг харвестера. В каравне неактивен,
## раскрывается на _start_deploy в anchor.
func _build_build_grid() -> void:
	_build_grid = BuildGrid.new()
	_build_grid.name = "BuildGrid"
	add_child(_build_grid)
	_build_grid.bind_camp(self)
	# Изменился набор построек → пересчитать генераторы и гейтить харвестер.
	_build_grid.buildings_changed.connect(_on_grid_buildings_changed)


## Меню постройки выбрало здание — спавним его в руку игрока. Дальше он сам
## прихлопывает его в ячейку грида (BuildGrid). Требует развёрнутого лагеря.
func spawn_building_into_hand(id: StringName) -> bool:
	if build_block_scene == null:
		push_warning("Camp: build_block_scene не задана")
		return false
	if _state != State.DEPLOYED:
		return false
	var hand := get_tree().get_first_node_in_group(Hand.HAND_GROUP) as Hand
	if hand == null:
		return false
	# Уже держим кисть/здание — выбор нового ЗАМЕНЯЕТ кисть: убираем текущее из
	# руки (неоплаченную болванку удаляем) перед спавном/хватом нового. Иначе
	# hold_item упёрся бы в занятую руку (orphan новой болванки).
	if _build_grid != null and _build_grid.has_method(&"is_build_active") and _build_grid.is_build_active():
		_build_grid.cancel_build()
	# Некоторые здания (ворота) — своя сцена-наследник BuildBlock (поле "scene"
	# в каталоге). Иначе обычный build_block_scene.
	var scene_path: String = CampBuildings.get_data(id).get("scene", "")
	var scene: PackedScene = (load(scene_path) as PackedScene) if scene_path != "" else build_block_scene
	if scene == null:
		push_warning("Camp: сцена здания не загрузилась (%s)" % id)
		return false
	var block := scene.instantiate() as BuildBlock
	if block == null:
		push_warning("Camp: сцена здания не инстанцируется как BuildBlock")
		return false
	var root: Node = get_tree().current_scene
	if root == null:
		root = self
	root.add_child(block)
	block.configure(id)
	# Сразу придаём зданию размер его ячейки (по кольцу-tier) — в руке оно уже
	# нужного размера, а не компактная болванка. На установке conform повторится
	# с теми же размерами (то же кольцо).
	if _build_grid != null:
		# gapless-здание (стена/ворота/блиндаж) сразу в руке полноширинное (без
		# зазора-улицы) — как встанет; inset (генератор/казарма/портал) — с зазором.
		var dims: Dictionary = _build_grid.tier_cell_dims(block.ring_tier, block.footprint, block.is_gapless())
		block.conform_to_cell(dims["inner"], dims["outer"], dims["seg_deg"])
	block.global_position = hand.global_position
	hand.hold_item(block)
	return true


## Пересчёт генераторов: скорость добычи харвестера масштабируется их числом.
## 0 → стоит; min_generators_to_mine → стартует на min_generator_yield_frac;
## линейно до полной скорости на generators_required; больше — потолок (1.0).
func _on_grid_buildings_changed() -> void:
	# Набор зданий изменился (постройка/слом/перенос) → пересобрать навмеш, чтобы
	# гномы/скелеты огибали новые здания (и не огибали снесённые). Debounce —
	# волна построек/сломов в одном кадре даёт один bake.
	_request_debounced_rebake()
	# UI журнала реагирует на набор зданий: вкладка «Армия» гейтит найм по
	# построенным казармам (can_recruit_squad), «Лагерь» — счётчики.
	EventBus.camp_buildings_changed.emit()
	if _harvester == null or _build_grid == null:
		return
	_harvester.set_production_scale(_generator_production_scale(_build_grid.generator_count()))


## Доля [0..1] полной скорости добычи по числу установленных генераторов.
func _generator_production_scale(gens: int) -> float:
	if gens < min_generators_to_mine:
		return 0.0
	if gens >= generators_required:
		return 1.0
	var span: int = generators_required - min_generators_to_mine
	if span <= 0:
		return 1.0
	var t: float = float(gens - min_generators_to_mine) / float(span)
	return lerpf(min_generator_yield_frac, 1.0, t)


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
## типам ресурсов; будут нормализованы к сумме 1.0. Все ключи —
## ResourcePile.ResourceType. Делегируется в [CampCollectionPlan];
## EventBus.collection_priority_changed эмитится через подписку в _ready.
func set_collection_priority(weights: Dictionary) -> void:
	_plan.set_weights(weights)


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
	var base: float = _plan.get_weight(type)
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
	# Базовый план (без stock-балансировки) — UI показывает план как задал
	# игрок. Эффективные веса (с учётом stock) — через
	# get_collection_priority_weight.
	return _plan.get_weights()


func get_collection_mode() -> int:
	return _collection_mode


## Переключает режим сбора. WORK — все gatherer'ы возвращаются к работе
## (enter_deployed → SEARCHING). ALARM — все gatherer'ы → request_return
## (бегут в палатки → IN_TENT, скрыты, неуязвимы).
##
## SoldierGnome (pikeman/archer-squad) пропускается — они в squad-flow,
## своё AI без оглядки на gatherer-mode. Режим имеет эффект только в
## DEPLOYED — в каравне/при свёртке гномы и так в палатках или идут туда.
func set_collection_mode(mode: int) -> void:
	if _collection_mode == mode:
		return
	_collection_mode = mode
	EventBus.collection_mode_changed.emit(mode)
	if debug_log and LogConfig.master_enabled:
		print("[Camp] режим сбора: %s" % CollectionMode.keys()[mode])
	if _state != State.DEPLOYED:
		return
	# FREE раздаётся глобально (распределение по кострам/слотам — _assign_idle_life),
	# WORK/ALARM — per-gnome.
	if mode == CollectionMode.FREE:
		_assign_idle_life()
		return
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g is SoldierGnome:
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
	# Если лагерь уже DEPLOYED — новые гномы выходят согласно текущему режиму
	# (FREE: idle-жизнь / WORK: сбор / ALARM: в палатки), иначе сидели бы IN_TENT.
	if _state == State.DEPLOYED:
		_reapply_collection_mode()
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
	# Костёр этой палатки (индекс синхронен) — убираем синхронно.
	if idx < _campfires.size():
		var fire: Node3D = _campfires[idx]
		if is_instance_valid(fire):
			fire.queue_free()
		_campfires.remove_at(idx)
	# Переназначаем сиротских гномов на ближайшую живую палатку. Без этого
	# гном с _home_tent → freed-инстансом застревает: при request_return
	# _tick_returning видит null tent и сразу _enter_in_tent на текущей
	# позиции (становится невидим где-то в поле), а в CARAVAN_FOLLOWING
	# IN_TENT-приклейка к null'у не работает — он не двигается с караваном.
	# Если живых палаток вообще не осталось — просто оставляем _home_tent=null,
	# гномы продолжают жить на местах (Camp всё равно невалиден для волн).
	_reassign_orphan_gnomes(part)
	# В FREE перераспределяем idle-жизнь: tender'ы исчезнувшего костра и
	# осиротевшие гномы встанут к оставшимся кострам / станут бродягами.
	if _state == State.DEPLOYED and _collection_mode == CollectionMode.FREE:
		_assign_idle_life()
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


## Ядро уничтожено — обнуляем ссылку (пересчёт добычи в _on_grid_buildings_changed
## null-safe станет no-op). Поражение матча ведёт MatchGoal через тот же сигнал.
func _on_harvester_destroyed() -> void:
	if debug_log and LogConfig.master_enabled:
		print("[Camp] ядро (харвестер) уничтожено")
	_harvester = null


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


## True если центр отряда в зоне строительства лагеря (build_radius от
## _deploy_anchor). Защита «Защищать лагерь» — лагерное действие: команда
## имеет смысл только когда отряд физически рядом с лагерем. Не пускаем
## защиту с другого конца карты (включая dungeon). В свёрнутом лагере
## (_state != DEPLOYED) — false: зоны строительства нет.
func is_squad_in_build_zone(squad: Squad) -> bool:
	if _state != State.DEPLOYED:
		return false
	if squad == null or squad.count_alive() == 0:
		return false
	return is_in_build_zone(_squad_alive_center(squad))


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
			# Харвестер установлен НАВСЕГДА — свернуть нельзя (pack удалён). Чтобы
			# уйти: собрать гномов в башню (тревога) и уехать башней; харвестер и
			# постройки остаются. R в развёрнутом состоянии ничего не делает.
			pass
		State.PACKING_RETURNING:
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
	# Cache hit: либо null (нет POI в радиусе), либо живой Node. На freed-POI
	# (теоретически — пока POI не разрушаются, но защита есть) — invalidate
	# и пересчёт ниже. Раньше условие читалось обратно («null И валиден»),
	# что было верно по смыслу, но запутывало читающего.
	if cache_age_msec < int(POI_CACHE_TTL_SEC * 1000.0):
		if _poi_cache == null:
			return null
		if is_instance_valid(_poi_cache):
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
	# Палаток нет — кольца целей не строим.
	_deployed_targets.clear()
	_deploy_hold = 0.0
	_pack_hold = 0.0
	_was_holding_stationary = false
	if debug_log and LogConfig.master_enabled:
		print("[Camp] харвестер установлен @ (%.1f, %.1f, %.1f)" % [_deploy_anchor.x, _deploy_anchor.y, _deploy_anchor.z])
	deployed.emit(_deploy_anchor)
	# Tower уходит из аггро-цели — скелеты переключаются на гномов/ядро.
	_set_tower_aggro(false)
	# Гномы ВЫХОДЯТ из башни на установке харвестера в состоянии СВОБОДНЫХ —
	# бродят вокруг ядра. «Работа» (C) → добыча, «Тревога» (V) → обратно в башню.
	_collection_mode = CollectionMode.FREE
	EventBus.collection_mode_changed.emit(CollectionMode.FREE)
	_assign_idle_life()
	# Уровень земли под anchor — через башню (палаток-референса больше нет).
	var ground_y: float = _ground_y_at(_tower, _deploy_anchor) if _tower != null else 0.0
	# Центральный слот для модулей переезжает в anchor и активируется.
	if _center_slot:
		_center_slot.global_position = Vector3(_deploy_anchor.x, ground_y, _deploy_anchor.z)
		_center_slot.enabled = true
	# Anchor drop zone: переехала на anchor, начинает пожирать брошенные кучи.
	if _anchor_drop_zone != null:
		_anchor_drop_zone.global_position = Vector3(_deploy_anchor.x, _deploy_anchor.y + 0.5, _deploy_anchor.z)
		_anchor_drop_zone.monitoring = true
	# Харвестер врастает НАВСЕГДА (одноразовая установка — pack удалён) и качает золото.
	if _harvester != null:
		_harvester.deploy_on(Vector3(_deploy_anchor.x, ground_y, _deploy_anchor.z))
	# Полярный грид строительства раскрывается вокруг ядра (харвестера).
	if _build_grid != null:
		_build_grid.deploy(Vector3(_deploy_anchor.x, ground_y, _deploy_anchor.z))
	# Ядро встало на финальную позицию и теперь препятствие навмеша — ребейк,
	# чтобы гномы/скелеты огибали его (а не первичный bake у caravan-позиции).
	_request_debounced_rebake()


# --- Idle-«жизнь лагеря» (режим FREE): костры + распределение гномов ---

## Создаёт костёр для палатки на её ring-target'е, смещённый к центру лагеря
## (костёр между палаткой и anchor'ом — кольцо костров смотрит внутрь). Старт
## UNLIT. Возвращает ноду костра или null (scene не задана / не инстанцируется).
func _make_campfire_for(tent: Node3D, tent_target: Vector3) -> Node3D:
	if campfire_scene == null:
		return null
	var scene_root := get_tree().current_scene
	if not is_instance_valid(scene_root):
		return null
	var to_center: Vector3 = _deploy_anchor - tent_target
	to_center.y = 0.0
	var dir: Vector3 = to_center.normalized() if to_center.length() > 0.01 else Vector3.FORWARD
	var fire_pos: Vector3 = tent_target + dir * campfire_offset
	fire_pos.y = _ground_y_at(tent, fire_pos)
	var fire := campfire_scene.instantiate() as Node3D
	if fire == null:
		push_warning("Camp: campfire_scene не инстанцируется как Node3D")
		return null
	scene_root.add_child(fire)
	fire.global_position = fire_pos
	return fire


## Спавнит по одному костру у каждой палатки. Индекс _campfires СИНХРОНЕН с
## _parts/_deployed_targets (даже если костёр null при незаданной scene) —
## _on_part_destroyed удаляет по idx. Зовётся из _start_deploy.
func _spawn_campfires_for_deploy() -> void:
	_despawn_campfires()
	for i in range(_parts.size()):
		if i >= _deployed_targets.size():
			break
		_campfires.append(_make_campfire_for(_parts[i], _deployed_targets[i]))


func _despawn_campfires() -> void:
	for f in _campfires:
		if is_instance_valid(f):
			f.queue_free()
	_campfires.clear()


## count точек по кольцу fire_slot_radius вокруг костра — слоты, на которые
## садятся гномы. Слоты считает Camp (единый источник истины, как ring палаток),
## сам Campfire их не хранит.
func _fire_slot_positions(fire_pos: Vector3, count: int) -> Array:
	var slots: Array = []
	var n: int = maxi(count, 1)
	for i in range(n):
		var angle: float = float(i) * TAU / float(n)
		slots.append(Vector3(
			fire_pos.x + cos(angle) * fire_slot_radius,
			fire_pos.y,
			fire_pos.z + sin(angle) * fire_slot_radius,
		))
	return slots


## Раздаёт живым gatherer'ам idle-роли (режим FREE). Первые ~fire_slot_ratio
## садятся у костров по слотам (round-robin по кострам — каждый получает хотя бы
## одного, первый поджигает), остальные — бродяги. Пропускает SoldierGnome
## (свой squad-flow) и бездомных (идут за караваном). Костров нет → все бродяги.
func _assign_idle_life() -> void:
	var gatherers: Array = []
	for g in _gnomes:
		if not is_instance_valid(g):
			continue
		if g is SoldierGnome:
			continue
		if g.is_following_caravan():
			continue
		gatherers.append(g)

	var fires: Array = []
	for f in _campfires:
		if is_instance_valid(f):
			fires.append(f)

	if fires.is_empty():
		# Костров нет → свободные гномы бродят вокруг харвестера-ядра (это и есть
		# нормальное состояние «свободного»). «Работа» → добыча, «Тревога» → башня.
		for g in gatherers:
			g.enter_idle_life(Gnome.IdleRole.WANDERER, null, Vector3.INF, false)
		return

	# Параллельные массивы состояния по кострам (слоты / курсор слота / зажжён ли
	# назначен разжигатель).
	var fire_slots: Array = []
	var fire_next: Array = []
	var fire_lit_assigned: Array = []
	for f in fires:
		fire_slots.append(_fire_slot_positions(f.global_position, fire_slots_per_fire))
		fire_next.append(0)
		fire_lit_assigned.append(false)

	var total: int = gatherers.size()
	var n_fire: int = int(round(float(total) * fire_slot_ratio))
	# Гарантируем разжигателя на каждый костёр (но не больше, чем всего гномов).
	n_fire = clampi(n_fire, mini(fires.size(), total), total)

	for idx in range(total):
		var g = gatherers[idx]
		if idx < n_fire:
			var fi: int = idx % fires.size()
			var slots: Array = fire_slots[fi]
			var slot_i: int = fire_next[fi] % maxi(slots.size(), 1)
			fire_next[fi] = fire_next[fi] + 1
			var should_light: bool = not fire_lit_assigned[fi]
			fire_lit_assigned[fi] = true
			g.enter_idle_life(Gnome.IdleRole.FIRE_TENDER, fires[fi], slots[slot_i], should_light)
		else:
			g.enter_idle_life(Gnome.IdleRole.WANDERER, null, Vector3.INF, false)


## Применяет ТЕКУЩИЙ режим ко всем gatherer'ам (новый набор гномов на deploy'е
## уже стоит). Используется reset_population. FREE раздаётся глобально.
func _reapply_collection_mode() -> void:
	if _collection_mode == CollectionMode.FREE:
		_assign_idle_life()
		return
	for g in _gnomes:
		if not is_instance_valid(g) or g is SoldierGnome:
			continue
		if _collection_mode == CollectionMode.WORK:
			g.enter_deployed()
		else:
			g.request_return()


## Применяет текущий режим к ОДНОМУ новому гному (постройка палатки, рекрут,
## конверсия солдата обратно). В FREE — бродяга (общий _assign_idle_life
## перераздаст костры при следующем общем событии). SoldierGnome не трогаем.
func _apply_mode_to_one(g) -> void:
	if g == null or not is_instance_valid(g) or g is SoldierGnome:
		return
	match _collection_mode:
		CollectionMode.FREE:
			g.enter_idle_life(Gnome.IdleRole.WANDERER, null, Vector3.INF, false)
		CollectionMode.WORK:
			g.enter_deployed()
		CollectionMode.ALARM:
			g.request_return()


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
	# Костры idle-жизни демонтируются — лагерь снимается с места.
	_despawn_campfires()
	# Незавершённые стройки отменяются (лагерь уходит). Ресурсы не возвращаем.
	_despawn_construction_sites()
	for g in _gnomes:
		if is_instance_valid(g):
			g.request_return()


func _finalize_pack() -> void:
	_state = State.CARAVAN_FOLLOWING
	if debug_log and LogConfig.master_enabled:
		print("[Camp] лагерь свёрнут (все гномы дома)")
	# Пересеять snake-trail: после deploy палатки разлетелись в ring-формацию,
	# текущий trail (если был) указывает на старый путь tower'а ДО deploy.
	# Сейчас нужна свежая линейка за tower'ом — палатки выстроятся в строй
	# через первые кадры _update_caravan_follow.
	_seed_tower_trail()
	# Слот выключается → модуль с него отпадает (остаётся стоять на земле,
	# где был лагерь — игрок может подобрать рукой и поставить заново).
	if _center_slot:
		_center_slot.enabled = false
	# Грид сворачивается: ячейки гаснут, стоявшие блоки падают на землю (база с
	# собой целиком не едет — забираем палатки/ресурсы отдельно).
	if _build_grid != null:
		_build_grid.pack()
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

# --- Snake-trail helpers ---


## Полная длина каравана в метрах. Используется для trim'а _tower_trail —
## хранить больше точек чем нужно для последнего сегмента бессмысленно.
func _caravan_total_length() -> float:
	var total: float = 0.0
	var has_harvester: bool = _harvester != null and is_instance_valid(_harvester) and not _harvester.is_deployed()
	if has_harvester:
		total += harvester_gap
	var part_count: int = 0
	for p in _parts:
		if not is_instance_valid(p):
			continue
		if p is CampPart and (not (p as CampPart).is_in_caravan() or (p as CampPart).is_in_hand()):
			continue
		part_count += 1
	if part_count > 0:
		# Первая палатка: harvester_to_part_gap (если есть Harvester) или part_gap.
		# Остальные палатки: по part_gap каждая.
		if has_harvester:
			total += harvester_to_part_gap + float(part_count - 1) * part_gap
		else:
			total += float(part_count) * part_gap
	return total + trail_buffer_extra


## Заполняет _tower_trail синтетической линейкой за tower'ом — N точек по
## -X шагом trail_sample_step, длиной [_caravan_total_length]. Вызывается
## когда trail пуст (spawn / pack-finalize / большой телепорт tower'а).
##
## -X выбран потому что _spawn_one_tent ставит палатки именно по -X от
## tower'а (см. line 532). Так первый кадр snake-follow не дёргает их
## искусственно вбок.
func _seed_tower_trail() -> void:
	_tower_trail.clear()
	if _tower == null:
		return
	var pos: Vector3 = _tower.global_position
	_tower_trail.append(pos)
	var needed: float = _caravan_total_length()
	if needed <= 0.0 or trail_sample_step <= 0.0:
		return
	var count: int = int(ceil(needed / trail_sample_step)) + 1
	for i in range(1, count):
		_tower_trail.append(Vector3(pos.x - float(i) * trail_sample_step, pos.y, pos.z))


## Пишет новую точку в head trail'а если tower сдвинулся на ≥
## trail_sample_step с прошлой записи. Trim'ит хвост до _caravan_total_length.
func _record_tower_trail() -> void:
	if _tower == null:
		return
	var pos: Vector3 = _tower.global_position
	if _tower_trail.is_empty():
		_seed_tower_trail()
		return
	var head: Vector3 = _tower_trail[0]
	var dx: float = pos.x - head.x
	var dz: float = pos.z - head.z
	if dx * dx + dz * dz < trail_sample_step * trail_sample_step:
		return
	# Большой скачок (telepport tower'а) — переcеять. Иначе сегменты потащит
	# по странной кривой через старую позицию.
	var jump_threshold: float = trail_sample_step * 50.0
	if dx * dx + dz * dz > jump_threshold * jump_threshold:
		_seed_tower_trail()
		return
	_tower_trail.push_front(pos)
	# Trim до needed-длины (cumulative-distance walk).
	var needed: float = _caravan_total_length()
	var accumulated: float = 0.0
	var keep: int = _tower_trail.size()
	for i in range(1, _tower_trail.size()):
		var seg: float = _tower_trail[i - 1].distance_to(_tower_trail[i])
		accumulated += seg
		if accumulated >= needed:
			keep = i + 1
			break
	if keep < _tower_trail.size():
		_tower_trail.resize(keep)


## Точка на trail'е на накопленной дистанции target_dist от текущей позиции
## tower'а. Walk head→tail с накоплением длин сегментов; найден сегмент,
## где target_dist попадает между accumulated и accumulated+seg_len —
## возвращаем lerp(prev, curr, t). Если target_dist больше всей доступной
## длины — возвращаем последнюю точку (lstайл tail).
func _sample_trail_at(target_dist: float) -> Vector3:
	if _tower == null:
		return Vector3.ZERO
	if _tower_trail.is_empty() or target_dist <= 0.0:
		return _tower.global_position
	var accumulated: float = 0.0
	var prev: Vector3 = _tower.global_position
	for p in _tower_trail:
		var seg_len: float = prev.distance_to(p)
		if accumulated + seg_len >= target_dist:
			if seg_len < 1e-6:
				return p
			var t: float = (target_dist - accumulated) / seg_len
			return prev.lerp(p, t)
		accumulated += seg_len
		prev = p
	return _tower_trail[_tower_trail.size() - 1]


func _update_caravan_follow(delta: float) -> void:
	# NB: раньше тут был ранний `or _parts.is_empty()` — он оставлял Harvester'а
	# позади, если все палатки уничтожены (Harvester живёт отдельным полем, не в
	# _parts). Единственная корректная проверка «нечего двигать» — харвестер-aware
	# guard ниже, после _record_tower_trail. Всё между ними empty-safe.
	if _tower == null:
		return
	# Halted: палатки замораживаются на текущих позициях, башня едет дальше.
	# Гномы IN_TENT в каравне и так не двигаются — не нужно их трогать.
	if _caravan_halted:
		return

	# Записываем новую точку trail'а если tower сдвинулся. Это база для
	# snake-следования: сегменты читают точки по cumulative-distance от
	# головы (tower'а), скорость сегментов = скорости tower'а ровно.
	_record_tower_trail()

	# Виртуальная цепочка: только палатки, которыми Camp реально может управлять.
	# Skip'аются: torn_off (живут по физике), in_hand (Hand двигает), вне строя.
	var active_parts: Array[Node3D] = []
	for part in _parts:
		if not is_instance_valid(part):
			continue
		if part is CampPart:
			var cp := part as CampPart
			if not cp.is_in_caravan() or cp.is_in_hand():
				continue
		active_parts.append(part)
	if active_parts.is_empty() and (_harvester == null or _harvester.is_deployed()):
		return

	# Лидер для проверки «башня ушла слишком далеко» — Tower vs первая
	# палатка. Если ушла — snake-следование останавливаем (никто не двигается):
	# семантика «башня скрылась из виду, караван ждёт».
	var lead_check_node: Node3D = null
	if not active_parts.is_empty():
		lead_check_node = active_parts[0]
	elif _harvester != null and not _harvester.is_deployed():
		lead_check_node = _harvester
	if lead_check_node != null:
		var lead_dist: float = lead_check_node.global_position.distance_to(_tower.global_position)
		var leader_too_far := lead_dist > follow_max_distance
		if debug_log and LogConfig.master_enabled and leader_too_far != _was_out_of_range:
			if leader_too_far:
				print("[Camp] башня вне зоны видимости (dist=%.1f)" % lead_dist)
			else:
				print("[Camp] башня вернулась в зону видимости (dist=%.1f)" % lead_dist)
			_was_out_of_range = leader_too_far
		if leader_too_far:
			return

	# Накопленная дистанция от tower'а вдоль trail'а. Harvester — первое
	# звено (harvester_gap), палатки — далее каждая на part_gap.
	var cumulative_gap: float = 0.0
	var harvester_in_caravan: bool = _harvester != null and not _harvester.is_deployed()
	if harvester_in_caravan:
		cumulative_gap = harvester_gap
		var harvester_target: Vector3 = _sample_trail_at(cumulative_gap)
		harvester_target.y = _ground_y_at(_harvester, harvester_target)
		_move_part_kinematic(_harvester, _smooth_to(_harvester.global_position, harvester_target, delta))
	for i in range(active_parts.size()):
		# Первая палатка после Harvester'а получает увеличенный gap
		# (harvester_to_part_gap), остальные — обычный part_gap.
		if i == 0 and harvester_in_caravan:
			cumulative_gap += harvester_to_part_gap
		else:
			cumulative_gap += part_gap
		var part: Node3D = active_parts[i]
		var target_pos: Vector3 = _sample_trail_at(cumulative_gap)
		var part_offset_y: float = (part as CampPart).floor_offset_y() if part is CampPart else 0.0
		target_pos.y = _ground_y_at(part, target_pos) + part_offset_y
		_move_part_kinematic(part, _smooth_to(part.global_position, target_pos, delta))


## Лёгкая инерция поверх snake-target: фактическая позиция отстаёт от
## трэйл-точки на ~1/trail_smoothing секунд. exp-decay-форма не зависит
## от dt. Если smoothing = 0 — возвращаем target as-is (чистый snap).
func _smooth_to(current: Vector3, target: Vector3, delta: float) -> Vector3:
	if trail_smoothing <= 0.0:
		return target
	var t: float = 1.0 - exp(-trail_smoothing * delta)
	return current.lerp(target, t)


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
