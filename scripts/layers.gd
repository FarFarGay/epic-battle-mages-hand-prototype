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
const MASK_HAND_SLAM := ITEMS | ACTORS | ENEMIES | CAMP_OBSTACLE | COLD_ENEMY | FRIENDLY_UNIT                       # 438

## «Всё обычное» (без палаток лагеря). Tower / Item / Ground / shatter.
const MASK_ALL_GAMEPLAY := TERRAIN | ITEMS | ACTORS | PROJECTILES | ENEMIES   # 31

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
const MASK_SKELETON := TERRAIN | ITEMS | ACTORS | CAMP_OBSTACLE     # 39

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
