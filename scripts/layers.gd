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

## «Холодные» враги — FAR-LOD скелеты (вне камеры/далеко от центра действий).
## Они на этом слое вместо ENEMIES, чтобы:
##   - другие скелеты их не «видели» через broad-phase (Skeleton.mask без COLD_ENEMY);
##   - башня их не блокировала (Tower.mask без COLD_ENEMY);
##   - турель не тратила выстрелы (OctagonTurret.target_mask = ENEMIES без COLD_ENEMY).
## НО — рука и slam их видят (MASK_HAND_TARGETS и MASK_HAND_SLAM включают
## COLD_ENEMY). Иначе игрок при отзумленной камере не мог бы бить дальние стаи:
## все скелеты становились FAR-фантомами, slam через PhysicsShapeQuery не находил
## никого.
const COLD_ENEMY := 1 << 7       # 128 — bit 7 = layer 8

# Композитные маски — собирай через OR из именованных битов.

## Hand cursor raycast: пол + предметы + смонтированные модули. Под цели
## "поверхностей под рукой" попадает турель на верхушке башни — иначе
## курсор пролетал бы сквозь неё (тауэр на ACTORS, не в маске).
const MASK_HAND_CURSOR := TERRAIN | ITEMS | MOUNTED_MODULE      # 67

## Hand grab / flick: предметы и враги (то, во что бьём/подсвечиваем).
## MOUNTED_MODULE — чтобы рука могла снять смонтированный модуль обратно
## с башни / центра лагеря. COLD_ENEMY — чтобы рука доставала FAR-LOD
## скелетов (фантомов для всего остального broad-phase).
const MASK_HAND_TARGETS := ITEMS | ENEMIES | MOUNTED_MODULE | COLD_ENEMY     # 210

## Slam: предметы и враги, без MOUNTED_MODULE. Хлопок не должен срывать
## смонтированный модуль со слота — снять модуль можно только хватом руки
## (через MASK_HAND_TARGETS), а Slam — это AOE по «свободному» миру.
## COLD_ENEMY включён по той же причине что и в MASK_HAND_TARGETS.
const MASK_HAND_SLAM := ITEMS | ENEMIES | COLD_ENEMY                         # 146

## «Всё обычное» (без палаток лагеря). Tower / Item / Ground / shatter.
const MASK_ALL_GAMEPLAY := TERRAIN | ITEMS | ACTORS | PROJECTILES | ENEMIES   # 31

## Skeleton scan: всё обычное + палатки (упирается в них в обоих режимах).
const MASK_SKELETON := TERRAIN | ITEMS | ACTORS | ENEMIES | CAMP_OBSTACLE     # 55

## Shatter-фрагменты: видят только пол.
const MASK_TERRAIN_ONLY := TERRAIN                              # 1

## Стрела защитного модуля (OctagonTurret): пол + враги. Item'ы пропускает
## (стрелы дружественны и не должны застревать в ящиках); Tower на ACTORS
## (бит 2) тоже пропускает — друг.
const MASK_FRIENDLY_PROJECTILE := TERRAIN | ENEMIES             # 17


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
