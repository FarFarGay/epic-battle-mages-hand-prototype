Привет, добро пожаловать в проект.
Твоя задача полностью изучить спецификацию проекта epic battle mages в этой папке, посмотреть и ревизировать код.
Внешний репозиторий находится по ссылке - https://github.com/FarFarGay/epic-battle-mages-hand-prototype
После изучения локального репозитория, нужно сравнить код и спецификацию на Git

Выполняй задачи как проофессиональный разработчик на Годот с 6 летним стажем. При необходимости используй в работе агентов.

Твой опыт и основные проекты на Godot - это экшен стратегии.

Сохраняй дополнительно приобретенные во время работы и скилы в этот файл.

---

# Заметки по работе с проектом (накапливаются)

## Сессия 2026-05-01 (вечер-3) — FAR-скелеты вне broad-phase: 29мс физики → ?

### Контекст / диагноз
Стресс-тест 2000 скелетов через `]` показал: FPS 7, Process 6мс, **Physics 29мс**, Draw calls 25. Узкое — physics. Не `move_and_slide` (NEAR/MID ~100 шт, ~6k вызовов/сек), а **broad-phase BVH на 2060 движущихся CharacterBody3D**. В прежнем «cold-mode» FAR-скелет имел `collision_layer=COLD_ENEMY, mask=0`, но CollisionShape оставался активным — physics-сервер всё равно индексировал AABB и ребилдил BVH каждый раз когда `_far_step` двигал `global_position`.

### Главные изменения
- **`Skeleton._apply_lod_physics_mode()`** ([skeleton.gd](scripts/skeleton.gd)): для FAR теперь `collision_layer=0, collision_mask=0` И `CollisionShape3D.disabled = true`. Это полностью убирает FAR-скелетов из broad-phase BVH. Для NEAR/MID — `disabled = false` обратно. Добавил `@onready var _collision_shape: CollisionShape3D = $CollisionShape3D`.
- **`HandPhysicalSlam._perform_slam()`** ([hand_physical_slam.gd](scripts/hand_physical_slam.gd)): после основного `PhysicsShapeQuery` — второй проход по `Skeleton.SKELETON_GROUP` с distance²-фильтром, фильтрует только `_lod_level == FAR`. Применяет тот же `Pushable.try_push` + `Damageable.try_damage`. Обходим 2000 элементов группы в _perform_slam (раз в slam_cooldown=0.5с) — пара 0.05мс, копейки.
- **Документация в [layers.gd](scripts/layers.gd)**: COLD_ENEMY теперь зарезервированный слой, FAR-скелеты на нём больше не лежат. Маски MASK_HAND_TARGETS / MASK_HAND_SLAM / MASK_FRIENDLY_PROJECTILE формально включают COLD_ENEMY, но в текущей логике это no-op (FAR-скелеты на layer=0). Оставлено на случай повторного использования слоя для других «исключаемых» сущностей.

### Главное архитектурно
- **Главный пожиратель physics_ms на 2000+ движущихся тел — это broad-phase index**, а не `move_and_slide` или active-pair тесты. `collision_mask=0` НЕ убирает тело из broad-phase BVH — только `CollisionShape3D.disabled = true` или `collision_layer=0` это делает. Запомнить для будущих перф-кризисов.
- **Group-fallback паттерн для AOE**: когда нужно «дотянуться» до объектов вне broad-phase, делаем второй проход по тематической группе с distance² (не distance — корень дороже). Применимо для slam, future spell-AOE, future shockwave башни. На 2000 элементах группы — 0.05мс.
- **Узкие места в архитектуре после фикса**: hand grab/magnet (Area3D `_grab_area`, `_magnet_area`) теперь не видят FAR-скелетов. На практике игрок крайне редко грабит скелета зумаут-камерой, поэтому пока live-with-it. Если потребуется — копировать паттерн group-fallback в Hand.get_grabbable_bodies/get_magnet_bodies.
- **Стрелы защитников и турели тоже теряют FAR-скелетов**, но `attack_radius=22.5м < lod_near_distance=25м` — стрелы летят только в NEAR/MID область, FAR-скелетов в полётной траектории не бывает. Потому ничего не правил.

### Что измерять после
- **Physics_ms должен упасть** с 29мс до ~5-10мс (BVH больше не индексирует ~1950 FAR-скелетов).
- **FPS должен подскочить** с 7 до 30-60 (зависит от того, что станет следующим узким).
- **Slam при зумаут-камере должен работать** — лог `[Hand:Physical:Slam]` теперь печатает «задело: N (из них FAR: M)»; если M>0 — group-fallback сработал.
- **LOD-распределение** в PerfHud должно остаться прежним (NEAR ~25, MID ~75, FAR ~1900 при 2000 скелетов uniform).

### Что отложено
- **Hand grab/magnet для FAR-скелетов** — добавить group-fallback, если игроку потребуется хватать скелетов на зумауте.
- **Стрелы и FAR** — добавить group-fallback в `arrow.gd`, если когда-то аркада будет стрелять дальше lod_near_distance (сейчас не нужно).
- **MultiMesh для FAR (вариант 3)** — если physics опустилась, но FPS всё ещё ниже 30, следующий боттлнек — рендер 1900 уникальных MeshInstance3D. ~250 строк, 2-3 часа работы.

### Дополнение 9 — Resource-система: типы ресурсов + ResourceZone-расставлятель
**Запрос геймдизайнера**: 4 типа ресурсов (дерево, камень, железо, еда) с разными визуалами; быстро расставлять зоны по карте.

**Архитектура (Этап А — простые pile'ы + зона-спавнер)**:
- В [resource_pile.gd](scripts/resource_pile.gd) добавлен enum `ResourceType` (GENERIC/WOOD/STONE/IRON/FOOD) и `PileShape` (AUTO/BOX/CYLINDER/SPHERE). Дефолтные визуалы по типу — wood: коричневый цилиндр-«бревно» (0.5×1.4×0.5), stone: серый куб (0.9×0.7×0.9), iron: тёмно-стальной приплюснутый бокс (0.8×0.4×0.8), food: красно-оранжевая сфера (0.7×0.7×0.7), generic: старый зелёный бокс. Если `pile_color/pile_size/pile_shape` оставлены дефолтными (BLACK/ZERO/AUTO) — берётся пресет; иначе экспорты переопределяют. CollisionShape пересоздаётся под форму (Box/Cylinder/Sphere). Logical поведение `take_one()` / hp / freeze не изменилось.
- Новый класс [resource_zone.gd](scripts/resource_zone.gd) (`@tool`, `class_name ResourceZone`) — нода-спавнер по аналогии с SpawnZone. Поля: `size: Vector2`, `resource_type: int (export_enum)`, `count`, `units_per_pile`, `min_spacing`, `pile_scene: PackedScene`, `spawn_root_path: NodePath`. На `_ready` (вне editor_hint): спавнит `count` инстансов pile'а в случайных точках внутри прямоугольника (с rejection sampling по `min_spacing`), назначает `resource_type` и `units` ДО `add_child`, рандомизирует Y-rotation. Визуал-индикатор скрывается в рантайме.
- Сцена [resource_zone.tscn](scenes/resource_zone.tscn) — Node3D + MeshInstance3D ребёнком, `pile_scene` уже привязан к resource_pile.tscn.

**UX**: дизайнер бросает ResourceZone в сцену, в инспекторе ставит type/count/size, всё. В редакторе видит цветной плоский индикатор зоны (цвет по типу для отличия — wood коричневый, stone серый, etc). При запуске сцены зона разбрасывает pile'ы и индикатор исчезает.

**Что НЕ сделали (Этапы Б/В на потом)**:
- Многоэтапное дерево (стоит → trunk → 3 logs). Сейчас wood-pile = «бревно» с units=3, гном забирает по 1 — функционально работает, визуально упрощено.
- `interaction_time` на pile'е (гном «рубит/копает» N секунд перед take_one). Сейчас take_one мгновенный.

### Дополнение 8 — Boids-style avoidance: визуальное расступание без physics-пар
**Симптом**: после убирания skel-skel пар (Дополнение 3) на волнах визуально некрасиво — скелеты сходятся в одну кучу и проходят друг через друга. Геймдизайнер: «не нравится».

**Решение** — boids-style avoidance через spatial-grid скелетов.
- Static `_skel_grid: Dictionary` (по аналогии с `_target_grid`), cell_size=4м, refresh раз в 0.3с.
- В `_ai_step` после super._ai_step / _wander_tick вызывается `_apply_neighbor_avoidance()`. Скелет суммирует векторы отталкивания от соседей в radius=1.5м (linear falloff), кап по магнитуде `move_speed × strength`, прибавка к velocity.
- Применяется только в APPROACH (включая wander) и НЕ-FAR — engaged скелеты (WINDUP/STRIKE/COOLDOWN) и FAR не отвлекаются.
- Avoidance прибавляется до MID-компенсации velocity*N, чтобы масштабироваться синхронно.

**Параметры (export'ы)**:
- `neighbor_avoidance_radius: float = 1.5` — personal space.
- `neighbor_avoidance_strength: float = 0.5` — доля move_speed (max 0.5×2.7 = 1.35м/с avoidance).
- `0` — выключить (вернётся «толпа фантомов»).

**Цена**: 9-cell scan × ~5 entries × ~10 ops = ~200 ops/вызов. ~12k вызовов/сек × 200 ops = ~12мс CPU/сек = 0.2мс/кадр. Незначительно.

**Эмерджентное поведение**: скелеты, идущие к одной палатке, формируют не плотный «клин», а арку/полукольцо вокруг неё (avoidance = тяга наружу, target = тяга внутрь, equilibrium на ring'е). Выглядит естественно как RTS-flocking. Engaged-скелеты (атакующие) avoidance НЕ применяют — на них не давят соседи, они стоят на своих позициях.

**Что не сделали**: avoidance для FAR — невидимы, незаметно. Если камера панится на FAR-кластер — frustum-override переводит ближайшие в NEAR/MID, avoidance включается, кластер расходится за ~1-2с (время refresh + tick).

### Дополнение 7 — Tower mask без ENEMIES + MID divisor 2→3
После spatial grid'а Process упал с ~12мс до **3мс** (vision больше не узкое), но physics остался **20мс**, FPS 15-20. Все ~20мс ушли в чистый m_a_s + broad-phase.

**Скрытый пожиратель**: Tower сам делает `move_and_slide` каждый тик (он CharacterBody3D, движется по миру, см. tower.gd:100). Его `collision_mask = 31` включал бит ENEMIES (16) → Tower процессил контакты с КАЖДЫМ NEAR/MID скелетом в зоне. В кластере из 100+ skel'ов — это десятки контактов в каждом m_a_s Tower'а × 60Гц. Легко 3-5мс физики.

**Решение**: Tower.collision_mask 31→15 в [scenes/tower.tscn](scenes/tower.tscn). Убрал бит ENEMIES (16). Tower теперь не видит скелетов в своих коллизиях → m_a_s проходит без contact processing с ними.

**Что сохранили**: pair всё ещё формируется (skel.mask=39 включает ACTORS=4 = Tower.layer), скелет всё ещё обнаруживает Tower как препятствие → bounce-off на lunge работает. Только Tower сам не «видит» скелетов в своих контактах. Геймплейно: Tower теперь физически едет сквозь толпу скелетов, не тормозясь о них (разумно — он тяжёлая башня, скелеты лёгкие).

**Дополнительно**: MID-divisor дефолт 2→3 в [skeleton.gd](scripts/skeleton.gd). MID скелеты тикают на 20Гц вместо 30. На 25-50м от камеры визуально незаметно. Tunneling-проверка: 2.7×3×0.0167 = 0.135м/тик при радиусе 0.4 — запас ×3.

**Ожидание**: physics 20мс → ~12-14мс. FPS 15-20 → 35-50.

### Дополнение 6 — Spatial grid для skeleton_target: 720k → ~50k distance-checks/сек
Layer split + frustum-override на гномов не помогли (physics 20мс, FPS 7) — мы оптимизировали collision-pairs, но узкое сместилось в **vision-сканы**.

**Анализ**: Гномы в `skeleton_target` group растят размер с ~18 (палатки) до ~144 (палатки + 126 гномов). Каждый скелет в `_scan_target` итерировал ВСЮ группу с `get_nodes_in_group()` + distance-check. Считал: 487 NEAR/MID + 1500 FAR ≈ 5000 vision-сканов/сек × 144 = **720k distance-checks/сек, или ~12-15мс из 20мс physics_ms** (поскольку `_scan_target` зовётся внутри `_physics_process`). Это именно тот класс боттлнека, что был у DefenderGnome (3fps на 340 скелетах) — лечится spatial grid.

**Решение**: spatial grid в [skeleton.gd](scripts/skeleton.gd) как static class state (не autoload — пользует только Skeleton).
- `_target_grid: Dictionary = {}` — `Vector2i(cell_x, cell_z) → Array of [Vector3 pos, Node3D node]`.
- `TARGET_GRID_CELL_SIZE = 12.0` (= vision_radius). 3×3 cell'ов вокруг скелета гарантированно покрывают vision-диск.
- `TARGET_GRID_REFRESH_INTERVAL = 0.4с`. Все скелеты читают один глобальный snapshot. Stale-границы: гном двигается ≤0.64м за 0.4с (move_speed=1.6 × 0.4) — для vision_radius=12 неотличимо.
- `_maybe_refresh_target_grid(tree)` — ленивый pass по группе раз в 0.4с globally вместо одного pass'а на каждый скан каждого скелета.
- `_scan_target` теперь смотрит 9 cell'ов (3×3) вокруг своей cell-позиции. Каждый cell — Array из ~5-15 элементов в плотной Camp-зоне, 0 в пустой. dist²-чек первым (cheap), затем validity/group (expensive).

**Ожидание**: 5000 сканов/сек × ~50 элементов в окрестности (вместо 144) = 250k checks/сек (вместо 720k). ~3× редукция. Physics_ms: **20мс → ~10-12мс**. FPS должен подскочить до 30+.

**Cache-валидность**: skel'ы могут таргетить уже мёртвую цель в окне 0.4с stale snapshot'а — `is_instance_valid` + `is_in_group` чек в loop'е отсекает. Grid не отслеживает unregister в реальном времени — refreshing раз в 0.4с — компромисс простоты vs точности.

**Gotcha (зафиксил)**: `var node: Node3D = entry[1]` — typed assignment ИЗ Array — вылетает с `Trying to assign invalid previously freed instance` если объект уже освобождён. is_instance_valid сработал бы, но НЕ ДОТЯГИВАЕТ — runtime бьёт ошибку до проверки. Правильный паттерн с грид-снэпшотами:
```
var raw = entry[1]              # untyped Variant
if not is_instance_valid(raw):
    continue
var node := raw as Node3D       # `as` cast freed-объекта возвращает null без ошибки
if node == null:
    continue
```
В loops через `for n in get_nodes_in_group(...)` тот же паттерн (`n` заимствуется как Variant, `as` возвращает null для freed) — безопасно. Опасно именно при typed `var x: Type = arr[i]`.

**Альтернатива spatial grid'у** для будущего: TargetGrid autoload с `register/unregister`-хуками в Gnome._ready/_destroyed и CampPart._ready/_destroyed — нулевая задержка, но сложнее. Пока хватает snapshot'а.

### Дополнение 5 — Гномы в свой layer FRIENDLY_UNIT, frustum-override на гномов
**Симптом**: «если вызвать гномов в толпе скелетов — жесть просадка ФПС». В толпе из 126 гномов + 487 NEAR/MID скелетов вокруг Camp каждый скелет в move_and_slide процессит контакты с каждым близким гномом. Сотни skel-gnome пар в кадре.

**Решение**:
1. Новый layer `FRIENDLY_UNIT = 1 << 8 = 256` (layer 9 = bit 8). Зарегистрирован в [project.godot](project.godot) и [layers.gd](scripts/layers.gd).
2. Гнома и DefenderGnome перенёс с layer=ACTORS(4) на layer=FRIENDLY_UNIT(256). Файлы: [scenes/gnome.tscn](scenes/gnome.tscn), [scenes/defender_gnome.tscn](scenes/defender_gnome.tscn).
3. `MASK_SKELETON` (39) FRIENDLY_UNIT не включает → скелет в broad-phase гнома не видит → пар нет → m_a_s проходит сквозь гнома без collision-iteration. Tower остался на ACTORS (4), MASK_SKELETON ACTORS включает → башня по-прежнему блокирует скелетов и даёт bounce-off на lunge.

**Что сохранили**: Damageable.try_damage(gnome) на STRIKE-фазе скелета — это отдельный код-путь, не зависит от physics-collision. Скелет всё ещё ловит цель глазами (vision_radius=12м), бьёт STRIKE'ом, наносит damage. Только физически проходит сквозь гнома (а не упирается).

**Что потеряли**: visual «скелет упирается в гнома» — теперь он лунжит сквозь. И bounce-off от гнома (если был) не сработает — но bounce у скелета настроен только на active-target, а если гном не active_target скелета (когда target — палатка), такого bounce и не было.

**Hand/arrow проверка**: GrabArea (mask=210), MagnetArea (mask=2), Arrow (mask=145) FRIENDLY_UNIT не включают — гномов и не видели раньше (через ACTORS не сканировали), не видят и теперь.

**Frustum-override на гномах** (в [gnome.gd:_update_lod()](scripts/gnome.gd)). Симметрично Skeleton._update_lod_level: если гном вне cone'а вокруг forward-направления Camera3D → форсируем `_lod_far = true` (cold-mode без move_and_slide и гравитации). На 126 гномах в кластере вокруг Tower при стандартной FOV это перенесёт ~50% в холодный режим. Новый export `lod_offscreen_half_angle_deg: float = 60.0`, прекомпьют cos в _ready.

**Ожидание**: physics должна резко упасть. На сцене с гномами в толпе скелетов раньше получали жёсткие просадки ФПС — после обнуления skel-gnome пар + cold-mode половины гномов нагрузка на NEAR/MID скелетов сократится в разы (меньше slide-iterations об гномов).

### Дополнение 4 — MID-divisor (60→30Гц для средней зоны) с компенсацией velocity
После снятия skel-skel коллизий physics 16→18мс — изменений по сути нет. Геймдизайнер уточнил наблюдение: «лагает когда скелеты в палатках застревают или между ними». Главная нагрузка — `move_and_slide` с slide-iterations об палатки и башню для 100 NEAR + 301 MID скелетов в кластере.

**Решение**: MID-divisor по аналогии с FAR-divisor. MID-скелеты тикают на 30Гц вместо 60Гц. Скорость движения сохраняется через **компенсацию velocity** в `_ai_step`: на полном тике `velocity.x/z *= divisor` → один `move_and_slide` переносит N кадров пути.

- Новый export `lod_mid_tick_divisor: int = 2` (range 1-4).
- Новый счётчик `_mid_phys_tick_counter` с фазовым сдвигом `randi() % 4`.
- В `_physics_process`: `match _lod_level` ветвится на FAR/MID/NEAR, MID early-return на N-1 из N тиков.
- В `_ai_step` (после super._ai_step или _wander_tick): `if _lod_level == MID and lod_mid_tick_divisor > 1: velocity.x *= mult; velocity.z *= mult`. Knockback ветка (super._physics_process в base Enemy ветвится по `_knockback.is_active`) сюда не попадает — компенсация только для нормального AI-движения.

**Tunneling-проверка**: skel.move_speed=2.7 × divisor=2 × 0.0167 = 0.09м/тик при радиусе 0.4м → запас ×4. Lunge_speed=8 — но это knockback, в обход _ai_step, не множится.

**Ожидание**: 301 MID × 60 = 18060 m_a_s/сек → 9030 m_a_s/сек. Total m_a_s в кадре с 100 NEAR (60Гц) + 301 MID (30Гц) = ~250 m_a_s/тик вместо ~400. Physics ~10мс. FPS должен подскочить до 30-40.

NEAR (100 скелетов в фокусе игрока) трогать не стал — фризы заметны при близкой камере. Если 10мс окажется недостаточно — добавим NEAR-divisor=2 или сделаем «auto-anchor» (скелет в attack-режиме у палатки → set_physics_process(false), таймер атак в _process).

### Дополнение 3 — skel-skel коллизии отключены: `MASK_SKELETON` без ENEMIES
После frustum override физика 16мс → ожидали 8-10мс. Цифры показали 100 NEAR + 301 MID = 401 в обзоре (frustum снял только 86 шт периметра, не центральный кластер вокруг Tower'а — он-то в кадре). Геймдизайнер диагностировал верно: **скелеты сбиваются в кучи, не обтекают друг друга, физика грузит broad-phase пары и move_and_slide.collision_iterations**.

**Решение**: в [layers.gd](scripts/layers.gd) убрал бит `ENEMIES` из `MASK_SKELETON`: `TERRAIN | ITEMS | ACTORS | CAMP_OBSTACLE = 39` (было 55). Поскольку И A и B — оба скелеты, пара в broad-phase не формируется (Godot pair = `(A.mask & B.layer) || (B.mask & A.layer)`; обе стороны вычеркнули ENEMIES → ни одна не видит другую). Также обновил `collision_mask = 39` в [scenes/skeleton.tscn](scenes/skeleton.tscn) — это initial value до первого LOD-перехода.

**Цена**: `Enemy._push_neighbor` lunge-domino перестаёт работать. Реализован через `get_slide_collision()` после `move_and_slide` в `_resolve_knockback_contacts` ([enemy.gd](scripts/enemy.gd)) — без skel-skel slide-collision'ов туда никто не попадает. Документировал в [skeleton.gd](scripts/skeleton.gd) docstring и в комменте к константе `MASK_SKELETON` в [layers.gd](scripts/layers.gd). Если потребуется восстановить (визуальная фишка «удар → волна по соседям») — paттерн group+dist push, аналогичный Slam group-fallback.

**Что сохранили**: skel-tower bounce (Tower.layer=ACTORS, в маске), skel-tent блок (CAMP_OBSTACLE в маске), skel-ground (TERRAIN), skel-item push (ITEMS). Только взаимодействие skel-skel вычеркнуто.

**Ожидание**: physics 16мс → 5-8мс. На 400 NEAR/MID kostьм пары между ними — главная нагрузка; их больше нет. FPS должен вернуться в 30+ при башне в кластере.

### Дополнение 2 — frustum-aware LOD: NEAR/MID кластер вокруг башни
После 19мс физики (uniform 2000) Tower заехал в кластер NEAR/MID 487 шт (157 NEAR + 330 MID), physics опять 20мс — узким стало уже не FAR-`_far_step`, а **`super._physics_process` + `move_and_slide` для 487 NEAR/MID** (≈29k вызовов/сек) и broad-phase пары между ними в плотной куче.

Альтернативы рассмотрел:
1. MID-divisor (тикать MID на 30Гц вместо 60). Простой, режет ~33%. Без учёта видимости.
2. **Frustum-aware LOD**: скелет вне обзора → форсируем FAR. Учитывает то что игрок реально видит.

Выбрал #2. Сильнее эффект (50-65% NEAR/MID уходят в FAR при FOV ~70°), проще код (~15 строк), геймплейно правильнее: видимое — детально, невидимое — дёшево. Без эксплойтов «отвернись и не получишь удар»: симуляция продолжает работать в FAR-режиме (с divisor=3), просто дёшево.

**Реализация** в [skeleton.gd:_update_lod_level()](scripts/skeleton.gd):
- Новый export `lod_offscreen_half_angle_deg: float = 60.0` (полу-cone «впереди камеры»). 60° = 120° полный cone, покрывает горизонтальный FOV ~95° (FOV=70 + aspect 16:9) с запасом.
- В `_ready` прекомпьютим `_lod_offscreen_cos = cos(deg_to_rad(60.0))` чтобы не гонять трига на каждом LOD-чеке (раз в 0.5с × 2000 скелетов).
- В `_update_lod_level` ДО distance-classification: `to_skel = pos - camera.global_position`, `forward = -camera.global_transform.basis.z`, `cos_angle = forward.dot(to_skel) / dist`. Если `cos_angle < _lod_offscreen_cos` → FAR, return.
- Frustum-чек от Camera3D (реальная точка наблюдения), а не от CameraRig'a (он только distance-anchor).

**Ожидаю:** при том же кластере NEAR/MID должно упасть с 487 до ~200, physics с 20мс до 7-10мс. FPS подскочит до 50-60 при тех же 2000 скелетов и башне в гуще.

### Дополнение (после первого замера: 29мс → 19мс)
Отключение CollisionShape убрало broad-phase, но physics_ms осталось 19мс. Анализ — 1900 FAR × 60Гц = 114k вызовов `_far_step`/сек: knockback.tick, vision-валидность, position-write, wander/AI. Это GDScript-нагрузка, выполняется в физкадре → засчитывается в physics_ms.

**Добавлен FAR-divisor:** новый export `lod_far_tick_divisor: int = 3` в Skeleton. В `_physics_process` для FAR-скелетов теперь:
- Каждый физкадр: декремент `_lod_check_timer` (для своевременных LOD-переходов).
- Только каждый N-й физкадр (N=divisor): `_far_step(delta * N)`. Остальные тики — early return.
- На «полном» тике `work_delta = delta × divisor`, чтобы movement, knockback friction, vision_scan_timer корректно покрывали пропущенные кадры в wall-clock.
- Фазовый сдвиг `_far_phys_tick_counter = randi() % 6` в `_ready` — иначе все FAR-скелеты бегают _far_step в одном физкадре, нагрузка идёт волной.

**Ожидание:** physics_ms должен ещё упасть пропорционально divisor'у. При divisor=3 — теоретически до ~7-9мс. Slam по FAR задерживается на ≤50мс — не видно. Inner `_lod_should_skip_ai_tick` (для FAR — каждый 3-й AI-тик) остался — суммарная AI-частота FAR ≈ 60/3/3 ≈ 6.7Гц, для боя с целью без скипа 60/3 = 20Гц. На практике норм.

## Сессия 2026-05-01 (вечер-2) — Перф-измерения для 2000 скелетов: PerfHud + stress-кнопка

### Главные изменения
- **PerfHud расширен** ([perf_hud.gd](scripts/perf_hud.gd)): к FPS+LOD-счётчику добавлены `Process` ms, `Physics` ms (через `Performance.TIME_PROCESS × 1000` и `TIME_PHYSICS_PROCESS × 1000`), `Draw calls` и `Objects` (`RENDER_TOTAL_DRAW_CALLS_IN_FRAME` / `RENDER_TOTAL_OBJECTS_IN_FRAME`), `Mem` MB (`MEMORY_STATIC / 1MiB`), `Nodes` (`OBJECT_NODE_COUNT`). Layout панели расширен до 540×100, шрифт 14, 3 строки.
- **Stress-кнопка `]`** (action `debug_stress_2000`, keycode 93): fire-and-forget вызов `EnemySpawner.spawn_uniform(skeleton_scene, 2000)`. Без safe-фильтра, без SpawnZone-фильтра — uniform по всему квадрату ±map_half_extent. Async-батч по 6/кадр (≈5.5с до полного спавна на 60fps). Висит рядом с `[`-debug в `wave_director.gd:_process`.

### Главное архитектурно — методология следующих оптимизаций
- **Не оптимизируй вслепую.** На 290 скелетах главным win'ом был LOD + collision_mask=0 на FAR. На 2000 узким местом может быть совсем другое — vision-сканы группой `skeleton_target` (O(N×M) на каждом скане), draw calls (если LOD-FAR не схлопнут в MultiMesh), память (~2000 Node3D + ScatterEffect-резервы).
- **PerfHud теперь главный диагностический инструмент.** Сценарий: P → стартовать кампанию → ] → спавн 2000 → подождать пока async закончит → читать Process/Physics/Draw calls.
  - **Process растёт** → CPU AI/vision узкое. Кандидаты: spatial grid для `_scan_target` (главный win), уменьшить `lod_far_distance`, snapshotить группу `skeleton_target` раз в 0.5с в Array вместо `get_nodes_in_group` каждый скан.
  - **Physics растёт** → broad-phase или move_and_slide. Кандидаты: уменьшить `lod_far_distance` чтобы быстрее уходило в FAR (move_and_slide там не вызывается), вынести replenish-таймеры из физтика в idle.
  - **Draw calls ≈ числу MeshInstance3D** → GPU/уникальность мешей. Кандидат: MultiMesh для FAR-скелетов (1 draw call на пачку).
  - **Mem растёт линейно с N** → Node-aллокация. Кандидат: pool скелетов вместо queue_free/instantiate.
- **`Performance.get_monitor(id)`** возвращает float; `TIME_PROCESS / TIME_PHYSICS_PROCESS` в секундах (нужно ×1000 для мс), всё остальное — ints в float-обёртке. Документация: [Godot Performance class](https://docs.godotengine.org/en/4.6/classes/class_performance.html).
- **Fire-and-forget coroutine pattern**: `_spawner.spawn_uniform(skeleton_scene, 2000)` без `await` запускает coroutine, `_process` продолжается. Это легитимный паттерн в GDScript — coroutine работает до первого `await get_tree().physics_frame` и резюмится по физкадрам автономно. Используем где не нужен возврат значения и не нужно ждать конца.

### Что отложено / план оптимизации по приоритету
1. **Прогнать stress-test 2000** — какой из счётчиков PerfHud вылетел? Это определит порядок следующих шагов.
2. **Spatial grid для skeleton_target** (если Process высокий): autoload `TargetGrid` с cell ~10м, `register_target/unregister_target` хуки в `Gnome._ready/_destroyed` и `CampPart._ready/_destroyed`, `query(pos, radius)` возвращает массив целей в 9 соседних cell'ах. `Skeleton._scan_target` использует grid вместо `get_nodes_in_group` + полный обход.
3. **MultiMesh для FAR-скелетов** (если Draw calls высокий): один `MultiMeshInstance3D` рядом с CameraRig'ом, FAR-скелет регистрирует свой transform-слот при переходе в FAR, освобождает при возврате в MID. Mesh скелета (`MeshInstance3D`) при FAR делается невидимым; все FAR рисуются как пачка.
4. **Снизить `lod_far_distance` 50→35** (если Physics высокий): константа в Skeleton, бесплатно.
5. **Pool скелетов** (если Mem растёт): EnemyPool autoload с pre-allocated скелетами, при `queue_free` возвращаем в пул вместо удаления.

### Ключевые числа
- Stress-test: 2000 скелетов uniform по карте ±195м.
- Spawn rate: 6/кадр × 60fps = 360/сек → 5.6с до полного спавна.

## Сессия 2026-05-01 (вечер) — SpawnZone: диск → прямоугольник

### Главные изменения
- **`SpawnZone.radius: float` → `SpawnZone.size: Vector2`** (полные размеры по локальным X (size.x) и Z (size.y), в метрах). Дефолт `Vector2(60, 60)` — квадрат, грубо соответствующий прежнему диску r=30 по площади. Поворот вокруг Y живёт в transform узла; сэмплирование точки прогоняет локальный `(rand_x, 0, rand_z)` через `zone.global_transform`, поэтому повёрнутые зоны работают корректно.
- **Визуал**: `CylinderMesh` (h=0.04, top/bottom_radius=1) → `BoxMesh` (size=`Vector3(1, 0.04, 1)`). Mesh-нода масштабируется сеттером `size` до `(size.x, 1, size.y)`. По умолчанию `transform.scale = (60, 1, 60)` в `scenes/spawn_zone.tscn`.
- **Public API SpawnZone**: добавлен `area() -> float` (`size.x * size.y`). EnemySpawner использует его для взвешивания выбора зоны и для проверки «зона валидна» (вместо прежней проверки `radius > 0`).
- **EnemySpawner.pick_random_pos**: вес выбора зоны теперь `area()` вместо `r²`. Сэмплирование внутри выбранной зоны делегировано `random_point_in_zone(zone)` — общий код, не дублируется.
- **EnemySpawner.random_point_in_zone**: вместо `(angle, sqrt(rand)*r)` теперь `randf_range(±size.x/2)` и `randf_range(±size.y/2)` в локали, потом `zone.global_transform * local`.
- **Видимость только в редакторе**: `_refresh_visual()` ставит `mesh.visible = Engine.is_editor_hint()`. В Play/билде красные коврики не отрисовываются — игрок их не видит. В редакторе остаются для дизайнера.

### Главное архитектурно
- **`global_transform * Vector3.local`** — корректный путь для сэмплирования внутри ориентированного прямоугольника. Не требует matrix-разбора, basis уже включён.
- **Дефолт `Vector2(60, 60)` ≈ старому диску r=30**. Площадь: 3600 vs π·900≈2827. Близко, чтобы на первом запуске после миграции спавн-плотность не упала. Если делать совсем эквивалентно — `Vector2(53, 53)` (площадь ~2809).
- **Существующие 7 зон в `main.tscn`** не имели override'ов `radius` (использовали дефолт). Теперь у них `size` тоже дефолтный → вживую станут квадратами 60×60. Дизайнеру нужно будет пройти по сцене и задать осмысленные ширины/длины руками (или повернуть зоны — это теперь поддерживается).
- **`RoadSpawnZone` теперь не нужен как отдельный класс** — обычный SpawnZone с длинным узким size и поворотом по углу дороги делает то же самое. Заметку из «Что отложено» предыдущей сессии можно вычеркнуть в этой части.

### Ключевые числа (актуальные после сессии)
- SpawnZone дефолт: `size=Vector2(60, 60)`, `wave_count=5`, `skeletons_per_wave=10`.
- POI safe radius: 45м, Camp safe radius: 45м (без изменений).

### Что отложено / на следующую сессию
- **Передизайн расстановки SpawnZone в main.tscn**: после миграции все 7 зон стали квадратами 60×60 на старых позициях. Дизайнеру стоит прокатиться по сцене и подобрать осмысленные размеры/повороты под коридоры между POI (особенно для логики «волны идут по дороге»).
- **Стрелы не втыкаются в землю** (хвост).
- **HUD-индикатор уровня защитника** (хвост).
- **Quest-завершение по триггерам** вместо клавиши Q (хвост).

## Сессия 2026-05-01

### Главные изменения
- **Quest-система** (autoload `QuestProgress` + `class_name QuestActor`) — 3 POI на карте (`Poi_ESE`, `Poi_Heart`, `Poi_SW`) с актором-капсулой на каждом, цвет по состоянию (locked/active/completed). Прогресс продвигается клавишей **Q** (debug-заглушка). Сигнал `EventBus.quest_advanced(new_index)` — все акторы перекрашиваются по нему. Геймдизайнерская привязка: `actor_id` (StringName) + `quest_order` (int) per-instance. Линейная цепочка ESE → Heart → SW.
- **SpawnZone** (`class_name SpawnZone`, `@tool`) — диск спавна с budget'ом волн. Поля: `radius`, `target_poi: NodePath`, `wave_count` (стартовый бюджет), `skeletons_per_wave`. Рантайм-API: `consume_wave/add_waves/set_waves`. EnemySpawner собирает все `SpawnZone`-дети `zone_root_path` в `_ready`.
- **WaveDirector переписан под зоны**:
  - **Neutral-спавн** (initial 20 + ramp до 50 + replenish + `[`-debug-100): через `EnemySpawner.pick_random_pos()` — uniform-точка в объединении SpawnZone-ов площадно-взвешенно (πr²). Safe-фильтр Camp/POI накладывается поверх (45м), 30 попыток + фоллбэк.
  - **Waves**: дирижёр выбирает SpawnZone с `waves_left() > 0` (uniform random) → `random_point_in_zone(zone)` → группа из `zone.skeletons_per_wave` → ближайший Camp как target → `consume_wave()`. Глобальный `wave_count` экспорт удалён, теперь per-zone.
  - **Public API**: `set_waves_in_all_zones(n)` / `add_waves_to_all_zones(n)` — для рантайм-эвентов типа «приход Короля Ночи» (заполнить всем зонам по 100 волн разом).
- **POI safe-радиус** в WaveDirector: `poi_safe_radius=45м` (новый параметр, симметричный `wave_safe_radius=45м` для лагерей). Скелеты не спавнятся ближе этого радиуса к POI. `_safe_score(pos)` — общий «избыток distance − safe_radius», >=0 принимаем, иначе фоллбэк-кандидат с max score.
- **Фикс палаток**: `Camp._spawn_tents` теперь строит цепочку **сразу за башней** (`leader_xz - (i+1) × part_gap`). Раньше tent[0] спавнился в Camp local (0,0,0) и догонял башню через exp_decay — на разнесённых Camp/Tower палатки на первом кадре сидели в центре.
- **Debug-кнопка `[`** (action `debug_spawn_100`): моментальный спавн 100 скелетов neutral по зонам. Не трогает фазу/таймеры кампании, можно жать в IDLE.

### Главное архитектурно
- `class_name SpawnZone` через @tool — сеттер `radius` сразу масштабирует визуальный диск-индикатор в редакторе. Шаблон @tool+setter+get_node_or_null хорошо работает для дизайнерских визуальных хелперов в Godot 4.6.
- **Два потока спавна — neutral и waves — расщеплены**. Neutral идёт через `pick_random_pos()` (все зоны, включая исчерпанные) + safe-фильтр. Waves идёт через `random_point_in_zone(zone)` (одна конкретная) без safe-фильтра — дизайнер отвечает за непересечение с safe-зонами.
- **Roads** (`scripts/roads.gd`) — генератор-меш дорог между POI через `SurfaceTool` с конвертом-синусом и FastNoiseLite — **сделан и откатан** (геймдизайнер передумал). Файл оставлен в `scripts/`, но в `main.tscn` ноды Roads нет. Если вернуть — добавить `[node name="Roads" type="Node3D" parent="." script=ExtResource("…")]`.
- **PoiMarker @tool с safe-зоной визуала** — пробовали, **откатили**. Был перегруз по визуалу (бирюзовый диск 45м у каждой POI закрывал собой полкарты). Глобальный `poi_safe_radius` остался в WaveDirector как и был.
- **Quest-актор реализован как ребёнок POI**, а не как сам POI: разделили «гео-маркер» (POI, статика) и «выдатчик квеста» (Actor, состояние). POI ничего не знает про квесты, Actor ничего не знает про safe-зоны. Хорошая декомпозиция.

### Ключевые числа (актуальные после сессии)
- POI safe radius: 45м (глобально на WaveDirector — новый параметр).
- Camp safe radius: 45м (глобально на WaveDirector — без изменений).
- SpawnZone дефолт: radius=30м, wave_count=5, skeletons_per_wave=10.
- POI на карте (Tower сейчас на x=159): `Poi_ESE` (124, 0), `Poi_Heart` (0, 0), `Poi_SW` (-110, 0). Линия z≈0.
- Стартовая `SpawnZone1` в (-130, 0, -130), r=30 — далеко от всех safe-зон.

### Что отложено / на следующую сессию
- **Дороги между POI**: геймдизайнер хочет, чтобы Tower+гномы шли по дороге вне safe-зон, в зонах готовились к переходу. Дизайнерское решение по плотным коридорам спавна вдоль дорог — пока ручная расстановка дисков `SpawnZone` (4-6 штук между POI). Альтернатива — параметрический `RoadSpawnZone` (прямоугольник между двумя точками + ширина) — отложили на «когда диски достанут тюнить руками».
- **Цель волн = POI, а не Camp**: текущая логика `_nearest_alive_camp(origin)` работает корректно когда Camp следует за Tower (волна идёт туда где сейчас Camp, т.е. куда подъехала башня). Если игроку дадут несколько Camp'ов одновременно — будет правильное распределение по близости. Но если архитектура поменяется на «осада статичной POI без Camp» — нужен fallback на POI как target.
- **Quest-завершение по триггеру** вместо клавиши Q: пока Q просто `QuestProgress.advance()`. Настоящие триггеры (диалог завершён, монстр убит, предмет принесён) — отдельная задача.
- **Стрелы не втыкаются в землю** (унаследовано с прошлой сессии).
- **HUD-индикатор уровня защитника** (унаследовано).

## Состояние репозитория на 2026-04-30
- Локальная `main` синхронизирована с `origin/main` (последний коммит `61114d2`).
- За сессию 2026-04-29/30 добавлено 3 коммита:
  1. `df7cdb0` feat: волновая система с режиссёром + один Camp у Tower + HUD
  2. `956b7dc` feat: баллистика стрел + прокачка точности защитников
  3. `61114d2` docs: SPEC.md под текущее состояние

## Главное архитектурно (новое в 2026-04-29/30)
- **WaveDirector** (новый узел в main, scripts/wave_director.gd) — режиссёр кампании
  врагов. Фазы IDLE → RAMP (20→50 за 30с) → MAINTAIN (replenish с гистерезисом 20
  + волны каждые 60с). Спавн волны: точка вне 35м safe-радиуса от лагеря через
  `_pick_safe_pos` с N попыток + fallback. Forced_target = ближайшая палатка
  (Camp.nearest_part_to). P — старт/рестарт, O — немедленная волна.
- **EnemySpawner** теперь низкоуровневый: публичный API `spawn_at / spawn_uniform /
  spawn_ring / spawn_group / kill_all_skeletons`. Старый `spawn_wave()` остался как
  debug helper. P-биндинг ушёл в WaveDirector. `map_half_extent` теперь 195
  (карта 400, был drift с 95).
- **Skeleton._scan_target приоритет: гномы > палатки**. Скелеты «голодные», палатка —
  цель только когда гномов в зоне нет. `forced_target` — fallback aggro для
  wave-скелетов (они спавнятся в 50м+ от лагеря, vision 12м не достаёт).
- **DefenderGnome прокачка точности**. `_shots_fired: int` per-инстанс,
  `current_inaccuracy_radius() = base / (1 + shots/half)` — логарифмическая кривая.
  base=1.5м, half=100, после 500 выстрелов разброс 0.25м (стабильно цепляет).
  Опыт теряется на смерть/P-рестарт через `Camp.reset_population()`. Стимул
  беречь защитников.
- **Arrow баллистика**. Решает задачу о броске низкой дугой: `tan(α) = (v² − √disc) / (g·d)`.
  gravity=6, lifetime=4с. Если цель вне досягаемости — фоллбэк на прямой выстрел.
- **Camp.current_center()** — реальный центр через среднее живых палаток. Узел Camp
  в caravan-mode статичен (двигаются только дочерние палатки) — раньше WaveDirector
  считал safe-радиус от (0,0,0) и волны спавнились в зоне огня.
- **Camp публичный API**: `reset_population / current_center / nearest_part_to /
  has_alive_parts / gatherer_count / defender_count / tent_count_alive`.
- **GameplayHud** (scenes/gameplay_hud.tscn): индикаторы способностей слева,
  статус лагеря справа (3-значные счётчики гномов/лучников/уровня=палаток).
- **Один Camp у Tower** в main.tscn вместо 6 POI-поселений. 6 POI убраны для
  упрощения теста (можно вернуть массивом — WaveDirector.camp_paths умеет).
- **Gnome._state теперь property с сеттером** — фронт-лог переходов автоматически.
  debug_log default=true.
- **Camera zoom_max 2.5 → 5.0** (двойной зумаут).

## Ключевые числа (актуальные)
- Skeleton: hp=30, vision_radius=12, vision_scan_interval=0.3, wander_speed=1.2
- Defender: attack_radius=22.5 (×1.5), patrol_radius=12, base_inaccuracy=1.5,
  exp_half=100, cooldown 1.0..2.0, damage 25..40
- Camp: deploy_radius=8 (×2), tent_count=4 (caravan), gnomes_per_tent=7,
  defenders_per_tent=3 — итого 12 защитников + 16 собирателей
- WaveDirector: initial=20, target=50, ramp=30с, replenish_threshold=20,
  replenish_interval=2с, wave_count=10, wave_interval=60с, wave_radius=4 (group),
  wave_safe_radius=35
- Arrow: speed=22, gravity=6 (дальность ~80м), lifetime=4с

## Решённые в эту сессию баги
- **PhysicsShapeQuery в Godot 4.6 подмешивает AABB-результаты вне sphere**.
  DefenderGnome видел цели на 50м+ при attack_radius=22.5. Фикс: explicit
  `if d > attack_radius: continue` после `intersect_shape`. Тот же фикс в
  OctagonTurret. Это паттерн на будущее — все sphere-query через physics
  должны иметь explicit radius-чек.
- **Camp.global_position не двигается при перемещении Tower** (узел Camp
  статичен, двигаются дети-палатки). Решение: `current_center()` через
  среднее живых палаток.

## Не доделано / отложено в эту сессию
- **Стрелы не втыкались в землю** (откатил по просьбе геймдизайнера). Основная
  проблема: body_entered Area3D с Ground (StaticBody3D) не триггерится
  корректно — стрелы пролетали сквозь Ground, одна улетела на y=−34.7м. Если
  возвращать механику воткнутых стрел — сначала разобраться почему.
- **Target-filter стрел** (стрелы попадали в первого встречного) откатили: было
  желание чтобы стрелы попадали только в назначенную цель, а через плотную
  группу пробивали мимо — но это меняло fundamental геймплей, отложили.
- **HUD-индикатор уровня защитника** (пока нет визуала ветеранов). Публичные
  API готовы: `DefenderGnome.get_shots_fired()`, `current_inaccuracy_radius()`.

## Состояние репозитория на 2026-04-28 (после 11 коммитов работы)
- Локальная `main` синхронизирована с `origin/main` (последний коммит `a77ae79`).
- За эту сессию сделано (хронологически):
  1. `c6597c5` fix: Camp реагирует на смерть Tower и синхронизирует _deployed_targets
  2. `57e71a9` fix: Gnome клампит wander-точки в границах карты
  3. `7081ca9` refactor: магические маски через Layers + Layers.MASK_HAND_SLAM
  4. `c0e759b` docs: SPEC.md под фактическое состояние EventBus, масок и FSM Camp
  5. `de9cc2c` perf: distance-based LOD для скелетов (NEAR/MID/FAR)
  6. `ef7465c` feat: PerfHud — FPS + счётчик скелетов с разбивкой по LOD
  7. `e19c58a` perf: cold-mode для FAR-скелетов — без коллизий и без move_and_slide
  8. `751bc4c` fix: рука и slam достают FAR-скелетов (Layers.COLD_ENEMY)
  9. `9644228` content: карта 200×200 → 400×400
  10. `709ec37` content: hex-layout с 12 POI-маркерами
  11. `69b9a7e` content: POI на всю карту, маркеры подросли
  12. `4538b29` content: jitter POI — менее ровная гексагональная фигура
  13. `7147dce` refactor: палатка — самостоятельная сцена; Camp.tent_count
  14. `727ae4a` refactor: gnomes_per_tent теперь параметр палатки, дефолт 7
  15. `27f4691` feat: статические поселения гномов на POI (start_deployed)
  16. `472a74c` feat: гномы-защитники — 3 лучника + 4 собирателя
  17. `22f84e3` feat: лучники-защитники патрулируют по периметру лагеря
  18. `11a5917` perf: DefenderGnome throttle target scan
  19. `5690bff` perf: LOD для гномов — cold-mode за 50м от камеры
  20. `f88042d` perf: balance batch (vision interval, arrow lifetime, cooldown, shadows)
  21. `a77ae79` chore: defender_gnome.gd.uid

## Что появилось архитектурно (главные новые сущности)
- **`Layers.COLD_ENEMY` (бит 8 = 128)** — FAR-LOD скелеты переключаются на этот слой. Маски руки/slam'а его включают (`MASK_HAND_TARGETS = 210`, `MASK_HAND_SLAM = 146`), а Skeleton/Tower/OctagonTurret — нет. Так broad-phase разгружается, но рука и slam продолжают доставать дальние стаи.
- **`MASK_FRIENDLY_PROJECTILE = 145`** (TERRAIN | ENEMIES | COLD_ENEMY) — стрелы ловят и горячих, и холодных скелетов.
- **3-уровневый LOD у Skeleton** (NEAR/MID/FAR). FAR — холодный режим: collision_layer=COLD_ENEMY, mask=0, move_and_slide пропускается, position += velocity. AI/vision throttled. Якорь дистанции — CameraRig (зум не влияет).
- **2-уровневый LOD у Gnome** (hot/cold). За 50м от CameraRig — cold: skip move_and_slide и гравитации. AI работает на полной частоте.
- **`Camp.start_deployed: bool`** — статический режим. Camp на _ready сразу разворачивается со своей global_position. R-toggle игнорируется. На карте 6 таких static-camps (поселений) на POI.
- **Палатка теперь отдельная сцена** (`scenes/tent.tscn` + `camp_part.gd`). Camp.tent_scene + tent_count экспорты. tent_count меняется в инспекторе любой Camp-инстанс.
- **`CampPart.gnomes_per_tent` + `CampPart.defenders_per_tent`** — палатка декларирует «во мне 7 жителей, 3 защитника». Camp читает.
- **`DefenderGnome extends Gnome`** — гном-защитник. Красный, патрулирует контур лагеря (radius=6, за палатками которые на 4), останавливается и стреляет при появлении скелета. PhysicsShapeQuery throttle 0.25с. Урон 25..40 (1-shot kill в 66%). Использует `arrow.tscn`.
- **Виртуальный hook `Gnome._active_tick(delta)`** — переопределяется подклассами. База — собиратель, DefenderGnome — combat. Structural скелет (LOD, gravity, knockback, move_and_slide) живёт в базе.
- **PerfHud (`scenes/perf_hud.tscn`)** — оверлей с FPS + Skeleton count + LOD-разбивка. F3 toggle. В main.tscn.

## Сцена main.tscn сейчас содержит
- Tower (центр (0,3,0)), CameraRig follow Tower, Hand
- EnemySpawner (скелеты, target=Tower)
- OctagonTurret1 (свободный модуль на (4,0.35,4) — можно подобрать рукой)
- 6 жёлтых POI-маркеров (без логики, для будущих локаций)
- 6 GnomeCamps (статические поселения, tent_count 2..4)
- PerfHud
- Ground 400×400, шейдер сетки
- НЕТ: Items (5 ящиков), Resources (20 куч), Camp у Tower — всё убрано в текущих экспериментах с layout'ом.

## Ключевые числа (после balance batch f88042d)
- Skeleton: hp=30, move_speed=2.7, vision_radius=12, vision_scan_interval=**0.3** (поднял с 0.15 — было 280k distance-checks/сек на группе 144)
- Skeleton LOD: near=25м, far=50м от CameraRig
- Defender: hp=20, attack_radius=15, cooldown **1.0..2.0** (поднял с 0.6/1.2), damage 25..40, patrol_radius=6, patrol_speed=1.0
- Gatherer Gnome: hp=20, search_radius=300, vision_radius=10
- Arrow: speed=22, lifetime **2.0** (срезал с 4.0), mask=145
- cast_shadow=0 на skeleton/gnome/defender_gnome/arrow (тени остались у статичных Tower/палатки/POI/турели)

## Архитектурный обзор (для быстрой ориентации)
- Godot 4.6.2, GDScript, перспективная камера 40°, pitch 55°.
- Autoloads: `EventBus`, `LogConfig`. Контракт-RefCounted'ы (`Damageable/Pushable/Grabbable/Layers/KnockbackState/ShatterEffect/VecUtil`) — не autoload, статический API через `class_name`.
- 7 коллизионных слоёв: Terrain/Items/Actors/Projectiles/Enemies/CampObstacle/MountedModule. Маски централизованы в `scripts/layers.gd`, но в `.tscn` хранятся числа (drift возможен).
- Главные системы: Hand (рука) → PhysicalActions (Slam/Flick) + SpellActions (заглушка); Camp (3-state FSM) + Gnome (6-state FSM); Tower (CharacterBody3D) + MountSlot + CampModule (OctagonTurret); Enemy → Skeleton; ResourcePile + EnemySpawner + Arrow.

## Ключевые расхождения SPEC ↔ Code (на 2026-04-27)
1. **`slam_mask = 18` литералом** в `hand_physical_slam.gd:42`, не через `Layers.MASK_HAND_TARGETS` (= 82).
   Slam НЕ попадает по mounted-модулям. Комментарий «Items + Enemies = 18» верен по факту, но рассогласован с именем `MASK_HAND_TARGETS`. Спека местами называет это расхождение «дискуссией» — финал не зафиксирован.
2. **`octagon_turret.gd:33`** — `target_mask = 16` литералом, не `Layers.ENEMIES`.
3. **`hand.gd:27`** — `cursor_raycast_mask = 67` литералом, хотя комментарий ссылается на `Layers.MASK_HAND_CURSOR`.
4. **EventBus имеет 4 сигнала, не упомянутых в SPEC**: `gnome_damaged/destroyed`, `camp_part_damaged/destroyed`. Спеку нужно дополнить.
5. **`ResourcePile` re-emit'ит на `item_damaged/destroyed`**, а не на отдельные `pile_*` сигналы — семантика смешивает Item и Pile (вопрос UI-фильтрации в будущем).

## Важные потенциальные баги (для следующего прохода)
- **`Camp._update_deployed`** (`camp.gd:343-348`): после смерти палатки `_parts.erase(part)` не синхронизирует `_deployed_targets` — индексы съезжают, оставшиеся палатки идут к чужим точкам. **Исправить.**
- **`Skeleton._physics_process`**: рескан таргета перед `super` может перевыбрать цель в середине WINDUP — визуал расходится с реальной атакой. **Решение:** замораживать кэш на время WINDUP/STRIKE.
- **`Camp` после `tower_destroyed`** не реагирует — караван продолжает follow'ить мёртвую башню. Нужна подписка на `EventBus.tower_destroyed`.
- **`Gnome._random_point_around` без clamp** в границы карты (`search_radius=300` при карте ±95). У Skeleton clamp есть.
- **`MountSlot.on_hand_released`** недетерминирован: при двух близких слотах — выигрывает порядок подписки. Нужен явный приоритет (например, ближайший по distance).
- **Идемпотентность `take_damage`**: Item/ResourcePile полагаются на `is_queued_for_deletion()` — есть микрооконце между `destroyed.emit` и `queue_free`, в котором повторный удар снова сэмитит destroyed. Привести к единому стилю с `_dying`-флагом.
- **`Tower.take_damage` без `queue_free`** — мёртвая башня остаётся стенкой; следствие — баги Camp, OctagonTurret.

## Code smells (низкий приоритет)
- `enemy_spawner.gd:88` — `enemy.set_target(_target)` для Skeleton мёртвый код (Skeleton override'ит `get_active_target`).
- `Arrow.hit` сигнал (`arrow.gd:12`) никем не подписан.
- `HandSpell` — заглушка, 3 TODO (`hand_spell.gd:23, 32, 33`).
- `HandPhysicalActions.AbilityType.NONE = -1` — определён, но никогда не присваивается.
- `find_flick_target` дублирует `_find_closest_grabbable` (`hand_physical.gd:142-152`) — близкая копипаста.
- Магические значения в `.tscn` (collision_mask = 18/55/82) — не выводятся из `Layers`, при перепорядке слоёв ломаются.

## Принципы работы по проекту (выведены из истории и SPEC)
- **Сцена + скрипт = пакет.** Каждая сущность самодостаточна. Сцены не содержат скриптов из чужих папок; скрипты не делают `preload` чужих сцен (исключение: рантайм-спавн).
- **`main.tscn` — только композиция.** Логики там быть не должно.
- **Cross-cutting через RefCounted-контракты**, не через `is Item`/`is Enemy`. После рефакторинга `c33a9d3` в коде не должно быть классовых веток для урона/толчка/захвата.
- **EventBus — дополнительный канал, не замена** локальным сигналам. Re-emit подключается в `_ready` сущности один раз.
- **Логи**: `if debug_log and LogConfig.master_enabled:`. На `printerr` не распространяется.
- **`super._ready()` обязателен** в подклассах Enemy (там регистрации Damageable/Pushable + assert'ы).
- **Frame-independent decay**: `target + (current - target) * exp(-decay * delta)`, не `lerp(a, b, follow_speed * delta)`.

## Полезные приёмы из работы с этим проектом (приобретённые навыки)
- **Параллельный аудит большим SPEC + код** — делегировать двум агентам параллельно (один читает SPEC.md по частям, второй читает все .gd/.tscn). Объединять выходы у себя — сравнение строится сразу. Выгоднее, чем читать SPEC самому при 168 KB.
- **Сравнение SPEC vs Code через "противоречия в SPEC"** — спека местами противоречит сама себе (MASK_HAND_TARGETS = 18 vs 82 в разных абзацах). Перед тем как чинить код, надо определить финальное намерение через git log + коммит-сообщения.
- **Static shared materials через `_ensure_shared_materials()`** на уровне класса — пакетная оптимизация для многократно спавнящихся сущностей (см. `skeleton.gd`). Ставит шаблон для будущих Enemy-подклассов.
- **Knockback compose**: `KnockbackState.compose(current_v, impulse)` с x/z replace + y max — корректно сочетает падение с горизонтальным импульсом.
- **Self-knockback без `_on_knockback`-хука** через `_apply_velocity_change` — иначе скелет отменяет свой же strike. Урок: разделять «внешний толчок» и «собственный импульс».
- **Pre-slide velocity** для bounce/neighbor-push: запоминать `pre_slide_velocity := velocity` ДО `move_and_slide`. После `move_and_slide` velocity уже изменена коллизиями.
- **Polling vs edge-events для grab**: `Input.is_action_pressed` + сравнение фронта — спасает от залипаний после lock'а руки во Flick.
- **`@onready` + `@export_node_path`** для слабо-связанных ссылок (Camp.target_path, EnemySpawner.target_path/spawn_root_path).
- **`RefCounted` + `class_name` + статический API** как альтернатива autoload-у — нет глобального состояния, но единая точка для контракта.

## Перфоманс-приёмы (наработано в сессии 2026-04-28 на стресс-тестах 290..1400 скелетов)
- **Distance-based LOD с CameraRig-якорем, не Camera3D-якорем.** Зум камеры меняет позицию Camera3D (через `_base_offset × _zoom`), но не CameraRig. Если меришь от Camera3D — зум двигает все границы LOD. От CameraRig (через `camera.get_parent()`) — стабильно.
- **Cold-mode для дальних NPC.** При FAR-LOD: переключить collision_layer на специальный (например, COLD_ENEMY), mask=0, и в `_physics_process` пропускать `move_and_slide` + gravity, делая `global_position += velocity * delta`. Главный win на 1000+ тел — broad-phase их не видит, slide-resolve не вызывается. Сохраняй: knockback tick (иначе self-impulse зависнет), state-таймеры (cooldown).
- **Отдельный physics layer для cold-агентов** — иначе рука/snipingпроекции их не достанут. У нас `Layers.COLD_ENEMY` включён в `MASK_HAND_TARGETS / MASK_HAND_SLAM / MASK_FRIENDLY_PROJECTILE`, но НЕ в `MASK_SKELETON` / `Tower.mask` / `target_mask` турели. Так broad-phase их игнорирует, а игрок и стрелы — попадают.
- **Кэш + throttle для PhysicsShapeQuery.** На 54 защитниках без throttle было 3240 query/сек = 3 fps. С интервалом 0.25с + кэш-validity (валидна ли цель + в радиусе) → 216 query/сек.
- **Фазовая рандомизация таймеров** (`_lod_check_timer = randf() * lod_check_interval` в `_ready`) — чтобы N сущностей не пересчитывали в одном кадре. Иначе кадровая нагрузка идёт волной каждые 0.25-0.5с.
- **Виртуальный `_active_tick(delta)` в базе** — подклассы переопределяют только AI-логику, structural скелет (LOD, gravity, knockback, move_and_slide vs cold-mode) живёт в базе один раз. См. `Gnome._active_tick` ↔ `DefenderGnome._active_tick`.
- **`cast_shadow = 0` на массовых мешах.** Тени от 400+ мелких сущностей — отдельный shadow pass. У статичных (палатки, башня, маркеры) — оставлять, у движущихся (скелеты, гномы, стрелы) — отключать.
- **Lifetime короче, fire rate медленнее** — балансовый win против spawn-spam'а. Стрел в воздухе = fire_rate × lifetime; уменьшение обеих переменных даёт квадратичный буст. Но не за счёт ощутимости боя.

## Принципы декомпозиции (выведенные в этой сессии)
- **Сцена + скрипт = пакет (повторение).** Палатка раньше была инлайн в Camp — переделана в `tent.tscn`. То же делать для всех «массовых» элементов когда они становятся сущностями со своими параметрами.
- **Параметры вместимости — на самой сущности.** `gnomes_per_tent` / `defenders_per_tent` живут на CampPart, не на Camp. Это позволяет иметь разные типы палаток (командная, жилая, склад) с разной заселённостью без правки координатора.
- **Двухрежимные сущности через bool-флаг.** `Camp.start_deployed` — переключает между mobile (caravan + R-toggle) и static (поселение на POI). Один класс, два режима. Пересовместимо с принципом «mainly composition».
- **Композиция гномов из ролей.** Camp читает декларацию палатки (`gnomes_per_tent`, `defenders_per_tent`), сам инстанцирует нужные сцены через `gnome_scene` + `defender_scene`. Палатка не знает про сцены, Camp не знает про конкретные роли — оба знают что хотят.

## Открытые направления на следующие сессии
- **MultiMesh для рендера скелетов/гномов** — главный оставшийся buster. 470 MeshInstance3D = 470 draw calls (минус culling). Через MultiMeshInstance3D — 1-2 группы. Сложность: windup-glow скелета сейчас через смену material_override; с MultiMesh это переделывается на per-instance color.
- **EnemySpawner cap** — сейчас можно нажать P 10 раз и получить 5000 скелетов. Прикрутить `max_alive` чтобы новые spawn'ы игнорировались при overshoot.
- **Магия (HandSpell)** — заглушка с 3 TODO в `hand_spell.gd`. Концептуально хочется чтобы рука кастовала фаерболы / щиты / т.п.
- **Tower не делает queue_free на смерть** — мёртвая башня остаётся стенкой. Camp реагирует через tower_destroyed (обнуляет _tower), но Hand и OctagonTurret продолжают работать с мёртвым телом. Нужна ревизия.
- **MountSlot.on_hand_released недетерминирован** при двух близких слотах. Приоритет по distance.
- **Идемпотентность `take_damage`** — Item/ResourcePile через `is_queued_for_deletion()`, остальные через `_dying`. Унифицировать.
- **Spatial partitioning для skeleton_target** — на 144 целях × 290 скелетов distance-check всё ещё O(N×M). Bucket-grid 50×50м снимет это к O(local).
- **Tents разных типов** — раз `gnomes_per_tent` уже на CampPart, естественно сделать `tent_command.tscn` (1 командир) / `tent_living.tscn` (7 жителей) / `tent_storage.tscn` (0 жителей, но больше hp). Camp принимает любую `tent_scene` с CampPart-скриптом.
