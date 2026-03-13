// ============================================================
//  КАРТА — размер, тайлы, туман войны, высоты
// ============================================================
import { CAMERA_OFFSET_Y, TILE_W, TILE_H, HEIGHT_TO_SCREEN } from './constants.js';
import { isoToScreen, camera } from './isometry.js';
import { canvas, ctx, drawIsoDiamond } from './renderer.js';

// ============================================================
//  ТИПЫ ТАЙЛОВ
// ============================================================
export const TILE_TYPES = {
    plain:   { even: '#2a2a4a', evenStr: '#222240', odd: '#252545', oddStr: '#1e1e3a' },
    forest:  { even: '#1a3a1a', evenStr: '#142e14', odd: '#1e3e1e', oddStr: '#183218' },
    water:   { even: '#1a2a4a', evenStr: '#142040', odd: '#1e2e4e', oddStr: '#182444', animated: true },
    stone:   { even: '#3a3535', evenStr: '#2e2a2a', odd: '#353030', oddStr: '#2a2525' },
    village: { even: '#3a2a1a', evenStr: '#2e2010', odd: '#3e2e1e', oddStr: '#322414' },
    ice:     { even: '#2a3a4a', evenStr: '#203040', odd: '#2e3e4e', oddStr: '#243444' },
    burning: { even: '#cc4400', evenStr: '#aa3300', odd: '#dd5500', oddStr: '#993300', animated: true },
    scorched:{ even: '#2a1a0a', evenStr: '#1e1206', odd: '#261808', oddStr: '#1a1004' },
    puddle:  { even: '#2244aa', evenStr: '#1a3388', odd: '#2a4ebb', oddStr: '#1e3a99', animated: true },
    steam:   { even: '#aabbcc', evenStr: '#99aabb', odd: '#bbccdd', oddStr: '#aabbcc', animated: true },
    swamp:   { even: '#2a3a1a', evenStr: '#1e2e10', odd: '#243416', oddStr: '#1a280c' },
    wall:    { even: '#667788', evenStr: '#556677', odd: '#5a6a7a', oddStr: '#4a5a6a' },
    rubble:  { even: '#8899aa', evenStr: '#778899', odd: '#7a8a9a', oddStr: '#6a7a8a' },
};

// ============================================================
//  ТУМАН ВОЙНЫ
// ============================================================
export const FOG = {
    HIDDEN:   'hidden',
    EXPLORED: 'explored',
    VISIBLE:  'visible',
};

// ============================================================
//  CALLBACK ПРИ СМЕНЕ ТАЙЛА
// ============================================================
let _onTileChangedCb = null;
export function setTileChangedCallback(cb) {
    _onTileChangedCb = cb;
}

export class GameMap {
    constructor(size = 80) {
        this.size = size;

        // Seed для генератора карты
        this.seed = Math.floor(Math.random() * 1000000);

        // Туман войны вкл/выкл
        this.fogEnabled = true;

        // Позиция замка
        this.castlePos = { ix: -30, iy: 0 };

        // Начальные позиции миньонов — относительно castlePos
        this.initialMinions = [
            { ix: this.castlePos.ix - 4, iy: this.castlePos.iy },
            { ix: this.castlePos.ix + 4, iy: this.castlePos.iy },
        ];

        // Типы тайлов
        this._tiles = {};

        // Карта высот: key → float [-1, 1]
        this._heightMap = {};

        // Кэш вариации цвета: key → float (дельта яркости ±0.08)
        this._colorCache = {};

        // Туман войны
        this._fog = {};
    }

    // ============================================================
    //  ВСПОМОГАТЕЛЬНЫЕ
    // ============================================================
    _key(ix, iy) { return `${ix},${iy}`; }

    isInBounds(ix, iy) {
        return ix >= -this.size && ix <= this.size &&
               iy >= -this.size && iy <= this.size;
    }

    // ============================================================
    //  ТАЙЛЫ
    // ============================================================
    setTile(ix, iy, type, cause) {
        if (!(type in TILE_TYPES)) return;
        const key = this._key(ix, iy);
        const oldType = this._tiles[key] ?? 'plain';
        this._tiles[key] = type;
        delete this._colorCache[key];
        if (_onTileChangedCb) _onTileChangedCb(ix, iy, oldType, type, cause);
    }

    getTile(ix, iy) {
        return this._tiles[this._key(ix, iy)] ?? 'plain';
    }

    // ============================================================
    //  ВЫСОТЫ
    // ============================================================
    getHeight(ix, iy) {
        return this._heightMap[this._key(ix, iy)] ?? 0;
    }

    setHeight(ix, iy, value) {
        this._heightMap[this._key(ix, iy)] = value;
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

    revealAround(ix, iy, radius = 3) {
        const cx = Math.round(ix), cy = Math.round(iy);
        const r2 = radius * radius, ri = Math.ceil(radius);
        for (let dy = -ri; dy <= ri; dy++) {
            for (let dx = -ri; dx <= ri; dx++) {
                if (dx * dx + dy * dy <= r2) {
                    const fx = cx + dx, fy = cy + dy;
                    if (this.isInBounds(fx, fy))
                        this._fog[this._key(fx, fy)] = FOG.VISIBLE;
                }
            }
        }
    }

    _revealSquare(ix, iy, halfSize) {
        const cx = Math.round(ix), cy = Math.round(iy);
        for (let dy = -halfSize; dy <= halfSize; dy++) {
            for (let dx = -halfSize; dx <= halfSize; dx++) {
                const fx = cx + dx, fy = cy + dy;
                if (this.isInBounds(fx, fy))
                    this._fog[this._key(fx, fy)] = FOG.VISIBLE;
            }
        }
    }

    tickFog(sources) {
        if (!this.fogEnabled) return;
        for (const key of Object.keys(this._fog)) {
            if (this._fog[key] === FOG.VISIBLE) this._fog[key] = FOG.EXPLORED;
        }
        for (const src of sources) {
            if (src.shape === 'square') this._revealSquare(src.ix, src.iy, src.radius);
            else                        this.revealAround(src.ix, src.iy, src.radius);
        }
    }

    resize(newSize) {
        this.size = newSize;
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
        const w = canvas.width, h = canvas.height, z = camera.zoom;
        const marginX = TILE_W * 2;
        const marginY = TILE_H * 2 + 80; // запас для высоких тайлов

        const sxMin = w / 2 * (1 - 1 / z) + camera.x / z - marginX;
        const sxMax = w / 2 * (1 + 1 / z) + camera.x / z + marginX;
        const syMin = h / 2 * (1 - 1 / z) + camera.y / z - marginY - CAMERA_OFFSET_Y;
        const syMax = h / 2 * (1 + 1 / z) + camera.y / z + marginY - CAMERA_OFFSET_Y;

        for (let iy = -this.size; iy <= this.size; iy++) {
            for (let ix = -this.size; ix <= this.size; ix++) {
                const iso        = isoToScreen(ix, iy);
                const tileHeight = this.getHeight(ix, iy);
                const sx = iso.x + w / 2;
                const sy = iso.y + h / 2 - CAMERA_OFFSET_Y - tileHeight * HEIGHT_TO_SCREEN;

                if (sx < sxMin || sx > sxMax || sy < syMin || sy > syMax) continue;

                const fog = this.fogEnabled ? this.getFog(ix, iy) : FOG.VISIBLE;

                if (fog === FOG.HIDDEN) {
                    drawIsoDiamond(sx, sy, '#0a0a12', '#08080e');
                    continue;
                }

                const tileType = this.getTile(ix, iy);
                const colors   = TILE_TYPES[tileType];
                const isEven   = (ix + iy) % 2 === 0;

                if (fog === FOG.EXPLORED) {
                    drawIsoDiamond(sx, sy,
                        isEven ? '#181828' : '#141420',
                        isEven ? '#121220' : '#0e0e1c');
                    continue;
                }

                // VISIBLE — анимированные тайлы
                if (colors.animated) {
                    if (tileType === 'burning') {
                        const t = performance.now() * 0.005 + ix * 3.7 + iy * 2.3;
                        const flicker = Math.sin(t) * 0.5 + 0.5;
                        const r1 = 0xcc + Math.round((0xff - 0xcc) * flicker);
                        const g1 = 0x33 + Math.round((0x66 - 0x33) * flicker);
                        drawIsoDiamond(sx, sy, `rgb(${r1},${g1},0)`, `rgb(${r1 - 0x22},${Math.max(0, g1 - 0x11)},0)`);
                    } else if (tileType === 'puddle') {
                        const t    = performance.now() * 0.002 + ix * 1.1 + iy * 0.7;
                        const wave = Math.sin(t) * 0.15 + 0.85;
                        const b    = Math.round(0xaa * wave);
                        drawIsoDiamond(sx, sy, `rgb(34,${Math.round(68 * wave)},${b})`, `rgb(26,${Math.round(51 * wave)},${Math.round(b * 0.8)})`);
                    } else if (tileType === 'water') {
                        const t    = performance.now() * 0.001 + ix * 0.5 + iy * 0.3;
                        const wave = Math.sin(t) * 0.05 + 0.97;
                        const r    = Math.round(0x1a * wave), g = Math.round(0x2a * wave), b = Math.round(0x4a * wave);
                        drawIsoDiamond(sx, sy, `rgb(${r},${g},${b})`, isEven ? colors.evenStr : colors.oddStr);
                    } else {
                        drawIsoDiamond(sx, sy, isEven ? colors.even : colors.odd, isEven ? colors.evenStr : colors.oddStr);
                    }
                } else {
                    // Вариация цвета из кэша
                    const variation = this._colorCache[`${ix},${iy}`] ?? 0;
                    if (variation !== 0) {
                        drawIsoDiamond(sx, sy,
                            _varyColor(isEven ? colors.even   : colors.odd,   variation),
                            _varyColor(isEven ? colors.evenStr : colors.oddStr, variation * 0.5));
                    } else {
                        drawIsoDiamond(sx, sy, isEven ? colors.even : colors.odd, isEven ? colors.evenStr : colors.oddStr);
                    }
                }

                // Боковая грань при перепаде высот
                this._drawSideFace(ix, iy, sx, sy, tileType, tileHeight);
            }
        }
    }

    _drawSideFace(ix, iy, sx, sy, tileType, h1) {
        // Рисуем грань между (ix,iy) и правым-нижним соседом (ix+1,iy)
        const nx = ix + 1, ny = iy;
        if (!this.isInBounds(nx, ny)) return;
        const h2   = this.getHeight(nx, ny);
        const diff = (h1 - h2) * HEIGHT_TO_SCREEN;
        if (diff < 4) return;

        const fog = this.fogEnabled ? this.getFog(ix, iy) : FOG.VISIBLE;
        if (fog !== FOG.VISIBLE) return;

        const colors = TILE_TYPES[tileType] || TILE_TYPES.plain;
        const c = _darken(colors.even, 0.45);

        // Правое ребро тайла (ix,iy): верх-право (sx+TILE_W/2, sy), низ-право (sx, sy+TILE_H/2)
        // Нижний тайл — те же X, но другой Y
        ctx.beginPath();
        ctx.moveTo(sx + TILE_W / 2, sy);
        ctx.lineTo(sx + TILE_W / 2, sy + diff);
        ctx.lineTo(sx, sy + TILE_H / 2 + diff);
        ctx.lineTo(sx, sy + TILE_H / 2);
        ctx.closePath();
        ctx.fillStyle = c;
        ctx.fill();
    }
}

// ============================================================
//  УТИЛИТЫ ЦВЕТА
// ============================================================
function _varyColor(hex, delta) {
    if (!hex || hex[0] !== '#' || hex.length < 7) return hex;
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    const f = 1 + delta;
    return `rgb(${_c(r * f)},${_c(g * f)},${_c(b * f)})`;
}

function _darken(hex, factor) {
    if (!hex || hex[0] !== '#' || hex.length < 7) return '#111';
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    return `rgb(${_c(r * factor)},${_c(g * factor)},${_c(b * factor)})`;
}

function _c(v) { return Math.max(0, Math.min(255, Math.round(v))); }

export const gameMap = new GameMap();
