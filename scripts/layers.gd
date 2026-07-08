class_name Layers
extends RefCounted
## Именованные физические слои коллизий + helper'ы для сборки масок.
## Имена и биты должны соответствовать [layer_names] в project.godot.
##
## Использование:
##     collision_layer = Layers.ITEMS
##     collision_mask = Layers.MASK_HAND_GRAB
##
## ВАЖНО: для Area3D / CharacterBody3D / RigidBody3D, созданных в .tscn,
## используем числовые литералы (Godot эдитор хранит их в .tscn). Чтобы избежать
## drift'а — после изменения слоёв в project.godot пересчитываем .tscn-маски
## через эти константы и копируем итог в .tscn (см. раздел в SPEC.md).

const TERRAIN := 1 << 0          # 1  — bit 0 = layer 1
const ITEMS := 1 << 1            # 2  — bit 1 = layer 2
const ACTORS := 1 << 2           # 4  — bit 2 = layer 3
const PROJECTILES := 1 << 3      # 8  — bit 3 = layer 4 (зарезервирован под магию)
const ENEMIES := 1 << 4          # 16 — bit 4 = layer 5
const CAMP_OBSTACLE := 1 << 5    # 32 — bit 5 = layer 6
## Слой только для CampModule в момент монтажа в слот. Башня его не сканирует
## (mask=31 без бита 6) — иначе touching-контакт «башня сверху, турель сидит»
## давал бы ложные wall-collision'ы. Hand.GrabArea его сканирует, чтобы рука
## могла снять модуль обратно.
const MOUNTED_MODULE := 1 << 6   # 64 — bit 6 = layer 7

## «Холодные» враги — зарезервированный слой. Раньше использовался для
## FAR-LOD скелетов (collision_layer=COLD_ENEMY, mask=0): они оставались
## видимы руке/сламу через MASK_HAND_TARGETS/MASK_HAND_SLAM, но не для других
## систем. На 2000 скелетах это давало 25+мс на physics broad-phase —
## BVH всё равно индексировал 2000 движущихся AABB. Теперь FAR-скелеты
## полностью исключаются из broad-phase (CollisionShape3D.disabled=true,
## collision_layer/mask=0), а слам ловит их вторым проходом по
## SKELETON_GROUP с distance²-фильтром (HandPhysicalSlam._perform_slam).
## Слой оставлен в layer_names на случай, если понадобится для других
## «исключаемых из обычного broad-phase, но видимых отдельным системам»
## сущностей в будущем.
const COLD_ENEMY := 1 << 7       # 128 — bit 7 = layer 8

## Дружественные NPC (гномы — collectors и defenders). Отдельный слой от
## ACTORS (=Tower), чтобы скелеты могли блокироваться об башню (ACTORS в
## MASK_SKELETON) и при этом проходить сквозь гномов (FRIENDLY_UNIT не
## в MASK_SKELETON). На 126 гномах в плотной толпе скелетов skel-gnome
## broad-phase пары были одной из главных нагрузок: каждая move_and_slide
## скелета процессила контакты с каждым гномом в досягаемости. Урон по
## гномам идёт через `Damageable.try_damage` на STRIKE-фазе скелета — не
## зависит от physical-collision'а, поэтому смена слоя не сломает геймплей,
## только визуально скелет проходит сквозь гнома (а не упирается).
const FRIENDLY_UNIT := 1 << 8    # 256 — bit 8 = layer 9

## Палисад (стены, столбики). Отдельный слой ОТ [CAMP_OBSTACLE] нужен чтобы
## развязать: Tower и CampPart должны упираться в палисад, но не друг в друга.
## Палисад имеет ОБА слоя одновременно (collision_layer = CAMP_OBSTACLE |
## PALISADE_OBSTACLE = 544) — Skeleton (MASK_SKELETON включает CAMP_OBSTACLE)
## блокируется им как палаткой, рука/магия (MASK_HAND_SLAM) — задевает.
## Tower и CampPart маскируют только PALISADE_OBSTACLE → блокируются стеной
## но не друг другом.
const PALISADE_OBSTACLE := 1 << 9   # 512 — bit 9 = layer 10

## Мины (трап-объекты от mine_scatter). Отдельный слой ОТ [ITEMS] нужен чтобы
## Tower (mask=575 со включённым ITEMS) физически не врезался в мины как в
## стены. Раньше мина была на ITEMS (для того чтобы AOE-силы с MASK_HAND_SLAM,
## который включает ITEMS, находили мину shape-query'ем) — но это завязывало
## мин-physics на Tower.mask. Теперь мины на собственном слое, и
## MASK_HAND_SLAM явно включает MINE_HAZARD — те же силы триггерят мины,
## но Tower/Skeleton проходят сквозь.
const MINE_HAZARD := 1 << 10        # 1024 — bit 10 = layer 11

## Слой ворот (WallGate). Отдельный от [CAMP_OBSTACLE] / [PALISADE_OBSTACLE]
## специально чтобы Tower проходила сквозь, а скелеты — нет. Tower маска
## (575) НЕ включает этот слой → ворота для неё прозрачные. MASK_SKELETON
## его ВКЛЮЧАЕТ → enemies заблокированы как стеной. Открытие/закрытие
## анимации дверей — чисто визуальное, физика не переключается.
const WALL_GATE_BLOCK := 1 << 11    # 2048 — bit 11 = layer 12

## Слой carve-proxy навмеша. Здания (BuildBlock) и палатки — RigidBody3D, а
## навмеш в режиме STATIC_COLLIDERS парсит коллайдеры ТОЛЬКО у StaticBody3D →
## RigidBody-здания не выгрызались (юниты шли сквозь). BuildBlock добавляет
## дочерний StaticBody3D с копией формы здания на ЭТОТ слой — его навмеш парсит
## (бит в geometry_collision_mask сцены), а физически его НИКТО не маскирует →
## проксти инертна, влияет ТОЛЬКО на запекание навмеша. Без GPU-readback (в
## отличие от parsed_geometry_type=BOTH, который парсил бы и импорт-меши).
const NAV_CARVE := 1 << 12          # 4096 — bit 12 = layer 13

## Настил-постройка, разрушаемая АТАКАМИ ИГРОКА (мост). Коллайдер настила на ЭТОМ
## слое: магия/слэм/burn (MASK_HAND_SLAM включает его), а также дэш и щит башни
## (явный sphere-query по этому слою) находят его и бьют через Damageable. При этом
## слой НЕ маскируют ни Tower (575 — настил не блокирует ходьбу башни по мосту), ни
## Skeleton/стрелы (враги мост не ломают), ни Искра (она бьёт только свои группы) —
## потому «разрушается всем кроме искры» выходит без единого фильтра-исключения.
const DESTRUCTIBLE_DECK := 1 << 13  # 8192 — bit 13 = layer 14

## Невидимый барьер ФЕЙКОВОЙ пропасти (ChasmBarrier: пол сплошной, дыра —
## визуал). Отдельный слой ОТ стен (2026-07-07): барьер держит БАШНЮ и
## СКЕЛЕТОВ (edge геймплея), но ПРЕДМЕТЫ проходят — мост несут/кладут ПОПЕРЁК
## пропасти, гарпун летит через. Когда предметы получили стены в маску
## (MASK_ALL_GAMEPLAY 575), барьер на 544 стал бить мост об невидимую стену.
const CHASM_BARRIER := 1 << 14      # 16384 — bit 14 = layer 15

# Композитные маски — собирай через OR из именованных битов.

## Hand cursor raycast: пол + предметы + смонтированные модули. Под цели
## "поверхностей под рукой" попадает турель на верхушке башни — иначе
## курсор пролетал бы сквозь неё (тауэр на ACTORS, не в маске).
const MASK_HAND_CURSOR := TERRAIN | ITEMS | MOUNTED_MODULE      # 67

## Hand grab / flick: всё, что рука может «увидеть» в зоне захвата.
## По дизайнерскому решению (2026-05-03) рука действует одинаково на врагов
## и на дружественных (гномы, башня, палатки): slam/flick наносят damage,
## grab подсвечивает кандидата (фактически взять можно только Grabbable
## RigidBody3D — гном/башня/палатка не RigidBody, в _find_closest_grabbable
## фильтруются). Per-target исключение — через группу HAND_IMMUNE_GROUP
## (`add_to_group("hand_immune")` или Groups-вкладка в editor'е).
## MOUNTED_MODULE — чтобы рука могла снять смонтированный модуль обратно
## с башни / центра лагеря.
## COLD_ENEMY оставлен на случай ручной пометки сущностей этим слоем; сами
## FAR-скелеты теперь имеют collision_layer=0 (Skeleton._apply_lod_physics_mode).
const MASK_HAND_TARGETS := ITEMS | ACTORS | ENEMIES | CAMP_OBSTACLE | MOUNTED_MODULE | COLD_ENEMY | FRIENDLY_UNIT  # 502

## Slam: AOE по миру, без MOUNTED_MODULE (модуль снимается только хватом).
## Те же дружественные слои, что и MASK_HAND_TARGETS — slam одинаково бьёт
## врагов, гномов, башню и палатки. Per-target иммунитет — через
## группу HAND_IMMUNE_GROUP.
## COLD_ENEMY оставлен исторически; FAR-скелеты slam ловит отдельным проходом
## по SKELETON_GROUP с distance²-фильтром в _perform_slam.
## MINE_HAZARD включён, чтобы Slam (и все «огневые» силы, использующие
## MASK_HAND_SLAM как default: Fireball, Firestorm, Super, BurnPatch)
## детонировали мины через Damageable.try_damage. Раньше мины ловились
## через бит ITEMS (мина была на ITEMS), но Tower тоже сканирует ITEMS
## и физически врезался в мины — пришлось переселить мины на отдельный
## слой и явно включить его в этой маске.
const MASK_HAND_SLAM := ITEMS | ACTORS | ENEMIES | CAMP_OBSTACLE | COLD_ENEMY | FRIENDLY_UNIT | MINE_HAZARD | DESTRUCTIBLE_DECK   # 9654

## «Всё обычное» для ПРЕДМЕТОВ (grabbable/throwable: ящик, плашка, клетка,
## кристалл, элементы Врат). 2026-07-07: + CAMP_OBSTACLE | PALISADE_OBSTACLE —
## брошенный предмет упирается в стены комнат/палисад/постройки (блокеры на 544),
## а не пролетает сквозь. Итог 575 = ровно маска Tower: предмет сталкивается
## с тем же, с чем башня. Ворота (WALL_GATE_BLOCK) намеренно НЕ включены —
## предметы проходят как башня. .tscn-литералы 31 пересчитаны → 575
## (item.tscn, bridge_plank.tscn, узлы level_rooms — см. шапку файла).
const MASK_ALL_GAMEPLAY := TERRAIN | ITEMS | ACTORS | PROJECTILES | ENEMIES | CAMP_OBSTACLE | PALISADE_OBSTACLE   # 575

## Детонация при смерти крупного объекта (башня, харвестер-ядро): бьёт по
## площади врагов (ENEMIES), постройки лагеря и ядро (CAMP_OBSTACLE), палисад/
## стены (PALISADE_OBSTACLE) и башню (ACTORS — чтобы детонация ядра могла задеть
## башню и наоборот). FRIENDLY_UNIT (гномы) НАМЕРЕННО исключён — как и Slam,
## взрыв не должен массово выкашивать своих гномов. Источник сам выходит из
## Damageable-группы до взрыва, так что себя не задевает.
const MASK_DEATH_BLAST := ENEMIES | CAMP_OBSTACLE | PALISADE_OBSTACLE | ACTORS   # 564

## Skeleton scan: пол, предметы, башня, палатки. **Без `ENEMIES`** —
## намеренно: скелеты не сталкиваются друг с другом физически, проходят
## сквозь. На 400+ скелетах в плотном кластере вокруг башни skel-skel
## broad-phase пары становились главным пожирателем physics_ms (после того
## как FAR-LOD убрали из broad-phase): каждый AABB пересекается с 5-15
## соседями, move_and_slide делает collision-iterations об них. Также
## визуально кучи рассасываются: скелеты не утыкаются друг в друга
## по инерции, продолжают идти к цели.
##
## Цена: `Enemy._push_neighbor` (lunge-domino — выпад одного скелета
## физически отбрасывает соседа через get_slide_collision) не работает,
## так как slide-collision между скелетами не регистрируется. Если
## понадобится восстановить — paттерн group+dist push, как Slam-fallback.
const MASK_SKELETON := TERRAIN | ITEMS | ACTORS | CAMP_OBSTACLE | WALL_GATE_BLOCK | CHASM_BARRIER     # 18471

## Shatter-фрагменты: видят только пол.
const MASK_TERRAIN_ONLY := TERRAIN                              # 1

## Стрела дружественного снаряда (OctagonTurret, DefenderGnome): пол + враги.
## Item'ы пропускает (стрелы не должны застревать в ящиках); Tower на ACTORS
## (бит 2) тоже пропускает — друг. COLD_ENEMY оставлен исторически; FAR-скелеты
## теперь имеют collision_layer=0 и стрелами не пробиваются. Это OK на практике:
## attack_radius защитников ~22м, всегда в LOD NEAR/MID. Если в будущем
## стрела «улетит» далеко и должна задеть FAR-скелета — нужен group-fallback
## в стрелах, по аналогии со Slam.
const MASK_FRIENDLY_PROJECTILE := TERRAIN | ENEMIES | COLD_ENEMY  # 145

## Стрела вражеского снаряда (skeleton-archer): пол + дружественные цели + палисад.
## Зеркало MASK_FRIENDLY_PROJECTILE с инверсией стороны: бьёт Tower (ACTORS),
## палатки/колокол (CAMP_OBSTACLE), смонтированные модули, гномов/защитников
## (FRIENDLY_UNIT), Squad-юнитов. Палисад блокирует стрелу физически —
## стена даёт укрытие. Высокие арки баллистики могут перелетать через
## palisade_segment.height=1.5м (зависит от angle/speed) — это by design,
## частокол не абсолютная защита.
const MASK_HOSTILE_PROJECTILE := TERRAIN | ACTORS | CAMP_OBSTACLE | MOUNTED_MODULE | FRIENDLY_UNIT | PALISADE_OBSTACLE  # 869


## Группа-маркер: цель исключена из всех hand-actions (slam, flick, grab,
## magnet) и магии. Включи через editor (Node → Groups → Add «hand_immune»)
## на конкретном инстансе сцены или программно (`add_to_group(Layers.HAND_IMMUNE_GROUP)`)
## в _ready, если нужно сделать исключение по типу. Пустая по умолчанию —
## дизайнер опционально помечает то, что должно стать недосягаемым для руки.
const HAND_IMMUNE_GROUP := &"hand_immune"


## True, если объект — Node, исключённый из hand-actions через HAND_IMMUNE_GROUP.
## Hand-actions (slam, flick, grab, magnet) фильтруют через эту проверку
## ПОСЛЕ broad-phase / overlap-выборки.
static func is_hand_immune(target: Object) -> bool:
	return target is Node and (target as Node).is_in_group(HAND_IMMUNE_GROUP)


## Группа-маркер: цель НЕ получает damage от Slam (хлопка), но push/knockback
## применяется как обычно. Дизайнерское решение (2026-05-16): хлопок — это
## AOE friendly-fire-mistake, гномов не должно одним хлопком убивать.
## Применяется в `HandPhysicalSlam._perform_slam`: после Pushable.try_push
## делается проверка `is_slam_damage_immune` перед `Damageable.try_damage`.
## Палатки/палисад/башня/скелеты НЕ в этой группе → им урон проходит.
## Узкий scope только на Slam (не Flick): Flick — single-target chosen
## action, дизайнерски «целюсь и щёлкаю», осознанный выбор.
const SLAM_DAMAGE_IMMUNE_GROUP := &"slam_damage_immune"


## True, если объект — Node, помеченный как иммунный к damage от Slam.
## Push к нему всё равно применяется (волна отбрасывания).
static func is_slam_damage_immune(target: Object) -> bool:
	return target is Node and (target as Node).is_in_group(SLAM_DAMAGE_IMMUNE_GROUP)


## Группа-маркер: «soft-release» предметы. При отпускании рукой если её
## smoothed_velocity ниже порога (`HandPhysical.soft_release_velocity_threshold`),
## Hand пропускает применение impulse и кладёт предмет ровно там, где была
## рука — без полёта-броска. Используется для палаток (CampPart) и любых
## объектов, которые игрок «ставит, а не бросает». Обычные RB вне группы
## всегда получают impulse от smoothed_velocity (как и было).
##
## Семантика: «ставится, не бросается». Если игрок РЕЗКО махнул рукой
## (velocity ≥ threshold), Hand применит impulse — soft-release не запрещает
## бросок, просто отделяет «положить» от «швырнуть».
const HAND_SOFT_RELEASE_GROUP := &"hand_soft_release"


## True, если объект — Node, помеченный как soft-release. Hand._release
## использует это перед применением impulse.
static func is_hand_soft_release(target: Object) -> bool:
	return target is Node and (target as Node).is_in_group(HAND_SOFT_RELEASE_GROUP)


## Группа-маркер: «громоздкие» предметы, которые рука ВОЛОЧЁТ, а не приклеивает.
## Обычный grab = freeze + телепорт к руке каждый кадр; haul-предмет НЕ замораживается —
## рука тянет его пружиной за точку хвата (`HandPhysicalActions._apply_haul_force`):
## предмет провисает под гравитацией, цепляет землю дальним концом, разворачивается
## за рукой. Семантика: «тащишь бревно, а не держишь ящик». (Плашка-мост.)
const HAND_HAUL_GROUP := &"hand_haul"


## True, если объект — Node, помеченный как haul («волочение» вместо приклеивания).
static func is_hand_haul(target: Object) -> bool:
	return target is Node and (target as Node).is_in_group(HAND_HAUL_GROUP)


## Контракт-группы, которые ОДИН файл регистрирует, а ДРУГОЙ читает — единый
## источник имени, иначе опечатка в литерале тихо рвёт связь register↔read.
##   gnome_strike_target — цели удара гнома (горшок/рычаг/дерево/мост) ⇄ SoldierGnome скан.
##   spark_target        — цели Искры (диод/горшок) ⇄ SparkBolt._notify_spark_targets.
##   shield_breakable    — утварь, ломаемая щитом башни (горшок) ⇄ Tower._shield_shatter_scenery.
const GNOME_STRIKE_TARGET_GROUP := &"gnome_strike_target"
const SPARK_TARGET_GROUP := &"spark_target"
const SHIELD_BREAKABLE_GROUP := &"shield_breakable"
## Склад ресурсов башни (room-режим): рабочий сдаёт сюда добытое ⇄ HUD читает запас.
const TOWER_STORE_GROUP := &"tower_store"
## Источник ресурса (дерево и т.п.) — area-клик по нему = приказ GATHER (рубить+носить).
const RESOURCE_SOURCE_GROUP := &"resource_source"
## Блюпринт стройки (мост и т.п.) — area-клик по нему = приказ BUILD (нести ресурс+класть).
const BUILD_SITE_GROUP := &"build_site"


## Возвращает true, если в маске установлен бит указанного слоя.
static func has_layer(mask: int, layer_bit: int) -> bool:
	return (mask & layer_bit) != 0


## Собрать маску из произвольного набора слоёв: Layers.compose(Layers.ITEMS, Layers.ENEMIES).
static func compose(a: int, b: int = 0, c: int = 0, d: int = 0, e: int = 0, f: int = 0) -> int:
	return a | b | c | d | e | f


## Человекочитаемое имя для маски: декомпозирует биты и подставляет имена из
## ProjectSettings (`layer_names/3d_physics/layer_N`). Для пустой маски — «—».
static func layer_name_for_bits(mask: int) -> String:
	if mask == 0:
		return "—"
	var names: Array[String] = []
	for i in range(32):
		if (mask & (1 << i)) != 0:
			var key := "layer_names/3d_physics/layer_%d" % (i + 1)
			var raw = ProjectSettings.get_setting(key, "")
			var n: String = str(raw) if raw else ""
			if n.is_empty():
				n = "layer_%d" % (i + 1)
			names.append(n)
	return ",".join(names)
