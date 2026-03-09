// ============================================================
//  КАРТА — размер, тайлы, туман войны, ресурсы
// ============================================================
import { CAMERA_OFFSET_Y } from './constants.js';
import { isoToScreen } from './isometry.js';
import { canvas, drawIsoDiamond } from './renderer.js';

// ============================================================
//  ТИПЫ ТАЙЛОВ
// ============================================================
// Каждый тип задаёт цвета чётных и нечётных тайлов (fill + stroke)
export const TILE_TYPES = {
    plain:   { even: '#2a2a4a', evenStr: '#222240', odd: '#252545', oddStr: '#1e1e3a' },
    forest:  { even: '#1a3a1a', evenStr: '#142e14', odd: '#1e3e1e', oddStr: '#183218' },
    water:   { even: '#1a2a4a', evenStr: '#142040', odd: '#1e2e4e', oddStr: '#182444' },
    stone:   { even: '#3a3535', evenStr: '#2e2a2a', odd: '#353030', oddStr: '#2a2525' },
    village: { even: '#3a2a1a', evenStr: '#2e2010', odd: '#3e2e1e', oddStr: '#322414' },
    ice:     { even: '#2a3a4a', evenStr: '#203040', odd: '#2e3e4e', oddStr: '#243444' },
};

// ============================================================
//  ТУМАН ВОЙНЫ
// ============================================================
export const FOG = {
    HIDDEN:   'hidden',   // не открыто — чёрный тайл
    EXPLORED: 'explored', // посещено, но вне обзора — затемнён
    VISIBLE:  'visible',  // в зоне видимости — нормальный цвет
};

export class GameMap {
    constructor(size = 80) {
        this.size = size;

        // Включить/выключить туман войны
        this.fogEnabled = true;

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

        // Позиция замка (центр карты)
        this.castlePos = { ix: 0, iy: 0 };

        // Типы тайлов: key `${ix},${iy}` → имя типа из TILE_TYPES
        this._tiles = {};

        // Туман войны: key → FOG.xxx
        this._fog = {};
    }

    // ============================================================
    //  ВСПОМОГАТЕЛЬНЫЕ
    // ============================================================
    _key(ix, iy) {
        return `${ix},${iy}`;
    }

    isInBounds(ix, iy) {
        return ix >= -this.size && ix <= this.size &&
               iy >= -this.size && iy <= this.size;
    }

    // ============================================================
    //  ТАЙЛЫ
    // ============================================================
    setTile(ix, iy, type) {
        if (!(type in TILE_TYPES)) return;
        this._tiles[this._key(ix, iy)] = type;
    }

    getTile(ix, iy) {
        return this._tiles[this._key(ix, iy)] ?? 'plain';
    }

    // ============================================================
    //  ТУМАН ВОЙНЫ
    // ============================================================
    getFog(ix, iy) {
        return this._fog[this._key(ix, iy)] ?? FOG.HIDDEN;
    }

    setFog(ix, iy, state) {
        this._fog[this._key(ix, iy)] = state;
    }

    // Открыть круг тайлов вокруг точки
    revealAround(ix, iy, radius = 3) {
        const cx = Math.round(ix);
        const cy = Math.round(iy);
        const r2 = radius * radius;
        for (let dy = -radius; dy <= radius; dy++) {
            for (let dx = -radius; dx <= radius; dx++) {
                if (dx * dx + dy * dy <= r2) {
                    const fx = cx + dx;
                    const fy = cy + dy;
                    if (this.isInBounds(fx, fy)) {
                        this._fog[this._key(fx, fy)] = FOG.VISIBLE;
                    }
                }
            }
        }
    }

    // Открыть квадратное поле тайлов вокруг точки (halfSize — полуразмер стороны)
    _revealSquare(ix, iy, halfSize) {
        const cx = Math.round(ix);
        const cy = Math.round(iy);
        for (let dy = -halfSize; dy <= halfSize; dy++) {
            for (let dx = -halfSize; dx <= halfSize; dx++) {
                const fx = cx + dx;
                const fy = cy + dy;
                if (this.isInBounds(fx, fy)) {
                    this._fog[this._key(fx, fy)] = FOG.VISIBLE;
                }
            }
        }
    }

    // Обновить туман за один кадр по списку источников видимости.
    // sources: [{ ix, iy, radius, shape? }, ...]
    // shape: 'circle' (по умолчанию) или 'square'
    // Сначала все VISIBLE → EXPLORED, затем снова открываем вокруг каждого источника.
    tickFog(sources) {
        if (!this.fogEnabled) return;

        for (const key of Object.keys(this._fog)) {
            if (this._fog[key] === FOG.VISIBLE) {
                this._fog[key] = FOG.EXPLORED;
            }
        }

        for (const src of sources) {
            if (src.shape === 'square') {
                this._revealSquare(src.ix, src.iy, src.radius);
            } else {
                this.revealAround(src.ix, src.iy, src.radius);
            }
        }
    }

    // ============================================================
    //  ИЗМЕНЕНИЕ РАЗМЕРА
    // ============================================================
    resize(newSize) {
        this.size = newSize;
        // Удаляем данные тайлов и тумана вне новых границ
        for (const key of Object.keys(this._tiles)) {
            const [ix, iy] = key.split(',').map(Number);
            if (!this.isInBounds(ix, iy)) delete this._tiles[key];
        }
        for (const key of Object.keys(this._fog)) {
            const [ix, iy] = key.split(',').map(Number);
            if (!this.isInBounds(ix, iy)) delete this._fog[key];
        }
    }

    // ============================================================
    //  РЕНДЕР
    // ============================================================
    draw() {
        for (let iy = -this.size; iy <= this.size; iy++) {
            for (let ix = -this.size; ix <= this.size; ix++) {
                const iso = isoToScreen(ix, iy);
                const sx = iso.x + canvas.width / 2;
                const sy = iso.y + canvas.height / 2 - CAMERA_OFFSET_Y;

                const fog = this.fogEnabled ? this.getFog(ix, iy) : FOG.VISIBLE;

                if (fog === FOG.HIDDEN) {
                    drawIsoDiamond(sx, sy, '#0a0a12', '#08080e');
                    continue;
                }

                const tileType = this.getTile(ix, iy);
                const colors = TILE_TYPES[tileType];
                const isEven = (ix + iy) % 2 === 0;

                if (fog === FOG.EXPLORED) {
                    // Посещённые, но вне обзора — фиксированный тёмный цвет
                    const fill   = isEven ? '#181828' : '#141420';
                    const stroke = isEven ? '#121220' : '#0e0e1c';
                    drawIsoDiamond(sx, sy, fill, stroke);
                } else {
                    // VISIBLE — нормальный цвет тайла
                    const fill   = isEven ? colors.even   : colors.odd;
                    const stroke = isEven ? colors.evenStr : colors.oddStr;
                    drawIsoDiamond(sx, sy, fill, stroke);
                }
            }
        }
    }
}

export const gameMap = new GameMap();
