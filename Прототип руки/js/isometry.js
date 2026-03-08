// ============================================================
//  ИЗОМЕТРИЧЕСКАЯ ПРОЕКЦИЯ
// ============================================================
import { TILE_W, TILE_H, CAMERA_OFFSET_Y } from './constants.js';

export const camera = {
    zoom: 1.0,
    targetZoom: 1.0,
};

export function isoToScreen(ix, iy) {
    return {
        x: (ix - iy) * (TILE_W / 2),
        y: (ix + iy) * (TILE_H / 2)
    };
}

export function screenToIso(sx, sy, canvas) {
    // Учитываем зум камеры: экранные координаты → мировые
    const cx = (sx - canvas.width / 2) / camera.zoom;
    const cy = (sy - canvas.height / 2) / camera.zoom + CAMERA_OFFSET_Y;
    return {
        x: (cx / (TILE_W / 2) + cy / (TILE_H / 2)) / 2,
        y: (cy / (TILE_H / 2) - cx / (TILE_W / 2)) / 2
    };
}

export function getDepth(isoX, isoY) {
    return isoX + isoY;
}
