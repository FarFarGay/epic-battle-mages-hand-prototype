// ============================================================
//  ДЕКОРАЦИИ — визуальные объекты на тайлах (деревья, камни, домики...)
// ============================================================
import { PIXEL_SCALE } from './constants.js';
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
} from './sprites.js?v=3';

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
export function onTileChanged(ix, iy, oldType, newType, cause) {
    if (newType === 'burning' || newType === 'wall' || newType === 'water') {
        // Сначала спавним частицы, потом удаляем
        for (let i = decorations.length - 1; i >= 0; i--) {
            const d = decorations[i];
            if (d.tileIx !== ix || d.tileIy !== iy) continue;
            destroyDecorationWithEffect(d, cause);
            decorations.splice(i, 1);
        }
    } else if (newType === 'scorched') {
        // Убираем деревья, оставляем камни
        for (let i = decorations.length - 1; i >= 0; i--) {
            const d = decorations[i];
            if (d.tileIx !== ix || d.tileIy !== iy) continue;
            if (!d.spriteKey.startsWith('TREE')) continue;
            destroyDecorationWithEffect(d, cause);
            decorations.splice(i, 1);
        }
    } else if (newType === 'plain' || newType === 'puddle' || newType === 'swamp') {
        // Лес срублен/затоплен — убираем деревья
        if (oldType === 'forest') {
            for (let i = decorations.length - 1; i >= 0; i--) {
                const d = decorations[i];
                if (d.tileIx !== ix || d.tileIy !== iy) continue;
                if (!d.spriteKey.startsWith('TREE')) continue;
                destroyDecorationWithEffect(d, cause);
                decorations.splice(i, 1);
            }
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

        const scale = DECO_RENDER_SCALE[deco.spriteKey] || PIXEL_SCALE;
        const depth = deco.ix + deco.iy - 0.1; // чуть позади юнитов на том же тайле
        const ox = s.x - (sp.w * scale) / 2;
        const oy = s.y - sp.h * scale;

        // Capture values for closure
        const _ox = ox, _oy = oy, _sp = sp, _scale = scale;
        renderList.push({
            depth,
            draw: () => drawPixelArt(_ox, _oy, _sp.pixels, _scale),
        });
    }
}
