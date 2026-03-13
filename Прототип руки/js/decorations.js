// ============================================================
//  ДЕКОРАЦИИ — визуальные объекты на тайлах (деревья, камни, домики...)
// ============================================================
import { PIXEL_SCALE, HEIGHT_TO_SCREEN } from './constants.js';
import { drawPixelArt } from './renderer.js';
import { worldToScreen } from './isometry.js';
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
} from './sprites.js';

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
};

// ============================================================
//  МАССИВ ДЕКОРАЦИЙ
// ============================================================
// Каждая: { ix, iy, tileIx, tileIy, spriteKey }
// ix/iy — точные координаты с offset; tileIx/tileIy — ячейка тайла для fog/removal
export const decorations = [];

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
//  CALLBACK ПРИ СМЕНЕ ТАЙЛА
// ============================================================
export function onTileChanged(ix, iy, oldType, newType) {
    if (newType === 'burning' || newType === 'wall' || newType === 'water') {
        removeDecorationsAt(ix, iy);
    } else if (newType === 'scorched') {
        // Убираем деревья, оставляем камни
        removeDecorationsAt(ix, iy, d => d.spriteKey.startsWith('TREE'));
    } else if (newType === 'plain' || newType === 'puddle' || newType === 'swamp') {
        // Лес срублен/затоплен — убираем деревья
        if (oldType === 'forest') {
            removeDecorationsAt(ix, iy, d => d.spriteKey.startsWith('TREE'));
        }
    }
}

// ============================================================
//  ДОБАВЛЕНИЕ В RENDER LIST
// ============================================================
export function addDecorationsToRenderList(renderList, canvas) {
    for (const deco of decorations) {
        // Fog check по тайлу
        if (gameMap.getFog(deco.tileIx, deco.tileIy) !== FOG.VISIBLE) continue;

        const sp = DECO_SPRITES[deco.spriteKey];
        if (!sp) continue;

        const s = worldToScreen(deco.ix, deco.iy);

        // Viewport culling
        if (s.x < -100 || s.x > canvas.width + 100 ||
            s.y < -150 || s.y > canvas.height + 100) continue;

        const depth = deco.ix + deco.iy;
        const ox = s.x - (sp.w * PIXEL_SCALE) / 2;
        const oy = s.y - sp.h * PIXEL_SCALE;

        // Capture values for closure
        const _ox = ox, _oy = oy, _sp = sp;
        renderList.push({
            depth,
            draw: () => drawPixelArt(_ox, _oy, _sp.pixels, PIXEL_SCALE),
        });
    }
}
