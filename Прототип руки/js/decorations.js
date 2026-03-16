// ============================================================
//  ДЕКОРАЦИИ — визуальные объекты на тайлах (деревья, камни, домики...)
// ============================================================
import { PIXEL_SCALE } from './constants.js';
import { worldToScreen, camera } from './isometry.js';
import { gameMap, FOG } from './Map.js';
import {
    DECO_TREE_1, DECO_TREE_1_W, DECO_TREE_1_H,
    DECO_TREE_2, DECO_TREE_2_W, DECO_TREE_2_H,
    DECO_TREE_3, DECO_TREE_3_W, DECO_TREE_3_H,
    DECO_ROCK_1, DECO_ROCK_1_W, DECO_ROCK_1_H,
    DECO_ROCK_2, DECO_ROCK_2_W, DECO_ROCK_2_H,
    DECO_GRASS_1, DECO_GRASS_1_W, DECO_GRASS_1_H,
    DECO_HOUSE_1, DECO_HOUSE_1_W, DECO_HOUSE_1_H,
    DECO_HOUSE_2, DECO_HOUSE_2_W, DECO_HOUSE_2_H,
    DECO_ICE_CRACK, DECO_ICE_CRACK_W, DECO_ICE_CRACK_H,
    DECO_SLAB_1, DECO_SLAB_1_W, DECO_SLAB_1_H,
    DECO_WALL_1, DECO_WALL_1_W, DECO_WALL_1_H,
    DECO_VILLAGE_HOUSE_S, DECO_VILLAGE_HOUSE_S_W, DECO_VILLAGE_HOUSE_S_H,
    DECO_VILLAGE_HOUSE_M, DECO_VILLAGE_HOUSE_M_W, DECO_VILLAGE_HOUSE_M_H,
    DECO_VILLAGE_WELL, DECO_VILLAGE_WELL_W, DECO_VILLAGE_WELL_H,
    DECO_CROP_GREEN, DECO_CROP_GREEN_W, DECO_CROP_GREEN_H,
    DECO_CROP_RIPE, DECO_CROP_RIPE_W, DECO_CROP_RIPE_H,
} from './sprites.js?v=7';

// ============================================================
//  ДАННЫЕ СПРАЙТОВ ПО КЛЮЧУ
// ============================================================
const DECO_SPRITES = {
    TREE_1:    { pixels: DECO_TREE_1,    w: DECO_TREE_1_W,    h: DECO_TREE_1_H    },
    TREE_2:    { pixels: DECO_TREE_2,    w: DECO_TREE_2_W,    h: DECO_TREE_2_H    },
    TREE_3:    { pixels: DECO_TREE_3,    w: DECO_TREE_3_W,    h: DECO_TREE_3_H    },
    ROCK_1:    { pixels: DECO_ROCK_1,    w: DECO_ROCK_1_W,    h: DECO_ROCK_1_H    },
    ROCK_2:    { pixels: DECO_ROCK_2,    w: DECO_ROCK_2_W,    h: DECO_ROCK_2_H    },
    GRASS_1:   { pixels: DECO_GRASS_1,   w: DECO_GRASS_1_W,   h: DECO_GRASS_1_H   },
    HOUSE_1:   { pixels: DECO_HOUSE_1,   w: DECO_HOUSE_1_W,   h: DECO_HOUSE_1_H   },
    HOUSE_2:   { pixels: DECO_HOUSE_2,   w: DECO_HOUSE_2_W,   h: DECO_HOUSE_2_H   },
    ICE_CRACK: { pixels: DECO_ICE_CRACK, w: DECO_ICE_CRACK_W, h: DECO_ICE_CRACK_H },
    SLAB_1:    { pixels: DECO_SLAB_1,    w: DECO_SLAB_1_W,    h: DECO_SLAB_1_H    },
    WALL_1:    { pixels: DECO_WALL_1,    w: DECO_WALL_1_W,    h: DECO_WALL_1_H    },
    VILLAGE_HOUSE_S: { pixels: DECO_VILLAGE_HOUSE_S, w: DECO_VILLAGE_HOUSE_S_W, h: DECO_VILLAGE_HOUSE_S_H },
    VILLAGE_HOUSE_M: { pixels: DECO_VILLAGE_HOUSE_M, w: DECO_VILLAGE_HOUSE_M_W, h: DECO_VILLAGE_HOUSE_M_H },
    VILLAGE_WELL:    { pixels: DECO_VILLAGE_WELL,    w: DECO_VILLAGE_WELL_W,    h: DECO_VILLAGE_WELL_H    },
    CROP_GREEN:      { pixels: DECO_CROP_GREEN,     w: DECO_CROP_GREEN_W,     h: DECO_CROP_GREEN_H     },
    CROP_RIPE:       { pixels: DECO_CROP_RIPE,      w: DECO_CROP_RIPE_W,      h: DECO_CROP_RIPE_H      },
};

// ============================================================
//  МАСШТАБ РЕНДЕРА ПО КЛЮЧУ
// ============================================================
// GRASS_1 рисуется мельче (scale=2) — фоновый шум, остальные scale=3
const DECO_RENDER_SCALE = {
    TREE_1:    3,
    TREE_2:    3,
    TREE_3:    3,
    ROCK_1:    3,
    ROCK_2:    3,
    GRASS_1:   2,
    HOUSE_1:   3,
    HOUSE_2:   3,
    ICE_CRACK: 3,
    SLAB_1:    3,
    WALL_1:    3,
    VILLAGE_HOUSE_S: 3,
    VILLAGE_HOUSE_M: 3,
    VILLAGE_WELL:    3,
    CROP_GREEN:      3,
    CROP_RIPE:       3,
};

// ============================================================
//  МАССИВ ДЕКОРАЦИЙ
// ============================================================
// Каждая: { ix, iy, tileIx, tileIy, spriteKey }
// ix/iy — точные координаты с offset; tileIx/tileIy — ячейка тайла для fog/removal
export const decorations = [];

// ============================================================
//  ЧАСТИЦЫ РАЗРУШЕНИЯ ДЕКОРАЦИЙ
// ============================================================
// Формат: { x, y, vx, vy, gravity, life, maxLife, size, color }
// Координаты — camera space (worldToScreen), рендерятся внутри camera transform.
export const decoParticles = [];

// ============================================================
//  РАЗРУШЕНИЕ ДЕКОРАЦИИ С ЭФФЕКТОМ
// ============================================================
export function destroyDecorationWithEffect(deco, cause) {
    const sp = DECO_SPRITES[deco.spriteKey];
    if (!sp) return;

    const scale = DECO_RENDER_SCALE[deco.spriteKey] || PIXEL_SCALE;
    const s  = worldToScreen(deco.ix, deco.iy);
    const ox = s.x - (sp.w * scale) / 2;
    const oy = s.y - sp.h * scale;

    for (const [px, py, color] of sp.pixels) {
        if (!color) continue;

        const cx = ox + px * scale;
        const cy = oy + py * scale;

        let vx, vy, gravity, life;

        if (cause === 'fire') {
            // Вверх-вверх, медленно тает
            vx      = (Math.random() - 0.5) * 38;
            vy      = -(12 + Math.random() * 32);
            gravity = -18;   // продолжает лететь вверх
            life    = 0.30 + Math.random() * 0.20;
        } else if (cause === 'earth') {
            // Щепки — в стороны и вниз
            vx      = (Math.random() - 0.5) * 70;
            vy      = -8 + (Math.random() - 0.5) * 38;
            gravity = 130;
            life    = 0.35 + Math.random() * 0.20;
        } else if (cause === 'harvest') {
            // Сбор ресурса — частицы вверх, мягко рассеиваются
            vx      = (Math.random() - 0.5) * 20;
            vy      = -(20 + Math.random() * 25);
            gravity = 40;
            life    = 0.40 + Math.random() * 0.25;
        } else if (cause === 'artillery') {
            const a = Math.random() * Math.PI * 2;
            const spd = 70 + Math.random() * 80;
            vx      = Math.cos(a) * spd;
            vy      = Math.sin(a) * spd * 0.5 - 30;
            gravity = 110;
            life    = 0.45 + Math.random() * 0.30;
        } else {
            // water / wind / expire / unknown
            vx      = (Math.random() - 0.5) * 28;
            vy      = -(8 + Math.random() * 18);
            gravity = 80;
            life    = 0.25 + Math.random() * 0.20;
        }

        decoParticles.push({ x: cx, y: cy, vx, vy, gravity, life, maxLife: life, size: scale, color });
    }
}

// ============================================================
//  СБОР РЕСУРСА ИЗ ДЕКОРАЦИИ
// ============================================================
// Тип предмета, который выпадает при сборе декорации на производственном тайле.
// Возвращает typeIndex (ITEM_TYPES) или -1 если тайл не производственный.
export function getHarvestType(tileIx, tileIy) {
    const tile = gameMap.getTile(tileIx, tileIy);
    if (tile === 'lumber_tile')  return 2;  // дерево
    if (tile === 'mine_tile')    return 1;  // камень
    if (tile === 'farmland' || tile === 'farmland_ripe') return 0;  // пшеница
    return -1;
}

// Собрать декорацию: разрушить спрайт с эффектом, вернуть { typeIndex, ix, iy }
// для спавна предмета. Возвращает null если декорация не найдена / не ресурсная.
export function harvestDecoration(deco) {
    const idx = decorations.indexOf(deco);
    if (idx === -1) return null;

    const harvestType = getHarvestType(deco.tileIx, deco.tileIy);
    if (harvestType < 0) return null;

    destroyDecorationWithEffect(deco, 'harvest');
    decorations.splice(idx, 1);

    return { typeIndex: harvestType, ix: deco.ix, iy: deco.iy };
}

// ============================================================
//  УДАЛЕНИЕ ДЕКОРАЦИЙ С ТАЙЛА
// ============================================================
// filter(deco) — если передан, удаляем только декорации, для которых filter(deco) === true
export function removeDecorationsAt(ix, iy, filter) {
    for (let i = decorations.length - 1; i >= 0; i--) {
        const d = decorations[i];
        if (d.tileIx !== ix || d.tileIy !== iy) continue;
        if (filter && !filter(d)) continue;
        decorations.splice(i, 1);
    }
}

// ============================================================
//  CALLBACK СПАВНА ПРЕДМЕТОВ (устанавливается из World.js)
// ============================================================
// cb(typeIndex, ix, iy, vx, vy, vz)
let _onItemSpawnCb = null;
export function setItemSpawnCallback(cb) { _onItemSpawnCb = cb; }

function _spawnItem(typeIndex, ix, iy, vx, vy, vz) {
    if (_onItemSpawnCb) _onItemSpawnCb(typeIndex, ix, iy, vx || 0, vy || 0, vz || 0);
}

// ============================================================
//  ВСПОМОГАТЕЛЬНЫЕ: удаление декораций с тайла
// ============================================================
function _destroyAllDecosAt(ix, iy, cause) {
    for (let i = decorations.length - 1; i >= 0; i--) {
        const d = decorations[i];
        if (d.tileIx !== ix || d.tileIy !== iy) continue;
        destroyDecorationWithEffect(d, cause);
        decorations.splice(i, 1);
    }
}

function _destroyDecosAt(ix, iy, cause, filter) {
    for (let i = decorations.length - 1; i >= 0; i--) {
        const d = decorations[i];
        if (d.tileIx !== ix || d.tileIy !== iy) continue;
        if (filter && !filter(d)) continue;
        destroyDecorationWithEffect(d, cause);
        decorations.splice(i, 1);
    }
}

// ============================================================
//  СПАВН РЕСУРСОВ ИЗ ДЕКОРАЦИЙ ПРИ РАЗРУШЕНИИ ТАЙЛА
// ============================================================
// Дроп дерева из леса/лесопилки
function _dropWood(ix, iy, cause) {
    const count = 1 + Math.floor(Math.random() * 2);
    for (let i = 0; i < count; i++) {
        const ox = ix + (Math.random() - 0.5) * 0.8;
        const oy = iy + (Math.random() - 0.5) * 0.8;
        const spread = cause === 'artillery' ? 3.0 : 1.5;
        const vx = (Math.random() - 0.5) * spread;
        const vy = (Math.random() - 0.5) * spread;
        const vz = 1.5 + Math.random() * 2.0;
        _spawnItem(2, ox, oy, vx, vy, vz);
    }
}

// Камнепад: камни летят в стороны в 3D
function _dropRocks(ix, iy, cause) {
    const count = 2 + Math.floor(Math.random() * 3);
    for (let i = 0; i < count; i++) {
        const angle = Math.random() * Math.PI * 2;
        const speed = cause === 'artillery' ? (2.0 + Math.random() * 3.0) : (1.5 + Math.random() * 2.5);
        const vx = Math.cos(angle) * speed;
        const vy = Math.sin(angle) * speed;
        const vz = 2.0 + Math.random() * 3.0;
        const ox = ix + (Math.random() - 0.5) * 0.4;
        const oy = iy + (Math.random() - 0.5) * 0.4;
        _spawnItem(1, ox, oy, vx, vy, vz);
    }
}

// Дроп пшеницы
function _dropWheat(ix, iy) {
    const count = 1 + Math.floor(Math.random() * 2);
    for (let i = 0; i < count; i++) {
        const ox = ix + (Math.random() - 0.5) * 0.6;
        const oy = iy + (Math.random() - 0.5) * 0.6;
        _spawnItem(0, ox, oy, (Math.random() - 0.5) * 0.8, (Math.random() - 0.5) * 0.8, 1.0 + Math.random());
    }
}

// ============================================================
//  CALLBACK ПРИ СМЕНЕ ТАЙЛА
// ============================================================
export function onTileChanged(ix, iy, oldType, newType, cause) {
    // --- Стена разрушена ---
    if (oldType === 'wall' && newType !== 'wall') {
        _destroyDecosAt(ix, iy, cause, d => d.spriteKey === 'WALL_1');
    }

    // --- Камнепад: earth/artillery + stone → stone (тайл не меняется, но камни летят) ---
    if (oldType === 'stone' && newType === 'stone' && (cause === 'earth' || cause === 'artillery')) {
        _destroyDecosAt(ix, iy, cause, d => d.spriteKey === 'ROCK_1' || d.spriteKey === 'ROCK_2');
        _dropRocks(ix, iy, cause);
        return;
    }

    // --- Лес/лесопилка → plain (ветер, земля, артиллерия) ---
    if ((oldType === 'forest' || oldType === 'lumber_tile') &&
        (newType === 'plain' || newType === 'rubble')) {
        _destroyDecosAt(ix, iy, cause, d => d.spriteKey.startsWith('TREE'));
        _dropWood(ix, iy, cause);
        return;
    }

    // --- Горение: уничтожает всё на тайле ---
    if (newType === 'burning' || newType === 'wall' || newType === 'water') {
        // Поля/фермы → дроп пшеницы перед сгоранием (если причина не огонь)
        if ((oldType === 'farmland' || oldType === 'farmland_ripe') && cause !== 'fire') {
            _dropWheat(ix, iy);
        }
        _destroyAllDecosAt(ix, iy, cause);
        if (newType === 'wall') {
            decorations.push({ ix, iy, tileIx: ix, tileIy: iy, spriteKey: 'WALL_1' });
        }
        return;
    }

    // --- Щебень (earth/artillery по деревне, производственным тайлам) ---
    if (newType === 'rubble') {
        // Деревня → дроп камня из обломков
        if (oldType === 'village_house' || oldType === 'village_square') {
            _destroyAllDecosAt(ix, iy, cause);
            _dropRocks(ix, iy, cause);
        } else if (oldType === 'mine_tile') {
            _destroyAllDecosAt(ix, iy, cause);
            _dropRocks(ix, iy, cause);
        } else if (oldType === 'farmland' || oldType === 'farmland_ripe') {
            _destroyAllDecosAt(ix, iy, cause);
            _dropWheat(ix, iy);
        } else if (oldType === 'village_road') {
            _destroyAllDecosAt(ix, iy, cause);
        } else {
            _destroyAllDecosAt(ix, iy, cause);
        }
        return;
    }

    // --- Scorched: убираем деревья и урожай, оставляем камни ---
    if (newType === 'scorched') {
        _destroyDecosAt(ix, iy, cause, d =>
            d.spriteKey.startsWith('TREE') ||
            d.spriteKey.startsWith('CROP') ||
            d.spriteKey.startsWith('VILLAGE') ||
            d.spriteKey === 'GRASS_1');
        return;
    }

    // --- Вода + пустое поле → спелый урожай ---
    if (oldType === 'farmland' && newType === 'farmland_ripe') {
        // Убираем зелёный урожай, ставим спелый
        _destroyDecosAt(ix, iy, cause, d => d.spriteKey === 'CROP_GREEN');
        decorations.push({
            ix: ix + (Math.random() - 0.5) * 0.3,
            iy: iy + (Math.random() - 0.5) * 0.3,
            tileIx: ix, tileIy: iy,
            spriteKey: 'CROP_RIPE',
        });
        return;
    }

    // --- Лес → puddle/swamp (вода) ---
    if ((newType === 'plain' || newType === 'puddle' || newType === 'swamp') && oldType === 'forest') {
        _destroyDecosAt(ix, iy, cause, d => d.spriteKey.startsWith('TREE'));
    }
}

// ============================================================
//  ДОБАВЛЕНИЕ В RENDER LIST
// ============================================================
export function addDecorationsToRenderList(renderList, canvas) {
    // Viewport bounds с учётом камерного зума
    const z  = camera.zoom || 1;
    const w  = canvas.width, h = canvas.height;
    const m  = 150; // margin в screen-пикселях
    const xMin = (camera.x - w / 2 - m) / z + w / 2;
    const xMax = (camera.x - w / 2 + w + m) / z + w / 2;
    const yMin = (camera.y - h / 2 - m) / z + h / 2;
    const yMax = (camera.y - h / 2 + h + m) / z + h / 2;

    for (const deco of decorations) {
        // Fog: скрытые тайлы не рисуем, исследованные — с затемнением
        const fog = gameMap.getFog(deco.tileIx, deco.tileIy);
        if (fog === FOG.HIDDEN) continue;

        const sp = DECO_SPRITES[deco.spriteKey];
        if (!sp) continue;

        const s = worldToScreen(deco.ix, deco.iy);

        // Viewport culling с учётом зума
        if (s.x < xMin || s.x > xMax || s.y < yMin || s.y > yMax) continue;

        const scale = DECO_RENDER_SCALE[deco.spriteKey] || PIXEL_SCALE;
        const depth = deco.ix + deco.iy - 0.1;
        const ox = s.x - (sp.w * scale) / 2;
        const oy = s.y - sp.h * scale;

        renderList.push({
            type: 'decoration',
            depth,
            ox, oy,
            pixels: sp.pixels,
            scale,
            explored: fog === FOG.EXPLORED,
        });
    }
}
