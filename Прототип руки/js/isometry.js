// ============================================================
//  ИЗОМЕТРИЧЕСКАЯ ПРОЕКЦИЯ
// ============================================================
import { TILE_W, TILE_H, CAMERA_OFFSET_Y, HEIGHT_TO_SCREEN } from './constants.js';
import { canvas } from './renderer.js';
// Круговая зависимость Map.js ↔ isometry.js допустима в ES-модулях:
// gameMap используется только внутри функций (не при инициализации модуля).
import { gameMap } from './Map.js';

export const camera = {
    zoom: 1.0,
    targetZoom: 1.0,
    x: 0, y: 0,
    targetX: 0, targetY: 0,
};

export function isoToScreen(ix, iy) {
    return {
        x: (ix - iy) * (TILE_W / 2),
        y: (ix + iy) * (TILE_H / 2),
    };
}

export function screenToIso(sx, sy, canvas) {
    const cx = (sx - canvas.width  / 2 + camera.x) / camera.zoom;
    const cy = (sy - canvas.height / 2 + camera.y) / camera.zoom + CAMERA_OFFSET_Y;
    return {
        x: (cx / (TILE_W / 2) + cy / (TILE_H / 2)) / 2,
        y: (cy / (TILE_H / 2) - cx / (TILE_W / 2)) / 2,
    };
}

export function getDepth(isoX, isoY) {
    return isoX + isoY;
}

// Изо-координаты → canvas-пиксели с учётом высоты тайла
export function worldToScreen(wx, wy) {
    const iso         = isoToScreen(wx, wy);
    const tileHeight  = gameMap.getHeight(Math.round(wx), Math.round(wy));
    return {
        x: iso.x + canvas.width  / 2,
        y: iso.y + canvas.height / 2 - CAMERA_OFFSET_Y - tileHeight * HEIGHT_TO_SCREEN,
    };
}

// Экранные координаты → canvas-координаты (с учётом зума и пана)
export function screenToCanvas(sx, sy) {
    return {
        x: (sx - canvas.width  / 2 + camera.x) / camera.zoom + canvas.width  / 2,
        y: (sy - canvas.height / 2 + camera.y) / camera.zoom + canvas.height / 2,
    };
}
