// ============================================================
//  КАРТА — размер, тайлы, туман войны, ресурсы
// ============================================================
import { CAMERA_OFFSET_Y, TILE_W, TILE_H } from './constants.js';
import { isoToScreen, camera } from './isometry.js';
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
    // — Новые тайлы (создаются заклинаниями) —
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
    HIDDEN:   'hidden',   // не открыто — чёрный тайл
    EXPLORED: 'explored', // посещено, но вне обзора — затемнён
    VISIBLE:  'visible',  // в зоне видимости — нормальный цвет
};

export class GameMap {
    constructor(size = 80) {
        this.size = size;

        // Включить/выключить туман войны
        this.fogEnabled = true;

        // Начальные позиции предметов: 100 × 5 типов = 500 штук.
        // Генерируются спиральным алгоритмом — каждый тип в своём секторе карты.
        //   0 = Пшеница, 1 = Камень, 2 = Дерево, 3 = Железо, 4 = Свиток
        this.initialItems = this._generateInitialItems();

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
    //  ГЕНЕРАЦИЯ РЕСУРСОВ
    // ============================================================
    // Раскладывает 100 единиц каждого ресурса спиральным паттерном.
    // Каждый тип стартует под своим углом → разные сектора карты.
    // rMin/rMax — диапазон расстояния от замка (iso-единицы).
    _generateInitialItems() {
        const items = [];
        const occupied = new Set();
        // [typeIndex, startAngle, rMin, rMax]
        const typeParams = [
            [0,  0,                4,  35], // Пшеница  — ближние поля
            [1,  Math.PI * 0.4,    5,  38], // Камень   — каменистые гряды
            [2,  Math.PI * 0.8,    6,  40], // Дерево   — леса
            [3,  Math.PI * 1.2,    8,  42], // Железо   — глубокие залежи
            [4,  Math.PI * 1.6,   10,  45], // Свиток   — руины и тайники
        ];
        for (const [type, angleStart, rMin, rMax] of typeParams) {
            for (let i = 0; i < 100; i++) {
                const t = i / 100;
                const r = rMin + (rMax - rMin) * t;
                // 5 полных витков → хорошее угловое покрытие
                const angle = angleStart + t * Math.PI * 10;
                let ix = Math.round(r * Math.cos(angle));
                let iy = Math.round(r * Math.sin(angle));
                // Избегаем стакания предметов на одном тайле
                let key = `${ix},${iy}`;
                let tries = 0;
                while (occupied.has(key) && tries < 8) {
                    ix += (tries % 2 === 0) ? 1 : 0;
                    iy += (tries % 2 === 1) ? 1 : 0;
                    key = `${ix},${iy}`;
                    tries++;
                }
                occupied.add(key);
                items.push({ type, ix, iy });
            }
        }
        return items;
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
        const ri = Math.ceil(radius);
        for (let dy = -ri; dy <= ri; dy++) {
            for (let dx = -ri; dx <= ri; dx++) {
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
        // Viewport culling: вычисляем видимую область в координатах world-canvas
        // screenX = zoom*(sx - w/2) + w/2 - camera.x → sx = (screenX - w/2 + camera.x)/zoom + w/2
        const w = canvas.width, h = canvas.height, z = camera.zoom;
        const marginX = TILE_W;
        const marginY = TILE_H;
        const sxMin = w / 2 * (1 - 1 / z) + camera.x / z - marginX;
        const sxMax = w / 2 * (1 + 1 / z) + camera.x / z + marginX;
        const syMin = h / 2 * (1 - 1 / z) + camera.y / z - marginY - CAMERA_OFFSET_Y;
        const syMax = h / 2 * (1 + 1 / z) + camera.y / z + marginY - CAMERA_OFFSET_Y;

        for (let iy = -this.size; iy <= this.size; iy++) {
            for (let ix = -this.size; ix <= this.size; ix++) {
                const iso = isoToScreen(ix, iy);
                const sx = iso.x + canvas.width / 2;
                const sy = iso.y + canvas.height / 2 - CAMERA_OFFSET_Y;

                // Пропускаем тайлы за пределами экрана
                if (sx < sxMin || sx > sxMax || sy < syMin || sy > syMax) continue;

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
                } else if (colors.animated && tileType === 'burning') {
                    // Мерцающий огненный тайл
                    const t = performance.now() * 0.005 + ix * 3.7 + iy * 2.3;
                    const flicker = Math.sin(t) * 0.5 + 0.5; // 0..1
                    const r1 = 0xcc + Math.round((0xff - 0xcc) * flicker);
                    const g1 = 0x33 + Math.round((0x66 - 0x33) * flicker);
                    const fill = `rgb(${r1},${g1},0)`;
                    const stroke = `rgb(${r1 - 0x22},${Math.max(0, g1 - 0x11)},0)`;
                    drawIsoDiamond(sx, sy, fill, stroke);
                } else if (colors.animated && tileType === 'puddle') {
                    // Лёгкая волна на луже
                    const t = performance.now() * 0.002 + ix * 1.1 + iy * 0.7;
                    const wave = Math.sin(t) * 0.15 + 0.85;
                    const b = Math.round(0xaa * wave);
                    const fill = `rgb(34,${Math.round(68 * wave)},${b})`;
                    const stroke = `rgb(26,${Math.round(51 * wave)},${Math.round(b * 0.8)})`;
                    drawIsoDiamond(sx, sy, fill, stroke);
                } else if (colors.animated && tileType === 'steam') {
                    // Полупрозрачный пар
                    const fill   = isEven ? colors.even   : colors.odd;
                    const stroke = isEven ? colors.evenStr : colors.oddStr;
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
