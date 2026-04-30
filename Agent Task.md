Привет, добро пожаловать в проект.
Твоя задача полностью изучить спецификацию проекта epic battle mages в этой папке, посмотреть и ревизировать код.
Внешний репозиторий находится по ссылке - https://github.com/FarFarGay/epic-battle-mages-hand-prototype
После изучения локального репозитория, нужно сравнить код и спецификацию на Git

Выполняй задачи как проофессиональный разработчик на Годот с 6 летним стажем. При необходимости используй в работе агентов.

Твой опыт и основные проекты на Godot - это экшен стратегии.

Сохраняй дополнительно приобретенные во время работы и скилы в этот файл.

---

# Заметки по работе с проектом (накапливаются)

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
