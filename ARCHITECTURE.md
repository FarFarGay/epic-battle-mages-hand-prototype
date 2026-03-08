# Epic Battle Mages — Архитектура проекта

**Версия:** 1.0
**Дата:** 2026-03-08
**Статус:** Черновик

---

## 1. Контекст

Epic Battle Mages — стратегический рогалик с физикой и процедурной картой.
Жанр: Slay the Spire + FTL + Noita. Одна сессия — 60–90 минут.

**Технологический стек:** уточняется (прототип — Vanilla HTML5 Canvas; рассматривается Godot)

---

## 2. Ключевые принципы

1. **Data-driven** — баланс, заклинания, взаимодействия тайлов — в данных, не в коде
2. **ECS** (Entity-Component-System) — все объекты мира собираются из компонентов
3. **Event Bus** — необратимые изменения мира идут через события, без прямых зависимостей
4. **Стейт-машины** — для руки, башни, миньонов, предметов, фаз боя
5. **Без хардкода формул** — все числа баланса в конфигурационных файлах

---

## 3. Структура проекта

```
epic-battle-mages/
├── core/
│   ├── ecs/              # Entity, Component, System — базовые классы
│   ├── events/           # EventBus
│   ├── physics/          # PhysicsSystem (общая для всего, что летит)
│   └── state_machine/    # Базовый класс StateMachine
│
├── world/
│   ├── map/              # TileSystem, MapGenerator, FogOfWar
│   ├── regions/          # RegionConfig, ResourceSpawner
│   └── camera/           # IsometricCamera (zoom, shake, проекции)
│
├── entities/
│   ├── tower/            # TowerSystem, FloorSystem, LeashSystem
│   ├── minions/          # MinionSystem, BehaviorTree
│   ├── hand/             # HandSystem, GrabSystem, SpellCastSystem
│   └── items/            # ItemSystem, ItemPhysics
│
├── spells/
│   ├── crafting/         # SpellCraftingSystem (Form + Element + Intent)
│   ├── artillery/        # ArtillerySystem, Ballistics
│   └── effects/          # ElementInteractionSystem
│
├── data/
│   ├── forms.json
│   ├── elements.json
│   ├── intents.json
│   ├── tile_interactions.json
│   ├── synergies.json
│   ├── items.json
│   ├── minion_equipment.json
│   └── regions.json
│
├── rendering/
│   ├── IsoRenderer       # Изометрическая проекция
│   ├── DepthSorter       # Сортировка по глубине (ix + iy)
│   ├── PixelArtRenderer  # Pixel-art, масштаб ×3
│   └── EffectsRenderer   # Тени, подсветка, тряска экрана
│
└── ui/
    ├── hud/
    ├── spellbook/
    └── minimap/
```

---

## 4. Система заклинаний-снарядов

Главная механика — полностью data-driven. Три независимые оси.

### 4.1 Структура данных

**forms.json** — физический носитель снаряда
```json
[
  { "id": "arrow", "name": "Стрела",  "area": 1, "dmgMult": 1.5, "manaMult": 1.0, "range": 12 },
  { "id": "shell", "name": "Снаряд", "area": 3, "dmgMult": 1.0, "manaMult": 1.2, "range": 8  },
  { "id": "shot",  "name": "Дробь",  "area": 6, "dmgMult": 0.4, "manaMult": 0.8, "range": 6  }
]
```

**elements.json** — субстанция и визуал
```json
[
  { "id": "fire",  "name": "Огонь", "baseMult": 1.0, "color": "#e74c3c", "vfx": "fire_particle" },
  { "id": "water", "name": "Вода",  "baseMult": 1.0, "color": "#3498db", "vfx": "water_particle" },
  { "id": "earth", "name": "Земля", "baseMult": 1.0, "color": "#8B7355", "vfx": "earth_particle" }
]
```

**intents.json** — игровой эффект
```json
[
  { "id": "destroy",  "name": "Уничтожить", "baseDmg": 200, "baseMana": 80 },
  { "id": "protect",  "name": "Защитить",   "baseDmg": 0,   "baseMana": 50 },
  { "id": "see",      "name": "Увидеть",    "baseDmg": 0,   "baseMana": 35 }
]
```

### 4.2 Формула урона

```
finalDmg = baseDmg × dmgMult × elementMult × tileMult × synergyBonus
finalMana = baseMana × manaMult
```

Все множители — в данных. Код не знает конкретных чисел.

### 4.3 Таблица взаимодействий со стихиями

**tile_interactions.json** — одна таблица на все случаи
```json
{
  "fire": {
    "forest":  { "mult": 1.8, "effect": "burn",    "spread": true  },
    "water":   { "mult": 0.3, "effect": "steam",   "spread": false },
    "stone":   { "mult": 1.0, "effect": "melt",    "spread": false },
    "village": { "mult": 1.8, "effect": "destroy", "spread": false },
    "ice":     { "mult": 0.5, "effect": "thaw",    "spread": false },
    "plain":   { "mult": 1.0, "effect": "burn",    "spread": false }
  },
  "water": {
    "forest":  { "mult": 1.0, "effect": "growth",  "spread": false },
    "water":   { "mult": 1.0, "effect": "flood",   "spread": true  },
    "stone":   { "mult": 0.3, "effect": "erosion", "spread": false },
    "village": { "mult": 1.8, "effect": "harvest", "loyalty": 10   },
    "ice":     { "mult": 1.8, "effect": "expand",  "spread": true  },
    "plain":   { "mult": 1.0, "effect": "swamp",   "spread": false }
  },
  "earth": {
    "forest":  { "mult": 0.5, "effect": "roots",   "spread": false },
    "water":   { "mult": 1.8, "effect": "swamp",   "spread": false },
    "stone":   { "mult": 1.8, "effect": "reinforce","spread": false },
    "village": { "mult": 1.0, "effect": "fortify", "spread": false },
    "ice":     { "mult": 0.5, "effect": "collapse", "spread": false },
    "plain":   { "mult": 1.0, "effect": "wall",    "spread": false }
  }
}
```

Добавление новой стихии = одна новая запись в этом файле. Нет изменений в коде.

### 4.4 Именованные синергии

**synergies.json** — открываются игроком, не задокументированы в UI
```json
[
  { "key": "arrow_fire_destroy",  "name": "Драконье Копьё",    "bonus": 1.2 },
  { "key": "shell_water_destroy", "name": "Потоп",             "bonus": 1.2 },
  { "key": "shell_earth_protect", "name": "Крепость",          "bonus": 1.2 },
  { "key": "shot_fire_destroy",   "name": "Армагеддон",        "bonus": 1.2 },
  { "key": "arrow_earth_destroy", "name": "Пробойник",         "bonus": 1.2 },
  { "key": "shell_fire_destroy",  "name": "Напалм",            "bonus": 1.2 },
  { "key": "shot_water_destroy",  "name": "Ледниковый Период", "bonus": 1.2 },
  { "key": "shot_earth_see",      "name": "Сеть Стража",       "bonus": 1.2 },
  { "key": "shell_water_protect", "name": "Ледяная Крепость",  "bonus": 1.2 }
]
```

### 4.5 SpellCraftingSystem

```
SpellCraftingSystem.craft(formId, elementId, intentId):
  form    = load("forms.json")[formId]
  element = load("elements.json")[elementId]
  intent  = load("intents.json")[intentId]
  key     = formId + "_" + elementId + "_" + intentId
  synergy = load("synergies.json").find(key)  // null если нет
  → SpellProjectile { form, element, intent, synergy }
```

---

## 5. Физическая система

Единый `PhysicsSystem` обрабатывает всё что летит: снаряды, миньонов, предметы.
Параметры объекта — в его данных, логика физики — в системе.

### 5.1 PhysicsComponent

```
PhysicsComponent {
  ix, iy, iz       // изометрическая позиция (iz — высота)
  vx, vy, vz       // скорость по трём осям
  mass             // масса (влияет на бросок и тряску экрана)
  bounciness       // коэффициент отскока (0.0 – 1.0)
  friction         // трение при скольжении
  airResistance    // сопротивление воздуха (по умолчанию 0.99)
}
```

### 5.2 Константы физики

Все в конфиге — не в коде:

```
GRAVITY           = 8.0     // ед/с²
CARRY_HEIGHT      = 1.5     // высота переноса
LIFT_SPEED        = 4.0     // скорость подъёма
THROW_VZ_BASE     = 3.0     // базовый вертикальный импульс при броске
THROW_SCALE       = 1.5     // множитель скорости руки → скорость броска
BOUNCE_MIN_VZ     = 0.3     // минимальный vz для отскока
MAX_BOUNCES       = 5       // максимум отскоков
SLIDE_STOP        = 0.05    // порог остановки скольжения
HEIGHT_TO_SCREEN  = 40      // пикселей на единицу высоты
VELOCITY_HISTORY  = 10      // кадров для усреднения скорости броска
MAX_THROW_SPEED   = 8.0     // максимальная скорость броска
WALL_BOUNCE       = 0.6     // коэффициент отскока от стен
```

### 5.3 Стейт-машина предметов / снарядов

```
idle → lifting → carried → thrown ─┬→ bouncing → sliding → settling → idle
                                    └→ sliding  → settling → idle
```

| Состояние  | Поведение |
|------------|-----------|
| `idle`     | На земле, iz=0, ожидание |
| `lifting`  | easeOut подъём к CARRY_HEIGHT, движение к руке |
| `carried`  | Следует за рукой |
| `thrown`   | Гравитация, горизонтальное движение, сопротивление воздуха |
| `bouncing` | vz инвертируется × bounciness, vx/vy × friction |
| `sliding`  | Экспоненциальное трение на земле |
| `settling` | Пауза 0.15с перед переходом в idle |

### 5.4 Тряска экрана

Запускается через Event Bus при первом ударе о землю:
```
intensity = mass × |vz| × 0.5
max       = 15px
decay     = экспоненциальное затухание
```

---

## 6. Рука мага

### 6.1 HandSystem

- Рука = курсор мыши, плавная интерполяция (`lerp = 1 - 0.001^dt`)
- Системный курсор скрыт, заменён маркером 3×3px
- Радиус захвата: 1.5 изо-единицы (для летящих предметов: только iz < 2.0)

### 6.2 Стейт-машина руки

```
open → closing → closed → opening → open
```

### 6.3 Трекинг скорости для броска

Хранение последних N кадров скорости (`VELOCITY_HISTORY = 10`).
Взвешенное среднее: последние кадры важнее. Учёт массы предмета.

### 6.4 Улучшения руки (items.json)

Экипировка руки как data-объекты, не хардкод:
```json
[
  { "id": "ring_fire",    "slot": "ring",     "spellMult": 1.15, "element": "fire"  },
  { "id": "gauntlet_iron","slot": "glove",    "physDmg":   +20,  "armorBreak": true },
  { "id": "bracelet_mana","slot": "bracelet", "manaRegen": +5                       }
]
```

---

## 7. Башня

### 7.1 Компоненты башни

```
Tower Entity
  ├── TransformComponent      (ix, iy)
  ├── TowerStateComponent     (static | moving)
  ├── FloorListComponent      [floorId, ...]
  ├── VisibilityComponent     (radius = f(этажей))
  ├── LeashComponent          (maxLength, currentSpeed)
  └── ArtilleryComponent      (spellQueue[], cooldown)
```

### 7.2 Этажи

Каждый этаж — отдельная Entity с `FloorTypeComponent`:

```
floor_types.json:
[
  { "id": "barracks",    "minionCapacity": 10, "weight": 2.0 },
  { "id": "workshop",    "productionRate": 1.5, "weight": 1.5 },
  { "id": "watchtower",  "visibilityBonus": 3,  "weight": 1.0 },
  { "id": "storage",     "resourceCap": 200,    "weight": 1.0 }
]
```

Радиус обзора вычисляется автоматически: `baseRadius + sum(visibilityBonus)`.
Скорость башни: `baseSpeed / sqrt(totalWeight)`. Нет хардкода.

### 7.3 Два состояния башни

**Подвижное:** управление поводком через руку, атаки рукой, направление миньонов
**Статичное:** сбор ресурсов, крафт заклинаний, артиллерия, развитие башни

Переход между состояниями — через стейт-машину башни.

---

## 8. Миньоны

### 8.1 Компоненты миньона

```
Minion Entity
  ├── TransformComponent
  ├── PhysicsComponent        (масса зависит от брони)
  ├── EquipmentComponent      { weapon, armor, tool }
  ├── TaskComponent           { type, target, priority }
  ├── StatsComponent          { hp, dmg, speed, carryCapacity }
  └── StateComponent          (idle | moving | gathering | fighting | thrown | dead)
```

### 8.2 Роли через экипировку

Роль не enum — она следует из компонентов:

```
minion_equipment.json:
[
  { "id": "axe",         "slot": "weapon", "gatherBonus": 1.5 },
  { "id": "sword",       "slot": "weapon", "dmg": 15          },
  { "id": "iron_armor",  "slot": "armor",  "hp": +50, "surviveThrow": true },
  { "id": "pickaxe",     "slot": "tool",   "mineBonus": 2.0   }
]
```

Без брони — миньон разбивается при броске о стену. Железная броня = проникает в окна замка.

### 8.3 Задачи миньона (TaskComponent)

```
{ type: "explore",  target: enemy_castle_region }
{ type: "gather",   target: resource_node, returnTo: tower }
{ type: "fight",    target: enemy_minion }
{ type: "siege",    target: enemy_castle }
```

Система задач выбирает поведение из `TaskComponent` + `EquipmentComponent`. Нет if-else по ролям.

### 8.4 Потеря миньонов

При движении башни все миньоны в пути становятся «дикими» — отдельный статус в `StateComponent`.
Дикого миньона можно подобрать позже.

---

## 9. Карта

### 9.1 Тайлы

Тайл — чистый Data Object. Логика изменений — только в `TileSystem`.

```
Tile {
  id: string
  type: TileType (forest | water | stone | village | ice | plain)
  resourceYield?: number
  modified: boolean    // был ли изменён снарядом
}
```

### 9.2 TileSystem

Слушает события, применяет изменения из таблицы:

```
TileSystem.on(ProjectileHitEvent(projectile, tilePos)):
  interaction = tile_interactions[projectile.element][tile.type]
  applyEffect(interaction.effect, tilePos)
  if interaction.spread:
    scheduleSpread(tilePos, interaction)
  emit TileChangedEvent(tilePos, oldType, newType)
```

Все эффекты необратимы (флаг `modified = true`).

### 9.3 Туман войны

Два независимых слоя:

| Слой | Поведение |
|------|-----------|
| `explored[][]` | Постоянный. Обновляется при движении башни и разведке |
| `visible[][]`  | Динамический. Пересчитывается каждый кадр от позиции башни |

За пределами `visible` — топология видна, действия юнитов — нет.

### 9.4 Процедурная генерация

Каждый регион конфигурируется в данных:

```
regions.json:
[
  {
    "id": "volcano",
    "resources": [{ "type": "sulfur", "spawn": "fire_spells_only" }],
    "tileWeights": { "stone": 0.5, "plain": 0.3, "forest": 0.2 },
    "enemyDifficulty": 2
  }
]
```

Маршрут определяет арсенал. Алгоритм генерации получает конфиг региона — не хардкод тайлов.

---

## 10. Артиллерийская система

### 10.1 Баллистика снарядов

```
Projectile Entity
  ├── PhysicsComponent (масса из formId, гравитация влияет)
  ├── SpellComponent   { formId, elementId, intentId, synergyBonus }
  └── TrailComponent   (визуальный след)
```

Снаряд летит по физике. `PhysicsSystem` обрабатывает его наравне с предметами.
При попадании в тайл — `ProjectileHitEvent` → `TileSystem`.

### 10.2 Наведение

Требует разведчика у цели — без него артиллерия слепа.
Разведчик корректирует координаты (`TargetCorrectionEvent`).

### 10.3 Производство снарядов

Снаряды крафтятся из компонентов, привязанных к регионам:

```
crafting_recipes.json:
[
  { "spell": "fire_*",  "requiredResource": "sulfur",  "region": "volcano" },
  { "spell": "water_*", "requiredResource": "mercury",  "region": "lake"   },
  { "spell": "earth_*", "requiredResource": "ore",      "region": "mountains" }
]
```

---

## 11. Рендеринг

### 11.1 Изометрическая проекция

```
ISO_ANGLE    = π/4 (45°)
TILE_W       = 64px
TILE_H       = TILE_W × sin(45°) ≈ 45px
PIXEL_SCALE  = 3 (масштаб pixel-art)
```

Функции преобразования:
```
isoToScreen(ix, iy) → canvas (x, y)
screenToIso(sx, sy) → iso (ix, iy) с учётом зума камеры
worldToScreen(ix, iy) → screen (центрированный)
```

### 11.2 Глубинная сортировка

Все объекты рендера сортируются по `depth = ix + iy` перед отрисовкой.

### 11.3 Камера

```
CameraComponent {
  zoom:       float   (0.2 – 3.0)
  targetZoom: float   (плавная интерполяция)
  shakeOffset: vec2   (тряска, затухает экспоненциально)
}
```

### 11.4 Слои рендера

```
1. Пол (тайловая сетка)
2. Объекты мира (depth-sorted: тайловые эффекты, предметы, миньоны)
3. Башня и её этажи
4. Снаряды в полёте
5. Рука (всегда поверх мира)
6. Захваченный предмет (между миром и рукой)
7. UI (вне зума и тряски)
```

---

## 12. Event Bus

Все необратимые действия — через события. Модули не знают друг о друге.

### Ключевые события

| Событие | Источник | Подписчики |
|---------|----------|------------|
| `ProjectileHitEvent` | ArtillerySystem | TileSystem, FogOfWar, ScreenShake |
| `TileChangedEvent` | TileSystem | Renderer, MapState |
| `MinionThrownEvent` | HandSystem | PhysicsSystem, MinionSystem |
| `MinionLostEvent` | TowerSystem | MinionSystem, UI |
| `ResourceCollectedEvent` | MinionSystem, HandSystem | ResourceManager, UI |
| `TowerStateChanged` | TowerSystem | InputSystem, UISystem |
| `EnemyCastleFoundEvent` | MinionSystem (разведчик) | ArtillerySystem, UI |

---

## 13. Game Loop

```
GameLoop(dt):
  dt = min(dt, 0.05)   // не менее 20 FPS для стабильности физики

  InputSystem.update()
  HandSystem.update(dt)
  PhysicsSystem.update(dt)    // предметы, миньоны, снаряды
  MinionSystem.update(dt)
  TowerSystem.update(dt)
  TileSystem.update(dt)       // тик эффектов (горение, затопление)
  FogOfWarSystem.update()
  CameraSystem.update(dt)
  EventBus.flush()            // обработка накопленных событий

  Renderer.render()
```

---

## 14. Фазы боя

Стейт-машина битвы:

```
SETUP → ARTILLERY_DUEL → CLOSE_COMBAT → VICTORY/DEFEAT
```

| Фаза | Триггер | Доступные действия |
|------|---------|-------------------|
| `SETUP` | Начало региона | Крафт снарядов, подготовка миньонов |
| `ARTILLERY_DUEL` | Контакт с регионом | Разведка, обстрел, сбор ресурсов |
| `CLOSE_COMBAT` | Ресурсы на карте иссякли | Осада замка, рукопашная, прямые атаки рукой |
| `VICTORY` | Замок врага уничтожен / колдун убит | Разграбление, усиление |
| `DEFEAT` | Башня уничтожена | Game Over |

---

## 15. Масштабирование

### Добавление новых механик без изменения ядра

| Что добавить | Как |
|---|---|
| Новая стихия | Одна запись в `elements.json` + строка в `tile_interactions.json` |
| Новая форма снаряда | Одна запись в `forms.json` |
| Новый тип тайла | Строка в `tile_interactions.json` для каждой стихии |
| Новая синергия | Одна запись в `synergies.json` |
| Новый тип этажа | Запись в `floor_types.json` |
| Новое снаряжение миньона | Запись в `minion_equipment.json` |
| Новый регион | Запись в `regions.json` |

---

## 16. Известные ограничения текущего прототипа

(см. `Прототип руки/SPEC.md`)

- Нет коллизий между предметами
- Нет звуковых эффектов
- Один HTML-файл без модульной системы
- Только мышь + клавиатура (нет мобильного управления)

Все ограничения снимаются при переходе к полной архитектуре.
