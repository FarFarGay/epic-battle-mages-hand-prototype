Привет, добро пожаловать в проект.
Твоя задача полностью изучить спецификацию проекта epic battle mages в этой папке, посмотреть и ревизировать код.
Внешний репозиторий находится по ссылке - https://github.com/FarFarGay/epic-battle-mages-hand-prototype
После изучения локального репозитория, нужно сравнить код и спецификацию на Git

Выполняй задачи как проофессиональный разработчик на Годот с 6 летним стажем. При необходимости используй в работе агентов.

Твой опыт и основные проекты на Godot - это экшен стратегии.

Сохраняй дополнительно приобретенные во время работы и скилы в этот файл.

---

# Заметки по работе с проектом (накапливаются)

## Сессия 2026-05-10 (3) — Супер-удар: ковровая бомбардировка через QTE-паттерн

### Контекст / запрос
Геймдизайнер: «супер-удар через QTE. Шкала «великой силы» копится за damage по врагам, под маной башни. На full → Space → время замедляется → паттерн из точек → ПКМ-drag нитью по ним → если прошёл, ПКМ ставит в точку каст. Эффект — дождь фаерболов в области».

### Главные изменения
- **`Camp` — шкала «великой силы»** (`_super_charge`, `super_charge_max=100`). Подписка `EventBus.enemy_damaged` → `add_super_charge(amount)` (1 hp damage = 1 charge). API: `is_super_ready / get_super_charge / get_super_charge_max / consume_super_charge`. `super_charge_fail_penalty=0.5` — половинное списание при провале QTE.
- **`EventBus`** — три новых сигнала: `super_charge_changed(value, max)`, `super_cast_started`, `super_cast_finished(success: bool)`.
- **`gameplay_hud`** — третий бар в tower-stats panel (золотой, ниже HP/MP). На `super_charge >= max` лейбл переключается на «ГОТОВО (Space)» жёлтым.
- **`Hand.Category`** — добавлен `SUPER`. `hand_physical._handle_input` и `hand_spell._handle_input` начинаются с `if active_category == SUPER: return` — весь физический и магический ввод заглушается на время каста (включая equip 1/2/3/4).
- **`HandSuper` координатор** (`scripts/hand_super.gd`) — child node `SuperActions` под Hand. State machine: `READY → AIMING_PATTERN → AIMING_TARGET → CASTING → READY`.
  - `READY`: слушает `cast_super` (Space). Гейтит на `Camp.is_super_ready() && !Hand.is_holding()`.
  - `AIMING_PATTERN`: `Engine.time_scale = 0.15`, спавнит `SuperPatternOverlay`. Ждёт `pattern_finished(success)`.
  - `AIMING_TARGET`: `time_scale=1`, ПКМ → `_commit_rain` (полное списание шкалы, спавн серии). Space → бесплатная отмена (шкала full сохраняется).
  - `CASTING`: серия из 12 шотов с `rain_shot_interval=0.18`, спавнит fireball'ы из target+UP×30 + horizontal jitter, баллистика «вертикально вниз с быстрым разгоном».
- **`SuperPatternOverlay`** (`scripts/super_pattern_overlay.gd` + `scenes/super_pattern_overlay.tscn`) — Control с custom `_draw`. Сетка 3×3 точек, `pattern_length=4` отмечены как путь. ПКМ-зажат → drag-нить через ожидаемую последовательность. Snap-radius 35px на 280px-extent grid. Тайм-аут 8с реальных секунд (под slow-mo ≈ 53с игрового времени), отслеживается через `get_process_delta_time() / Engine.time_scale`. Custom drawing: фейд-фон, точки (зелёные пройденные / золотая текущая / светлые впереди / dim не-в-sequence), нить между пройденными точками, прогресс-бар тайм-аута снизу.
- **`hand.tscn`** — добавлен `SuperActions` node со скриптом и `pattern_overlay_scene` ExtResource'ом. `Hand.gd` получил `@onready var super_actions: HandSuper = $SuperActions` и `super_actions.setup(self)` в `_ready`.
- **`project.godot`** — input action `cast_super` на keycode 32 (Space).

### Главное архитектурно
- **SUPER — третья ось ввода, не часть HandSpell.** Equipped-слот HandSpell держит Fireball/Firestorm; делать Super четвёртым equipped-вариантом значило бы переключение через клавишу + одинаковая ПКМ-семантика. Вместо этого SUPER — отдельный координатор, перехватывает контроль на время каста через `Hand.set_active_category(SUPER)` и возвращает в `_pre_super_category` на завершении. `hand_physical` и `hand_spell` гасятся ранним return на `active_category == SUPER`.
- **Time scale через `Engine.time_scale`** замораживает физику + AI + всё `_process(delta)` пропорционально, но **CanvasLayer ноды вне scale**. Overlay получает `get_process_delta_time()` уменьшенный на time_scale; делим обратно на `Engine.time_scale` чтобы тайм-аут жил в реальных секундах независимо от slow-mo. `process_mode = PROCESS_MODE_ALWAYS` на CanvasLayer и Overlay — на случай будущей паузы.
- **Шкала «великой силы» как Camp-state, не Tower**. Concept: «отрядное достижение», как `_squad_xp` (тоже на Camp). Накопление через EventBus.enemy_damaged покрывает любой источник damage'а (рука, магия, защитники, башня). 1 hp damage = 1 charge — простая прозрачная формула, легко понять «убил скелета (30 hp) — 30%». Параметр `super_charge_max` через @export, прокачка через SpellSystem отложена до отдельного коммита.
- **Pattern overlay рисуется через `_draw()`, не через child Control'ы**. 9 точек — это просто массив локальных Vector2, layout считается в `_grid_pos(idx)` каждый redraw. Нет лишнего scene tree, нет per-dot signal'ов. Custom drawing получился ~50 строк, Control'ы дали бы ~200 строк ради тех же circle+line.
- **AIMING_TARGET — отдельная фаза от AIMING_PATTERN**. Альтернатива «прошёл паттерн → сразу каст в зафиксированную точку» хуже UX'но: игрок успевает подумать, точка может оказаться не там где целились. С AIMING_TARGET игрок видит руку в реальном времени и кастит ПКМ когда удобно. Также Space в этой фазе — бесплатная отмена (страховка: «передумал, не хочу тратить полную шкалу»).
- **Per-target иммунитет в rain** не нужен дополнительно — каждый шот это отдельный Fireball._explode, наследует фикс `affected_set` из предыдущей сессии. Между шотами разные взрывы, повторное попадание в одну цель = разный ивент, ОК.

### Что не сделано / отложено
- **Звук** супер-каста (whoosh time slow, low rumble, fireball impacts × 12). Вся аудио-система ещё не построена.
- **Прокачка** через SpellSystem — место под `&"super"` id с levels (pattern_length, shot_count, rain_radius) есть, но catalog-entry не написан. Делается отдельным коммитом когда придёт время.
- **Visual replenish** шкалы — сейчас просто bar в HUD'е. Хотелось бы pulsing-glow когда full, и +N popup как у XP. Можно добавить в SquadXpFx-стиле подписку на EventBus.super_charge_changed.
- **Кулдаун** между кастами — сейчас нет. Естественный кд = время накопления шкалы (3-4 убитых скелета). Если окажется что игроки спамят (после прокачки damage'а быстрее копят) — добавить min_cooldown между super_cast_finished и следующим start.
- **Drop-on-super-start** удерживаемого предмета — сейчас просто блокируется (не кастуется если is_holding). Можно добавить «игрок ронит предмет автоматически на каст», но это поведение требует обсуждения.
- **Удерживаемая ЛКМ при переходе в SUPER** не сбрасывается через `_on_hand_category_changed` — _is_grabbing остаётся true в hand_physical._physics_process. На практике редкий edge-case (игрок держит граб + жмёт Space с full шкалой); _try_start_cast уже гейтит на is_holding. Если проявится — добавить `if new_category == SUPER: _is_grabbing = false` в hand_physical handler.

### Урок про class_cache (важно для будущих сессий)
**После создания нового файла с `class_name X`** — `--check-only` выдаёт «Could not find type X», даже если файл компилится. Нужно **сначала** прогнать Godot в editor-mode чтобы он зарегистрировал глобальные классы:
```
"D:\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" --headless --quit-after 1 --path "D:/<project>" --editor
```
Затем уже обычный `--check-only --quit` будет видеть новые class_name'ы. Это касается и любых grep'ов «как делает type-check проект» — после нового class_name прогонять editor-проход.

## Сессия 2026-05-10 (2) — Код-ревью и багфиксы

### Контекст
Геймдизайнер запросил «хорошее код-ревью с последующим багфиксом». Запустил три параллельных Explore-агента (магия+прокачка / архитектура+broad-phase / HUD+UI), кросс-верифицировал находки grep'ом и spot-чтениями (часть была ложноположительной). Реальных проблем оказалось 6, починил все. Парс-чек `--check-only` чистый.

### Найденные и пофикшенные баги

1. **Mana и cooldown списывались ДО валидации `instantiate()`** в `hand_spell_fireball.gd:_perform_cast`. Если `fireball_scene` повреждена и `instantiate()` возвращает null — игрок терял ману и попадал на кд. Фикс: сначала `instantiate()`, при провале — early return; mana и `_cooldown_remaining` устанавливаются после успешного инстанцирования. На провале mana уже после spend'а снаряд `queue_free`'ится. В Firestorm порядок не критичен (instantiate в `_launch_one`, scene валидируется на старте серии в `_start_volley`).

2. **Двойной хит AOE: broad-phase + FAR-fallback** в `Fireball._explode` и `BurnPatch._apply_tick`. Цель, попавшая в `intersect_shape` И в FAR-fallback по группе, получала damage дважды. На практике редко (FAR обычно с `monitoring=false`), но код хрупкий. Фикс: `var affected_set: Array[Node]` после первого прохода, FAR-цикл скипает уже задетых (`if skel in affected_set: continue`). Тот же паттерн в обоих местах.

3. **`is X` нарушения архитектурного правила «cross-cutting через контракты, не типы»** — 6 точек:
   - `hand_spell_fireball.gd:183` и `hand_spell_firestorm.gd:160`: `tower is Tower` → `tower.has_method(&"try_consume_mana")`. Контракт «мана-провайдера» через duck-typing.
   - `skeleton.gd:871` (`is Gnome` для приоритета цели), `defender_gnome.gd:793` (`is Gnome` для фильтра «наш гном»), `xp_orb.gd:170` (`is Gnome` для резолва camp'а): добавил **`Gnome.GNOME_GROUP := &"gnome"`**, регистрация в `Gnome._ready` (наследуется DefenderGnome'ом). Все три места перешли на `is_in_group(Gnome.GNOME_GROUP)`.
   - `skeleton.gd:923` (`is CampPart or (is Gnome and not is DefenderGnome)` для alarm-фильтра): теперь `active.is_in_group(TARGET_GROUP) and not active.is_in_group(DefenderGnome.DEFENDER_GROUP)`. TARGET_GROUP включает палатки в строю + всех гномов; DEFENDER_GROUP — только Defender'ов; разница = «alarm-victim'ы».
   - `tower.gd:177, 284` (`is Item`) **оставил**: это локальная type-specialization для RigidBody-mediated push (Tower знает Item.mass/freeze/apply_central_impulse), а не cross-cutting через систему. Пара симметрична `Pushable.is_pushable + is CharacterBody3D` для kinematic-ветки.

4. **Дребезг кнопок прокачки в журнале** — повторный клик до перерисовки UI мог дважды списать ресурс. Добавил helper `_wire_action_button(btn, callback)`: lambda на `pressed`, в которой первым же шагом `btn.disabled = true`, потом callback. Применил к 4 кнопкам: unit-upgrade, build, spell-unlock, spell-upgrade. Plan-preset (`set_collection_priority`) не требует — идемпотентен.

5. **Отсутствие `is_instance_valid` для collider'ов в AOE-callback'ах**. Между `intersect_shape` и `_apply_aoe`/`Damageable.try_damage` цель могла умереть. Добавил guard'ы в `Fireball._explode` (перед обращением к `(collider as Node3D).global_position`) и `Fireball._apply_aoe`, и в `BurnPatch._apply_tick`.

6. **Orphan Camp reference в HUD** — `gameplay_hud.gd` в трёх местах (`_ready` x2 и `_refresh_squad_bar`, `_sync_all_resources`) проверял только `_camp != null`, но не валидность инстанса. Если Camp queue_free'нулся, EventBus-коллбек всё ещё мог прийти. Заменил на `is_instance_valid(_camp)` везде.

### Что не было настоящим багом (отфильтрованные FP агентов)
- «Race condition в Firestorm при смене категории во время серии» — tick'и идут на оба подмодуля всегда (`hand_spell.gd:60-61`), серия завершается корректно по зафиксированному `_volley_target`.
- «Утечка ссылки `_hand`» — теоретическая, `_hand` живёт со сценой.
- «`queue_free` vs `free` для UI clear» в JournalPanel — текущая реализация работает, race не воспроизводится.
- «Двойные `connect` в `_ready` autoload'ов» — `_ready` autoload'а вызывается один раз.
- «`LogConfig` без null-fallback» — autoload, всегда есть.
- «`AoeVisual.spawn_wave` утечки» — уже корректно проверяет `is_instance_valid(mesh)` в callback'е tween'а.

### Архитектурно
- **GNOME_GROUP** — новый постоянный контракт «это гном» (мирный или защитник). Не путается со state-driven SKELETON_TARGET_GROUP (приходит/уходит при IN_TENT/SEARCHING). Использовать когда нужен «вообще гном».
- **Helper для UI-кнопок** `_wire_action_button` — паттерн для всех будущих кнопок что списывают ресурс или меняют state. Дребезг покрыт автоматически: lambda не пускает повторный клик до `_refresh()` пересоздаст карточку.
- **Per-target иммунитет в одном AOE** через `affected_set: Array[Node]` — паттерн для любого сочетания broad-phase + group-fallback. В новых заклинаниях AOE копировать.
- **Mana-spend порядок**: «сначала instantiate, потом списываем» — общий принцип для будущих заклинаний (одиночных). Для серий (Firestorm) проверка scene в `_start_volley` достаточна, mana списывается до launch'ей.

### Метод
- Для подобного ревью эффективно: 3 параллельных Explore-агента по разным осям (gameplay / архитектура / UI) + кросс-верификация grep'ом для отсева FP. Агенты дали ~14 находок, реальных оказалось 6.
- `Godot --headless --check-only --quit --path <project>` — быстрый парс-чек после серии правок (исполняемый в `D:\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe` — да, exe лежит внутри одноимённой папки).

## Сессия 2026-05-10 — Финал магии: шквал, прокачка, страницы, баланс, SPEC

### Контекст
Продолжение сессии магии. Добавил Огненный шквал, систему прокачки заклинаний за страницы (новый ResourceType.PAGE), вкладку «Заклинания» в журнал, balance-tuning (radius, drift, mana, скорость), визуал взрыва без шейдеров (3 GPUParticles3D-слоя), фикс horizontal-only distance в AOE. Обновил SPEC.md под новое состояние, коммит и push.

### Главные изменения
- **`SpellSystem` autoload** (`scripts/spell_system.gd`): каталог `SPELL_CATALOG` (Dictionary id → name/description/levels[]/upgrade_costs[]), state `_unlocked`/`_levels`, API `is_unlocked / get_level / get_current_level_data / can_upgrade_further / try_unlock / try_upgrade`. Списание через `Camp.try_spend()`. Сигналы `EventBus.spell_unlocked` / `spell_upgraded`.
- **`ResourcePile.ResourceType.PAGE`** — пятый тип, фиолетовый. Чит «+100 каждого ресурса» теперь даёт и страницы.
- **`HandSpellFirestorm`** (`scripts/hand_spell_firestorm.gd`): state-machine серии, фиксирует параметры на press'е, списывает mana один раз. Реюзает fireball.tscn. Каждый шот таргетит точку в `scatter_radius` через uniform-по-площади jitter.
- **Журнал → вкладка «Заклинания»** (`Tab.SPELLS`): generic карточки на каждое заклинание из каталога. Locked → unlock_cost + кнопка «открыть»; Unlocked + ↑ → upgrade_cost + кнопка «улучшить»; Max → disabled. Stats формируются автоматически из level-data.
- **`HandSpell` координатор**: enum `SpellType { FIREBALL, FIRESTORM }`, action `equip_firestorm` (4), диспатч в `_dispatch_cast`.
- **Visual взрыва — `AoeVisual.spawn_explosion`** (`scripts/aoe_visual.gd`): ядро-вспышка sphere unshaded (tween scale 0→radius×0.7→0) + GPUParticles3D-fire (60шт, 0.5с) + GPUParticles3D-smoke (40шт, 1.2с, up bias). Полностью процедурно, без внешних ассетов. Slam ещё на старом visual'е (с пулом) — оставил.
- **Balance fixes**:
  - Fireball/Firestorm radius существенно увеличен (были 3.0/1.5, стали 4.5/2.5 базовых, дальше прокачкой) — раньше «рядом со скелетом не попадало».
  - **Horizontal-only distance check** в `Fireball._explode` и `BurnPatch._apply_tick`: 3D distance отъедал ~0.9м эффективного radius'а из-за высоты капсулы скелета.
  - Firestorm @export `burn_radius` 0.8 → 2.0 (был критичный bug — burn-зона шквала не задевала никого).
  - Дрейф фаербола усилен: `boost_drift_velocity` 1.5→2.8, `homing_drift_angle_deg` 28°→45°, `homing_turn_rate` 5.0→3.5 (длиннее «крюк»).
  - **Fireball ≡ одиночный shot Firestorm'а** (дизайнерское: «фаербол это одиночный шквал»). damage=15, radius=2.5, mana_cost=12. DPS Fireball ≈ 37 ровно, Firestorm ≈ 30 со взрывом 60 в пик.
- **Tower mana/health** — в HUD добавлены HP/MP полоски сверху по центру через `_build_tower_stats` программно. Сигналы `tower_health_changed` / `tower_mana_changed` через EventBus. `try_consume_mana` атомарно.

### Главное архитектурно
- **SpellSystem — single source of truth** для balance-параметров заклинаний. Подмодули руки (HandSpellFireball/Firestorm) читают через `get_current_level_data(id)` с fallback на @export'ы. Прокачка → следующие касты с новыми числами. Серии (Firestorm) фиксируют параметры на press'е чтобы избежать mid-volley-смены-балансов.
- **Добавление нового заклинания** — 5 шагов: (1) запись в `SPELL_CATALOG`, (2) `HandSpellXxx`-подмодуль (или реюз снаряда), (3) узел в `hand.tscn` под `SpellActions`, (4) `equip_xxx` action в project.godot, (5) enum + диспатч в HandSpell. Прокачка/мана/UI бесплатно через каталог.
- **AoeVisual helper** — единый VFX-язык для AOE-эффектов руки и магии. Slam пока на собственной (с пулом) реализации, но шаблон готов: при будущем refactor'е переедет на helper.
- **Horizontal-only distance** для AOE на ground'е. AOE-зоны (Slam, Fireball-explode, BurnPatch) — это «пятна» на земле, distance к target'у нужен horizontal. 3D distance был unintentional «съедатель радиуса» из-за высоты капсулы. Применил везде.

### Что отложено
- **PAGE на карте**: дроп с врагов / награда за квесты — пока страниц нет в спавне, насыпаются только читом. Дизайнер решает позже.
- **Slam на AoeVisual.spawn_wave/dust** — refactor отложен. Slam с пулом MeshInstance3D работает, не трогаем.
- **`&"meteor"` заглушка** в каталоге — locked, 15 страниц. Дизайнер заполнит levels когда придёт время.
- **HUD-индикатор activity active spell** — какое заклинание сейчас в руке. `Hand.active_category` + `HandSpell.equipped` публичны, gameplay_hud подцепит.

## Сессия 2026-05-09 (5) — Магия: фаербол + категория ввода Hand

### Контекст / запрос геймдизайнера
HandSpell был заглушкой с TODO. Дизайнер: «теперь магические действия —
фаербол. Выбрал, ПКМ, шар вылетает из башни по дуге, перед падением
ускоряется, врезается в землю — урон по области».

### Главные изменения
- **`hand.gd`**: добавлен `enum Category { PHYSICAL, MAGIC }` и публичный
  setter `set_active_category(category)` + сигнал `category_changed`.
  Active category — кто из подмодулей реагирует на ЛКМ/ПКМ. Equip-биндинги
  (1/2 — physical, 3 — magic) обрабатываются всегда и переключают
  category. Остальной ввод гейтится по `active_category`.
- **`hand_physical.gd`**:
  - Equip 1/2 теперь дополнительно ставят `Hand.Category.PHYSICAL`.
  - `_handle_input`: ранний return если `active_category != PHYSICAL`
    (после обработки equip-биндингов).
  - `_physics_process`: тоже ранний return (страховка для magnet/grab).
  - `_update_candidate_highlight`: в MAGIC не подсвечивает кандидата.
  - Подписка на `_hand.category_changed`: при уходе из PHYSICAL с
    предметом в руке — принудительный `_release()`.
- **`hand_spell.gd`** переписан в полноценный координатор по образцу
  `hand_physical.gd`:
  - `enum SpellType { FIREBALL }`.
  - Action `equip_fireball` (3) ставит category = MAGIC.
  - В MAGIC ПКМ диспатчит каст на активный подмодуль.
  - Подмодуль `Fireball` (HandSpellFireball) — children в hand.tscn.
- **`hand_spell_fireball.gd`** — новый: cooldown, on_press → spawn fireball
  с расчётом параметров дуги. Launch — Tower (через `Tower.GROUP`),
  fallback Hand. Target — `Hand.cursor_world_position()` минус
  `hand_height` (поверхность земли под курсором, а не плоскость руки).
- **`fireball.gd`** + **`fireball.tscn`** — снаряд: Node3D + MeshInstance3D
  (sphere с emission) + OmniLight3D. Симуляция баллистики вручную в
  `_physics_process` (без RigidBody — не нужны контакт-driven коллизии,
  только AOE-shape-query на взрыве). После apex (vy<0) применяется
  `g_dive` > `g_up` — визуально «ускоряется перед падением». При
  достижении target.y или proximity — `_explode()`: AOE по `MASK_HAND_SLAM`
  с per-target иммунитетом + FAR-fallback по `Skeleton.SKELETON_GROUP`
  (паттерн скопирован из `HandPhysicalSlam._perform_slam`).
- **`tower.gd`**: добавлена `const GROUP := &"tower"` + `add_to_group(GROUP)`
  в `_ready` — для discovery без NodePath.
- **`project.godot`**: action `equip_fireball` (keycode 51 = клавиша 3).
- **`hand.tscn`**: добавлен `Fireball` под `SpellActions`, привязана
  `fireball_scene` через ExtResource.

### Главное архитектурно
- **Категория — централизованное состояние Hand**, не state-машина в
  каждом подмодуле. `Hand.active_category` единая точка истины: гейтят
  оба координатора, equip-биндинги пишут. Альтернатива (флаг в каждом
  координаторе) рассинхронилась бы при двустороннем переключении.
- **Equip-биндинги слушаются всегда**, даже когда категория не «своя».
  Игрок жмёт 3 в момент когда сейчас PHYSICAL — hand_spell ловит
  `equip_fireball`, переключает category → MAGIC. Hand_physical
  `_handle_input` начинается с проверки `equip_slam`/`equip_flick`
  (тоже всегда) — и если игрок жмёт 1, переключение обратно работает
  даже из MAGIC.
- **Принудительный release при уходе из PHYSICAL**: если в руке висит
  ящик, переключение на магию его роняет. Иначе странный визуал:
  «магия с ящиком в руке».
- **Параметры дуги выводятся явно** (не подобраны). Дано
  `flight_time`, `peak_height_above_launch`, `ascent_fraction`, `target.y`,
  `launch.y`. Считаем `g_up = 2×peak_h/t_apex²`, `vy_initial = g_up×t_apex`,
  `g_dive = 2×(peak_h - dy)/t_descent²`. С дефолтами (1.6с, 6м, 0.55)
  получается `g_dive ≈ 2.25 × g_up` — заметное ускорение, но не
  телепорт. Дизайнер тюнит export'ы.
- **Снаряд — обычный Node3D, не RigidBody**. Не нужна broad-phase
  collision со скелетами в полёте — он бьёт только в AOE при взрыве.
  Симуляция в `_physics_process` явная: `velocity.y -= g × delta`,
  `position += velocity × delta`. Меньше physics-overhead на каждый
  снаряд, проще тюнинг (нет artefactов от RigidBody-интегратора).
- **AOE один в один как у Slam** — единый паттерн для рук-mode и
  магии: тот же `MASK_HAND_SLAM`, тот же иммунити-чек через
  `Layers.is_hand_immune`, тот же FAR-fallback. Это обещание спеки
  «магия унифицирована с физикой через MASK_HAND_SLAM».

### Дополнение — визуал взрыва (по запросу геймдизайнера)
Изначально `Fireball._explode` только наносил AOE и делал `queue_free` —
игрок не видел взрыва и не понимал габаритов. Геймдизайнер: «добавь
сферу взрыва, чтобы видеть габариты, и разлёт как у удара рукой по земле».

- **Новый helper `aoe_visual.gd`** (RefCounted, static methods) с тремя
  визуалами:
  - `spawn_wave(root, pos, radius, duration)` — distortion-сфера
    (`slam_distortion_material.tres`) расширяется до `radius` за 0.45с
    с затуханием intensity. Это «волна удара» — тот же визуал, что
    делает Slam.
  - `spawn_dust(root, pos)` — GPUParticles3D one_shot (`slam_dust_*`),
    радиальный разлёт пыли. Тот же что у Slam.
  - `spawn_radius_indicator(root, pos, radius, color, duration)` —
    solid translucent оранжевая сфера фиксированного размера = radius,
    fade-out за 0.4с. Чёткий «вижу габариты»-индикатор поверх волны.
- `Fireball._explode` зовёт все три на `get_parent()` (effects_root).
  Spawn'ятся ДО `queue_free()` снаряда — tween'ы привязаны к самим
  визуалам (parent-сцене), не к фаерболу, переживут его уход.
- Slam пока оставлен на собственной (с пулом) реализации — не ломаю
  работающее. Когда придёт время refactor'а, Slam перейдёт на тот же
  helper (нужно будет вернуть пул в helper для slam'а с cooldown=0.5с,
  иначе ~2 instance/сек × create_overhead).

**Урон/разлёт уже идентичен slam-паттерну** — `Pushable.try_push`
с `knockback_force=35` (slam=30), `knockback_lift=0.5` (slam=0.4),
`knockback_duration=0.4` (=slam). Если разлёт окажется слабее
визуально — геймдизайнер подкрутит экспорты в инспекторе.

### Что отложено
- **Огненная окраска dust** — сейчас Fireball использует тот же серый
  pyl, что и Slam (общий ресурс). Если потребуется — продублировать
  process+material под огненный градиент (оранжевый→красный→чёрный
  дым) и передать в `spawn_dust` как параметр.
- **Визуальный trail** за фаерболом в полёте — кометный хвост из
  GPUParticles3D. Сейчас только emission на mesh + OmniLight3D.
- **Звук**: каст, полёт, взрыв. Вся проектная аудиосистема ещё не
  построена (см. SPEC), фаербол подцепится когда появится.
- **Mana / cost / global cooldown** для магии. Сейчас только локальный
  `cooldown` (3.0с) на конкретное заклинание. Когда будет ресурс маны
  или общая система — добавится в HandSpell._dispatch_cast.
- **HUD-индикатор активной категории и заклинания**. Иконка магии
  слева на HUD, рядом с Slam/Flick. `Hand.active_category` уже
  публичный — gameplay_hud подцепит.
- **Несколько заклинаний**: щит, телепорт, луч и т.п. Каркас готов —
  add child под SpellActions, описать как HandSpellFireball, добавить
  enum-значение и кнопку equip.

## Сессия 2026-05-09 (4) — Capped speed для палаток в caravan-follow

### Контекст / запрос геймдизайнера
После halt-resume Tower может оказаться далеко (играл WASD пока караван
стоял). Палатки догоняли через `_exp_decay`, который даёт шаг ∝ дистанции —
визуально это «рывок-ускорение». Геймдизайнер: «пусть возвращается к башне
не ускоряясь».

### Главные изменения
- **`camp.gd`**: новый `@export var caravan_max_speed: float = 10.0` (м/с).
  Чуть выше Tower.move_speed=8.0 — палатка медленно догоняет, не
  телепортируется и не выглядит ускоряющейся.
- Новый static helper **`_exp_decay_capped(current, target, decay,
  max_speed, delta)`**: тот же exp-шаг, но длина шага клампится на
  `max_speed × delta`. На малых дистанциях (обычный follow в строю) cap
  неактивен — поведение идентично `_exp_decay`. На больших разрывах
  (после halt-resume, выкинутая палатка вне строя) шаг ограничен.
- **`_update_caravan_follow`** теперь зовёт `_exp_decay_capped` для палаток.
  `_update_deployed` оставлен на прежнем `_exp_decay` — там дистанция
  малая (палатка ↔ точка кольца), cap не нужен.

### Главное архитектурно
- **Гномы-followers (DefenderGnome) trogаt не пришлось**: они уже capped
  через lerp(`move_speed=1.6` → `caravan_sprint_speed=9.0`) по дистанции
  до своего slot'а. Без exp-шага вообще — `velocity = dir × speed` с
  капированной скоростью. Логика «не ускоряется» там уже была.
- **Гномы IN_TENT** копируют palatka.global_position каждый physics-кадр —
  получают скорость палатки автоматически. Если палатка теперь догоняет
  с cap 10 м/с, гномы в ней едут с тем же cap.
- **Cap > Tower.move_speed обязательно**, иначе палатки никогда не
  догонят свободно едущую башню. 10 м/с (≈+25% к Tower) — компромисс:
  заметно медленнее «телепорта» exp_decay при дистанции 30+м, но и не
  выглядит «ползание».
- **Проверка не-регрессии в обычной езде**: при part_gap=2.5м, follow_speed=4,
  кадр 1/60с → exp-step ≈ 0.16м, cap-step = 10×(1/60) ≈ 0.167м. Шаги
  почти равны → cap практически не активен в обычном follow, видимое
  поведение не меняется. Активируется только когда дистанция>>part_gap
  (после halt'а или free-placement).

## Сессия 2026-05-09 (3) — Halt-режим каравана на Q

### Контекст / запрос геймдизайнера
После освобождения клавиши Q — Q становится «остановить караван».
Семантика: Tower продолжает кататься по WASD, а караван (палатки+гномы)
встаёт на текущей точке, **но это НЕ deploy** — палатки остаются в колонне,
гномы не выходят из палаток, ничего не собирают. Повторное Q — снова
привязать к Tower, караван продолжает следовать.

### Главные изменения
- **`project.godot`**: новый action `caravan_halt_toggle` (keycode 81 = Q).
- **`camp.gd`**: добавлен `var _caravan_halted: bool = false` + публичные
  `is_caravan_halted()` / `set_caravan_halted(value)` (с idempotency и
  логированием перехода).
- **`_handle_halt_input()`** (edge-trigger на Q) подключён в `_process`
  рядом с `_handle_collection_input`. Только в `State.CARAVAN_FOLLOWING`
  и не для `start_deployed=true` static-camp'ов (поселения).
- **`_update_caravan_follow`**: ранний return при `_caravan_halted` — палатки
  замораживаются на текущих позициях.
- **`_handle_input`** в `CARAVAN_FOLLOWING` при halted сбрасывает `_deploy_hold`
  и return — R-deploy блокируется. Игрок должен сначала Q (resume), потом
  держать R на стационарной башне.
- **`_start_deploy`**: страховочно сбрасывает `_caravan_halted = false` —
  если каким-то образом deploy случится из halted (например через будущий
  программный API), флаг не должен «зависнуть».

### Главное архитектурно
- **Halted — это флаг внутри CARAVAN_FOLLOWING, не отдельный state**. Можно
  было сделать `State.HALTED`, но 90% логики идентично CARAVAN_FOLLOWING
  (гномы IN_TENT, палатки vulnerable, агро-таргет — Tower+палатки).
  Отличие — только early return в `_update_caravan_follow`. Флаг меньше
  поверхности изменений и не требует дублирования FSM-кода.
- **Гномов трогать не пришлось**. `IN_TENT` — `_physics_process` копирует
  `_home_tent.global_position` каждый кадр; палатка стоит → гном стоит.
  `FOLLOWING_CARAVAN` defender — `get_chain_target_for_follower` берёт
  leader_pos = последняя палатка; палатка стоит → defender приходит к
  своему slot'у за палаткой и затормаживает. Без правок.
- **Halt блокирует deploy** (R игнорируется). Семантика: «стоп» и «лагерь»
  это разные намерения, смешивать нельзя — иначе случайное удержание R
  на остановленном караване развернуло бы лагерь без явного wish'а.
  Если игрок хочет deploy на месте halt'а — Q (resume) → нажать R на
  стационарной башне (которая если не двигается, тут же даст stationary).
- **Tower полностью независим**. WASD у Tower продолжает работать. Halted —
  именно «отвязать» Camp от Tower-цели; Tower это не знает и не должен.

### Что отложено
- **HUD-индикатор «караван остановлен»**. `Camp.is_caravan_halted()` уже
  публичный — gameplay_hud может подцепить и нарисовать иконку. Не сделал,
  дизайнер не просил.
- **Сигнал `EventBus.camp_halted_changed(value: bool)`** — если кому-то ещё
  понадобится реагировать (звук, UI). Сейчас слушателей нет, не добавлял.
- **Авто-resume при определённых событиях** (например, скелет напал на
  палатку → халт автоматически снимается). Дизайнер не просил, не делал.
- **Halt в DEPLOYED** — сейчас игнорируется (палатки и так стоят). Если
  потребуется «freeze гномов в кольце» — отдельная фича.

## Сессия 2026-05-09 (2) — Вкладка «Задания» в Журнале + освобождение клавиши Q

### Контекст / запрос геймдизайнера
Q была занята debug-биндингом `complete_quest` (продвижение QuestProgress).
Дизайнер хочет освободить клавишу под реальный геймплей и заодно подготовить
**архитектуру** для постановки задач + их описания в журнале — сами квесты
пока не пишем, но журнал должен уметь их показывать когда появятся.

### Главные изменения
- **`quest_actor.gd`**: добавил два экспорта в новой группе `Journal` —
  `quest_title: String` и `quest_description: String` (multiline).
  Источник истины задания = тот же узел что и POI/костёр/wave_schedule
  (паттерн «сцена+скрипт=пакет»). Дизайнер заполняет в редакторе на каждом
  QuestActor когда квест готов; журнал автоматически подхватит.
- **`quest_progress.gd`**: убрал `_unhandled_input` (Q-биндинг). Добавил
  `enum State { LOCKED, ACTIVE, COMPLETED }` и `get_state(order) -> int` —
  одной функцией вместо трёх отдельных is_*-проверок (UI приятнее).
  Добавил `get_actors_sorted() -> Array` — собирает все QuestActor по
  группе `POI_GROUP`, сортирует по `quest_order`. Журнал использует.
- **`project.godot`**: удалил action `complete_quest` целиком.
- **`journal_panel.gd`**:
  - Tab enum расширен: `UNITS, CAMP, PLAN, QUESTS, DEBUG`. Кнопка-вкладка
    «Задания» между «План» и «Читы».
  - `_build_quests_tab()` — без аргументов (Camp не нужен). Опрашивает
    `QuestProgress.get_actors_sorted()`, рендерит карточку на каждый
    QuestActor по его `get_state()`:
    - LOCKED — заголовок «???», описание скрыто, серая «🔒 закрыто», dim 0.5.
    - ACTIVE — заголовок жёлтый, описание яркое, «▶ активно».
    - COMPLETED — заголовок зелёный, описание приглушено, «✓ выполнено», dim 0.75.
    Если на сцене нет QuestActor'ов — «Нет заданий на сцене».
    Если `quest_title`/`quest_description` пустые — fallback'и
    «Задание #N» / «(описание ещё не задано)».
  - В Tab.DEBUG — шестая кнопка «Продвинуть квест» (фоллбэк замены Q).
    Дёргает `QuestProgress.advance()`.
  - Подписка на `EventBus.quest_advanced` в `_ready` — реактивность,
    при продвижении квеста (откуда угодно) вкладка перерисуется.
  - `_refresh()`: QUESTS добавлена в `camp_optional` (как DEBUG) — работает
    без Camp на сцене.

### Главное архитектурно
- **Источник истины квестов = QuestActor на сцене**, не каталог в коде.
  Альтернатива (Dictionary в QuestProgress) была бы дублем: и в коде, и
  в .tscn у QuestActor'ов уже есть `quest_order` + `actor_id` + POI-параметры.
  Каталог в коде заставил бы ID-mapping через actor_id+order.
- **Каталог автоматический через группу**. Журнал не знает наперёд сколько
  QuestActor'ов на сцене — это масштабируется без правок UI: добавил
  QuestActor в .tscn, заполнил title/description в инспекторе — оно появилось
  в журнале на следующем open(). Тот же паттерн что у `_build_camp_tab`
  через `Camp.CAMP_BUILDING_CATALOG` — только источник внешний (узлы),
  а не внутренний (Dict).
- **Реактивность через EventBus.quest_advanced**, не polling. Подписка в
  `_ready`, перерисовка только если `_current_tab == QUESTS` (и журнал
  открыт — `_refresh()` уже это проверяет). На любое продвижение прогресса
  (программное, чит, будущий триггер) журнал отрабатывает без явных связей.
- **State-enum в QuestProgress**: вместо трёх предикатов в UI-коде
  (`is_completed/is_active/is_locked`) теперь один `get_state(order)` →
  enum — match-блок в UI читается линейно. Старые предикаты оставлены
  (используются в QuestActor._refresh_visual), не трогал.

### Что отложено
- **Триггеры завершения квеста** — пока сдача только через чит. Когда
  появятся реальные триггеры (диалог завершён, монстр убит, предмет
  принесён) — добавятся в `QuestActor` или внешних системах, дёргают
  `QuestProgress.advance()`. Каркас готов.
- **Награда за квест** — не делал. Когда появится: либо поле `quest_reward`
  на QuestActor (Dictionary ресурсов / squad-XP / unlock апгрейда), либо
  отдельный сигнал `EventBus.quest_completed(actor_id)` чтобы Camp/др.
  системы сами реагировали (Camp.add_resource / grant_upgrade).
- **SPEC.md упоминает Q как debug-вход** — обновить SPEC.md под новое
  состояние (Q свободна, продвижение через Журнал → Читы). Отдельный
  doc-коммит.
- **Иконка / индикатор «есть активный квест»** в HUD/кнопке журнала —
  бэйдж как у апгрейдов. Отложил до появления реальных квестов.

## Сессия 2026-05-09 — Унификация идемпотентности take_damage + ревизия known-bugs

### Контекст / запрос геймдизайнера
Короткая баг-фикс сессия. Прошёл по списку «известных багов» из memory
(Camp._update_deployed индексы, Skeleton рескан в WINDUP, Tower без queue_free,
slam_mask=18 литералом). **Все четыре уже починены в предыдущих сессиях** —
memory устарела, я её обновил. Из оставшегося code-smell-списка взял
«идемпотентность take_damage» — Item полагался на `is_queued_for_deletion()`,
остальные на `_dying`-флаг.

### Главные изменения
- **`item.gd`**: добавил `var _dying: bool = false`, `take_damage` теперь
  guard'ит на `_dying or amount <= 0.0` и выставляет `_dying = true` ДО
  `destroyed.emit()` + `queue_free()`. Закрывает микрооконце: между
  `destroyed.emit` и `queue_free` слушатель сигнала мог в одном кадре
  передёрнуть `take_damage(item)` — раньше второй раз сэмитил бы destroyed
  (потому что `is_queued_for_deletion()` ставится только на _следующем_ idle
  frame, не сразу при `queue_free()`), теперь — ранний return.
- **`resource_pile.gd`**: убрал дублирующий `is_queued_for_deletion()` из
  условий `take_damage` / `take_one` / `consume_all`. `_dying` уже надёжно
  закрывает идемпотентность (выставляется до `queue_free`), а `queue_free`
  извне на pile никто не делает (грепнул — единственное упоминание
  `pile.is_queued_for_deletion()` в `camp.gd:1131` это валидность извне, не
  внутреннее).

### Главное архитектурно
- **`is_queued_for_deletion()` — НЕ замена `_dying`**. Между `queue_free()`
  и `is_queued_for_deletion()=true` есть синхронное окно (queue_free
  планирует deletion на idle frame, флаг `is_queued_for_deletion` ставится
  ВМЕСТЕ с queue_free, но destroyed.emit зовётся ДО queue_free —
  значит между destroyed.emit и queue_free нет окна для re-entry. **НО**
  слушатель destroyed может в обработчике сделать что угодно, в том числе
  передёрнуть take_damage другого объекта, который потом синхронно нанесёт
  damage обратно). `_dying`-флаг, выставленный СТРОГО ПЕРЕД destroyed.emit,
  единственный надёжный re-entry guard. Запомнить.
- **Унифицированный паттерн смерти Damageable** теперь во всех 6 классах:
  Tower, CampPart, Enemy(→Skeleton), Gnome(→DefenderGnome), Item, ResourcePile.
  Шаблон:
  ```
  var _dying: bool = false
  func take_damage(amount: float) -> void:
      if _dying or amount <= 0.0:
          return
      hp -= amount
      damaged.emit(amount)
      if hp <= 0.0:
          _dying = true
          destroyed.emit()
          queue_free()  # или set_physics_process(false) для "стенки" Tower
  ```

### Known-bugs ревизия (всё закрыто в предыдущих сессиях)
- ✅ `Camp._update_deployed` — `_on_part_destroyed` (camp.gd:1166) синхронно
  режет `_parts` + `_deployed_targets` + переназначает гномов-сирот.
- ✅ Skeleton рескан в WINDUP — `_windup_target` защёлкивается в
  `_on_state_enter(WINDUP)` (skeleton.gd:382), `_perform_strike` бьёт его, не
  свежий `_cached_target`.
- ✅ Tower без queue_free на смерть — есть `_dying` +
  `set_physics_process(false)` + `remove_from_group(Damageable.GROUP)`.
  OctagonTurret/Hand на Tower не завязаны (грепнул).
- ✅ `slam_mask=18` / `target_mask=16` / `cursor_raycast_mask=67` — все три
  теперь через `Layers.MASK_*`.

### Что отложено
- **Gnome._random_point_around без clamp карты** (search_radius=300 при карте
  ±195) — потенциальный wander за границы. Skeleton clamp есть.
- **MountSlot.on_hand_released недетерминирован** при двух близких слотах —
  выигрывает порядок подписки. Нужен явный приоритет по distance.
- **find_flick_target дублирует _find_closest_grabbable** в hand_physical.gd —
  копипаста, объединить в один helper.
- **enemy_spawner.gd:88 мёртвый код** — `enemy.set_target(_target)` для
  Skeleton no-op (override `get_active_target`).

## Сессия 2026-05-08 — Дебаг-читы из клавиатуры в JournalPanel → вкладка «Читы»

### Контекст / запрос геймдизайнера
4 дебаг-биндинга загрязняли клавиатуру: P (старт/рестарт волн), O (немедленная
волна), `[` (спавн 100 скелетов), `]` (стресс-тест 2000). Дизайнер хочет
освободить клавиши под реальный геймплей и собрать читы в одном месте — плюс
добавить «+100 каждого ресурса» для тестов экономики.

### Главные изменения
- **`wave_director.gd:_process` обнулил input-чеки.** 4 блока
  `Input.is_action_just_pressed("spawn_enemies"/...)` удалены. Тело `_process`
  теперь только `_tick_background / _tick_active_poi / _tick_safe_zone_monitor`.
- **Добавил публичный cheat-API**: `cheat_start_campaign / cheat_force_wave /
  cheat_spawn_100 / cheat_stress_2000`. Это тонкие обёртки над существующими
  приватными `_start_campaign / _spawn_poi_wave / _spawn_safe_uniform /
  _spawner.spawn_uniform`. Логика рестарта/safe-зон/таймеров идентична старой;
  только триггер сменился с keyboard на UI.
- **`project.godot → [input]`**: удалены 4 action'а целиком (`spawn_enemies`,
  `force_wave`, `debug_spawn_100`, `debug_stress_2000`). Все остальные
  биндинги остались как были.
- **`journal_panel.gd → Tab.DEBUG = "Читы"`** — четвёртая вкладка после
  Юниты/Лагерь/План. 5 карточек с описанием и кнопкой:
  «Старт/рестарт волн», «Немедленная волна», «+100 скелетов»,
  «Stress 2000 скелетов», «+100 каждого ресурса». Универсальный
  `_build_cheat_card(title, desc, btn_text, target, action)`. Если target
  (WaveDirector / Camp) не найден — кнопка disabled.
- **«+100 каждого ресурса»** реализован как 4 вызова `Camp.add_resource(type,
  100)` для WOOD/STONE/IRON/FOOD — каждый сам эмитит `resources_changed`,
  HUD-счётчики и Camp-вкладка журнала перерисовываются автоматически. Не
  потребовалось ни нового сигнала, ни нового метода в Camp.
- **`_refresh()` пропускает «Лагерь не найден»-ранний выход для DEBUG-вкладки**:
  cheat_start_campaign и пр. от лагеря не зависят, поэтому видеть кнопки можно
  даже до спавна Camp'а. Кнопка «+100 ресурсов» disable-ится индивидуально
  через `target == null`.

### Главное архитектурно
- **WaveDirector.GROUP** (`&"wave_director"`) уже был сделан для discovery без
  NodePath (ResourceZone / Camp / etc.). JournalPanel — autoload, доступа к
  main.tscn нет, поэтому `get_first_node_in_group(WaveDirector.GROUP)` —
  естественный путь. Не пришлось добавлять reference-поле.
- **Один cheat-card factory + Callable-action** даёт гибкость: первые 4 чита
  биндят wd-методы, пятый — локальный helper `_grant_all_resources(camp,
  100)`. Не пришлось хардкодить «один тип кнопки» в обёртке.
- **Не делал ParameterError на «нет активного POI» внутри cheat_force_wave —
  сохранил старый print-предупреждение**. Так дизайнер видит в консоли,
  почему кнопка визуально нажалась, а волны нет; не нужен disable-state на
  кнопке (требовал бы реактивности по camp_deployed/packed).

### Что отложено
- **Hotkey-фоллбэк для читов**. Если в плейтесте окажется неудобно открывать
  журнал каждый раз для стресс-теста — можно добавить debug-only Ctrl+Shift+
  combo через `_unhandled_key_input`. Пока не нужно.
- **Чит «убить всех скелетов»** — простой `_spawner.kill_all_skeletons()`,
  можно добавить шестой кнопкой если потребуется.
- **Авто-disable «Немедленная волна» когда нет активного POI** — потребует
  подписки на camp_deployed/packed и hidden-state в карточке. Не делал, так
  как сейчас фоллбэк (print + no-op) информативен и дёшев.

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
