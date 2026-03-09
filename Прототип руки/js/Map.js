// ============================================================
//  КАРТА — размер, начальные данные, рендер тайлов
// ============================================================
import { CAMERA_OFFSET_Y } from './constants.js';
import { isoToScreen } from './isometry.js';
import { canvas, drawIsoDiamond } from './renderer.js';

export class GameMap {
    constructor(size = 10) {
        this.size = size;

        // Начальные позиции предметов (type — индекс в ITEM_TYPES)
        this.initialItems = [
            { type: 0, ix: -2, iy: -1 },
            { type: 2, ix: -1, iy:  2 },
            { type: 3, ix:  1, iy: -2 },
            { type: 1, ix:  5, iy:  3 },
            { type: 1, ix: -6, iy:  2 },
            { type: 1, ix:  3, iy: -5 },
            { type: 1, ix: -4, iy: -4 },
        ];

        // Начальные позиции миньонов
        this.initialMinions = [
            { ix: -4, iy:  0 },
            { ix:  4, iy:  0 },
        ];

        // Позиция замка
        this.castlePos = { ix: 0, iy: -6 };
    }

    draw() {
        for (let iy = -this.size; iy <= this.size; iy++) {
            for (let ix = -this.size; ix <= this.size; ix++) {
                const iso = isoToScreen(ix, iy);
                const sx = iso.x + canvas.width / 2;
                const sy = iso.y + canvas.height / 2 - CAMERA_OFFSET_Y;
                const isEven = (ix + iy) % 2 === 0;
                drawIsoDiamond(sx, sy, isEven ? '#2a2a4a' : '#252545', isEven ? '#222240' : '#1e1e3a');
            }
        }
    }
}

export const gameMap = new GameMap();
