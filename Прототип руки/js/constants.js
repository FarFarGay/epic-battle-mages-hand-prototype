// ============================================================
//  КОНСТАНТЫ ИГРЫ
// ============================================================
import {
    CUBE_PIXELS,
    WHEAT_PIXELS, WHEAT_W, WHEAT_H,
    PLACEHOLDER3_PIXELS, PLACEHOLDER3_W, PLACEHOLDER3_H,
    PLACEHOLDER4_PIXELS, PLACEHOLDER4_W, PLACEHOLDER4_H,
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

// — Типы ресурсов (все gatherable — гоблины могут собирать) —
// Чтобы добавить новый ресурс: добавить спрайт в sprites.js, добавить запись сюда, добавить спавн в Map.js initialItems.
export const ITEM_TYPES = [
    // 0: Пшеница (еда)
    { name: 'Пшеница',             pixels: WHEAT_PIXELS,        w: WHEAT_W,        h: WHEAT_H,        mass: 0.5, bounciness: 0.2, friction: 0.90, radius: 0.30, gatherable: true },
    // 1: Камень (строительный материал)
    { name: 'Камень',              pixels: CUBE_PIXELS,         w: 7,              h: 6,              mass: 2.5, bounciness: 0.5, friction: 0.70, radius: 0.40, gatherable: true },
    // 2: Ресурс C — заглушка (дерево / оранжевый куб)
    { name: 'Ресурс C (заглушка)', pixels: PLACEHOLDER3_PIXELS, w: PLACEHOLDER3_W, h: PLACEHOLDER3_H, mass: 1.0, bounciness: 0.3, friction: 0.80, radius: 0.35, gatherable: true },
    // 3: Ресурс D — заглушка (руда / фиолетовый куб)
    { name: 'Ресурс D (заглушка)', pixels: PLACEHOLDER4_PIXELS, w: PLACEHOLDER4_W, h: PLACEHOLDER4_H, mass: 1.5, bounciness: 0.4, friction: 0.75, radius: 0.35, gatherable: true },
];

// — Замок —
export const CASTLE_BASE_RADIUS  = 1.3;  // радиус коллизии в iso-единицах (спрайт 80px при scale 8, ~1.25 iso-ед на сторону)
export const CASTLE_TOWER_HEIGHT = 4.0;  // максимальная высота коллизии (world units)
