// ============================================================
//  КОНСТАНТЫ ИГРЫ
// ============================================================
import {
    CUBE_PIXELS,
    WHEAT_PIXELS, WHEAT_W, WHEAT_H,
    WOOD_PIXELS, WOOD_W, WOOD_H,
    IRON_PIXELS, IRON_W, IRON_H,
    SCROLL_PIXELS, SCROLL_W, SCROLL_H,
} from './sprites.js';

// — Изометрическая проекция —
export const ISO_ANGLE       = Math.PI / 4; // 45 градусов
export const TILE_W          = 64;
export const TILE_H          = Math.round(TILE_W * Math.sin(ISO_ANGLE)); // ~45px при 45°
export const PIXEL_SCALE     = 3; // масштаб пикселей для pixel-art
export const CAMERA_OFFSET_Y = 40; // вертикальное смещение центра мира (px)

// — Физика —
export const GRAVITY         = 8.0;   // ед/с² вниз
export const CARRY_HEIGHT    = 1.5;   // высота переноса (мировые единицы)
export const LIFT_SPEED      = 4.0;   // скорость подъёма
export const THROW_VZ_BASE   = 3.0;   // базовый вертикальный импульс при броске
export const THROW_SCALE     = 1.5;   // множитель скорости руки → скорость броска
export const BOUNCE_MIN_VZ   = 0.3;   // минимальный vz для отскока
export const MAX_BOUNCES     = 5;     // максимум отскоков
export const SLIDE_STOP      = 0.05;  // порог остановки скольжения
export const HEIGHT_TO_SCREEN = 40;  // пикселей на единицу высоты
export const VELOCITY_HISTORY = 10;  // кадров для усреднения скорости
export const MAX_THROW_SPEED  = 8.0; // максимальная скорость броска (iso ед/с)
export const WALL_BOUNCE      = 0.6; // коэффициент отскока от стен
export const AIR_RESISTANCE   = 0.99; // коэффициент сопротивления воздуха (за 1/60 сек)

// — Миньоны —
export const MINION_SPEED    = 1.5;  // скорость блуждания миньона (iso ед/с)
export const MINION_MAX_HP   = 100;  // начальное здоровье гоблина
export const FALL_DMG_MED_VZ = 2.5;  // |vz| при ударе → средний урон
export const FALL_DMG_HI_VZ  = 5.0;  // |vz| при ударе → большой урон
export const FALL_DMG_MED    = 25;  // 25% от MINION_MAX_HP
export const FALL_DMG_HI     = 50;  // 50% от MINION_MAX_HP

// — Скелеты —
export const SKELETON_RISE_DELAY    = 3.0;  // секунд после смерти до воскрешения скелетом
export const SKELETON_SPEED_FACTOR  = 0.6;  // множитель скорости скелета относительно гоблина
export const SKELETON_MAX_HP        = 20;   // здоровье скелета (разрушается при 0)
export const SKELETON_AGGRO_RANGE   = 15.0; // дистанция обнаружения гоблина (iso-тайлы)
export const SKELETON_ATTACK_RANGE  = 0.6;  // дистанция удара (iso-тайлы)
export const SKELETON_ATTACK_DAMAGE = 15;   // урон за удар
export const SKELETON_ATTACK_CD     = 1.5;  // кулдаун между ударами (секунды)

// — Боевые характеристики гоблинов —
export const GOBLIN_ATTACK_DAMAGE  = 10;   // урон за удар
export const GOBLIN_ATTACK_CD      = 1.0;  // кулдаун между ударами (секунды)
export const GOBLIN_ATTACK_RANGE   = 0.6;  // дистанция удара (iso-тайлы)
export const GOBLIN_AGGRO_RANGE    = 10;   // дистанция обнаружения врагов (свободные гоблины)
export const GOBLIN_RALLY_RANGE    = 15;   // дистанция призыва на помощь при нападении

// — Классы гоблинов —
// 'basic'   — стандартный гоблин (реализован)
// 'warrior' — гоблин воитель (TODO)
// 'scout'   — гоблин разведчик (TODO)
// 'monk'    — гоблин монах (TODO)

// — Типы ресурсов (все gatherable — гоблины могут собирать) —
// Чтобы добавить новый ресурс: добавить спрайт в sprites.js, добавить запись сюда.
// Расположение на карте генерируется в Map._generateInitialItems() (100 штук каждого типа).
export const ITEM_TYPES = [
    // 0: Пшеница (еда — используется для производства гоблинов)
    { name: 'Пшеница', pixels: WHEAT_PIXELS,  w: WHEAT_W,  h: WHEAT_H,  mass: 0.5, bounciness: 0.2, friction: 0.90, radius: 0.30, gatherable: true },
    // 1: Камень (строительный материал)
    { name: 'Камень',  pixels: CUBE_PIXELS,   w: 7,        h: 6,        mass: 2.5, bounciness: 0.5, friction: 0.70, radius: 0.40, gatherable: true },
    // 2: Дерево (строительный материал)
    { name: 'Дерево',  pixels: WOOD_PIXELS,   w: WOOD_W,   h: WOOD_H,   mass: 1.0, bounciness: 0.3, friction: 0.75, radius: 0.35, gatherable: true },
    // 3: Железо (руда)
    { name: 'Железо',  pixels: IRON_PIXELS,   w: IRON_W,   h: IRON_H,   mass: 3.0, bounciness: 0.2, friction: 0.80, radius: 0.40, gatherable: true },
    // 4: Свиток (магия)
    { name: 'Свиток',  pixels: SCROLL_PIXELS, w: SCROLL_W, h: SCROLL_H, mass: 0.3, bounciness: 0.1, friction: 0.85, radius: 0.25, gatherable: true },
];

// — Замок —
export const CASTLE_BASE_RADIUS  = 1.3;  // радиус коллизии в iso-единицах (спрайт 80px при scale 8, ~1.25 iso-ед на сторону)
export const CASTLE_TOWER_HEIGHT = 4.0;  // максимальная высота коллизии (world units)

// — Производство гоблинов —
export const GOBLIN_MAX            = 25;   // максимум живых гоблинов
export const GOBLIN_SPAWN_DURATION = 3.0;  // секунд на производство одного гоблина
export const GOBLIN_FOOD_COST      = 1;    // единиц пшеницы за гоблина
export const GOBLIN_FOOD_TYPE      = 0;    // индекс пшеницы в ITEM_TYPES

// — Артиллерия замка —
export const ARTILLERY_GRAB_RADIUS   = 2.0;   // расстояние руки до замка для захвата (iso)
export const ARTILLERY_FLIGHT_TIME_K = 0.12;  // множитель: время полёта = distance * K
export const ARTILLERY_MIN_FLIGHT    = 0.6;   // мин. время полёта (секунды)
export const ARTILLERY_MAX_FLIGHT    = 2.5;   // макс. время полёта (секунды)
export const ARTILLERY_BLAST_RADIUS  = 3;     // радиус взрыва в iso-тайлах (7×7 = ±3)
export const ARTILLERY_DAMAGE        = 80;    // урон от взрыва
export const ARTILLERY_RETURN_DELAY  = 1.5;   // пауза после взрыва до возврата камеры (секунды)
