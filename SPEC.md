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
├── SPEC.md                    — этот документ
├── resources/
│   └── grid.gdshader          — спатиальный шейдер сетки на полу
├── scenes/
│   ├── main.tscn              — корневая сцена (композиция уровня)
│   ├── tower.tscn             — модуль "башня"
│   ├── hand.tscn              — модуль "рука" + два под-узла-категории
│   ├── camera_rig.tscn        — модуль "камера"
│   ├── item.tscn              — модуль "предмет" (шаблон)
│   ├── skeleton.tscn          — конкретный враг (Skeleton extends Enemy)
│   ├── camp.tscn              — лагерь (4 палатки + спавн гномов)
│   ├── gnome.tscn             — обитатель лагеря (CharacterBody3D)
│   └── resource_pile.tscn     — куча ресурсов на полу
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
    ├── enemy_spawner.gd       — спавнер волн (Node3D)
    ├── camp.gd                — class_name Camp
    ├── gnome.gd               — class_name Gnome
    ├── resource_pile.gd       — class_name ResourcePile
    ├── layers.gd              — class_name Layers (именованные физические слои + маски)
    ├── damageable.gd          — class_name Damageable (group-контракт + try_damage)
    ├── pushable.gd            — class_name Pushable (group-контракт + try_push)
    ├── grabbable.gd           — class_name Grabbable (group-контракт для LMB-grab)
    ├── shatter_effect.gd      — class_name ShatterEffect (визуал смерти, общий для врагов и т.п.)
    ├── vec_util.gd            — class_name VecUtil (горизонтальные хелперы Vector3)
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
3. **Именованные физические слои.** `scripts/layers.gd` (`class_name Layers`) — единая точка правды: `Layers.TERRAIN/ITEMS/ACTORS/PROJECTILES/ENEMIES/CAMP_OBSTACLE` плюс композитные `MASK_HAND_CURSOR / MASK_HAND_TARGETS / MASK_ALL_GAMEPLAY / MASK_SKELETON / MASK_TERRAIN_ONLY`. В коде GDScript маски берутся через `Layers.X`. В `.tscn` Godot хранит маски как ints — там литералы; пересчитываются от констант (комментарий рядом).
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
  | Ground | 200×1×200 | (0, −0.5, 0) | y=−0.5 (верх y=0) |
  | Tower | 2×6×2 | (0, 3, 0) | y=3 (низ y=0) |
  | Hand | сфера r=0.5 | следует курсору | `surface_y + hand_height` |
  | Item (бокс) | переменный (`item_size`) | произвольно | `size.y / 2` (низ на y=0) |

### 4.1 Коллизионные слои

Имена слоёв заданы в [project.godot → layer_names](project.godot) и продублированы константами в `scripts/layers.gd`. Слой определяет «что это семантически», маска — «с чем взаимодействует».

| Слой | Имя | Кто на нём | Кто его сканирует |
|---|---|---|---|
| 1 | Terrain | Ground (в будущем — холмы, стены) | все динамические тела + Hand-cursor-raycast + shatter-фрагменты |
| 2 | Items | `Item`, `ResourcePile` | все динамические тела + Hand-cursor-raycast + GrabArea/MagnetArea + Slam |
| 3 | Actors | Tower (player-side) | Items, Enemies |
| 4 | Projectiles | (заготовка под магию) | Terrain, Actors, Enemies |
| 5 | Enemies | `Skeleton` и будущие враги | Tower (Actors), Slam, Flick |
| 6 | CampObstacle | палатки `Camp` (CaravanPart*) — статически на этом слое в обоих режимах | Skeleton (мутуально-исключающе с Tower — башня НЕ сканирует слой 6) |

В коде GDScript маски берутся именованными константами из `Layers`; в `.tscn` Godot хранит ints, поэтому там — литералы (значения должны соответствовать `Layers.MASK_*`).

**Маски тел (актуальные значения):**
- `Tower`, `Item`, `Ground`, `ResourcePile`: `Layers.MASK_ALL_GAMEPLAY = 31` (Terrain + Items + Actors + Projectiles + Enemies) — взаимодействуют со всем «обычным», но **не с CampObstacle**: палатки намеренно не блокируют башню/предметы.
- `Skeleton`: `Layers.MASK_SKELETON = 55` (Terrain + Items + Actors + Enemies + CampObstacle) — включает свой же слой (мутуальная блокировка) и слой палаток (упирается в них и в каравне, и в развёрнутом лагере).
- Shatter-фрагменты: `Layers.MASK_TERRAIN_ONLY = 1` — падают на пол, проходят сквозь тела и друг друга.

**Маски запросов (не тел):**
- `Hand.cursor_raycast_mask`: `Layers.MASK_HAND_CURSOR = 3` (Terrain + Items) — рука поднимается над полом и ящиками/кучами, но не лезет на башню/врагов/снаряды.
- `Hand.GrabArea`: `Layers.MASK_HAND_TARGETS = 18` (Items + Enemies) — flick видит и Items (с mass-фильтром), и Enemies. LMB-grab фильтрует через `Grabbable.is_grabbable` + mass, поэтому скелета случайно не схватить.
- `Hand.MagnetArea`: `Layers.ITEMS = 2` — магнит тянет только то, что на слое Items (Items, ResourcePile).
- `Hand:PhysicalSlam.slam_mask`: `Layers.MASK_HAND_TARGETS = 18` (Items + Enemies).

---

## 5. Модули

### 5.1 Tower — `scenes/tower.tscn`, `scripts/tower.gd`

**Тип корня:** `CharacterBody3D` с `class_name Tower`.

**Назначение:** управляемая башня-герой. Передвигается по миру через WASD, прижимается гравитацией к полу. Если встречает на пути `Item`, который легче неё, — толкает его телом по направлению движения. Контактирующих kinematic-целей (скелетов и любых будущих врагов) расталкивает через универсальный `Pushable`-контракт.

**Регистрации в `_ready`:**
- `Damageable.register(self)` — башня принимает урон. `Pushable` НЕ регистрируется: башня не должна толкаться чужими импульсами (это игровая стена-герой).

**Экспорты:**
- `move_speed: float = 8.0` — горизонтальная скорость.
- `gravity: float = 20.0` — ускорение свободного падения.
- `mass: float = 10.0` — эффективная масса башни (для сравнения с `Item.mass`).
- `hp: float = 1000.0` — здоровье. На 0 → `destroyed.emit()` (без queue_free — game-over UI отдельно).
- Группа `Push Items`: `push_strength: float = 1.0` — множитель импульса при толкании предметов.
- Группа `Push Enemies`:
  - `enemy_push_speed_factor: float = 1.5` — множитель скорости knockback'а, который башня сообщает kinematic-цели при контакте.
  - `enemy_push_duration: float = 0.2` — длительность knockback'а. Refresh'ится каждый физкадр контакта.
- `fall_threshold: float = -10.0` — Y, ниже которого «провалились» (используется только в дебаг-логе).
- `debug_log: bool = true` — событийные логи.

**Константы и `@onready`:**
- `MIN_PUSH_VELOCITY := 0.1` — порог компоненты `intended_velocity` в направлении kinematic-цели.
- `_floor_normal_threshold := cos(get_floor_max_angle())` — `@onready`. Раньше был хардкод `FLOOR_NORMAL_THRESHOLD`; теперь один источник правды — `floor_max_angle` самого `CharacterBody3D`.

**Сигналы:** `damaged(amount: float)`, `destroyed`. Re-emit на `EventBus.tower_damaged/_destroyed`.

**Публичный API:** `take_damage(amount: float)` — общий damageable-контракт. На `hp ≤ 0` → `_dying = true`, `set_physics_process(false)`, `velocity = ZERO`, `destroyed.emit()`. Дальнейшие вызовы — no-op через ранний return по `_dying`. Тело остаётся коллидирующим (скелеты упираются как в стену).

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
- `GrabArea` — `Area3D` со сферой r=2 на оффсете `(0, −1.5, 0)`, `collision_mask=18` (Items + Enemies). Зона захвата (LMB) и поиска цели для Flick. Доступ снаружи — только через `get_grabbable_bodies()`.
- `MagnetArea` — `Area3D` со сферой r=4 на том же оффсете, `collision_mask=2` (только Items). Доступ — через `get_magnet_bodies()`.
- `PhysicalActions` — `Node` со скриптом `hand_physical.gd` (см. §5.2.1).
- `SpellActions` — `Node` со скриптом `hand_spell.gd` (см. §5.2.2).

**Экспорты на самой Hand (`scripts/hand.gd`):**
- `hand_height: float = 2.5` — просвет между рукой и поверхностью под курсором.
- `cursor_raycast_mask: int = 3` (`@export_flags_3d_physics`) — слои для raycast'а высоты под курсором (Terrain + Items). Имя точное: маска именно курсорного raycast'а, не «всех terrain-операций». Раньше называлось `terrain_mask`.
- `debug_log: bool = true` — лог только смены поверхности.

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
- `magnet_force: float = 30.0` — сила притяжения из `MagnetArea`.

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
- `PhysicsShapeQueryParameters3D` со сферой `slam_radius` в `_hand.global_position`, `collision_mask = slam_mask` (`@export_flags_3d_physics`, дефолт `18`).
- Для каждого результата (Damageable, не равного `_coord.get_held_item()`):
  - Falloff = `clamp(1 − horizontal_dist / slam_radius, 0, 1)` — горизонтальная, не 3D, иначе `hand_height` съел бы силу у близких целей.
  - Direction = `(horizontal + UP × slam_lift_factor).normalized()` (`_slam_direction_and_falloff`).
  - `Pushable.try_push(collider, dir × slam_force × falloff, slam_knockback_duration)`.
  - `Damageable.try_damage(collider, slam_damage × falloff)`.
- Визуал спавнится в `effects_root_path` (NodePath); если пуст или не резолвится — фолбэк на `_hand.get_tree().current_scene`. Главное — НЕ в `_hand`: иначе расширяющаяся сфера таскалась бы за рукой, эпицентр уезжал бы. Пул `_slam_visual_pool` (cap 3) переиспользует MeshInstance3D.
- `slammed.emit(origin, slam_radius)`.

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

**Скрипт `camera_rig.gd`:** без изменений. Простой Node3D-фолловер:
- `@export_node_path("Node3D") target_path: NodePath`.
- `@export follow_speed: float = 8.0`.
- В `_ready` снимает цель, мгновенно прыгает на её позицию (нет «въезда» с (0, 0, 0)).
- В `_process`: `global_position = global_position.lerp(target.global_position, follow_speed * delta)`.

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
- `attack_damage: float = 5.0` — урон цели при атаке.
- `attack_cooldown: float = 1.0` — секунды между атаками. Тикает всегда (в т.ч. в knockback'е).
- `attack_windup: float = 0.4` — длительность фазы WINDUP до удара.
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
- `apply_knockback(impulse, duration)` — внешний толчок. Заменяет горизонтальную velocity, накладывает вертикаль через `max`, взводит `_knockback_timer`, затем зовёт виртуальный `_on_knockback()` (хук подкласса для «сбить замах» и т.п.).
- `_apply_velocity_change(impulse, duration)` — низкоуровневая запись velocity + взвод таймера, **без** хука `_on_knockback`. Используется самим базовым классом (внутри `apply_knockback`) и подклассами для self-knockback (Skeleton lunge): свой же удар не должен дёргать хук «отмены состояний» и сбивать собственное FSM.
- `set_target(target)` / `set_targets(array)` — назначить кандидата(ов) в цели. Поле `_targets: Array[Node3D]`, AI каждый кадр через `get_active_target()` выбирает ближайшую живую (мёртвые `is_instance_valid → false` пропускаются автоматически, ручная чистка не нужна).
- `get_active_target() -> Node3D` — ближайшая валидная цель или `null`.

**`_ready` и обязательная регистрация контрактов:**
- В базовом `_ready` вызываются `Damageable.register(self)` и `Pushable.register(self)`, плюс re-emit'ы `damaged`/`destroyed` на `EventBus`.
- Подклассы, переопределяющие `_ready`, **обязаны** звать `super._ready()`. Иначе регистрация контрактов и подключение к EventBus тихо потеряются.
- Защита: первый `_physics_process` инстанса делает `assert(is_in_group(Damageable.GROUP))` и аналог для Pushable — забытый `super._ready()` падает с ассертом сразу.

**Виртуальные хуки:**
- `_perform_strike(target: Node3D)` — конкретный удар. Подкласс наносит урон и/или делает физический выпад. Вызывается базой ровно один раз в момент `WINDUP → STRIKE`, сразу после которого база сама переводит FSM в `COOLDOWN`.
- `_on_state_enter(new_state)` / `_on_state_exit(old_state)` — реакция на смену фазы FSM. Типичный кейс — телеграф замаха (Skeleton: подсветка вкл. на enter `WINDUP`, выкл. на exit).
- `_on_knockback()` — реакция на **внешний** толчок. Базовая реализация: только `WINDUP` сбрасывается в `APPROACH`. `COOLDOWN` намеренно **не** сбрасывается — кулдаун продолжает тикать в `_physics_process` независимо от knockback'а.
- `_on_destroyed()` — вызывается ровно перед `queue_free` на смерти, после `destroyed.emit`. Подклассы спавнят визуал смерти — он добавляется в `_effects_root` и переживает сам труп.

**Цикл (`_physics_process`):**
1. Ассерты Damageable/Pushable групп (поймать забытый `super._ready()`).
2. Гравитация → `velocity.y` (если не на полу), иначе обнуляется.
3. Декремент `_state_timer` для COOLDOWN — тикает всегда.
4. Если `_knockback_timer > 0` — AI заглушен, горизонтальная velocity лерпится к нулю по `knockback_friction × delta`, таймер декрементируется.
5. Иначе — зовётся `_ai_step(delta)` (в базе: APPROACH → WINDUP таймер → STRIKE через `_perform_strike` → COOLDOWN таймер).
6. Запоминается `pre_slide_velocity := velocity`, далее `move_and_slide()`.
7. Если в knockback'е — `_resolve_knockback_contacts(pre_slide_velocity)`:
   - Контакт с активной целью → нормали суммируются, после цикла применяется `_bounce_off_target` (elastic-отскок с `bounce_restitution`, считается через **pre-slide** velocity).
   - Контакт с другим `Enemy` → `_push_neighbor`: соседу применяется push **через `Pushable.try_push`**. Минимальный порог `MIN_NEIGHBOR_PUSH_SPEED = 0.5` отсеивает «соскользили вдоль» от «врезались».
   - Self-bounce от цели **не** идёт через Pushable: это собственная реакция инстанса на коллизию, не внешний толчок, и `_on_knockback` дёргать незачем.

**Зависимости:** только физика, `Damageable`/`Pushable`/`Layers`/`VecUtil` и наследники. Не знает про Tower, Hand, Item.

#### 5.5.2 Skeleton + ShatterEffect — `scenes/skeleton.tscn`, `scripts/skeleton.gd`, `scripts/shatter_effect.gd`

**Тип корня:** `CharacterBody3D` с `class_name Skeleton extends Enemy`.

**Назначение:** простейший враг — конкретизация базы. Идёт к ближайшей живой цели, в `attack_range` входит в `WINDUP` (телеграф), на завершении замаха выполняет физический выпад с уроном. Большая часть логики унаследована от `Enemy`; подкласс заполняет три слота: визуал замаха (через хуки состояний), сам удар (`_perform_strike`) и эффект смерти (`_on_destroyed`).

**Дочерние узлы:**
- `CollisionShape3D` — `CapsuleShape3D` r=0.4, h=2.
- `MeshInstance3D` — `CapsuleMesh` того же размера.

**Слой/маска (в `.tscn`):** `collision_layer = 16` (Enemies), `collision_mask = 55` (Terrain + Items + Actors + Enemies + CampObstacle).

**Override на инстансе:** `move_speed = 2.7` (медленнее общего дефолта Enemy=4.0).

**Экспорты:**
- Группа **Strike (физический выпад):**
  - `lunge_speed: float = 8.0` — m/s в момент удара (выше `move_speed`).
  - `lunge_duration: float = 0.2` — длительность knockback'а на сам выпад.
- Группа **Shatter (рассыпание на смерти):**
  - `shatter_fragment_count: int = 7`.
  - `shatter_lifetime: float = 2.0` (секунды).
  - `shatter_color: Color` — цвет осколков (дефолт = цвет тела).

**Константы:** `BODY_ALBEDO_COLOR`, `WINDUP_EMISSION_COLOR`, `WINDUP_EMISSION_INTENSITY`. Per-instance тонкая настройка цвета не предусмотрена.

**Static shared materials (батчинг GPU):**

```gdscript
static var _shared_normal_material: StandardMaterial3D
static var _shared_windup_material: StandardMaterial3D
```

Создаются **один раз на класс** через `_ensure_shared_materials()` в первом `_ready`. Все скелеты делят два материала на класс — никаких `.duplicate()` per-instance. Переключение состояния = смена ссылки в `_mesh.material_override` → GPU батчит 50 скелетов в один draw call на состояние.

**`_ready`:** `super._ready()` (обязателен), затем `_ensure_shared_materials()` и `_mesh.material_override = _shared_normal_material`.

**Override'ы базы:**
- `_on_state_enter(new_state)`: на `AttackState.WINDUP` → `_set_glow(true)`.
- `_on_state_exit(old_state)`: на выходе из `WINDUP` → `_set_glow(false)` (включая случай отмены замаха через базовый `_on_knockback`).
- `_perform_strike(_target)`: перевыбирает цель через `get_active_target()` (между `_ai_step` и `_perform_strike` цель могла умереть). Если живых нет — выходим. Иначе: `Damageable.try_damage(active, attack_damage)` (через контракт, **не** `has_method`/`call`), затем `_do_lunge(active)`.
- `_do_lunge(target)`: считаем горизонтальное направление к цели; **`_apply_velocity_change(dir × lunge_speed, lunge_duration)`**, а не `apply_knockback`. Свой собственный strike через `apply_knockback` дёрнул бы `_on_knockback` хук, который сбил бы только что выставленное состояние.

**Жизненный цикл (на уровне FSM базы):** APPROACH → WINDUP (`attack_windup` сек, красная подсветка через свап `material_override`) → STRIKE (зовётся `_perform_strike`, наносит урон + self-lunge через `_apply_velocity_change`) → COOLDOWN (`attack_cooldown` сек, тикает даже в knockback'е) → APPROACH.

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

**Назначение:** по input action порождает партию врагов кольцом вокруг цели. Распределяет спавн по нескольким физкадрам — без фрейм-спайка на старте волны.

**Экспорты:**
- `enemy_scenes: Array[PackedScene]` — типы врагов. Параллелен `enemy_counts`.
- `enemy_counts: Array[int]` — сколько каждого типа породить за волну.
- `target_path: NodePath` (`@export_node_path("Node3D")`) — кого ставить в `set_target` каждому врагу.
- `spawn_root_path: NodePath` (`@export_node_path("Node")`) — куда добавлять врагов как детей. Пустой → фолбэк на `get_tree().current_scene`.
- `spawn_radius: float = 25.0` — радиус кольца от цели.
- `spawn_radius_jitter: float = 0.3` — разброс ±jitter от радиуса (1 = ±50%).
- `spawn_height_offset: float = 1.0` — смещение по Y относительно цели (раньше был литералом).
- `debug_log: bool = true`.

**Внутренние константы:** `_SPAWNS_PER_FRAME: int = 6` — сколько спавнов в одном физкадре. `_CENTER_INVALID := Vector3.INF` — sentinel «target/spawner протухли, прерываемся».

**Логика:**
- В `_ready` резолвятся `_target` (по `target_path`) и `_spawn_root` (по `spawn_root_path` или фолбэк на `current_scene`).
- В `_process` ловит `Input.is_action_just_pressed("spawn_enemies")` → `spawn_wave()`.
- `spawn_wave()` сначала валидирует: размеры массивов совпадают, `_target` и `_spawn_root` живы. Затем для каждого `type_index` × `count`: инстанцирует, кастует к `Enemy`, кладёт в `_spawn_root`, выставляет позицию (угол × `spawn_radius × jitter`, Y = `target.y + spawn_height_offset`), зовёт `set_target(_target)`.
- Каждые `_SPAWNS_PER_FRAME` итераций — `await _yield_frame_and_recenter()`.

**Helper `_yield_frame_and_recenter()`:**

```gdscript
func _yield_frame_and_recenter() -> Vector3:
    await get_tree().physics_frame
    if not is_inside_tree():
        return _CENTER_INVALID
    if not is_instance_valid(_target):
        return _CENTER_INVALID
    return _target.global_position
```

Один общий хелпер устранил копипаст блока `await physics_frame` + проверка валидности target + проверка что сам спавнер ещё в дереве.

**TODO:** когда количество волн перевалит за 2 — заменить параллельные массивы `enemy_scenes` / `enemy_counts` на `Array[WaveEntry: Resource]`.

**Зависимости:** только PackedScene и Node3D через NodePath. Спавнер не знает ни типа конкретного врага по имени, ни тип цели; их типы заданы из `main.tscn` на инстансе.

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

### 5.7 Camp — `scenes/camp.tscn`, `scripts/camp.gd`

**Тип корня:** `Node3D` с `class_name Camp`.

**Назначение:** модуль «лагеря» — несколько палаток (`StaticBody3D`), в режиме каравана следующих за башней цепочкой. По зажатию `R` (при неподвижной башне) лагерь разворачивается вокруг текущей позиции башни в кольцо палаток-блокаторов. В развёрнутом состоянии лагерь спавнит **гномов** (см. §5.8) — те бродят, ищут `ResourcePile` (см. §5.9) и носят ресурсы к anchor'у. Повторное зажатие `R` инициирует свёртку: гномы возвращаются в палатки, и только после прихода всех лагерь снова становится караваном. Зависит от Tower через `target_path`.

**Дочерние узлы:**
- 4× `StaticBody3D` (`CaravanPart1..CaravanPart4`), каждая с `CollisionShape3D` 2×1.5×1.5 и `MeshInstance3D` (общий `Material_part` SubResource — один draw call на лагерь).
- Стартовые позиции — линия позади origin'а Camp (`x = 0, −3, −6, −9`).
- `collision_layer = 32` (`CampObstacle`, бит 5) **в обоих состояниях** — статически в `.tscn`, рантайм его не меняет. `collision_mask = 0` — палатки сами ничего не сканируют.
- В `gnome_scene` экспорте сцены прокидывается `gnome.tscn`.

**Экспорты:**
- `target_path: NodePath` (`@export_node_path("Node3D")`) — за кем следует караван. Обычно Tower.
- `part_nodes: Array[StaticBody3D]` — палатки в порядке цепочки. Прокидываются вручную в инспекторе. Если массив пуст — `_ready` заполнит `_parts` через `get_children()` с фильтром по имени `CaravanPart*` (фолбэк).
- `follow_speed: float = 4.0` — **decay-коэффициент** (log-rate) экспоненциального следования палаток. **Не зависит от dt** (см. `_exp_decay`).
- `part_gap: float = 2.5` — целевая дистанция между соседними палатками.
- `follow_max_distance: float = 30.0` — «зона видимости».
- `deploy_duration: float = 3.0` — секунды зажатой `R` при неподвижной башне для развёртки.
- `pack_duration: float = 4.0` — секунды зажатой `R` в развёрнутом состоянии для свёртки.
- `deploy_radius: float = 4.0` — радиус кольца палаток вокруг anchor.
- `stationary_threshold: float = 0.01` — порог смещения **позиции** цели за кадр, ниже которого считаем её неподвижной (раньше читалась `velocity` у CharacterBody3D — теперь `_tower` хранится как `Node3D`, и неподвижность определяется через эпсилон-чек delta-position).
- Группа **Gnomes:**
  - `gnome_scene: PackedScene` — сцена гнома (см. §5.8).
  - `gnomes_per_tent: int = 2` — сколько гномов спавнить на каждую палатку.
- `debug_log: bool = true`.

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
- `_state: State`, `_parts: Array[StaticBody3D]`, `_deploy_anchor: Vector3`, `_deployed_targets: Array[Vector3]`.
- `_deploy_hold: float`, `_pack_hold: float` — раздельные таймеры удержания `R`. Раньше был один `_hold_progress` на оба перехода.
- `_last_target_pos: Vector3 = Vector3.INF` — позиция башни на прошлом кадре.
- `_gnomes: Array[Gnome]` — гномы лагеря (создаются в `_spawn_gnomes`).
- `deploy_anchor: Vector3` — публичное property (геттер возвращает `_deploy_anchor`). Гномы читают, чтобы знать, куда нести ресурс.

**`_ready`:** резолвит `_tower` через `target_path`; собирает `_parts` из `part_nodes` (или фолбэк); `_spawn_gnomes()`; подключает re-emit на EventBus.

**`_spawn_gnomes`:** для каждой палатки `gnomes_per_tent` раз инстанцирует `gnome_scene`, кастует к `Gnome`, кладёт ребёнком Camp, ставит в позицию палатки и вызывает `gnome.setup(self, tent)`.

**Логика follow (`_update_caravan_follow`):**
- Distance-gate: если `parts[0].distance_to(tower) > follow_max_distance` — ведущая стоит, остальные подтягиваются к своим лидерам.
- Цепочка: `target = leader_pos − dir × part_gap`. Y цели — через `_ground_y_at(part, target_pos)`: raycast по `Layers.TERRAIN`. Палатки следуют рельефу.
- Сглаживание — **`_exp_decay`** (статический helper): `target + (current - target) * exp(-decay * delta)`. Покадрово стабильное, в отличие от прошлого `lerp(a, b, follow_speed × delta)` (frame-зависимый).

**Логика DEPLOYED (`_update_deployed`):** каждая палатка `_exp_decay` к своей `_deployed_targets[i]` (точка кольца).

**Логика свёртки (двухфазная):**
1. `_pack_hold ≥ pack_duration` → `_start_pack()`:
   - `_state = PACKING_RETURNING`, локальный сигнал **не** эмитится (пока).
   - Вызов `g.request_return()` для каждого гнома.
   - Палатки продолжают `_update_deployed` (стоят на местах кольца).
2. Каждый кадр в `_process` при `PACKING_RETURNING`: проверка `_all_gnomes_home()`. Если да — `_finalize_pack()`: `_state = CARAVAN_FOLLOWING`, эмит `packed`. Палатки возобновляют follow с текущих позиций — без teleport'а.

**Логика развёртки (`_handle_input` в `CARAVAN_FOLLOWING`):**
- Пока зажата `R` И `_is_tower_stationary()` — `_deploy_hold += delta`. Любое движение башни или отпускание `R` → сброс.
- На `_deploy_hold ≥ deploy_duration` → `_start_deploy()`: `_deploy_anchor = tower.global_position`; для каждой палатки считается своя `_deployed_targets[i]`; `_state = DEPLOYED`; эмит `deployed(anchor)`.
- Вызов `g.enter_deployed()` для каждого гнома → выходит из палатки, `_state = SEARCHING`.

**`_is_tower_stationary`:** `_tower != null` и delta-position на горизонтали `< stationary_threshold`. Не зависит от того, что цель — `CharacterBody3D`; работает с любым `Node3D`.

**Дележ куч между гномами (`is_pile_claimed`):**

```gdscript
func is_pile_claimed(pile: ResourcePile, exclude_gnome: Gnome = null) -> bool
```

Возвращает `true`, если кучу уже нацелил какой-то гном, отличный от `exclude_gnome`. Гном-сканер пропускает claimed-кучи — каждый ищет «своё», нашедший один не созывает остальных.

**Логирование (`debug_log=true`, фронт-триггеры):** «начат отсчёт развёртки», «отсчёт прерван (отпущена R)» / «(башня поехала)», «лагерь развёрнут @ (...)», «свёртка инициирована — ждём гномов», «лагерь свёрнут (все гномы дома)».

**Внешние зависимости:** Tower через `target_path` (читается только `global_position`). Тип `Gnome` (для `_gnomes` массива и API). Тип `ResourcePile` (для сигнатуры `is_pile_claimed`). `Layers.TERRAIN` для raycast'а пола под палатками.

---

### 5.8 Gnome — `scenes/gnome.tscn`, `scripts/gnome.gd`

**Тип корня:** `CharacterBody3D` с `class_name Gnome`.

**Назначение:** обитатель лагеря. Спавнится `Camp` по `gnomes_per_tent` штук на каждую палатку. Сам ищет ресурсы (двухфазная FSM: поиск глазами + патруль / челнок к найденной куче), сам носит их к anchor'у лагеря. По сигналу свёртки — возвращается в свою палатку.

**Дочерние узлы:**
- `CollisionShape3D` — `CapsuleShape3D` r=0.25, h=0.7.
- `MeshInstance3D` — `CapsuleMesh` того же размера.
- (рантайм) `_carry_visual: MeshInstance3D` — маленький зелёный куб над головой при подборе, `queue_free` при дропе.

**Слой/маска:** `collision_layer = 0`, `collision_mask = 1` (только Terrain). Гномы проходят сквозь башню, врагов, предметы и друг друга — не толкаются и не блокируют игрока. Гравитация — единственное физическое взаимодействие.

**Экспорты:**
- Группа **Movement:** `move_speed: float = 1.6`, `gravity: float = 20.0`.
- Группа **Behaviour:**
  - `search_radius: float = 300.0` — радиус патруля от anchor'а (карта 200×200, радиус нарочно покрывает всю карту).
  - `vision_radius: float = 10.0` — дальность зрения. Куча в этом радиусе считается «увиденной» во время патруля.
  - `idle_radius: float = 4.0` — радиус ошивания возле anchor'а, когда куч на карте нет.
  - `pickup_distance: float = 0.8`, `deposit_distance: float = 1.2`, `home_distance: float = 0.8`, `wander_arrival: float = 0.6`.
- Группа **Visual:** `gnome_color`, `carry_color`, `carry_visual_size`.
- `debug_log: bool = false` — по умолчанию выключен.

**FSM:**

```gdscript
enum State {
    IN_TENT, SEARCHING, COMMUTING_TO_PILE, COMMUTING_TO_BASE,
    IDLE_NEAR_BASE, RETURNING_TO_TENT,
}
```

- `IN_TENT` — приклеен к `_home_tent.global_position`, `visible = false`. Состояние по умолчанию (караван).
- `SEARCHING` — фаза 1 поиска.
- `COMMUTING_TO_PILE` / `COMMUTING_TO_BASE` — фаза 2 «челнок» с найденной кучей.
- `IDLE_NEAR_BASE` — куч на карте нет, ошивается возле anchor'а в `idle_radius`.
- `RETURNING_TO_TENT` — лагерь свёртывается, идёт к своей палатке. Carry-визуал дропается сразу.

**Поля:** `_camp: Camp`, `_home_tent: Node3D`, `_state: State`, `_assigned_pile: ResourcePile`, `_wander_target: Vector3`, `_carry_visual: MeshInstance3D`.

**API для Camp:**
- `setup(camp, home_tent)` — кэширует ссылки, входит в `IN_TENT`.
- `enter_deployed()` — `visible = true`, `_state = SEARCHING`.
- `request_return()` — дропает carry, `_state = RETURNING_TO_TENT`.
- `is_home() -> bool` — `_state == IN_TENT`.
- `get_assigned_pile() -> ResourcePile` — возвращает `_assigned_pile` если гном сейчас в фазе челнока, иначе `null`. Camp использует в `is_pile_claimed`.

**Двухфазная логика сбора:**

| Шаг | Условие | Действие |
|---|---|---|
| 1. Поиск (SEARCHING) | каждый кадр | `_scan_vision()`: ближайшая куча в `vision_radius` от **позиции гнома**, не пустая, не `freeze`, не claimed чужим. |
| 2. Найдено | `spotted != null` | `_assigned_pile = spotted` → `COMMUTING_TO_PILE`. |
| 3. Не нашёл, кучи в мире нет | `_world_has_any_pile() == false` | → `IDLE_NEAR_BASE`. |
| 4. Не нашёл, кучи где-то есть | иначе | патруль: новая `_wander_target` через `_random_point_around(anchor, search_radius)`. |
| 5. Челнок к куче | `COMMUTING_TO_PILE` | если `_assigned_pile.units > 0` и не `freeze` — идём к ней. На `pickup_distance` зовём `take_one()`; успех → carry-визуал, `COMMUTING_TO_BASE`. Провал/потеря → `_on_pile_lost()` → SEARCHING. |
| 6. К базе | `COMMUTING_TO_BASE` | идём к `_camp.deploy_anchor`. На `deposit_distance` дропаем carry. Если `_assigned_pile` ещё валиден и `units > 0` — снова в `COMMUTING_TO_PILE`. Иначе → SEARCHING. |

**Skip frozen-куч:** во `_scan_vision` и в `_tick_commuting_to_pile` явно проверяется `pile.freeze` — рука держит кучу, гном считает её недоступной. Контракт: пока кучу схватили рукой, гномы не топчут к ней зря и переходят в SEARCHING (`_on_pile_lost`).

**Зависимости:** типы `Camp` (через ссылку из `setup`, читает `deploy_anchor`, `is_pile_claimed`) и `ResourcePile`. Не знает Tower/Hand/Skeleton.

---

### 5.9 ResourcePile — `scenes/resource_pile.tscn`, `scripts/resource_pile.gd`

**Тип корня:** `RigidBody3D` с `class_name ResourcePile`.

**Назначение:** куча ресурсов на карте. Гномы забирают по 1 единице через `take_one()` в фазе сбора. Параллельно куча — полноценный физический предмет: рука может схватить её и кинуть, башня и Item могут толкнуть, slam ломает по hp. Реализует **три** контракта одновременно: `Damageable`, `Pushable`, `Grabbable`.

**Дочерние узлы:**
- `MeshInstance3D` — пустой в `.tscn`, в `_apply_visual` создаётся `BoxMesh` `pile_size`.
- `CollisionShape3D` — пустой в `.tscn`, в `_apply_shape` создаётся `BoxShape3D` `pile_size`.

**Слой/маска (в `.tscn`):** `collision_layer = Layers.ITEMS` (бит 2), `collision_mask = Layers.MASK_ALL_GAMEPLAY = 31`. Та же раскладка, что у `Item`.

**Экспорты:**
- `units: int = 5` — запас ресурсов; декрементируется при `take_one()`. На 0 — `queue_free`.
- `hp: float = 30.0` — здоровье. Урон от руки/slam'а. На 0 — `queue_free` независимо от `units`.
- `pile_color: Color`, `pile_size: Vector3`, `highlight_color: Color`, `highlight_intensity: float`.
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
| Damageable | `take_damage(amount)` | Декремент `hp`, эмит `damaged`. На `hp ≤ 0` — `destroyed.emit()` + `queue_free()`. Защита через `is_queued_for_deletion()`. |
| Pushable | `apply_push(velocity_change, _duration)` | `apply_central_impulse(velocity_change × mass)`. **Return при `freeze`**. |
| Grabbable | `set_highlighted(value)` | Toggle emission. Дёргается рукой на смене кандидата. |

**Метод для гномов (`take_one`):**

```gdscript
func take_one() -> bool:
    if freeze or units <= 0 or is_queued_for_deletion():
        return false
    units -= 1
    if units == 0:
        destroyed.emit()
        queue_free()
    return true
```

`freeze` (рука держит) → `false`. Гном считает кучу «занятой» и через `_on_pile_lost` уходит искать другую.

**Размещение в `main.tscn`:** в группе `Resources` (Node3D-контейнер) **20 ResourcePile-инстансов** в трёх кольцах от origin: радиусы ~30, 50, 70.

**Зависимости:** `Damageable`, `Pushable`, `Grabbable`, `EventBus`, `Layers`. Не знает Gnome/Camp напрямую — связь через группу и публичные поля.

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
| `camp_toggle` | R | Camp (зажать для развёртки/свёртки) |

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
    - **Семантика в EventBus.** Через bus гномы и кучи ничего нового не эмитят. ResourcePile использует уже существующие `EventBus.item_damaged/item_destroyed` — куча по контракту неотличима от Item для cross-cutting слушателей (UI/счёт ресурсов разнесёт их при необходимости через `target is ResourcePile`).

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
| EnemySpawner | — | `Input "spawn_enemies"`, `Array[PackedScene]` + `target_path` + `spawn_root_path` из `main.tscn` |
| Hand | сигналы `grabbed(item: Node3D)/released(item: Node3D, velocity)` (re-emit из PhysicalActions); публичный API: `lock_position(bool)`, `set_locked_position(pos)`, `cursor_world_position()`, `smoothed_velocity()`, `get_grabbable_bodies()/get_magnet_bodies()`, `register_raycast_excluder(Callable)` | активная камера; никаких конкретных game-классов |
| Hand:PhysicalActions | сигналы `grabbed/released/slammed/flicked(target: Node3D, velocity)`, методы `get_held_item()/is_holding()/find_grab_candidate()/find_flick_target()`, `@export equipped: AbilityType` | Input `hand_grab/hand_action/equip_slam/equip_flick`; Hand через `setup` цепочку. Цели — через `Damageable.is_damageable / Grabbable.is_grabbable / Pushable.try_push`, а не через `is Item / is Enemy` |
| Hand:SpellActions | сигнал `spell_cast(name, position)` (черновик) | родитель Hand через `setup(hand)` |
| Camp | сигналы `deployed(anchor: Vector3)/packed`, экспорт `target_path/part_nodes/gnome_scene`, публичные `deploy_anchor: Vector3` (свойство) и `is_pile_claimed(pile, exclude_gnome)` | Input `camp_toggle`, читает `Tower.global_position` (delta-position для stationary-чека); зовёт `Gnome.enter_deployed/request_return/is_home/get_assigned_pile` |
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
| `hand_grabbed` | `(item: Node3D)` | `Hand._ready` re-emit |
| `hand_released` | `(item: Node3D, velocity: Vector3)` | `Hand._ready` re-emit |
| `hand_slammed` | `(position: Vector3, radius: float)` | `HandPhysicalActions._ready` re-emit |
| `hand_flicked` | `(target: Node3D, velocity: Vector3)` | `HandPhysicalActions._ready` re-emit |
| `camp_deployed` | `(anchor: Vector3)` | `Camp._ready` re-emit |
| `camp_packed` | — | `Camp._ready` re-emit |

`Gnome` и `ResourcePile.take_one` через шину **не эмитят**. Гномы — внутренняя механика лагеря, спавнятся в Camp напрямую; декремент `units` куч пока не нужен наружу (счётчика ресурсов ещё нет). При появлении HUD-счётчика добавится отдельный сигнал — типизированный как `Node3D`, как и остальные.

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
