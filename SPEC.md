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
├── project.godot              — конфиг движка, input map
├── SPEC.md                    — этот документ
├── resources/
│   └── grid.gdshader          — спатиальный шейдер сетки на полу
├── scenes/
│   ├── main.tscn              — корневая сцена (композиция уровня)
│   ├── tower.tscn             — модуль "башня"
│   ├── hand.tscn              — модуль "рука"
│   ├── camera_rig.tscn        — модуль "камера"
│   └── item.tscn              — модуль "предмет" (шаблон)
└── scripts/
    ├── tower.gd
    ├── hand.gd
    ├── camera_rig.gd
    └── item.gd                — class_name Item
```

---

## 3. Архитектурные принципы

1. **Каждая сущность — самодостаточный пакет** (`.tscn` + `.gd`). Все внутренние узлы и под-ресурсы инкапсулированы в собственной сцене.
2. **Контракты через типы и сигналы:**
   - Тип `Item` (`class_name`) — рука принимает «всё, что наследует Item», а не «любой RigidBody3D».
   - Сигналы `Hand.grabbed/released` — внешние слушатели подключаются без правок руки.
3. **Связи между модулями — через `@export`**, а не через хардкоженные `NodePath` внутри скриптов. Подмена цели камеры с башни на руку — одно поле в инспекторе.
4. **`main.tscn` — только композиция:** инстансы модулей + ландшафт + свет. Никакой собственной логики.
5. **`scripts/` — только поведение, `scenes/` — только структура.** Сцены не содержат скриптов в чужих папках, скрипты не делают `preload` чужих сцен (кроме рантайм-спавна, которого пока нет).

---

## 4. Координатное пространство и физика

- **Мировая ось Y — вверх**, X — вправо, Z — на зрителя.
- **Уровень пола — y = 0** (верхняя грань узла `Ground`).
- **Камера — ортогональная**, изометрический угол: позиция `(12, 12, 12)` от цели, `look_at(target)`. Смещение и базис в `Camera3D.transform` посчитаны вручную.
- **Размеры и позиции:**
  | Узел | Размер | Стартовая позиция | Высота центра |
  |---|---|---|---|
  | Ground | 200×1×200 | (0, −0.5, 0) | y=−0.5 (верх y=0) |
  | Tower | 2×6×2 | (0, 3, 0) | y=3 (низ y=0) |
  | Hand | сфера r=0.5 | следует курсору | `surface_y + hand_height` |
  | Item (бокс) | переменный (`item_size`) | произвольно | `size.y / 2` (низ на y=0) |

### 4.1 Коллизионные слои

Имена слоёв заданы в [project.godot → layer_names](project.godot). Слой определяет «что это семантически», маска — «с чем взаимодействует».

| Слой | Имя | Кто на нём | Кто его сканирует |
|---|---|---|---|
| 1 | Terrain | Ground (в будущем — холмы, стены) | все динамические тела + Hand-raycast |
| 2 | Items | все `Item` (поднимаемые ящики) | все динамические тела + Hand-raycast + GrabArea/MagnetArea + Slam |
| 3 | Actors | Tower (player-side) | Items, Enemies |
| 4 | Projectiles | (заготовка под магию) | Terrain, Actors, Enemies |
| 5 | Enemies | `Skeleton` и будущие враги | Tower (Actors), Slam |

**Маски в текущей итерации:**
- `Tower`, `Item`, `Ground`: `mask = 31` (все 5 слоёв) — взаимодействуют с чем угодно.
- `Skeleton`: `mask = 23` (Terrain + Items + Actors + Enemies) — включает свой же слой, поэтому скелеты блокируют друг друга. Так как оба кинематика, не «пушат» — просто скользят вдоль; визуально это даёт плотную толкучку у цели.

**Маски запросов (не тел):**
- `Hand.GrabArea` / `Hand.MagnetArea`: `collision_mask = 2` (только Items) — нельзя схватить башню или скелета.
- `Hand.terrain_mask`: `3` (Terrain + Items) — рука поднимается над полом и ящиками, но не лезет на башню/врагов/снаряды.
- `Hand:PhysicalActions.slam_mask`: `18` (Items + Enemies) — slam задевает только то, что должно «разлетаться».

---

## 5. Модули

### 5.1 Tower — `scenes/tower.tscn`, `scripts/tower.gd`

**Тип корня:** `CharacterBody3D`.

**Назначение:** управляемая башня-герой. Передвигается по миру через WASD, прижимается гравитацией к полу. Если встречает на пути `Item`, который легче неё, — толкает его телом по направлению движения.

**Экспорты:**
- `move_speed: float = 8.0` — горизонтальная скорость.
- `gravity: float = 20.0` — ускорение свободного падения.
- `mass: float = 10.0` — эффективная масса башни (для сравнения с `Item.mass`).
- `hp: float = 1000.0` — здоровье. На 0 → `destroyed.emit()` (без queue_free — game-over UI отдельно).
- `push_strength: float = 1.0` — множитель импульса при толкании предметов (группа `Push Items`).
- `enemy_push_speed_factor: float = 1.5` — множитель скорости knockback'а, который башня сообщает врагу при контакте (группа `Push Enemies`).
- `enemy_push_duration: float = 0.2` — длительность knockback'а врагу. Refresh'ится каждый физкадр контакта.
- `debug_log: bool = true` — включить событийные логи.

**Сигналы:**
- `damaged(amount: float)` — каждый раз при `take_damage`.
- `destroyed` — в момент перехода `hp ≤ 0`.

**Публичный API:**
- `take_damage(amount: float)` — общий «damageable»-контракт (см. `scripts/damageable.gd`). Враги бьют через него.

**Логика движения:**
- `velocity.y -= gravity * delta`, обнуляется при `is_on_floor()`.
- `velocity.x/z = input_dir * move_speed`, где `input_dir` — нормализованный вектор от `Input.get_axis`.
- `move_and_slide()` — стандартный кинематический шаг.

**Логика разрешения контактов (`_resolve_contacts`, после `move_and_slide`):**
- Скорость **до** `move_and_slide` запоминается в `intended_velocity` (после слайда компонент в сторону препятствия обнуляется, и без этого нельзя понять, что туда шли).
- Для каждой слайд-коллизии диспатч по типу:
  - **`Item` (`_push_item`)**, при условиях не-freeze и `tower.mass > item.mass`:
    - `push_dir = -col.get_normal()` — направление от башни в предмет.
    - `v_into = intended_velocity.dot(push_dir)`, `v_diff = v_into − item.linear_velocity.dot(push_dir)`.
    - Импульс: `push_dir × v_diff × item.mass × ratio × push_strength`, где `ratio = (mass − item.mass) / mass` ∈ [0, 1).
  - **`Enemy` (`_push_enemy`)**:
    - Горизонтальный `push_dir_h = -col.get_normal().horizontal.normalized()`.
    - Если `intended_velocity.dot(push_dir_h) ≤ 0.1` — башня не едет в эту сторону, скип.
    - `enemy.apply_knockback(push_dir_h × v_into × enemy_push_speed_factor, enemy_push_duration)`.
    - В `_contacts_last` врагов не пишем — слишком много, спам логов.
    - Эффект: пока башня едет в скелетов, knockback каждый физкадр обновляется → они летят в сторону движения и тут же выводятся из-под башни. После того как тоwer проедет, AI скелетов снова включается, они разворачиваются и идут обратно.

**Логирование (когда `debug_log=true`):**
- `print` на: контакт с полом ↔ воздух, любое изменение `input_dir` (старт/стоп/смена направления).
- `printerr` на: «застряли» (есть ввод, скорость < 10% от move_speed), «провалились» (y < −10), коллизия со стеной (нормаль с y ≤ 0.7, отфильтровывает пол).

**Внешние зависимости:** только `Input` actions и физика. Ни одной ссылки на другие модули.

### 5.2 Hand — `scenes/hand.tscn`

**Тип корня:** `Node3D` с `class_name Hand`.

**Назначение:** координатор. Сама Hand отвечает только за позиционирование под курсором (с учётом высоты поверхности), сглаженный трекинг скорости и проксирование сигналов наружу. Все «действия» вынесены в подузлы по категориям, у каждой категории — собственный скрипт и собственные экспорты.

**Дочерние узлы:**
- `HandMesh` — `MeshInstance3D` со сферой r=0.5 (визуал).
- `GrabArea` — `Area3D` со сферой r=2 на оффсете `(0, −1.5, 0)`, `collision_mask=2` (Items). Зона мгновенного захвата.
- `MagnetArea` — `Area3D` со сферой r=4 на том же оффсете, `collision_mask=2`. Зона притяжения.
- `PhysicalActions` — `Node` со скриптом `hand_physical.gd` (см. §5.2.1).
- `SpellActions` — `Node` со скриптом `hand_spell.gd` (см. §5.2.2).

**Экспорты на самой Hand (`scripts/hand.gd`):**
- `hand_height: float = 2.5` — просвет между рукой и поверхностью под курсором.
- `terrain_mask: int = 3` (`@export_flags_3d_physics`) — слои для raycast'а высоты. Terrain + Items.
- `debug_log: bool = true` — лог только смены поверхности (всё остальное логируется в подмодулях).

**Публичный API для подмодулей:**
- `hand.global_position` — мировая позиция (на луче камеры, на высоте `surface_y + hand_height`).
- `hand.smoothed_velocity()` — сглаженная скорость движения за 6 кадров (для «силы» броска и пр.).
- `hand.grab_area: Area3D`, `hand.magnet_area: Area3D` — Area-зоны.
- `hand.physical_actions`, `hand.spell_actions` — ссылки на подмодули.
- `hand.lock_position(bool)` — пока залочено, Hand перестаёт перетаскивать руку под курсор. Подмодуль может временно ставить руку куда хочет (используется щелбаном для орбиты вокруг цели).
- `hand.cursor_world_position()` — точка-под-курсором в мире. Обновляется каждый кадр **независимо** от lock'а. Подмодуль может читать её, чтобы реагировать на мышь, даже когда сам перехватил позицию руки.

**Сигналы (re-emit из PhysicalActions, для совместимости):**
- `grabbed(item: Item)`, `released(item: Item, velocity: Vector3)`.

**Логика позиционирования (`_follow_cursor`):**
1. `intersect_ray` от камеры через `mouse_pos` по `terrain_mask` → `surface_y`. Удерживаемый предмет (если PhysicalActions сейчас что-то держит) исключается из запроса. Промах → `surface_y = 0`.
2. Пересечение **того же** луча камеры с горизонтальной плоскостью на `surface_y + hand_height` → позиция руки. Так рука и на луче (под пиксельным курсором), и над поверхностью на нужный просвет.

**Логирование Hand (`debug_log=true`):**
- `[Hand] поверхность: <имя> [<слой>], y=...` — на фронте смены поверхности.

**Внешние зависимости:** активная камера сцены, тип `Item` (для сигналов).

#### 5.2.1 PhysicalActions — `scripts/hand_physical.gd`

**Категория:** физика. Содержит:
- **Постоянное действие** — захват / бросок / магнит (ЛКМ).
- **Активная способность** на ПКМ — диспатчится по `equipped`. Сейчас две: `slam` (хлопок) и `flick` (щелбан). Смена клавишами `1` / `2`.

**Архитектурно:** `_handle_input` обрабатывает три набора триггеров — `equip_*` (смена экипировки), `hand_action` (press/release с диспатчем по `equipped` через `_dispatch_action_press/_release`), `hand_grab` (захват — отключён, пока активен `flick`, иначе схватили бы цель щелбана). Состояние текущего ПКМ-действия — в `_action_active` (`""`/`"flick"`; для `slam` остаётся `""`, потому что hold-state ему не нужен).

**Экспорты (захват/бросок/магнит):**
- `max_lift_mass: float = 10.0` — порог массы для подъёма (и магнита).
- `throw_strength: float = 1.2` — множитель импульса при броске.
- `max_throw_speed: float = 30.0` — потолок скорости броска.
- `hold_offset: Vector3 = (0, −1, 0)` — где предмет висит относительно руки.
- `magnet_force: float = 30.0` — сила притяжения из `MagnetArea`.

**Экспорты (группа `Equipment`):**
- `equipped: String` (`@export_enum("slam", "flick")`) — текущая активная способность. Дефолт `slam`. Меняется клавишами `1` / `2` или из инспектора. Сеттер логирует смену.

**Экспорты (группа `Slam (RMB)`):**
- `slam_radius: float = 5.0` — радиус AOE.
- `slam_force: float = 30.0` — базовая сила импульса в эпицентре.
- `slam_lift_factor: float = 0.4` — вертикальная компонента толчка.
- `slam_damage: float = 20.0` — базовый урон в эпицентре.
- `slam_cooldown: float = 0.5` — секунды между хлопками.
- `slam_mask: int = 18` (`@export_flags_3d_physics`) — Items + Enemies.
- `slam_visual_color: Color` — цвет вспышки.
- `slam_knockback_duration: float = 0.4` — на сколько секунд враги «оглушены» knockback'ом (их AI не работает в это время).

**Экспорты (группа `Flick (RMB hold-release)`):**
- `flick_orbit_radius: float = 1.5` — расстояние, на которое рука «отъезжает» от цели по направлению курсора.
- `flick_force: float = 25.0` — импульс при отпускании ПКМ.
- `flick_damage: float = 5.0` — урон цели при щелчке.

**Сигналы:**
- `grabbed(item)`, `released(item, velocity)` — Hand их re-emit'ит наружу.
- `slammed(position: Vector3, radius: float)` — в момент хлопка.
- `flicked(target: Item, velocity: Vector3)` — в момент отпускания щелбана.

**Публичный API:** `get_held_item() -> Item`, `is_holding() -> bool`.

**Зависимости:** только родитель Hand. Через него `_hand.global_position`, `_hand.smoothed_velocity()`, `_hand.grab_area`, `_hand.magnet_area`, `_hand.get_world_3d()` (для шейп-каста хлопка), `_hand.lock_position(bool)` (для удержания позиции при щелбане). Тип `Item` (для фильтра, `set_highlighted`, `take_damage`).

**Логика хлопка (`_perform_slam`):**
1. Кулдаун-гейт через `_slam_cooldown_remaining`.
2. `PhysicsShapeQueryParameters3D` со сферой `slam_radius` в `_hand.global_position`, маска = `slam_mask`. `intersect_shape` возвращает все тела в зоне.
3. Falloff = `1 − horizontal_dist / slam_radius` (горизонтальная, не 3D — иначе `hand_height` съел бы всю силу). Направление = `(horizontal + UP × slam_lift_factor).normalized()`. Считаются вспомогательной `_slam_direction_and_falloff`, общей для всех типов целей.
4. Для каждого `Item` (не `freeze`): `apply_central_impulse(dir × slam_force × falloff)` + `take_damage(slam_damage × falloff)`.
5. Для каждого `Enemy`: `enemy.apply_knockback(dir × slam_force × falloff, slam_knockback_duration)` + `take_damage(slam_damage × falloff)`. У `CharacterBody3D` нет `apply_central_impulse`, поэтому через метод `apply_knockback`, который подменяет velocity и временно отключает AI.
6. Спавним полупрозрачную сферу с emission в эпицентре; `Tween` масштабирует до `slam_radius` и фейдит альфу за 0.3s, потом `queue_free`.
7. `slammed.emit(origin, slam_radius)`.

**Логика щелбана (flick):**
1. **Press (`_flick_pressed`):** Если рука уже что-то держит — отказ. Иначе ищем `_find_closest_item` в `GrabArea`; если пусто — отказ. При успехе:
   - `_flick_target = target`.
   - Стартовое `_flick_orbit_dir` = горизонтальная разница `(hand − target)`, или дефолтный `+X` если рука прямо над целью.
   - `_hand.lock_position(true)` — Hand перестаёт перетаскивать руку под курсор. **При этом `cursor_world_position()` продолжает обновляться** — flick читает её каждый кадр.
   - `_action_active = "flick"`.
2. **Hold (`_update_flick`, в `_process`):** Направление орбиты берётся из курсора:
   - `to_cursor_h = (cursor − target)` в плоскости XZ.
   - Если ненулевое → `_flick_orbit_dir = to_cursor_h.normalized()`. Если курсор слишком близко к цели — держим прошлое направление (без дёрганий).
   - `hand.global_position = target + _flick_orbit_dir × flick_orbit_radius`. Куда курсор — туда рука.
   - Если цель уничтожилась посреди прицеливания — отмена и разлок руки.
3. **Release (`_flick_released`):** `_hand.lock_position(false)`. Направление импульса = `(target − hand).normalized()` = `−_flick_orbit_dir` (предмет летит **противоположно** руке). `apply_central_impulse(dir × flick_force)` + `take_damage(flick_damage)`. `flicked.emit(target, velocity)`.

**Подсветка кандидата:**
Каждый кадр `_update_candidate_highlight` ищет ближайший `Item` в `GrabArea` (проходящий по массе). На фронте смены — `set_highlighted` у старого/нового. Пока `_held != null` — кандидата нет. Во время орбиты щелбана подсветка остаётся на цели — она самая близкая к руке.

**Логи (`[Hand:Physical] ...`):**
- Экипировка: `экипировано: X` (на фронте).
- Захват: `схвачен X (mass=)`. Бросок: `отпущен X, |v|=...`.
- Магнит: `магнит тянет X (mass=, dist=)` / `магнит: цели нет` — на фронте.
- Кандидат: `кандидат: X` / `кандидат: —` — на фронте.
- Хлопок: `хлопок @ (x, y, z), задело: N` / `хлопок на кулдауне (Xs)`.
- Щелбан: `щелбан: захват цели X` / `щелбан: предмета под рукой нет` / `щелбан: рука занята...` / `щелбан: X полетел в (...), |v|=...`.

#### 5.2.2 SpellActions — `scripts/hand_spell.gd`

**Категория:** заклинания. **ЗАГЛУШКА** на текущей итерации.

**План (TBD):**
- Привязка ввода: ПКМ или клавиши 1..N.
- Реестр заклинаний (`name → cost / cooldown / scene-effect`).
- Сигнал `spell_cast(spell_name: String, position: Vector3)` для слушателей (UI, звук, анимация башни).

**Экспорты сейчас:** `debug_log: bool = true`.

**Зависимости (проектируемые):** только родитель Hand. Через него позиция (для исхода заклинания) и скорость (если каст должен учитывать движение руки).

### 5.3 CameraRig — `scenes/camera_rig.tscn`, `scripts/camera_rig.gd`

**Тип корня:** `Node3D`.

**Назначение:** контейнер, следящий за указанной целью. Камера-ребёнок наследует движение, но сохраняет свой локальный изометрический угол.

**Дочерние узлы:**
- `Camera3D` — ортогональная камера. Локальный transform: `(12, 12, 12)` со look-at в локальный (0, 0, 0); ортогональный размер 30.

**Экспорты:**
- `target_path: NodePath` — `@export_node_path("Node3D")`. Кого следить.
- `follow_speed: float = 8.0` — коэффициент `lerp` за кадр.

**Логика:**
- В `_ready` снимает цель из `target_path`, мгновенно прыгает на её позицию (нет «въезда» с (0,0,0)).
- В `_process`: `global_position.lerp(target.global_position, follow_speed * delta)`.

**Внешние зависимости:** ничего. `target_path` устанавливается из главной сцены, скрипт не знает имени цели.

### 5.4 Item — `scenes/item.tscn`, `scripts/item.gd`

**Тип корня:** `RigidBody3D` с `class_name Item`.

**Назначение:** базовый подбираемый предмет. Все варианты (дерево/камень/железо) — это инстансы одной сцены с разным `item_color` и `mass`.

**Дочерние узлы:**
- `CollisionShape3D` — `BoxShape3D` 1×1×1.
- `MeshInstance3D` — `BoxMesh` 1×1×1 без материала-по-умолчанию.

**Экспорты:**
- `item_color: Color` — базовый цвет.
- `item_size: Vector3` — размер бокса (XYZ).
- `highlight_color: Color` — цвет emission'а при подсветке (по умолчанию тёплый жёлтый).
- `highlight_intensity: float` (0..5) — `emission_energy_multiplier` при подсветке.
- `hp: float = 100.0` — здоровье. На 0 → `destroyed.emit()` + `queue_free()`.
- Унаследованный `mass: float` — стандартное свойство `RigidBody3D`, переопределяется на инстансе.

В `_ready` скрипт создаёт уникальные `BoxMesh`, `BoxShape3D` и `StandardMaterial3D` с заданными параметрами. Ссылка на материал кэшируется в `_material` для последующего управления emission'ом. Ресурсы из `item.tscn` остаются только для превью пустой заготовки в редакторе.

**Сигналы:**
- `damaged(amount: float)` — каждый раз при `take_damage`.
- `destroyed` — когда `hp` ушло в 0 (один раз, перед `queue_free`).

**Публичный API:**
- `set_highlighted(value: bool)` — включает/выключает emission на материале. Дёргается рукой, когда предмет становится текущим кандидатом захвата.
- `take_damage(amount: float)` — наносит урон, эмитит сигналы, при `hp ≤ 0` уничтожает узел. Реализация общего «damageable»-контракта (см. `scripts/damageable.gd`).

**Тестовый набор предметов в `main.tscn`:**

| Имя | Размер | Масса | Толкается башней (mass=10)? | Поднимается рукой (max_lift=10)? |
|---|---|---|---|---|
| SmallBox | 0.5³ | 0.5 | да, легко (ratio=0.95) | да |
| WoodBox | 1³ | 1 | да, легко (ratio=0.9) | да |
| StoneBox | 1³ | 5 | да, медленнее (ratio=0.5) | да |
| IronBox | 1.5³ | 8 | да, тяжело (ratio=0.2) | да |
| GiantCrate | 2.5³ | 20 | нет — башня упирается, скользит вокруг | нет — рука игнорирует |

**Внешние зависимости:** ничего.

### 5.5 Enemies — категория врагов

Иерархия: `Enemy` (база) → `Skeleton` (конкретный тип). Спавн делает отдельный узел `EnemySpawner` в `main.tscn`.

#### 5.5.1 Enemy — `scripts/enemy.gd`

**Тип корня:** `CharacterBody3D` с `class_name Enemy`. **Базовый класс**, не используется напрямую — только через подклассы (Skeleton и будущие).

**Назначение:** общая инфраструктура врагов — HP/урон, knockback, гравитация, цикл `_physics_process`. Поведение оставляется подклассам в виртуальном `_ai_step(delta)`.

**Экспорты:**
- `hp: float = 30.0` — здоровье.
- `move_speed: float = 4.0` — горизонтальная скорость передвижения (используется подклассами через `velocity`).
- `gravity: float = 20.0` — ускорение свободного падения.
- `attack_range: float = 1.5` — на каком расстоянии до цели начинается атака.
- `attack_damage: float = 5.0` — урон цели при атаке.
- `attack_cooldown: float = 1.0` — секунды между атаками. Тикает всегда (в т.ч. в knockback'е), иначе lunge-knockback растягивал бы реальный кулдаун.
- `knockback_friction: float = 5.0` — насколько быстро затухает knockback-velocity (lerp coefficient).
- Группа **Knockback contacts:**
  - `bounce_restitution: float = 0.6` — коэффициент отскока от `_target` при ударе во время knockback'а.
  - `neighbor_push_factor: float = 0.5` — доля собственной скорости, передаваемая соседу-Enemy при контакте в knockback'е.
  - `neighbor_push_duration: float = 0.15` — длительность knockback'а на соседа.

**Сигналы:** `damaged(amount: float)`, `destroyed`.

**Публичный API:**
- `take_damage(amount)` — общий damageable-контракт (см. `scripts/damageable.gd`). На `hp ≤ 0` → `destroyed.emit()` + `queue_free()`.
- `apply_knockback(impulse: Vector3, duration: float)` — внешний толчок. На время `duration` AI отключён, скорость подменяется на `impulse` и плавно затухает к нулю по `knockback_friction`. После применения зовётся виртуальный `_on_knockback()` — подклассы могут сбросить локальное состояние.
- `set_target(target: Node3D)` — кого преследовать. Подклассы используют `_target` в своём AI.

**Виртуальные хуки:**
- `_ai_step(delta)` — поведение в активной фазе.
- `_on_knockback()` — реакция на внешний толчок (например, отменить начатый замах атаки).

**Цикл (`_physics_process`):**
- Применяется гравитация → `velocity.y`.
- `_attack_cooldown_remaining` декрементируется (всегда).
- Если `_knockback_timer > 0` — AI заглушен, горизонтальная velocity лерпится к нулю.
- Иначе — зовётся `_ai_step(delta)`.
- `move_and_slide`.
- **Если в knockback'е** — `_resolve_knockback_contacts()`:
  - Если задели `_target` — `_bounce_off_target(normal)`: компонент скорости в нормаль инвертируется по правилу elastic с `bounce_restitution`.
  - Если задели другого Enemy — `_push_neighbor(other, col)`: соседу применяется `apply_knockback(push_dir × my_speed × neighbor_push_factor, neighbor_push_duration)`. Лунж пробивает толпу, отбрасывая ближних.

**Зависимости:** ничего, кроме физики и Input. Не знает про Tower, Hand, Item.

#### 5.5.2 Skeleton — `scenes/skeleton.tscn`, `scripts/skeleton.gd`

**Тип корня:** `CharacterBody3D` с `class_name Skeleton extends Enemy`.

**Назначение:** простейший враг. Идёт к `_target`, в `attack_range` выполняет **телеграфированный замах**, затем бьёт.

**Дочерние узлы:**
- `CollisionShape3D` — `CapsuleShape3D` r=0.4, h=2.
- `MeshInstance3D` — `CapsuleMesh` того же размера, тёплый бело-серый цвет.

**Экспорты (поверх Enemy):**
- `windup_color: Color` — цвет emission'а во время замаха (по умолчанию красный).
- `windup_intensity: float` (0..5) — `emission_energy_multiplier` во время замаха.
- `attack_windup: float = 0.4` — секунды от начала замаха до удара. У игрока ровно столько, чтобы среагировать (slam'ом отбросить).
- Группа **Strike (физический выпад):**
  - `lunge_speed: float = 8.0` — m/s в момент удара (выше `move_speed`, чтобы выпад был резким).
  - `lunge_duration: float = 0.2` — длительность knockback'а на сам выпад.

**Override в инстансе:** `move_speed = 2.7` (медленнее общего дефолта Enemy=4.0, для теста).

**Слой/маска:** `collision_layer = 16` (Enemies), `collision_mask = 23` (Terrain + Items + Actors + Enemies). Скелеты мутуально видят друг друга; CharacterBody3D-vs-CharacterBody3D просто блокирует движение (без «push»), и у цели образуется плотная толкучка.

**Жизненный цикл:** APPROACH → WINDUP → STRIKE → (LUNGE-knockback) → COOLDOWN → APPROACH.
- **APPROACH:** `dist > attack_range` → `velocity.xz = (target − pos).xz.normalized() × move_speed`.
- **WINDUP:** в `attack_range` и `_attack_cooldown_remaining ≤ 0` → `_in_windup = true`, `_windup_remaining = attack_windup`, `_set_glow(true)`. Скелет стоит, светится красным.
- **STRIKE:** `_windup_remaining ≤ 0` → `_set_glow(false)`, взвести `_attack_cooldown_remaining`, `target.take_damage(...)`, **`_do_lunge()`**.
- **LUNGE-knockback:** `_do_lunge` зовёт `apply_knockback(dir × lunge_speed, lunge_duration)` сам себе — фактически self-induced knockback. На `lunge_duration` AI выключен, скелет физически летит в цель через `move_and_slide`. Удар о башню → `Enemy._bounce_off_target` инвертирует скорость с `bounce_restitution`. Контакт с соседним скелетом → `Enemy._push_neighbor` отбрасывает соседа на `my_speed × neighbor_push_factor`. Лунж буквально «врезается и расталкивает».
- **COOLDOWN:** AI в обычной фазе, кулдаун декрементируется (тикает всегда, в т.ч. в knockback'е). Может сдвинуться, если цель ушла.

**Реакция на knockback (`_on_knockback`):** если был в windup — отменяем. Должен снова подойти и зарядиться.

**Уникальный материал:** в `_ready` дублируем `material_override`, чтобы emission менялся только у этого инстанса. Иначе все 50 скелетов засветились бы одновременно.

**Зависимости:** наследует Enemy. Не знает, что цель именно Tower — просто `Node3D`, у которого может быть `take_damage`.

#### 5.5.3 EnemySpawner — `scripts/enemy_spawner.gd` (Node3D в `main.tscn`)

**Назначение:** по input action порождает партию врагов кольцом вокруг цели.

**Экспорты:**
- `skeleton_scene: PackedScene` — какую сцену спавнить. Привязывается из `main.tscn`.
- `target_path: NodePath` — кого ставить в `set_target` каждому врагу (через `Node3D`-цель).
- `spawn_radius: float = 25.0` — радиус кольца от цели.
- `spawn_radius_jitter: float = 0.3` — разброс ±jitter от радиуса (1 = ±50%).
- `spawn_count: int = 50` — сколько порождать за волну.
- `debug_log: bool = true`.

**Логика:**
- В `_process` ловит `Input.is_action_just_pressed("spawn_enemies")` → `spawn_skeleton_wave()`.
- На каждую волну: цикл `spawn_count` раз — случайный угол на `TAU`, дистанция = `spawn_radius × (1 + ±jitter/2)`, добавляем инстанс `skeleton_scene` в `current_scene`, зовём `set_target(_target)`.

**Зависимости:** только PackedScene и Node3D через NodePath. Спавнер не знает ни Skeleton, ни Tower по имени; их имена/типы заданы из `main.tscn` на инстансе.

### 5.6 Ground — inline в `main.tscn`

**Тип корня:** `StaticBody3D`.

**Назначение:** пол с отрисованной сеткой 2×2 м.

**Состав:**
- `GroundCollision` — `CollisionShape3D` с `BoxShape3D` 200×1×200.
- `GroundMesh` — `MeshInstance3D` с тем же боксом и `ShaderMaterial`, использующим `resources/grid.gdshader`.

**Шейдер (`grid.gdshader`):**
- Считает в фрагментном шейдере расстояние до ближайшей линии по мировым XZ.
- Сглаживает края через `fwidth + smoothstep` — линии не «лесенят» при любом зуме.
- Принимает освещение от `DirectionalLight3D` (тень от башни падает на пол).
- Параметры: `base_color`, `grid_color`, `grid_size`, `line_width`. Дефолты в `main.tscn`: `grid_size=2.0`, `line_width=0.04`.

---

## 6. Управление и инпуты

Регистрируются в `project.godot → [input]`:

| Action | Клавиша | Используется в |
|---|---|---|
| `move_forward` | W | Tower |
| `move_back` | S | Tower |
| `move_left` | A | Tower |
| `move_right` | D | Tower |
| `hand_grab` | LMB | Hand:PhysicalActions (захват/бросок) |
| `hand_action` | RMB | Hand:PhysicalActions (триггер активной способности — slam/flick) |
| `equip_slam` | 1 | Hand:PhysicalActions (экипировать хлопок) |
| `equip_flick` | 2 | Hand:PhysicalActions (экипировать щелбан) |
| `spawn_enemies` | P | EnemySpawner (волна скелетов) |

Курсор мыши — позиция руки. Системного захвата курсора нет, он движется свободно.

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

### 7.3 Решённые ошибки

| # | Ошибка | Причина | Исправление |
|---|---|---|---|
| 1 | Камера смотрит вверх и в сторону, башню не видно | В `Transform3D(...)` я записал базисные векторы по столбцам, а Godot хранит матрицу базиса по строкам. Получилось другое вращение. | Перепаковал значения: `Transform3D(X.x, Y.x, Z.x, X.y, Y.y, Z.y, X.z, Y.z, Z.z, ox, oy, oz)`. |
| 2 | Лог башни показывает один input, а позиция уползла в неожиданную сторону | Логирование триггерилось только на смену «движется ↔ стоит», смены направления (например, S → A+S → A) проходили молча. | Стал логировать **любое изменение `input_dir`**, а не только on/off-переходы. |
| 3 | Чтобы схватить предмет, курсор приходится точно поставить «над» ним; малейший отступ — и захват не работает | `GrabArea` располагался **на самой руке** (y=2.5), сфера r=2 «касалась» предмета на полу (y=0.5) только в нижней точке. При сдвиге курсора на 0.5 м дистанция уже превышала радиус. | (а) Опустил `GrabArea` на y=−1.5 относительно руки (центр сферы у пола). (б) Добавил отдельный `MagnetArea` r=4 + притягивающую силу — предмет «доползает» к руке, если игрок чуть-чуть не дотянулся. |

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
| Tower | сигналы `damaged/destroyed`, метод `take_damage(float)` (damageable-контракт, см. `scripts/damageable.gd`) | Input actions WASD; читает `Item.mass`, `Item.freeze`; пушит `Item` через `apply_central_impulse` |
| Enemy (база) | сигналы `damaged/destroyed`, методы `take_damage(float)` / `apply_knockback(Vector3, float)` / `set_target(Node3D)`; виртуальный `_ai_step(delta)` (damageable-контракт, см. `scripts/damageable.gd`) | физика, наследники |
| Skeleton | (наследует Enemy) | `_target.take_damage(...)` (duck-typed) |
| EnemySpawner | — | `Input "spawn_enemies"`, PackedScene + NodePath из main.tscn |
| Hand | сигналы `grabbed/released` (re-emit из PhysicalActions), публичный API для подмодулей (`global_position`, `smoothed_velocity()`, `grab_area`, `magnet_area`) | активная камера; тип `Item` |
| Hand:PhysicalActions | сигналы `grabbed/released/slammed/flicked`, методы `get_held_item()/is_holding()`, экспорт `equipped` | Input `hand_grab`/`hand_action`/`equip_slam`/`equip_flick`, родитель Hand (включая `lock_position`), тип `Item` (включая `take_damage`) |
| Hand:SpellActions | сигнал `spell_cast(name, position)` (черновик) | родитель Hand (план) |
| CameraRig | — | `@export target_path` |
| Item | `@export item_color/item_size/highlight_*/hp`, наследует `mass`, методы `set_highlighted(bool)` / `take_damage(float)`, сигналы `damaged(amount)` / `destroyed` | физика, телепорт от руки в `freeze` |
| Ground | — | — |

Каждая стрелка сверху проходит **только через имя класса, сигнал или `@export`**. Никаких `get_node("../Tower")` внутри скриптов.

---

## 9. EventBus (autoload)

**Файл:** `scripts/event_bus.gd`. **Регистрация:** `project.godot → [autoload] → EventBus="*res://scripts/event_bus.gd"`. Глобально доступен как `EventBus` в любом скрипте.

**Назначение.** Глобальный канал событий. Каждая damageable / interactive сущность по-прежнему держит **локальные** сигналы (`damaged`, `destroyed`, `grabbed`, …) — это контракт для тесно-связанных слушателей. Параллельно она перенаправляет их на bus, чтобы UI / счёт / звук подписывались **один раз** на нужный глобальный сигнал, не зная про конкретные инстансы и не переподключаясь при каждом spawn'е.

**Конвенция именования:** `<entity>_<event>(args)`. Первый аргумент — сама сущность (для тех типов, где нужно отличить инстанс; Tower одна на сцене, поэтому без `self`).

**Список сигналов:**

| Сигнал | Аргументы | Источник |
|---|---|---|
| `item_damaged` | `(item: Item, amount: float)` | `Item._ready` re-emit |
| `item_destroyed` | `(item: Item)` | `Item._ready` re-emit |
| `enemy_damaged` | `(enemy: Enemy, amount: float)` | `Enemy._ready` re-emit (Skeleton наследует через `super._ready()`) |
| `enemy_destroyed` | `(enemy: Enemy)` | `Enemy._ready` re-emit |
| `tower_damaged` | `(amount: float)` | `Tower._ready` re-emit |
| `tower_destroyed` | — | `Tower._ready` re-emit |
| `hand_grabbed` | `(item: Item)` | `Hand._ready` re-emit |
| `hand_released` | `(item: Item, velocity: Vector3)` | `Hand._ready` re-emit |
| `hand_slammed` | `(position: Vector3, radius: float)` | `HandPhysical._ready` re-emit |
| `hand_flicked` | `(target: Item, velocity: Vector3)` | `HandPhysical._ready` re-emit |

**Паттерн re-emit'а в сущности:**
```gdscript
func _ready() -> void:
    # ... базовая инициализация ...
    damaged.connect(func(amount: float) -> void: EventBus.item_damaged.emit(self, amount))
    destroyed.connect(func() -> void: EventBus.item_destroyed.emit(self))
```

**Как подписаться (cross-cutting слушатель):**
```gdscript
func _ready() -> void:
    EventBus.enemy_destroyed.connect(_on_enemy_destroyed)

func _on_enemy_destroyed(enemy: Enemy) -> void:
    score += 10
```

**Принципы:**
1. Bus — **дополнительный** канал, не замена локальным сигналам. Hand:PhysicalActions слушает `Item.destroyed` локально (если ему это нужно для своей логики); UI слушает `EventBus.item_destroyed` — оба источника эмитятся параллельно.
2. Bus **только эмитит**. Никакой логики, фильтрации, состояния — иначе становится god-object'ом.
3. Подключение re-emit'а делается в `_ready` сущности **один раз**. Подклассы с собственным `_ready` обязаны звать `super._ready()`, иначе теряется подключение базы (см. Skeleton).
4. Тип-сигнатуры в сигналах bus'а служат документацией; рантайм Godot не валидирует их строго (динамический emit), но статический анализатор и автокомплит ловят опечатки.

### 9.1. LogConfig (autoload)

**Файл:** `scripts/log_config.gd`. **Регистрация:** `project.godot → [autoload] → LogConfig="*res://scripts/log_config.gd"`. Поле `master_enabled: bool` — глобальный мастер-выключатель debug-логов. Каждый entity-скрипт с per-entity `debug_log: bool` гейтит print'ы как `if debug_log and LogConfig.master_enabled:` — per-entity флаги остаются для тонкого мута одного шумного модуля, а `master_enabled = false` глушит всё разом (удобно при сборе/демо). На `printerr` (предупреждения) не распространяется.

---

## 10. Незакрытые вопросы и направления

Не реализовано в текущей итерации (на будущее):

- **Магия.** Есть в концепте, в коде её нет.
- **Поворот башни** (мышью или клавишами).
- **Препятствия / стены.** Сейчас только плоский пол.
- **HUD** (мана, кулдауны, инвентарь).
- **Контролируемое сглаживание захвата.** Магнит сейчас тянет постоянной силой; возможно, стоит сделать пружину (target velocity → force) для более стабильного «подлёта».
- **Звук.** Полностью отсутствует.
- **Системный курсор.** Видим одновременно с рукой; имеет смысл скрыть/заменить на собственный.
- **Editor preview цвета Item.** Без `@tool` все ящики в редакторе серые до запуска.
