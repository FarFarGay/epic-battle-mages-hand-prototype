# Hand Gameplay Prototype — Спецификация

**Проект:** Прототип механики гигантской руки мага для Epic Battle Mages (3D-итерация).
**Движок:** Godot 4.6.2 (Vulkan, Forward+).
**Язык:** GDScript.
**Статус:** прототип, минимальная вертикаль (управление башней + захват предметов рукой).

---

## 1. Цель проекта

Перенести в 3D базовую механику предыдущего JS/Canvas-прототипа ([epic-battle-mages-hand-prototype](https://github.com/FarFarGay/epic-battle-mages-hand-prototype)):
- Башня — управляемый игроком «герой», передвигается по миру.
- Рука — отдельная сущность, привязанная к курсору мыши, отвечает за всё взаимодействие с предметами.
- Предметы — физические объекты на полу, которые рука может поднимать и бросать.

Текущий прототип реализует первый горизонт: WASD-движение башни, изометрическая камера, рука-курсор с магнитным захватом, три тестовых предмета.

---

## 2. Структура проекта

```
hand_gameplay_prot/
├── project.godot              — конфиг движка, input map, layer_names, autoloads
├── SPEC.md                    — этот документ (Godot-имплементация, low-level: LOD, spatial grid, freed-safety и пр.)
├── docs/
│   └── handoff_to_ue.md       — design-spec для UE5-команды (этап 49+). Описывает механики на уровне «что/параметры», без Godot-привязки. Используется при передаче прототипа на UE.
├── resources/
│   ├── grid.gdshader               — спатиальный шейдер пола (исторически с grid'ом, в этапе 44 grid убран — остался только fbm-травянистый noise через NoiseTexture2D sample)
│   ├── ground_noise.tres           — `NoiseTexture2D` 512×512, FastNoiseLite type=Perlin, frequency=0.018, octaves=4, seamless — texture-noise для пола И для ветра травы (один на всё)
│   ├── grass.gdshader              — 3D-mesh grass с vertex displacement: sin-волна по миру + noise variance, без transparency (godotshaders.com/shader/grass-shader подход)
│   ├── grass_blade.obj             — low-poly blade 9 vertices / 7 трисов (1м×4м, узкий к верху). Импортируется как Mesh
│   ├── grass_material.tres         — `ShaderMaterial` для grass.gdshader, использует ground_noise.tres как noise_texture для качания
│   ├── smoke.gdshader              — стилизованный дым (POI-костёр SmokeParticles): voronoi-нойз UV-скролл + alpha-curve через `COLOR.a` от ParticleProcessMaterial
│   ├── smoke_material.tres         — `ShaderMaterial` для smoke.gdshader (params: Vor_Scale=0.8, Vor_Speed=0.2, Color, Alpha_Clip=0)
│   ├── smoke_color_gradient.tres   — `GradientTexture1D` тёмный→светлый-серый (индексируется COLOR.a по жизни частицы)
│   ├── smoke_voronoi_noise.tres    — `NoiseTexture2D` 256×256, FastNoiseLite type=CELLULAR, frequency=0.04, seamless
│   ├── smoke_alpha_curve.tres      — `CurveTexture` peak в середине → создаёт «клочья» дыма
│   ├── smoke_mesh.tres             — `ArrayMesh` (190KB, 9408 индексов) от Loop-Box/Stylized-Smoke-For-Godot4.5: объёмная сетка из множества quad'ов под разными углами для billboard-эффекта в particles
│   ├── slam_distortion.gdshader    — distortion+ripple шейдер для slam-визуала: SCREEN_TEXTURE-преломление + chromatic aberration + accretion glow + SDF-noise dissolve + бегущая ripple-волна
│   ├── slam_distortion_material.tres — `ShaderMaterial` для slam-эффекта; параметры `intensity`/`ripple_time` тveen'ятся из кода
│   ├── slam_dust_material.tres     — `StandardMaterial3D` (billboard) для пылевых quad'ов при ударе
│   └── slam_dust_process.tres      — `ParticleProcessMaterial` для пыли: emission sphere + spread 80° + scale_curve + color_ramp бело-серый → прозрачный
├── scenes/
│   ├── main.tscn              — корневая сцена (композиция уровня)
│   ├── tower.tscn             — модуль "башня"
│   ├── hand.tscn              — модуль "рука" + два под-узла-категории
│   ├── camera_rig.tscn        — модуль "камера"
│   ├── item.tscn              — модуль "предмет" (шаблон)
│   ├── skeleton.tscn          — конкретный враг (Skeleton extends Enemy)
│   ├── camp.tscn              — лагерь (4 палатки + спавн гномов + центральный mount-slot)
│   ├── gnome.tscn             — обитатель лагеря (CharacterBody3D)
│   ├── defender_gnome.tscn    — защитник-лучник (Gnome extends, красный, стреляет стрелами)
│   ├── resource_pile.tscn     — куча ресурсов на полу (типы: WOOD/STONE/IRON/FOOD/GENERIC + форма)
│   ├── resource_zone.tscn     — зона расставлятель куч (`@tool`-нода: drag → выставить тип/count/size → spawn на _ready)
│   ├── octagon_turret.tscn    — защитный модуль (CampModule), стреляет стрелами
│   ├── arrow.tscn             — снаряд защитного модуля
│   ├── poi_marker.tscn        — маркер точки интереса (тёмный круг золы под костром, ~0.95м)
│   ├── quest_actor.tscn       — актор-выдатчик квеста: костёр (3 полена крест-накрест + FlameCore + FlameParticles + SmokeParticles + OmniLight)
│   ├── spawn_zone.tscn        — зона спавна врагов (плоский красный box-индикатор, виден только в редакторе)
│   ├── perf_hud.tscn          — оверлей FPS / process+physics ms / draw calls / скелеты+LOD
│   ├── gameplay_hud.tscn      — игровой HUD (способности слева, статус лагеря справа)
│   ├── grass_chunk.tscn       — `MultiMeshInstance3D` с blade-mesh + grass-материалом (шаблон для GrassField._spawn_chunks)
│   └── grass_field.tscn       — корневой Node3D с GrassField-скриптом, сеткой ChunkCount×ChunkCount чанков по карте
└── scripts/
    ├── tower.gd               — class_name Tower
    ├── hand.gd                — class_name Hand (координатор)
    ├── hand_physical.gd       — class_name HandPhysicalActions (LMB-grab + диспатч RMB)
    ├── hand_physical_slam.gd  — class_name HandPhysicalSlam
    ├── hand_physical_flick.gd — class_name HandPhysicalFlick
    ├── hand_spell.gd          — class_name HandSpell (заглушка)
    ├── camera_rig.gd
    ├── item.gd                — class_name Item
    ├── enemy.gd               — class_name Enemy (база с FSM APPROACH/WINDUP/STRIKE/COOLDOWN)
    ├── skeleton.gd            — class_name Skeleton extends Enemy
    ├── enemy_spawner.gd       — class_name EnemySpawner — низкоуровневый спавн (spawn_at/uniform/ring/group + zones)
    ├── wave_director.gd       — class_name WaveDirector — режиссёр фаз кампании врагов
    ├── spawn_zone.gd          — class_name SpawnZone (@tool, прямоугольник с budget'ом волн)
    ├── camp.gd                — class_name Camp
    ├── gnome.gd               — class_name Gnome
    ├── defender_gnome.gd      — class_name DefenderGnome extends Gnome (лучник с прокачкой точности)
    ├── resource_pile.gd       — class_name ResourcePile (4 типа ресурса × 4 формы pile'а с дефолтами и override-экспортами)
    ├── resource_zone.gd       — class_name ResourceZone (`@tool`, спавнит count pile'ов в прямоугольнике на _ready через await process_frame + rejection sampling)
    ├── quest_progress.gd      — autoload QuestProgress (линейный прогресс сюжета + Q-debug)
    ├── quest_actor.gd         — class_name QuestActor (POI-зона + выдатчик квеста: костёр, safe_radius, wave_schedule)
    ├── wave_stage.gd          — class_name WaveStage (Resource): одна стадия осады POI
    ├── wave_schedule.gd       — class_name WaveSchedule (Resource): массив стадий для QuestActor.wave_schedule
    ├── combat_group.gd        — class_name CombatGroup (Resource): атомарная единица волны (composition + spawn_zone + кластер)
    ├── unit_entry.gd          — class_name UnitEntry (Resource): пара (scene, count) внутри CombatGroup
    ├── roads.gd               — генератор-меш дорог между POI (orphan, не подключён в main.tscn)
    ├── layers.gd              — class_name Layers (именованные физические слои + маски)
    ├── damageable.gd          — class_name Damageable (group-контракт + try_damage)
    ├── pushable.gd            — class_name Pushable (group-контракт + try_push)
    ├── grabbable.gd           — class_name Grabbable (group-контракт для LMB-grab)
    ├── camp_module.gd         — class_name CampModule (база для апгрейдов лагеря/башни)
    ├── mount_slot.gd          — class_name MountSlot (точка монтажа модулей)
    ├── octagon_turret.gd      — class_name OctagonTurret extends CampModule
    ├── arrow.gd               — class_name Arrow (снаряд защитного модуля)
    ├── knockback_state.gd     — class_name KnockbackState (RefCounted helper, общий kinematic-knockback)
    ├── shatter_effect.gd      — class_name ShatterEffect (визуал смерти, общий для врагов и т.п.)
    ├── vec_util.gd            — class_name VecUtil (горизонтальные хелперы Vector3)
    ├── perf_hud.gd            — class_name PerfHud (оверлей FPS/ms/draw calls/скелеты/LOD, F3 toggle)
    ├── gameplay_hud.gd        — игровой HUD (способности + статус лагеря)
    ├── grass_field.gd         — class_name GrassField (Node3D, корень chunked-grass'a; на _ready спавнит 8×8 GrassChunk-нод по карте 400×400)
    ├── xp_orb.gd              — class_name XpOrb (этап 49, осязаемый XP-дроп; Node3D + Area3D, IDLE → MAGNETIZED)
    ├── xp_orb_spawner.gd      — autoload XpOrbSpawner (слушает EventBus.enemy_destroyed, спавнит XpOrb)
    ├── squad_xp_fx.gd         — autoload SquadXpFx (popup'ы «+N» в точке arrival орба к anchor'у)
    ├── journal_panel.gd       — autoload JournalPanel (J открывает CanvasLayer с тремя вкладками: Юниты/Лагерь/План; level-gated апгрейды отряда, постройки за ресурсы, preset'ы плана сбора)
    ├── resource_fx.gd         — autoload ResourceFx (одноразовый GPUParticles3D-всплеск при сборе единицы / consume pile'а; цвет = ResourcePile.color_for_type)
    ├── event_bus.gd           — autoload EventBus
    └── log_config.gd          — autoload LogConfig
```

---

## 3. Архитектурные принципы

1. **Каждая сущность — самодостаточный пакет** (`.tscn` + `.gd`). Все внутренние узлы и под-ресурсы инкапсулированы в собственной сцене.
2. **Контракты через группы и сигналы, а не через жёсткие типы.** Раньше код писал `if body is Item` — это привязывало руку к одному классу. Сейчас три cross-cutting контракта живут в `scripts/{damageable,pushable,grabbable}.gd` (каждый — `RefCounted` со static-API):
   - `Damageable` — `register(node) → group "damageable"`, `is_damageable(target)`, `try_damage(target, amount)`. Цели: `Item`, `Tower`, `Enemy` (Skeleton), `ResourcePile`.
   - `Pushable` — `register/is_pushable/try_push(target, Δv, duration)`. RigidBody-цели реализуют `apply_push` через `apply_central_impulse(Δv * mass)`, kinematic-цели (Enemy) — через свой `apply_knockback`. Снаружи всё едино — `Tower._push_kinematic` не знает, какой класс перед ним.
   - `Grabbable` — `register/is_grabbable`. Hand сейчас грабит «любой `RigidBody3D` в группе grabbable, у которого есть `set_highlighted` и `mass < max_lift_mass`» вместо `body is Item`. `ResourcePile` подключился без правок руки — только через `Grabbable.register` в своём `_ready`.
3. **Именованные физические слои.** `scripts/layers.gd` (`class_name Layers`) — единая точка правды: `Layers.TERRAIN/ITEMS/ACTORS/PROJECTILES/ENEMIES/CAMP_OBSTACLE/MOUNTED_MODULE/COLD_ENEMY/FRIENDLY_UNIT` плюс композитные `MASK_HAND_CURSOR / MASK_HAND_TARGETS / MASK_HAND_SLAM / MASK_ALL_GAMEPLAY / MASK_SKELETON / MASK_TERRAIN_ONLY / MASK_FRIENDLY_PROJECTILE`. В коде GDScript маски берутся через `Layers.X`. В `.tscn` Godot хранит маски как ints — там литералы; пересчитываются от констант (комментарий рядом). Кросс-cutting иммунитет руки/магии — группа `Layers.HAND_IMMUNE_GROUP` (`hand_immune`), helper `Layers.is_hand_immune(target)`.
4. **Связи между модулями — через `@export` и `setup(...)` инъекцию.** Подмодули руки (`HandPhysicalSlam/Flick/Spell`) получают ссылки на `Hand` и координатор через явный `setup(hand, coord)`, а не лезут вверх по дереву через `get_parent().get_parent()`. Камера, лагерь, спавнер — всё на `@export NodePath`.
5. **`main.tscn` — только композиция:** инстансы модулей + ландшафт + свет. Никакой собственной логики.
6. **`scripts/` — только поведение, `scenes/` — только структура.** Сцены не содержат скриптов в чужих папках, скрипты не делают `preload` чужих сцен (кроме рантайм-спавна — гномы, скелеты, фрагменты-осколки).
7. **Эффекты-без-владельца.** Визуалы вроде «осколки на смерти» (`scripts/shatter_effect.gd`, `class_name ShatterEffect`) — `RefCounted` со static `spawn(parent, position, color, count, lifetime)`. Скелет, ResourcePile или будущий разрушаемый объект зовёт его без наследования и без хранения собственных Tween'ов; общий `SceneTreeTimer` чистит пачку фрагментов разом.

---

## 4. Координатное пространство и физика

- **Мировая ось Y — вверх**, X — вправо, Z — на зрителя.
- **Уровень пола — y = 0** (верхняя грань узла `Ground`).
- **Камера — перспективная** (`Camera3D.projection = 0`), `fov = 40°` (узкая, чтобы перспективные искажения не «перетряхивали» изометрический look). Изометрический угол: позиция `(18, 36.4, 18)` от цели, pitch ~55° вниз, yaw 45°. Смещение и базис в `Camera3D.transform` посчитаны вручную (см. §5.3). Раньше была orthographic с `size=30` из `(12, 12, 12)`; перевели на perspective в `cc82894`, после чего pitch и fov прошли несколько итераций тюнинга.
- **Размеры и позиции:**
  | Узел | Размер | Стартовая позиция | Высота центра |
  |---|---|---|---|
  | Ground | 300×1×300 | (0, −0.5, 0) | y=−0.5 (верх y=0) |
  | Tower | 2×6×2 | (0, 3, 0) | y=3 (низ y=0) |
  | Hand | сфера r=0.5 | следует курсору | `surface_y + hand_height` |
  | Item (бокс) | переменный (`item_size`) | произвольно | `size.y / 2` (низ на y=0) |

### 4.1 Коллизионные слои

Имена слоёв заданы в [project.godot → layer_names](project.godot) и продублированы константами в `scripts/layers.gd`. Слой определяет «что это семантически», маска — «с чем взаимодействует».

| Слой | Имя | Кто на нём | Кто его сканирует |
|---|---|---|---|
| 1 | Terrain | Ground (в будущем — холмы, стены) | все динамические тела + Hand-cursor-raycast + shatter-фрагменты |
| 2 | Items | `Item`, `ResourcePile` | все динамические тела + Hand-cursor-raycast + GrabArea/MagnetArea + Slam |
| 3 | Actors | Tower (player-side) | Items, Enemies (но **не сами Skeleton'ы для других Skeleton'ов** — см. MASK_SKELETON ниже) |
| 4 | Projectiles | (заготовка под магию) | Terrain, Actors, Enemies |
| 5 | Enemies | `Skeleton` и будущие враги | Tower (исторически; теперь Tower.mask=15 без ENEMIES — башня **физически проходит сквозь скелетов**, см. ниже), Arrow, Slam, Flick |
| 6 | CampObstacle | палатки `Camp` (Tent*-инстансы из `tent.tscn`, `RigidBody3D` с `freeze=true` в норме) — на этом слое и в frozen-, и в torn_off-режиме | Skeleton (палатки блокируют скелетов в любом режиме; летящая torn_off-палатка через CAMP_OBSTACLE в `MASK_SKELETON` физически разбрасывает их). Tower **не** сканирует — палатки своего же лагеря не должны мешать башне |
| 7 | MountedModule | `CampModule` в момент монтажа в слот (динамически переключается с ITEMS) | Hand.GrabArea, Hand.cursor_raycast — иначе игрок не сможет снять модуль с башни обратно. Tower **не** сканирует — иначе touching-контакт «башня снизу, модуль на ней» давал бы ложные wall-collision'ы |
| 8 | ColdEnemy | **зарезервированный, на 2026-05-02 не используется**. Раньше FAR-LOD скелеты лежали на нём (`collision_layer=COLD_ENEMY, mask=0`), но broad-phase BVH всё равно индексировал AABB 2000 движущихся скелетов → 25+мс на physics_ms. Сейчас FAR-скелеты полностью исключаются из broad-phase через `CollisionShape3D.disabled = true` (см. §5.5.2), а слам ловит их вторым проходом по `Skeleton.SKELETON_GROUP` с distance²-фильтром. Бит COLD_ENEMY ещё включён в `MASK_HAND_TARGETS / MASK_HAND_SLAM / MASK_FRIENDLY_PROJECTILE` исторически — это no-op (никто на этом слое не лежит). Слой оставлен на случай повторного использования для других «исключаемых» сущностей | Hand.GrabArea, Slam, Arrow (все — no-op в текущей реализации) |
| 9 | FriendlyUnit | `Gnome`, `DefenderGnome` — отдельный от ACTORS, чтобы скелеты могли блокироваться об башню (ACTORS в `MASK_SKELETON`) и при этом **физически проходить сквозь гномов** (FRIENDLY_UNIT не в `MASK_SKELETON`) | Hand.GrabArea / Slam — теперь **смотрят** на FRIENDLY_UNIT (изменение 2026-05-03, унификация рукой и магии: рука одинаково действует на врагов и на гномов). Arrow на FRIENDLY_UNIT не смотрит — стрелы дружественные, по гномам не бьют |

В коде GDScript маски берутся именованными константами из `Layers`; в `.tscn` Godot хранит ints, поэтому там — литералы (значения должны соответствовать `Layers.MASK_*`).

**Маски тел (актуальные значения):**
- `Item`, `Ground`, `ResourcePile`: `Layers.MASK_ALL_GAMEPLAY = 31` (Terrain + Items + Actors + Projectiles + Enemies) — взаимодействуют со всем «обычным», но **не с CampObstacle**: палатки намеренно не блокируют ящики/кучи.
- `Tower`: `15` (Terrain + Items + Actors + Projectiles, **без ENEMIES**) — башня **не процессит контакты со скелетами** в `move_and_slide`. Раньше было 31, но Tower сама движется (CharacterBody3D), и в плотном кластере 100+ скелетов вокруг неё каждый m_a_s обходил все skel-Tower пары → отдельные миллисекунды physics_ms. Скелеты по-прежнему обнаруживают Tower как препятствие (Tower.layer=ACTORS в MASK_SKELETON), упираются и получают bounce-off на lunge. Только сама Tower сквозит толпу не тормозясь — это разумно (тяжёлая башня, скелеты лёгкие).
- `Skeleton`: `Layers.MASK_SKELETON = 39` (Terrain + Items + Actors + CampObstacle, **без ENEMIES**) — скелеты **проходят сквозь друг друга** (perf-фикс на 400+ кластерах: skel-skel пары были главным пожирателем broad-phase + slide-iterations об соседей). Цена: `Enemy._push_neighbor` lunge-domino не работает (slide-collision между скелетами не регистрируется). Восстановление — через group+dist push, по аналогии со Slam-fallback. Визуально лечится через `_apply_neighbor_avoidance` (boids-style раздвигание, см. §5.5.2).
- `Gnome` / `DefenderGnome`: `collision_layer = Layers.FRIENDLY_UNIT = 256`, `collision_mask = Layers.TERRAIN = 1` — гномы видят только пол. Не блокируются скелетами, не толкают друг друга, проходят сквозь Tower и Item. Урон по гномам приходит через `Damageable.try_damage` — раньше только от STRIKE скелета, с 2026-05-03 ещё и от Slam/Flick (рука стала «вездесущей» по дизайнерскому решению, см. §4.1.bis). Push от Slam применяется через `Pushable.try_push` → `gnome.apply_push` (knockback-механизм гнома, AI глушится на `slam_knockback_duration`).
- Shatter-фрагменты: `Layers.MASK_TERRAIN_ONLY = 1` — падают на пол, проходят сквозь тела и друг друга.
- **FAR-LOD Skeleton (динамически):** `collision_layer = 0, collision_mask = 0`, плюс `CollisionShape3D.disabled = true` — полностью вне broad-phase. Slam достаёт через group-fallback (см. §5.2.1).

**Маски запросов (не тел):**
- `Hand.cursor_raycast_mask`: `Layers.MASK_HAND_CURSOR = 67` (Terrain + Items + MountedModule) — рука поднимается над полом, ящиками/кучами и смонтированными модулями (иначе курсор не «ловил» бы турель на верху башни и снять рукой не получалось бы). На лету в `Hand._raycast_terrain` к маске прибавляется `ACTORS`, если в руке `CampModule` — чтобы при переноске модуля курсор «находил» верхушку башни и hand поднимался к слоту, а не упирался в стену тауэра.
- `Hand.GrabArea`: `Layers.MASK_HAND_TARGETS = 502` (Items + Actors + Enemies + CampObstacle + MountedModule + ColdEnemy + FriendlyUnit) — рука «видит» в зоне всё, что может быть целью какого-либо action'а. С 2026-05-03 включает гномов (FRIENDLY_UNIT), башню (ACTORS) и палатки (CAMP_OBSTACLE) — это нужно Flick'у, который через `find_flick_target` ищет Damageable-цель в зоне руки. LMB-grab дополнительно фильтрует через `Grabbable.is_grabbable` + `mass < max_lift_mass`, поэтому гнома/башню случайно не схватить (они не Grabbable, не RigidBody). Per-target иммунитет — через группу `Layers.HAND_IMMUNE_GROUP = "hand_immune"`: дизайнер ставит её на конкретный инстанс через editor (Node → Groups), и рука его пропускает в Slam, Flick, grab, magnet. Бит COLD_ENEMY формально включён, но в текущей реализации никто на нём не лежит (FAR-скелеты вне broad-phase). **FAR-скелеты руке недоступны** (не в broad-phase) — на практике игрок редко грабит зумаут-камерой, поэтому live-with-it; нужен будет — копировать паттерн group-fallback.
- `Hand.MagnetArea`: `Layers.ITEMS = 2` — магнит тянет только то, что на слое Items (Items, ResourcePile).
- `Hand:PhysicalSlam.slam_mask`: `Layers.MASK_HAND_SLAM = 438` (Items + Actors + Enemies + CampObstacle + ColdEnemy + FriendlyUnit, без MOUNTED_MODULE). С 2026-05-03 хлопок одинаково бьёт врагов, гномов, башню и палатки — дизайнерская унификация. Per-target иммунитет — `Layers.is_hand_immune(target)` (группа `hand_immune`); `_perform_slam` проверяет её сразу после `Damageable.is_damageable`. Бит ColdEnemy остался исторически — FAR-скелеты теперь не на нём, slam ловит их **отдельным проходом по `Skeleton.SKELETON_GROUP` с distance²-фильтром** (FAR-fallback тоже фильтрует по `is_hand_immune`). Без MOUNTED_MODULE — намеренно: смонтированный модуль нельзя сбить хлопком, только хватом руки.
- `Arrow.collision_mask`: `Layers.MASK_FRIENDLY_PROJECTILE = 145` (Terrain + Enemies + ColdEnemy). FAR-скелеты сейчас вне broad-phase — стрелы их не пробивают; на практике это OK (`attack_radius` лучников ~22м < `lod_near_distance=25м`, FAR-скелетов в полётной траектории не бывает).

### 4.2 Унификация руки и магии (friendly fire by default + per-target иммунитет)

**Дизайнерское решение от 2026-05-03.** Все физические действия руки (Slam, Flick, Grab, Magnet) и магия (HandSpell, заглушка) одинаково применяются к врагам и к дружественным сущностям (гномы, Tower, палатки). Логика:
- Враг подставился под Slam — получит damage и push.
- Гном попал в радиус Slam — получит damage и push (через `gnome.apply_push` → knockback).
- Tower попала в радиус Slam — получит damage (но НЕ push — Tower не Pushable).
- Палатка в радиусе Slam — получит damage (палатка не Pushable).
- Гном/враг в зоне руки + Flick — будет щёлкнут (если Damageable + mass-фильтр прошёл; гном — CharacterBody3D, mass-фильтр для не-RigidBody всегда true → попадёт под flick).
- Гном/Tower/палатка в зоне Grab — НЕ хватаются (фильтр `Grabbable.is_grabbable` + `body is RigidBody3D`; ни один из этих типов не Grabbable и не RigidBody).

**Маски:** `MASK_HAND_TARGETS = 502`, `MASK_HAND_SLAM = 438` — оба включают `FRIENDLY_UNIT | ACTORS | CAMP_OBSTACLE` помимо `ITEMS | ENEMIES`. `GrabArea.collision_mask` в `hand.tscn` синхронно = 502.

**Per-target исключение** — группа `Layers.HAND_IMMUNE_GROUP = "hand_immune"`:
- Дизайнерский путь: открыть инстанс в editor'е, вкладка Node → Groups, добавить группу `hand_immune`. Конкретный гном/палатка/предмет станет невидим для всех hand-actions и магии.
- Программный путь: `node.add_to_group(Layers.HAND_IMMUNE_GROUP)` в `_ready` (например, для сюжетного NPC, бесcмертного босса, «защищённого» здания).
- Helper для проверки: `Layers.is_hand_immune(target)` (используется внутри Slam, Flick, grab/magnet ПОСЛЕ broad-phase / overlap-выборки).

**Где иммунитет проверяется:**
- `HandPhysicalSlam._perform_slam` — основной shape-query цикл и FAR-fallback по `Skeleton.SKELETON_GROUP`.
- `HandPhysical.find_flick_target` — для Flick'а.
- `HandPhysical._find_closest_grabbable` — для Grab и Magnet (один helper на оба).
- `HandSpell` (заглушка): TODO в коде указывает использовать `MASK_HAND_SLAM` + `Layers.is_hand_immune` при будущей реализации AOE-заклинаний — симметрия с физическими действиями.

**Чего НЕ затрагивает иммунитет:** скелетных STRIKE-атак по гномам, башенных стрел/турелей, физических контактов «башня тащит ящик / скелет упирается в палатку» — это не hand-actions, у них своя логика.

---

## 5. Модули

### 5.1 Tower — `scenes/tower.tscn`, `scripts/tower.gd`

**Тип корня:** `CharacterBody3D` с `class_name Tower`.

**Назначение:** управляемая башня-герой. Передвигается по миру через WASD, прижимается гравитацией к полу. Если встречает на пути `Item`, который легче неё, — толкает его телом по направлению движения. Контактирующих kinematic-целей (скелетов и любых будущих врагов) расталкивает через универсальный `Pushable`-контракт.

**Коллизия:** `collision_layer=4 (ACTORS)`, `collision_mask=31 (TERRAIN+ITEMS+ACTORS+PROJECTILES+ENEMIES = MASK_ALL_GAMEPLAY)`. Включение бита ENEMIES (этап 43) — bidirectional коллизия со скелетами: Skeleton.mask=39 уже включала ACTORS (скелет упирался об башню), Tower.mask теперь включает ENEMIES (башня упирается об скелетов). Раньше `mask=15` без ENEMIES — Tower проходила сквозь толпу. С etапа 43 толпа физически замедляет караван — игрок чувствует массу скелетов телом башни.

**Регистрации в `_ready`:**
- `Damageable.register(self)` — башня принимает урон. `Pushable` НЕ регистрируется: башня не должна толкаться чужими импульсами (это игровая стена-герой).

**Экспорты:**
- `move_speed: float = 8.0` — горизонтальная скорость.
- `gravity: float = 20.0` — ускорение свободного падения.
- `mass: float = 10.0` — эффективная масса башни (для сравнения с `Item.mass`).
- `max_hp: float = 1000.0` — максимум здоровья. `var hp` сетится в `_ready = max_hp`. На `hp ≤ 0` → `destroyed.emit()` (без queue_free — game-over UI отдельно). Текущий `hp` эмитится через `health_changed(current, max)` на каждом take_damage.
- Группа `Mana`:
  - `max_mana: float = 100.0` — максимум маны. Тратится магическими действиями руки через `try_consume_mana(amount) -> bool`. Физика руки (Slam/Flick/grab) маны не требует.
  - `mana_regen_rate: float = 10.0` — единиц/сек. В `_physics_process` `mana = min(mana + rate × delta, max_mana)`, эмитит `mana_changed(current, max)` только при реальных изменениях (не дёргает HUD на full mana каждый кадр).
- Группа `Push Items`: `push_strength: float = 1.0` — множитель импульса при толкании предметов.
- Группа `Push Enemies`:
  - `enemy_push_speed_factor: float = 1.5` — множитель скорости knockback'а, который башня сообщает kinematic-цели при контакте.
  - `enemy_push_duration: float = 0.2` — длительность knockback'а. Refresh'ится каждый физкадр контакта.
- `fall_threshold: float = -10.0` — Y, ниже которого «провалились» (используется только в дебаг-логе).
- `debug_log: bool = true` — событийные логи.

**Группа:** `const GROUP := &"tower"` + `add_to_group(GROUP)` в `_ready`. HandSpellFireball/Firestorm дискаверят башню через `get_first_node_in_group(Tower.GROUP)` — фаербол стартует из её позиции + UP×launch_offset_y.

**Дополнительные сигналы:** `health_changed(current: float, maximum: float)`, `mana_changed(current: float, maximum: float)`. Re-emit на `EventBus.tower_health_changed / tower_mana_changed`. HUD рисует HP/MP полоски сверху по центру.

**Константы и `@onready`:**
- `MIN_PUSH_VELOCITY := 0.1` — порог компоненты `intended_velocity` в направлении kinematic-цели.
- `_floor_normal_threshold := cos(get_floor_max_angle())` — `@onready`. Раньше был хардкод `FLOOR_NORMAL_THRESHOLD`; теперь один источник правды — `floor_max_angle` самого `CharacterBody3D`.

**Сигналы:** `damaged(amount: float)`, `destroyed`. Re-emit на `EventBus.tower_damaged/_destroyed`.

**Публичный API:** `take_damage(amount: float)` — общий damageable-контракт. На `hp ≤ 0` → `_dying = true`, `set_physics_process(false)`, `velocity = ZERO`, `remove_from_group(Damageable.GROUP)`, `destroyed.emit()`. Дальнейшие вызовы — no-op через ранний return по `_dying`. Снятие из группы Damageable нужно, чтобы AOE-эффекты (Slam и будущие spell-аое) больше не считали труп целью; стенка-коллизия остаётся (скелеты упираются как в стену).

**Логика движения:**
- `velocity.y -= gravity * delta`, обнуляется при `is_on_floor()`.
- `velocity.x/z = input_dir * move_speed`, где `input_dir` нормализован.
- `intended_velocity := velocity` запоминается **до** `move_and_slide` (после слайда компонент в сторону препятствия зануляется и без него нельзя понять, что туда шли).
- `move_and_slide()`, далее `_resolve_contacts(intended_velocity)`.

**Логика разрешения контактов (`_resolve_contacts`):**
Для каждой слайд-коллизии диспатч по типу:
- **`is Item` → `_push_item`** (mass-mediation вшит, единый `Pushable.try_push` не дал бы условный mass-check):
  - При `freeze` — пропуск.
  - Подписка `item.tree_exited → _on_contact_item_exited` (через мета-флаг `&"_tower_contact_hooked"`, чтобы при повторных контактах не подключать сигнал второй раз — `Callable.bind(item)` делает экземпляр несравнимым через `is_connected`).
  - При `mass ≤ item.mass` → `contacts_now[item] = "block"` (упёрлись, но не толкаем).
  - Иначе `push_dir = -col.get_normal()`, `v_into = intended.dot(push_dir)`, `v_diff = v_into − item_v_into`. Импульс: `push_dir × v_diff × item.mass × ratio × push_strength`, где `ratio = clamp((mass − item.mass) / mass, 0, 1)`.
- **`Pushable.is_pushable(collider)` И `collider is CharacterBody3D` → `_push_kinematic`**:
  - Горизонтальное направление `push_dir_h = horizontal(-col.get_normal()).normalized()`.
  - Если `intended.dot(push_dir_h) ≤ MIN_PUSH_VELOCITY` — скип (башня в эту сторону не едет).
  - `Pushable.try_push(target, push_dir_h × v_into × enemy_push_speed_factor, enemy_push_duration)`.
  - В `_contacts_last` НЕ записываем — для 50+ скелетов получился бы спам логов.
  - Зависимости от `class_name Enemy` нет: всё через `Pushable`-контракт.

**Очистка `_contacts_last`:** через `item.tree_exited` — без неё в словаре оставались бы zombie-ключи на удалённые предметы. Идемпотентность подключения — через мета-флаг.

**Логирование (`debug_log = true and LogConfig.master_enabled`):**
- Контакт с полом (фронт), любое изменение `input_dir` (старт/стоп/смена направления), фронт-переходы статусов в `_contacts_last` (push / block / прекращение).
- `printerr` на: «застряли» (есть ввод, скорость < 10% от move_speed), «провалились ниже карты» (`y < fall_threshold`).
- Коллизия со «стеной» (нормаль с `y ≤ _floor_normal_threshold`) — пропускает Item (он залогирован в `_push_item`) И kinematic-pushable-CharacterBody3D (50+ скелетов = спам).

**Внешние зависимости:** `Input` actions, физика, контракты `Damageable` / `Pushable`, autoloads `EventBus` / `LogConfig`. Ни одной ссылки на конкретные модули (`Item`, `Enemy`, `Skeleton`).

### 5.2 Hand — `scenes/hand.tscn`, `scripts/hand.gd`

**Тип корня:** `Node3D` с `class_name Hand`.

**Назначение:** координатор. Сама Hand отвечает только за позиционирование под курсором (с учётом высоты поверхности), сглаженный трекинг скорости и проксирование сигналов наружу. Все «действия» вынесены в подузлы по категориям, у каждой категории — собственный скрипт и собственные экспорты.

**Дочерние узлы:**
- `HandMesh` — `MeshInstance3D` со сферой r=0.5 (визуал).
- `GrabArea` — `Area3D` со сферой r=2 на оффсете `(0, −1.5, 0)`, `collision_mask=502` (Items + Actors + Enemies + CampObstacle + MountedModule + ColdEnemy + FriendlyUnit, == `Layers.MASK_HAND_TARGETS`). Зона захвата (LMB) и поиска цели для Flick. Доступ снаружи — только через `get_grabbable_bodies()`.
- `MagnetArea` — `Area3D` со сферой r=4 на том же оффсете, `collision_mask=2` (только Items). Доступ — через `get_magnet_bodies()`.
- `PhysicalActions` — `Node` со скриптом `hand_physical.gd` (см. §5.2.1).
- `SpellActions` — `Node` со скриптом `hand_spell.gd` (см. §5.2.2).

**Экспорты на самой Hand (`scripts/hand.gd`):**
- `hand_height: float = 2.5` — просвет между рукой и поверхностью под курсором.
- `cursor_raycast_mask: int = Layers.MASK_HAND_CURSOR` (`@export_flags_3d_physics`, числовое значение 67 = Terrain + Items + MountedModule) — слои для raycast'а высоты под курсором. На лету в `Hand._raycast_terrain` к маске прибавляется `ACTORS`, если в руке `CampModule` (см. §4.1). Имя точное: маска именно курсорного raycast'а, не «всех terrain-операций». Раньше называлось `terrain_mask`.
- `debug_log: bool = true` — лог только смены поверхности.

**Категория ввода:**
- `enum Category { PHYSICAL, MAGIC }`, `var active_category` (default PHYSICAL).
- `set_active_category(category)` — публичный setter, эмитит `category_changed`. Equip-биндинги (1/2 в HandPhysical, 3/4 в HandSpell) вызывают это для переключения. ЛКМ-граб работает в любой категории; ПКМ — только в активной.
- `is_holding() -> bool` — общий guard для ПКМ-действий (если рука занята — ни Slam, ни Flick, ни Fireball не триггерятся).
- См. §5.12 «Магия» для полного контекста.

**Внутреннее состояние:**
- `_grab_area`, `_magnet_area` — приватные `Area3D`, доступ снаружи закрыт. Подмодули получают тела через `get_grabbable_bodies()` / `get_magnet_bodies()` — Hand не отдаёт ссылку на сами Area, чтобы они не превратились в публичную поверхность.
- `_position_locked: bool` — пока true, Hand не пересаживает себя под курсор. Cursor world-position при этом продолжает обновляться.
- `_last_cursor_world: Vector3` — текущая «точка под курсором», читается подмодулями через `cursor_world_position()`.
- `_raycast_excluders: Array[Callable]` — провайдеры RID'ов для exclude в курсорном raycast'е. Подмодули регистрируются через `register_raycast_excluder(callable)` (PhysicalActions исключает удерживаемый предмет).

**Публичный API для подмодулей:**
- `hand.global_position` — мировая позиция (на луче камеры, на высоте `surface_y + hand_height`).
- `hand.smoothed_velocity()` — сглажено за `VELOCITY_HISTORY_FRAMES = 6` кадров.
- `get_grabbable_bodies() -> Array[Node3D]`, `get_magnet_bodies() -> Array[Node3D]` — зонные тела как Node3D.
- `hand.physical_actions: HandPhysicalActions`, `hand.spell_actions: HandSpell` — типизированные ссылки на подмодули.
- `hand.lock_position(bool)` — включить/выключить «залипание» под курсор.
- `hand.set_locked_position(pos: Vector3)` — прямой сеттер, требует `_position_locked = true` (assert). Используется Flick'ом — рука перетаскивается без обхода lock-контракта (раньше Flick писал в `global_position` напрямую, что путало `_track_velocity`).
- `hand.cursor_world_position() -> Vector3` — последняя точка-под-курсором. Обновляется каждый кадр **независимо** от lock'а.
- `hand.register_raycast_excluder(provider: Callable)` — provider возвращает `Array[RID]` для исключения из курсорного raycast'а.

**Сигналы (re-emit из PhysicalActions, для совместимости):**
- `grabbed(item: Node3D)`, `released(item: Node3D, velocity: Vector3)`. Тип ослаблен до `Node3D` — захватывается любой Grabbable, не обязательно `Item`.
- Re-emit на `EventBus.hand_grabbed` / `EventBus.hand_released`.

**Связь с подмодулями:** `_ready` устанавливает связи явно — `physical_actions.grabbed/released.connect(self.<sig>.emit)`, `spell_actions.setup(self)`. Spells не лезут к родителю через `get_parent()` — Hand передаёт ссылку на себя.

**Логика позиционирования (`_update_cursor_world` + `_process`):**
1. `intersect_ray` от камеры через `mouse_pos` по `cursor_raycast_mask` → `surface_y`. Удерживаемые подмодулями объекты (через `_raycast_excluders`) исключаются.
2. Пересечение того же луча камеры с горизонтальной плоскостью на `surface_y + hand_height` → `_last_cursor_world`. Так рука и на луче (под пиксельным курсором), и над поверхностью на нужный просвет.
3. Если `_position_locked == false` → `global_position = _last_cursor_world`. Иначе позицию рулит подмодуль через `set_locked_position`.

**Трекинг скорости (`_track_velocity`):**
- Накапливает `(global_position − _previous_pos) / delta` в кольцевой буфер `VELOCITY_HISTORY_FRAMES = 6`.
- При `_position_locked = true` — кадр пропускается (только обновляется `_previous_pos`). Без этого Flick, перетаскивая руку через `set_locked_position`, копил бы ложные скорости в истории, и при отпускании предмета `released.velocity = smoothed × throw_strength` была бы безумной.

**Логирование Hand:** `[Hand] поверхность: <имя> [<слой>], y=...` на фронте смены поверхности.

**Внешние зависимости:** активная камера сцены, autoloads `Layers` / `LogConfig` / `EventBus`, тип `HandPhysicalActions` / `HandSpell` (через `@onready` типизированные ссылки).

#### 5.2.1 PhysicalActions — `scripts/hand_physical.gd`

**Тип:** `Node` с `class_name HandPhysicalActions`.

**Категория:** физика. Содержит:
- **Постоянное действие** — захват / бросок / магнит (LMB).
- **Активная способность** на RMB — диспатчится по `equipped`. Сейчас две, в подузлах:
  - `Slam` (`HandPhysicalSlam`, `hand_physical_slam.gd`) — хлопок.
  - `Flick` (`HandPhysicalFlick`, `hand_physical_flick.gd`) — щелбан с орбитой.
  Смена клавишами `1` / `2` (action `equip_slam` / `equip_flick`).

**Связь с Hand и подмодулями:**
- `_hand = get_parent() as Hand` в `_ready` — родитель ровно одного уровня выше. Если не Hand — `push_error` и `set_process/physics_process(false)`.
- `_hand.register_raycast_excluder(_get_excluded_rids)` — рука исключает удерживаемый объект из курсорного raycast'а.
- Подмодули получают связь через явный `_slam.setup(_hand, self)` / `_flick.setup(_hand, self)`. Ни один подмодуль не зовёт `get_parent().get_parent()` — все ссылки переданы аргументами.
- Сигналы подмодулей: `_slam.slammed.connect(slammed.emit)`, `_flick.flicked.connect(flicked.emit)`.

**Действия как `StringName`-константы:**
```gdscript
const ACTION_GRAB := &"hand_grab"
const ACTION_ACTION := &"hand_action"
const ACTION_EQUIP_SLAM := &"equip_slam"
const ACTION_EQUIP_FLICK := &"equip_flick"
```

**Экспорты (группа `Balance`, захват/бросок/магнит):**
- `max_lift_mass: float = 10.0` — порог массы для подъёма (и магнита).
- `throw_strength: float = 1.2` — множитель импульса при броске.
- `max_throw_speed: float = 30.0` — потолок скорости броска.
- `hold_offset: Vector3 = (0, −1, 0)` — где предмет висит относительно руки.

**Подгруппа `Magnet` (с насыщением):**
- `magnet_force: float = 30.0` — базовая сила притяжения из `MagnetArea`. Реально прикладывается `min(magnet_force, mass × magnet_max_accel)`.
- `magnet_dead_zone: float = 0.6` — внутри этого радиуса вокруг руки магнит силу не прикладывает. На нулевой дистанции направление дрожит, и константная сила колебала бы предмет туда-сюда. Грэб всё равно подхватит на следующем кадре — `GrabArea` (r=2) ≫ `magnet_dead_zone`.
- `magnet_max_accel: float = 25.0` — saturation: верхний предел ускорения от магнита (m/c²). Без него лёгкий предмет (`mass=0.5`) при `magnet_force=30` получал бы 60 m/c² и пролетал руку насквозь. С cap'ом для `mass=0.5` сила = 12.5 N, для `mass≥1.2` — полные 30 N.

**Экспорты (группа `Equipment`):**
- `equipped: AbilityType` (`enum {NONE = -1, SLAM, FLICK}`) — текущая активная способность. Дефолт `SLAM`. Сеттер логирует смену.

**Состояние:**
- `_held: RigidBody3D = null` — текущий захваченный объект. **Любой Grabbable RigidBody3D**, не обязательно `Item` (раньше тип был `Item`). Контракт: член группы `Grabbable.GROUP`. Класс целевого объекта Physical больше не знает.
- `_current_candidate: RigidBody3D = null` — то же для подсветки кандидата.
- `_is_grabbing: bool` — текущее состояние LMB через **polling** (`Input.is_action_pressed(ACTION_GRAB)`), не через `just_pressed/released`. Edge-events во время Flick'а пропускались бы и `_is_grabbing` залипало (магнит после Flick'а тянул бы предметы постоянно).

**Сигналы:**
- `grabbed(item: Node3D)`, `released(item: Node3D, velocity: Vector3)` — Hand их re-emit'ит наружу.
- `slammed(position, radius)` (re-emit из Slam-подмодуля).
- `flicked(target: Node3D, velocity: Vector3)` (re-emit из Flick-подмодуля).
- Re-emit на `EventBus.hand_slammed/_flicked`.

**Публичный API:**
- `get_held_item() -> RigidBody3D`, `is_holding() -> bool`.
- `find_grab_candidate() -> RigidBody3D` — ближайший Grabbable RigidBody3D в `GrabArea` через `_find_closest_grabbable`.
- `find_flick_target() -> Node3D` — ближайшая damageable-цель в `GrabArea` через `Damageable.is_damageable`. Для RigidBody3D дополнительно фильтр по `mass < max_lift_mass`. Класс-чек по `is Item`/`is Enemy` отсутствует — щелбан работает по контракту `Damageable`.

**Поиск кандидатов (`_find_closest_grabbable`):**
- Проходит по `bodies: Array[Node3D]`.
- Фильтры (в порядке): `Grabbable.is_grabbable(body)`, `body is RigidBody3D`, `rb.mass < max_lift_mass`.
- Возвращает ближайший по `_hand.global_position.distance_to`.
- Class-чек `is Item` удалён — через `Grabbable`-группу можно регистрировать любые подбираемые типы.

**Slam-подмодуль (`HandPhysicalSlam`):**
- Вызывает координатор: `can_trigger() / on_press() / on_release() / tick(delta) / is_active() (=false для one-shot)`.
- Кулдаун-гейт через `_slam_cooldown_remaining`.
- `PhysicsShapeQueryParameters3D` со сферой `slam_radius` в `_hand.global_position`, `collision_mask = slam_mask` (`@export_flags_3d_physics`, дефолт `Layers.MASK_HAND_SLAM = 438`, Items + Actors + Enemies + CampObstacle + ColdEnemy + FriendlyUnit без MOUNTED_MODULE).
- **Балансные параметры (v5, 2026-05-10):** `slam_damage: float = 25.0`, `slam_radius: float = 3.5`, `slam_force: float = 30.0`, `slam_cooldown: float = 0.7`. Slam — **utility** (knockback + добивание), не основной damage-инструмент: магия (Fireball L0 = 47 damage / 3.5м / 12 mana) даёт больше DPS. На скелете `hp=30` slam в эпицентре = 25 dmg (не убивает с одного раза), 2-shot или slam → magic finish — by design.
- Для каждого результата `intersect_shape` (Damageable, **не в группе `hand_immune`**, не равного `_coord.get_held_item()`):
  - Falloff = `√(clamp(1 − horizontal_dist / slam_radius, 0, 1))` — sqrt-curve (единая с Fireball'ом). Горизонтальная, не 3D, иначе `hand_height` съел бы силу у близких целей.
  - Direction = `(horizontal + UP × slam_lift_factor).normalized()` (`_slam_direction_and_falloff`).
  - `Pushable.try_push(collider, dir × slam_force × falloff, slam_knockback_duration)`.
  - `Damageable.try_damage(collider, slam_damage × falloff)`.
- **Group-fallback по FAR-скелетам.** FAR-LOD-скелеты выключены из broad-phase (`CollisionShape3D.disabled = true`) и не попадают в `intersect_shape`. После основного цикла идёт второй проход по `get_nodes_in_group(Skeleton.SKELETON_GROUP)`: для каждого с `_lod_level == FAR` и `(skel.global_position - origin).length_squared() ≤ slam_radius²` применяется тот же `Pushable.try_push` + `Damageable.try_damage`. На 2000 скелетах в группе — ~2000 distance²-операций, ~0.05мс на slam_cooldown=0.5с (копейки). Без этого fallback'а игрок при отзумленной камере (где почти вся стая FAR) не мог бы ударить хлопком. NEAR/MID-скелеты пропускаются по `_lod_level` — они уже обработаны в первом цикле.
- Лог: `[Hand:Physical:Slam] хлопок @ (x, y, z), задело: N (из них FAR: M)` — `M > 0` подтверждает, что fallback сработал.
- Визуал спавнится в `effects_root_path` (NodePath); если пуст или не резолвится — фолбэк на `_hand.get_tree().current_scene`. Главное — НЕ в `_hand`: иначе расширяющаяся сфера таскалась бы за рукой, эпицентр уезжал бы. Пул `_slam_visual_pool` (cap 3) переиспользует MeshInstance3D.
- `slammed.emit(origin, slam_radius)`.

**Slam-визуал — distortion-сфера + dust:**

`_spawn_slam_visual(origin)` создаёт **two parallel-effects** в эпицентре:

1. **Distortion-сфера** (`SLAM_VISUAL_TWEEN_DURATION = 0.45с`):
    - `SphereMesh` unit-radius=0.5 (height=1.0). **Важно:** шейдер использует `sphere_dist = length(object_position) - 0.5` для SDF-noise dissolve, поэтому радиус mesh'а должен быть ровно 0.5; визуальный размер — через `mesh.scale = ONE × (slam_radius / 0.5)` = 10× для дефолтного `slam_radius=5`. Если поставить меньший mesh-radius, dissolve обрезает alpha до 0 → пузырь невидим.
    - `material_override` — `load(slam_distortion_material.tres).duplicate()` per-instance. **Duplicate обязателен:** параллельные slam'ы из пула (cap 3) хранят свой tween-state в shader_parameter'ах; без копии один tween затирает другой.
    - **Tween parallel** трёх параметров одновременно:
      - `mesh.scale: ONE → ONE × target_scale` (TRANS_QUAD, EASE_OUT — резкий старт расширения).
      - `shader.intensity: 1.0 → 0.0` (TRANS_CUBIC, EASE_IN) — master-control шейдера, плавное затухание blur/chromatic/accretion/fresnel.
      - `shader.ripple_time: 0.0 → 1.0` (LINEAR) — волна разбегается; шейдер сам гасит её через `(1 - ripple_time)`.
    - `shader.ripple_center` ставится в **world-координатах** (= origin) перед стартом tween'а — шейдер считает дистанцию от world_position фрагмента, поэтому центр волны **не смещается** при росте сферы.
    - `_set_slam_param(value, mat, name)` helper нужен потому что `Tween.tween_property` не умеет в `shader_parameter`'ы (читаются/пишутся через `set_shader_parameter`, не через property path). Используется `tween_method` с `.bind(mat, name)`.
    - Cleanup через `_recycle_slam_visual(mesh)` — возврат в пул, при `pool.size > cap` — `queue_free`.

2. **Пыль** (`_spawn_slam_dust(origin)`, fire-and-forget):
    - `GPUParticles3D` с `one_shot=true`, `explosiveness=1.0` (все 72 частицы вылетают в первом кадре одним «взрывом», не размазываются по lifetime'у).
    - `amount=72`, `lifetime=0.9с`, `cast_shadow=OFF`.
    - `process_material` — `slam_dust_process.tres`: emission sphere r=0.3, spread 80°, velocity 3.5–6.5 м/с, gravity (0, -2.5, 0), damping 1.5–2.5 (быстро тормозятся в воздухе), angular_velocity ±180°/с (каждая крутится). `scale_curve` 0.4 → 1.0 → 0.0 (растёт первые 30%, плавно сжимается).
    - `material_override` — `slam_dust_material.tres` (`StandardMaterial3D` billboard, серый albedo 0.78, мягкая emission 0.3).
    - `draw_pass_1` — `QuadMesh` 0.22×0.22.
    - **Без пула:** при `slam_cooldown=0.5с` и `dust_lifetime=0.9с` максимум 2 одновременно живых GPUParticles3D, новый создаётся реже чем старый завершается. Cleanup через `get_tree().create_timer(lifetime + 0.2с).timeout.connect(queue_free)`.

**Distortion-shader** — `resources/slam_distortion.gdshader` (`spatial`, `unshaded, cull_disabled, blend_mix`):
- **Black hole distortion**: SCREEN_TEXTURE сэмплируется со смещением `NORMAL.xy * distortion`, где `distortion = distortion_strength × edge_factor² × intensity + ripple_offset`. Вокруг краёв сферы фон преломляется как через линзу.
- **Chromatic aberration**: R/G/B каналы сэмплятся с разным offset'ом по `chromatic_aberration × edge_factor`. Сейчас 0.0 в материале (геймдизайнер выключил для нейтрального ч/б эффекта).
- **Accretion disk glow**: яркая добавка по краям sphere `accretion_color × pow(edge_factor, accretion_width) × accretion_intensity`. Текущий цвет — голубой (тюнинг геймдизайнера в инспекторе).
- **Event horizon darkening**: `event_horizon_radius/darkness` затемняют центр sphere для эффекта «дыры».
- **SDF noise dissolve**: `sdFbm` (recursive bumpy SDF) с `noise_detail=6` итерациями фрактала, `noise_scale_min/max` контролируют через `intensity_2` плавность переходов; на низком intensity_2 (0.3) `dissolve_sharpness=36` → резкие концентрические полосы; на высоком (0.9) `=5.9` → размытое облако.
- **Ripple-волна**: `wave = sin(dist × ripple_frequency - ripple_time × ripple_speed) × 0.5 + 0.5`, затухание `exp(-dist × fade_distance) × (1 - ripple_time)`. Создаёт бегущие наружу концентрические кольца искажения; `ripple_glow` добавляет голубоватую подсветку (хардкод `vec3(0.4, 0.7, 1.0)` в шейдере) на ближней depth-зоне.
- **Depth-аware base color**: `texture(depth_texture)` сравнивает с фрагментом sphere. За пределами `threshold` берётся `color1` (далёкий фон), внутри — `color2` (рядом с поверхностью объекта). Даёт разные тона на «свободном» небе vs «контактной» зоне у скелетов/земли.

**Slam-визуал в инспекторе** (для тонкой настройки):
- `slam_distortion_material.tres` — все шейдер-параметры: цвета, intensity, ripple, accretion, dissolve, blur. Изменения подхватываются на следующем slam'е (per-instance копия делается через `.duplicate()` в `_spawn_slam_visual`).
- `slam_dust_process.tres` — emission/velocity/gravity/scale частиц пыли.
- `slam_dust_material.tres` — albedo/emission пыли.
- В скрипте [hand_physical_slam.gd](scripts/hand_physical_slam.gd) константы `SLAM_DUST_AMOUNT=72`, `SLAM_DUST_LIFETIME=0.9`, `SLAM_DUST_QUAD_SIZE=0.22`, `SLAM_VISUAL_TWEEN_DURATION=0.45`.

**Flick-подмодуль (`HandPhysicalFlick`):**
- `is_active()` возвращает `_active`. Координатор по нему понимает, что hold-state удерживается.
- **Press (`on_press`):** если `_coord.is_holding()` — отказ. Иначе `_coord.find_flick_target()`. При успехе:
  - Стартовое `_flick_orbit_dir` = горизонтальная разница `(hand − target)`, или дефолт `+X` если рука прямо над целью.
  - `_hand.lock_position(true)`, `_active = true`. Cursor world-position продолжает обновляться.
- **Tick (`tick(delta)`, в `_process` координатора):** Если цель `is_instance_valid` ложно → отмена (`lock_position(false)`, сброс). Иначе:
  - `to_cursor_h = horizontal(cursor − target)`. Если ненулевое → `_flick_orbit_dir = to_cursor_h.normalized()`. Если курсор прямо на цели — держим прошлое направление.
  - `_hand.set_locked_position(target + _flick_orbit_dir × flick_orbit_radius)`.
- **Release (`on_release`):** `_hand.lock_position(false)`, `_active = false`. Если цель валидна:
  - `dir = horizontal(target − hand).normalized()` (цель летит противоположно руке).
  - `velocity = dir × flick_force`, `damage = randf_range(flick_damage_min, flick_damage_max)`.
  - `Pushable.try_push(target, velocity, flick_knockback_duration)` + `Damageable.try_damage(target, damage)`.
  - `flicked.emit(target, velocity)`.

**Логика ввода (`_handle_input`):**
- `ACTION_EQUIP_*` — всегда доступны.
- RMB (`ACTION_ACTION`): если ни одна способность не активна — `_dispatch_action_press()` (по `equipped` зовёт `_slam.on_press()` или `_flick.on_press()`); иначе на `just_released` — `_dispatch_action_release()`.
- LMB (`ACTION_GRAB`) — polling. Во время Flick (`_flick.is_active()`) — early return (рука прицеплена к орбите). Иначе фронт `was_grabbing != _is_grabbing` дёргает `_try_grab` / `_release`.

**Подсветка кандидата (`_update_candidate_highlight`):**
- Каждый кадр ищет `_find_closest_grabbable(_hand.get_grabbable_bodies())`, пока `_held == null`.
- На фронте — `_current_candidate.set_highlighted(false)` / `candidate.set_highlighted(true)` (через `has_method` — защита от Grabbable без подсветки).

**`_exit_tree`:** если `_held != null` — `_release()`. Без этого предмет остался бы `freeze=true` в мире после уничтожения руки.

**Логи (`[Hand:Physical] ...`):** экипировка, захват/бросок, магнит-фронт, кандидат-фронт. Slam/Flick логируют под `[Hand:Physical:Slam]` / `[Hand:Physical:Flick]`.

**Зависимости:** только Hand-родитель (через `get_parent()`), контракты `Damageable` / `Pushable` / `Grabbable`, autoloads. Конкретных классов `Item` / `Enemy` не упоминает.

#### 5.2.2 SpellActions — `scripts/hand_spell.gd`

**Тип:** `Node` с `class_name HandSpell extends Node`.

**Категория:** заклинания. **ЗАГЛУШКА** на текущей итерации.

**Жизненный цикл:**
- В `_ready` отключает `set_process(false)` / `set_physics_process(false)` — без активной логики не тикаем.
- `setup(hand: Hand)` вызывается из `Hand._ready` после собственной инициализации. Хранит `_hand` для будущего доступа к позиции/скорости. Получение ссылки идёт явно от координатора, не через `get_parent()`.

**План (TBD):**
- Привязка ввода: ПКМ или клавиши 1..N.
- Реестр заклинаний (`name → cost / cooldown / scene-effect`).
- `cast(spell_name: String)` с проверкой кулдауна/маны.

**Сигналы:**
- `spell_cast(spell_name: String, position: Vector3)` — черновик, под будущих слушателей (UI/звук/анимация башни).

**Экспорты сейчас:** `debug_log: bool = true`.

**Зависимости:** только родитель Hand (через `setup`). Через него — позиция и скорость для исхода заклинания.

### 5.3 CameraRig — `scenes/camera_rig.tscn`, `scripts/camera_rig.gd`

**Тип корня:** `Node3D`.

**Назначение:** контейнер, плавно следящий за указанной целью. Камера-ребёнок наследует движение и сохраняет свой локальный угол.

**Дочерние узлы:**
- `Camera3D` — **перспективная** (раньше была orthogonal). Параметры:
  - `fov = 40°` — узкий угол, чтобы перспективные искажения не «перетряхивали» изометрический look.
  - Локальная позиция `(18, 36.4, 18)` — поднята выше по Y, чтобы pitch ~55° вниз при тех же XZ-осях.
  - Pitch ~55° вниз, yaw 45° (классическая «изометрия» с осью Y вверх).
  - Базис задан явно в `transform = Transform3D(...)` в `.tscn` — не через `look_at`, чтобы матрица не зависела от стартовой позиции рига.

**Скрипт `camera_rig.gd`:** Node3D-фолловер + zoom колесом мыши.
- `@export_node_path("Node3D") target_path: NodePath`.
- `@export follow_speed: float = 8.0`.
- В `_ready` снимает цель, мгновенно прыгает на её позицию (нет «въезда» с (0, 0, 0)). Также сохраняет `_base_offset := _camera.position` — оффсет Camera3D из `.tscn`. Зум масштабирует именно его, не накапливая ошибки от предыдущих кадров.
- В `_process`: `global_position = global_position.lerp(target.global_position, follow_speed * delta)` + `_update_zoom(delta)`.

**Zoom колесом мыши:**
- `_unhandled_input`: ловит `InputEventMouseButton` с `button_index = MOUSE_BUTTON_WHEEL_UP / WHEEL_DOWN`. WHEEL_UP → `_zoom_target *= zoom_step` (приближение), WHEEL_DOWN → `/= zoom_step` (отдаление). После клампа в `[zoom_min, zoom_max]`.
- `_update_zoom(delta)` лерпит `_zoom → _zoom_target` по `zoom_speed × delta` (snap к target при `Δ < 0.001`, иначе asymp-tic-tail). На каждом тике пишет `_camera.position = _base_offset * _zoom` — направление и угол сохраняются, меняется только дистанция (Camera3D's basis из .tscn неизменен).
- Mouse wheel — единственный геймплейный инпут, который **не** идёт через project.godot input actions: пересмотр-зум — UI-уровень и не нуждается в рекастомизации.

**Экспорты группы `Zoom`:**
- `zoom_step: float = 0.9` — множитель оффсета за один щелчок колеса (10% приближения; обратный 1/0.9 ≈ 1.11 для отдаления).
- `zoom_min: float = 0.4`, `zoom_max: float = 5.0` — границы относительно базового оффсета. 1.0 = «как в .tscn». zoom_max повышен с 2.5 → 5.0 — двойной зумаут для обзора крупных волн (на отдалении 5× все скелеты вне `lod_far_distance=50` уходят в FAR-LOD). Slam достаёт FAR-скелетов через group-fallback (`HandPhysicalSlam._perform_slam` второй проход); hand grab — через основной Area3D, FAR-скелеты ему недоступны (collision_shape disabled).
- `zoom_speed: float = 10.0` — скорость экспоненциального доезда к целевому зуму.

**Поля состояния:** `_base_offset: Vector3` (стартовый оффсет камеры), `_zoom: float = 1.0` (текущий, плавный), `_zoom_target: float = 1.0` (куда едем).

**Внешние зависимости:** ничего. `target_path` устанавливается из главной сцены, скрипт не знает имени цели.

### 5.4 Item — `scenes/item.tscn`, `scripts/item.gd`

**Тип корня:** `RigidBody3D` с `class_name Item`.

**Назначение:** базовый подбираемый предмет. Все варианты (дерево/камень/железо) — это инстансы одной сцены с разным `item_color`, `item_size` и `mass`.

**Дочерние узлы:**
- `CollisionShape3D` — `BoxShape3D` 1×1×1 (заглушка, перезаписывается в `_ready`).
- `MeshInstance3D` — `BoxMesh` 1×1×1 без материала-по-умолчанию.

Кешируются как `@onready var _mesh: MeshInstance3D = $MeshInstance3D` / `_shape: CollisionShape3D = $CollisionShape3D`. `_apply_visual` / `_apply_shape` пишут в них напрямую — раньше каждый метод заново звал `$MeshInstance3D` / `$CollisionShape3D`.

**Экспорты:**
- `item_color: Color` — базовый цвет.
- `item_size: Vector3` — размер бокса (XYZ).
- `highlight_color: Color` — цвет emission'а при подсветке (по умолчанию тёплый жёлтый).
- `highlight_intensity: float` (0..5) — `emission_energy_multiplier` при подсветке.
- `hp: float = 100.0` — здоровье. На 0 → `destroyed.emit()` + `queue_free()`.
- Унаследованный `mass: float` — стандартное свойство `RigidBody3D`, переопределяется на инстансе.

**Регистрации в `_ready`:**
- `Damageable.register(self)` — принимает урон через `take_damage`.
- `Pushable.register(self)` — принимает push через `apply_push`.
- `Grabbable.register(self)` — рука может схватить.
- Re-emit `damaged` / `destroyed` на `EventBus.item_damaged/_destroyed`.
- Создание уникальных `BoxMesh` / `BoxShape3D` / `StandardMaterial3D` (`_apply_visual` / `_apply_shape`). Ссылка на материал кэшируется в `_material` для управления emission'ом. Ресурсы из `item.tscn` остаются только для превью пустой заготовки в редакторе.

**Сигналы:**
- `damaged(amount: float)` — каждый раз при `take_damage`.
- `destroyed` — когда `hp` ушло в 0 (один раз, перед `queue_free`).

**Публичный API:**
- `set_highlighted(value: bool)` — включает/выключает emission. Без изменений: рука дёргает на смене кандидата.
- `take_damage(amount: float)` — общий damageable-контракт.
  - Идемпотентность через `is_queued_for_deletion()` (отдельное поле `_destroyed` удалено — `RigidBody3D` уже знает, что он на пути в небытие).
  - На `hp ≤ 0` → `destroyed.emit()` + `queue_free()`.
- `apply_push(velocity_change: Vector3, _duration: float)` — реализация Pushable-контракта.
  - При `freeze` (предмет в руке, RigidBody-интегратор отключён) — ранний return: импульс ушёл бы в никуда.
  - Иначе `apply_central_impulse(velocity_change * mass)` — Pushable-контракт обещает «изменение скорости», поэтому масштабируем по массе сами (RigidBody импульс делит на mass).
  - `_duration` игнорируется — у RigidBody knockback-таймер не нужен, всё уже в физике.

**Тестовый набор предметов в `main.tscn`:**

| Имя | Размер | Масса | Толкается башней (mass=10)? | Поднимается рукой (max_lift=10)? |
|---|---|---|---|---|
| SmallBox | 0.5³ | 0.5 | да, легко (ratio=0.95) | да |
| WoodBox | 1³ | 1 | да, легко (ratio=0.9) | да |
| StoneBox | 1³ | 5 | да, медленнее (ratio=0.5) | да |
| IronBox | 1.5³ | 8 | да, тяжело (ratio=0.2) | да |
| GiantCrate | 2.5³ | 20 | нет — башня упирается, скользит вокруг | нет — рука игнорирует |

**Внешние зависимости:** контракты `Damageable` / `Pushable` / `Grabbable`, autoload `EventBus`.

### 5.5 Enemies — категория врагов

Иерархия: `Enemy` (база) → `Skeleton` (конкретный тип). Вспомогательный модуль смерти — `ShatterEffect` (общий, не привязан к одному врагу). Спавн делает отдельный узел `EnemySpawner` в `main.tscn`.

#### 5.5.1 Enemy — `scripts/enemy.gd`

**Тип корня:** `CharacterBody3D` с `class_name Enemy`. **Базовый класс**, не используется напрямую — только через подклассы (Skeleton и будущие).

**Назначение:** общая инфраструктура врагов — HP/урон, knockback, гравитация, цикл `_physics_process`, **базовый FSM атаки** и набор виртуальных хуков, через которые подкласс описывает «свою» атаку. Без подкласса не запускается осмысленно.

**FSM (общий, в базе):**

```gdscript
enum AttackState { APPROACH, WINDUP, STRIKE, COOLDOWN }
```

- `_state: int` — текущее состояние, по умолчанию `APPROACH`.
- `_state_timer: float` — обратный отсчёт текущей фазы (windup/cooldown). Тикается внутри `_ai_step` (для WINDUP) и в `_physics_process` (для COOLDOWN — иначе самонанесённый lunge-knockback искусственно удлинял бы атак-цикл).
- Переходы централизованы в `_enter_state(new_state)`: дёргает `_on_state_exit(old)` → меняет `_state` → выставляет `_state_timer` (windup→`attack_windup`, cooldown→`attack_cooldown`, иначе 0) → дёргает `_on_state_enter(new)`.
- `_ai_step` (тоже в базе) рулит переходами APPROACH↔WINDUP по дистанции и WINDUP→STRIKE→COOLDOWN→APPROACH по таймерам. Подклассу обычно `_ai_step` переопределять не надо — достаточно `_perform_strike` и хуков состояний.

**Экспорты:**
- `hp: float = 30.0` — здоровье.
- `move_speed: float = 4.0` — горизонтальная скорость передвижения.
- `gravity: float = 20.0` — ускорение свободного падения.
- `attack_range: float = 1.5` — на каком расстоянии до цели начинается атака.
- `attack_damage: float = 8.0` — урон цели при атаке. С variance ±20% в Skeleton — 6.4-9.6 за strike. 1 удар = ~27% pikeman-hp (30), копейщик умирает за 3-5 ответных.
- `attack_cooldown: float = 1.0` — секунды между атаками. Тикает всегда (в т.ч. в knockback'е).
- `attack_windup: float = 0.4` — длительность фазы WINDUP до удара.
- `attack_windup_point_blank: float = 0.1` — короткий windup, если цель уже глубоко в attack_range на момент входа в WINDUP. См. **Point-blank trigger** ниже.
- `point_blank_distance_factor: float = 0.7` — доля от `attack_range`, ниже которой замах считается point-blank'ом.
- `knockback_friction: float = 5.0` — насколько быстро затухает knockback-velocity (lerp-коэф).
- Группа **Knockback contacts:**
  - `bounce_restitution: float = 0.6` — коэффициент отскока от активной цели при ударе во время knockback'а.
  - `neighbor_push_factor: float = 0.5` — доля собственной скорости, передаваемая соседу-Enemy при контакте в knockback'е.
  - `neighbor_push_duration: float = 0.15` — длительность knockback'а на соседа.
- Группа **Effects:**
  - `effects_root_path: NodePath` (`@export_node_path("Node")`) — куда складывать эффекты смерти (осколки и т.п.). В `_ready` резолвится: при пустом пути или если узел не нашёлся — фолбэк на `get_tree().current_scene` плюс `push_warning`. Используется подклассами через поле `_effects_root`.

**Сигналы:** `damaged(amount: float)`, `destroyed`.

**Публичный API:**
- `take_damage(amount)` — общий damageable-контракт. На `hp ≤ 0` → `destroyed.emit()` → `_on_destroyed()` → `queue_free()`. Защищён от повторного входа флагом `_dying`.
- `apply_push(velocity_change, duration)` — Pushable-контракт. Реализован как тонкий делегат к `apply_knockback`: «push» и «knockback» для врага семантически одно и то же.
- `apply_knockback(impulse, duration)` — внешний толчок. Через `KnockbackState.compose(velocity, impulse)` (x/z заменяются, y берётся как `max`) сливает impulse в текущую velocity, взводит таймер через `_knockback.start(duration)`, затем зовёт виртуальный `_on_knockback()` (хук подкласса для «сбить замах» и т.п.).
- `_apply_velocity_change(impulse, duration)` — низкоуровневая запись velocity + взвод таймера, **без** хука `_on_knockback`. Используется самим базовым классом (внутри `apply_knockback`) и подклассами для self-knockback (Skeleton lunge): свой же удар не должен дёргать хук «отмены состояний» и сбивать собственное FSM.

**Состояние knockback'а:**
- `_knockback: KnockbackState = KnockbackState.new()` — общий helper для всех kinematic-knockback'ов (Enemy, Gnome). Раньше код таймера и lerp-затухания дублировался; вынесен в один RefCounted-объект. Поля: `friction` (выставляется в `_ready` из `knockback_friction`), внутренний `_timer`. Методы: `is_active()`, `start(duration)`, `tick(delta)`, `apply_friction(velocity, delta)`, статический `compose(current_v, impulse)`.
- `set_target(target)` / `set_targets(array)` — назначить кандидата(ов) в цели. Поле `_targets: Array[Node3D]`, AI каждый кадр через `get_active_target()` выбирает ближайшую живую (мёртвые `is_instance_valid → false` пропускаются автоматически, ручная чистка не нужна).
- `get_active_target() -> Node3D` — ближайшая валидная цель или `null`.

**`_ready` и обязательная регистрация контрактов:**
- В базовом `_ready` вызываются `Damageable.register(self)` и `Pushable.register(self)`, плюс re-emit'ы `damaged`/`destroyed` на `EventBus`.
- Подклассы, переопределяющие `_ready`, **обязаны** звать `super._ready()`. Иначе регистрация контрактов и подключение к EventBus тихо потеряются.
- Защита: сразу после регистраций в `_ready` стоят `assert(is_in_group(Damageable.GROUP))` и аналог для Pushable — забытый `super._ready()` падает с ассертом сразу. Раньше asserts стояли в `_physics_process` (выполнялись каждый физкадр на каждом враге — на 50 скелетов это лишняя работа в editor-сборке); перенос в `_ready` ничего не теряет, поскольку группы расставлены прямо в той же функции.
- В `_ready` также `_knockback.friction = knockback_friction` — связка export'а с helper'ом.

**Виртуальные хуки:**
- `_perform_strike(target: Node3D)` — конкретный удар. Подкласс наносит урон и/или делает физический выпад. Вызывается базой ровно один раз в момент `WINDUP → STRIKE`, сразу после которого база сама переводит FSM в `COOLDOWN`.
- `_on_state_enter(new_state)` / `_on_state_exit(old_state)` — реакция на смену фазы FSM. Типичный кейс — телеграф замаха (Skeleton: coiled-pose squash на enter `WINDUP`, extended-pose snap на enter `STRIKE`).
- `_on_knockback()` — реакция на **внешний** толчок. Базовая реализация: только `WINDUP` сбрасывается в `APPROACH`. `COOLDOWN` намеренно **не** сбрасывается — кулдаун продолжает тикать в `_physics_process` независимо от knockback'а.
- `_on_destroyed()` — вызывается ровно перед `queue_free` на смерти, после `destroyed.emit`. Подклассы спавнят визуал смерти — он добавляется в `_effects_root` и переживает сам труп.

**Цикл (`_physics_process`):**
1. Гравитация → `velocity.y` (если не на полу), иначе обнуляется.
2. Декремент `_state_timer` для COOLDOWN — тикает всегда.
3. `_knockback.tick(delta)`. Если `_knockback.is_active()` — AI заглушен, горизонтальная velocity сглаживается через `_knockback.apply_friction(velocity, delta)` (lerp к нулю по `friction × delta`).
4. Иначе — зовётся `_ai_step(delta)` (в базе: APPROACH → WINDUP таймер → STRIKE через `_perform_strike` → COOLDOWN таймер).
5. Запоминается `pre_slide_velocity := velocity`, далее `move_and_slide()`.
6. Если `_knockback.is_active()` — `_resolve_knockback_contacts(pre_slide_velocity)`:
   - Контакт с активной целью → нормали суммируются, после цикла применяется `_bounce_off_target` (elastic-отскок с `bounce_restitution`, считается через **pre-slide** velocity).
   - Контакт с другим `Enemy` → `_push_neighbor`: соседу применяется push **через `Pushable.try_push`**. Минимальный порог `MIN_NEIGHBOR_PUSH_SPEED = 0.5` отсеивает «соскользили вдоль» от «врезались».
   - Self-bounce от цели **не** идёт через Pushable: это собственная реакция инстанса на коллизию, не внешний толчок, и `_on_knockback` дёргать незачем.

**Point-blank trigger.** В `_approach_target` после `_enter_state(WINDUP)` проверяется текущая дистанция до цели: если `dist ≤ attack_range × point_blank_distance_factor` — `_state_timer` переписывается на `attack_windup_point_blank`. Дизайнерское правило: «в упор не нужен полный замах, ткнул сразу». Главная цена для бойцов (Pikeman): после lunge'а они стоят 0.35с в RECOVERY — point-blank windup 0.1с легко перекрывается ответным ударом скелета, оказавшегося в нос. На «крайних» WINDUP'ах (dist ≈ attack_range) point-blank НЕ срабатывает — нормальный замах 0.4с. Применяется ко всем подклассам Enemy.

**Зависимости:** только физика, `Damageable`/`Pushable`/`Layers`/`VecUtil` и наследники. Не знает про Tower, Hand, Item.

#### 5.5.2 Skeleton + ShatterEffect — `scenes/skeleton.tscn`, `scripts/skeleton.gd`, `scripts/shatter_effect.gd`

**Тип корня:** `CharacterBody3D` с `class_name Skeleton extends Enemy`.

**Назначение:** простейший враг — конкретизация базы. Идёт к ближайшей живой цели, в `attack_range` входит в `WINDUP` (телеграф), на завершении замаха выполняет физический выпад с уроном. Большая часть логики унаследована от `Enemy`; подкласс заполняет три слота: визуал замаха (через хуки состояний), сам удар (`_perform_strike`) и эффект смерти (`_on_destroyed`).

**Дочерние узлы:**
- `CollisionShape3D` — `CapsuleShape3D` r=0.4, h=2.
- `MeshInstance3D` — `CapsuleMesh` того же размера.

**Слой/маска (в `.tscn`):** `collision_layer = 16` (Enemies), `collision_mask = 39` (Terrain + Items + Actors + CampObstacle, **без Enemies**). См. §4.1: skel-skel коллизии отключены ради перфоманса (broad-phase + slide-iterations были главным пожирателем physics_ms на 400+ кластерах вокруг Tower).

**Override на инстансе:** `move_speed = 2.7` (медленнее общего дефолта Enemy=4.0).

**Vision-таргетинг (override базового `_targets`):**

Skeleton не использует `Enemy._targets` — вместо этого **сканирует группу `skeleton_target`** в радиусе `vision_radius` и выбирает цель с приоритетом. В группу входят (этап 42-43):
- **Tower** — пока `Camp._state == CARAVAN_FOLLOWING` или `_finalize_pack` (Camp ставит/убирает через `_set_tower_aggro`). Скелеты бьют башню при движении каравана. На развёртке tower уходит из группы — агро переключается на палатки/гномов вокруг костра.
- **Палатки** (CampPart) — теперь почти всегда (кроме PACKING_RETURNING когда тент бронируется): в каравне атакуемы тоже. Раньше «только в DEPLOYED», изменено по геймдизайну: караван = полноценная цель.
- **Активные гномы** — через `Gnome.enter_deployed/request_return`. Защитники у периметра — тоже.

**Приоритет: гномы > палатки.** Скелеты «голодные», охотятся на существ. Если в радиусе хоть один живой гном (любого типа — собиратель или защитник), идём к ближайшему гному, палатки игнорируются. Палатка берётся целью только когда гномов в зоне нет (например, на свёртке лагеря все попрятались). Защитники-лучники у периметра лагеря «перехватывают агро» — wave-скелеты переключаются на них как только подходят на 12м к лагерю, прежде чем добежать до палаток.

**`forced_target: Node3D` — fallback aggro-точка для wave-скелетов.** WaveDirector назначает её через `set_forced_target(palatка)` сразу после `spawn_group`. В `_scan_target` используется только если весь vision пуст — это «направление движения» для скелетов, заспавненных в 50м+ от лагеря (vision только 12м, без forced они wander бесцельно). Когда волна доходит до 12м зоны — vision захватывает гномов на периметре, и приоритет переключает скелета на ближайшего гнома.

**Spatial grid целей (главный perf-фикс на 290+ скелетах × 144 цели):** наивный скан `get_nodes_in_group("skeleton_target")` каждым скелетом × ~5000 сканов/сек × 144 элементов = **~720k distance-checks/сек** = ~12-15мс из 20мс physics_ms. Заменён на статический spatial grid:
- `static var _target_grid: Dictionary = {}` — `Vector2i(cell_x, cell_z) → Array of [Vector3 pos, Node3D node]`. Глобальный для всех скелетов.
- `TARGET_GRID_CELL_SIZE = 12.0` (= `vision_radius`). 3×3 cell'ов вокруг скелета гарантированно покрывают vision-диск.
- `TARGET_GRID_REFRESH_INTERVAL = 0.4с`. Все скелеты читают один глобальный snapshot. Stale-границы: гном двигается ≤0.64м за 0.4с (move_speed=1.6 × 0.4) — для vision_radius=12 неотличимо. Палатки и большинство гномов в зоне атаки стоят на месте — тоже неотличимо.
- `_maybe_refresh_target_grid(tree)` — ленивый pass по группе раз в 0.4с globally, в начале каждого скана. Один pass на 144 цели вместо 5000 pass'ов.
- `_scan_target` теперь читает 9 cell'ов (3×3) вокруг своей cell-позиции. Каждый cell — Array из ~5-15 элементов в плотной Camp-зоне, 0 в пустой. Итого ~50 distance-checks вместо 144 на скан, **редукция ×3**.

**Cache + throttle поверх grid'а:**
- Поле `_cached_target: Node3D` — последняя найденная цель.
- Поле `_vision_scan_timer: float`, период `vision_scan_interval = 0.4с` (история: 0.15 → 0.3 → 0.4, см. этап 43).
- Override `_physics_process(delta)`: тикает таймер; если истёк **или** кэш протух (`is_instance_valid=false` или вне группы `skeleton_target`) — рескан. **NB (этап 43):** `null` НЕ считается stale — это легитимное «целей в зоне нет». Раньше было `stale := _cached_target == null or ...`, и бесцельный скелет сканировал каждый physics-tick (60Гц) вместо раз в 0.4с — на 452 скелетах `_scan_target` давал 27k вызовов/сек и 2.39ms/тик. После фикса — 27 вызовов/тик, 0.30ms.
- Override `get_active_target()`: возвращает кэш, провалидировав группу/валидность; если устарел — `null` (следующий тик пере-сканирует).
- В `_ready` → `_vision_scan_timer = randf() * vision_scan_interval` — фазовый сдвиг, чтобы 50 скелетов не сканировали группу в один кадр.

**Aggro-on-hit:** подписка на собственный `damaged`-сигнал → `_on_damage_react_aggro` дёргает `_scan_target` немедленно, минуя 0.4с-тайминг. Без этого pikeman мог сделать весь lunge-цикл (APPROACH/WINDUP/LUNGE/DRIFT/RECOVERY ≈ 0.85с) внутри одного scan-интервала, и скелет успевал отреагировать только когда атакующий уже в безопасности. Стоимость хука — один scan-call на каждый удар (≪ 60Гц), нагрузки ноль. Сценарий: pikeman lunge → strike → push knockback (через `Pushable.try_push` → `apply_knockback` → `_on_knockback` сбрасывает WINDUP→APPROACH) → скелет в APPROACH'е с уже-новым `_cached_target` (pikeman) → следующий AI tick идёт на pikeman'а, который в RECOVERY и не может отбиться. Это и есть «уязвимое окно» бойца.

**Per-spawn variance:** в `_ready` после `super._ready` зовётся `_apply_stat_variance` — ровно один раз умножает hp/damage/windup/move_speed/cooldown на `randf_range(1-X, 1+X)`. Константы: hp/damage/windup ±20%, speed/cooldown ±15%. Дизайнерская цель — defenders не должны автопилот'ить волну по запомненному ритму («windup ровно 0.4с, hp ровно 30»). На пачке 200+ скелетов разброс создаёт волатильность: одни умирают с первого удара, другие наносят больший урон, кто-то windup'ит на 0.32с (быстрее ожидаемого), кто-то на 0.48с. Move_speed разброс меньше — большее значение «ломало» бы пакетное движение цепочкой; 15% даёт лёгкое расслоение, форма волны остаётся читаемой.

**Gotcha (важный паттерн при работе с grid-snapshot'ами):** typed-assignment из Array (`var node: Node3D = entry[1]`) вылетает с `Trying to assign invalid previously freed instance`, если объект уже освобождён — runtime бьёт ошибку **до** проверки `is_instance_valid`. Правильный паттерн:
```gdscript
var raw = entry[1]              # untyped Variant
if not is_instance_valid(raw):
    continue
var node := raw as Node3D       # `as` cast freed-объекта возвращает null без ошибки
if node == null:
    continue
```
В loops через `for n in get_nodes_in_group(...)` тот же паттерн (`n` заимствуется как Variant, `as` возвращает null для freed) — безопасно. Опасно именно при typed `var x: Type = arr[i]` на потенциально-freed-элементе.

**Экспорты:**
- Группа **Vision:**
  - `vision_radius: float = 12.0` — дальность зрения. Цель в этом радиусе считается «увиденной».
- Группа **Vision scan throttle:**
  - `vision_scan_interval: float = 0.4` (этап 43, было 0.3) — период между ре-сканами целей (с). На 2000 скелетов даёт +25% экономии vs 0.3с. См. также fix throttle когда `_cached_target=null` в `_physics_process`.
- Группа **Wander (без цели):**
  - `wander_speed: float = 1.2` — скорость патруля без цели.
  - `wander_distance_min/max: 5.0/15.0` — диапазон следующей wander-точки.
  - `wander_rest_min/max: 1.0/3.0` — длительность RESTING-фазы.
  - `wander_map_half_extent: 145.0` — клампа wander-точки в пределах карты 300×300.
  - `wander_arrival: 0.8` — порог «дошёл».
- Группа **Strike (физический выпад):**
  - `lunge_speed: float = 8.0` — m/s в момент удара (выше `move_speed`).
  - `lunge_duration: float = 0.2` — длительность knockback'а на сам выпад.
- Группа **Shatter (рассыпание на смерти):**
  - `shatter_fragment_count: int = 7`.
  - `shatter_lifetime: float = 2.0` (секунды).
  - `shatter_color: Color` — цвет осколков (дефолт = цвет тела).
- Группа **LOD (масштабирование на 2000+ скелетов):**
  - `lod_near_distance: float = 25.0` — ближе которой работает на полной частоте (LOD `NEAR`).
  - `lod_far_distance: float = 50.0` — дальше которой минимальная частота (LOD `FAR`). Между — `MID`.
  - `lod_check_interval: float = 0.5` — период переоценки LOD-уровня. Distance-чек 2000 врагов на каждом физкадре сам по себе нагрузка.
  - `lod_far_tick_divisor: int = 4` (range 1-6) (этап 43, было 3) — кратность пропуска физтика для FAR-скелетов. На 1900 FAR-скелетах `_far_step` (knockback.tick, vision-валидность, AI, position-write) — основной пожиратель physics_ms после того, как broad-phase отключён через `CollisionShape3D.disabled`. Кратность 4 = 60→15Гц. Slam-knockback по FAR задерживается максимум на `divisor × 16.6мс ≈ 67мс` — игрок не успевает заметить.
  - `lod_mid_tick_divisor: int = 4` (range 1-6) (этап 43, было 3) — кратность пропуска физтика для MID-скелетов. 4 = каждый 4-й физкадр (60→15Гц). Скорость движения сохраняется компенсацией `velocity *= divisor` в `_ai_step` — один `move_and_slide` на N тиков переносит N-кратное движение. Tunneling-риск: `move_speed=2.7 × 4 × 0.0167 = 0.18м/тик` при радиусе 0.4м (запас ×2, безопасно). На 25-50м от камеры визуально незаметно.
  - `lod_offscreen_half_angle_deg: float = 60.0` (range 30-90) — **frustum-override**: скелет вне cone'а «впереди камеры» форсируется в FAR независимо от расстояния (его не видно игроку — симулировать дёшево безопасно). 60° полу-cone = 120° полный, с запасом покрывает горизонтальный FOV ~95°. Прекомпьют `cos(deg_to_rad(...))` в `_ready` (раз в 0.5с × 2000 скелетов на trig-функциях — заметно). При типичном кластере вокруг Tower'а frustum-override переносит ~50% NEAR/MID в FAR, освобождая physics.

**LOD-поведение** (см. enum `LodLevel { NEAR, MID, FAR }`):

| Уровень | Дистанция от камеры | AI-tick | vision_scan | Физика |
|---|---|---|---|---|
| NEAR | ≤ 25м, в frustum-cone | каждый кадр | каждые 0.4с | Полная (collision_layer=ENEMIES, MASK_SKELETON, move_and_slide на 60Гц). Boids-avoidance включён. |
| MID | 25..50м, в cone | каждый 2-й | каждые 0.8с (×2) | Полная, но move_and_slide на 15Гц (`mid_tick_divisor=4` с velocity-компенсацией). Boids выключен (этап 43). |
| FAR | > 50м **или** вне cone | каждый 3-й (внутри `_far_step`) | каждые 1.6с (×4) | **Холодная: collision_layer=0, mask=0, `CollisionShape3D.disabled=true`, без `move_and_slide`. `_far_step` тикает только каждый N-й физкадр (`far_tick_divisor=4`)** |

**Что мерится:** дистанция до **точки интереса камеры** — `Camera3D.get_parent()` если он Node3D (т.е. наш `CameraRig`), иначе сама `Camera3D.global_position`. Через CameraRig потому, что он lerp'ом следует за Tower, а зум камеры (через `Camera3D.position × _zoom`) меняет реальную позицию Camera3D, **не** меняя CameraRig. До этого фикса при максимальном зуме (zoom=2.5, Camera3D на ~111м от центра карты) скелеты возле башни все становились FAR, и slam терял по ним цели — теперь зум на LOD не влияет. Tower как якорь не подошёл — он может queue_free, а CameraRig живёт всегда.

**Холодный режим FAR (главный win на 2000 скелетах: physics_ms 29 → ~5-10мс):**
- `collision_layer = 0`, `collision_mask = 0`, **`CollisionShape3D.disabled = true`**. На 2000 движущихся CharacterBody3D `collision_mask=0` сам по себе НЕ убирает тело из broad-phase BVH — physics-сервер всё равно индексирует AABB и ребилдит дерево каждый раз, когда `_far_step` двигает `global_position`. Только `disabled = true` (или `collision_layer=0`) полностью исключает тело из broad-phase. Это и есть главный перф-фикс — раньше FAR-скелеты лежали на `Layers.COLD_ENEMY`, и BVH индексировал их зря.
- `@onready var _collision_shape: CollisionShape3D = $CollisionShape3D` — кэшированная ссылка для toggle.
- `_apply_lod_physics_mode` идемпотентен: переключение `disabled` происходит только при реальной смене уровня, не каждые 0.5с.
- `move_and_slide()` пропускается. Вместо неё `_far_step` делает простое `global_position.x/z += velocity * delta × divisor` (на полном тике, остальные — early return).
- **FAR-divisor с work_delta-компенсацией:** счётчик `_far_phys_tick_counter` декрементируется каждый физкадр; на N-м тике вызывается `_far_step(delta * N)`, чтобы movement, knockback friction и vision_scan_timer корректно покрывали пропущенные кадры в wall-clock. Фазовый сдвиг `randi() % 6` в `_ready` — иначе 1900 FAR-скелетов работали бы синхронно одной волной нагрузки.
- **Что сохраняется в _far_step:** `KnockbackState.tick(delta)` (иначе lunge через `_apply_velocity_change` навечно отправил бы скелета в полёт), декремент `_state_timer` для COOLDOWN, AI-step (включая LOD-skip в APPROACH), Damageable.try_damage в `_perform_strike` (урон по палатке/гному не зависит от collision-layer'ов).
- **Что теряется:** скелеты сквозят друг друга и палатки вне камеры (но игрок этого не видит); нет gravity (плоский пол — ок); `is_on_floor()` всегда false на FAR (AI это не читает).
- **При возврате FAR→MID** (скелет приблизился к камере или зашёл в frustum-cone): `_apply_lod_physics_mode` восстанавливает `collision_layer = Layers.ENEMIES` / `collision_mask = MASK_SKELETON` / `_collision_shape.disabled = false`, и со следующего тика снова работает полный `super._physics_process` — physics возвращается без проблем.

**Что скипается, что нет на NEAR/MID:**
- Скип AI-tick — **только в `AttackState.APPROACH/wander`**. В `WINDUP` не скипаем (там декрементится таймер замаха, скип заморозил бы скелета); в `STRIKE` транзитно; в `COOLDOWN` таймер тикает в базе независимо.
- Knockback, гравитация работают на полной частоте всегда (только на NEAR/MID; FAR — холодный режим выше).
- При скипе AI velocity сохраняется — скелет едет по инерции до следующего полного тика.

**Anti-«волна»:** `_lod_check_timer = randf() * lod_check_interval`, `_lod_ai_tick_counter = randi() % 6`, `_far_phys_tick_counter = randi() % 6`, `_mid_phys_tick_counter = randi() % 4` в `_ready` — distance-чеки и skip-тики разнесены по фазе. Иначе кадровая нагрузка идёт волной каждые 0.5с.

**Initial LOD apply в `_ready`:** в самом конце `Skeleton._ready()` зовётся `_apply_lod_physics_mode()`. До этой страховки initial `_lod_level=NEAR` полагался на маски в [skeleton.tscn](scenes/skeleton.tscn) (16/39); сейчас совпадает, но любая правка маски в `.tscn` тихо ломала бы первый кадр всех NEAR-скелетов до первого LOD-перехода (lod_check_interval=0.5с). Явный вызов делает контракт автономным.

**Counter reset на knockback exit:** `_physics_process` запоминает `was_knockback_active := _knockback.is_active()` **до** super/_far_step и сравнивает после. На переходе active→inactive — `_mid_phys_tick_counter = 0` и `_far_phys_tick_counter = 0`. Без этого счётчик мог застрять на skip-фазе во время knockback'а → следующий кадр после восстановления был бы skipped → AI хочет двигаться, но скелет «глюк-замораживается» на ~16мс (MID) / ~50мс (FAR). Phase-randomization уменьшает шанс, но не исключает.

**Что игрок не заметит:** скелеты вне камеры всё равно вне камеры; реакция дальних на цель хуже на ~0.5с (один divisor-цикл, меньше windup'а 0.4с). На 2000 скелетах при равномерном распределении (~25 NEAR + 75 MID + 1900 FAR) physics-сервер обрабатывает броад-фазу для ~100 тел вместо 2000 + `_far_step` тикает не на 60Гц, а на 20Гц. Замеры до фиксов: physics 29мс / FPS 7. После: physics ~5-10мс / FPS 30-60 (зависит от того, что становится следующим узким — обычно draw calls на 2000 уникальных MeshInstance3D). Дальнейший buster — MultiMesh + GPU-instanced рендер (~250 строк, 2-3 часа).

#### Boids-style avoidance — мягкое расступание толпы взамен убранных physics-пар

Симптом, который вылез после убирания skel-skel коллизий (`MASK_SKELETON` без ENEMIES, см. §4.1): скелеты сходятся в одну кучу и проходят друг через друга — некрасиво. Лечение через flocking-avoidance, не возвращая physics-пары.

**Параметры (экспорты группы `Neighbor avoidance (boids-style)`):**
- `neighbor_avoidance_radius: float = 1.5` — personal space (≥ `capsule_radius × 2 = 0.8м` с запасом для визуально-комфортного зазора).
- `neighbor_avoidance_strength: float = 0.5` (range 0.0-2.0) — сила отталкивания как доля `move_speed`. 0.5 = avoidance может прибавить до 0.5 × 2.7 = 1.35м/с к velocity. **0 — выключить** (вернётся «толпа фантомов»).

**Реализация — второй static spatial grid:**
- `static var _skel_grid: Dictionary` (по аналогии с `_target_grid`), `SKEL_GRID_CELL_SIZE = 4.0м`, `SKEL_GRID_REFRESH_INTERVAL = 0.3с`. Заполняется лениво из `SKELETON_GROUP` в начале `_apply_neighbor_avoidance`.
- В `_ai_step` после `super._ai_step` / `_wander_tick` вызывается `_apply_neighbor_avoidance()`. Скелет суммирует векторы отталкивания от соседей в radius=1.5м (linear falloff `(radius − dist) / radius`), кап по магнитуде `move_speed × strength`, прибавка к velocity.
- **Применяется только в APPROACH/wander на NEAR-уровне** (этап 43, было NEAR+MID). MID/FAR-скелеты пропускаются — на 25м+ от камеры мелкие столкновения тимы визуально не читаются, а cost ~18мкс/call. На 2000 скелетах экономия ~1ms vs прежнее «NEAR+MID». Engaged-скелеты (WINDUP/STRIKE/COOLDOWN) на позициях боя не отталкиваются — они стоят и бьют.
- **Self-фильтр через идентичность ноды** (`entry[1] == self`), не через `d_sq < epsilon` — стейл-снимок отдалён на ~0.81м, эпсилон-чек давал бы фантомный push в собственную stale-копию (этап 41).
- Avoidance прибавляется **до** MID-velocity-компенсации, чтобы масштабироваться синхронно с divisor'ом.

**Цена:** 9-cell scan × ~5 entries × ~10 ops = ~200 ops/вызов. ~12k вызовов/сек × 200 ops ≈ 0.2мс/кадр на 400 NEAR/MID скелетов. Незначительно.

**Эмерджентное поведение:** скелеты, идущие к одной палатке, формируют не плотный «клин», а арку/полукольцо вокруг неё (avoidance = тяга наружу, target = тяга внутрь, equilibrium на ring'е). Выглядит естественно как RTS-flocking.

**Константы:** `BODY_ALBEDO_COLOR`. Per-instance тонкая настройка цвета не предусмотрена.

**Static shared material (батчинг GPU):**

```gdscript
static var _shared_normal_material: StandardMaterial3D
```

Создаётся **один раз на класс** через `_ensure_shared_materials()` в первом `_ready`. Все скелеты делят один материал на класс — никаких `.duplicate()` per-instance. GPU батчит 50 скелетов в один draw call.

Раньше был ещё `_shared_windup_material` с красным emission — телеграф WINDUP'а через цвет. Удалён: красная подсветка читалась игроком как «получил урон», а не как «замахивается». Заменён на pose-телеграф (squash & stretch на _mesh.scale, см. ниже).

**`_ready`:** `super._ready()` (обязателен), затем `_apply_stat_variance`, `_ensure_shared_materials()` и `_mesh.material_override = _shared_normal_material`.

**Override'ы базы:**
- `_on_state_enter(new_state)`: на `AttackState.WINDUP` → `_tween_pose_to(POSE_WINDUP_SKEL, POSE_WINDUP_TIME)` (coiled-поза) + **защёлкиваем `_windup_target = get_active_target()`** (этап 47). Лок цели замаха — strike будет бить именно её, а не текущий рескан-результат. На `AttackState.STRIKE` → `_tween_pose_strike()` (snap в extended-позу с chain'ом restore к нейтрали).
- `_on_state_exit(_old_state)`: ничего — поза управляется через enter-хуки.
- `_on_knockback()` (override): super сбрасывает WINDUP→APPROACH; если был WINDUP — `_tween_pose_to(POSE_NEUTRAL, POSE_RESTORE_TIME)`, иначе coiled-поза зависла бы.
- `_perform_strike(_target)` — **AoE-удар в радиусе** `attack_range × STRIKE_RADIUS_FACTOR=1.3` (~1.95м) вокруг скелета. Damage'ит всех в `TARGET_GROUP` в этом радиусе через `Damageable.try_damage(node, attack_damage)`. `_windup_target` используется только для направления self-lunge'а — куда скелет целил, туда и сделает физический выпад. Если locked invalid → forward по текущему look_at (local -Z) через `_apply_velocity_change`. Параметр `_target` из `Enemy._ai_step` игнорируется. `EventBus.skeleton_attacked_camp.emit` дёргается один раз на strike с первой не-defender жертвой (не спамим на каждую damage'нутую). **Почему AoE, а не single-target:** старая single-target логика с slack-валидацией (×1.5 от attack_range) мазала по движущимся целям — pikeman после lunge'а драфтит из slack'а к моменту STRIKE'а, и удар не проходил даже когда pikeman был в физическом melee. AoE решает это: размах конечностью покрывает дугу, кто рядом — получил. Цена: кластер защитников/гномов ближе чем 1.95м к скелету получают damage все вместе.
- `_do_lunge(target)`: считаем горизонтальное направление к цели; **`_apply_velocity_change(dir × lunge_speed, lunge_duration)`**, а не `apply_knockback`. Свой собственный strike через `apply_knockback` дёрнул бы `_on_knockback` хук, который сбил бы только что выставленное состояние.

**Squash & stretch телеграф (как у копейщика):**
- `POSE_NEUTRAL = (1,1,1)`, `POSE_WINDUP_SKEL = (1.2, 0.75, 0.85)` — coiled, скелет приседает и расширяется поперёк (вид сверху: широкий приплюснутый овал), `POSE_STRIKE_SKEL = (0.7, 1.1, 1.45)` — extended, вытягивается копьём вперёд (Z-контраст windup→strike: 0.85 → 1.45 ≈ 1.7×).
- Тайминги: `POSE_WINDUP_TIME=0.12с` (медленный ramp в coiled — у скелета вся фаза 0.32-0.48с, есть запас), `POSE_STRIKE_TIME=0.04с` (snap «выстрел»), `POSE_RESTORE_TIME=0.25с` (chain'ом после strike-snap, к середине COOLDOWN'а скелет в нейтрале).
- `_pose_tween: Tween` хранится для kill'а при следующем переходе (быстрая серия windup'ов не должна перекрываться tween'ами).
- `_tween_pose_to(target, duration)` — обычный переход. `_tween_pose_strike()` — снап + chain restore одной цепочкой.
- Hit-feedback (`_on_self_damaged`) — пропускается в WINDUP'е: scale-punch (target=Vector3.ONE×1.25→ONE) перетёр бы coiled-позу и оставил бы скелета в нейтрале до конца замаха, телеграф терялся бы при попадании.

**Зачем target-lock в WINDUP** (этап 47): `_vision_scan_timer` тикает в `_physics_process` независимо от FSM-состояния, поэтому за 0.4с замаха `_cached_target` мог быть подменён ближайшим гномом из 12-метрового vision. До фикса — strike бил по новой цели на любой дистанции (`Damageable.try_damage` без contact-чека → мгновенный урон по цели за 11м). После фикса — strike бьёт того, на кого замахнулся, или мажет, если он ушёл.

**Жизненный цикл (на уровне FSM базы):** APPROACH → WINDUP (`attack_windup` сек, coiled-pose телеграф + slow creep к цели на `windup_creep_speed=1.5 м/с`) → STRIKE (зовётся `_perform_strike`, наносит урон + self-lunge через `_apply_velocity_change`, extended-pose snap с chain restore) → COOLDOWN (`attack_cooldown` сек, тикает даже в knockback'е, поза восстанавливается до нейтрали) → APPROACH.

**WINDUP-creep (`_apply_windup_creep`):** базовый `Enemy._ai_step` зануляет XZ-velocity в WINDUP-ветке — скелет «замирал» на attack_range от цели, и любое боковое движение цели уводило её из удара. Override после `super._ai_step` ставит velocity = `direction_to(_windup_target) × windup_creep_speed` + `look_at` (re-aim каждый тик). За 0.32-0.48с замаха скелет ползёт ~0.5-0.7м, отслеживая позицию цели. Направление берётся к `_windup_target` (не `_cached_target`) — strike будет бить именно его, creep-направление должно совпадать. MID-divisor multiplier ниже умножает и creep-velocity → net distance на skip'аемых кадрах сохраняется.

**Смерть (`_on_destroyed`):**
- Прячем `MeshInstance3D` (`visible = false`) — труп визуально исчезает.
- Если `_effects_root` есть — `ShatterEffect.spawn(_effects_root, global_position, shatter_color, shatter_fragment_count, shatter_lifetime)`.

**Зависимости:** наследует Enemy. Не знает, что цель именно Tower — `get_active_target()` возвращает `Node3D`. Урон через `Damageable.try_damage` (контракт), не duck-typing.

##### ShatterEffect — `scripts/shatter_effect.gd`

**Тип:** `class_name ShatterEffect extends RefCounted`. Не сцена и не Node — переиспользуемый «эффект-функция», статически вызывается.

**Назначение:** визуальный эффект «рассыпание»: пачка `RigidBody3D`-кубиков с импульсами, удаляются скопом одним общим `SceneTreeTimer` (а не tween-per-fragment). Не привязан к Skeleton — переиспользуем для других «рассыпающихся» сущностей.

**Публичное API:**

```gdscript
static func spawn(
    parent: Node,
    position: Vector3,
    color: Color,
    fragment_count: int = 7,
    lifetime: float = 1.5
) -> void
```

**Логика:**
- Создаётся один общий `StandardMaterial3D` для пачки (все фрагменты делят его).
- `fragment_count` раз: создаётся `RigidBody3D` через `_make_fragment` с боксом `FRAGMENT_SIZE = 0.25`, массой `FRAGMENT_MASS = 0.1`, `collision_layer = 0`, `collision_mask = Layers.TERRAIN`. Никто из игровых тел осколки не видит — они просто падают на пол.
- Каждый фрагмент стартует со случайного оффсета вокруг `position` (горизонталь ±`SPREAD_HORIZONTAL`, вертикаль 0..`SPREAD_VERTICAL`), `linear_velocity` = радиальный импульс наружу × `IMPULSE_RADIAL` + `Vector3.UP × IMPULSE_VERTICAL × randf_range(0.5, 1.0)`, `angular_velocity` — рандом по всем осям в `±ANGULAR_RANGE`.
- В конце: один `parent.get_tree().create_timer(lifetime)`, на `timeout` — цикл `queue_free` по всем фрагментам с защитой `is_instance_valid(f) and f.is_inside_tree()` (на случай выгрузки сцены до таймаута).

**Константы (внутренние, не экспортятся):** `FRAGMENT_SIZE = 0.25`, `FRAGMENT_MASS = 0.1`, `SPREAD_HORIZONTAL = 0.3`, `SPREAD_VERTICAL = 2.0`, `IMPULSE_RADIAL = 4.0`, `IMPULSE_VERTICAL = 5.0`, `ANGULAR_RANGE = 5.0`.

**Зависимости:** `Layers.TERRAIN` для маски. Не зависит от Enemy/Skeleton/любых типов сцены. Принимает parent/position/color/параметры извне.

#### 5.5.3 EnemySpawner — `scripts/enemy_spawner.gd` (Node3D в `main.tscn`)

**Назначение:** низкоуровневый «как» — порождает врагов в заданных паттернах. Не имеет таймеров и фаз кампании (это уезжает в `WaveDirector` 5.5.4). Распределяет крупные спавны по нескольким физкадрам — без фрейм-спайка на старте волны.

**Экспорты:**
- `enemy_scenes: Array[PackedScene]` — типы врагов для legacy `spawn_wave()`.
- `enemy_counts: Array[int]` — параллельный массив для `spawn_wave()`.
- `target_path: NodePath` (`@export_node_path("Node3D")`) — кого ставить в `set_target` базовому Enemy. Skeleton override'ит и `_targets` игнорирует, но для будущих врагов фолбэк остаётся.
- `spawn_root_path: NodePath` (`@export_node_path("Node")`) — куда добавлять врагов как детей. Пустой → фолбэк на `get_tree().current_scene`.
- `zone_root_path: NodePath` (`@export_node_path("Node3D")`) — корень узлов `SpawnZone` (см. §5.5.5). Все прямые дети этого узла собираются в `_zones` на _ready и формируют **позитивный фильтр спавна**: `pick_random_pos()` возвращает точку только внутри объединения прямоугольников этих зон (площадно-взвешенно по `size.x · size.y`). Если корень не задан или пуст — фоллбэк на uniform по `±map_half_extent`.
- `map_half_extent: float = 150.0` — полу-длина карты от центра (карта 300×300). Используется как фоллбэк `pick_random_pos()` при отсутствии зон, и для clamp в `spawn_group/spawn_ring`.
- `spawn_y: float = 1.0` — Y-координата спавна.
- `debug_log: bool = true`.

**Внутренние константы:** `_SPAWNS_PER_FRAME: int = 6` — сколько спавнов в одном физкадре в async-методах.

**Публичный API (вызывается WaveDirector'ом):**
- `pick_random_pos() -> Vector3` — кандидат-точка (Y=0). Если есть `SpawnZone`-ы — выбирает зону площадно-взвешенно (`size.x · size.y`), затем `random_point_in_zone(zone)` внутри неё. Иначе — uniform по `±map_half_extent`. Используется WaveDirector'ом как генератор кандидатов для neutral-спавна (initial/ramp/replenish/[-debug-100); safe-фильтр Camp/POI накладывается caller'ом отдельно.
- `random_point_in_zone(zone) -> Vector3` — uniform-точка внутри **одной конкретной** зоны. Используется для wave-спавна, где зона уже выбрана через budget-логику в WaveDirector.
- `get_zones() -> Array[SpawnZone]` — отдаёт собранный список зон. WaveDirector фильтрует по `waves_left() > 0`.
- `spawn_at(scene, pos) -> Enemy` — синхронный, один спавн в точке. Ставит `set_target(_target)` базовому Enemy. Возвращает инстанс для постобработки (например `WaveDirector` ставит `forced_target`).
- `spawn_uniform(scene, count) -> void` — async. Спавн uniform по квадрату `[−extent, extent]²`, по `_SPAWNS_PER_FRAME` в кадр.
- `spawn_ring(scene, count, center, radius, angle_jitter_deg = 15.0, radius_jitter = 3.0) -> void` — async. Спавн на кольце вокруг `center` с jitter углов и радиуса.
- `spawn_group(scene, count, center, group_radius) -> Array[Enemy]` — синхронный, спавн `count` врагов в круге радиуса `group_radius`. Точки uniform-в-круге через `sqrt(randf())` (без концентрации в центре). Возвращает массив для назначения `forced_target` каждому.
- `kill_all_skeletons() -> int` — `queue_free` для всех в группе `&"skeleton"`. Используется при P-рестарте кампании. Без `shatter` — это «обнуление», не смерть.

**Legacy:** `spawn_wave()` со списками `enemy_scenes`/`enemy_counts` сохранён как debug helper для ручных смешанных волн без режиссёра. Не привязан к input action — только из консоли/теста.

**Зависимости:** только PackedScene и Node3D через NodePath. Спавнер не знает ни типа конкретного врага по имени, ни тип цели; их типы заданы из `main.tscn` на инстансе.

#### 5.5.4 WaveDirector — `scripts/wave_director.gd` (Node в `main.tscn`)

**Назначение:** режиссёр угрозы. POI-driven архитектура (с этапа 42): фоновый прилив скелетов растёт всегда, а POI-осады включаются по событию `EventBus.camp_deployed`. Сам не считает «когда у нас уже 50 скелетов» — это работа фонового таймера. Не считает «когда осаждать» — это работа подписки.

**Фазы:**
- `IDLE` — до первого нажатия P. Ничего не делается.
- `RUNNING` — после P. Тикает фон + (если есть активный POI) тикает осада.

**Старая RAMP/MAINTAIN-фаза удалена** на этапе 42 — простота вместо двух раздельных state-machine'ов. См. этап 42 в §7.2.

**Фоновый прилив (`_tick_background`):**
- На P: `background_initial_count=50` спавнится мгновенно через `_spawn_safe_uniform`, `_background_target = 50.0`.
- Каждый кадр: `_background_target += background_growth_per_minute / 60 × delta`, кламп до `background_cap`. По умолчанию `growth=30` скел/мин wall-clock, `cap=600`.
- Каждые `background_replenish_interval=1.0с`: если живых < target — спавним одного скелета (uniform safe). Темп подкачки 1/сек — плавный «прилив», не залп.
- На P-рестарте target сбрасывается в initial. Стартовый initial-спавн снова идёт.

**POI-осада (`_tick_active_poi`, активна только если есть `_active_poi`/`_active_schedule`):**
- На `EventBus.camp_deployed(anchor)`: ищем Camp по anchor (ближайший в `_camps`), POI по anchor (ближайший в `_pois`, sanity-чек ≤5м). Берём `poi.get_wave_schedule()`. Если null/пустое — POI «мирный», только фон.
- Иначе: `_active_camp / _active_poi / _active_schedule = ...`, `_stage_index=0`, `_stage_elapsed=0`, `_wave_cd = stages[0].wave_interval`.
- Каждый кадр: `_stage_elapsed += delta`, `_wave_cd -= delta`. Если `_wave_cd ≤ 0` — ветка по `stage.has_groups()`: либо `_spawn_groups_wave(stage.groups)` (новая многосоставная модель), либо `_spawn_legacy_poi_wave(stage.skeletons_per_wave)` (single-front legacy). Перевзвод `_wave_cd`.
- Stage advance: если `_stage_elapsed ≥ stage.duration` и есть следующая стадия — `_stage_index += 1`, `_stage_elapsed=0`. **Финальная стадия залипает** (продолжает играть пока лагерь не свернут).
- Sanity: если `_active_camp.has_alive_parts() == false` (палатки разбили в ходе осады) — `_clear_active_poi()`.
- На `EventBus.camp_packed` — `_clear_active_poi()`. Фон продолжает идти, POI-волны останавливаются.

**Боевая группа (CombatGroup) — атомарная единица волны.** Resource в `scripts/combat_group.gd`. Поля:
- `composition: Array[UnitEntry]` — пары (scene, count). Несколько UnitEntry в группе = разные типы юнитов в одном кластере (например 8 обычных + 3 лучника).
- `spawn_zone_index: int = -1` — индекс конкретной SpawnZone в `get_zones()`, или -1 для random fallback. Множество групп с разными индексами = многофронт за один залп.
- `cluster_spread: float = 1.0` — множитель `wave_group_radius` (плотность пачки).

`UnitEntry` (`scripts/unit_entry.gd`) — пара `scene: PackedScene` + `count: int`. Сцена должна быть наследником Enemy (иначе forced_target не назначится).

WaveStage поддерживает обе модели одновременно:
- Новая: `groups: Array[CombatGroup]` — если непуст, используется.
- Legacy: `skeletons_per_wave: int` — fallback когда `groups` пуст. WaveStage без `groups` (старые .tres) продолжают работать через legacy-ветку.

Текущий `wave_schedule_default.tres` уже groups-driven (с этапа после Phase A): три стадии «разведка» (1 группа ×5), «давление» (2 группы 5+3, вторая с spread=1.3), «осада» (3 группы 5+4+3, spread'ы 1.0/1.2/1.5). Все группы с `spawn_zone_index=-1` (random live zone) — на единственной SpawnZone это даёт несколько кластеров одновременно в **разных частях зоны** благодаря safe-фильтру (rejection sampling 30 попыток в `_pick_safe_point_in_zone`). Когда дизайнер добавит больше зон вокруг POI — те же группы дадут реальный многофронт с разных сторон без правки расписания.

**Spawn новой модели (`_spawn_groups_wave`):** для каждой CombatGroup → `_spawn_single_group`: резолв SpawnZone через `_resolve_spawn_zone(index)` (запрошенная zone если жива, иначе random fallback), origin = random point в zone, target_part = nearest_part_to(origin), затем итерация по composition с `spawn_group(entry.scene, entry.count, origin, radius)` + `_assign_forced_targets`. Один `consume_wave()` на zone-резолв (не на UnitEntry).

**Spawn legacy-модели (`_spawn_legacy_poi_wave`):** одна случайная zone с `waves_left() > 0`, группа `count` скелетов в её прямоугольнике, forced_target = nearest_part_to(origin), consume_wave. Сохраняется для обратной совместимости.

**Safe-фильтр (`_safe_score`):** возвращает «избыток» (distance − safe_radius) до ближайшей запретной зоны: живой Camp (radius=`wave_safe_radius=32м`) или POI (radius читается с `poi.safe_radius` — каждый POI имеет свой через `QuestActor.safe_radius`; fallback `poi_safe_radius_fallback=32м`). >=0 → принимаем, <0 → запоминаем как фоллбэк. Применяется и к фоновому спавну (`_pick_safe_pos`), и к POI-волнам (`_pick_safe_point_in_zone`) — последнее критично когда SpawnZone перекрывает лагерь (например, одна большая зона размером с карту): без фильтра волна могла бы заспавниться вплотную к палаткам. Если за `wave_position_attempts` (30) попыток safe-точка не найдена — возвращается «лучшая» (с максимальным excess'ом), как страховка.

**Рестарт кампании (`cheat_start_campaign`):** в фазе RUNNING повторный вызов → `kill_all_skeletons` + `Camp.reset_population()` для каждого camp + `_clear_active_poi()` + новый initial-спавн фона. Если игрок стоит на POI и хочет возобновить осаду — сворачивает и разворачивает лагерь (camp_packed → camp_deployed эмитится снова, осада запустится с stage 0). Раньше висело на P; с 2026-05-08 — кнопка во вкладке «Читы» журнала.

**Force-wave (`cheat_force_wave`):** немедленный спавн волны активной стадии (groups или legacy, по `stage.has_groups()`) + перевзвод `_wave_cd`. Без активного POI — игнор с предупреждением «волне некуда идти». Кнопка во вкладке «Читы».

**Force-multifront-wave (`cheat_force_multifront_wave`):** демо многофронта. Автоматически собирает `Array[CombatGroup]` — по одной группе с 5 скелетов на каждую живую SpawnZone — и спавнит через тот же `_spawn_groups_wave` pipeline. Дизайнер видит как ведут себя defenders при атаке со всех сторон, без необходимости настраивать .tres. Кнопка во вкладке «Читы».

**Debug spawn (`cheat_spawn_100`):** `_spawn_safe_uniform(100)` поверх фона. Не трогает таргет/таймеры — единоразовый дамп. Раньше `[`, теперь кнопка.

**Stress test (`cheat_stress_2000`):** fire-and-forget `EnemySpawner.spawn_uniform(skeleton_scene, 2000)`. Игнорирует safe-зоны и SpawnZone-границы; для замера перфоманса (PerfHud F3). Раньше `]`, теперь кнопка.

**Safe-zone monitor:** раз в 1с считает скелетов в `wave_safe_radius` от `current_center()` каждого лагеря. Лог по фронту с указанием `target/cap` фона.

**Public API:**
- `set_waves_in_all_zones(n) / add_waves_to_all_zones(n)` — рантайм-управление budget'ом SpawnZone-ов (для будущих эвентов «Король Ночи»).
- `is_safe_pos(pos) -> bool` — внешний фасад над `_safe_score >= 0`. Сейчас потребителей нет; оставлен для будущего (ResourceZone раньше использовал для WOOD-фильтра, потом фильтр убрали).

**Экспорты (в инспекторе):**
- Refs: `spawner_path`, `camp_paths: Array[NodePath]`, `poi_root_path: NodePath`, `skeleton_scene: PackedScene`.
- Background tide: `background_initial_count=50`, `background_growth_per_minute=30.0`, `background_cap=600`, `background_replenish_interval=1.0`.
- POI siege: `wave_group_radius=4.0`, `wave_safe_radius=32.0`, `poi_safe_radius_fallback=32.0`, `wave_position_attempts=30`.

**Зависимости:** держит ссылку на `EnemySpawner`, `Array[Camp]`, `Array[Node3D]` POI. Подписан на `EventBus.camp_deployed/camp_packed`. Использует `Camp.current_center / has_alive_parts / nearest_part_to / reset_population` и `EnemySpawner.get_zones / random_point_in_zone / pick_random_pos`. POI читает duck-typing через `has_method("get_wave_schedule")` и свойство `safe_radius`.

#### 5.5.5 SpawnZone — `scenes/spawn_zone.tscn`, `scripts/spawn_zone.gd` (`@tool`)

**Тип корня:** `Node3D` с `class_name SpawnZone`.

**Назначение:** прямоугольник `size` (X×Z, в метрах) с центром в собственной `global_position` и поворотом из transform узла. Два аспекта:

1. **Фоновый прилив.** `EnemySpawner.pick_random_pos` выбирает рандомную точку в объединении всех SpawnZone-ов площадно-взвешенно (size.x·size.y). Wave-budget здесь не учитывается — даже исчерпанная зона остаётся фоновой «локацией».

2. **POI-волны.** `WaveDirector._spawn_poi_wave` ищет SpawnZone-ы с `waves_left() > 0`, выбирает одну (uniform random) и фейерит группу штук внутри её прямоугольника. **Размер группы теперь читается из активной `WaveStage` POI**, не из самой зоны (на этапе 42 параметр `skeletons_per_wave` стал deprecated). После выстрела `consume_wave()` декрементит `_waves_left`; при 0 зона выходит из POI-пула, но в фоновом потоке остаётся.

**Экспорты:**
- `size: Vector2 = Vector2(60, 60)` — полные размеры по локальным X (size.x) и Z (size.y). Сеттер `@tool` мгновенно масштабирует визуальный индикатор (плоский box под собой) — в редакторе видно размер сразу. Поворот вокруг Y берётся из transform узла; сэмплирование (`random_point_in_zone`) учитывает basis.
- Группа **Waves**:
  - `target_poi: NodePath` — метаданные привязки к POI (для дизайна и потенциальных будущих политик дирижёра вроде «бить по POI с ближайшим Tower»). В текущей реализации не запрещает другим POI «получить» волну отсюда — только справочно.
  - `wave_count: int = 5` — стартовый budget волн. На `_ready` копируется в `_waves_left`.
  - `skeletons_per_wave: int = 10` — **DEPRECATED** (этап 42). Размер пачки теперь приходит из `WaveStage.skeletons_per_wave` POI; поле оставлено только чтобы main.tscn с override-нутым значением не валился на загрузке.

**Public API:**
- `area() -> float` — площадь (size.x·size.y). Используется EnemySpawner'ом для взвешивания выбора зоны.
- `waves_left() -> int` — остаток budget'а.
- `consume_wave() -> bool` — декремент на 1; false если зона уже исчерпана.
- `add_waves(n: int) -> void` — накопительно прибавить к `_waves_left`.
- `set_waves(n: int) -> void` — жёсткая перезапись (для Король Ночи: сразу всем по 100 волн).

**Сборка зон в дереве:** `EnemySpawner` собирает зоны один раз в `_ready` из прямых детей `zone_root_path`. Рантайм-добавление новых SpawnZone-нод после старта сцены не подхватывается; пополнение `_waves_left` существующих зон — работает.

**Визуал:** плоский BoxMesh (1×0.04×1) на y=0.05, масштабируемый сеттером `size` до `size.x×0.04×size.y`, полупрозрачный красный с эмишеном. Видим **только в редакторе** — `_refresh_visual` ставит `mesh.visible = Engine.is_editor_hint()`, поэтому в рантайме (Play и билд) зоны игроку не видны.

### 5.6 Ground — inline в `main.tscn`

**Тип корня:** `StaticBody3D`.

**Назначение:** пол 400×400м с travel-noise (этап 44, было — с grid-сеткой 2×2м, удалена по геймдизайну).

**Шейдер `resources/grid.gdshader`** (имя историческое):
- В fragment'е сэмпл `noise_texture` (см. `resources/ground_noise.tres` — `NoiseTexture2D` 512×512 с FastNoiseLite type=Perlin, freq=0.018, octaves=4, **seamless=true**) по `world_pos.xz × noise_scale`. Результат смешивается между `grass_color_dark` и `grass_color_light` через smoothstep, потом mix'ится с `base_color` по `noise_strength`.
- Texture-based вместо in-shader fbm — на координатах ±200 (карта 400×400) float-precision in-shader hash21+fbm плыл и давал видимые квадраты ~50м. NoiseTexture2D + repeat_enable + seamless даёт чистый bake без артефактов.
- Cost: один texture-sample на пиксель пола. На 400×400м BoxMesh — копейки.
- Параметры в Material_ground (`main.tscn`): `base_color`, `noise_strength=0.35`, `noise_scale=0.02` (тайл ~50м), `grass_color_dark/light`. Откат: `noise_strength=0`.

**Состав:**
- `GroundCollision` — `CollisionShape3D` с `BoxShape3D` 400×1×400.
- `GroundMesh` — `MeshInstance3D` с тем же боксом и `ShaderMaterial`, использующим `resources/grid.gdshader`.

### 5.6.1 GrassField — `scenes/grass_field.tscn`, `scripts/grass_field.gd`

**Тип корня:** `Node3D` с `class_name GrassField`.

**Назначение:** chunked 3D-mesh трава по всей карте (этап 44). На `_ready` спавнит `chunk_count_xz × chunk_count_xz` инстансов `GrassChunk` (`MultiMeshInstance3D`-обёртка), каждый со своим `MultiMesh`, заполненным random-blade'ами в его прямоугольнике.

**Зачем чанки:** Godot культит MultiMesh по общему AABB — один большой MultiMesh на 400×400 пересекал бы frustum из любой точки и vertex-шейдер гонял бы все blade'ы каждый кадр. Сетка 16×16 чанков по 25м даёт 256 отдельных AABB; frustum culling оставляет только видимые. На каждом чанке ещё `visibility_range_end=120м` — дальние пропадают по дистанции до камеры (раньше было 60м, но при зум-out видимая дистанция камеры ~150м, чанки за 60м пропадали посередине экрана).

**Cost-estimate (дефолты `density=4`, `chunk_count=16`, `visibility=120м`):**
- 256 чанков × 25м×25м×4 = 2500 blade per chunk = ~640k blade суммарно по карте.
- В кадре видно ~12-20 чанков = ~30k-50k blade × 7 трисов = ~210k-350k трисов на vertex stage.
- Шейдер дешёвый: один texture-sample + sin + 2 add'a в vertex'е, fragment без alpha и без discard.
- Один draw call на чанк (MultiMesh batched через GPU instancing).
- Память: 256 уникальных MultiMesh-resource'ов × 2500 × 64 байта Transform3D ≈ 40MB.

**Ключевой баг (этап 44, фикс `9f03444`):** MultiMesh в `grass_chunk.tscn` — это `sub_resource`, и `chunk_scene.instantiate()` копирует **NodePath на ресурс**, не сам ресурс. Без `chunk.multimesh = chunk.multimesh.duplicate()` все 256 чанков пишут в один и тот же MultiMesh-буфер, `instance_count=X` и `set_instance_transform(...)` перезаписывают друг друга. На скрине геймдизайнера это спамило 429 ошибок в дебаггере и визуально показывало только один чанк (последний). Fix — duplicate в `_spawn_one_chunk` сразу после instantiate.

**Y-position (этап 44):** `GrassField` в `main.tscn` имеет `transform.origin.y = -0.28`. Причина: Ground transform в main.tscn — `position.y=-0.5`, `scale.y=0.439`, BoxMesh size.y=1 → top of ground = -0.5 + 0.5×0.439 = -0.28. Корень blade'а в OBJ на y=0, при scale=0.15 в transform — низ blade'а должен совпадать с верхом пола. GrassField с y=0 ставил blade'ы на 0.28м над полом (парили).

**Шейдер `resources/grass.gdshader`:**
- `render_mode cull_disabled` — травинку видно с обеих сторон.
- Vertex: `bend = (sin(TIME×sway_time_scale + dot(instance.xz, vec2(0.07, 0.13))) × 0.5 + (noise(...) − 0.5) × 0.6) × sway × pow(height_norm, sway_pow)`. Двухкомпонентное смещение: главная sin-волна с фазой по миру (бежит видимая «волна» по полю) + локальная вариация из noise (травинки качаются не perfect-sin). `height_norm = VERTEX.y × 0.25` (blade.obj высотой 4 → нормируется в [0,1]). `pow(_, sway_pow=2)` — корень неподвижен, верхушка качается.
- Fragment: `mix(base_color, tip_color, smoothstep(0, color_grad_height, height_norm))`. Без alpha, без discard.
- Использует **тот же** `ground_noise.tres` что и пол — один noise-texture на проект.

**Mesh `resources/grass_blade.obj`:** 9 vertices, 7 трисов. Базовый размер 1м×4м, узкий к верху. В MultiMesh `transform.basis` масштабируется на `blade_scale × randf_range(1−variance, 1+variance)` — дефолт даёт blade ~0.1м×0.4м.

**Coverage target (этап 45):** в `main.tscn` GrassField имеет `coverage_target_path = NodePath("../Ground/GroundMesh")`. На `_ready` через `_get_coverage_rect()` берётся world AABB указанного `VisualInstance3D` (`mesh.global_transform * mesh.get_aabb()`), и спавн чанков идёт в его XZ-проекцию. Это даёт единый источник правды: дизайнер двигает / масштабирует Ground — grass подстраивается без правки `world_size`.

Без coverage_target — fallback на квадрат `world_size × world_size` с центром в (0,0). Чанки могут быть **не квадратными**: `chunk_size_x = rect.size.x / chunk_count_xz`, `chunk_size_z = rect.size.y / chunk_count_xz`. Раньше Ground в `main.tscn` имел `scale.z = 0.439` (несимметричный squash) — реальный ground X∈±200, Z∈±88, а GrassField со `world_size=400` спавнил blade'ы на 400×400 → ~56% травы (640k → 360k blade) висели за границей пола. После фикса blade'ы сидят строго внутри Ground'а.

**Параметры (`scenes/grass_field.tscn`, инспектор):**
- `coverage_target_path: NodePath` — опционально. Указывается на `MeshInstance3D` (обычно `GroundMesh`); пустой → fallback на `world_size`.
- `world_size: float = 400.0` — fallback-сторона мира когда coverage пуст.
- `chunk_count_xz: int = 16` — сетка чанков. 16×16 при world_size=400 → 25м чанк (мельче culling-step, плотнее покрытие видимой зоны).
- `density: float = 4.0` — травинок на квадратный метр.
- `visibility_distance: float = 120.0` — дистанция культинга по `visibility_range_end` (покрывает зум-out камеры на 100-150м).
- `blade_scale: float = 0.15`, `blade_scale_variance: float = 0.2` — базовый размер blade'а и разброс.
- `random_seed: int = -1` — `-1 = randomize`, иначе фиксированный seed для воспроизводимого распределения.

**Параметры ветра (`grass_material.tres`, инспектор):**
- `sway: float = 0.6` — амплитуда смещения как доля высоты blade'а. Макс смещение по миру = blade.height × sway = 0.6м × 0.6 ≈ 0.36м для дефолтного blade'а. Итерации тюнинга: 0.15 → 0.25 → 0.6.
- `sway_pow: float = 1.5` — степень затухания к корню. 2 — корень неподвижен (статичная база), 1 — линейное затухание (низ тоже двигается). 1.5 — компромисс «активное колыхание».
- `sway_time_scale: float = 2.5` — частота. ~раз в 2.5с одно полное качание.
- `sway_dir: Vector2 = (1, 0.3)` — направление ветра по XZ.
- `sway_noise_scale: float = 0.08` — масштаб noise-вариации между травинками. Меньше = крупнее единые «волны», больше = каждая травинка качается по-своему.

**Откат:** `density = 0` в инспекторе GrassField (на _ready ранний return — чанки не спавнятся).

### 5.7 Camp — `scenes/camp.tscn`, `scripts/camp.gd`

**Тип корня:** `Node3D` с `class_name Camp`.

**Назначение:** модуль «лагеря» — несколько палаток (`RigidBody3D` с `freeze=true`, см. §5.7.bis) с гномами-жителями. Работает в **двух режимах**, переключается через флаг `start_deployed`:

1. **Mobile (caravan mode, `start_deployed = false`):** в `CARAVAN_FOLLOWING` палатки следуют за башней цепочкой. По зажатию `R` (при неподвижной башне) лагерь разворачивается вокруг текущей позиции башни в кольцо. По повторному зажатию — сворачивается обратно. **Halt-режим (Q):** `caravan_halt_toggle` (Q) переключает флаг `_caravan_halted` — палатки замирают на текущих позициях, башня продолжает кататься по WASD независимо. Гномы IN_TENT едут вместе с палатками (копируют их позицию) → стоят. Defender'ы FOLLOWING_CARAVAN тоже останавливаются у своих slot'ов. R-deploy в halted блокируется. Q ещё раз → караван догоняет башню. Скорость догона capped на `caravan_max_speed = 10.0` м/с (чуть выше Tower.move_speed=8) — exp_decay со скейлом, но шаг ограничен `max_speed × delta`, чтобы при большом разрыве (после halt-resume) не было пропорционального дистанции «рывка». В обычной езде cap не активен (exp-step ≪ max-step).

2. **Static (settlement mode, `start_deployed = true`):** Camp на `_ready` сразу стартует в `DEPLOYED` со своей собственной `global_position` как anchor'ом. Палатки расставлены в кольце вокруг неё, гномы выходят и собирают. R-toggle игнорируется — поселение не сворачивается. Используется для статических лагерей-поселений на POI карты (без следования за башней). `target_path` для такого Camp оставляют пустым.

В развёрнутом виде (любой режим) лагерь спавнит **гномов** (см. §5.8) — те бродят, ищут `ResourcePile` (см. §5.9) и носят ресурсы к anchor'у.

**Дочерние узлы:**
- `CenterMountSlot` (`Node3D` со скриптом `mount_slot.gd`) — центральный слот для модулей в развёрнутом виде. Стартует `enabled=false` (вне DEPLOYED центра нет).
- Палатки **не лежат в camp.tscn инлайном** — спавнятся динамически из `tent_scene` × `tent_count` в `_spawn_tents()` (см. ниже). Это та же декомпозиция «сцена + скрипт = пакет», что и у Item, ResourcePile, Skeleton: палатка теперь самостоятельная сущность ([scenes/tent.tscn](scenes/tent.tscn) + [scripts/camp_part.gd](scripts/camp_part.gd)), а Camp — её композитор.

**Экспорты:**
- `target_path: NodePath` (`@export_node_path("Node3D")`) — за кем следует караван. Обычно Tower.
- Группа **Caravan composition:**
  - `tent_scene: PackedScene` — сцена палатки. По дефолту в `camp.tscn` стоит `tent.tscn`, но можно подменить любой `RigidBody3D` со скриптом `CampPart` (StaticBody больше не сработает — apply_push требует RB API).
  - `tent_count: int = 4` — сколько палаток в караване. Меняется в инспекторе. Layout цепочки автоматически распределяется через `part_gap`; на развёртку угол кольца = `TAU / tent_count` — любое разумное число работает.
  - `start_deployed: bool = false` — static-режим: на `_ready` минуем `CARAVAN_FOLLOWING`, сразу разворачиваемся вокруг собственной `global_position`. R-toggle игнорируется. Используется для статических поселений на POI карты.
- `follow_speed: float = 4.0` — **decay-коэффициент** (log-rate) экспоненциального следования палаток. **Не зависит от dt** (см. `_exp_decay`).
- `part_gap: float = 2.5` — целевая дистанция между соседними палатками.
- `follow_max_distance: float = 30.0` — «зона видимости».
- `deploy_duration: float = 3.0` — секунды зажатой `R` при неподвижной башне для развёртки.
- `pack_duration: float = 4.0` — секунды зажатой `R` в развёрнутом состоянии для свёртки.
- `pack_timeout: float = 12.0` — таймаут принудительной свёртки если кто-то из гномов застрял (см. ниже).
- `deploy_radius: float = 8.0` — радиус кольца палаток вокруг anchor (×2 от исходного 4 в коммите про геометрию лагеря).
- `stationary_threshold: float = 0.01` — порог смещения **позиции** цели за кадр, ниже которого считаем её неподвижной (раньше читалась `velocity` у CharacterBody3D — теперь `_tower` хранится как `Node3D`, и неподвижность определяется через эпсилон-чек delta-position).
- Группа **POI deploy gate** (этап 42):
  - `require_poi: bool = true` — если true, deploy возможен только когда башня в радиусе [QuestActor.safe_radius] хотя бы одной POI-зоны (группа `poi_zone`). Hold R вне POI игнорируется. Anchor лагеря защёлкивается на POI.global_position (а не на tower) — палатки кольцом строятся симметрично вокруг костра. false — старое поведение «deploy где угодно». Для отладки.
- Группа **Gnomes:**
  - `gnome_scene: PackedScene` — сцена обычного гнома-собирателя.
  - `defender_scene: PackedScene` — сцена защитника-лучника (DefenderGnome). Camp читает `CampPart.defenders_per_tent` и `gnomes_per_tent`, спавнит `defenders_per_tent` защитников и `(gnomes_per_tent − defenders_per_tent)` собирателей на каждую палатку. Дефолт 7 жителей: 3 защитника + 4 собирателя.
- `debug_log: bool = true`.

**Публичный API (используется WaveDirector'ом и HUD'ом):**
- `current_center() -> Vector3` — реальный центр лагеря: среднее живых палаток (в caravan-mode узел Camp статичен, двигаются только дочерние палатки). Fallback: позиция Tower → собственная позиция узла. WaveDirector использует для расчёта safe-зоны.
- `nearest_part_to(pos) -> Node3D` — ближайшая живая палатка. Для назначения `forced_target` волне. Оторванные (torn_off) пропускаются — волне не назначаем летающую цель.
- `has_alive_parts() -> bool` — есть ли хоть одна живая палатка. Лагерь-без-палаток не валидная цель волны.
- `reset_population() -> void` — `queue_free` всех живых гномов и `_spawn_gnomes` снова. Палатки не восстанавливаются. Используется при P-рестарте кампании WaveDirector'ом. После reset в `DEPLOYED`-режиме новые гномы сразу `enter_deployed()` — выходят бродить.
- `gatherer_count() / defender_count() / tent_count_alive() -> int` — счётчики для GameplayHud. Defender'ы фильтруются через `is DefenderGnome`.

**Сигналы:**
- `deployed(anchor: Vector3)` — на переходе `CARAVAN_FOLLOWING → DEPLOYED`. Re-emit'ится в `EventBus.camp_deployed`.
- `packed` — на переходе `PACKING_RETURNING → CARAVAN_FOLLOWING` (т.е. **после** прихода всех гномов домой). Re-emit'ится в `EventBus.camp_packed`.

**Состояния (внутреннее enum):**

```gdscript
enum State { CARAVAN_FOLLOWING, DEPLOYED, PACKING_RETURNING }
```

- `CARAVAN_FOLLOWING` — палатки тянутся «змейкой» за башней, гномы IN_TENT.
- `DEPLOYED` — палатки в кольце вокруг `_deploy_anchor`, гномы бродят и собирают ресурсы.
- `PACKING_RETURNING` — пользователь начал свёртку: гномы получили `request_return()`, идут в палатки. Сами палатки **пока не двигаются** — продолжают `_update_deployed` на местах кольца. Когда `_all_gnomes_home()` → `_finalize_pack()` → переход в `CARAVAN_FOLLOWING` и сигнал `packed`. Промежуточные состояния `DEPLOYING` / `PACKING` (из старой версии) удалены.

Все три состояния имеют одинаковую коллизионную семантику (палатки на `CampObstacle`, башня проходит, скелеты упираются) — переключения слоя в рантайме нет.

**Поля:**
- `_tower: Node3D` (не `CharacterBody3D`!) — тип ослаблен, чтобы не зависеть от Tower по конкретному классу.
- `_state: State`, `_parts: Array[Node3D]` (палатки в любом физтипе — сейчас RigidBody3D), `_deploy_anchor: Vector3`, `_deployed_targets: Array[Vector3]`.
- `_deploy_hold: float`, `_pack_hold: float` — раздельные таймеры удержания `R`. Раньше был один `_hold_progress` на оба перехода.
- `_last_target_pos: Vector3 = Vector3.INF` — позиция башни на прошлом кадре.
- `_gnomes: Array[Gnome]` — гномы лагеря (создаются в `_spawn_gnomes`).
- `deploy_anchor: Vector3` — публичное property (геттер возвращает `_deploy_anchor`). Гномы читают, чтобы знать, куда нести ресурс.

**`_ready`:** резолвит `_tower` через `target_path`; вызывает `_spawn_tents()` затем `_spawn_gnomes()`; подключает re-emit на EventBus и подписку на `tower_destroyed`.

**`_spawn_tents`:** инстанцирует `tent_scene` × `tent_count` раз. Стартовая XZ — цепочка **позади башни** (`leader = _tower.global_position` если есть, иначе `global_position` Camp): `tent[i].x = leader.x − (i+1) × part_gap`, `z = leader.z`. Y берётся из самой `tent.tscn` (там 0.75 — низ меша на полу). Раньше `tent[0]` ставился в Camp local (0,0,0) и подтягивался к башне через exp_decay — на разнесённых Camp/Tower палатки на первом кадре сидели в центре и потом «уезжали»; сейчас сразу строится конечная цепочка. Каждая палатка — самостоятельный `CampPart`-инстанс; Camp подписывается на её `destroyed`, чтобы синхронно вычистить и `_parts`, и `_deployed_targets` по индексу. Без сцены (`tent_scene = null`) или при `tent_count <= 0` — `push_warning` и пустой караван.

**`_spawn_gnomes`:** для каждой палатки в `_parts` читает её собственный `gnomes_per_tent` (поле `CampPart`, дефолт 7) и инстанцирует `gnome_scene` соответствующее количество раз. Кастует к `Gnome`, кладёт ребёнком Camp, ставит в позицию палатки и вызывает `gnome.setup(self, tent)`. Палатка-владелец передаётся как `home_tent` — гном привязан именно к ней (хранит в `_home_tent`, идёт туда при `request_return`, а в `IN_TENT` приклеен к её `global_position`).

**Логика follow (`_update_caravan_follow`):**
- Distance-gate: если `parts[0].distance_to(tower) > follow_max_distance` — ведущая стоит, остальные подтягиваются к своим лидерам.
- Цепочка: `target = leader_pos − dir × part_gap`. Y цели — через `_ground_y_at(part, target_pos)`: raycast по `Layers.TERRAIN`. Палатки следуют рельефу.
- Сглаживание — **`_exp_decay`** (статический helper): `target + (current - target) * exp(-decay * delta)`. Покадрово стабильное, в отличие от прошлого `lerp(a, b, follow_speed × delta)` (frame-зависимый).

**Логика DEPLOYED (`_update_deployed`):** каждая палатка `_exp_decay` к своей `_deployed_targets[i]` (точка кольца).

**Финальная модель каравана с физикой палаток (2026-05-04 + этап 45).** Tent — `RigidBody3D` (`mass=8`, `linear_damp=2`, `angular_damp=2.5` в покое) с `freeze=true` в норме. Camp двигает её через `global_position`, пока заморожен. HP палатки = 120 (под 2 хлопка от Slam, см. ниже).

**Палатка как щит для гномов (этап 45).** Пока палатка цела (hp > 0), гномы IN_TENT неуязвимы — `Gnome.take_damage` ранний return при `_state == IN_TENT`. Это блокирует и Slam-AOE по `Damageable`, и удары скелетов по гномам внутри. До этого (на старой модели) Slam через Damageable.try_damage пробивал по всем зарегистрированным в радиусе и выкашивал IN_TENT гномов одним хлопком. Сейчас гномов «выпускает наружу» только сама палатка через `_eject_in_tent_gnomes`. Дизайн: «целая палатка защищает жителей; разрушенная — их освобождает».

**Источники impulse'а на палатку** (Slam, Flick, бросок рукой) идут через единый путь `_become_torn_off(impact, apply_impulse)`:
1. `_torn_off = true` (обратимо: на следующий `_on_hand_grabbed` флаг сбрасывается).
2. `freeze=false`, `sleeping=false`, `linear_damp=torn_off_linear_damp(0.5)`, `angular_damp=torn_off_angular_damp(0.3)` — низкое затухание, чтобы обломок красиво кубарем летел и крутился.
3. `apply_central_impulse(impact × push_velocity_factor × mass)` если `apply_impulse=true`. Slam/Flick передают Δv → импульс нужен. Hand-throw уже задал `linear_velocity` в `Hand._release` → `apply_impulse=false`.
4. `apply_torque_impulse(random_unit × |impact| × torque_factor × mass)` — кувыркание.
5. **Гномов сам tear-off НЕ вылетает** (изменение этапа 45 vs 2026-05-04). Они вылетают порциями на ударах о землю/тело.

**Pinata-механика (этап 45).** После tear-off палатка работает как пиньята. На каждом `body_entered` со speed ≥ `contact_damage_min_speed` (4 m/s):
- Контактный damage по hp палатки: `(speed - min) × contact_damage_factor (4)`.
- Eject `gnomes_per_impact` гномов (default 1) из тех, кто ещё IN_TENT. С cooldown'ом `impact_eject_cooldown=0.15с` против дублирования при кучных контактах в одном кадре.
- Гномы выходят **без damage** — палатка их защитила, выход в стрессе, но живыми.

При hp ≤ 0 → `_destroy()`: shatter-фрагменты, queue_free. Перед shatter'ом `_eject_in_tent_gnomes(-1)` выпускает всех ещё-сидящих внутри гномов, тоже без damage. Дизайн: «удар о землю → партия гномов наружу; если разнесло палатку до того, как все вышли — оставшиеся всё равно живы и на свободе».

`take_damage` для `_torn_off` пропускает гейт `_vulnerable` (PACKING_RETURNING-бронь не действует на обломки).

**Возврат целой палатки в строй (этап 45).** `_on_hand_grabbed` сбрасывает **оба** флага: `_outside_caravan = false` И `_torn_off = false`. Если палатка не разрушилась (HP > 0) и игрок её подобрал — она снова normal tent. Soft-release → `notify_part_settled` → встанет в строй (если в зоне) или mark_outside_caravan (если вне). Hard-throw → `_become_torn_off` снова → летит как пиньята. Гномы, которые уже вылетели за время полёта, остаются follower'ами в FOLLOWING_CARAVAN (они с `_home_tent=null`); те, что ещё внутри — едут вместе с восстановленной палаткой.

**Тихий release** — снэп-зависит от `Camp._state`:
- В `not _torn_off` ветке палатки: `_snap_to_ground()` (raycast по TERRAIN, Y = `hit.y + floor_offset_y()`), `freeze=true`, `linear_velocity = angular_velocity = 0`, затем `Camp.notify_part_settled(self)`.
- `notify_part_settled` теперь ветвится по `Camp._state`:
  - **CARAVAN_FOLLOWING** — zone-snap. В зоне (`distance ≤ placement_zone_radius=15м` от tower) → `_reorder_parts_by_position()`. Вне зоны → `mark_outside_caravan()`.
  - **DEPLOYED / PACKING_RETURNING** (этап 45) — **free-placement**: всегда `mark_outside_caravan`, никакого snap'а к ring-слоту. Игрок может перестраивать лагерь под местность. На `_finalize_pack` все палатки восстанавливаются (см. ниже).
- В `_torn_off` ветке (брошенная или soft-released после броска) palatка остаётся в физике, упадёт под гравитацией.

**Soft-release threshold** (`HandPhysical.soft_release_velocity_threshold=8 m/s`): в `Hand._release` если held в `Layers.HAND_SOFT_RELEASE_GROUP` и `smoothed_velocity < threshold` — `linear_velocity` обнуляется. Стенка между «поставил» и «бросил».

**Виртуальная цепочка** (`Camp._update_caravan_follow`). Камп строит `active_parts` из `_parts`, исключая `not is_in_caravan()` (= torn_off ИЛИ outside_caravan) и `is_in_hand()`. Идёт цепочкой: `active[0]` за башней, `active[i]` за `active[i-1]`. Если выбили `parts[0]`, `parts[1]` сжимает строй и сама становится ведущей.

**Цепочка с гномами-followers (этап 45).** За палатками в каравне идут не только палатки, но и **бездомные гномы** в общей цепочке. Camp ведёт `_caravan_followers: Array[Gnome]` (порядок регистрации = слот). API:
- `register_caravan_follower(g)` — Gnome.enter_following_caravan вызывает на себя.
- `unregister_caravan_follower(g)` — Gnome.take_damage при death + Gnome._claim_tent_as_home при заселении в вакантную палатку.
- `get_chain_target_for_follower(g) → Vector3` — для Gnome._tick_following_caravan. Звенья: tower → active tents → followers до slot−1. Target = `leader_pos − dir × gnome_chain_gap + perp × side_offset + dir × forward_offset`. Per-гном `_caravan_chain_offset: Vector2` (рандомный, стабильный после `enter_following_caravan`) разворачивается через `gnome_chain_jitter (0.7)` и `gnome_chain_gap_variance (0.35)`. Цепочка не выглядит ниткой — гномы рассыпаются полосой шириной до 1.4м с раздёрганным gap. `gnome_chain_gap=1.2` (плотнее tent's `part_gap=2.5`).
- В `DEPLOYED` цепочка не имеет смысла (палатки в кольце) — `get_chain_target_for_follower` fallback'ает на `_tower.global_position`, гномы идут к башне.

**Vacancy claim (этап 45).** Бездомные гномы (FOLLOWING_CARAVAN) периодически (раз в ~1-1.5с с jitter'ом) спрашивают `Camp.find_tent_with_vacancy_for(self)`. Если в палатке есть свободное место (`get_tent_occupancy(tent) < tent.gnomes_per_tent`) — гном «заселяется»: `_home_tent = tent`, `state = RETURNING_TO_TENT`, бежит sprint-скоростью, на прибытии `_enter_in_tent`. На `PACKING_RETURNING` Camp возвращает `null` — иначе свёртка ждала бы только-что-переведённого в FOLLOWING_CARAVAN гнома до его прибытия в палатку.

**Свободное размещение в DEPLOYED + восстановление на pack (этап 45).** В `DEPLOYED` игрок может поднять палатку и опустить в любом месте лагеря — она остаётся там (mark_outside_caravan, `_update_deployed` пропускает). На `_finalize_pack` Camp вызывает `restore_to_caravan()` на каждой `CampPart` (сбрасывает `_outside_caravan`, не трогает `_torn_off`) и затем `_reorder_parts_by_position()` — палатки сортируются по расстоянию до Tower, ближайшая становится первой в строю. `_update_caravan_follow` плавно вытягивает их в линию через exp_decay.

**Слой палатки** остаётся `CAMP_OBSTACLE` в любом состоянии. `collision_mask` Tent = TERRAIN+ENEMIES (17). Гномы IN_TENT — `Grabbable` контракт, `set_highlighted(value)` через per-instance копию `StandardMaterial3D`.

**Логика свёртки (двухфазная, этап 47):**
1. `_pack_hold ≥ pack_duration` → `_start_pack()`:
   - `_state = PACKING_RETURNING`, `_pack_elapsed = 0`.
   - `g.request_return()` для каждого гнома. Поведение зависит от роли:
     - **Gatherer с живой `_home_tent`** → `_state = RETURNING_TO_TENT`, sprint к палатке (`caravan_sprint_speed=9 м/с`), на arrival `_enter_in_tent` → IN_TENT (visible=false, неуязвим). Палатка = безопасное место.
     - **Gatherer без палатки (бездомный)** → `enter_following_caravan` (некуда возвращаться).
     - **Defender** (override `DefenderGnome.request_return`) → сразу `enter_following_caravan`. Палатка для защитника — не безопасное место, он остаётся в строю и стреляет на ходу.
2. Каждый кадр при `PACKING_RETURNING`: проверка `_all_gnomes_home()` = «все гномы IN_TENT or FOLLOWING_CARAVAN». Гном в `RETURNING_TO_TENT` НЕ считается дома — Camp ждёт его прихода или таймаута.
3. `_finalize_pack()`: `_state = CARAVAN_FOLLOWING`. `restore_to_caravan` на каждой палатке. `_reorder_parts_by_position()`. Эмит `packed`. `_update_caravan_follow` далее ведёт строй.
4. **Таймаут** (`pack_timeout=12с`): если `_all_gnomes_home()` всё-таки не true (gatherer застрял sprint'ом через всё поле под огнём) — форсированный `_finalize_pack()` с логом. Sprint=9м/с покрывает диаметр лагеря (~16м) за ~1.8с, поэтому таймаут срабатывает только при патологии.

**Гномы возвращаются sprint-скоростью (этап 45).** `Gnome._tick_returning` использует `caravan_sprint_speed` (9 m/s, выше Tower=8) вместо `move_speed` (1.6). Через лагерь 12м гном пробегает за 1.3с. С vacancy-claim это значит: в `CARAVAN_FOLLOWING` бездомный нашёл вакансию → бежит к ней быстро, тут же IN_TENT.

**Сироты при гибели палатки** (`_on_part_destroyed → _reassign_orphan_gnomes`): когда палатка умирает, гномы с `_home_tent == dead_tent` получают `set_home_tent(nearest_alive)`. Если живых палаток нет — `enter_following_caravan` (бездомные). Ejected гномы (eject_from_tent поставил `_home_tent=null`) этим reassign'ом не затрагиваются.

**Eject из палатки (этап 45).** `Gnome.eject_from_tent(camp)` вызывается из `CampPart._eject_in_tent_gnomes`:
1. State = SEARCHING (промежуточный, чтобы IN_TENT-приклейка не вернула гнома обратно).
2. `add_to_group(SKELETON_TARGET_GROUP)` — теперь скелет может его атаковать.
3. **Окно неуязвимости** `post_eject_invulnerability` (2с) — `take_damage` ранний return. Чтобы окруживший скелетоход не срезал гнома мгновенно при разрушении палатки.
4. Random `apply_push(scatter_dir × post_eject_scatter_speed (5), post_eject_scatter_duration (0.5))` — горизонтальный scatter по инерции, AI off на длительность knockback'а. Гномы разлетаются в стороны, не идут аккуратной очередью.
5. `_home_tent = null`, `enter_following_caravan` → state FOLLOWING_CARAVAN, регистрация в `Camp._caravan_followers`.

**Логика развёртки (`_handle_input` в `CARAVAN_FOLLOWING`):**
- POI-gate: каждый кадр `_find_poi_for_deploy()` ищет ближайший QuestActor в группе `poi_zone`, в радиусе которого находится башня. `poi_ok = (not require_poi) or (poi != null)`.
- Пока зажата `R` И `_is_tower_stationary()` И `poi_ok` — `_deploy_hold += delta`. Движение башни / отпускание R / выезд из POI → сброс счётчика. Лог-фронт различает причину сброса.
- На `_deploy_hold ≥ deploy_duration` → `_start_deploy()`: anchor приоритет `poi.global_position > _tower.global_position > self`. Для каждой палатки считается своя `_deployed_targets[i]`; `_state = DEPLOYED`; эмит `deployed(anchor)`. Anchor совпадает с POI → WaveDirector найдёт POI по anchor'у и запустит осаду по `wave_schedule`.
- Вызов `g.enter_deployed()` для каждого гнома → выходит из палатки, `_state = SEARCHING`.

**`_is_tower_stationary`:** `_tower != null` и delta-position на горизонтали `< stationary_threshold`. Не зависит от того, что цель — `CharacterBody3D`; работает с любым `Node3D`.

**Tower aggro (этап 42):** Camp ставит/убирает `_tower` в группу `skeleton_target`:
- На `_ready` (если не start_deployed): `_set_tower_aggro(true)` — в каравне tower сам по себе цель. Фоновые wander-скелеты, увидев караван глазами, идут к tower и атакуют (Damageable.try_damage от Skeleton._perform_strike).
- На `_start_deploy`: `_set_tower_aggro(false)` — осада переключается на палатки/гномов вокруг костра.
- На `_finalize_pack`: `_set_tower_aggro(true)` — возвращаем после свёртки.
- На `_on_tower_destroyed`: `_set_tower_aggro(false)` (страховка перед очисткой ссылки).
- `_set_tower_aggro` идемпотентен (повторный add no-op), null-safe (tower=null → no-op), `is_inside_tree()`-guard.

**Дележ куч между гномами (`is_pile_claimed`):**

```gdscript
func is_pile_claimed(pile: ResourcePile, exclude_gnome: Gnome = null) -> bool
```

Возвращает `true`, если кучу уже нацелил какой-то гном, отличный от `exclude_gnome`. Гном-сканер пропускает claimed-кучи — каждый ищет «своё», нашедший один не созывает остальных.

**Логирование (`debug_log=true`, фронт-триггеры):** «начат отсчёт развёртки», «отсчёт прерван (отпущена R)» / «(башня поехала)», «лагерь развёрнут @ (...)», «свёртка инициирована — ждём гномов», «лагерь свёрнут (все гномы дома)».

**Внешние зависимости:** Tower через `target_path` (читается только `global_position`). Тип `Gnome` (для `_gnomes` массива и API). Тип `ResourcePile` (для сигнатуры `is_pile_claimed`). `Layers.TERRAIN` для raycast'а пола под палатками.

#### Squad XP и апгрейды отряда (этап 47)

Camp накапливает общий **squad XP** и уровни отряда защитников. Apgreids читаются защитниками через `has_upgrade(id)`.

**Состояние:**
- `_squad_xp: int` — общий XP отряда. Накапливается через `add_squad_xp(amount, at_position)` (этап 49) — зовётся `XpOrb` на arrival к anchor'у.
- `_squad_level: int` — текущий уровень. Считается по `squad_level_xp_curve: Array[int] = [50, 120, 250, 500, 1000]`. Дойдя до порога — `_squad_level++ + _pending_upgrade_choices++ + EventBus.squad_leveled_up.emit(level)`.
- `_active_upgrades: Array[StringName]` — выданные апгрейды. Защитники читают на каждом тике через `has_upgrade(id)` — новые после respawn'а автоматически в курсе.
- `_pending_upgrade_choices: int` — банк выборов: уровни в очереди на трату. JournalPanel-вкладка «Юниты» рисует бэйдж с числом и активирует кнопки «выбрать»; на трате эмитит `EventBus.pending_upgrade_choices_changed(count)`.

**Параметры:**
- `upgrade_long_draw_bonus: float = 5.0` — +5м к `attack_radius` при апгрейде long_draw.
- `kite_threshold_distance: float = 6.0` — порог для kiting-апгрейда: ближе → защитник пятится.
- (Сумма XP за орб задаётся в `XpOrbSpawner.XP_PER_KILL = 10`, не в Camp — Camp получает amount как параметр и не привязан к фиксированному значению.)

**API:**
- `add_squad_xp(amount: int, at_position: Vector3)` (этап 49) — добавляет XP. Эмитит `EventBus.squad_xp_gained_at(amount, position)` (для popup'а), затем `squad_xp_changed`. While-цикл проверяет уровни, эмитит `squad_leveled_up`. Заменил старый `credit_kill` — XP теперь приходит через осязаемый объект-орб, который игрок видит на земле и собирает.
- `has_upgrade(id) -> bool`, `grant_upgrade(id)` — для JournalPanel-вкладки «Юниты». На trate эмитит `pending_upgrade_choices_changed`.
- `available_upgrades() -> Array[StringName]` — id'шки, ещё не выданные.

**Каталог апгрейдов** — `UPGRADE_CATALOG: Dictionary` (id → name + description + level):
- `UPGRADE_KITING` (level 1) — "Манёвр уклонения": лучники стреляют на ходу и пятятся от близких скелетов.
- `UPGRADE_LONG_DRAW` (level 1) — "Усиленное натяжение": дальность стрельбы +5м.

`level` — минимальный `squad_level` для разблокировки. JournalPanel показывает все апгрейды (активные / нужен уровень / нет очков / выбрать), отсортированные по `level`. Дизайнер: первые два доступны на уровне 1, дальше по одному на уровень.

**Замена UpgradeModal на JournalPanel (2026-05-07):** старый `UpgradeModal`-autoload (попап на `squad_leveled_up` с `get_tree().paused = true`) удалён. Дизайнер: «не останавливать каждый раз игру для улучшения юнитов». Теперь level-up просто инкрементит `_pending_upgrade_choices` + flash в HUD, игрок открывает Journal (J) когда удобно. Подробнее — раздел JournalPanel ниже.

**Группа `camp`:** Camp в `_ready` добавляется в группу `camp` через `add_to_group(CAMP_GROUP)`. JournalPanel и другие UI-autoload'ы находят лагерь через `get_first_node_in_group("camp")`.

#### Ресурсная экономика (фаза 2, 2026-05-07)

Camp хранит пул ресурсов и API списания. Гном на arrival к `deploy_anchor` кредитует 1 единицу типа который нёс (см. `Gnome._tick_commuting_to_base`). Рука может бросить целый pile в `_anchor_drop_zone` — он consume'нется целиком (см. ниже).

- `_resources: Dictionary[int, int]` — `ResourcePile.ResourceType (int) → amount`. Хранится только заполненные ключи (Dictionary, не Array — на проекте могут быть зоны без всех типов).
- `add_resource(type, amount)` — гном/anchor-zone кредитует. Эмитит `EventBus.resources_changed(type, total)`.
- `try_spend(cost: Dictionary) -> bool` — атомарно. Если хватает по всем типам, списывает; иначе ничего не меняет.
- `can_afford(cost) -> bool` / `get_resource(type) -> int` — для UI.

#### Постройки лагеря (фаза 3, 2026-05-07)

Параллельный каталог `CAMP_BUILDING_CATALOG` отдельно от `UPGRADE_CATALOG`: апгрейды отряда — за уровни (XP-driven), постройки — за ресурсы. Дизайнер: «У лагеря нет источника XP. Это постройка за ресурсы».

- `BUILDING_NEW_TENT` — новая палатка в кольце лагеря. Cost: 20 wood + 10 stone + 5 food. `deployed_only: true` (строится только в `State.DEPLOYED` — дизайнерское правило 2026-05-08, изменено с прежнего «только в свёрнутом»). `repeatable: true`.
- `try_build(id) -> {success, reason}` — атомарно: `can_build_reason` (state) → `can_afford` → `try_spend` → `_apply_building`. Эмитит `camp_buildings_changed`.
- `_build_new_tent`: вызывает извлечённый `_spawn_one_tent()` (общий с инициализацией), ставит палатку на `_deploy_anchor`, дёргает `_rebuild_deployed_targets()` (кольцо пересчитывается на N+1 слотов), спавнит гномов, дёргает `enter_deployed()` на новых.

#### Anchor drop zone (бросок ресурса рукой)

`_anchor_drop_zone: Area3D` (sphere radius=`anchor_drop_radius=2.5м`, layer=0/mask=Items). Создаётся в `_ready`, monitoring=false. На `_start_deploy` едет на anchor (+0.5м по Y) и включается, на `_start_pack` выключается.

Polling в `_process` через `_consume_piles_in_drop_zone()`: иду по `get_overlapping_bodies()`, фильтрую `pile.freeze` (рука держит — не вырываем), вызываю `pile.consume_all() -> int`, кредитую `add_resource`, спавню `ResourceFx.pulse(pile_pos, color)`. Polling, а не `body_entered`-сигнал — чтобы поймать «рука держит pile в зоне → отпускает» (entered не сработал бы).

#### План распределения сбора + alarm/work (2026-05-08)

`_collection_priority: Dictionary[int, float]` — нормализованные веса по типам (sum=1). Гном в `_find_nearest_pile` использует weighted distance: `dist² / weight²`. Высокий weight «приближает» pile, weight≤0.001 — тип игнорируется.

- `set_collection_priority(weights)` — нормализует sum к 1, эмитит `collection_priority_changed`. JournalPanel-вкладка «План» имеет 5 preset'ов (Равномерно / Больше дерева/камня/железа/еды).
- Дефолт через `@export initial_collection_priority_*` (по 1.0 каждому → равномерно).
- На смену приоритета гномы реактивно перевыбирают pile (см. Gnome._on_collection_priority_changed).

`_collection_mode: CollectionMode {WORK, ALARM}` — переключается хоткеями `gnome_collect` (C) и `gnome_alarm` (V), обработка в новом `_handle_collection_input()` (отдельно от `_handle_input` чтобы работало и в start_deployed-лагерях). На переключение в DEPLOYED:
- `WORK`: каждый gatherer → `enter_deployed()` (выходит, идёт в SEARCHING).
- `ALARM`: каждый gatherer → `request_return()` (бежит в палатку → IN_TENT, скрыт). DefenderGnome пропускается (продолжает защищать).

**Skeleton alarm на удар по лагерю** (этап 47): `Skeleton._perform_strike` после успешного `try_damage` по CampPart или НЕ-DefenderGnome'у эмитит `EventBus.skeleton_attacked_camp(self, victim, position)`. Defender'ы своего лагеря (фильтр в хендлере) разворачиваются на attacker'а на 5с (override конуса).

---

### 5.8 Gnome — `scenes/gnome.tscn`, `scripts/gnome.gd`

**Тип корня:** `CharacterBody3D` с `class_name Gnome`.

**Назначение:** обитатель лагеря. Базовый класс — гном-собиратель. Спавнится `Camp` по `(gnomes_per_tent − defenders_per_tent)` штук на каждую палатку. Сам ищет ресурсы (двухфазная FSM: поиск глазами + патруль / челнок к найденной куче), сам носит их к anchor'у лагеря. По сигналу свёртки — возвращается в свою палатку.

Имеет подкласс `DefenderGnome` (см. §5.8.1) — гном-защитник, переопределяет «активный» AI на «стой и стреляй».

**Дочерние узлы:**
- `CollisionShape3D` — `CapsuleShape3D` r=0.25, h=0.7.
- `MeshInstance3D` — `CapsuleMesh` того же размера.
- (рантайм) `_carry_visual: MeshInstance3D` — маленький зелёный куб над головой при подборе, `queue_free` при дропе.

**Слой/маска:** `collision_layer = Layers.FRIENDLY_UNIT = 256`, `collision_mask = Layers.TERRAIN = 1`. Гномы проходят сквозь башню, врагов, предметы и друг друга — не толкаются и не блокируют игрока. Гравитация — единственное физическое взаимодействие. **Главное:** `MASK_SKELETON = 39` НЕ включает FRIENDLY_UNIT → скелет в broad-phase гнома не видит → пар нет → `move_and_slide` скелета проходит сквозь гнома без collision-iteration. На 126 гномах в плотной толпе скелетов это была одна из главных нагрузок (каждый skel в кадре обходил contact-list по каждому соседнему гному). Урон по гномам идёт через `Damageable.try_damage` на STRIKE-фазе (контракт, не physics-collision) — смена слоя не сломала геймплей, только визуально скелет проходит сквозь гнома.

**Экспорты:**
- Группа **Movement:** `move_speed: float = 1.6`, `gravity: float = 20.0`.
- Группа **Behaviour:**
  - `vision_radius: float = 10.0` — дальность зрения только для XP-орбов (`_scan_orb`). Pile-ам не нужна: гном ищет ближайший годный pile **глобально** через `_find_nearest_pile` (без cap'а дистанции, weight'ы из `Camp._collection_priority` управляют выбором). Изменено 2026-05-08: раньше был `search_radius=300` random-wander, гномы бегали через всю карту; теперь идут целенаправленно.
  - `idle_radius: float = 4.0` — радиус ошивания возле anchor'а, когда куч нет / все claim'нуты другими.
  - `idle_pile_rescan_sec: float = 1.5` — пауза между rescan'ами в IDLE_NEAR_BASE. Без этого гном залипал в idle (raньше не пересканировал куч до следующего deploy'я).
  - `pickup_distance: float = 0.8`, `deposit_distance: float = 1.2`, `home_distance: float = 0.8`, `wander_arrival: float = 0.6`.
  - `wander_map_half_extent: float = 195.0` — clamp idle-wander к границам карты (на случай если deploy_anchor близко к краю).
- Группа **Visual:** `gnome_color`, `carry_color`, `carry_visual_size`.
- Группа **LOD (масштабирование на 100+ гномов):**
  - `lod_far_distance: float = 50.0` — дальше этой дистанции до точки интереса камеры (`CameraRig`) гном уходит в холодный режим: `_physics_process` пропускает `move_and_slide` и гравитацию, position обновляется через `global_position += velocity * delta` (X/Z). AI продолжает работать на полной частоте — он дёшев. Главный win: при удалённой камере 6 поселений × ~21 гном = 126 гномов без `move_and_slide`.
  - `lod_check_interval: float = 0.5` — период переоценки.
  - `lod_offscreen_half_angle_deg: float = 60.0` — **frustum-override** (симметрично Skeleton): гном вне cone'а перед Camera3D форсируется в FAR-режим независимо от расстояния. На 126 гномах в кластере вокруг Tower при стандартной FOV это переносит ~50% в холодный режим. Прекомпьют `cos(...)` в `_ready`. Frustum-чек берётся от Camera3D (реальная точка наблюдения), distance — от CameraRig (зум-стабильный якорь).
- `debug_log: bool = false` — по умолчанию выключен.

**FSM:**

```gdscript
enum State {
    IN_TENT, SEARCHING, COMMUTING_TO_PILE, COMMUTING_TO_BASE,
    IDLE_NEAR_BASE, RETURNING_TO_TENT, FOLLOWING_CARAVAN,
}
```

- `IN_TENT` — приклеен к `_home_tent.global_position`, `visible = false`. Палатка-щит: `take_damage` ранний return (этап 45).
- `SEARCHING` / `COMMUTING_TO_PILE` / `COMMUTING_TO_BASE` / `IDLE_NEAR_BASE` — активная AI-логика в DEPLOYED.
- `RETURNING_TO_TENT` — идёт к своей палатке sprint-скоростью `caravan_sprint_speed` (9 m/s, этап 45). Дропает carry. Используется при свёртке + при vacancy-claim (бездомный нашёл место).
- `FOLLOWING_CARAVAN` (этап 45, расширение) — бездомный гном идёт за караваном в общей цепочке за палатками. Зарегистрирован в `Camp._caravan_followers`. В `_tick_following_caravan` запрашивает `Camp.get_chain_target_for_follower(self)` и идёт к chain-слоту. Скорость — lerp от `move_speed` (в слоте) до `caravan_sprint_speed` по дистанции до slot'а через `caravan_full_sprint_distance` (5м). Раз в ~1-1.5с проверяет вакансии в живых палатках через `Camp.find_tent_with_vacancy_for(self)`; найдёт — `_claim_tent_as_home(tent)` переключает в RETURNING_TO_TENT.

**Поля:** `_camp: Camp`, `_home_tent: Node3D`, `_state: State`, `_assigned_pile: ResourcePile`, `_wander_target: Vector3`, `_carry_visual: MeshInstance3D`, `_knockback: KnockbackState`, `_post_eject_invulnerable_until_msec: int` (этап 45, время неуязвимости после eject'а), `_caravan_chain_offset: Vector2` (этап 45, per-гном смещение в строю), `_next_tent_vacancy_check_msec: int` (этап 45, throttle vacancy-чека).

**API для Camp:**
- `setup(camp, home_tent)` — кэширует ссылки, входит в `IN_TENT`.
- `enter_deployed()` — `visible = true`, `_state = SEARCHING`.
- `request_return()` (этап 47, обновлено) — IN_TENT → ничего; иначе если `is_instance_valid(_home_tent)` → `_state = RETURNING_TO_TENT` (gatherer бежит домой), иначе → `enter_following_caravan()` (бездомный в колонну). Палатка = безопасное место для собирателей. Защитники переопределяют этот метод и сразу идут в колонну (см. 5.8.1).
- `eject_from_tent()` (этап 45, без `damage` параметра) — выпуск из IN_TENT с 2с неуязвимостью + scatter knockback + FOLLOWING_CARAVAN.
- `enter_following_caravan()` — идемпотентно ставит state, регистрирует в `_caravan_followers`, рандомизирует chain-offset.
- `is_home() -> bool` — `_state == IN_TENT`.
- `is_following_caravan() -> bool` (этап 45) — `_state == FOLLOWING_CARAVAN`. Camp `_all_gnomes_home` считает «settled» = `is_home() or is_following_caravan()`.
- `get_caravan_chain_offset() -> Vector2` (этап 45) — для Camp.get_chain_target_for_follower.
- `get_assigned_pile() -> ResourcePile`.

**Логика сбора (2026-05-08, единая модель):**

| Шаг | Условие | Действие |
|---|---|---|
| 1. Поиск (SEARCHING) | каждый кадр | `_find_nearest_pile()`: глобальный обход `_pile_grid`, weighted-cost = `dist² / weight²` где `weight = _camp.get_collection_priority_weight(pile.resource_type)`. Skip: пустые, `freeze=true`, claimed, weight≤0.001. |
| 2. Найдено | `pile != null` | `_assigned_pile = pile` → `COMMUTING_TO_PILE`. |
| 3. Не нашёл | nothing годное | → `IDLE_NEAR_BASE` (не random-wander, как было до). |
| 4. Челнок к куче | `COMMUTING_TO_PILE` | идём к `pile.global_position` (читаем каждый кадр — следим за катящимся бревном). На `pickup_distance` зовём `take_one()`; успех → carry, `_carry_type = pile.resource_type`, `COMMUTING_TO_BASE`. Провал/потеря → `_on_pile_lost()` → SEARCHING. |
| 5. К базе | `COMMUTING_TO_BASE` | идём к `_camp.deploy_anchor`. На `deposit_distance` зовём `_camp.add_resource(_carry_type, 1)` + `ResourceFx.pulse(...)`, дропаем carry. **Всегда** `_on_pile_lost()` → SEARCHING (полный rescan под текущий приоритет; если приоритет тот же, ближайший pile часто остаётся тем же — челнок неявный). |
| 6. Idle | `IDLE_NEAR_BASE` | слоняемся в `idle_radius` вокруг anchor'а. Раз в `idle_pile_rescan_sec` зовём `_find_nearest_pile` — ловим момент когда другой гном освободил claim или новый pile появился. Если pile найден → `COMMUTING_TO_PILE`. |

**Реактивность:**
- `pile.freeze == true` (рука держит) → `_tick_commuting_to_pile` → `_on_pile_lost()` → SEARCHING. Когда отпустят, гном переисщет.
- `pile.global_position` читается каждый кадр в `_tick_commuting_to_pile` — следит за катящимся бревном автоматически.
- `EventBus.collection_priority_changed` (игрок поменял preset плана): гном в `COMMUTING_TO_PILE` дропает текущий pile (`_on_pile_lost`), новый поиск под обновлённый приоритет. Гном с carry в `COMMUTING_TO_BASE` донесёт текущую единицу — кредит важнее мгновенной переоценки. После доставки auto-rescan подхватит.

**Carry-тип** (`_carry_type: int`) — записывается в `_pickup_carry` из `_assigned_pile.resource_type` ДО возможного `queue_free` pile'а (units → 0); сбрасывается в `_drop_carry`. Цвет carry-визуала — `ResourcePile.color_for_type(_carry_type)`. Кредит в `_tick_commuting_to_base` происходит ТОЛЬКО на честной доставке (по `deposit_distance` к anchor'у); смерть гнома и `RETURNING_TO_TENT` дропают carry без кредита (буквально «уронил по дороге»).

**Зависимости:** типы `Camp` (через ссылку из `setup`, читает `deploy_anchor`, `is_pile_claimed`) и `ResourcePile`. Не знает Tower/Hand/Skeleton.

---

### 5.8.1 DefenderGnome — `scenes/defender_gnome.tscn`, `scripts/defender_gnome.gd`

**Тип корня:** `CharacterBody3D` с `class_name DefenderGnome extends Gnome`.

**Назначение:** гном-защитник-лучник. Спавнится `Camp` по `defenders_per_tent` штук на каждую палатку (дефолт 1 из 7 жителей; остальные 6 — обычные собиратели). В отличие от собирателей, **никогда не сидит в палатке** — на спавне сразу выходит в режим escort, в развёрнутом лагере патрулирует периметр. Видит угрозы через **конус зрения** (не sphere), реагирует на **alarm-канал** удара по лагерю, прокачивает **squad XP** убийствами.

**Что наследуется без изменений:**
- Базовый `_physics_process` (LOD, gravity, knockback, move_and_slide vs cold-mode).
- `take_damage` / `apply_push` / `_knockback`. HP то же (20).
- Shatter-эффект на смерть.
- Цвет `gnome_color` через `_apply_visual` — в `defender_gnome.tscn` override на красный.

**Что переопределяется:**
- `_enter_in_tent()` → перенаправляет в `enter_following_caravan()`. Защитник не сидит в палатке: и на спавне, и при возврате домой сразу идёт в escort.
- `request_return()` (этап 47) → сразу `enter_following_caravan()`, минуя `RETURNING_TO_TENT` базового класса. Защитнику палатка не «безопасное место», поэтому он не делает крюк к ней при свёртке — встаёт в строй и продолжает стрелять на ходу.
- `enter_following_caravan()` → переключает state в FOLLOWING_CARAVAN, но **не регистрируется** в `_caravan_followers` (orphan-end-of-column не для него).
- `_tick_following_caravan()` → escort: цель = `_compute_escort_target` (палатка + perpendicular × `escort_lateral_distance × ±1`). Если палатка уничтожена — fallback на башню. Sprint-catchup как у обычного гнома.
- `enter_deployed()` → super + ставит `_facing` наружу от лагеря, чтобы первый кадр сканировал в правильную сторону.
- `_active_tick(delta)` — четыре ветки: RETURNING_TO_TENT (super, но в норме не активен — request_return защитника сразу в FOLLOWING_CARAVAN), FOLLOWING_CARAVAN (escort + parallel `_caravan_combat_tick`), DEPLOYED-states (`_defender_combat_tick`).

**Конус зрения** (этап 47):
- `cone_vision_radius: float = 35.0` — радиус ВИДИМОСТИ (больше attack_radius=22.5 — лучник видит дальше чем стреляет).
- `vision_half_angle_deg: float = 45.0` — полу-угол конуса (90° FOV total). Сужено с 60° чтобы оставить место апгрейду «сторожевая вышка».
- `_facing: Vector3` — текущее направление взгляда (горизонтальный unit-vector). Тело физически разворачивается через `rotation.y = atan2(-_facing.x, -_facing.z)`. Видимый игроку индикатор — `FacingIndicator` (тёмный «нос» на капсуле).
- `_is_in_cone(target_pos)`: dot(_facing, dir_to_target) >= cos(half_angle). Прекомпьют `_vision_cone_cos` в `_ready`.
- `_scan_cone()` — PhysicsShapeQuery со сферой `cone_vision_radius` (broadphase) → фильтр по углу через `_is_in_cone` → выбор «лучшей» цели по формуле `score = dist × (1 + aimers × target_share_penalty)`. Это распределение огня (см. ниже).

**Alarm-канал** (этап 47):
- `EventBus.skeleton_attacked_camp(attacker, victim, position)` — emit'ится из `Skeleton._perform_strike` после удара по CampPart или НЕ-DefenderGnome (мирному гному).
- DefenderGnome подписан в `_ready`. Хендлер `_on_skeleton_attacked_camp` фильтрует «наш ли лагерь» (CampPart-родитель == _camp, или Gnome ∈ _camp.get_gnomes()), ставит `_alarm_target = attacker`, `_alarm_until_msec = now + alarm_persist_sec×1000`.
- В `_resolve_target` alarm имеет приоритет над cone-сканом — конус игнорируется, лучник разворачивается на attacker даже из-за спины. Через 5с без ре-триггера alarm протухает.
- `alarm_persist_sec: float = 5.0` (export).

**Apply при перцепции** — единый путь `_resolve_target(delta) -> Node3D`:
1. Cleanup freed `_cached_target` (жёсткий `is_instance_valid` cleanup в начале — без него typed Node3D-параметр в `_log_target_change` падает на freed-инстансе с ошибкой Godot 4.6 «previously freed not subclass»).
2. Alarm-target если активный → `_cached_target = alarm`, throttle-сброс.
3. Иначе — stale-чек cone-цели (вне радиуса/конуса), рескан раз в `TARGET_SCAN_INTERVAL=0.25с` или при стейл-стимулом (была цель — теперь null).
4. Вызывается из обоих боевых тиков (DEPLOYED+CARAVAN).

**Боевая модель:**
- `attack_radius: float = 22.5` — дистанция гарантированного попадания (читается через `effective_attack_radius()`, +5м с апгрейдом long_draw).
- `attack_cooldown_min/max = 1.0 / 2.0`.
- `arrow_damage_min/max = 20 / 32` (v5, 2026-05-10: −20% от 25/40). Avg 26 dmg, 1-shot скелета (hp=30) только при удачном крите 30..32 (~6%), обычно 2-shot. Магия должна оставаться основным DPS, лучник — пассивный backup.
- `arrow_speed = 22`, `arrow_spawn_offset = (0, 0.6, 0)`.
- На `_fire_at(target)` лучник готовит и спавнит стрелу. Kill-credit chain (этап 47-48) удалён в этапе 49 — XP теперь идёт через `XpOrbSpawner` autoload (слушает `EventBus.enemy_destroyed`). Стрелок не привязан к стреле.

**Боевой тик в DEPLOYED** (`_defender_combat_tick`):
- Цель в `effective_attack_radius()` → стой, стреляй. С апгрейдом kiting и `dist < kite_threshold_distance` — пятимся (-_facing × patrol_speed) продолжая стрелять.
- Цель в конусе, но дальше attack_radius → sector-патруль: точка на окружности `patrol_radius=12м` от `deploy_anchor`, под углом = direction от лагеря к цели. Идёт туда; войдя в attack range, переключится автоматически.
- Без цели → случайный патруль по периметру + cone-fallback `_facing` в направление движения, иначе outward от лагеря.
- В attack-ветке всегда добавляется **сепарация** (см. ниже) — лучники не стоят «один на одном».

**Боевой тик в CARAVAN** (`_caravan_combat_tick`):
- Параллельно с escort-движением: тот же `_resolve_target`, при цели в attack_radius — стрельба НЕ останавливаясь (велосити управляется escort-логикой).
- Sector-патруль здесь не применяется (anchor stale, колонна ведёт).

**Точность и прокачка (per-instance):**
- `base_inaccuracy_radius = 1.5`, `experience_half_shots = 100` — кривая `base / (1 + shots/half)`. 0 выстрелов: 1.5м, 100: 0.75м, 500: 0.25м, 1000: 0.14м.
- `_shots_fired` per-инстанс, не сохраняется. На смерть теряется.
- Геттер `current_inaccuracy_radius()`, `get_shots_fired()`.

**Сепарация и распределение огня** (этап 47):
- `separation_radius = 1.5`, `separation_strength = 0.5` (× patrol_speed) — `_compute_separation_force()` суммирует векторы отталкивания от защитников в радиусе с linear falloff. Прибавляется к velocity в attack-ветке. Защитник стоит/пятится, но дрейфует вбок если сосед прижался. `_facing` не меняется.
- `target_share_penalty = 0.5` — в `_scan_cone` цель с N уже-стрелков получает score × (1 + N×0.5). Близкая цель с 1 стрелком сравняется с целью на 50% дальше без стрелков. Раскидывает огонь.
- `DEFENDER_GROUP = "defender"` — все живые DefenderGnome (для итерации в обоих механиках).

**Escort (caravan-режим)** (этап 46):
- `escort_lateral_distance = 2.0` — метров вбок от палатки.
- `_escort_lateral_sign: ±1.0` рандомизирован в `_ready` per-инстанс — несколько защитников распределяются по обоим бортам.
- `_compute_escort_target()`: `tent.position + perpendicular × lateral × sign`. Forward-вектор каравана = (tower − tent).normalized; perpendicular = 90° rotation в плоскости XZ.
- Если палатка убита и Camp не нашёл новой — fallback на башню.

**Kill credit** (этап 49 — переработано на XP-orbs):
- Прежняя цепочка `Arrow._shooter → on_kill_credit → camp.credit_kill` удалена. Стрелок не передаётся в стрелу, `Arrow.on_body_entered` ничего не знает про XP.
- Вместо этого: `XpOrbSpawner` autoload подписан на `EventBus.enemy_destroyed`, на каждый kill спавнит `XpOrb` в позиции трупа. Орб лежит, ждёт касания союзника (Tower / CampPart / Gnome), на касании магнитится к `Camp.deploy_anchor`, на arrival вызывает `add_squad_xp`. См. §5.10 (XpOrb).
- Личный опыт защитника (`_shots_fired` для точности) не зависел и не зависит от kill credit'а — инкрементируется в `_fire_at` per-выстрел.

**Level-up flash** (этап 49):
- `_on_squad_leveled_up(_level)` — подписка на `EventBus.squad_leveled_up` в `_ready`. Tween scale меша 1.0 → 1.3 → 1.0 за 300мс (TRANS_QUAD). Каждый живой защитник «вспыхивает» на левел-апе. Без шейдеров; tween на `_mesh.create_tween()` — если защитник умрёт mid-flight, mesh queue_free'нется вместе с ним и tween тихо отвалится.

**Squad-апгрейды** (читаются через `_camp.has_upgrade(id)`):
- `Camp.UPGRADE_KITING` — пятиться при близком враге (см. боевой тик).
- `Camp.UPGRADE_LONG_DRAW` — `effective_attack_radius() = attack_radius + camp.upgrade_long_draw_bonus`.

**Маска поиска целей:** `ENEMIES | COLD_ENEMY = 144` (исторически, чтобы видеть и cold-LOD скелетов).

**Explicit radius-фильтр после intersect_shape:** Godot 4.6 PhysicsShapeQuery подмешивает AABB-broadphase результаты вне сферы. Ручной `if d > cone_vision_radius: continue` без этого видели цели на 50м+.

**Архитектура:** `Gnome` — базовый класс с виртуальным `_active_tick(delta)`. DefenderGnome переопределяет hook + ряд lifecycle-методов (`_enter_in_tent`, `enter_following_caravan`, `_tick_following_caravan`, `enter_deployed`). Весь structural скелет (IN_TENT-приклейка для не-defender'ов, LOD, gravity, knockback) живёт в базе один раз.

---

### 5.8.2 Армия — `Squad` (RefCounted), `SoldierGnome` (копейщик), `SoldierSystem` (autoload), `HandSquadAim` (aim-координатор)

**Концепция.** Игрок мобилизует gatherer'ов в боевые отряды через `JournalPanel → «Армия»`. Призыв — лагерное действие (доступно только в `State.DEPLOYED`). Размобилизация — обратная конверсия в gatherer'а на текущей позиции, тоже только в лагере. Лучники (DefenderGnome) — НЕ призываются; они только штатные защитники у палаток. Призываются только melee-копейщики.

#### 5.8.2.1 SoldierSystem — каталог типов юнитов
Autoload-сценарий, аналог SpellSystem. Single source of truth для параметров рекрутируемых юнитов.

`SOLDIER_CATALOG: Dictionary` — id → Dictionary с полями:
- `name`, `description`, `icon_color`
- `squad_size: int` — единица призыва (5 для копейщиков). За один recruit-клик конвертится N gatherer'ов в N солдат.
- `cost: Dictionary` (ResourcePile.ResourceType → amount) — ресурсы за весь отряд.
- `scene: PackedScene` — что инстанцировать (extends SoldierGnome).
- `stats: Dictionary` — параметры юнита (hp, enemy_detect_radius, attack_range, damage_min/max, cooldown_min/max, move_speed).

Текущий каталог — только `pikeman`: hp=30, attack_range=2.2м, damage 22..32, cooldown 0.6..1.0с, move_speed=2.2.

#### 5.8.2.2 Squad — RefCounted-сущность
Не Node. Чистая логическая обёртка: `members: Array[SoldierGnome]`, `state`, `hold_position`, `_strict_move`. Каждый soldier держит ссылку (`_squad`), Camp хранит в `_squads` — пока живы, RefCounted alive.

**States:**
- `HOLDING_POSITION(pos)` — кольцо вокруг hold_position. Бой в leash-радиусе. Радиус адаптивный: `HOLD_RING_RADIUS=1.6м` как floor, выше — `HOLD_RING_MIN_ARC × n / TAU` (минимум 1.3м дуги на юнита, чтобы капсулы не налезали). На squad_size=5 — 1.6м (no-op), на 10 — ~2м, на 15 — ~3.1м.
- `ESCORTING_TOWER` — то же кольцо, но центр = tower.
- `DEFENDING_CAMP` — wander-патруль по периметру лагеря (НЕ кольцо, см. SoldierGnome._tick_defend_patrol).

`_strict_move: bool` — флаг последнего `command_hold(pos)`. Юнит, не дошедший до своего слота, в этом режиме игнорирует бой («точное указание места — четкое указание, всё прерывает»). На `command_escort/defend` сбрасывается. Per-soldier flag `_strict_arrived_at_slot` снимает блокировку combat'а после первого прибытия — иначе lunge выбрасывал бы из слота, strict снова марш back, юнит дёргался.

API: `command_hold(pos, strict=true)` / `command_escort()` / `command_defend()`. Public `remove_member(soldier)` — для dismiss-конверсии (queue_free без _die не фронтит destroyed-сигнал).

#### 5.8.2.3 SoldierGnome — копейщик
Подкласс Gnome. Не привязан к палатке. Combat — **6-фазная charge-state machine** с anticipation-паузой:

```
READY → APPROACH → WINDUP → LUNGE → DRIFT → RECOVERY → READY
```

- **APPROACH** (`approach_max_speed=3.5`, `approach_accel_time=0.18`) — бежит к цели, скорость линейно с 0 до max, направление пересчитывается каждый кадр (re-aim). При `dist ≤ lunge_trigger_range=4.0м` → WINDUP. Лимит `max_approach_distance=9м` — отмена.
- **WINDUP** (`LUNGE_WINDUP_DURATION=0.09с`) — статичная coiled-пауза перед взрывом. `velocity = 0`, направление обновляется на последний кадр (за 90мс цель могла сдвинуться). Тело tween'ится в `POSE_WINDUP=(1.3, 0.95, 0.6)` — вид сверху широкий овал поперёк, гном «припал как пружина». Без этой фазы рывок сливался бы с разгоном и читался как «продолжил ускоряться», а не «выстрелил копьём». Anticipation — обязательна даже когда цель уже в упор.
- **LUNGE** (`lunge_speed=22 м/с`, фикс-дир) — молниеносный рывок (~6× approach_max_speed — резкий разрыв, глаз отделяет lunge от разгона как другое событие). Удар первым кадром в `attack_range=2.2м`. Продолжает лететь `lunge_pass_distance=1.6м` после удара по инерции («протыкает насквозь»). Тело снапает в `POSE_LUNGE=(0.6, 1.0, 1.7)` — extended-стрелка вдоль направления удара.
- **DRIFT** (`drift_time=0.25с`) — резкое торможение поверх 22 м/с. Speed спадает по `pow(t, 0.6)` — медленный начальный спад («занос держит инерцию»). На входе в DRIFT поза tween'ится обратно в `POSE_NEUTRAL=(1,1,1)` за `POSE_RESTORE_TIME=0.22с`.
- **RECOVERY** (`recovery_time=0.7с`) — стоит, отдыхает, уязвим. Окно расплаты для скелета 0.95с (drift 0.25 + recovery 0.7) — windup 0.32-0.48с укладывается дважды, один strike гарантированно, второй возможен при удачном тайминге. После — READY.

Полный цикл: WINDUP 0.09 + LUNGE ~0.15 + DRIFT 0.25 + RECOVERY 0.7 ≈ 1.2с + cooldown 0.6-1.0с ≈ 1.8-2.2с между ударами.

**Squash & stretch.** Tween-переходы между позами через `_tween_pose_to(target, duration)` — параллельно скейлится тело (`_mesh` из Gnome) и `FacingIndicator` (только у Pikeman'а, через `get_node_or_null`). Z-контраст POSE_WINDUP→POSE_LUNGE: 0.6→1.7 ≈ 2.8× — заметный визуальный «взрыв». `_pose_tween` хранится для kill'а старого при следующем переходе (быстрая серия charge'ей не должна перекрывать tween'ами). Хелперы `_enter_drift(d)` / `_enter_recovery(r)` централизуют «state + restore pose» — три места выхода в DRIFT (успешный pass, промах, превышение approach-лимита) и два места выхода в RECOVERY (target died в APPROACH/WINDUP).

**Quick-strike при «иди сюда» на врагов:** в strict-march check, если уже есть claimable target в lunge_trigger_range, soldier пропускает арриваль у слота и сразу `_start_charge` — «вбегает в бой» с марша (через WINDUP).

**Combat target distribution (1:1):** `_find_target_in_leash` — только незанятые скелеты в `combat_leash_radius=12м` от центра режима. `_is_target_claimed_by_other` считает других солдат в APPROACH/WINDUP/LUNGE/DRIFT (не RECOVERY). Если все цели заняты — null → squad-positioning. Каждый бьёт своего; целей меньше юнитов → лишние стоят в формации.

**Strike feedback:** `_strike_at(target)` → `Damageable.try_damage` → если выжил (`hp > 0`), `Pushable.try_push` с `strike_knockback_speed=8 м/с` Δv в направлении lunge'а на `strike_knockback_duration=0.18с`. Скелета чувствительно отбрасывает — соразмерно «молниеносному» рывку.

**Centre-resolve по squad.state** (`_resolve_squad_center`): HOLD → hold_position; ESCORT → tower.global_position; DEFEND → camp.deploy_anchor (fallback на tower если лагерь свёрнут).

**DEFEND wander-patrol:** `_tick_defend_patrol` — каждый юнит независимо берёт случайные точки на окружности `defend_patrol_radius=12м` (как у DefenderGnome.patrol_radius), идёт `defend_patrol_speed=1.2 м/с`. Не использует squad-кольцо — отряд равномерно расходится по периметру. На бой переключается из основного `_active_tick`.

#### 5.8.2.4 HandSquadAim — координатор aim'а «Идти сюда»
Дочерний узел Hand. Активируется HUD-кнопкой `«Идти сюда»` на squad-card → `Hand.set_active_category(SQUAD_AIM)` → spawn ground-кольца радиусом `aim_ring_radius=3.5м` под курсором. ПКМ — commit точки → `Camp.command_squad_hold(squad, pos)`.

**Hostile-подсветка:** каждый кадр scan'ит SKELETON_GROUP в радиусе кольца. Если найдены живые — кольцо красное (`Color(1.0, 0.25, 0.25, 0.95)`), иначе голубое. Сигнализирует: «кликнешь — отряд вбежит в эту толпу».

UI-гейт на ПКМ: `Hand.is_pointer_over_ui()` — клик по HUD не фиксируется как commit aim'а.

**Cancel:** Esc (`ui_cancel`) отменяет aim без команды. Повторный клик «Идти сюда» на той же карточке — тоже toggle-cancel.

#### 5.8.2.5 Camp API для отрядов
- `recruit_squad(soldier_type)` — гейтится `is_deployed() + can_afford(cost) + gatherer_count() ≥ squad_size + get_recruit_reserve()`. Reserve = `tent_count_alive() × RECRUIT_RESERVE_PER_TENT (=1)` — лагерь оставляет себе минимум 1 сборщика на каждую живую палатку, иначе экономика встанет (дизайнерское правило: армию строим излишком). UI расшифровывает нехватку как «оставьте сборщиков в лагере (нужно ещё N)». `get_recruit_reserve() -> int` — публичный getter, JournalPanel читает его для UX-текста.
- Конвертирует gatherer'ов на месте, создаёт Squad.
- `dismiss_squad(squad)` — гейтится `is_deployed() + ВСЕ члены в `dismiss_radius=12м` от deploy_anchor`. Spawn нового gatherer'а на каждой позиции солдата + queue_free солдата.
- `command_squad_hold(squad, pos)` / `command_squad_escort(squad)` / `command_squad_defend(squad)`.
- `cheat_summon_squad(soldier_type)` — мимо всех гейтов, спавн кольцом 2м вокруг центра лагеря (X/Z от anchor/tower, Y от global_position камп'а — иначе спавн в воздухе при tower.y=3).

#### 5.8.2.6 Recall-зона + волна вызова (Q-toggle)

`@export recall_zone_radius=20м`, `recall_wave_speed=25 м/с`. Гейтит:
- **Q-toggle отрядов:** все отряды в зоне получают `command_escort()` если хоть один сейчас не в ESCORT, иначе `command_hold(center, false)` (HOLD-soft). Отряды вне зоны игнорируются (`EventBus.squad_recall_ignored.emit`).
- **Q-toggle каравана** (`set_caravan_halted`) — гейтится зоной от camp_center к башне.
- **Pack (R-hold в DEPLOYED):** `is_tower_in_camp_recall_zone()` — отсчёт прерывается если башня вне зоны от anchor'а. Игрок может «оставить лагерь и уйти только с солдатами».

**Волна:** команда применяется с задержкой `dist / wave_speed` через `get_tree().create_timer(delay)` — ближний копейщик срывается раньше, дальний позже, точно когда фронт волны касается. HUD рисует expanding-ring через `AoeVisual.spawn_expanding_ring` (тонкий фронт `thickness=0.14` + размытый тейл с задержкой 70мс).

**Indication out-of-zone:**
- Карточка отряда: ⚠ префикс + красноватый цвет title когда вне зоны. Кнопка «За башней» disabled с tooltip'ом. Refresh раз в 0.25с (юниты двигаются без сигналов).
- На Q: красный flash карточки (`squad_recall_ignored`).
- Визуал волны: только до границы зоны — out-of-zone отряды визуально «не слышат».

#### 5.8.2.7 HUD squad-cards (правая колонка слева от RightPanel)
ScrollContainer (PRESET_RIGHT_WIDE: anchor_top=0, anchor_bottom=1) → VBoxContainer с карточками. Lazy-create на первый `EventBus.squad_created`. Каждая карточка: title + 4 кнопки («Идти сюда», «За башней», «Защищать», «Распустить»). Все с `focus_mode = FOCUS_NONE` — иначе Space на сфокусированной кнопке параллельно «нажимал» бы её (помимо cast_super).

---

### 5.9 ResourcePile — `scenes/resource_pile.tscn`, `scripts/resource_pile.gd`

**Тип корня:** `RigidBody3D` с `class_name ResourcePile`.

**Назначение:** куча ресурсов на карте. Гномы забирают по 1 единице через `take_one()` в фазе сбора. Параллельно куча — полноценный физический предмет: рука может схватить её и кинуть, башня и Item могут толкнуть, slam ломает по hp. Реализует **три** контракта одновременно: `Damageable`, `Pushable`, `Grabbable`.

Поддерживает **4 типа ресурса** (Этап А — простые pile'ы): WOOD / STONE / IRON / FOOD + GENERIC (старый зелёный для обратной совместимости). Тип задаёт дефолтный визуал (цвет, форма, размер); если `pile_color/pile_size/pile_shape` оставлены дефолтными (`Color.BLACK / Vector3.ZERO / AUTO`) — берётся пресет, иначе экспорты переопределяют.

**Этапы Б/В отложены:** многоэтапность дерева (стоит → trunk → 3 logs) и `interaction_time` на pile'е (гном «рубит/копает» N секунд перед `take_one`) — не сделано, на функциональность сбора это не влияет (wood-pile = «бревно» с units=3, take_one мгновенный).

**Дочерние узлы:**
- `MeshInstance3D` — пустой в `.tscn`, в `_apply_visual` создаётся `BoxMesh` / `CylinderMesh` / `SphereMesh` по `pile_shape`.
- `CollisionShape3D` — пустой в `.tscn`, в `_apply_shape` создаётся `BoxShape3D` / `CylinderShape3D` / `SphereShape3D` под форму.

**Enum'ы:**

```gdscript
enum ResourceType { GENERIC, WOOD, STONE, IRON, FOOD }
enum PileShape { AUTO, BOX, CYLINDER, SPHERE }
```

`PileShape.AUTO` — берётся дефолт от типа. Остальные — явное переопределение формы независимо от типа (например, food-куча в виде BOX'а вместо стандартной сферы).

**Дефолтные визуалы по `resource_type`** (в `_defaults_for_type`):

| Тип | Цвет | Размер | Форма |
|---|---|---|---|
| WOOD | коричневый `(0.45, 0.28, 0.15)` | `(0.5, 1.4, 0.5)` | CYLINDER (бревно вертикально) |
| STONE | серый `(0.55, 0.55, 0.55)` | `(0.9, 0.7, 0.9)` | BOX (каменный блок) |
| IRON | стальной `(0.35, 0.38, 0.42)` | `(0.8, 0.4, 0.8)` | BOX (приплюснутая куча оружия/доспехов) |
| FOOD | оранжево-красный `(0.85, 0.35, 0.25)` | `(0.7, 0.7, 0.7)` | SPHERE (фруктовый куст/ягоды) |
| GENERIC | зелёный `(0.4, 0.75, 0.3)` | `(0.6, 0.6, 0.6)` | BOX (старый pile) |

В `_apply_visual` / `_apply_shape` через `match` создаётся правильный mesh + shape. Размер передаётся как `Vector3`, для CYLINDER берётся `radius = s.x * 0.5, height = s.y`; для SPHERE — `radius = s.x * 0.5`.

**Слой/маска (в `.tscn`):** `collision_layer = Layers.ITEMS` (бит 2), `collision_mask = Layers.MASK_ALL_GAMEPLAY = 31`. Та же раскладка, что у `Item`.

**Экспорты:**
- `resource_type: ResourceType = GENERIC` — тип ресурса. Используется для дефолтных визуалов и (в будущем) для UI/HUD/Camp-инвентаря, чтобы агрегировать «сколько у нас дерева/камня».
- `units: int = 5` — запас ресурсов; декрементируется при `take_one()`. На 0 — `queue_free`.
- `hp: float = 30.0` — здоровье. Урон от руки/slam'а. На 0 — `queue_free` независимо от `units`.
- `pile_color: Color = BLACK` — переопределить цвет. `BLACK` = «не задан, бери дефолт от типа».
- `pile_size: Vector3 = ZERO` — переопределить размер. `ZERO` = «бери дефолт от типа».
- `pile_shape: PileShape = AUTO` — переопределить форму. `AUTO` = «бери дефолт от типа».
- `highlight_color: Color`, `highlight_intensity: float` — emission при подсветке кандидата (Grabbable).
- Унаследованный `mass: float = 0.5` (в `.tscn`) — лёгкая, грабится рукой при `max_lift_mass = 10`.

**Сигналы:** `damaged(amount: float)`, `destroyed`. Re-emit'ятся в `EventBus.item_damaged` / `EventBus.item_destroyed` (как у Item — UI/счёт не различает Item и ResourcePile).

**Константа:** `GROUP := &"resource_pile"` — гномы сканируют через `get_tree().get_nodes_in_group(ResourcePile.GROUP)`.

**`_ready`:**
- `add_to_group(GROUP)`.
- `Damageable.register(self)`, `Pushable.register(self)`, `Grabbable.register(self)` — три контракта подряд.
- `_apply_visual()`, `_apply_shape()` — создают уникальные ресурсы.
- Re-emit на EventBus.

**Контракты:**

| Контракт | Метод | Поведение |
|---|---|---|
| Damageable | `take_damage(amount)` | Декремент `hp`, эмит `damaged`. На `hp ≤ 0` — `_dying = true` + `destroyed.emit()` + `queue_free()`. Защита через `_dying` флаг + `is_queued_for_deletion()`. |
| Pushable | `apply_push(velocity_change, _duration)` | `apply_central_impulse(velocity_change × mass)`. **Return при `freeze`**. |
| Grabbable | `set_highlighted(value)` | Toggle emission. Дёргается рукой на смене кандидата. |

**Идемпотентность смерти — `_dying: bool` флаг.** `take_damage` и `take_one` могут привести pile к уничтожению **независимо в одном кадре** (например, slam добивает hp до 0, гном параллельно вызывает `take_one` на `units=1`). `queue_free()` сам по себе идемпотентен, но `destroyed.emit()` — нет, и без флага EventBus получал бы двойной `item_destroyed` → UI/счётчики реагировали бы дважды. Флаг `_dying` ставится в начало любой ветки перед эмитом и проверяется на входе в обе функции:

```gdscript
func take_damage(amount: float) -> void:
    if _dying or is_queued_for_deletion() or amount <= 0.0:
        return
    hp -= amount
    damaged.emit(amount)
    if hp <= 0.0:
        _dying = true
        destroyed.emit()
        queue_free()


func take_one() -> bool:
    if _dying or freeze or units <= 0 or is_queued_for_deletion():
        return false
    units -= 1
    if units == 0:
        _dying = true
        destroyed.emit()
        queue_free()
    return true
```

`freeze` (рука держит) → `false`. Гном считает кучу «занятой» и через `_on_pile_lost` уходит искать другую.

**Размещение в `main.tscn`:** через `ResourceZone`-расставлятели (см. §5.9.1) — дизайнер ставит зону в нужное место, выбирает тип/count/size, на старте сцены зона разбрасывает pile'ы. Ручной список pile-инстансов больше не используется (раньше было 20 куч в трёх кольцах от origin).

**Зависимости:** `Damageable`, `Pushable`, `Grabbable`, `EventBus`, `Layers`. Не знает Gnome/Camp напрямую — связь через группу и публичные поля.

---

### 5.9.1 ResourceZone — `scenes/resource_zone.tscn`, `scripts/resource_zone.gd` (`@tool`)

**Тип корня:** `Node3D` с `class_name ResourceZone`. По паттерну `SpawnZone` (см. §5.5.5) — `@tool`-нода-расставлятель: дизайнер бросает её в сцену, в инспекторе задаёт `resource_type / count / size`, на `_ready` сцены зона спавнит `count` инстансов `ResourcePile` в случайных точках внутри своего прямоугольника.

**Назначение:** убрать ручную расстановку 20+ куч по карте. Дизайнерский цикл: drag ResourceZone → type/count/size → save. На запуске сцены — pile'ы появляются, индикатор зоны исчезает.

**Дочерние узлы:**
- `Mesh` — `MeshInstance3D` со `BoxMesh` (1×0.04×1), масштабируется сеттером `size` до `(size.x, 1, size.y)`. Виден **только в редакторе**, в `_ready` (не editor_hint) скрывается.

**Экспорты:**
- `size: Vector2 = Vector2(20.0, 20.0)` — полные размеры по локальным X/Z (с сеттером, мгновенно перерисовывает индикатор в редакторе через `_refresh_visual`).
- `resource_type: int` (`@export_enum("Generic","Wood","Stone","Iron","Food")`, дефолт 1=Wood) — тип ресурса. Маппинг 1:1 с `ResourcePile.ResourceType`. Дублируется как int (а не reference на enum) — `@export`-у enum нужен прямой type-reference, и cyclic-import между `ResourceZone ↔ ResourcePile` создаст проблему.
- `count: int = 8` (range 1-1000) — сколько pile'ов спавнить. Верхний лимит поднят с 100 для плотных лесов и крупных каменоломен; на 1000 при `min_spacing=1.5` зоне нужна площадь хотя бы ~50×50м, иначе rejection sampling выдыхается и кучи пойдут внахлёст.
- `units_per_pile: int = 5` (range 1-50) — `units` каждого спавненного pile'а.
- `min_spacing: float = 1.5` — минимальная дистанция между соседними кучами (rejection sampling, до 10 попыток на pile; 0 = выключить фильтр).
- `pile_scene: PackedScene` — что спавнить. Дефолт в `resource_zone.tscn` — `res://scenes/resource_pile.tscn`.
- `spawn_root_path: NodePath` — куда добавлять. Пусто → `current_scene` (чтобы pile'ы пережили возможное удаление зоны или её родителя).

**`_ready`-логика:**
- В editor-hint: только `_refresh_visual()` — индикатор виден дизайнеру.
- В рантайме: `_spawn_instances.call_deferred()` + скрыть `Mesh`. **`call_deferred` важен** — `_ready` вызывается во время setup'а родительской сцены, и Godot не даёт `add_child` пока parent «is busy setting up children». К моменту deferred-вызова дерево полностью собрано, `add_child` проходит.

**`_spawn_instances`:**
- **POI-фильтр**: точки внутри круга палаток вокруг костра (radius = `QuestActor.safe_radius`, ~12м) отбрасываются — кучи там перекрывались бы с палатками. Camp `wave_safe_radius=32м` и любой другой WaveDirector-фильтр НЕ применяются — дизайнер сам решает на каком расстоянии от лагеря разместить кучи (кроме самой плотной зоны костра). На старте `_spawn_instances` снимает срез POI в кеш (позиция + r²) — экономия на per-attempt `get_tree().get_nodes_in_group()`.
- Цикл по `count`, для каждого — `_pick_position(placed_positions, spacing², poi_circles)` (rejection sampling до 10 попыток внутри прямоугольника `±size/2` через локаль → `global_transform * local`, поворот зоны вокруг Y учитывается). Точки в POI-круге проматываются `continue`'ом. Если за 10 попыток ни одна не выпала вне POI / соблюдая spacing — берётся последняя случайная точка (визуальный нахлёст / попадание в круг возможны, но это редкость при разумно поставленной зоне).
- На каждом инстансе — назначить `resource_type` и `units` **до** `add_child` (чтобы `_ready` применил правильный визуал сразу). Позиция выставляется после `add_child`, затем рандомная Y-rotation для визуального разнообразия.
- **Жёсткий контракт `pile_scene`:** если `pile_scene.instantiate()` возвращает не-`ResourcePile` (дизайнер случайно подменил сцену) — `push_error` + `queue_free` инстанса + `continue`. Без этой проверки тип/units тихо не назначались бы и в дереве появлялись зелёные generic-pile'ы с дефолтным `units=5` — причина не очевидна; теперь сразу видно в консоли.

**Визуальный индикатор в редакторе:** перекрашивается в цвет типа (массив `_TYPE_COLORS`: зелёный/коричневый/серый/стальной/оранжевый) — дизайнер видит зоны разного типа без чтения инспектора.

**Зависимости:** `ResourcePile` (для `resource_type`/`units` присвоения и instanceof-проверки), `current_scene` для root-fallback.

---

### 5.10 Модули (Camp/Tower upgrades) — `camp_module.gd`, `mount_slot.gd`

Слот-модульная подсистема апгрейдов: модули (`CampModule extends RigidBody3D`) переносятся рукой и ставятся в слоты (`MountSlot extends Node3D`). Слот живёт на башне (наверху меша) или в центре развёрнутого лагеря. Подсистема нужна, чтобы добавлять защитные/утилитарные модули (турель, алтарь, кузница, …) без правок Hand/Tower/Camp — каждый новый тип модуля просто наследует `CampModule` и переопределяет `_on_mounted/_on_unmounted/_physics_process`.

#### CampModule — `scripts/camp_module.gd`

**Тип корня:** `RigidBody3D`. Регистрируется в `Grabbable` группе → рука хватает по тому же контракту, что и Item/ResourcePile.

**Состояния:**
1. **Свободный** (`_slot=null`, `freeze=false`, `collision_layer=ITEMS`) — лежит на земле как обычный RigidBody.
2. **В руке** (`_slot=null`, `freeze=true`, `collision_layer=ITEMS`) — Hand задаёт freeze и позицию через `_update_held_position`.
3. **Mounted** (`_slot=Slot`, `freeze=true`, `collision_layer=MOUNTED_MODULE`) — Slot задаёт позицию каждый физкадр, вызывает виртуал `_module_tick`/работу модуля. Слой переключается на `MOUNTED_MODULE` (бит 6 = 64), чтобы тауэр (mask=31) не видел смонтированный модуль как стену — иначе touching-контакт «башня сверху, турель сидит на ней» спамил бы wall-collision-логи. Hand.GrabArea (mask=82 = ITEMS|ENEMIES|MOUNTED_MODULE) всё равно ловит, так что снять модуль с башни рукой можно.

**Публичный API:**
- `is_mounted() -> bool`, `get_slot() -> Node`.
- `attach_to_slot(slot)` / `detach_from_slot()` — вызываются **только** Slot'ом, не вручную. `attach` ставит `freeze=true`, обнуляет velocities, эмитит `mounted`. `detach` снимает ссылку и эмитит `unmounted`. **Freeze сама не сбрасывает** — это решает Slot (см. ниже).

**Виртуальные хуки:**
- `_on_mounted(slot)` — подкласс начинает свою работу (стрельба, аура, …).
- `_on_unmounted(old_slot)` — подкласс останавливает.
- `set_highlighted(value)` — стандартный Grabbable-контракт; базовая реализация работает с `_material` (StandardMaterial3D), подкласс должен установить ссылку.

#### MountSlot — `scripts/mount_slot.gd`

**Тип корня:** `Node3D`. Кладётся как ребёнок Tower/Camp. Принимает только модули, упавшие из руки в его `snap_radius`.

**Экспорты:**
- `module_offset: Vector3 = (0, 0, 0)` — куда конкретно ставится центр модуля относительно слота. На башне `(0, 0.35, 0)`, чтобы цилиндр турели сидел на верхушке башни. Каждый слот настраивает оффсет под высоту своего модуля.
- `snap_radius: float = 1.5` — горизонтальный радиус, в котором релиз модуля рукой засчитывается как монтаж.
- `enabled: bool = true` (с сеттером) — выключение слота с занятым модулем вызывает `_drop_mounted()` → модуль падает с гравитацией. Camp использует это в фазе CARAVAN_FOLLOWING.

**Связь с Hand — через EventBus:**
- На `EventBus.hand_grabbed(item)` слот проверяет: если `item == _mounted` → `_release_to_hand()` (отдаём руке, freeze не трогаем).
- На `EventBus.hand_released(item, velocity)` слот проверяет: если `enabled && _mounted=null && item is CampModule && distance ≤ snap_radius` → `_mount(module)`.

**Два пути размонтажа:**
1. `_release_to_hand()` — игрок схватил. Hand уже владеет freeze (выставил true в `_attach`); слот только освобождает свою ссылку.
2. `_drop_mounted()` — слот выключен (Camp свёрнут). Сам сбрасывает `freeze=false`, чтобы модуль упал.

**Каждый физкадр:** если `_mounted ≠ null` — пишем `_mounted.global_position = global_position + module_offset`. Так модуль автоматически следует за двигающимся слотом (на башне) или фиксируется на anchor'е лагеря.

**Re-emit на EventBus:** `module_mounted(module, slot)` / `module_unmounted(module, slot)` — для UI/звука/будущих апгрейдов кампа.

#### OctagonTurret — `scenes/octagon_turret.tscn`, `scripts/octagon_turret.gd`

Первый конкретный модуль. **Тип корня:** `RigidBody3D` через `CampModule`. Восьмигранный цилиндр (`CylinderMesh radial_segments=8`, r=0.45, h=0.7), масса 3.0, на слое `ITEMS=2` — рука ловит как обычный Grabbable.

**Поведение:**
- Когда mounted в слоте — каждый физкадр тикает `_fire_timer`. Когда истёк, `_find_target()` через `PhysicsShapeQueryParameters3D` (sphere `attack_radius=12м`, `target_mask = Layers.ENEMIES = 16`) ищет ближайшего Damageable на слое врагов и `_fire_at(target)`.
- Стрельба круговая (omnidirectional) — нет фронта, нет «поворачивания дула», цель выбирается просто по близости.
- Между выстрелами — случайная пауза `randf_range(fire_interval_min=0.4, fire_interval_max=0.9)`. Несколько турелей не залпуют синхронно.
- Когда не mounted (свободный или в руке) — `_physics_process` сразу возвращается, стрельбы нет.

**Балансные параметры:**
- `arrow_damage: float = 35.0` — `≥ skeleton.hp=30` → ваншот по требованию задачи.
- `arrow_speed: float = 22.0` — стрелы баллистические (см. Arrow), угол выбирается автоматически.
- `attack_radius: float = 12.0` (default; в `main.tscn` override на 22.0). После `intersect_shape` тот же explicit radius-фильтр что и в DefenderGnome — Godot подмешивает AABB-результаты вне sphere.

**Цели:** маска `ENEMIES` (бит 4 = 16). Гномы (ACTORS=4) и башня (ACTORS=4) **не попадают** под огонь, дружественный fire исключён.

#### Arrow — `scenes/arrow.tscn`, `scripts/arrow.gd`

Баллистический проджектайл. **Тип корня:** `Node3D` (не RigidBody — ручное интегрирование velocity по гравитации, дешевле). Дочерний `Area3D` с `CollisionShape3D` детектит попадания.

**Слой/маска:** Area3D `collision_layer=0`, `collision_mask=Layers.MASK_FRIENDLY_PROJECTILE = 145` (`TERRAIN | ENEMIES | COLD_ENEMY`). Стрелы пролетают сквозь Items, башню, гномов, палатки — не задевают своих. COLD_ENEMY в маске сейчас избыточен (FAR-скелеты исключены из broad-phase, см. Skeleton._apply_lod_physics_mode), но на практике стрелы летят на ≤22м от Camp = всегда NEAR/MID область, FAR-скелетов в полётной траектории не бывает.

**Параметры (экспорты):**
- `damage: float`, `speed: float = 22.0`.
- `gravity: float = 6.0` — настильнее мирового 9.8. На v=22 максимальная горизонтальная дальность `v²/g ≈ 80м`.
- `lifetime: float = 4.0` — до queue_free, если ничего не поймала.

**Баллистика (`_compute_launch_velocity`):**

Решение задачи о броске с фиксированным `|v| = speed` и гравитацией по −Y. Формула низкой дуги: `tan(α) = (v² − √disc) / (g·d)` где `disc = v⁴ − g·(g·d² + 2·dy·v²)`. Из двух решений (низкая/высокая дуга) берётся низкая — короткое время полёта, более «настильный» визуал.

Если `disc < 0` — цель вне досягаемости с заданной speed; фоллбэк: прямой выстрел в направлении цели (стрела упадёт по дороге, в логе будет видна как промах в землю).

**Цикл:**
- `setup(source_pos, target_pos)` от стрелка → стрела ставится в source, `_compute_launch_velocity` решает баллистику, `look_at` ориентирует меш носом вдоль `_velocity`.
- `_physics_process(delta)`: `_velocity.y -= gravity * delta; global_position += _velocity * delta`. Каждый кадр `_orient_along_velocity` пересчитывает поворот меша — стрела сначала смотрит вверх, потом носом вниз. На `_life ≥ lifetime` queue_free.
- `Area3D.body_entered`: идемпотентный `_consumed`-флаг защищает от двойного срабатывания. Если тело — Damageable, наносим урон через `Damageable.try_damage`. Затем queue_free независимо.

#### Слоты в проекте

- **Tower** — `MountSlot` под именем `MountSlot` в [tower.tscn](scenes/tower.tscn), transform y=3 (верх box'а), `module_offset=(0, 0.35, 0)`, `snap_radius=2.0`, `enabled=true`.
- **Camp** — `MountSlot` под именем `CenterMountSlot` в [camp.tscn](scenes/camp.tscn), стартует `enabled=false`. Camp.gd при `_start_deploy` вычисляет `ground_y = _ground_y_at(_parts[0], _deploy_anchor)`, ставит slot в `(anchor.x, ground_y, anchor.z)` и `enabled=true`. При `_finalize_pack` — `enabled=false` (модуль автоматически дропается).

#### Расширение

Добавить новый модуль (магический алтарь, ремонтная кузница, …):
1. Скрипт `scripts/altar.gd`: `class_name Altar extends CampModule`, override `_on_mounted/_on_unmounted/_physics_process`.
2. Сцена `scenes/altar.tscn`: RigidBody3D с этим скриптом, mass < 10, layer ITEMS, своя визуализация.
3. Никаких правок Hand/MountSlot/Tower/Camp не нужно — слоты примут любого CampModule по тому же контракту.

Если новому модулю нужна другая высота — настроить `module_offset` на слотах под него (можно сделать слот-специфичный или ввести `placement_offset` на самом модуле).

### 5.11 POI/Quest system — POI markers, QuestActor (POI-зона), WaveSchedule, QuestProgress

POI = костёр. Одна нода [QuestActor] совмещает три вещи: квест-выдатчик, визуал костра и параметры **POI-зоны** для геймплея «лагерь + осада» (этап 42). Линейная цепочка сюжетных заданий: 3 POI на карте, прогресс продвигается через **Журнал → вкладку «Читы» → «Продвинуть квест»** (`QuestProgress.advance()`). Раньше был на клавише Q — освобождена под `caravan_halt_toggle`. Описания заданий (`quest_title`, `quest_description`) хранятся **на самих QuestActor**-нодах сцены, журнал собирает их через группу `POI_GROUP`, вкладка «Задания» рендерит карточки по 3 состояниям (LOCKED / ACTIVE / COMPLETED).

#### POI markers — `scenes/poi_marker.tscn`

**Тип корня:** `Node3D` (без скрипта).

**Назначение:** статический визуальный маркер точки интереса — небольшой круг тёмной золы под костром (top/bottom_radius≈0.95, height=0.04, грязно-серый, без emission). Раньше был большой жёлтый плоский цилиндр r=2.5, height=0.6 — заменили на скромное «пятно» (`516ddbf` → текущая версия), потому что весь визуал POI теперь несёт `QuestActor` (костёр сверху). Используется для двух разных целей:

1. **Quest-точка.** В `main.tscn` под `PointsOfInterest/` лежат три POI: `Poi_ESE`, `Poi_Heart`, `Poi_SW`. У каждого ребёнок `Actor` (см. ниже), на нём сидит `quest_order`.
2. **POI-зона.** Сам `Actor` (QuestActor) регистрируется в группе `poi_zone`, его `safe_radius` используется Camp'ом (deploy-gate), WaveDirector'ом (фоновый safe-фильтр + поиск POI по anchor) и ResourceZone (отбрасывание точек в круге костра/палаток). См. §5.5.4 и описание QuestActor ниже.

#### QuestActor — `scenes/quest_actor.tscn`, `scripts/quest_actor.gd`

**Тип корня:** `Node3D` с `class_name QuestActor`.

**Назначение:** «актор» квестов на POI. Визуал — **костёр** (3 полена-BoxMesh крест-накрест в три уровня + статичное FlameCore + 2× GPUParticles3D пламени и дыма + OmniLight3D). Состояние из `QuestProgress` управляет режимом костра, перекрас — по сигналу `EventBus.quest_advanced`:
- **locked** — потухший: тлеющие угли (тёмно-оранжевая emission поленьев energy=0.05), струйка дыма (5 частиц), без пламени, свет выключен.
- **active** — горящий: яркое оранжевое пламя (FlameCore visible + 24 GPUParticles), активный дым (14 частиц), тёплый свет (energy=1.6, color=оранжевый).
- **completed** — отгоревший с магическим следом: зелёно-голубоватая emission поленьев, минимум дыма (3 частицы), тусклый зелёный свет (energy=0.7). Символика «закрыто», в отличие от обычного потухшего костра.

**Структура сцены:**
- `Logs/Log1..Log3` — `MeshInstance3D` с общим `BoxMesh` (size=0.7×0.14×0.14), три уровня крест-накрест:
  - `Log1` — вдоль X на y=0 (базовый).
  - `Log2` — повёрнут 90° вокруг Y, вдоль Z, на y=0.14 (поверх первого).
  - `Log3` — повёрнут 45° вокруг Y, на y=0.28 (третий уровень).
  Поверх Logs — корневой transform Y=0.07, чтобы низ первого полена сидел на полу. **Material_log общий в `.tscn`**, но в `_ready` `_clone_log_material` делает per-instance копию через `(_logs_root.get_child(0).material_override).duplicate()` и переназначает на все полена — иначе все QuestActor'ы на сцене делили бы один override и emission переключался бы у всех разом.
- `FlameCore` — `MeshInstance3D` со `SphereMesh` (radius=0.18, scale Y=1.4) на y=0.45, материал `transparency=ALPHA, shading_mode=UNSHADED, emission_energy=4.0`. Видим только в active-состоянии. Это статичное «ядро» пламени — частицы FlameParticles рисуются поверх.
- `FlameParticles` — `GPUParticles3D` на y=0.3, `amount=24`, `lifetime=0.8с`. ProcessMaterial: emission sphere r=0.12, gravity=(0, 1.2, 0) (антигравитация → летит вверх), velocity 0.6..1.2 м/с, **`particle_flag_rotate_y = true`** + `angle_min/max = ±90°` (рандомный начальный поворот, чтобы quad'ы из draw_pass не были параллельны), `scale_min/max = 0.18/0.28` (компенсация под объёмный smoke_mesh), scale_curve 1.0 → 0.05 (растёт и схлопывается), color_ramp ярко-жёлтый → оранжевый → тёмно-красный с alpha 1→0. **`draw_pass_1 = res://resources/smoke_mesh.tres`** — тот же объёмный mesh что у дыма (без него quad'ы лежат плоскими «жёлтыми кубиками»). `material_override` — отдельный `StandardMaterial3D` (UNSHADED, alpha=0.85, emission orange energy=2.5) для оранжевого цвета.
- `SmokeParticles` — `GPUParticles3D` на y=0.45, `amount=10` (динамически: 5/14/3 по состоянию), `lifetime=2.95с`, `trail_lifetime=0.2`, `cast_shadow=OFF`. ProcessMaterial: emission sphere r=0.18, gravity=(0.05, 2.0, 0) (медленно вверх со сносом, в active взлетает выше), velocity 0.4..0.7 м/с, `particle_flag_rotate_y=true`, `angle_min/max=±90°`, `scale_min/max=0.4` (фиксированный), scale_curve 0.27 → 1.0, alpha_curve 0→1 (плавное появление), `hue_variation_min/max=0..0.02` (лёгкий разброс оттенков), `turbulence_noise_strength=0.05, scale=0.1` (мягкие завихрения). **`draw_pass_1 = res://resources/smoke_mesh.tres`**, **`material_override = res://resources/smoke_material.tres`** (см. ниже).
- `Light` — `OmniLight3D` на y=0.5, range=7м, attenuation=1.5. Цвет/энергия меняются по состоянию.

**Smoke shader pipeline** — стилизованный billboard-volumetric:
- **`resources/smoke.gdshader`** (`spatial`, `depth_prepass_alpha`). В `fragment()`: UV скроллится через `TIME * Vor_Speed`, сэмплируется из voronoi-нойза → индексирует `Alpha_Curve` для финальной альфы. `COLOR.a` (от `color_ramp` GPUParticles) индексирует `Color_Gradiant` по жизни частицы. `EMISSION = Emmision_Power × Color × Gradiant`.
- **`resources/smoke_mesh.tres`** (190KB, 9408 индексов) — взят из [Loop-Box/Stylized-Smoke-For-Godot4.5](https://github.com/Loop-Box/Stylized-Smoke-For-Godot4.5). Объёмная сетка из quad'ов под разными углами; в паре с `particle_flag_rotate_y=true` даёт billboard-эффект во все стороны (без него обычный QuadMesh с шейдером превращается в плоские «чёрные коробки» в 3D-перспективе — баг был в первой итерации).
- **`resources/smoke_material.tres`** — `ShaderMaterial`, params: `Vor_Scale=0.8, Vor_Speed=0.2, Color=(1,1,1,0.6), Alpha_Clip=0.0, Emmision_Power=1.0, Fernal_Power=1.0`. `Color.alpha=0.6` снижает плотность — раньше дым давил визуал, после уменьшения читается как лёгкая струя.
- Подключённые текстуры:
  - `smoke_color_gradient.tres` — `GradientTexture1D` тёмный→серый→светло-серый (offsets 0/0.4/1, colors `(0.05,0.05,0.06)` → `(0.45,0.45,0.5)` → `(0.85,0.85,0.92)`). Индексируется по `COLOR.a` от ParticleProcessMaterial.color_ramp.
  - `smoke_voronoi_noise.tres` — `NoiseTexture2D` 256×256 с `FastNoiseLite type=CELLULAR (4)`, frequency=0.04, seamless=true.
  - `smoke_alpha_curve.tres` — `CurveTexture` peak в середине (curve points: `(0,0)`, `(0.5,1)`, `(1,0)`) → создаёт «клочья» дыма вместо равномерного облака.

**Логика управления состоянием в `quest_actor.gd`:**

```gdscript
func _refresh_visual() -> void:
    if QuestProgress.is_completed(quest_order):
        _apply_completed()
    elif QuestProgress.is_active(quest_order):
        _apply_active()
    else:
        _apply_locked()
```

Каждый `_apply_*` переключает: `_log_material.emission` (цвет+energy), `_flame_core.visible`, `_flame_particles.emitting`, `_smoke_particles.emitting/amount`, `_light.light_color/light_energy`. См. [quest_actor.gd](scripts/quest_actor.gd).

**Экспорты:**
- Quest:
  - `actor_id: StringName` — уникальный идентификатор для будущих скриптовых триггеров (диалог, выдача награды, ивенты в EventBus). Сейчас не используется кроме логов.
  - `quest_order: int = 0` — порядковый номер в линейной цепочке (0=первый, 1=второй, …).
- POI zone (этап 42):
  - `safe_radius: float = 12.0` — радиус, в котором лагерь может развернуться вокруг костра. Должен быть ≥ `Camp.deploy_radius` (8м), иначе кольцо палаток выйдет за пределы «зоны костра». Также используется WaveDirector'ом как safe-радиус для фонового спавна (см. §5.5.4).
  - `wave_schedule: WaveSchedule` (nullable) — расписание осады. Если null/пустое — POI «мирный»: лагерь развернётся, но волны не идут.

**Public API (POI-роль):**
- `is_within_safe_radius(world_pos: Vector3) -> bool` — XZ-расстояние ≤ safe_radius. Camp использует для deploy-gate'а.
- `get_wave_schedule() -> WaveSchedule` — для WaveDirector'а на `camp_deployed`.

**Группа:** `add_to_group(QuestActor.POI_GROUP)` (= `&"poi_zone"`) в `_ready`. Camp ищет ближайший POI через `get_tree().get_nodes_in_group(POI_GROUP)`.

**Подписка:** `EventBus.quest_advanced.connect(_on_quest_advanced)` — все 3 актора слушают, переключают режим костра одновременно при продвижении прогресса.

**Использование в `main.tscn`:** под каждым `Poi_*` инстанс `quest_actor.tscn` с уникальным `actor_id` (`"ese"`, `"heart"`, `"sw"`), `quest_order = 0/1/2` соответственно и (опционально) `wave_schedule` — отдельный `.tres` для разной сложности на разных POI.

#### WaveSchedule + WaveStage — `scripts/wave_schedule.gd`, `scripts/wave_stage.gd`

**Тип:** оба — `Resource` (с `class_name`).

**Назначение:** дизайнерский «расписание осады». Прикладывается в инспекторе костра (`QuestActor.wave_schedule`). Когда лагерь развёртывается на POI, WaveDirector проигрывает массив `WaveStage` по порядку — это даёт нелинейный рост угрозы во времени без массива магических чисел в коде.

**`WaveStage` поля (одна стадия):**
- `duration: float = 60.0` — сколько играет эта стадия (с). По истечении → переход в `stages[i+1]`. Финальная стадия залипает.
- `wave_interval: float = 60.0` — период между волнами в этой стадии (с).
- `skeletons_per_wave: int = 5` — размер пачки в одной волне.

**`WaveSchedule` поля:**
- `stages: Array[WaveStage]` — массив стадий по порядку. Если пуст — POI «мирный».

**`WaveSchedule.get_stage(index)`** клампит до последней — это и даёт «залипание» финальной стадии без специальной ветки в WaveDirector'е.

**Пример (стандартная сложность):**
- `stages[0]: duration=60, interval=60, per_wave=5`  — «разведка» (5 скел/мин).
- `stages[1]: duration=90, interval=45, per_wave=8`  — «давление» (~10 скел/мин).
- `stages[2]: duration=∞,  interval=30, per_wave=12` — «осада» (24 скел/мин).

Лёгкие POI (стартовые) могут иметь пологое расписание, поздние — агрессивное. Все параметры в `.tres` ресурсах.

#### QuestProgress — `scripts/quest_progress.gd` (autoload)

**Тип корня:** `Node`, autoload с именем `QuestProgress`.

**Назначение:** глобальное состояние линейного прогресса сюжета. `current_index` указывает на активного актора:
- акторы с `quest_order < current_index` — **completed**;
- с `quest_order == current_index` — **active**;
- с `quest_order > current_index` — **locked**.

**API:**
- `current_index: int = 0` — публичная переменная, рантайм-чтение/запись.
- `is_active(order)`, `is_completed(order)`, `is_locked(order)` — предикаты для QuestActor.
- `advance() -> void` — `current_index += 1`, эмит `EventBus.quest_advanced(current_index)`.

**Продвижение прогресса:** через `QuestProgress.advance()`. Дёргается из чита Журнала «Продвинуть квест» (Tab.DEBUG) до появления настоящих геймплейных триггеров (диалог завершён / предмет принесён / монстр убит). Старого `_unhandled_input`-биндинга на Q больше нет — клавиша теперь под halt-режим каравана.

---

### 5.12 Магия — `SpellSystem` autoload, `HandSpell` координатор, заклинания

Система магии — отдельная категория действий руки, параллельная физическим (Slam/Flick). Состоит из трёх слоёв: `SpellSystem` (источник истины о разблокировках/уровнях), `HandSpell`-координатор + подмодули отдельных заклинаний (`HandSpellFireball`, `HandSpellFirestorm`), и runtime-снаряды (`Fireball`, `BurnPatch`, общий `AoeVisual` helper для VFX-взрыва).

#### Hand.Category

`Hand` имеет enum `Category { PHYSICAL, MAGIC }` и поле `active_category` (default PHYSICAL). Equip-биндинги переключают:
- `equip_slam` (1), `equip_flick` (2) → `PHYSICAL` через `HandPhysicalActions._handle_input`.
- `equip_fireball` (3), `equip_firestorm` (4) → `MAGIC` через `HandSpell._handle_input`.

Equip-биндинги слушаются всегда, остальной ввод гейтится по категории:
- ЛКМ-граб — работает в любой категории (можно тащить ящик и параллельно кастовать ПКМ).
- ПКМ-action в `PHYSICAL` → Slam/Flick; в `MAGIC` → cast активного заклинания.
- Удерживаемый предмет в руке блокирует ПКМ-действия (и физические, и магические) — рука занята. `Hand.is_holding()` — общий guard.
- При смене категории на MAGIC активный Flick (если был) принудительно отпускается — иначе hold-state потерял бы кнопку отпускания (ПКМ ушла в каст фаербола).

Сигнал `Hand.category_changed(new_category)` — для подмодулей-слушателей.

#### Tower.mana

Магия списывает ману с **башни** (Tower), не с руки. Tower имеет:
- `@export var max_mana = 100`, `@export var mana_regen_rate = 10` (ед/сек).
- `var mana` (current), сетится в `_ready` = `max_mana`, регенится в `_physics_process` до cap'а.
- `try_consume_mana(amount) -> bool` — атомарно списывает (false если не хватает, не идёт в минус).
- Сигналы `health_changed(current, max)`, `mana_changed(current, max)` + re-emit на `EventBus.tower_health_changed` / `tower_mana_changed`.

Физические действия руки (Slam/Flick/grab) маны не требуют — это сознательное разделение «лёгкая физика / дорогая магия».

#### SpellSystem (autoload)

`scripts/spell_system.gd`. Источник истины о состоянии магии — какие заклинания разблокированы и на каком уровне прокачки.

**Каталог `SPELL_CATALOG`** — Dictionary `id (StringName) → metadata`:
- `name`, `description`, `icon_color`.
- `unlocked_by_default: bool` — открывается на _ready или требует unlock.
- `unlock_cost: Dictionary` — `ResourceType → amount` (обычно `PAGE` — см. ниже).
- `levels: Array[Dictionary]` — параметры по уровням. Индекс 0 = базовый (выдаётся при unlock'е), 1+ — после апгрейдов. Поля level-data специфичны для конкретного заклинания (для fireball: `damage`/`radius`/`cooldown`/`mana_cost`/`burn_*`).
- `upgrade_costs: Array[Dictionary]` — стоимость каждого следующего уровня. `upgrade_costs[i]` — цена перехода `level i → i+1`.

**State:**
- `_unlocked: Dictionary` (id → true) — инициализируется на `_ready` по `unlocked_by_default`.
- `_levels: Dictionary` (id → int, 0 = базовый) — присутствует только для разблокированных.

**API:**
- `is_unlocked(id) -> bool`, `get_level(id) -> int`.
- `get_spell_data(id) -> Dictionary` (полный каталог-эntry), `get_current_level_data(id) -> Dictionary` (параметры текущего уровня).
- `can_upgrade_further(id) -> bool`, `get_next_upgrade_cost(id) -> Dictionary`.
- `try_unlock(id) -> bool`, `try_upgrade(id) -> bool` — списывают ресурсы через `Camp.try_spend()`, эмитят `EventBus.spell_unlocked` / `spell_upgraded`.

Конкретные подмодули руки (`HandSpellFireball`, `HandSpellFirestorm`) при касте читают параметры через `SpellSystem.get_current_level_data(id)` и используют их **поверх @export-fallback'а** — single source of truth для gameplay-балансовых полей.

#### ResourcePile.ResourceType.PAGE

Пятый тип ресурса — «страницы из книги колдовства». Хранятся в общем `Camp._resources` через `add_resource(PAGE, n)`, тратятся на `unlock_cost` и `upgrade_costs` заклинаний через `Camp.try_spend()`. Дефолтный визуал — фиолетовый плоский бокс. На карте PAGE'ы пока **не спавнятся** через ResourceZone — дроп/реворд-механизмы будут добавлены позже; пока пополняются читом «+100 каждого ресурса».

Цвет (фиолетовый `Color(0.55, 0.35, 0.85)`) одной точкой определён в `ResourcePile.color_for_type` и используется в HUD/Journal/burn-patch'ах для консистентного визуального языка магии.

#### HandSpell координатор

`scripts/hand_spell.gd` (extends Node, child of Hand). По образцу `HandPhysicalActions`:
- Enum `SpellType { FIREBALL, FIRESTORM }`. `equipped` — текущее активное заклинание.
- В `_handle_input`: ловит equip-биндинги (3/4 → set MAGIC), на ПКМ диспатчит `_dispatch_cast()` если категория MAGIC + `Hand.is_holding() == false`.
- Подмодули `_fireball`, `_firestorm` живут под HandSpell в `hand.tscn`; setup получает Hand-ссылку, `tick(delta)` вызывается в `_process` независимо от категории (чтобы cooldown'ы тикали даже при переключении на физику).
- Re-emit `spell_cast(name, position)` от подмодулей.

#### HandSpellFireball — `scripts/hand_spell_fireball.gd`

Однотактное заклинание: один снаряд → один взрыв. Cooldown ≈ 0.4с (скорострельный), параметры fallback'ом в @export'ах.

**`_perform_cast`:**
1. `SpellSystem.is_unlocked(&"fireball")` — иначе return.
2. Резолв параметров: `damage / radius / cooldown / mana_cost / burn_*` из `get_current_level_data(&"fireball")` с fallback на @export.
3. `Tower.try_consume_mana(p_mana_cost)` — иначе return (cooldown НЕ запускается, попытка не «съедается»).
4. `launch_pos` = Tower + UP × `launch_offset_y`; `target_pos` = `Hand.cursor_world_position()` − `hand_height` (приземление, не плоскость руки).
5. `_cooldown_remaining = p_cooldown`. Spawn `fireball.tscn` в `effects_root` (current_scene), `setup(...)` + опционально `setup_burn(...)`.

#### HandSpellFirestorm — `scripts/hand_spell_firestorm.gd`

Серия из N малых фаерболов в зону: «огненный шквал». Реюзает `fireball.tscn` как снаряд (та же баллистика/drift/homing) — отличие в gameplay-параметрах (меньший damage/radius per-shot, рассеяние target_pos).

**State-machine в `tick(delta)`:**
- `_cooldown_remaining` — общий cooldown серии (декрементится всегда).
- `_shots_remaining` — счётчик невыпущенных шотов; на `_next_shot_in <= 0` запускает `_launch_one()` и сбрасывает таймер на `shot_interval`.
- `can_trigger() == false` пока серия идёт ИЛИ cooldown активен — нельзя дозаказать в середине серии.

**`_start_volley`:**
1. Spell-gate (`SpellSystem.is_unlocked(&"firestorm")`).
2. Резолвит и **фиксирует** параметры серии (`_series_shot_damage / _series_shot_radius / _series_scatter_radius`) — серия летит со старыми параметрами даже если игрок прокачает заклинание во время неё (избегаем середины-серии-смены-балансов).
3. Atomic mana списание (один раз за всю серию, не per-shot).
4. Зафиксирует `_volley_target = cursor_world` (игрок может водить курсор во время серии — шквал ложится туда, где было нажатие).

**`_launch_one`:**
- Random jitter target в круге `scatter_radius` через `(angle, sqrt(randf()) × scatter_radius)` — uniform по площади, не по радиусу.
- `fireball.setup(...)` с уменьшенным `damage`/`radius` из series-state.
- Burn-параметры — собственные @export'ы HandSpellFirestorm (не из SpellSystem; меньше fireball'ового burn'а — серия даёт overlap'ы).

**Балансовая зависимость с Fireball:** один шот шквала ≈ одиночный Fireball (damage/radius). Mana_cost фаербола = ~Firestorm.mana_cost / shot_count. Получается: Fireball — равномерный конвейер (DPS ~37), Firestorm — бёрст 4 шота за 0.45с с большим cooldown (DPS ~30, но пик выше).

#### Fireball — `scripts/fireball.gd`, `scenes/fireball.tscn`

Снаряд. Корень — `Node3D` (не RigidBody — broad-phase коллизии при полёте не нужны, AOE-shape-query только в момент взрыва). Содержит SphereMesh-ядро (scale 1.19/0.595/0.595 — капля по local X), GPUParticles3D-хвост (`local_coords=false` — частицы остаются в world space, фаербол улетает быстрее → автоматический «след»), OmniLight3D для glow'а.

**Двухфазная траектория «ракета»:**

1. **Phase.BOOST** (длительность `boost_duration ≈ 0.18с`):
   - Стартовая velocity = `UP × boost_velocity_up + dir_xz × boost_velocity_forward + perp_xz × random_sway` (random sway создаёт «дрожь» при выстреле — каждый каст уходит чуть в свою сторону).
   - В `_physics_process`: `velocity.y -= boost_gravity × delta`; `position += velocity × delta`.
   - Дуга вверх+вперёд из башни, ~1м над launch.

2. **Phase.HOMING** (после boost'а до взрыва):
   - На переходе: `_velocity = drift_basis × desired_dir × _homing_initial_speed`, где `drift_basis = Basis(UP, random ± homing_drift_angle_deg)` — фаербол стартует «мимо», под случайным углом 0..45° от target. Slerp ниже плавно докручивает к цели — характерный «крюк».
   - Каждый кадр: `current_dir.slerp(desired_dir, 1 - exp(-homing_turn_rate × delta))` — frame-rate independent поворот к target. `current_speed = min(current_speed + homing_acceleration × delta, homing_max_speed)`. Velocity = new_dir × speed.
   - Получается: фаербол ныряет вбок, потом плавно докручивает обратно и врезается на максимальной скорости.

**Ориентация Node3D** через `_orient_along_velocity()`: `basis.x = horizontal_velocity_dir`, `basis.y = UP`, `basis.z = perpendicular`. Вытянутая капля и хвост-партиклы выглядят естественно по направлению полёта.

**`_explode()`:**
- AOE-shape-query (SphereShape `radius`, mask `MASK_HAND_SLAM`) + per-target иммунитет (`Layers.is_hand_immune`) + **horizontal-only distance check** (`_xz_distance_sq` — взрыв на ground'е, центр капсулы скелета на y≈0.9, 3D distance отъедал бы ~0.9м эффективного radius'а).
- FAR-fallback по `Skeleton.SKELETON_GROUP` (FAR-скелеты с `CollisionShape.disabled=true` в broad-phase не попадают).
- `_apply_aoe(target)`: linear horizontal falloff `1 - dist/radius`; `Pushable.try_push(target, dir × force × falloff)` + `Damageable.try_damage(target, damage × falloff)`.
- Visual: `AoeVisual.spawn_explosion(fx_root, origin, radius)` — комбо ядро-вспышки + огненных + дымных partикл (см. ниже).
- Если задана `_burn_patch_scene` — спавнит `BurnPatch` в эпицентре через `setup_burn`-параметры.

#### BurnPatch — `scripts/burn_patch.gd`, `scenes/burn_patch.tscn`

Статичная зона горения после взрыва. Не двигается, не растёт — пятно фиксированного радиуса на земле, тикает урон каждые `tick_interval` всем damageable в радиусе, через `duration` секунд `queue_free`.

**`_apply_tick`:** PhysicsShapeQuery + per-target иммунитет + horizontal-only distance + FAR-fallback (тот же паттерн что у Fireball._explode и Slam._perform_slam). Урон **без falloff** — внутри зоны равномерно (горение не зависит от дистанции до центра). Knockback не применяется.

Параметры передаются через `setup(radius, damage_per_tick, tick_interval, duration, mask)`.

#### AoeVisual — `scripts/aoe_visual.gd`

`RefCounted`-helper со static-методами. Общие визуалы AOE-удара/взрыва, без ассетов кроме `slam_distortion_material.tres` / `slam_dust_*` (исторически из Slam'а):
- `spawn_wave(root, pos, radius, duration)` — distortion-сфера расширяется до radius за 0.45с (из Slam-шейдера).
- `spawn_dust(root, pos)` — GPUParticles3D one_shot пыли (тот же материал что у Slam).
- `spawn_radius_indicator(root, pos, radius, color, duration)` — solid translucent sphere = radius, fade-out 0.4с (явный «вижу габариты» индикатор).
- `spawn_explosion(root, pos, radius)` — комбо для взрыва: ядро-вспышка (scale 0 → radius×0.7 → 0 за 0.3с) + огненные partикли (радиальный разлёт жёлтый→красный→прозрачный, 60 шт. lifetime 0.5с) + дымные (up bias, серый→прозрачный, 40 шт. lifetime 1.2с — задерживаются после пламени). Используется `Fireball._explode` и `HandSuper._on_carrier_burst` (взрыв в воздухе на разделении carrier'а).
- `spawn_ground_ring(root, pos, radius, duration, color) -> MeshInstance3D` — плоское TorusMesh-кольцо на земле фиксированного `radius`. При `duration > 0` — auto-fade с pulse-открытием (scale 0.85→1.0 за 0.08с) и линейным альфа-fade. При `duration <= 0` возвращает mesh без tween'а — caller владеет жизненным циклом (используется HandSuper'ом для `_aim_indicator` в фазе AIMING_TARGET).

Slam пока на собственном (с пулом MeshInstance3D) визуале — не трогали работающее. Когда придёт refactor — Slam перейдёт на `AoeVisual.spawn_wave + spawn_dust`.

#### Ground-warning (telegraph) — единый паттерн для магии

Все AOE-заклинания telegraph'ят landing-точку огненно-оранжевым кольцом на земле через `AoeVisual.spawn_ground_ring`. Радиус кольца = реальный AOE-radius взрыва (точно показывает зону damage'а, не зону разлёта или прицеливания):

- **Fireball**: 1 кольцо на target_pos в момент press'а, radius = `p_radius`, duration `warning_duration=1.0`с (>flight_time), цвет `warning_color=(1.0, 0.5, 0.15, 0.85)`.
- **Firestorm**: per-shot кольцо в `_launch_one`, radius = `_series_shot_radius`, duration `warning_duration=0.9`с. 4-6 колец появляются по очереди с `shot_interval`.
- **Super carrier (на земле)**: золотой `_aim_indicator` радиусом `_resolved_payload_radius` в фазе AIMING_TARGET (зона разлёта payload'ов, цвет `aim_indicator_color=(1.0, 0.7, 0.15, 0.95)`). Per-payload красные кольца (`payload_warning_color=(1.0, 0.35, 0.15, 0.85)`) с lead_time=0.3с в `_spawn_one_payload`, radius = `_resolved_payload_radius_aoe`.

Цвет: огненно-оранжевый = «маг-warning» единый знаковый язык; золотой aim_indicator супер-удара = «куда я целюсь, не куда ударит» — отделяется от warning'а оттенком.

#### Super-удар (великий удар) — `HandSuper`, `SuperCarrier`, `SuperPatternOverlay`

Двухступенчатый каст: накопить шкалу → пройти QTE → carrier из tower'а → разделение → ковёр payload'ов.

**Шкала «великой силы»** в `Camp` (`super_charge_max=100`):
- Накопление 1:1 от damage'у врагам через подписку на `EventBus.enemy_damaged` в `Camp._on_enemy_damaged`.
- API: `add_super_charge(amount)`, `get_super_charge()` / `get_super_charge_max()`, `is_super_ready()`, `consume_super_charge(amount)`.
- Сигналы: `EventBus.super_charge_changed(value, max)`, `super_cast_started`, `super_cast_finished(success: bool)`.
- HUD: золотой бар в `gameplay_hud._build_tower_stats` под HP/MP башни. Когда full — лейбл «ГОТОВО (Space)».

**HandSuper** (`scripts/hand_super.gd`) — третья ось ввода, дочерний к `Hand`:
- **State machine**: `READY → AIMING_PATTERN → AIMING_TARGET → CASTING → READY`.
- `READY`: слушает action `cast_super` (Space, keycode 32). Гейтит на `Camp.is_super_ready() && !Hand.is_holding()`. Резолвит балансовые параметры из `SpellSystem.SPELL_CATALOG.super.levels[0]` в `_resolved_*` (фиксация на каст, прокачка mid-cast не меняет balance).
- `AIMING_PATTERN`: `Hand.set_active_category(SUPER)`, `Engine.time_scale = pattern_time_scale=0.15`, спавнит `SuperPatternOverlay`. Hand_physical и hand_spell гасятся ранним return на `active_category == SUPER`.
- `AIMING_TARGET` (на success QTE): `time_scale=1`, `_aim_indicator` следит за курсором каждый кадр в `_process`. ПКМ → `_commit_rain` (списывает 100% шкалы), Space → `_cancel_aim` (бесплатная отмена, шкала full сохраняется).
- `CASTING`: спавнит `SuperCarrier`, подписывается на `carrier.burst.connect(_on_carrier_burst.bind(target_pos))`. Категория возвращается СРАЗУ — игрок управляет рукой пока carrier летит.
- На fail QTE: `consume_super_charge(super_charge_max * super_charge_fail_penalty=0.5)`, возврат категории.

**SuperCarrier** (`scripts/super_carrier.gd`, `scenes/super_carrier.tscn`) — носитель из tower'а в burst-точку над целью:
- Двухфазная траектория «как ракета» (boost+homing, копия Fireball-схемы).
- `setup(launch, burst, boost_*, homing_*)`. На `_age >= boost_duration` → переход в HOMING с initial drift_angle (random ±35° по умолчанию).
- Arrival двумя путями: **proximity** (`HIT_PROXIMITY_SQ=4.0` = radius 2м, с запасом под высокую скорость) и **overshoot detection** через `_min_distance_to_target` (если был ближе `OVERSHOOT_TRIP_DISTANCE=3.5`, потом удалился — burst). Без overshoot'а на homing_max_speed=48 carrier зацикливался вокруг точки.
- На burst'е emit'ит `burst.emit(global_position)` (текущую позицию, не зафиксированный target) и self-destructs.
- Visual: SphereMesh radius 0.4 × `visual_scale=1.2` = 0.48 (≈1.85× от fireball'а 0.26 — «не больше 2× от обычного» по дизайнерскому решению), OmniLight, GPUParticles3D-trail.
- `AoeVisual.spawn_explosion(burst_position, carrier_burst_visual_radius=4.0)` в момент разделения — core-вспышка + fire/smoke. Payload'ы вылетают «из огня».

**Payload spawn** в `_on_carrier_burst` (HandSuper):
- На burst'е итерирует `_resolved_payload_count=12`, для каждого payload'а — random delay в `[0; payload_max_delay=0.4]`с через `get_tree().create_timer(delay).timeout.connect(_spawn_one_payload.bind(...))` (импакты «очередью», не один-в-один).
- Per-payload random multiplier в `[1−speed_jitter; 1+speed_jitter]=[0.75; 1.25]` на homing_acceleration / homing_max_speed; случайные drift_angle (4..14°) и turn_rate (8..14) — каждый летит «своей траекторией».
- Sub-spawn ground-warning ring сразу при вычислении target'а, lead_time=0.3с через await таймер, потом instantiate fireball (target = ground_target + uniform-по-площади jitter в круге `payload_radius`).

**SuperPatternOverlay** (`scripts/super_pattern_overlay.gd`, `scenes/super_pattern_overlay.tscn`) — QTE UI:
- Control в CanvasLayer (layer=10, `process_mode = PROCESS_MODE_ALWAYS` — не подвержен time_scale).
- 3×3 grid точек, `pattern_length=4` (через `SpellSystem.super.levels[0].pattern_length`) случайных индексов помечены как путь.
- Custom drawing через `_draw()`: фоновый fade, 3-слойный halo на каждой sequence-точке (мягкий glow без шейдеров), pulse-scale на текущей точке (`sin(now * 6.0) × 12%`), hit-flash растущим зелёным ring'ом 0.45с после прохождения, нить с тёмным shadow ниже (читается на любом фоне), cursor-trail из последних 0.4с позиций мыши.
- Все таймеры через `Time.get_ticks_msec()` — независимы от time_scale. `_time_remaining` тикает в `_process` как `delta / Engine.time_scale` (real time).
- ПКМ-зажат → drag через ожидаемую sequence-точку (snap_radius_px=35); на release при `_passed_count == sequence.size()` → success. Любой не-ожидаемый snap или release раньше — fail. Тайм-аут `pattern_timeout=8с` real time.
- Сигналы: `pattern_started`, `pattern_finished(success: bool)`. HandSuper подписан на `pattern_finished`, дальше state machine.

#### Журнал → вкладка «Заклинания»

`JournalPanel.Tab.SPELLS` (между «План» и «Задания»). `_build_spells_tab(camp)` итерирует `SpellSystem.SPELL_CATALOG`, рендерит карточку на каждое заклинание:
- **Locked** — «🔒 закрыто», описание скрыто, стоимость `unlock_cost` в страницах, кнопка «открыть» (disabled если `Camp.can_afford(cost) == false`).
- **Unlocked, есть апгрейды** — «ур. N/M», список stats текущего уровня (generic key:value через `_format_stat`), стоимость следующего уровня, кнопка «улучшить → ур. N+1».
- **Max level** — «макс. уровень», disabled.

Реактивно через `EventBus.spell_unlocked` / `spell_upgraded`. Stats-формат generic — каталог можно расширять без правок UI (ключи level-data автоматически рендерятся в карточке).

#### Балансовые цифры (на 2026-05-10, v5)

История balance-проходов: исходный (v0) → v1 (площадь Fireball'а вверх + burn-зона ≈ AOE) → v2 (+20% damage) → v3 (+15%) → v4 (+10%) → v5 (магия +20%, лучник −20%). Накопительно ×1.82 по damage'у от исходного.

**AOE falloff** (Fireball/Firestorm/Super/Slam): теперь sqrt-curve, `damage × √(1 − dist/radius)`. На 50% радиуса ≈ 71% damage'а (vs 50% при linear), на 75% ≈ 50% (vs 25%). Обновлено в `fireball.gd._apply_aoe` и `hand_physical_slam.gd._slam_direction_and_falloff`. Burn-патчи без falloff'а — равномерно внутри `burn_radius`.

**Fireball (4 уровня, открыт по умолчанию):**

| Уровень | damage | radius | cooldown | mana | burn dmg | burn radius | burn dur | burn tick |
|---|---|---|---|---|---|---|---|---|
| 0 | 47 | 3.5 | 0.40 | 12 | 18 | 2.8 | 2.5 | 0.50 |
| 1 | 58 | 3.8 | 0.36 | 11 | 24 | 3.0 | 2.5 | 0.50 |
| 2 | 77 | 4.2 | 0.32 | 10 | 29 | 3.3 | 3.0 | 0.45 |
| 3 | 101 | 4.5 | 0.28 | 9 | 37 | 3.5 | 3.5 | 0.40 |

Стоимость апгрейдов: 3 → 6 → 12 страниц.

**Firestorm (3 уровня, открыт по умолчанию):**

| Уровень | shots | interval | dmg/shot | radius | scatter | cooldown | mana | burn dmg | burn radius | burn dur | burn tick |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 4 | 0.15 | 40 | 3.0 | 2.8 | 2.0 | 50 | 11 | 2.0 | 2.0 | 0.50 |
| 1 | 5 | 0.13 | 52 | 3.2 | 3.0 | 1.8 | 55 | 14 | 2.2 | 2.0 | 0.50 |
| 2 | 6 | 0.11 | 64 | 3.5 | 3.2 | 1.6 | 60 | 18 | 2.4 | 2.5 | 0.45 |

Стоимость апгрейдов: 6 → 12 страниц. Burn-параметры теперь в каталоге (раньше были хардкодом @export'а в `hand_spell_firestorm.gd` — не масштабировались по уровню; v3-фикс).

**Super (1 уровень, открыт по умолчанию, без апгрейдов):**

| payload_count | payload_damage | payload_radius (разлёт) | payload_radius_aoe (взрыв) | pattern_length |
|---|---|---|---|---|
| 12 | 47 | 7.0 | 4.0 | 4 |

Шкала «великой силы» в `Camp` (`super_charge_max=100`, накопление 1:1 от damage'у врагам через `EventBus.enemy_damaged`); провал QTE списывает 50% (`super_charge_fail_penalty=0.5`).

**Slam (физическая категория, не магия — для сравнения):**

| damage | radius | cooldown | force | lift |
|---|---|---|---|---|
| 25 | 3.5 | 0.7 | 30 | 0.4 |

Slam — utility «оглушил → добил» (2-shot скелета hp=30 в эпицентре), не основной damage. Бесплатный (без mana), но magic'у уступает по single-target и AOE-DPS — это by design.

**Defender (лучник) — для сравнения, не магия:**

`arrow_damage` рандом из `20.0..32.0` (avg 26), `attack_cooldown` 1.0..2.0с (avg 1.5с) → ~17 DPS. `base_inaccuracy_radius=1.5м` падает по логарифмической кривой через `experience_half_shots`.

---

## 6. Управление и инпуты

Регистрируются в `project.godot → [input]`:

| Action | Клавиша | Используется в |
|---|---|---|
| `move_forward` | W | Tower |
| `move_back` | S | Tower |
| `move_left` | A | Tower |
| `move_right` | D | Tower |
| `hand_grab` | LMB | Hand:PhysicalActions (захват/бросок — работает в любой категории) |
| `hand_action` | RMB | Hand:PhysicalActions (slam/flick) или Hand:Spell (fireball/firestorm), в зависимости от Hand.active_category |
| `equip_slam` | 1 | Hand:PhysicalActions (экипировать хлопок) → category PHYSICAL |
| `equip_flick` | 2 | Hand:PhysicalActions (экипировать щелбан) → category PHYSICAL |
| `equip_fireball` | 3 | Hand:Spell (экипировать фаербол) → category MAGIC |
| `equip_firestorm` | 4 | Hand:Spell (экипировать огненный шквал) → category MAGIC |
| `cast_super` | Space | Hand:Super — старт супер-удара (когда Camp.is_super_ready). В AIMING_TARGET повторное нажатие = бесплатная отмена. |
| `camp_toggle` | R | Camp (зажать для развёртки/свёртки на POI). В DEPLOYED отсчёт pack'а гейтится `is_tower_in_camp_recall_zone()` — если башня вне `recall_zone_radius` от anchor'а, pack не запускается («оставить лагерь и уйти с солдатами»). |
| `caravan_halt_toggle` | Q | Composite-команда: (1) toggle halted-режима в CARAVAN_FOLLOWING; (2) squad-recall для всех отрядов в recall-зоне башни (toggle ESCORT/HOLD-soft); (3) спавн волны вызова (expanding-ring визуал, команды применяются по `dist / wave_speed` задержке). Подробнее — §5.8.2.6. |
| `ui_journal` | J | JournalPanel (открыть/закрыть журнал — семь вкладок: Юниты / Лагерь / План / Заклинания / Армия / Задания / Читы) |
| `gnome_collect` | C | Camp.set_collection_mode(WORK) — gatherer'ы возвращаются на сбор |
| `gnome_alarm` | V | Camp.set_collection_mode(ALARM) — gatherer'ы бегут в палатки (request_return); defender'ы продолжают защищать |

**UI-гейт мыше-инпутов:** `Hand.is_pointer_over_ui()` → `get_viewport().gui_get_hovered_control() != null`. Все мыше-зависимые действия (LMB grab в hand_physical, ПКМ ability/spell, ПКМ commit aim'а отряда) гейтятся этим — клик по HUD-кнопке не тригерит параллельный grab/cast/aim под виджетом. Уже-активные действия (release удерживаемого) не трогаются. Клавиатурные хоткеи (equip 1/2/3/4, Space, Q, R) гейтом не покрыты — они работают и над UI.

**Focus_mode HUD-кнопок:** все squad-cards и journal-кнопка имеют `focus_mode = FOCUS_NONE`. Без этого Godot Button по дефолту имеет FOCUS_ALL, и Space на сфокусированной (последней кликнутой) кнопке параллельно триггерит её pressed-сигнал — после клика «Идти сюда» Space одновременно вызывал и super-удар, и активировал squad-aim ring.

**Дебаг-читы вынесены с клавиатуры в JournalPanel → вкладку «Читы»**
(2026-05-08). Старые actions `spawn_enemies` (P), `force_wave` (O),
`debug_spawn_100` (`[`), `debug_stress_2000` (`]`) удалены из project.godot
вместе с `Input.is_action_just_pressed`-чеками в `wave_director.gd:_process`.
Теперь вкладка «Читы» вызывает публичный API:

| Кнопка | WaveDirector / Camp метод | Эффект |
|---|---|---|
| Старт/рестарт волн | `cheat_start_campaign()` | Переход IDLE→RUNNING (initial spawn) или рестарт (kill_all_skeletons + reset_population + сброс активного POI) |
| Немедленная волна | `cheat_force_wave()` | Спавн POI-волны на активный лагерь, сброс `_wave_cd`. Без активного POI — лог-предупреждение, no-op |
| +100 скелетов | `cheat_spawn_100()` | `_spawn_safe_uniform(100)` — uniform по safe-зонам, не трогает фазу/таймеры |
| Stress 2000 скелетов | `cheat_stress_2000()` | `EnemySpawner.spawn_uniform(skeleton_scene, 2000)` — async-batched, для замеров перфоманса |
| +100 каждого ресурса | `Camp.add_resource(type, 100)` × 5 типов | По 100 единиц wood/stone/iron/food/page на склад. Каждый эмитит `resources_changed`, HUD/Journal перерисовываются |
| Продвинуть квест | `QuestProgress.advance()` | Завершает текущий активный квест (ранее был на клавише Q) |

Курсор мыши — позиция руки. Системного захвата курсора нет, он движется свободно.

**Колесо мыши** (без input action — read raw в `CameraRig._unhandled_input`): WHEEL_UP — приблизить камеру, WHEEL_DOWN — отдалить. Зум плавный, ограничен `zoom_min/max` относительно базового оффсета из `.tscn`.

---

## 7. История работы и решения

### 7.1 Стартовая точка

Локальный проект изначально содержал монолитный `main.tscn` с башней, рукой и магией, плюс четыре скрипта (`tower.gd`, `hand.gd`, `magic.gd`, `camera_rig.gd`) с прямыми связями между собой. Hand был ребёнком Tower, бросок и магия летели в направлении башни (а не курсора), сцена не имела предметов для теста.

**Решение:** удалить всё и начать с нуля по инкрементальной схеме (башня → камера → рука → предметы), под архитектуру модульных сцен.

### 7.2 Этапы работы

1. **Башня + WASD.** Минимальный `CharacterBody3D` с гравитацией, без покачиваний и поворотов мышью.
2. **Изометрическая камера.** Сначала жёстко привязанная к башне; потом — `CameraRig` с lerp-следованием через `target_path`.
3. **Сетка на полу.** Шейдер на материале пола, чтобы видно было движение и расстояния.
4. **Рука с захватом.** Курсор → плоскость → позиция руки. Захват ближайшего `RigidBody3D` в `Area3D`. Бросок по сглаженной скорости.
5. **Модульный рефакторинг.** Каждый объект вынесен в свою `.tscn`. Введён `class_name Item`. Связи переведены на `@export NodePath` и сигналы.
6. **Магнитный захват.** Опускание `GrabArea` к полу, добавление `MagnetArea` с притяжением через `apply_central_force`.
7. **Толкание предметов башней.** Башня по массе сравнивается с `Item`; если тяжелее — толкает телом при движении через приложенный импульс.
8. **Параметризация Item.** Размер вынесен в `@export var item_size: Vector3`, скрипт собирает уникальные меш и шейп при `_ready`. Добавлен набор тестовых ящиков от 0.5³ до 2.5³ с массами 0.5–20 для проверки порога толкания.
9. **Порог подъёма у руки.** Параллельно с `tower.mass > item.mass` для пуша добавлен `hand.max_lift_mass > item.mass` для захвата. Фильтр стоит в `_find_closest_item`, поэтому тяжёлые предметы не магнитятся впустую: рука их вообще не «видит» как кандидатов.
10. **Подъём руки по высоте под курсором.** `_follow_cursor` переделан с пересечения горизонтальной плоскости на двухэтапную схему: сначала `intersect_ray` по физике (узнаём Y поверхности), потом пересечение того же луча камеры с плоскостью на `surface_y + hand_height`. `hand_height` стало просветом над любой поверхностью под курсором, а не абсолютной координатой. Удерживаемый предмет добавляется в `query.exclude` — иначе рука удалялась бы от своего же ящика, потому что луч сначала бил бы в него.

    **Подводный камень, на который наткнулись:** первая версия клала руку как `hit_pos + UP × hand_height`. Это давало правильную высоту, но визуально отрывало руку от пиксельного курсора — в изометрии «над точкой попадания» и «на луче камеры» это разные точки. Лечение: оставить пересечение с горизонтальной плоскостью (рука гарантированно на луче), а raycast использовать только для определения Y этой плоскости.

11. **Коллизионные слои.** Введена семантическая разметка: `Terrain (1) / Items (2) / Actors (3) / Projectiles (4)` (см. §4.1). Маски тел остались «всё со всем» (15), слои несут только смысл для запросов. Появилось два места, где это используется: `Hand.GrabArea/MagnetArea.collision_mask = 2` (физически видят только Items) и `Hand._raycast_terrain` через `@export_flags_3d_physics terrain_mask = 3` (Terrain + Items, без Actors и Projectiles). Когда появятся NPC и снаряды, рука уже автоматически их игнорирует — править ничего не придётся.

12. **Логирование системы слоёв и контактов.**
    - `Hand` получил `debug_log` и логи: смена поверхности под курсором (с именем слоя), грабинг, магнит-фаза. Так напрямую видно, как `terrain_mask` фильтрует и куда смотрит `_raycast_terrain`.
    - `Tower._push_items` логирует фронт контактов с `Item`: «толкаем X», «упёрлись в X», «контакт прекращён». Состояние контакта отслеживается через `_contacts_last: Dictionary` (Item → "push"/"block").
    - В `Tower._debug_log` старая «коллизия со стеной» теперь пропускает `Item` — иначе дублирует push-лог. Останется писать только про реальные стены, когда они появятся.

13. **Подсветка кандидата на захват.** У `Item` появился публичный метод `set_highlighted(bool)` — переключает emission на собственном материале. Hand каждый кадр в `_update_candidate_highlight` ищет ближайший `Item` в `GrabArea` (с учётом `max_lift_mass`), сравнивает с `_current_candidate` и на фронте дёргает `set_highlighted` у старого/нового. Пока `_held` не пустой — кандидата нет. Контракт ровно один метод, никакого autoload-хайлайтера или сигнала-шины: Hand знает только тип `Item`, а Item не знает про Hand вообще.

14. **Категории действий руки.** Hand разрезана на координатора и два подузла-категории:
    - `Hand` (Node3D, `class_name Hand`) — позиционирование, сглаженная скорость, raycast поверхности, лог смены поверхности. Сама ничего не делает, кроме как раздаёт API подмодулям.
    - `PhysicalActions` (Node, `hand_physical.gd`) — категория «физика»: захват, бросок, магнит, подсветка кандидата. Привязка ЛКМ. Бывшая логика грабинга переехала сюда целиком, состояние (`_held`, `_is_grabbing`, `_current_candidate`) ушло вместе с ней.
    - `SpellActions` (Node, `hand_spell.gd`) — категория «заклинания», заглушка под будущую систему.

    Hand re-emit'ит `grabbed/released` от `PhysicalActions` для обратной совместимости. Подмодули зависят только от родителя Hand (через `get_parent() as Hand`), друг про друга ничего не знают. Добавление новой категории = новый Node-ребёнок со своим скриптом, без правок в Hand.

15. **Хлопок по земле (Slam, RMB).** Первое физическое действие сверх захвата. Реализован в `Hand:PhysicalActions`:
    - `Item` получил поле `hp` и метод `take_damage(amount)` + сигналы `damaged/destroyed` — общий «damageable»-контракт, под который потом подключатся враги.
    - `_perform_slam` через `PhysicsShapeQueryParameters3D` (сфера `slam_radius`) ищет всё в зоне на маске `Items + Actors`. Удерживаемые (`freeze=true`) пропускаются.
    - Falloff считается по **горизонтальной** дистанции: рука летит на `hand_height`, и 3D-метрика в `slam_radius` учитывала бы вертикаль и резко гасила силу даже у близких ящиков.
    - Кулдаун через `_slam_cooldown_remaining`. Визуал — расширяющаяся прозрачная сфера с emission, спавнится в `current_scene` и `queue_free` через 0.3s.
    - Сигнал `slammed(position, radius)` — для будущих звука/анимации/UI без правок руки.

16. **Щелбан (Flick) и equip-система.** Введены экипируемые активные способности на ПКМ:
    - `equipped: String` (`slam` / `flick`) меняется клавишами `1` / `2`. Дефолт `slam` — старое поведение сохраняется, пока не нажмёшь `2`.
    - `_handle_input` стал диспатчером: ПКМ press → `_dispatch_action_press` (выбирает по `equipped`), release → `_dispatch_action_release`. Slam — one-shot. Flick требует hold/release-цикла, поэтому держит `_action_active = "flick"` между ними.
    - На время flick LMB-грабинг отключён — иначе случайно схватили бы свою же цель щелбана.
    - На Hand добавлен публичный `lock_position(bool)`: пока залочено, `global_position` не пересаживается под курсор. Flick дёргает `lock_position(true)` на старте и `false` на release.
    - Защита: если цель уничтожилась во время прицеливания — `is_instance_valid(_flick_target)` ловит, рука разлокается, состояние сбрасывается.

17. **Курсор-управляемая орбита щелбана.** Первая итерация щелбана крутила руку автоматически (`_flick_orbit_angle += speed × delta`). Игрок не контролировал направление — нужно было «ловить тайминг». Нелогично: вся прочая система собрана вокруг «рука = курсор».
    - **Что переделано:** `Hand` теперь каждый кадр считает позицию-под-курсором в `_last_cursor_world` и хранит её, **даже когда `_position_locked = true`**. Раньше при lock'е `_follow_cursor` целиком пропускался, и cursor world-position не обновлялся.
    - Появился публичный `Hand.cursor_world_position()` — возвращает последнее значение. Подмодули могут читать «куда сейчас тычет мышь» независимо от того, перехватили ли они позицию руки.
    - `_update_flick` вместо инкремента угла читает `cursor_world_position()`, считает горизонтальную разницу `(cursor − target)`, нормирует и ставит руку на `target + dir × flick_orbit_radius`. Куда курсор — туда рука. На release предмет летит в противоположную руке сторону, как и раньше.
    - Если курсор «попадает» прямо на цель (XZ почти совпадают) — держим прошлое направление вместо нулевой нормали. Без рывков и NaN'ов.
    - `flick_orbit_speed` удалён за ненадобностью.

18. **Категория врагов: Enemy / Skeleton / EnemySpawner.** Первый внешний противник для башни.
    - Введён слой `5: Enemies`. Скелеты на нём, маска изначально была `7` (Terrain+Items+Actors) — без своего слоя; через шаг переделана (см. этап 19). Tower / Item / Ground получили `mask = 31`, чтобы все остальные с врагами симметрично взаимодействовали.
    - `class_name Enemy extends CharacterBody3D` — общая база с `hp`, `take_damage`, `apply_knockback`, гравитацией, кулдаунами и виртуальным `_ai_step`. Состояние knockback'а отдельно от AI: `_knockback_timer` блокирует `_ai_step`, velocity лерпится к нулю.
    - `class_name Skeleton extends Enemy` — простой AI «иди и бей». Цель ставится извне через `set_target(Node3D)`, и Skeleton не знает, что это именно башня — duck-typed `target.has_method("take_damage")`.
    - `EnemySpawner` (Node3D со скриптом, в `main.tscn`) — spawnit'ит скелетов кольцом вокруг target по `Input.spawn_enemies` (P). Параметры: `spawn_radius`, `spawn_count`, `spawn_radius_jitter`. Зависит только от `PackedScene` и `NodePath`.
    - `Tower` обзавёлся `hp` + `take_damage` + сигналы `damaged/destroyed` — иначе скелетам некуда «бить». На `hp ≤ 0` сигнал есть, а `queue_free` нет: это игровой стейт, обработается отдельным UI-узлом, когда дойдём до game-over.
    - Slam расширен: `slam_mask = 18` (Items + Enemies), цикл результатов разбит на `_apply_slam_to_item` (через `apply_central_impulse`) и `_apply_slam_to_enemy` (через `apply_knockback` — у CharacterBody3D нет импульса). Расчёт falloff/направления вынесен в `_slam_direction_and_falloff`, общий для обоих.

19. **Телеграф атаки скелета + само-коллизии + замедление.** После первой партии тестов:
    - **Телеграф.** Раньше скелет в `attack_range` мгновенно бил без визуала — у игрока не было шанса среагировать. Введён state-machine APPROACH → WINDUP (0.4s, красная подсветка через emission) → STRIKE → COOLDOWN. Чтобы emission менялся локально, материал дублируется в `_ready` (без этого все 50 скелетов засветились бы одновременно).
    - **Хук `_on_knockback`.** Если slam попадает в скелета во время windup, замах должен отменяться. Добавлен виртуальный `Enemy._on_knockback()` — `apply_knockback` теперь зовёт его в конце; `Skeleton` переопределяет, сбрасывая `_in_windup`. Чистый расширяемый паттерн для будущих врагов.
    - **Само-коллизии.** Раньше `Skeleton.collision_mask = 7` (без Enemies) → скелеты проходили друг сквозь друга. Меняем на `23` — мутуально блокируются. Поскольку оба CharacterBody3D, физического push'а между ними нет, но `move_and_slide` корректно слайдит вдоль соседа → плотная толкучка возле цели вместо «вложенных капсул».
    - **Скорость.** `move_speed: 4.0 → 2.7` через override на инстансе в `skeleton.tscn` (не меняя дефолт `Enemy.move_speed`, чтобы будущие враги могли иметь свой темп).

20. **Тактильность атаки и проницаемость толпы (первая итерация).** 
    - **Lunge-выпад при ударе через Tween.** Сразу после windup'а, в `_strike`, скелет играл короткий «удар»: `Tween` двигал `MeshInstance3D.position` от `(0,0,0)` до `dir × lunge_distance` и обратно. Только меш — коллизия и AI не трогались.
    - **Tower-push для врагов.** Бывший `_push_items` переименован в `_resolve_contacts` и расширен ветвлением: `Item` обрабатывается как раньше (impulse с массовым ratio), `Enemy` получает `apply_knockback(push_dir × v_into × enemy_push_speed_factor, enemy_push_duration)`. Башня теперь **рассекает** толпу скелетов, не упираясь в них как в стену: каждый кадр контакта knockback обновляется, скелет вылетает из-под башни и AI снова подключается, как только башня проедет.
    - Лог по враг-контактам отключён (50+ скелетов = спам). Item-контакты по-прежнему фиксируются в `_contacts_last`.

21. **Lunge физический + bounce + push соседей (вторая итерация).** Tween-lunge меша в башню проходил визуально насквозь — выглядело некрасиво.
    - **Tween-lunge удалён.** Вместо него `_strike` вызывает `_do_lunge` → `apply_knockback(dir × lunge_speed, lunge_duration)` **сам себе**. AI выключен, физическое тело летит вперёд через `move_and_slide`. Башня (CharacterBody3D) блокирует физически — скелет упирается, как и положено.
    - **Bounce-off от цели.** В `Enemy._physics_process` после `move_and_slide`, если `_knockback_timer > 0` и одна из slide-коллизий — `_target`, считается elastic-отскок: компонент скорости в нормаль инвертируется по `(1 + bounce_restitution)`. Скелет «отлетает» от башни.
    - **Расталкивание соседей.** В той же пост-slide фазе для каждой коллизии с другим `Enemy` — `apply_knockback(push_dir × my_speed × neighbor_push_factor, neighbor_push_duration)`. Лунжущий скелет пробивает первый ряд толпы, тот толкает следующий, цепная реакция (затухает через `neighbor_push_factor < 1`).
    - **Кулдаун всегда тикает.** Раньше в knockback'е `_attack_cooldown_remaining` стоял, и lunge-knockback (0.2s) фактически удлинял атак-цикл. Перенёс декремент кулдауна выше ветки knockback'а.
    - Бонусом: больше нет per-strike Tween — это снимает часть нагрузки при 50+ скелетах одновременно атакующих.

22. **Bounce и neighbor-push не срабатывали — pre-slide velocity.** Сразу после реализации (этап 21) обнаружилось: при ударе скелетов о башню они не отскакивали, и соседей тоже не толкали — никто ни от кого. Причина:
    - `move_and_slide` **зануляет** компоненту `velocity` в направлении препятствия (это её работа — слайдить вдоль, а не пробивать). Поэтому когда `_resolve_knockback_contacts` смотрел `velocity.dot(into_dir)` уже **после** slide'а, получал ~0 и `bounce` ничего не добавлял. У `_push_neighbor` та же беда: `Vector2(velocity.x, velocity.z).length()` отдавал почти 0, push был мизерный.
    - Лечение: запомнить `pre_slide_velocity := velocity` до `move_and_slide` и передать в `_resolve_knockback_contacts`. Bounce-формула стала «добавить `−into_dir × pre_into × restitution` к текущей velocity» (эквивалентно reflection, но к зануленному компоненту). Push соседа использует pre-slide-скорость для расчёта силы.

23. **Flick расширен на врагов + диапазон урона.** Раньше щелбан работал только по `Item`'ам и наносил фиксированный урон 5 — для скелетов был бесполезен. Изменения:
    - `GrabArea.collision_mask: 2 → 18` (Items + Enemies). LMB-grab/магнит/подсветка кандидата по-прежнему фильтруют через `body is Item`, поэтому случайно схватить или примагнитить скелета нельзя.
    - В `HandPhysicalActions` появился `find_flick_target() -> Node3D` — отдельный поиск кандидата для щелбана, видит и Item (с mass-фильтром), и Enemy (без фильтра). `find_grab_candidate()` остался Item-only для LMB-канала.
    - `_flick_target: Item → Node3D`. На release — диспатч по типу: Item получает `apply_central_impulse`, Enemy получает `apply_knockback(velocity, flick_knockback_duration)` (CharacterBody3D без impulse-API). Урон через общий `take_damage` — damageable-контракт уже был.
    - Сигнал `flicked(target: Node3D, ...)` (был `Item`). `EventBus.hand_flicked` тоже расширен.
    - **Диапазон урона.** Замена `flick_damage: float = 5.0` на пару `flick_damage_min = 15.0` / `flick_damage_max = 35.0`. Каждый щелбан ролится через `randf_range`. На скелете hp=30: минимум 15 (два удара минимума ровно добивают), максимум 35 (есть шанс one-shot'а). Получили «убийство за 1-2 удара» с рандомизацией, как просил геймдизайн.

24. **Шатер скелета на смерти.** Раньше скелет на hp=0 просто исчезал через `queue_free` — без визуальной обратной связи на удар. Добавлена «рассыпающаяся» смерть:
    - В `Enemy` появился виртуальный хук `_on_destroyed()` — вызывается после `destroyed.emit()` и до `queue_free()`. Тот же паттерн расширения, что у `_on_knockback`.
    - `Skeleton._on_destroyed` прячет свой `MeshInstance3D` (visible=false) и спавнит 7 `RigidBody3D`-кубиков вдоль высоты капсулы в `current_scene` — они переживают `queue_free` самого скелета. Импульс: радиальный наружу × `SHATTER_IMPULSE_RADIAL` + вертикальный вверх с рандомным масштабом. Угловая скорость рандомная по всем осям.
    - `collision_layer = 0`, `mask = 1` — осколки падают на Terrain, проходят сквозь всё остальное (включая друг друга и башню). Без завалов и физ-нагрузки от взаимодействий.
    - `material_override = _shared_normal_material` — тот же общий материал, что у живых скелетов. GPU батчит их вместе (никакого дополнительного draw call'а на тип).
    - `Tween` на самом теле: `tween_interval(SHATTER_LIFETIME) → tween_callback(queue_free)`. Без таймер-нодов, всё само-уничтожается через 2с.

25. **Модуль Camp (караван + развёртка вокруг башни).** Добавлен новый модуль `Camp` (`scenes/camp.tscn`, `scripts/camp.gd`) — четыре палатки-`StaticBody3D`, которые в режиме каравана идут цепочкой за башней, а по зажатию `R` разворачиваются в кольцо палаток-блокаторов вокруг текущей позиции башни и так же сворачиваются обратно. Зависит от Tower через `@export target_path`, никто из других модулей про Camp не знает.

    **State machine на двух состояниях вместо четырёх.** Первой мыслью было разнести жизненный цикл на `CARAVAN_FOLLOWING / DEPLOYING / DEPLOYED / PACKING` — отдельная фаза «удержания R» как промежуточный state. На практике «удержание» — это просто `_hold_progress` внутри текущего состояния: в `CARAVAN_FOLLOWING` оно копит ход к развёртке, в `DEPLOYED` — к свёртке. Никаких визуальных отличий между «жду R» и «зажат R, идёт прогресс» нет, отдельный state ничего не давал бы. В итоге `enum {CARAVAN_FOLLOWING, DEPLOYED}` и переменная `_hold_progress`, сбрасываемая на отпускании клавиши или при движении башни (для развёртки). Проще, без потери функциональности.

    **Цепочка вместо position-history-buffer для follow.** Был соблазн делать «змейку» через буфер прошлых позиций башни и каждой палатке выдавать N-ный сэмпл назад — даёт точный «след шаг-в-шаг». Отверг: буфер требует размера, частоты сэмплинга, и плохо реагирует на телепорты. Цепочка — каждая палатка тянется к `leader_pos − dir × part_gap`, где лидер — предыдущая палатка (или башня для нулевой), `lerp` даёт плавность. Гибче в зоне видимости: при «выпадении» башни за `follow_max_distance` ведущая встаёт, остальные подтягиваются к своим лидерам, и цепочка естественным образом сжимается, не нужно отдельного gather-режима.

    **`collision_layer` toggle (0 ↔ 4) при смене режима.** В `CARAVAN_FOLLOWING` палатки на `collision_layer = 0` — башня их не видит, караван не мешает движению. В `DEPLOYED` — `collision_layer = 4` (Actors), палатки блокируют башню физически, как и положено лагерю-препятствию. Альтернативу «палатки всегда блокируют» отверг: караван бы упирался башне в спину при любом тормозящем шаге. Альтернативу «никогда не блокируют» отверг: тогда развёрнутый «лагерь» перестаёт быть препятствием и теряет смысл.

    **Stationary-чек через `_tower.velocity` (CharacterBody3D field).** Для развёртки нужно «башня стоит». Велосипед типа position-delta-за-кадр считать не стал — `CharacterBody3D` уже держит `velocity`, читаем горизонтальную составляющую и сравниваем с `stationary_speed_threshold`. Для прототипа этого достаточно, никаких допфакторов.

    **Развёртка не требует движения палаток в нужные позиции синхронно.** При входе в `DEPLOYED` каждой палатке вычисляется свой `_deployed_targets[i]` = точка кольца на `cos/sin(i × TAU / 4) × deploy_radius` от anchor'а; дальше каждая независимо `lerp`'ит к своей цели тем же `follow_speed`. Эстетически выходит «съезжаются в кольцо» — каждая палатка идёт по своей траектории, без чёткой хореографии. Кода меньше, выглядит живее.

26. **Палатки на отдельном слое `CampObstacle` вместо toggle коллизии.** Первая итерация (этап 25) переключала `collision_layer` палаток между `0` (караван) и `4 / Actors` (развёрнут). Это давало два побочных эффекта: (а) в развёрнутом лагере башня упиралась в собственные палатки и не могла зайти/выйти; (б) в каравне скелеты свободно проходили сквозь палатки — лагерь не служил препятствием для врагов на марше. Оба пожелания пользователь явно сформулировал: «развёрнутые палатки не должны мешать башне; в каравне палатки не должны пропускать скелетов».
    - **Решение через семантический слой.** Заведён новый слой `6: CampObstacle` (см. §4.1). Палатки **всегда** на `collision_layer = 32`, независимо от состояния. `Tower.mask = 31` бит 6 не включает → башня проходит сквозь палатки в любом режиме. `Skeleton.mask: 23 → 55` (добавлен бит 32) → скелеты упираются в палатки и в каравне, и в развёрнутом лагере.
    - **State-toggle коллизии удалён** из `_start_deploy` и `_start_pack`. State-машина теперь чисто про логику движения и таймеры; коллизии — статически в `.tscn`. Меньше связности, легче рассуждать.
    - **Альтернатива «палатки на Actors»**, рассмотренная: можно было бы убрать Actors из Tower.mask и оставить палатки на 4. Отверг — Actors несёт другую семантику (player-controlled cohort), а палатки концептуально — препятствие, не «игровая сторона». Отдельный слой делает namespace честным и не мешает будущим NPC-попутчикам, если такие появятся.

27. **Большой рефакторинг: устранение хардкода, унификация damage/push, инъекция связей** (`c33a9d3`). Точечные «магические» числа и `body is Item`-цепочки расползлись по проекту — стало пора собрать их в контракты.
    - **`Layers` (`scripts/layers.gd`, `class_name Layers`).** Именованные биты `TERRAIN/ITEMS/ACTORS/PROJECTILES/ENEMIES/CAMP_OBSTACLE` + композитные `MASK_HAND_CURSOR/MASK_HAND_TARGETS/MASK_ALL_GAMEPLAY/MASK_SKELETON/MASK_TERRAIN_ONLY` + `layer_name_for_bits(mask)` для логов. В коде маски берутся через `Layers.X`; в `.tscn` Godot хранит ints — там литералы, эквивалентные константам.
    - **Damageable из marker-группы в реальный контракт.** Был просто `add_to_group("damageable")` для индикации; теперь у `Damageable` есть `try_damage(target, amount) → bool` — единая точка нанесения урона. Slam и Flick стреляют через неё, тип цели не проверяют.
    - **Pushable — новый контракт.** `apply_push(velocity_change, duration)`. RigidBody-цели (Item, ResourcePile) преобразуют через массу: `apply_central_impulse(Δv * mass)`. Kinematic-цели (Enemy) применяют через свой `apply_knockback`. Tower и Slam/Flick зовут `Pushable.try_push(target, ...)` — без `is Item` / `is Enemy` веток.
    - **Hand: setup-инъекция в подмодулях.** `HandPhysicalSlam/Flick/Spell` получили `class_name` и явный `setup(hand, coord)` — вместо `get_parent().get_parent()`-цепочек. `Hand.grab_area/magnet_area` спрятаны, доступ через `get_grabbable_bodies()/get_magnet_bodies()`. ACTION_X — `StringName`-константы вместо литералов. Slam'овские визуалы переехали в pool с валидацией перед reuse и кладутся в `effects_root_path` (fallback на `current_scene`). Захваченный рукой Item исключается из Slam через `_coord.get_held_item`. `Hand.lock_position(true)` теперь требует `set_locked_position` для ручного перемещения — Flick больше не пишет в `global_position` напрямую. `Hand.smoothed_velocity()` не накапливает движение во время orbit'а — иначе на release щелбана накапливалась паразитная скорость броска. `_is_grabbing` через polling вместо edge-events — фикс залипания после Flick.
    - **Enemy: FSM в базе.** Перенёс APPROACH/WINDUP/STRIKE/COOLDOWN из Skeleton в `Enemy`. Подкласс реализует только `_perform_strike(target)` плюс хуки `_on_state_enter/_on_state_exit`. Заодно `_perform_strike` перепроверяет `get_active_target()` и тихо выходит, если цель умерла — раньше падал. Lunge у Skeleton идёт через `_apply_velocity_change`, не дёргая `_on_knockback` (иначе сам же отменял свой удар).
    - **`ShatterEffect` (`scripts/shatter_effect.gd`, `class_name ShatterEffect`, `RefCounted` со static `spawn`).** Эффект «рассыпание на смерти» вынесен из `Skeleton` — теперь общий, с одним `SceneTreeTimer` на пачку (вместо Tween-per-fragment).
    - **Camp.** Отвязка от `CharacterBody3D`: `target_path` теперь любой `Node3D`, stationary-чек через delta-position (а не `Tower.velocity`). `_exp_decay` вместо frame-зависимого `lerp`. Раздельные `_deploy_hold/_pack_hold` таймеры. `_ground_y_at` через terrain-raycast по `Layers.TERRAIN` — палатки идут по рельефу. `part_nodes` — явный `@export Array[StaticBody3D]` с fallback'ом на имена `CaravanPart*`. 4 материала палаток свёрнуты в один общий `Material_part`.
    - **Tower.** `class_name Tower`. `_push_kinematic` — через `Pushable.try_push`, без `is Enemy`. Контакт-трекер `_contacts_last` чистится по `tree_exited` — больше нет zombie-ключей. `fall_threshold` вынесен в `@export`. `_floor_normal_threshold` считается через `cos(get_floor_max_angle())` вместо хардкода 0.7. Debug-лог стен скипает kinematic-pushable (50 скелетов больше не спамят «коллизия со стеной»).
    - **Item.** `class_name Item`, регистрируется в Damageable + Pushable + Grabbable. `apply_push` ранний return при `freeze=true` — контракт Pushable обещает, что пуш применён, либо явный no-op.
    - **EventBus.** Аргументы сигналов ослаблены до `Node3D / Node` — autoload больше не зависит от `Item/Enemy`. Слушатели сами кастуют, когда нужно.

28. **Камера: orthographic → perspective + наклон/fov-tuning** (`cc82894 → a1dcc1f`).
    - `cc82894` — вернули перспективу. `Camera3D` была orthographic с `size=30` из `(12, 12, 12)`, теперь обычная проекция из той же точки с `fov=60` — фрейминг визуально близкий, но появилась глубина.
    - `f3de28d` — наклон сильнее сверху (~60° вниз вместо ~35°), типичный top-down ARPG-вид.
    - `a77d9b0` — фикс: первая попытка наклонить Transform3D перепутала строки/столбцы базиса (та же ошибка, что в §7.3.№1). Перепаковано корректно.
    - `64983c2` — `fov: 60° → 40°`, позиция отодвинута × 1.6. Широкий 60° давал fisheye-эффект на близкой дистанции; узкий fov + отступ дают плоский «телефото»-look.
    - `40815c0 → a1dcc1f` — pitch финально подкручен `60° → 57° → 55°`. ~5% менее top-down, чем сразу после `f3de28d`.
    - **Итог:** `Camera3D` локальный transform = `Transform3D(0.7071, -0.58, 0.405, 0, 0.572, 0.82, -0.7071, -0.58, 0.405, 18, 36.4, 18)`, `fov = 40°`. Параметры в §5.3 актуализированы.

29. **Гномы и кучи ресурсов** (`ac7d52a → 97a4873`). Лагерь перестал быть просто декорацией: при развёртке палатки выпускают обитателей, которые сами ищут кучи ресурсов на карте и носят их в anchor.
    - **`ResourcePile` (`scenes/resource_pile.tscn`, `scripts/resource_pile.gd`, `class_name ResourcePile extends RigidBody3D`).** Куча ресурсов на полу. Поля: `units: int` (запас, декрементируется через `take_one()`) и `hp: float` (урон от руки/slam'а, независим от units). Полностью participating в тех же контрактах, что и Item: `Damageable.register` + `Pushable.register` + `Grabbable.register` в `_ready`. Это потребовало нового `Grabbable`-контракта (этап ниже) — иначе пришлось бы делать `class_name ResourcePile extends Item`, что ломает декомпозицию (куча — не «предмет», у неё своя семантика). Сейчас Hand хватает её ровно тем же кодом, без правок руки.
    - **`Gnome` (`scenes/gnome.tscn`, `scripts/gnome.gd`, `class_name Gnome extends CharacterBody3D`).** По 2 гнома на палатку, спавнятся `Camp._spawn_gnomes()` в `_ready`. FSM из 6 состояний: `IN_TENT` (приклеены к палатке, скрыты, дефолт в каравне) → `SEARCHING` (vision-сканирование куч + патруль случайными точками в `search_radius`) → `COMMUTING_TO_PILE` → `COMMUTING_TO_BASE` → `RETURNING_TO_TENT` (на свёртку лагеря, по дороге роняют что несли) + `IDLE_NEAR_BASE` (анти-livelock-чек: если в мире нет ни одной кучи с `units > 0`, гном не патрулирует впустую, а ходит вокруг anchor'а в `idle_radius`). Связь с лагерем — `setup(camp, home_tent)`, гном не сканирует Tower/EnemySpawner.
    - **Vision-based discovery вместо broadcast'а** (`550dd1c`, `2951fb1`, `6ab8cf1`). Первая итерация делилась найденными кучами через общий список Camp'а — нашёл один, остальные сразу побежали. Получалось «коллективное всезнайство», нет геймплея поиска. Переделано: каждый гном сам сканирует кучи в радиусе `vision_radius=10` от своей позиции каждый кадр (через `get_tree().get_nodes_in_group(ResourcePile.GROUP)`); маленький радиус → дольше искать, большой → почти всезнайство. Вместо broadcast — claim-чек: гном пропускает кучи, на которые другой гном уже идёт (`Camp.is_pile_claimed(pile, exclude=self)`), чтобы каждый «нашёл своё». Гном видит кучу только если `units > 0` и `freeze=false` (рука не держит).
    - **Двухфазная FSM сбора** (`fe949b1`). Разделил ФАЗА 1 (поиск) и ФАЗА 2 (челнок). Поиск — патруль до vision-hit'а; челнок — ходка туда-обратно, пока куча не пуста или не пропадёт. На опустошении/потере — обратно в SEARCHING (без отдельного «возврата к базе порожним», иначе анимации кишели бы переходами). После закрытия рукой/уничтожения куча роняет несомое (`_on_pile_lost`).
    - **Контент: 20 куч в трёх кольцах** (`38d15a2`). Было 8 ровным кольцом, стало 20 в трёх концентрических кольцах вокруг центра — даёт ощутимую разницу между гномами с разным `vision_radius` и нагружает path-finding (когда добавим).
    - **Camp перешёл с 2-state на 3-state** для свёртки. Был `CARAVAN_FOLLOWING / DEPLOYED`, стал плюс `PACKING_RETURNING`: при нажатии R на свёртку сразу не сворачиваемся — гномам надо дойти до своих палаток. `request_return()` рассылается всем гномам, состояние держится пока `_all_gnomes_home()` не вернёт true, и только потом `_finalize_pack` → `CARAVAN_FOLLOWING`. Палатки в это время стоят на местах развёртки (используется `_update_deployed`).
    - **Новый контракт `Grabbable`** (`97a4873`). До куч `Hand:PhysicalActions._find_closest_item` и подсветка кандидата работали через `body is Item`. Это исключило бы ResourcePile из захвата, не наследуя её от Item. Решение — третий контракт: `scripts/grabbable.gd`, `class_name Grabbable`, `RefCounted` со static `register/is_grabbable`. Фильтр в Hand сменился на `Grabbable.is_grabbable(body) and body is RigidBody3D and rb.mass < max_lift_mass`. Item, ResourcePile (и любой будущий «можно схватить» RigidBody3D) попадают в захват без правок руки. `set_highlighted` объявлен частью контракта; Hand зовёт его через `has_method` для defensive-coding.
    - **Семантика в EventBus.** ResourcePile использует уже существующие `EventBus.item_damaged/item_destroyed` — куча по контракту неотличима от Item для cross-cutting слушателей (UI/счёт ресурсов разнесёт их при необходимости через `target is ResourcePile`). Гномы получили собственные `gnome_damaged/destroyed` (нужно UI-счётчику погибших), палатки — `camp_part_damaged/destroyed` (телеграф разрушения лагеря).

30. **Аудит и синхронизация спеки с кодом.** После накопления изменений (этапы 25–29) спека и код разошлись. Прошёлся аудитом: маски, сигналы шины, FSM-состояния, edge-cases.
    - **Camp `_deployed_targets` sync с `_parts`.** Раньше `_on_part_destroyed` делал только `_parts.erase(part)`, не трогая `_deployed_targets`. Если палатка `_parts[i]` погибала в DEPLOYED, индексы съезжали — оставшиеся палатки `_update_deployed` поедут к чужим точкам кольца. Теперь удаляется по индексу из обоих массивов синхронно.
    - **Camp реакция на `tower_destroyed`.** Camp подписывается на `EventBus.tower_destroyed` и обнуляет `_tower`. До этого караван продолжал follow'ить мёртвую (физически ещё существующую) Tower-ноду — `_update_caravan_follow` тянул палатки за статичной целью. Теперь null-чек прерывает follow.
    - **Gnome wander clamp.** `_random_point_around` при `search_radius=300` на карте ±95 уходил за пол. Добавлен `wander_map_half_extent: float = 95.0` и clamp в итог — симметрично `Skeleton.wander_map_half_extent`.
    - **Магические маски через `Layers`.** Литералы `slam_mask=18` / `target_mask=16` / `cursor_raycast_mask=67` заменены на `Layers.MASK_HAND_SLAM` / `Layers.ENEMIES` / `Layers.MASK_HAND_CURSOR`. Введена новая константа `MASK_HAND_SLAM = ITEMS | ENEMIES = 18` — Slam намеренно отличается от `MASK_HAND_TARGETS = 82` (без MOUNTED_MODULE: смонтированный модуль нельзя сбить хлопком, только хватом руки). Раньше спека сама себе противоречила: в одном месте slam_mask назван как `MASK_HAND_TARGETS = 18`, в другом — `MASK_HAND_TARGETS = 82`.
    - **EventBus сигналы доведены до фактического состояния.** В список добавлены `gnome_damaged/destroyed`, `camp_part_damaged/destroyed`, `module_mounted/unmounted` — они эмитятся в коде с этапов 26–29, но в спеке таблицу обновить забыли.

31. **LOD для скелетов** (под масштаб 100+ врагов). До этого этапа все скелеты работали на полной частоте: distance-чек до цели + vision-скан группы каждый физкадр + полный AI-tick. На 50 это норм, на 200+ просадка fps от per-instance overhead'а; на 1400 — стресс-тест показал ~5fps (главные виновники — broad-phase коллизий между 1400 CharacterBody3D и 1400 `move_and_slide` каждый тик). Решение в две итерации:

    **Итерация A (мягкий LOD):**
    - **Distance-based LOD по 3 уровням** (`enum LodLevel { NEAR, MID, FAR }`). Граница задаётся экспортами `lod_near_distance=25` / `lod_far_distance=50`. Дистанция меряется до **активной камеры**, не до Tower (Tower может queue_free, камера живёт всегда).
    - **`vision_scan_interval` × (1/2/4)** и AI-tick каждый 1-й / 2-й / 3-й кадр. Skip AI — **только в `APPROACH`** (в `WINDUP` декрементится `_state_timer` замаха, см. `enemy.gd:197-198`; пропуск заморозил бы скелета).
    - **Anti-«волна»:** `_lod_check_timer` и `_lod_ai_tick_counter` рандомизируются в `_ready`. Период LOD-чека `0.5с`.

    **Итерация B (холодный режим FAR — после стресс-теста на 1400 скелетов):** мягкий LOD не справился — `move_and_slide` и broad-phase 1400 тел оставались главной нагрузкой. Для FAR ушли в радикальный режим:
    - **`collision_layer = 0`, `collision_mask = 0`** — FAR-скелет невидим для broad-phase. Никаких взаимных коллизий, никаких блокировок башни. На 1000+ это убирает квадратичную нагрузку.
    - **Skip `move_and_slide` целиком.** Вместо неё `_far_step(delta)` делает простое `global_position.x/z += velocity * delta`. Y не считается (плоский пол).
    - **`_far_step` сохраняет:** `_knockback.tick(delta)` (иначе lunge через `_apply_velocity_change` навечно бы улетал), декремент `_state_timer` для COOLDOWN, AI-step с LOD-skip, `Damageable.try_damage` через `_perform_strike` (урон не зависит от collision-layer'ов).
    - **Side-effect:** FAR-скелеты сквозят друг друга и палатки вне камеры. Игрок этого не видит. Когда подходят ближе (становятся MID) — `_apply_lod_physics_mode` восстанавливает collision, и со следующего тика снова полная физика через `super._physics_process`.
    - `_set_lod_level` идемпотентен — collision_layer write случается только при реальной смене уровня, не каждые 0.5с.

    **Итерация C (фикс slam'а на FAR-скелетах):** после теста итерации B обнаружили, что при отзумленной камере slam перестаёт убивать скелетов — урон не приходит. Причина: `collision_layer = 0` делает FAR-скелета невидимым **для всего**, включая `PhysicsShapeQuery` от slam'а. При зуме=2.5 Camera3D в ~111м от центра карты, и почти все скелеты становились FAR от Camera3D — рука теряла цели. Двойной фикс:
    - **Новый слой `Layers.COLD_ENEMY` (бит 8 = 128).** FAR-скелет теперь на этом слое вместо `0`. Другие скелеты, башня, турель НЕ сканируют COLD_ENEMY (их маски не содержат бит 8) — broad-phase не нагружается. Но `MASK_HAND_TARGETS = 210` и `MASK_HAND_SLAM = 146` включают COLD_ENEMY — рука и slam доставают FAR-скелетов. `collision_mask = 0` сохраняется — FAR сам никого не сканирует.
    - **LOD-якорь сменён с Camera3D на CameraRig** (`camera.get_parent()`). CameraRig lerp'ится за Tower, зум на него не влияет (зум меняет только `Camera3D.position × _zoom` относительно rig'а). Границы LOD теперь стабильны независимо от зума.

    **Что осталось не оптимизировано:** рендер. 1400 MeshInstance3D = 1400 draw calls, frustum culling Godot отсекает невидимые, но vertex transform всё равно стоит. Дальнейший buster — MultiMesh + GPU-instanced рендер с per-instance color (windup glow через color override вместо смены material_override). Большой refactor, отложен до явной необходимости.

32. **Волновая система с режиссёром фаз** (`df7cdb0`). EnemySpawner раньше был «P → партия по кольцу вокруг target». Этого мало для игрового цикла — нужен ramp-up, поддержание популяции, периодические волны на лагерь. Решение в два слоя:
    - **EnemySpawner** остался низкоуровневым «как»: публичный API `spawn_at / spawn_uniform / spawn_ring / spawn_group / kill_all_skeletons`. Старый `spawn_wave()` оставлен как debug helper. P-биндинг убран отсюда.
    - **WaveDirector** (новый, см. §5.5.4) — высокоуровневый «когда и сколько». Фазы IDLE → RAMP (20→50 за 30с) → MAINTAIN (replenish с гистерезисом 20 + волны каждые 60с группой по 10 на ближайший лагерь). P — старт/рестарт кампании. O — немедленная волна.
    - **Skeleton.forced_target** — aggro-fallback. Wave-скелет, заспавненный в 50м+ от лагеря (за пределами vision_radius=12), идёт на назначенную палатку. Когда подходит на 12м, vision захватывает гномов на периметре, и приоритет переключает агро на ближайшего гнома (защитники-лучники «перехватывают» волну).
    - **Скелеты охотятся на существ, не на строения** (`_scan_target` приоритет: гном > палатка). Палатка берётся целью только когда гномов в зоне нет.
    - **Camp.current_center** — реальный центр лагеря через среднее живых палаток. Узел Camp в caravan-mode статичен, двигаются только дочерние палатки — раньше WaveDirector считал safe-радиус от `(0,0,0)` после перемещения Tower и спавнил волны прямо в зоне огня.
    - **Возврат к одному Camp у Tower** — 6 POI-поселений (этап 27) убраны для упрощения теста: один караван tent_count=4 (caravan-mode, R разворачивает). Конструкция масштабируется обратно при необходимости — `WaveDirector.camp_paths` принимает массив.

33. **Баллистика стрел и прокачка точности защитников** (`956b7dc`).
    - **Arrow.gd переписан на баллистику.** Был прямой выстрел с фиксированной скоростью; стало — `_compute_launch_velocity` решает задачу о броске (низкая дуга через discriminant), `_velocity` интегрируется по гравитации в `_physics_process`, меш ориентируется носом вдоль скорости каждый кадр. Параметры: `gravity=6` (настильнее мирового 9.8), `lifetime=4с`. На v=22 максимальная дальность ~80м.
    - **DefenderGnome.attack_radius 15→22.5** (×1.5).
    - **Прокачка через выстрелы.** Каждый выстрел инкрементирует `_shots_fired`, фактический разброс `current_inaccuracy_radius()` считается по логарифмической кривой `base / (1 + shots/half)` от стартового `base_inaccuracy_radius=1.5м` с `experience_half_shots=100`. Ветеран после 500 выстрелов имеет разброс 0.25м (~стабильно цепляет тело скелета capsule_radius=0.4); новичок — 1.5м (~7% точность). Опыт per-инстанс, на смерти теряется (P-рестарт через `Camp.reset_population` обнуляет всех). Геймплей-стимул: беречь защитников, не рестартить кампанию.
    - **Explicit radius-фильтр** для PhysicsShapeQuery в DefenderGnome и OctagonTurret. Godot 4.6 подмешивает результаты AABB-broadphase (тела вне sphere). Без фильтра защитники видели цели на 50м+ при `attack_radius=22.5` (наблюдалось в логе).

34. **GameplayHud — игровой HUD** (`df7cdb0`). Левая панель: индикаторы способностей (1=хлоп, 2=щелк) под PerfHud. Правая панель: статус лагеря (гномы/лучники/уровень=число палаток) с цветными иконками-плашками. Считывает три публичных геттера Camp каждые 0.25с. Раздел 9.3.

35. **Большая перф-сессия под 2000 скелетов** (`1f97c5a`). Стресс-тест через `]` (новый action `debug_stress_2000`, см. §5.5.4) показал на 2000 скелетов FPS 7 / Process 6мс / **Physics 29мс** / Draw calls 25 — узкое место именно физика. Серия итераций по локализации и устранению боттлнеков:

    **PerfHud расширен** (см. §9.2). К FPS+LOD добавлены `Process` ms / `Physics` ms / `Draw calls` / `Objects` / `Mem` MB / `Nodes`. Без этих счётчиков «оптимизировал бы вслепую» — методология теперь: P→старт→]→спавн 2000→читать счётчики→локализовать.

    **(а) `MASK_SKELETON` 55 → 39** — убран бит ENEMIES. Скелеты больше не сталкиваются друг с другом физически (broad-phase + slide-iterations). Цена: `Enemy._push_neighbor` lunge-domino перестаёт работать (slide-collision между скелетами не регистрируется). Документировал в `layers.gd` и `skeleton.gd`.

    **(б) Frustum-aware LOD** (`lod_offscreen_half_angle_deg=60`). Скелет вне cone'а перед камерой → форсируем FAR независимо от расстояния. Кластер NEAR/MID вокруг Tower при типичной FOV сокращается ~50%. Без эксплойтов «отвернись и не получишь удар» — симуляция продолжает работать в FAR-режиме (с divisor=3), просто дёшево.

    **(в) MID-divisor с velocity-компенсацией** (`lod_mid_tick_divisor=3`). MID-скелеты тикают на 20Гц вместо 60Гц. Скорость сохраняется через `velocity *= divisor` в `_ai_step` — один `move_and_slide` переносит N кадров пути. Tunneling-проверка: 2.7×3×0.0167=0.135м/тик при радиусе 0.4м — запас ×3.

    **(г) Layer FRIENDLY_UNIT для гномов** (`Layers.FRIENDLY_UNIT = 256`, layer 9). Гномов и DefenderGnome'ов перенёс с ACTORS(4) на FRIENDLY_UNIT(256). MASK_SKELETON FRIENDLY_UNIT не включает → skel-gnome пары в broad-phase не формируются. На 126 гномах в плотной толпе скелетов — это была одна из главных нагрузок. Урон по гномам идёт через `Damageable.try_damage` на STRIKE-фазе (контракт, не physics-collision) — смена слоя не сломала геймплей.

    **(д) Tower.mask 31 → 15** (без ENEMIES, [scenes/tower.tscn](scenes/tower.tscn)). Tower сам — CharacterBody3D, движется и `move_and_slide`. В кластере 100+ скелетов вокруг неё каждый m_a_s обходил contact-list по каждому близкому скелету. Pair всё ещё формируется (Tower.layer=ACTORS, в MASK_SKELETON), скелет упирается → bounce-off на lunge работает; только Tower сама сквозит толпу не тормозясь.

    **(е) Spatial grid для skeleton_target** (`_target_grid` static, cell=12, refresh=0.4с). Vision-сканы — главный CPU-боттлнек на 2000+ скелетах × 144 целях (палатки + 126 гномов). 720k distance-checks/сек → ~250k. Process падает с ~12мс до ~3мс.

    **(ж) Главный perf-фикс — `CollisionShape3D.disabled = true` на FAR.** Раньше FAR-скелеты лежали на `Layers.COLD_ENEMY` с `mask=0`, но broad-phase BVH всё равно индексировал AABB всех 2000 движущихся скелетов и ребилдил дерево каждый раз, когда `_far_step` двигал `global_position`. **`mask=0` НЕ убирает тело из BVH — только `disabled=true` или `layer=0`.** Теперь FAR: `layer=0, mask=0, disabled=true` — полностью исключены из broad-phase. Slam доcтаёт через group-fallback (см. §5.2.1) — второй проход по `SKELETON_GROUP` с distance²-фильтром. На 2000 элементах группы ~0.05мс на slam_cooldown=0.5с — копейки. Документировал COLD_ENEMY как зарезервированный слой.

    **(з) FAR-divisor с work_delta** (`lod_far_tick_divisor=3`, фазовый сдвиг `randi() % 6`). Даже после исключения из broad-phase 1900 FAR × 60Гц = 114k вызовов `_far_step`/сек оставались GDScript-нагрузкой. Tick на 20Гц с компенсацией `delta × N` для движения/knockback friction/таймеров.

    **(и) Boids-style avoidance** (`_skel_grid` static, cell=4, refresh=0.3с; `_apply_neighbor_avoidance`). Симптом после убирания skel-skel пар: толпа сходится в одну кучу и сквозит сама себя — некрасиво. Лечение через flocking без возврата physics-пар: 9-cell scan по spatial grid'у, linear falloff отталкивания, кап `move_speed × 0.5`. Применяется только в APPROACH/wander и не-FAR. Цена ~0.2мс/кадр на 400 NEAR/MID. Эмерджент: толпа формирует арку вокруг палатки, не клин.

    **Stress-test `]` для воспроизводимости.** Новый `debug_stress_2000` (keycode 93, `]`) в `wave_director.gd:_process` — fire-and-forget `EnemySpawner.spawn_uniform(skeleton_scene, 2000)`. Без safe-фильтра, без SpawnZone-фильтра — uniform по всему квадрату ±195м. Async-батч по 6/кадр, 5.6с до полного спавна. Кнопка задумана как ежедневный регрессионный замер, не геймплей.

    **SpawnZone: диск → прямоугольник.** Параллельно (`1f97c5a`) старый `SpawnZone.radius: float` заменён на `SpawnZone.size: Vector2`. Поворот вокруг Y живёт в transform узла; sample-точка прогоняется через `zone.global_transform`. Визуал — `BoxMesh` (1×0.04×1) с масштабированием через `transform.scale`. Видим только в редакторе (`mesh.visible = Engine.is_editor_hint()`) — игрок красные коврики не видит. EnemySpawner взвешивает зоны теперь по `area() = size.x * size.y`, не πr². Дефолт `Vector2(60, 60)` ≈ старому диску r=30 по площади.

    **Итог замеров:** physics 29мс → ~5-10мс, FPS 7 → 30-60. Дальнейший buster требует MultiMesh + GPU-instanced рендера (1900 уникальных MeshInstance3D = 1900 draw calls, frustum culling помогает но vertex-transform остаётся).

36. **Этап А ресурс-системы — типы + ResourceZone-расставлятель** (`516ddbf`). Геймдизайнер запросил 4 типа ресурсов с разными визуалами и быстрый дизайнерский UX расстановки.

    **`ResourcePile.ResourceType` enum** (GENERIC/WOOD/STONE/IRON/FOOD) + `PileShape` enum (AUTO/BOX/CYLINDER/SPHERE). Дефолтные визуалы по типу через `_defaults_for_type` (см. таблицу в §5.9). При дефолтных значениях `pile_color/pile_size/pile_shape` (BLACK/ZERO/AUTO) — берётся пресет, иначе экспорты переопределяют. CollisionShape пересоздаётся под форму (Box/Cylinder/Sphere). Logical поведение `take_one()` / hp / freeze не изменилось.

    **`ResourceZone`** (`@tool`, `class_name ResourceZone`, см. §5.9.1) — паттерн `SpawnZone` для куч. Дизайнер: drag → type/count/size → spawn на `_ready`. На запуске зоны разбрасывают pile'ы (через `call_deferred` — иначе `add_child` падает в setup'е родительской сцены). Рантайм-индикатор скрывается, в редакторе виден цветной плоский индикатор (цвет по типу — wood коричневый, stone серый, etc).

    **Этапы Б/В отложены:** многоэтапное дерево (стоит → trunk → 3 logs) и `interaction_time` на pile'е (гном «рубит/копает» N секунд). На функциональность сбора это не влияет — wood-pile = «бревно» с units=3, take_one мгновенный.

37. **ResourceZone safe-фильтр для WOOD + ужатие safe-радиусов** (сессия 2026-05-02 после docs-прохода). Геймдизайнер: «леса не должны спавниться в безопасной зоне». Параллельно — safe-радиусы (45м) ощущались избыточно большими: между лагерем и SpawnZone оставались «мёртвые» нейтральные коридоры, где скелеты wander-или без агро.

    **Публичный safe-API.** `WaveDirector` получил `is_safe_pos(pos: Vector3) -> bool` — тонкий фасад над приватным `_safe_score`. Внешние потребители (ResourceZone и любые будущие) не лезут в score-арифметику — спрашивают «эта точка снаружи safe-зон?».

    **Discovery через group, не NodePath.** WaveDirector в `_ready` добавляет себя в `&"wave_director"` (одиночка на сцене). ResourceZone в `_spawn_instances` находит его через `get_first_node_in_group` — никаких ручных `wave_director_path` инспектор-привязок. Дизайнер просто ставит зону, фильтр работает.

    **ResourceZone safe-фильтр — только для WOOD.** Сначала фильтр включался для всех типов ресурсов, но геймдизайнер уточнил: только лес. Логика — лес «глушь», вокруг поселений вырубленный; камень/железо/еда могут стоять под защитой (каменоломня, ферма, склад). В `_spawn_instances`: `if resource_type == WOOD: wave_director = get_first_node_in_group(...)`, иначе `wave_director = null` и safe-чек не работает. Для WOOD: внутри 10 попыток приоритет safe → spacing; если все unsafe — pile пропускается (count может выйти меньше заявленного; `push_warning("...WOOD...")` с числом skipped).

    **Safe-радиусы 45 → 32 (~30% меньше).** `wave_safe_radius` и `poi_safe_radius` уменьшены параллельно. Новый radius чуть внутри полной зоны огня защитника (12 + 22.5 = 34.5м) — спавн ближе к лагерю, скелеты быстрее доходят до боя, меньше нейтральных коридоров. WOOD-фильтр и `_pick_safe_pos` для скелетов используют один радиус → консистентно.

    **`ResourceZone.count` лимит 100 → 1000** (`dbddd84`). Дизайнеру нужны 100+ куч в плотных лесах и крупных каменоломнях; прежний `@export_range(1, 100)` отсекал слайдер. Сама `_spawn_instances` масштабируется линейно (10 попыток rejection sampling × count), на 1000 куч с `min_spacing=1.5` зоне нужна площадь ~50×50м минимум.

38. **Code review fix'ы — 4 находки** (`f9649a2`). После большой сессии запустил трёх параллельных code-review агентов на накопленные изменения skeleton.gd / hand_physical_slam.gd / resource_*.gd / wave_director.gd / scenes-masks. Из 30+ находок (большинство — косметика и edge-cases) выделил 4 **HIGH-priority** для одного коммита:

    - **`ResourcePile._dying`-флаг.** `take_damage` и `take_one` независимо могли довести pile до уничтожения в одном кадре — `destroyed.emit()` срабатывал дважды, EventBus.item_destroyed эмитился двойным сигналом. `queue_free` идемпотентен сам по себе, но сигнал нет → UI/счётчики реагировали бы дважды. Добавлен `_dying: bool` флаг, ставится перед `destroyed.emit()` в обеих ветках, проверяется на входе.

    - **`ResourceZone` валидирует `pile_scene`.** Раньше `if pile is ResourcePile` тихо пропускал присвоение `resource_type`/`units` если дизайнер случайно подменил сцену на не-ResourcePile — pile добавлялся в дерево с GENERIC дефолтами и units=5, причина не очевидна. Теперь `push_error` + `queue_free` инстанса + `continue`.

    - **`Skeleton._apply_lod_physics_mode()` в `_ready()`.** Initial `_lod_level=NEAR` раньше полагался на маски в `skeleton.tscn` (16/39). Сейчас совпадает, но любая правка маски в `.tscn` тихо ломала бы первый кадр всех NEAR-скелетов до первого LOD-перехода (lod_check_interval=0.5с). Явный вызов делает контракт автономным.

    - **MID/FAR-divisor counter reset на knockback exit.** `Skeleton._physics_process` теперь запоминает `was_knockback_active := _knockback.is_active()` **до** super/_far_step и сравнивает после. На переходе active→inactive — обнуляет `_mid_phys_tick_counter` и `_far_phys_tick_counter`. Без этого счётчик мог застрять на skip-фазе во время knockback'а → следующий кадр после восстановления был бы skipped → AI хочет двигаться, скелет «глюк-замораживается» на ~16мс (MID) / ~50мс (FAR).

    Остальные находки (stale comment в `camp.gd:17`, sentinel `Color.BLACK` коллизия, `Quest unbounded advance`, `_pick_safe_pos` без минимума, `_resolve_visual_params` дублирование, per-instance materials cost) зафиксированы, но отложены — не баги-сейчас.

39. **POI визуально стал костром** (коммиты `2d9f6a5`..`3398a5a`, `a25de28`, `855bb5f`, `1650683`, `a332b5b`). Геймдизайнер: «вместо диска и палки на POI поставим костёрок». Серия итераций по доводке визуала (см. §5.11 для финального состояния).

    **Архитектурно (v1):** заменили `quest_actor.tscn` (была капсула с цветом по состоянию) на новую структуру: 4 наклонённых полена в форме вигвама + FlameCore (статичный sphere с emission) + FlameParticles (GPUParticles3D) + SmokeParticles (GPUParticles3D с предоставленным шейдером дыма) + OmniLight3D. `poi_marker.tscn` (был жёлтый плоский диск r=2.5) ужат до маленького круга золы r=0.95.

    **`quest_actor.gd` переписан** под структурный костёр: `_clone_log_material` делает per-instance копию `Material_log` (иначе все QuestActor'ы делили бы один override и emission переключался бы у всех разом). `_apply_locked/_active/_completed` управляют `_log_material.emission`, `_flame_core.visible`, `_flame_particles.emitting`, `_smoke_particles.emitting/amount`, `_light.light_color/light_energy`.

    **Smoke shader pipeline** (от Loop-Box/Stylized-Smoke-For-Godot4.5):
    - `resources/smoke.gdshader` — voronoi-нойз UV-скролл + alpha-curve через `COLOR.a` от ProcessMaterial.
    - `resources/smoke_color_gradient.tres` (тёмный → светлый), `smoke_voronoi_noise.tres` (cellular noise 256×256, frequency=0.04), `smoke_alpha_curve.tres` (peak в середине → «клочья»).
    - `resources/smoke_material.tres` — ShaderMaterial с биндингами текстур.

    **Главный визуальный фикс v2:** в первой версии `SmokeParticles.draw_pass_1 = QuadMesh 0.7×0.7` без `particle_flag_rotate_y` → quad'ы статичны в +Z, в перспективе превратились в «большие чёрные кубы». Изучил Loop-Box demo-проект через WebFetch; ключевые открытия:
    - У них специальный `Mesh.tres` (190KB, 9408 индексов) — объёмная сетка из множества quad'ов под разными углами, **необходимая** для шейдера.
    - В ParticleProcessMaterial критично `particle_flag_rotate_y = true` (каждая частица случайно вращается по Y) + `angle_min/max = ±90°` (рандомный стартовый поворот).
    - `Vor_Scale=0.8, Alpha_Clip=0.0` (у меня по дефолту было 3.0 и 1.0).

    Скачал их `Mesh.tres` → `resources/smoke_mesh.tres`, подключил как `draw_pass_1`. Чёрные кубы исчезли.

    **Пламя на том же mesh'e v3:** сначала `FlameParticles` рисовал плоские «жёлтые кубики» (тот же баг что у дыма). Использовал `smoke_mesh.tres` для пламени тоже — он трёхмерный, billboard не нужен. Material — `StandardMaterial3D` UNSHADED + emission orange (без billboard_mode, конфликтовал бы с `particle_flag_rotate_y`).

    **Тонкая настройка геймдизайнером** через инспектор: `amount_ratio` для регулирования density без изменения базового `amount`, `lifetime_randomness=0.09`, `gravity Y=2.0` (дым взлетает выше). Color/cast_shadow тюнинг.

40. **Slam-визуал — distortion + ripple shader + пыль** (коммиты `5bc9691`..`3c9fc62`, `a332b5b`). К прежнему StandardMaterial3D-пузырю с emission и tween по альфе добавили серьёзный пост-эффект.

    **Distortion shader** (`resources/slam_distortion.gdshader`, от внешнего автора): `unshaded, cull_disabled, blend_mix`. SCREEN_TEXTURE-преломление через `NORMAL.xy * distortion`, chromatic aberration по edge_factor, accretion disk glow, depth-aware base color (`depth_texture` сравнение → `color1` за threshold-ом vs `color2` рядом с поверхностью), SDF-noise dissolve через recursive `sdFbm`, бегущая ripple-волна (`sin(dist × frequency - time × speed)`).

    **`_spawn_slam_visual` переписан:** `material_override = load(slam_distortion_material.tres).duplicate()` per-instance (без duplicate параллельные slam'ы из пула топчут друг друга через `set_shader_parameter`). Tween parallel:
    - `mesh.scale: ONE → ONE × (slam_radius / 0.5)` (TRANS_QUAD, EASE_OUT — резкий старт).
    - `shader.intensity: 1.0 → 0.0` (TRANS_CUBIC, EASE_IN) — master-control шейдера.
    - `shader.ripple_time: 0.0 → 1.0` (LINEAR) — волна разбегается, шейдер сам гасит через `(1 - ripple_time)`.

    **`_set_slam_param(value, mat, name)` helper** нужен потому что `Tween.tween_property` не умеет в `shader_parameter`'ы (читаются/пишутся через `set_shader_parameter`, не через property path). Используется `tween_method` с `.bind(mat, name)`.

    **`shader.ripple_center` ставится в WORLD-координатах** (= origin) перед стартом tween'а — шейдер считает дистанцию от world_position фрагмента, поэтому центр волны не смещается при росте сферы.

    **Bug-фикс: sphere unit-radius=0.5.** Шейдер использует `sphere_dist = length(object_position) - 0.5` для SDF-noise dissolve. Первая версия использовала `SphereMesh.radius=0.2`; `length(object_position) ≤ 0.2`, sphere_dist ∈ [-0.5, -0.3] всегда → `noise_alpha_raw = 0` → `dissolve_alpha = 0` → ALPHA = 0 → пузырь невидим. Поменял на radius=0.5/height=1.0, размер компенсируется через `target_scale = slam_radius / 0.5 = 10`.

    **Тюнинг геймдизайнером:** color1/color2 → ч/б нейтральный (slam = физ-удар, не магия), `chromatic_aberration=0.0`, `intensity_2=0.3` (резкие концентрические полосы dissolve вместо размытия), затем переход на голубой accretion (синяя ударная волна). Все параметры в `slam_distortion_material.tres` — открой в инспекторе для крутилок.

    **Пыль при ударе** (`9084ad7`..`3c9fc62`): добавлена `_spawn_slam_dust(origin)` — fire-and-forget GPUParticles3D без пула. `amount=72`, `lifetime=0.9с`, `explosiveness=1.0` (все частицы вылетают в первом кадре одним «взрывом»). Cleanup через `create_timer(lifetime + 0.2с).timeout.connect(queue_free)`. Ассеты: `slam_dust_material.tres` (StandardMaterial3D billboard серый), `slam_dust_process.tres` (sphere emission, spread 80°, velocity 3.5–6.5 м/с, gravity -2.5, damping). Слой пыли визуально весомо подкрепляет удар.

41. **Большое код-ревью: 13 фиксов C/H/M-уровня** (этот коммит). Прогнал 6 параллельных агентов по всем подсистемам, синтезировал отчёт, прошёлся по списку.

    **CRITICAL** (блокирующие баги, без которых лагерь/визуал ломаются):
    - `Camp.PACKING_RETURNING` deadlock: один зависший гном (рука держит, упал с обрыва, застрял в коллизии) залипал весь караван навсегда — `_all_gnomes_home` никогда не возвращал true. Добавил `pack_timeout=12с` и `_pack_elapsed`-таймер: если за это время не все дома — форсированный `_finalize_pack` с логом числа зависших.
    - `Camp` orphan-гномы: при гибели палатки гномы с `_home_tent → freed` оставались сиротами; их `request_return → _tick_returning` сразу `_enter_in_tent` на текущей точке (невидимы где попало в поле), а в `CARAVAN_FOLLOWING` IN_TENT-приклейка к null tent'у не работала — не двигались с караваном. Добавил `_reassign_orphan_gnomes(dead_tent)` в `_on_part_destroyed`: ищет ближайшую живую палатку и зовёт `gnome.set_home_tent(new_home)`. Публичный API в `gnome.gd`: `get_home_tent()`/`set_home_tent(Node3D)`.
    - `QuestActor` SmokeParticles cough: переключения состояний `locked/active/completed` писали `_smoke_particles.amount = N` — Godot пересоздаёт буфер симуляции при изменении `amount`, дым на кадр пропадает и стартует заново («икота»). Заменил на `amount_ratio`: `amount` зафиксирован максимумом из `.tscn` в `_ready` (поле `_smoke_amount_max`), три состояния пишут только `amount_ratio` (1.0 / 5÷max / 3÷max).
    - `Skeleton._apply_neighbor_avoidance` self-detection drift: фильтр своей же позиции через `if d_sq < 0.0001: continue`. Snapshot обновляется раз в 0.3с, а скелет успевает уйти на ~0.81м — d_sq против собственной stale-копии может быть 0.5+ м². Эпсилон-чек пропускал self как чужого соседа, давая фантомный push в точку, откуда мы только что пришли. Заменил на сравнение по идентичности ноды: `if entry[1] == self: continue` (не зависит от движения).

    **HIGH** (производительность и надёжность):
    - `Gnome._scan_vision` O(G×P): 126 гномов × 100 куч × 60Гц = 756k distance-checks/сек. Добавил статический spatial-grid `Gnome._pile_grid` (cell=10м=vision_radius, refresh раз в 0.5с лениво) — по аналогии со `Skeleton._target_grid`. `_scan_vision` теперь смотрит только 9 cell'ов, `_world_has_any_pile` редуцируется до `not _pile_grid.is_empty()`. Снижение ~10× в плотных зонах. Stale-погрешность ≤0.5с допустима — кучи почти статичны (RigidBody freeze=false, но обычно лежат).
    - Frustum-override hysteresis (`Skeleton`/`Gnome`): на самой границе cone-угла LOD флипал FAR↔NEAR/MID каждые `lod_check_interval` (0.5с) с пересчётом `collision_layer` и broad-phase rebuild'ом. Добавил `_lod_offscreen_cos_exit = cos(half_angle + 5°)`: вход в FAR по основному `_lod_offscreen_cos`, выход — только когда заходим в cone глубже на 5°. Скелет/гном на границе уже не дёргает физический режим.
    - `HandPhysicalActions._held` lifecycle race: `_update_held_position` каждый кадр писал `global_position` в потенциально freed RigidBody (если slam-damage в текущем тике уничтожил pile, который рука держала). Добавил guard'ы `is_instance_valid(_held) and not is_queued_for_deletion()` в начале `_physics_process`, в `_update_held_position` и в `_release` (с обнулением ссылки если invalid).
    - `HandPhysicalSlam` tween orphan: `Tween.tween_method(_set_slam_param.bind(mat, ...))` держит callable на self; если HandPhysicalSlam уйдёт из дерева mid-tween (рестарт сцены), bind на self.method указывает на freed-объект. Добавил `is_instance_valid(mat)` в `_set_slam_param`. Также `_exit_tree` чистит `_slam_visual_pool` через `queue_free`.
    - `ResourceZone` ordering: `_spawn_instances.call_deferred()` гарантирует idle-фрейм после `_ready`-цепочки, но `WaveDirector.add_to_group` в его `_ready` мог не отработать к этому моменту (порядок _ready детерминирован, но хрупок — call_deferred выполняется в idle-frame перед физикой следующего кадра, после всех _ready'ев в дереве). Заменил на `await get_tree().process_frame` явно — после await все _ready точно отработали. Также добавил `if not is_inside_tree(): return` после await на случай если зону удалили.
    - `ResourceZone` type-check на is_safe_pos: брал `get_first_node_in_group(&"wave_director")` без проверки `has_method("is_safe_pos")` — если в группе окажется чужая нода (тестовый стаб, перепутанные группы), упало бы на `wave_director.is_safe_pos(world)`. Теперь `if candidate.has_method("is_safe_pos")` — иначе warning и safe-фильтр отключён (лучше чем падать).
    - `ResourceZone` queue_free guard: `pile.queue_free()` вызывался на любом `pile`, который не extends ResourcePile. Теоретически `PackedScene.instantiate()` может вернуть Object без Node-предка (нестандартные сцены) — без guard'а упало бы «Nonexistent function 'queue_free'». Добавил `if pile is Node: (pile as Node).queue_free()`.
    - `smoke.gdshader` ALPHA_SCISSOR vs depth_prepass_alpha conflict: исходный Loop-Box шейдер прописывал и `render_mode depth_prepass_alpha`, и `ALPHA_SCISSOR_THRESHOLD = COLOR.a`. Это два взаимоисключающих режима: первый — плавный градиент с записью в depth, второй — бинарный clip. Godot 4.6 трактует ALPHA_SCISSOR как cutout только при `alpha_to_coverage`/без depth_prepass_alpha; легаси-артефакт в шейдере был mute, но создавал концептуальную путаницу. Удалил `ALPHA_SCISSOR_THRESHOLD` из fragment'а и параметр `Alpha_Clip` из uniform'а и `.tres`.

    **MEDIUM:**
    - `MountSlot._mount` re-entrance + zombie-detach: защёлку `_mounted = module` поставил **до** `module.attach_to_slot(self)` (re-entrance-protection если внутри attach сигналы вернутся в `_on_hand_released`). Добавил one-shot подписку на `module.unmounted`: если другой слот через `attach_to_slot` перехватит модуль, мы получаем сигнал и сбрасываем стейл-ссылку через `_on_module_force_detached` (проверяет `_mounted.get_slot() != self`).

    Все фиксы покрыты документирующими комментами в коде с описанием **причины** (incident / risk / mechanism), не только «что делает».

42. **POI-driven gameplay loop (3 коммита)**. Геймдизайн-петля «лагерь только в POI, угроза по нарастающей»: до этого этапа RAMP/MAINTAIN-фазы лили скелетов независимо от действий игрока, лагерь ставился где угодно, ResourceZone'ы и SpawnZone'ы балансировались параллельно на сцене. Стало: фон = всегда, POI = триггер осады.

    **K1 (`522712e`) — POI-зона + WaveSchedule + Camp deploy-gate:**
    - Новые `Resource`-классы:
      - `scripts/wave_stage.gd` (`WaveStage`): одна стадия осады с `duration / wave_interval / skeletons_per_wave`.
      - `scripts/wave_schedule.gd` (`WaveSchedule`): массив `stages`, `get_stage(idx)` клампит до последней (финальная стадия залипает).
    - `quest_actor.gd` расширен до POI-зоны: константа `POI_GROUP = &"poi_zone"`, регистрация в группе на `_ready`. Экспорты `safe_radius=12.0` и `wave_schedule: WaveSchedule` (nullable). API `is_within_safe_radius(world_pos)` для Camp-gate'а, `get_wave_schedule()` для WaveDirector'а.
    - `camp.gd` deploy-gate: `require_poi=true` (по умолчанию), `_find_poi_for_deploy()` ищет ближайший POI в группе `poi_zone`, в радиус которого попадает башня. В `_handle_input` `poi_ok` добавлен в условие запуска `_deploy_hold`. В `_start_deploy` anchor приоритет `poi.global_position > _tower.global_position > self`. Лог-фронт различает rejection-причину «башня поехала» vs «вышли из POI».

    **K2 (`7ade69a`) — WaveDirector POI-driven + фоновый прилив:**
    - Удалена RAMP/MAINTAIN фаза + параметры `initial_count / ramp_target_count / ramp_duration / replenish_threshold / replenish_interval / wave_interval` (глобальный). Заменено на `Phase.IDLE/RUNNING` (один фазовый бит) + фон + per-POI осада.
    - **Фоновый прилив** (`_tick_background`): `background_initial_count=50` мгновенно на P, `_background_target` плавно растёт `growth_per_minute=30 скел/мин` с cap'ом `background_cap=600`. Каждые `background_replenish_interval=1.0с` подспавн одного скелета через `_spawn_safe_uniform` если live < target. Игрок заходит в более грязный мир со временем — даёт «постепенно тяжелее» без ручного масштабирования сложности.
    - **POI-осада**: подписка на `EventBus.camp_deployed/camp_packed`. На deploy ищем Camp по anchor (ближайший в `_camps`) и POI по anchor (ближайший в `_pois`, sanity-чек ≤5м). Берём `poi.get_wave_schedule()`. Если пусто — POI «мирный». Иначе stage-machine: `_stage_index=0`, `_stage_elapsed`, `_wave_cd = stage.wave_interval`. Каждую `wave_interval` секунд `_spawn_poi_wave(stage.skeletons_per_wave)`. По `stage.duration` — `_stage_index += 1`, финальная залипает. На `camp_packed` — `_clear_active_poi`. Фон продолжает идти.
    - Защита: если активный лагерь разрушен в ходе осады — `_clear_active_poi`. POI без расписания — мирный, только фон.
    - `_safe_score` теперь читает per-POI `safe_radius` через duck-typing (`"safe_radius" in poi`); fallback `poi_safe_radius_fallback=32`.
    - `SpawnZone.skeletons_per_wave` deprecated — размер пачки приходит из `WaveStage`. Поле оставлено чтобы override в `main.tscn` не валился.

    **K3 (`09f9e54`) — Tower aggro в каравне:**
    - `Camp._set_tower_aggro(active)` — добавляет/убирает `_tower` в группу `skeleton_target`. Идемпотентен, null-safe, `is_inside_tree`-guard.
    - В `_ready` (если не `start_deployed`): aggro=true. На `_start_deploy`: false (осада на палатки). На `_finalize_pack`: true (караван снова цель). На `_on_tower_destroyed`: false (страховка).
    - Поведение: фоновые wander-скелеты, увидев караван глазами, идут к башне через Skeleton-vision (TARGET_GROUP `skeleton_target`) и атакуют через `Damageable.try_damage(tower)`. На POI tower вне группы — агро на палатки/гномов, башня визуально стоит в центре лагеря, но не задевается.

    **Дизайнерская петля сейчас:** между POI караван едет, фон в карте растёт. Скелеты могут увидеть караван и накинуться (агро через vision на tower). Игрок подъезжает к POI (костёр), жмёт R — лагерь разворачивается ровно по центру костра. WaveDirector видит deploy и стартует осаду по wave_schedule этого POI. Стадии нарастают по темпу. Игрок отбивается, собирает ресурсы (ResourceZone-ы около POI), потом сворачивает лагерь и едет к следующему POI — но мир уже грязнее. Все параметры (radii, schedules, фоновый рост) в инспекторе на самих нодах, никаких магических чисел в коде.

43. **POI handshake fix + полная атака каравана + perf на 2000 (4 коммита)**. После первого тестирования K1+K2+K3 всплыли два сюжетных бага и performance regression при 2000 скелетов.

    **Bug 1 (`3bff0e1`) — POI handshake.** Лагерь развёрнут на костре, но осада не запускалась (O → «нет активного POI с осадой»). WaveDirector собирал `_pois` из poi_root_path-детей напрямую, а это `Poi_*`-маркеры (poi_marker.tscn без скрипта). `wave_schedule/safe_radius/get_wave_schedule` живут на их `QuestActor`-детях. `has_method("get_wave_schedule")` возвращал false → POI «мирный». Camp-side (`_find_poi_for_deploy`) использовал группу `poi_zone` корректно — handshake рвался только на стороне WaveDirector. Fix: собираю `_pois` через `get_nodes_in_group(QuestActor.POI_GROUP)` лениво в `_collect_pois_deferred` (после `process_frame`, чтобы все QuestActor`._ready` отработали). `poi_root_path` помечен deprecated.

    **Bug 2 (`7c190ec`) — караван — целое.** Геймдизайнер: «Tower проходит сквозь скелетов; в каравне атакуется только башня, палатки нет — нужно чтобы атаковались и башня, и палатки». Два root cause:
    - **Tower.collision_mask: 15 → 31** (`scenes/tower.tscn`). Skeleton.mask=39 (включает ACTORS) уже блокировался об башню, но Tower.mask=15 без ENEMIES → башня их игнорировала и проходила сквозь. Симметризовал: толпа теперь замедляет Tower массой.
    - **CampPart уязвимы в каравне тоже**, не только в DEPLOYED. Раньше `_ready: vulnerable=false`, `_start_deploy: true`, `_start_pack: false`, `_finalize_pack` ничего не делал → в caravan-mode после первой свёртки палатки оставались бронированными. Сейчас vulnerable=true в caravan и DEPLOYED, false **только** в PACKING_RETURNING (бронь во время сбора). Хелпер `_set_parts_vulnerable(bool)` вместо четырёхкратного дубль-цикла.

    **Bug 3 (`517b882`) — vision-scan throttle.** Профайлер на 452 скелетах: `Skeleton._scan_target` = 452 calls/тик (60Гц), 2.39ms self-time. Throttle через `_vision_scan_timer` не работал. Причина: `stale := _cached_target == null or not is_instance_valid(...) or ...` — когда скелет не находил цель, `_cached_target = null` после первого скана, на следующем тике `null → stale=true → немедленный rescan`. Бесцельный FAR-скелет рескан'ил каждый кадр вместо 1 раз/0.6с. Fix: `null` НЕ stale (это легитимное «целей в зоне нет»), stale только если cached невалиден или вышел из группы. После: 452 → 27 calls/тик (×17 сокращение). Та же правка в DefenderGnome (3240 → 216 PhysicsShapeQuery/сек на 54 защитниках).

    **Perf-tuning (`c4bade0`) — на 2000 скелетов:**
    - `lod_far_tick_divisor`: 3 → 4 (FAR 60→15Гц). Slam-задержка 50→67мс.
    - `lod_mid_tick_divisor`: 3 → 4. Tunneling: `2.7×4×0.0167=0.18м/тик` при capsule_radius=0.4 — запас ×2.
    - `vision_scan_interval`: 0.3 → 0.4с (доп. 25% экономии _scan_target).
    - **Boids avoidance NEAR-only** (раньше NEAR+MID). На MID 25-50м от камеры мелкие столкновения тимы не читаются, cost ~18мкс/call → экономия ~1ms.

    **Профайлер «до → после»** на 2000 скелетов (Inclusive Frame Time):
    - Frame Time: ~17мс с пиками >25мс → ~12-13мс ровно.
    - Script Functions: 14.63 → 9.80мс (**−33%**).
    - Skeleton._physics_process: 11.59 → 7.57мс.
    - Enemy._physics_process: 5.21 → 3.34мс.
    - _far_step calls: 557 → 389.
    - _apply_neighbor_avoidance calls: 105 → 50.
    Бюджет 60Гц (16.66мс) теперь имеет 4-7мс запаса в среднем кадре на 2000 скелетов.

44. **Trial-and-error trip по визуалу: ground noise, billboard grass, 3D-mesh grass.** Геймдизайнер хотел оживить сцену травой — пройдены три варианта.

    **(а) Ground noise — fbm в `grid.gdshader`** (коммит `eabb562`). Дешёвый shader-эффект на полу: 3 octaves hash21+value_noise дают «травянистый» pattern. Зашло — пол стал природным.

    **(б) Billboard grass на POI** (коммит `e71f14b`, потом откат `94efcd4`). Кольца биллборд-quad'ов вокруг каждого костра радиусом 12м, плотность 1/м², ~450 blade per POI. **Не зашло** — кольца выглядят как искусственные «островки», не как лужайка. Удалены файлы `grass.gdshader` (билборд-версия), `grass_chunk.tscn`, `scripts/grass_chunk.gd`, `grass_material.tres`, `grass_quad_mesh.tres`. Заодно убрана grid-сетка 2×2м из ground-шейдера (по геймдизайну: «не нужна, fbm-noise сам даёт масштаб»).

    **(в) Texture-noise vs in-shader fbm** (коммит `a1df929`). Симптом: на полу видны квадраты ~50м с резкими краями. Причина: на координатах ±200 (карта 400×400) `world_pos × scale=0.5` доходило до ±100, hash21+fbm плыл из-за float32 precision. Fix: заменил in-shader fbm на `texture(noise_texture, world_pos.xz × scale).r`, где `noise_texture = ground_noise.tres` (NoiseTexture2D 512×512 FastNoiseLite Perlin, freq=0.018, octaves=4, **seamless=true**). Godot bake'ит её один раз на CPU; sampler с repeat_enable плавно тайлит без швов.

    **(г) 3D-mesh grass по всей карте** (коммиты `3b1a5fe` → `b1787d0` → `612ad05`). Подход с https://godotshaders.com/shader/grass-shader: low-poly blade (`grass_blade.obj`, 9 vertices / 7 трисов, узкая к верху) + vertex displacement по noise-texture. **Без transparency** — silhouette даёт реальная геометрия, нет fragment-overdraw'а. Critically важно при нашем 60fps впритык на 2000 скелетов.

    Архитектура — chunked MultiMesh: `GrassField` (`scripts/grass_field.gd`) на `_ready` спавнит `chunk_count_xz × chunk_count_xz` (8×8) узлов `GrassChunk` (`MultiMeshInstance3D`-обёртка). Каждый чанк имеет `visibility_range_end=60м` — дальние пропадают. Frustum-culling оставляет ~3-9 видимых чанков из 64.

    Ветер в шейдере: `bend = (sin(TIME×scale + worldPhase)×0.5 + (noise(...)−0.5)×0.6) × sway × pow(height_norm, sway_pow)`. Главная sin-волна даёт видимую бегущую волну по полю; noise-vary — травинки качаются не идентично; pow(height) — корень неподвижен, верхушка раскачивается.

    **Bug-fix в шейдере:** первая версия имела ветер `TIME × sway_time_scale × 0.05` — за секунду noise сдвигался на 0.02, период 20м → одно полное качание за ~1000 секунд. Визуально ветер не работал. Убрал `× 0.05` множитель + переписал на sin+noise, теперь видно.

    **Дальнейший дебаг (коммиты `f66b78f` → `9f03444` → `a1d6215`):**
    - `f66b78f`: visibility 60→120м (зум-out камеры видит ~150м, чанки за 60м пропадали посреди экрана), chunk_count 8→16 (мелкое culling-step, 25м чанки), density 5→4 (компенсация), blade_scale 0.12→0.15 (видимее с расстояния), GrassField y=−0.28 (корни на полу — Ground top at y=−0.28 из-за scale.y=0.439).
    - `9f03444`: **критический фикс** — `chunk.multimesh = chunk.multimesh.duplicate()` в `_spawn_one_chunk`. До этого все 256 чанков делили один MultiMesh-resource (sub_resource в .tscn копирует NodePath, не сам ресурс), `instance_count=X` и `set_instance_transform(i,t)` перезаписывали друг друга — 429 ошибок в дебаггере и виден только последний чанк.
    - `a1d6215`: усилены параметры ветра: `sway` 0.25→0.6 (амплитуда ×2.4), `sway_time_scale` 1.5→2.5 (быстрее), `sway_pow` 2→1.5 (корень тоже двигается). Геймдизайнер: «травинки почти не видно как шевелятся».

    **Финальные дефолты:** `density=4`, `visibility_distance=120м`, `blade_scale=0.15`, ~640k blade суммарно, ~30k-50k в кадре. Откат: `density=0` в инспекторе GrassField. Используется тот же `ground_noise.tres` что и для пола — один shared NoiseTexture2D на проект.

45. **Палатка как пиньята + цепочка-каравана с гномами + перепродумывание pack/deploy.** Большой архитектурный пересбор поведения палаток и гномов (2026-05-05).

    **(а) GrassField bounds через AABB (фикс).** GrassField со `world_size=400` спавнил blade'ы в квадрат 400×400, а Ground в `main.tscn` имеет `scale.z=0.439` — реальный пол только X∈±200, Z∈±88, ~360k blade висели за границей в воздухе. Добавил опциональный `coverage_target_path: NodePath` (в `main.tscn` указывает на `../Ground/GroundMesh`); GrassField берёт его world AABB через `mesh.global_transform * mesh.get_aabb()` и спавнит чанки строго внутрь. Чанки теперь могут быть не квадратными (`chunk_size_x ≠ chunk_size_z`).

    **(б) Палатка-щит для гномов IN_TENT.** Раньше Slam через `Damageable.try_damage` бил по всем зарегистрированным в радиусе — гномы внутри палатки получали damage и одним хлопком умирали все 21 (наблюдалось в логе). Фикс: `Gnome.take_damage` ранний return при `_state == State.IN_TENT`. Целая палатка теперь защищает жителей от любых damage-источников (Slam-AOE, скелеты).

    **(в) Pinata-механика tear-off.** Старая модель: `_become_torn_off` сразу выкидывал всех IN_TENT гномов с per-gnome random damage — половина умирала. Новая: tear-off гномов НЕ выкидывает; на каждом `body_entered` со speed ≥ min_speed палатка выпускает `gnomes_per_impact` (default 1) гномов с cooldown 0.15с, **без damage** — палатка защитила, при ударе вытряхивает наружу здоровыми. На `_destroy` (hp ≤ 0) выпускает оставшихся, тоже без damage. Дизайн «палатка как пиньята».

    **(г) HP палатки 250 → 120 + кубарем.** 2 хлопка Slam (60 damage каждый) убивают палатку. Параметры `torn_off_linear_damp=0.5, torn_off_angular_damp=0.3` снижаются на `_become_torn_off` (tent.tscn держит 2.0/2.5 для статики в покое) — обломок красиво летит и крутится вместо мгновенного torque-decay'а.

    **(д) Целая палатка в руке возвращается в строй.** Раньше `_torn_off` был необратим: даже если игрок подобрал летающую (но живую) палатку и тихо опустил — она оставалась обломком (`_on_hand_released` early return на `_torn_off`). Добавил сброс `_torn_off=false` на `_on_hand_grabbed` (вместе с `_outside_caravan`). Подобранная целая палатка ведёт себя как нормальная: soft-release → встаёт в строй (zone-snap или mark_outside_caravan); throw → `_become_torn_off` снова.

    **(е) Free-placement в DEPLOYED + restore на pack.** В `notify_part_settled` ветка по `Camp._state`: в DEPLOYED/PACKING_RETURNING всегда mark_outside_caravan (палатка остаётся где опустили), без zone-snap к ring-слоту. Игрок свободно перестраивает лагерь под местность. На `_finalize_pack` Camp вызывает `restore_to_caravan()` на всех CampPart (сбрасывает `_outside_caravan`, не `_torn_off`) и `_reorder_parts_by_position()` — палатки сортируются по distance до Tower и плавно вытягиваются в строй через exp_decay.

    **(ж) FOLLOWING_CARAVAN превратился в полноценную цепочку.** Раньше бездомные гномы (eject + отсутствие живых палаток) шли тупо к `_tower.global_position` и кучковались возле башни. Теперь Camp ведёт `_caravan_followers: Array[Gnome]` (порядок регистрации = слот). API `Camp.get_chain_target_for_follower(g)` возвращает chain-target по той же формуле что для палаток в `_update_caravan_follow`: `leader_pos − dir × gap + perp × side + dir × forward`. Звенья: `tower → активные палатки → followers до slot−1`.

    Per-гном `_caravan_chain_offset: Vector2` (рандомный, стабильный после `enter_following_caravan`) разворачивается через `gnome_chain_jitter (0.7м)` и `gnome_chain_gap_variance (0.35)` — гномы рассыпаются полосой шириной ~1.4м с раздёрганным gap. `gnome_chain_gap=1.2м` (плотнее tent's `part_gap=2.5`). Тоже самое для DefenderGnome: добавил `State.FOLLOWING_CARAVAN: _tick_following_caravan()` в его `_active_tick`-overrride. Бездомный лучник встаёт в общий строй наравне с собирателями.

    **(з) Sprint-скорость для догона каравана.** Tower бежит на 8 m/s, гном при `move_speed=1.6` отстать на любое расстояние означает «никогда не догнать». Решение: `_tick_following_caravan` считает скорость через `lerpf(move_speed, caravan_sprint_speed (9.0), dist / caravan_full_sprint_distance (5))`. В слоте walking, отстал — sprint. Естественное поведение «пешее сопровождение бежит когда отстало», без overall-ускоренной скорости (которая делала бы гномов дешёвыми и в спокойном состоянии).

    **(и) Vacancy claim.** В палатке `gnomes_per_tent` мест. Бездомные гномы FOLLOWING_CARAVAN раз в ~1-1.5с (random jitter) спрашивают `Camp.find_tent_with_vacancy_for(self)` — ближайшая non-torn / non-in-hand палатка с `get_tent_occupancy(tent) < tent.gnomes_per_tent`. Найдёт → `_claim_tent_as_home(tent)` ставит state RETURNING_TO_TENT, гном бежит и заселяется. Изначально палатки полны, вакансии открываются после смертей гномов внутри (или если игрок настроит `gnomes_per_tent` больше начального спавна).

    **(к) Pack завершается мгновенно через FOLLOWING_CARAVAN.** Раньше `request_return` вёл out-of-tent гномов в RETURNING_TO_TENT — те шли пешком 1.6 m/s через лагерь, pack постоянно упирался в `pack_timeout=12c`. Сейчас `request_return` для не-IN_TENT вызывает `enter_following_caravan` → они мгновенно в колонне за палатками. `_all_gnomes_home` обновлён: «settled» = `IN_TENT or FOLLOWING_CARAVAN`. Pack завершается на следующем тике после `_start_pack`. `Find_tent_with_vacancy_for` в PACKING_RETURNING возвращает `null` — иначе только-что-переведённый в FOLLOWING_CARAVAN гном тут же занял бы вакансию и pack ждал бы его прибытия.

    **(л) Sprint при возврате домой.** `_tick_returning` теперь использует `caravan_sprint_speed` вместо `move_speed`. Через лагерь 12м гном пробегает за 1.3с. Через vacancy-claim это значит: бездомный нашёл вакансию → bystrо туда → IN_TENT.

    **(м) Eject из палатки: 2с неуязвимость + scatter.** `Gnome.eject_from_tent()` (без `damage` параметра) ставит state SEARCHING → FOLLOWING_CARAVAN, добавляет в `SKELETON_TARGET_GROUP`, выставляет `_post_eject_invulnerable_until_msec = now + 2000` (take_damage гейтится), применяет random horizontal `apply_push(scatter_dir × 5, 0.5)` — гномы разлетаются в стороны по инерции, AI off на длительность knockback'а. Естественный «вылет из палатки в шоке».

    **(н) Defender-gnome FOLLOWING_CARAVAN-ветка.** Без неё лучник, выкинутый из палатки, попадал в `_defender_combat_tick` → `_patrol_tick` → патрулировал вокруг `_camp.deploy_anchor` (позиция бывшей палатки) и не уходил с караваном. Добавил явную ветку в `match _state` чтобы передать управление в `_tick_following_caravan` (наследуется от Gnome).

46. **Защитники: конус зрения + alarm-канал + escort-режим в каравне.** Перцепция защитников переписана со sphere-сканера на cone-vision + общий alarm-bus. Дизайнер: «лучник должен иметь слабое место — фланги», + хочется триггерить реакцию когда враг бьёт лагерь.

    **(а) Cone vision вместо 360° sphere.** `cone_vision_radius=35м` (видит дальше) + `vision_half_angle_deg=60°` (этап 47 → сужено до 45°). PhysicsShapeQuery со сферой как broadphase, потом per-target dot-фильтр через `_is_in_cone(pos)`. Тело физически разворачивается через `rotation.y = atan2(-_facing.x, -_facing.z)`. Visual: добавил `FacingIndicator` (тёмный нос на красной капсуле) — игроку видно куда смотрит страж.

    **(б) Зоны реакции по дистанции до защитника.** Цель в `attack_radius` → стой/стреляй; цель в конусе, но дальше → sector-патруль (точка на `patrol_radius` в направлении угрозы от лагеря). Это даёт «защитник видит далёкого — идёт на сторону», без ухода далеко от позиций.

    **(в) Alarm через EventBus.** Новый сигнал `skeleton_attacked_camp(attacker, victim, position)` — `Skeleton._perform_strike` эмитит после успешного `try_damage` по CampPart или НЕ-DefenderGnome'у. DefenderGnome подписан, фильтрует «наш ли лагерь» (CampPart-родитель == _camp, или Gnome ∈ _camp.get_gnomes()), ставит attacker как `_alarm_target` на `alarm_persist_sec=5`. В `_resolve_target` alarm priority над cone-сканом — лучник разворачивается даже на скелета за спиной. Это даёт чёткую причину играть осторожно: если скелет проскользнул мимо конусов, alarm активируется только когда он начал бить.

    **(г) Escort вместо IN_TENT.** Защитники больше не сидят в палатках. Override `_enter_in_tent` → `enter_following_caravan`. Override `_tick_following_caravan` идёт сбоку от своей палатки: target = `tent.position + perpendicular × escort_lateral_distance × ±1`. `_escort_lateral_sign` рандомизируется per-инстанс — несколько защитников распределяются по обоим бортам. В палатках теперь только мирные гномы. На спавне defender уже снаружи и работает.

    **(д) Стрельба на ходу в caravan-режиме.** Параллельно с escort-движением `_caravan_combat_tick` использует тот же `_resolve_target`, при цели в attack_radius стреляет НЕ останавливая velocity. Sector-патруль здесь не вызывается (anchor лагеря в caravan stale, колонна ведёт). Бездомный лучник (палатка убита) идёт за башней как fallback.

    **(е) Freed-safety паттерн.** Между физтиками `_cached_target` мог стать freed (скелет умер от чужой стрелы). Godot 4.6 на typed Node3D-параметре строго отвергает freed-инстанс с ошибкой «previously freed not subclass». Фикс: жёсткий `is_instance_valid` cleanup в начале `_resolve_target` — после него `_cached_target` либо null, либо живой. Также параметр-индикатор `had_prev: bool` (вместо передачи самого Node3D) в `_log_target_change` — типчек не падает.

47. **Squad XP, апгрейды отряда + сепарация и распределение огня.** Дизайнер: лучники не должны кучковаться (визуально и по огню). Плюс хочется прокачку отряда с выбором.

    **(а) Squad XP foundation.** Camp накапливает `_squad_xp` через `credit_kill(at_position)`. Кривая `squad_level_xp_curve = [50, 120, 250, 500, 1000]`. Arrow на летальном попадании (`hp_before > 0 → hp_after ≤ 0` через snapshot HP перед `try_damage`) вызывает `_shooter.on_kill_credit(victim)` — DefenderGnome форвардит в `_camp.credit_kill(victim.global_position)`. Сигналы EventBus: `squad_xp_gained_at` (popup), `squad_xp_changed` (HUD-bar), `squad_leveled_up` (модал + flash).

    **(б) Каталог апгрейдов + UpgradeModal autoload.** `Camp.UPGRADE_CATALOG: Dictionary[StringName, Dictionary]` с полями `name`/`description`. Защитники читают через `_camp.has_upgrade(id)` на каждом тике — новые после respawn'а в курсе автоматически. UpgradeModal — autoload, CanvasLayer с программно-собранным UI (overlay + центрированный panel + 2 кнопки-карточки), `process_mode=ALWAYS` для работы при `paused=true`. На `squad_leveled_up` берёт 2 случайных из `available_upgrades`, открывается, на клике вызывает `grant_upgrade` + закрывается. Если `_pending_upgrade_choices > 0` (несколько уровней быстро) — открывается заново.

    **(в) Два первых апгрейда:**
    - **`UPGRADE_KITING`** ("Манёвр уклонения"): в DEPLOYED при цели в `attack_radius` И ближе `kite_threshold_distance=6м` — лучник пятится `-_facing × patrol_speed`, продолжая стрелять. Дальше 6м — обычный stand-and-shoot.
    - **`UPGRADE_LONG_DRAW`** ("Усиленное натяжение"): `effective_attack_radius() = attack_radius + upgrade_long_draw_bonus(=5м)`. Используется и в DEPLOYED, и в caravan.

    **(г) HUD squad row.** В `gameplay_hud.gd` программно собирается ряд: золотая иконка + Label «ур. N» + ProgressBar с overlay-Label «X/Y». Реактивно обновляется на `squad_xp_changed` (без таймера). На `squad_leveled_up` — `tween` modulate flash белым на 200мс. На максимальном уровне (curve исчерпана) — бар 100% + текст «MAX».

    **(д) XP-popup `+10`.** `SquadXpPopup` (extends Label3D, билборд, fixed_size=false с `pixel_size=0.005, font_size=48` — текст ~0.24м высоты в мире, читается без перекрытия экрана). Поднимается на 0.8м/с, фадится последние 40% жизни (1с total). `SquadXpFx` autoload подписан на `squad_xp_gained_at`, спавнит popup в `current_scene` на переданной позиции.

    **(е) Сепарация защитников.** В attack-ветке `_compute_separation_force()` суммирует векторы отталкивания от других DefenderGnome в `separation_radius=1.5м` с linear falloff. Прибавляется к velocity (стой/пятиться) — лучник дрейфует вбок если сосед прижался, не ломая `_facing`. Сила `separation_strength=0.5 × patrol_speed` — ~0.5 м/с при касании. Группа `defender` для итерации.

    **(ж) Распределение огня.** В `_scan_cone` каждая цель получает `score = dist × (1 + aimers × target_share_penalty)`. `_count_aimers_on(target)` итерирует группу `defender`, считает у скольки `_cached_target == target`. С `target_share_penalty=0.5` близкая цель с 1 стрелком сравняется с целью на 50% дальше без стрелков. Лучники предпочитают распределяться, но не ломятся к далёкому.

    **(з) Konсу сужено 60° → 45°.** В конце сессии чтобы оставить место апгрейду «сторожевая вышка» (план на завтра — пассивный +15° к конусу + +5м радиуса, 1 gatherer становится spotter'ом).

    **(и) Меньше защитников.** `defenders_per_tent` 3 → 2 → 1 за две правки. На 4 палатки = 4 защитника + 24 собирателя.

48. **Большой код-ревью: WINDUP target lock + поведение свёртки + уборка drift'а** (2026-05-06).

    **(а) Skeleton WINDUP target lock — bug fix.** `Skeleton._physics_process` тикает `_vision_scan_timer` независимо от FSM-состояния, поэтому за `attack_windup=0.4с` `_cached_target` мог быть подменён ближайшим гномом из vision_radius=12. До фикса `_perform_strike` через `get_active_target()` бил по новой цели на любой дистанции (Damageable.try_damage без contact-чека). После фикса: `_on_state_enter(WINDUP)` защёлкивает `_windup_target = get_active_target()`, `_perform_strike` использует именно его + валидирует жив/в группе/`dist² ≤ (attack_range × 1.5)²`. Если цель ушла или сдохла — strike отменяется, COOLDOWN тикает обычно. Константа `WINDUP_TARGET_RANGE_SLACK=1.5` — запас на движение цели за время замаха (move_speed × attack_windup ≈ 0.6м + capsule).

    **(б) Поведение свёртки: gatherer домой, defender в строй.** До этапа 48 `Gnome.request_return` редиректил ВСЕХ гномов в `enter_following_caravan` ради мгновенного завершения pack. Геймдизайнерское решение: палатка = безопасное место для собирателей, поэтому при свёртке gatherer'ы должны прятаться внутрь. Теперь `Gnome.request_return` для gatherer'а с живой `_home_tent` ставит `_state = RETURNING_TO_TENT` (sprint к палатке через `caravan_sprint_speed=9 м/с`, на arrival → IN_TENT). Бездомные gatherer'ы → в колонну (некуда возвращаться). `DefenderGnome.request_return` — override, всегда `enter_following_caravan` (защитник не сидит в палатке принципиально, не делает крюк к ней). Pack timeout (12с) защищает от gatherer'а, застрявшего sprint'ом — sprint=9м/с покрывает диаметр лагеря (16м) за 1.8с, таймаут срабатывает только при патологии.

    **(в) Уборка docs/drift.** Несколько комментариев устарели после рефакторов слоёв и контрактов:
    - `hand_physical_slam.gd:slam_mask` docstring говорил «MASK_HAND_SLAM = 18» (реально 438 после добавления FRIENDLY_UNIT, COLD_ENEMY и пр.).
    - `octagon_turret.gd` shebang говорил «Гномы (layer=0)» (реально FRIENDLY_UNIT, бит 8).
    - `camp.gd` shebang говорил «Skeleton.mask=55, Tower.mask=31» (реально 39 / 15 после удаления skel-skel пар и ENEMIES из tower-mask).
    Все три обновлены до текущих значений. Также `arrow.gd` имел `@export var debug_log: bool = false`, который нигде не читался — экспорт удалён.

    **(г) Slam: explicit radius-check для консистентности.** OctagonTurret и DefenderGnome уже делали `if d > radius: continue` после `intersect_shape` (Godot 4.6 PhysicsShapeQuery подмешивает AABB-broadphase результаты вне сферы). Slam защищался через `falloff <= 0.0` — математически эквивалентно, но непоследовательно. Добавил явный distance²-чек в `_perform_slam` для единого паттерна по всем sphere-query в проекте.

    **(д) POI cache в Camp.** `_find_poi_for_deploy` дёргался каждый кадр на зажатой R (60 Гц) через `get_tree().get_nodes_in_group(POI_GROUP)` — лишние Array-аллокации. Добавлен кеш с TTL `POI_CACHE_TTL_SEC=0.1` — 6× срез нагрузки, граница «вошёл/вышел из safe_radius» задерживается на ≤100мс (игроком не читается; башня за это время проходит ≤0.8м).

49. **Squad XP — orb-drops + visual flair** (2026-05-06). Перевод XP с instant-credit'а на осязаемые орбы, которые надо собрать. Базовая модель: «гоняй караван в зону боя», апгрейд автомагнита оставлен на потом.

    **(а) `XpOrb` (`scripts/xp_orb.gd` + `scenes/xp_orb.tscn`).** Node3D с MeshInstance3D (золотой emissive sphere radius=0.2) и Area3D (radius=0.6, mask=ACTORS|CAMP_OBSTACLE|FRIENDLY_UNIT=292). Two states: IDLE (лежит, bobbing вокруг `_base_y`) → MAGNETIZED (лерпит к `_camp_target.deploy_anchor` со speed=12м/с, на arrival вызывает `add_squad_xp(amount, position)` + queue_free). Lifetime=60с — fallback против накопления неподобранных орбов после стресс-волн.

    **(б) `XpOrbSpawner` autoload.** Подписан на `EventBus.enemy_destroyed`, спавнит `XpOrb` в позиции трупа (+0.3 по Y). Сцена орба и `XP_PER_KILL=10` — `preload`/`const` (autoload без .tscn-инстанса, @export не настраиваются из инспектора). Skeleton ничего не знает про XP, EnemySpawner — про орбы.

    **(в) Снят kill-credit chain.** Удалены `Arrow._shooter / set_shooter / on_kill_credit`-цепочка и `DefenderGnome.on_kill_credit`. Стрелок не передаётся в стрелу. `Camp.credit_kill` переименован в `add_squad_xp(amount, position)` — параметризован суммой, не привязан к фиксированному `squad_xp_per_kill` (поле удалено).

    **(г) Resolve Camp на касании орба.** `XpOrb._on_body_entered` определяет владельца касания: `Gnome.get_camp()` (новый публичный геттер), `CampPart.get_parent() as Camp`, либо для Tower — итерация группы `camp` с проверкой `c.get_tower() == body` (Tower не хранит ссылку на Camp; группа маленькая — 1-2 Camp на карте). После активации магнита `Area3D.monitoring=false` чтобы лишние касания на полёте не обрабатывались.

    **(д) Гном-собиратель видит орбы.** Новый state `Gnome.State.COMMUTING_TO_ORB`. В `_tick_searching` и `_tick_idle_near_base` приоритет: орб > pile (орб исчезает за 60с, pile стационарен). `_scan_orb()` итерирует `XpOrb.GROUP` без spatial grid (на текущих масштабах достаточно; добавить grid если волны генерируют 500+ орбов одновременно). На касании Area3D орб магнитится к Camp'у, гном теряет цель → возврат в SEARCHING. arrival-чека через `pickup_distance` нет: Area3D radius=0.6 ловит контакт раньше.

    **(е) Level-up flash на защитниках.** `DefenderGnome._on_squad_leveled_up` — подписка на `EventBus.squad_leveled_up`. Tween scale меша 1.0 → 1.3 → 1.0 за 300мс (TRANS_QUAD). Каждый живой защитник «вспыхивает» на левел-апе. Tween создаётся на меше — корректно отвалится если защитник умрёт mid-flight.

    **(ж) Один путь, не много.** Архитектурно соблюдается правило `feedback_one_path_not_many`: единственный канал XP — orbs. Promежуточная попытка добавить per-kill flavor-trail (золотая искорка от трупа к ближайшему защитнику) была снята как мешающая: визуально trail неотличим от XpOrb (тот же золотой emissive шарик), игрок считывает частицу как «вот мой XP полетел в стрелка», а орб на земле — как что-то отдельное. Когнитивный диссонанс с реальной механикой. Один визуальный язык — один смысл: **золотой шар = XP, и это орб на земле, который надо собрать**.

    **(з) Будущее: апгрейд автомагнита.** Сохранён в памяти как `UPGRADE_ORB_MAGNET` для следующих этапов. После прокачки лагерь в радиусе R сам тянет орбы к anchor'у, без необходимости посылать гномов или провозить караван. Сейчас этого НЕТ — текущая модель «гномы/караван собирают» — это feature.

    **(и) Серия фиксов высоты орба** (in-session отладка по логам):
    - Spawn ставился ПОСЛЕ `add_child`, а `_ready` орба зовётся синхронно из `add_child` — поэтому `_base_y` захватывал дефолтную (0,0,0). Bobbing качал орб вокруг y=0, низ sphere уходил под пол. Фикс: `orb.position = ...` ДО `add_child` (root `Main` — Node3D с identity transform, `.position == .global_position` после добавления).
    - Магнит целился в `deploy_anchor`, который равен `Vector3.ZERO` пока лагерь не развёрнут — орб улетал в мировой ноль. Заменено на `current_center()` (среднее живых палаток с fallback на Tower).
    - Магнит держит y = `_base_y` (точку рождения орба), не центр палатки — орб летит строго горизонтально, без ныряний.
    - `_activate_magnet` правит `monitoring` через `set_deferred` (нельзя менять во время in/out signal-фазы Godot, иначе ошибка-спам).

45. **Магия: фаербол + огненный шквал, прокачка через страницы (2026-05-09…05-10)**.
    Полностью построил магический слой как параллельный физическому Slam/Flick: новая категория `Hand.Category.MAGIC`, своя экономика (мана у Tower'а), свои подмодули (`HandSpellFireball`, `HandSpellFirestorm`), отдельный ресурс прокачки (`PAGE`), runtime-снаряд `Fireball` с двухфазной траекторией «ракета», статичная зона горения `BurnPatch` после взрыва, и общий VFX-helper `AoeVisual.spawn_explosion`. Все balance-параметры заклинаний централизованы в `SpellSystem.SPELL_CATALOG` (autoload), runtime-подмодули читают через `get_current_level_data(id)` — single source of truth.

    **Sub-задачи / итерации в течение сессии:**
    - **Унификация take_damage** (start of session): Item остался на `is_queued_for_deletion()` страже от двойного `destroyed.emit()` — было микрооконце между emit и реальным free. Перевёл на `_dying`-флаг как у остальных. ResourcePile упрощён (убрал дублирующий `is_queued_for_deletion` из условий, `_dying` единственный страж).
    - **Q освобождён** (был на `complete_quest`/QuestProgress.advance debug-вход) — биндинг убран, продвижение квестов теперь через Журнал → Читы → «Продвинуть квест». Заодно добавил вкладку «Задания» в журнал, где `QuestActor` сам декларирует `quest_title` / `quest_description` экспортами; вкладка собирает их через `POI_GROUP`. На освободившийся Q повесил `caravan_halt_toggle`.
    - **Halt-режим каравана** (Q): `Camp._caravan_halted` флаг, `_update_caravan_follow` ранний return при halted, R-deploy блокируется в halted. Гномов/defender'ов трогать не пришлось — IN_TENT копирует palatka.global_position (стоят), FOLLOWING_CARAVAN ловит slot за стоящими палатками. Дополнительно: `caravan_max_speed = 10` cap для caravan-follow — после halt-resume Tower уехал далеко, exp_decay давал «рывок» пропорционально дистанции. Capped exp_decay (`_exp_decay_capped`) клампит шаг на `max_speed × delta`. В обычной езде cap не активен.
    - **Hand-категория** (`PHYSICAL` / `MAGIC`): equip 1/2 → PHYSICAL, equip 3/4 → MAGIC. ЛКМ-граб работает в любой категории; ПКМ — только в активной. `is_holding()` блокирует ПКМ-действия (рука занята). При смене категории на MAGIC удерживаемый предмет НЕ дропается (можно тащить ящик и кастовать), но активный Flick принудительно отпускается.
    - **Tower mana / health сигналы**: `max_mana=100`, `mana_regen_rate=10/сек`, `try_consume_mana(amount)` атомарно. Сигналы `health_changed` / `mana_changed` + re-emit на EventBus. HUD добавил сверху по центру две полоски HP (red) / MP (blue) через `_build_tower_stats` программно (без правок .tscn).
    - **ResourcePile.ResourceType.PAGE** (5-й тип): фиолетовый. Хранится в `Camp._resources` через общий `add_resource`. Чит «+100 каждого ресурса» расширен до 5 типов.
    - **SpellSystem autoload** + каталог + API (`is_unlocked / get_level / get_current_level_data / can_upgrade_further / try_unlock / try_upgrade`). Списание ресурсов через `Camp.try_spend()`. Сигналы `spell_unlocked` / `spell_upgraded`. Сейчас в каталоге `&"fireball"` (4 уровня), `&"firestorm"` (3 уровня), `&"meteor"` (заглушка locked, 15 страниц).
    - **Fireball — снаряд с двухфазной траекторией.** Phase.BOOST (~0.18с): vy=7, gravity=14, slight forward + random sway. Phase.HOMING: каждый кадр slerp velocity к target с `homing_turn_rate`, speed растёт линейно `homing_acceleration` до `homing_max_speed`. На переходе boost→homing — random initial drift-angle (±45°) от target — фаербол стартует «мимо», slerp плавно докручивает обратно. Характерный «крюк» в полёте, очень импактно. Sphere-капля (scale 1.19/0.595/0.595) ориентируется по horizontal velocity. GPUParticles3D-хвост (`local_coords=false`) автоматически отстаёт.
    - **AoeVisual helper** (`scripts/aoe_visual.gd`, RefCounted): `spawn_explosion(root, pos, radius)` — комбо ядро-вспышка (sphere unshaded scale 0→radius×0.7→0 за 0.3с) + огненные partикли (60 шт, lifetime 0.5с, jet→orange→red→прозрачный) + дымные (40 шт, lifetime 1.2с, up bias, серый→прозрачный). Также есть `spawn_wave / spawn_dust / spawn_radius_indicator` (последний — solid translucent sphere = radius для дизайнерского feedback'а).
    - **BurnPatch** — статичная зона горения после взрыва. Тикает damage каждые `tick_interval` сек по всем damageable в радиусе через `duration` секунд, потом `queue_free`. **Horizontal-only distance check** (`_xz_distance_sq` вместо 3D) — взрыв на ground, центр капсулы скелета на y≈0.9, 3D-distance отъедал ~0.9м эффективного radius'а. Та же правка применена в `Fireball._explode`.
    - **Firestorm — шквал**: state-machine с `_shots_remaining` + `_next_shot_in` в `tick(delta)`. На press фиксирует target+параметры серии (избегаем mid-series-смены-балансов), списывает mana один раз, спавнит N фаерболов с задержкой `shot_interval`. Каждый шот — `_volley_target + jitter` в круге `scatter_radius` через `(angle, sqrt(randf()) × scatter_radius)` — uniform по площади. Реюзает `fireball.tscn` как снаряд.
    - **Журнал → вкладка «Заклинания»**: рендерит карточки SpellSystem.SPELL_CATALOG. Locked → «открыть» с unlock_cost; Unlocked + есть апгрейды → «улучшить → ур. N+1»; Max → disabled. Stats текущего уровня показываются generic key:value (через `_format_stat`) — каталог расширяется без правок UI.
    - **Балансовый принцип Fireball ≡ один шот Firestorm.** Дизайнер: «фаербол — это одиночный шквал». Параметры выровнены: damage=15, radius=2.5, mana_cost=12 (≈ Firestorm 50/4=12.5). Прокачка фаербола — равномерный конвейер DPS≈37; шквал — бёрст 4 шота за 0.45с с большим cooldown, DPS≈30 но пик выше.
    - **Визуал**: пробовали два внешних шейдера с godotshaders.com (canvas-fireball, BOTW spatial-fireball). Canvas — спрайтовый, BOTW — требовал 8 текстур (sprite sheet анимации). Финальное решение — простой sphere-капля + GPUParticles3D-хвост без шейдеров: меньшее ядро (~0.5×0.26×0.26м), хвост из 40 partикл lifetime 0.3с, gravity (0,1.5,0) up — пламя восходит. Ориентация по horizontal velocity → хвост уходит точно за траекторией.

    **Архитектурный итог:** магия теперь self-contained подсистема. Добавление нового заклинания = (1) запись в `SPELL_CATALOG`, (2) подмодуль `HandSpellXxx` (или реюз снаряда `Fireball`), (3) узел в `hand.tscn` под `SpellActions`, (4) action `equip_xxx` в project.godot, (5) enum значение в `HandSpell.SpellType` + диспатч в `_dispatch_cast`. Прокачка/мана/UI работают автоматически через SpellSystem-каталог.

19. **Супер-удар + balance-проходы (2026-05-10).** Двухступенчатый каст: накопил → QTE → carrier → разделение → ковёр.

    - **Шкала «великой силы»** в `Camp` (`super_charge_max=100`). Накопление 1:1 от damage'у врагам через подписку на `EventBus.enemy_damaged`. HUD-бар третьим под HP/MP башни. Провал QTE списывает 50% (`super_charge_fail_penalty`), успешный каст — 100%.
    - **Hand.Category +SUPER** (третья ось ввода). HandPhysical и HandSpell `_handle_input` гасятся ранним return на `active_category == SUPER`. `HandSuper` подмодуль с state machine `READY → AIMING_PATTERN → AIMING_TARGET → CASTING → READY`. Action `cast_super` (Space, keycode 32).
    - **SuperPatternOverlay** — QTE UI. CanvasLayer + Control с custom `_draw()`. 3×3 grid, `pattern_length=4` случайных индексов помечены. ПКМ-зажат → drag через ожидаемую sequence в порядке. Snap_radius=35px, тайм-аут 8с real time. На время QTE `Engine.time_scale = 0.15`. Все таймеры через `Time.get_ticks_msec()` — независимы от time_scale (CanvasLayer `process_mode=PROCESS_MODE_ALWAYS`). Polish'ed: 3-слойный halo glow, pulse-scale текущей точки, hit-flash зелёным ring'ом, cursor-trail последних 0.4с, нить с тёмным shadow.
    - **SuperCarrier** — носитель из tower'а. Двухфазная траектория «как ракета» (boost+homing, копия Fireball-схемы). На burst эмитит сигнал, не делает AOE. Arrival двумя путями — proximity (`HIT_PROXIMITY_SQ=4.0`) + overshoot detection через `_min_distance_to_target` (на homing_max_speed=48 шаг 0.8м/тик пропускал burst'-точку, carrier зацикливался). Visual: `visual_scale=1.2` → ≈1.85× от обычного fireball'а (геймдизайнер: «не больше 2×»). `AoeVisual.spawn_explosion` в момент разделения.
    - **Payload spawn** в `_on_carrier_burst`: random delay в `[0; payload_max_delay=0.4]`с через `get_tree().create_timer().timeout.connect(_spawn_one_payload.bind(...))` — импакты «очередью», не один-в-один. Per-payload random factor `[0.75; 1.25]` на homing_acceleration / max_speed + случайные drift / turn_rate. `payload_count=12`, `payload_radius=7` (разлёт), `payload_radius_aoe=4` (взрыв одного).
    - **Ground-warning кольца — единый паттерн на все заклинания.** `AoeVisual.spawn_ground_ring(root, pos, radius, duration, color)` — TorusMesh кольцо, чуть выше пола (Y+0.05 без z-fight'а), pulse-открытие 0.08с + linear альфа-fade, auto queue_free. Используется: Fireball (radius=AOE, duration=1.0с), Firestorm per-shot (radius=shot_radius, duration=0.9с), Super aim_indicator (золотой, payload_radius, persistent), Super per-payload (красный, payload_radius_aoe, lead_time=0.3с).
    - **Balance-проходы v1..v5** (2026-05-10): магия суммарно ×1.82 от исходного damage'а. Финальные цифры в `SpellSystem.SPELL_CATALOG`. Лучник симметрично нерфнут на −20% (25..40 → 20..32). Slam ослаблен до utility (60→25 dmg, 5→3.5м radius, 0.5→0.7с cooldown) — magic должна оставаться основным DPS-инструментом.
    - **AOE falloff**: linear → sqrt-curve в `Fireball._apply_aoe` и `HandPhysicalSlam._slam_direction_and_falloff`. На 50% радиуса 71% damage'а (vs 50%), на 75% — 50% (vs 25%). Внешний пояс AOE перестал быть «бесполезным chip damage».
    - **Все balance-параметры в SpellSystem**. Раньше часть жила хардкодом @export'а в подмодулях (Firestorm burn, Super payload). Унифицировано: каждый подмодуль читает через `lvl = SpellSystem.get_current_level_data(id); lvl.get(key, fallback_export)`. @export'ы остались только для motion/feel (boost/homing/turn_rate) и visual'а — это не balance, это feel. Серии (Firestorm) и многоэтапные касты (Super carrier→burst→payloads) фиксируют значения в `_series_*` / `_resolved_*`: прокачка mid-cast не меняет числа активной серии.

### 7.3 Решённые ошибки

| # | Ошибка | Причина | Исправление |
|---|---|---|---|
| 1 | Камера смотрит вверх и в сторону, башню не видно | В `Transform3D(...)` я записал базисные векторы по столбцам, а Godot хранит матрицу базиса по строкам. Получилось другое вращение. | Перепаковал значения: `Transform3D(X.x, Y.x, Z.x, X.y, Y.y, Z.y, X.z, Y.z, Z.z, ox, oy, oz)`. |
| 2 | Лог башни показывает один input, а позиция уползла в неожиданную сторону | Логирование триггерилось только на смену «движется ↔ стоит», смены направления (например, S → A+S → A) проходили молча. | Стал логировать **любое изменение `input_dir`**, а не только on/off-переходы. |
| 3 | Чтобы схватить предмет, курсор приходится точно поставить «над» ним; малейший отступ — и захват не работает | `GrabArea` располагался **на самой руке** (y=2.5), сфера r=2 «касалась» предмета на полу (y=0.5) только в нижней точке. При сдвиге курсора на 0.5 м дистанция уже превышала радиус. | (а) Опустил `GrabArea` на y=−1.5 относительно руки (центр сферы у пола). (б) Добавил отдельный `MagnetArea` r=4 + притягивающую силу — предмет «доползает» к руке, если игрок чуть-чуть не дотянулся. |
| 4 | `SCRIPT ERROR: Trying to assign an array of type "Array" to a variable of type "Array[Node3D]"` в `Skeleton.set_target → Enemy.set_target`, спавн волны падал каждый раз. | В `Enemy.set_target` стояло `_targets = [target] if target else []` — ветви тернарника возвращают **нетипизированный** `Array`, который GDScript отказывается присвоить типизированному `Array[Node3D]`. Тип теряется на уровне выражения, а не присваивания. | Заменил на типизированную локальную: `var new_targets: Array[Node3D] = []; if target: new_targets.append(target); _targets = new_targets`. Локальное объявление с типом — единственный способ построить типизированный литерал в условии. |

### 7.4 Решения, которые мы ОТВЕРГЛИ (и почему)

- **Hand как ребёнок Tower.** Было в исходном проекте. Нарушает декомпозицию: рука «знает», что есть башня. Делает камеру через башню за рукой неудобной. Заменено на параллельный узел.
- **Tower как RigidBody3D вместо CharacterBody3D.** Дало бы push «бесплатно», но потеряли бы стабильное WASD-управление: пришлось бы возиться с трением, угловой инерцией, коэффициентами восстановления. Оставили кинематику и реализовали push вручную через `apply_central_impulse` по слайд-коллизиям.
- **Камера, следящая за рукой.** Рассматривалась вместо tower-следования. Отвергнуто на этом этапе: при больших отъездах курсора башня уезжает за край экрана. Если понадобится, в `main.tscn` меняется одно поле `target_path`.
- **Raycast вместо Area3D для захвата.** Пользователь предложил рейкаст. Я выбрал `Area3D + class_name`-фильтр: тот же результат (без стен оба варианта эквивалентны), но настраивается в редакторе видимыми сферами.
- **`@tool` на Item для предпросмотра цвета в редакторе.** Дало бы цвет в тулбаре, но добавило бы рантайм-исполнение скрипта в редакторе. Отложено как полировка; сейчас цвет виден только в Play.
- **Item как глобальная конфигурация (Resource-конфиги типов).** Преждевременно: пока разнообразие в один `@export var item_color`. Вернёмся, когда появятся свойства типа «горючесть», «дроп-тип», «вес-категория».
- **Сохранение старого кода в git перед удалением.** Пользователь явно отказался; чистый старт без истории.

---

## 8. Внешние интерфейсы (контракты)

| Модуль | Что экспортирует наружу | Что слушает |
|---|---|---|
| Tower | сигналы `damaged/destroyed`, метод `take_damage(float)` (через `Damageable.register`) | Input actions WASD; `Pushable.try_push` для kinematic-целей; `_push_item` ветка для Item (mass-mediation) |
| Enemy (база) | сигналы `damaged/destroyed`, методы `take_damage(float)`/`apply_push(Vector3, float)` (Pushable)/`apply_knockback(Vector3, float)`/`set_target(Node3D)`/`set_targets(Array[Node3D])`; виртуальные `_perform_strike(target)`, `_on_state_enter/_on_state_exit`, `_on_knockback`, `_on_destroyed`. Регистрируется в `Damageable` и `Pushable` группах в `_ready` | физика, наследники |
| Skeleton | (наследует Enemy) | `_target.take_damage(...)` через `Damageable.try_damage`; `ShatterEffect.spawn` на смерть |
| EnemySpawner | публичные `spawn_at/spawn_group/spawn_uniform/kill_all_skeletons/get_zones`, поле `spawn_y` | вызывается из `WaveDirector` (включая cheat-методы из вкладки «Читы»); `Array[PackedScene]` + `target_path` + `spawn_root_path` из `main.tscn` |
| Hand | сигналы `grabbed(item: Node3D)/released(item: Node3D, velocity)` (re-emit из PhysicalActions); публичный API: `lock_position(bool)`, `set_locked_position(pos)`, `cursor_world_position()`, `smoothed_velocity()`, `get_grabbable_bodies()/get_magnet_bodies()`, `register_raycast_excluder(Callable)` | активная камера; никаких конкретных game-классов |
| Hand:PhysicalActions | сигналы `grabbed/released/slammed/flicked(target: Node3D, velocity)`, методы `get_held_item()/is_holding()/find_grab_candidate()/find_flick_target()`, `@export equipped: AbilityType` | Input `hand_grab/hand_action/equip_slam/equip_flick`; Hand через `setup` цепочку. Цели — через `Damageable.is_damageable / Grabbable.is_grabbable / Pushable.try_push`, а не через `is Item / is Enemy` |
| Hand:SpellActions | сигнал `spell_cast(name, position)` (черновик) | родитель Hand через `setup(hand)` |
| Camp | сигналы `deployed(anchor: Vector3)/packed`, экспорт `target_path/tent_scene/tent_count/gnome_scene`, публичные `deploy_anchor: Vector3` (свойство) и `is_pile_claimed(pile, exclude_gnome)`. Палатки спавнит динамически в `_spawn_tents`; вместимость каждой читает из её `CampPart.gnomes_per_tent`. | Input `camp_toggle`, читает `Tower.global_position` (delta-position для stationary-чека); зовёт `Gnome.enter_deployed/request_return/is_home/get_assigned_pile`; слушает `EventBus.tower_destroyed` для остановки follow'а |
| Gnome | методы `setup(camp, home_tent)/enter_deployed()/request_return()/is_home()/get_assigned_pile()` | Camp через ссылку из `setup`; мир — через `get_tree().get_nodes_in_group(ResourcePile.GROUP)`; `ResourcePile.take_one()` |
| ResourcePile | сигналы `damaged/destroyed`, методы `take_damage(float)/apply_push(Vector3, float)/set_highlighted(bool)/take_one() -> bool`. Регистрируется в `Damageable` + `Pushable` + `Grabbable` группах + собственная `ResourcePile.GROUP = "resource_pile"` | физика, рука (через Grabbable/Damageable/Pushable), гномы (через `take_one`) |
| CameraRig | — | `@export target_path` |
| Item | `@export item_color/item_size/highlight_*/hp`, наследует `mass`, методы `set_highlighted(bool)/take_damage(float)/apply_push(Vector3, float)`, сигналы `damaged/destroyed`. Регистрируется в `Damageable` + `Pushable` + `Grabbable` | физика; рука держит через `freeze` |
| Ground | — | — |
| `Layers` (RefCounted) | `TERRAIN/ITEMS/ACTORS/PROJECTILES/ENEMIES/CAMP_OBSTACLE` + `MASK_*` константы; static `has_layer/compose/layer_name_for_bits` | — |
| `Damageable/Pushable/Grabbable` (RefCounted) | static `register(node)`, `is_*(target)`, `try_*(target, ...)`. Контракты, через которые модули знакомятся не зная типов друг друга | — |
| `ShatterEffect` (RefCounted) | static `spawn(parent, position, color, count, lifetime)` | — |

Каждая стрелка сверху проходит **только через имя класса, сигнал, `@export` или group-контракт**. Никаких `get_node("../Tower")` внутри скриптов; никаких `body is Item` для cross-cutting проверок (только там, где Item-специфика реально нужна, например push с mass-ratio в Tower).

---

## 9. EventBus (autoload)

**Файл:** `scripts/event_bus.gd`. **Регистрация:** `project.godot → [autoload] → EventBus="*res://scripts/event_bus.gd"`. Глобально доступен как `EventBus` в любом скрипте.

**Назначение.** Глобальный канал событий. Каждая damageable / interactive сущность по-прежнему держит **локальные** сигналы (`damaged`, `destroyed`, `grabbed`, …) — это контракт для тесно-связанных слушателей. Параллельно она перенаправляет их на bus, чтобы UI / счёт / звук подписывались **один раз** на нужный глобальный сигнал, не зная про конкретные инстансы и не переподключаясь при каждом spawn'е.

**Конвенция именования:** `<entity>_<event>(args)`. Первый аргумент — сама сущность (для тех типов, где нужно отличить инстанс; Tower одна на сцене, поэтому без `self`).

Аргументы типизированы как `Node3D` / `Node` (а не как `Item/Enemy/...`) — autoload не должен зависеть от конкретных геймплейных классов. Слушатели сами кастуют по необходимости (или работают на уровне Node3D). После рефакторинга `c33a9d3` это стало правилом: добавление новых типов целей (например, `ResourcePile`) не требует расширения сигнатур шины.

**Список сигналов:**

| Сигнал | Аргументы | Источник |
|---|---|---|
| `item_damaged` | `(item: Node3D, amount: float)` | `Item._ready` re-emit, **`ResourcePile._ready` re-emit** (куча неотличима от Item для cross-cutting слушателей) |
| `item_destroyed` | `(item: Node3D)` | `Item._ready` re-emit, `ResourcePile._ready` re-emit |
| `enemy_damaged` | `(enemy: Node3D, amount: float)` | `Enemy._ready` re-emit (Skeleton наследует через `super._ready()`) |
| `enemy_destroyed` | `(enemy: Node3D)` | `Enemy._ready` re-emit |
| `tower_damaged` | `(amount: float)` | `Tower._ready` re-emit |
| `tower_destroyed` | — | `Tower._ready` re-emit |
| `tower_health_changed` | `(current: float, maximum: float)` | `Tower._ready` re-emit. HUD рисует HP-bar |
| `tower_mana_changed` | `(current: float, maximum: float)` | `Tower._ready` re-emit. HUD рисует MP-bar |
| `spell_unlocked` | `(id: StringName)` | `SpellSystem.try_unlock`. Журнал-вкладка «Заклинания» перерисовывает |
| `spell_upgraded` | `(id: StringName, level: int)` | `SpellSystem.try_upgrade` |
| `super_charge_changed` | `(value: float, max_value: float)` | `Camp.add_super_charge` / `consume_super_charge`. HUD рисует «великую силу»-bar |
| `super_cast_started` | — | `HandSuper._try_start_cast` — игрок запустил QTE |
| `super_cast_finished` | `(success: bool)` | `HandSuper._finish_super` — каст завершён (success после `_commit_rain`, fail после QTE-провала или `_cancel_aim`) |
| `hand_grabbed` | `(item: Node3D)` | `Hand._ready` re-emit |
| `hand_released` | `(item: Node3D, velocity: Vector3)` | `Hand._ready` re-emit |
| `hand_slammed` | `(position: Vector3, radius: float)` | `HandPhysicalActions._ready` re-emit |
| `hand_flicked` | `(target: Node3D, velocity: Vector3)` | `HandPhysicalActions._ready` re-emit |
| `camp_deployed` | `(anchor: Vector3)` | `Camp._ready` re-emit |
| `camp_packed` | — | `Camp._ready` re-emit |
| `camp_part_damaged` | `(part: Node3D, amount: float)` | `CampPart._ready` re-emit |
| `camp_part_destroyed` | `(part: Node3D)` | `CampPart._ready` re-emit (Camp же подписывается через локальный `destroyed.bind(p)` для синхронизации `_parts`/`_deployed_targets`) |
| `gnome_damaged` | `(gnome: Node3D, amount: float)` | `Gnome._ready` re-emit |
| `gnome_destroyed` | `(gnome: Node3D)` | `Gnome._ready` re-emit |
| `module_mounted` | `(module: Node, slot: Node)` | `MountSlot._mount` |
| `module_unmounted` | `(module: Node, slot: Node)` | `MountSlot._release_to_hand` / `_drop_mounted` |
| `quest_advanced` | `(new_index: int)` | `QuestProgress.advance` (autoload) — эмит на каждое продвижение прогресса. Слушают QuestActor (перекрас) и потенциально HUD. |
| `skeleton_attacked_camp` | `(attacker: Node3D, victim: Node3D, position: Vector3)` | `Skeleton._perform_strike` после успешного `try_damage` по CampPart или НЕ-DefenderGnome'у. Defender'ы своего лагеря используют как alarm-цель (override конуса). |
| `squad_xp_changed` | `(xp: int, level: int)` | `Camp.add_squad_xp` (этап 49) после инкремента XP. HUD-бар (GameplayHud) слушает для обновления. |
| `squad_leveled_up` | `(level: int)` | `Camp.add_squad_xp` при пересечении threshold'а. JournalPanel инкрементит банк выборов (через pending_upgrade_choices_changed); GameplayHud делает flash-tween бара; DefenderGnome — scale-pulse «вспышка» на живых защитниках. |
| `squad_upgrade_granted` | `(upgrade_id: StringName)` | `Camp.grant_upgrade` после клика игрока в Journal. Сейчас только для логирования / будущего HUD активных апгрейдов. |
| `squad_xp_gained_at` | `(amount: int, world_position: Vector3)` | `Camp.add_squad_xp` (этап 49) ПЕРЕД `squad_xp_changed`. SquadXpFx autoload спавнит Label3D-popup «+10» в этой точке мира. |
| `pending_upgrade_choices_changed` | `(count: int)` | `Camp.add_squad_xp` (на новом уровне) и `Camp.grant_upgrade` (на трате). HUD рисует бэйдж на кнопке журнала; JournalPanel перерисовывает кнопки «выбрать». |
| `resources_changed` | `(type: int, amount: int)` | `Camp.add_resource` / `try_spend`. type — `ResourcePile.ResourceType` (int). amount — итоговый запас. HUD-счётчики, Journal «Лагерь» (афорд построек). |
| `camp_buildings_changed` | — | `Camp.try_build` после успешной постройки. JournalPanel перерисовывает карточки построек (для будущих одноразовых типа watchtower). |
| `collection_mode_changed` | `(mode: int)` | `Camp.set_collection_mode` (хоткеи C / V). HUD-индикатор «⚠ тревога» / скрыт. |
| `collection_priority_changed` | `(weights: Dictionary)` | `Camp.set_collection_priority` (preset-кнопки в Journal-вкладке «План»). Гном в `COMMUTING_TO_PILE` → `_on_pile_lost` → перевыбор. |
| `squad_created` | `(squad: RefCounted)` | `Camp.recruit_squad` / `cheat_summon_squad`. HUD создаёт карточку (lazy-создаёт ScrollContainer-панель если первая). |
| `squad_changed` | `(squad: RefCounted)` | `Camp._on_squad_changed` — re-emit от `Squad.members_changed` / `state_changed`. HUD перерисовывает карточку. |
| `squad_disbanded` | `(squad: RefCounted)` | `Camp._on_squad_disbanded` — после потери последнего члена. HUD убирает карточку. |
| `squad_recall_ignored` | `(squad: RefCounted)` | `Camp._handle_halt_input` — на каждый отряд вне recall-зоны при Q. HUD флешит карточку красным modulate-tween'ом. |
| `recall_zone_pulsed` | `(center: Vector3, radius: float, duration: float)` | `Camp._handle_halt_input` — на любое нажатие Q. HUD спавнит expanding-ring (тонкий фронт + размытый тейл) через `AoeVisual.spawn_expanding_ring`. |

`ResourcePile.take_one` через шину **не эмитит** (декремент `units` пока не нужен наружу — счётчика ресурсов ещё нет). При появлении HUD-счётчика добавится отдельный сигнал — типизированный как `Node3D`, как и остальные.

**Подписки самого Camp на шину:** помимо re-emit'а собственных `deployed/packed`, Camp слушает `EventBus.tower_destroyed` — обнуляет ссылку на башню, чтобы `_update_caravan_follow` и stationary-чек прекратили follow'ить мёртвую (но физически ещё существующую) Tower. Дополнительно через локальный `CampPart.destroyed.connect(_on_part_destroyed.bind(p))` Camp вычищает погибшую палатку из `_parts` И `_deployed_targets` (синхронно — иначе оставшиеся палатки уехали бы к чужим точкам кольца).

**Паттерн re-emit'а в сущности:**
```gdscript
func _ready() -> void:
    # ... базовая инициализация ...
    Damageable.register(self)
    damaged.connect(func(amount: float) -> void: EventBus.item_damaged.emit(self, amount))
    destroyed.connect(func() -> void: EventBus.item_destroyed.emit(self))
```

**Как подписаться (cross-cutting слушатель):**
```gdscript
func _ready() -> void:
    EventBus.enemy_destroyed.connect(_on_enemy_destroyed)

func _on_enemy_destroyed(enemy: Node3D) -> void:
    score += 10
```

**Принципы:**
1. Bus — **дополнительный** канал, не замена локальным сигналам. Hand:PhysicalActions слушает `Item.destroyed` локально (если ему это нужно для своей логики); UI слушает `EventBus.item_destroyed` — оба источника эмитятся параллельно.
2. Bus **только эмитит**. Никакой логики, фильтрации, состояния — иначе становится god-object'ом.
3. Подключение re-emit'а делается в `_ready` сущности **один раз**. Подклассы с собственным `_ready` обязаны звать `super._ready()`, иначе теряется подключение базы и регистрация в Damageable/Pushable группах. У `Enemy` есть assert в первом `_physics_process`, ловящий забытый `super._ready()`.
4. Тип-сигнатуры в сигналах bus'а служат документацией; рантайм Godot не валидирует их строго (динамический emit), но статический анализатор и автокомплит ловят опечатки.

### 9.1. LogConfig (autoload)

**Файл:** `scripts/log_config.gd`. **Регистрация:** `project.godot → [autoload] → LogConfig="*res://scripts/log_config.gd"`. Поле `master_enabled: bool` — глобальный мастер-выключатель debug-логов. Каждый entity-скрипт с per-entity `debug_log: bool` гейтит print'ы как `if debug_log and LogConfig.master_enabled:` — per-entity флаги остаются для тонкого мута одного шумного модуля, а `master_enabled = false` глушит всё разом (удобно при сборе/демо). На `printerr` (предупреждения) не распространяется.

### 9.2. PerfHud — `scenes/perf_hud.tscn`, `scripts/perf_hud.gd`

**Тип корня:** `CanvasLayer`, `class_name PerfHud`. Debug-оверлей для тестирования больших волн врагов и работы LOD-системы скелетов.

**Что показывает:**
- `FPS` (сглаженный по последним 8 значениям, чтобы не дёргался).
- `Process` (мс) — `Performance.TIME_PROCESS × 1000`. Время idle-кадра (AI, vision-сканы, скрипты-_process). На 60fps бюджет ~16мс на process+physics суммарно.
- `Physics` (мс) — `Performance.TIME_PHYSICS_PROCESS × 1000`. Время физкадра (CharacterBody3D.move_and_slide, broad-phase коллизии, knockback).
- `Draw calls` — `Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME`. Если ~= числу MeshInstance3D на сцене → батчинга нет, надо MultiMesh.
- `Objects` — `Performance.RENDER_TOTAL_OBJECTS_IN_FRAME`. Объекты в фрустуме камеры (то, что реально рисуется).
- `Mem` (МБ) — `Performance.MEMORY_STATIC / 1MiB`. Engine-память (без GPU).
- `Nodes` — `Performance.OBJECT_NODE_COUNT`. Все ноды в SceneTree.
- `Skeletons` — счётчик с разбивкой по LOD-уровням `NEAR / MID / FAR`. Распределение даёт визуальное подтверждение, что LOD реально классифицирует врагов по дистанции (не «все NEAR» из-за бага).

Используется в паре с cheat-кнопкой «Stress 2000 скелетов» (Журнал → вкладка «Читы», метод `WaveDirector.cheat_stress_2000`): спавн 2000 скелетов async-батчами и измерение, во что упирается. До 2026-05-08 этот же эффект был на keyboard-action `debug_stress_2000` (`]`).

**Структура:** `CanvasLayer → PanelContainer (полупрозрачный фон) → Label`. Position top-left, offset `(10, 10)`. Готово принимать клавишу `F3` через `_unhandled_input` (toggle visibility) — не зарегистрировано в InputMap, потому что debug-инструмент не должен засорять конфиг проекта.

**Цикл:** в `_process` тикает `_update_timer`; при истечении (`UPDATE_INTERVAL = 0.25с`) — `_update_label()`. Внутри: `Engine.get_frames_per_second()` для FPS + проход по `Skeleton.SKELETON_GROUP` (группа `&"skeleton"`) с подсчётом по `sk.get_lod_level()`.

**Источник данных:**
- FPS — `Engine.get_frames_per_second()`, кольцевой буфер 8 значений → среднее.
- Список скелетов — `get_tree().get_nodes_in_group(Skeleton.SKELETON_GROUP)`. Skeleton добавляется в эту группу в `_ready` (рядом с `add_to_group(SKELETON_GROUP)` после `super._ready()`). Группа ОТДЕЛЬНАЯ от `Damageable.GROUP`/`skeleton_target` — чтобы HUD не фильтровал по `is Skeleton` через type-check на каждом тике.
- LOD-уровень — публичный геттер `Skeleton.get_lod_level() -> int`. Приватное `_lod_level` снаружи не читается.

**Где живёт:** инстанс в `main.tscn` как ребёнок Main. Видим по умолчанию.

**Стоимость:** один проход по группе скелетов + 6 `Performance.get_monitor` reads раз в 0.25с + один `Label.text` setter. На 2000 врагов — < 0.1мс/обновление. Сам HUD не учтён в FPS-сглаживании специально — погрешность одного кадра поглощается буфером.

### 9.3. GameplayHud — `scenes/gameplay_hud.tscn`, `scripts/gameplay_hud.gd`

**Тип корня:** `CanvasLayer`. Игровой UI.

**Левая панель (под PerfHud):** два «окошка» способностей с цифрой клавиши и подписью: `[1]` хлоп, `[2]` щелк.

**Правая панель (top-right):** статус лагеря, программно дополняется тремя блоками:
1. Базовые строки из `.tscn`: 🟫 гном, 🟥 лучник, 🟫 палатки (`Camp.tent_count_alive()`).
2. Squad XP row (программно): иконка золота + «ур. N» + ProgressBar с XP/threshold внутри текущего уровня. Реактивно через `EventBus.squad_xp_changed`. На `squad_leveled_up` — flash-tween бара (200мс белого modulate).
3. Resources rows (программно, фаза 2): четыре строки с цветным квадратиком + названием + числом для WOOD/STONE/IRON/FOOD. Серый цвет числа при 0, белый при >0. Реактивно через `EventBus.resources_changed`.

**Программные элементы вне правой панели:**
- **Кнопка журнала** «📔 журнал [J]» — TOP_RIGHT-anchor под расширенной правой панелью, открывает JournalPanel. Бэйдж — красный кружок с числом невыбранных squad-апгрейдов (реактивно через `pending_upgrade_choices_changed`); скрыт при count=0.
- **Mode label** — под кнопкой журнала; виден только при ALARM (красный «⚠ тревога [V→C сброс]»). Реактивно через `collection_mode_changed`.

**Экспорты:** `camp_path: NodePath`. Цикл: `_process` раз в `UPDATE_INTERVAL=0.25с` обновляет базовые счётчики (гном/лучник/палатки). Squad XP, ресурсы, бэйдж, mode — реактивные сигналы.

### 9.4. JournalPanel — `scripts/journal_panel.gd` (autoload)

**Тип корня:** `CanvasLayer` (autoload). Заменяет старый `UpgradeModal` (удалён 2026-05-07): дизайнер не хотел останавливать игру модалом на каждый level-up.

**Открытие:** хоткей `J` (action `ui_journal`), либо клик кнопки в HUD'е. **Не ставит игру на паузу** — игрок выбирает апгрейд / постройку когда удобно. Закрытие: повторное `J`, крестик «×» в углу панели. Клики по полупрозрачному фону НЕ закрывают (легко промахнуться).

**Три вкладки:**

1. **Юниты** — апгрейды отряда из `Camp.UPGRADE_CATALOG`. Сортировка по `level`. Карточка показывает `name + description + level-tag`, состояние:
   - `✓ активен` — взят (карточка притенена)
   - `требуется ур. N` — `squad_level < required_level` (заблокировано)
   - `нет очков` — уровень есть, но банк `pending_upgrade_choices` пуст
   - `выбрать` — берётся, тратит очко из банка

2. **Лагерь** — постройки из `Camp.CAMP_BUILDING_CATALOG`. Карточка: `name + description + cost-row` (для каждого ресурса в cost — цветной квадратик + `имеется/требуется`, недостающие красным). Кнопка-состояние:
   - `только в развёрнутом лагере` — `deployed_only=true` и не в DEPLOYED
   - `не хватает ресурсов` — afford failed
   - `построить` — активна

3. **План** — preset'ы распределения сбора (`PLAN_PRESETS` const): Равномерно / Больше дерева/камня/железа/еды. Активный preset (тот, чьи нормализованные веса совпадают с `Camp.get_collection_priority()` с эпсилон 0.005) показан как `✓ активен`. На клик другого — `Camp.set_collection_priority(weights)`.

**Реактивность:** подписки на `pending_upgrade_choices_changed`, `squad_xp_changed`, `squad_upgrade_granted`, `resources_changed`, `camp_deployed/packed`, `camp_buildings_changed`, `collection_priority_changed` — `_refresh()` пересобирает только активную вкладку (если visible).

### 9.5. ResourceFx — `scripts/resource_fx.gd` (autoload)

Одноразовый particle-всплеск при сборе ресурса. Используется в двух местах:
- `Gnome._tick_commuting_to_base` — после `add_resource(_carry_type, 1)`
- `Camp._consume_piles_in_drop_zone` — после `pile.consume_all()`

API: `pulse(world_position: Vector3, color: Color)`. Программно создаёт `GPUParticles3D` (one_shot, 14 частиц, lifetime=0.6с, sphere-mesh 0.06м, unshaded+emission материал), парентится к `current_scene` (переживёт смерть Camp/Gnome'а), spawn'ится на `position + (0, 0.4, 0)` (над землёй / травой). Auto-cleanup через `create_timer(lifetime + 0.4)`.

Цвет берётся из `ResourcePile.color_for_type(type)` (единый источник истины — туда же ходят HUD/Journal/Gnome carry-визуал).

---

## 10. Незакрытые вопросы и направления

Не реализовано в текущей итерации (на будущее):

- **Магия.** Реализована (Fireball/Firestorm/Super), осталась прокачка через страницы и баланс.
- **Поворот башни** (мышью или клавишами).
- **Препятствия / стены.** Сейчас только плоский пол.
- **Контролируемое сглаживание захвата.** Магнит уже имеет дед-зону у руки и saturation по массе (`min(force, mass × max_accel)`); как следующий шаг — пружина (target velocity → force) могла бы сделать «подлёт» ещё стабильнее, особенно при движении руки.
- **Звук.** Полностью отсутствует.
- **Системный курсор.** Видим одновременно с рукой; имеет смысл скрыть/заменить на собственный.
- **Editor preview цвета Item.** Без `@tool` все ящики в редакторе серые до запуска.

**Армия (Squad/SoldierGnome) — открытые направления:**

- **Distribution внутри отряда.** HOLD/ESCORT-кольцо radius=1.6м тесное на 10+ юнитов. Нужны: динамический радиус от squad_size, или 2 концентрических кольца. (DEFEND wander-патруль уже самостоятельный.)
- **Spawn-лимиты.** Можно конвертировать всех gatherer'ов в копейщиков, оставить лагерь без сборщиков. Резерв (мин. N gatherer'ов на палатку)?
- **Гейт призыва через здание-казарму.** Сейчас «Армия» вкладка журнала всегда доступна (когда лагерь развёрнут). В будущем — `Camp.try_build` уже есть для построек.
- **Второй тип юнита** (опц.). Пока копейщик единственный мобильный класс. Лучник-кочевник с дальним боем (ranged subclass с override `_strike_at` через arrow_scene).
- **Особо крупные цели.** `_is_target_claimed_by_other` сейчас strict 1:1. Будущие крупные/боссы должны принимать `allow_multi_charge` или иметь capacity-чек (несколько копейщиков на одну цель).
- **Squad XP / прокачка отрядов.** `SoldierSystem` пока 1 уровень на тип. Если придёт время — `levels[]` как у SpellSystem.
