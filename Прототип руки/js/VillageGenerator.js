// ============================================================
//  ГЕНЕРАТОР ДЕРЕВЕНЬ — расположение, тайлы, зоны производства
// ============================================================
import { createRNG } from './noise.js';
import { gameMap } from './Map.js';

// ── Имена деревень ──────────────────────────────────────────
const VILLAGE_NAMES = [
    'Дубрава', 'Ключи', 'Каменка', 'Ольховка',
    'Зорница', 'Бережки', 'Пеплово', 'Тихий Лог',
    'Ведьмино', 'Угольки', 'Светлый Яр', 'Росток',
];

const PERSONALITIES = ['TRD', 'MIL', 'REL', 'COW'];

// ── Размеры деревень ────────────────────────────────────────
const SIZE_DEFS = [
    { type: 'small',  tileSize: 5,  housesMin: 8,  housesMax: 10  },
    { type: 'small',  tileSize: 5,  housesMin: 8,  housesMax: 10  },
    { type: 'medium', tileSize: 7,  housesMin: 16, housesMax: 20  },
    { type: 'large',  tileSize: 9,  housesMin: 28, housesMax: 35  },
];

// ── Минимальные расстояния ──────────────────────────────────
const MIN_DIST_BETWEEN = 25;   // между деревнями
const MIN_DIST_CASTLE  = 18;   // от замка

// ============================================================
//  ОСНОВНАЯ ФУНКЦИЯ
// ============================================================
export function generateVillages(gMap, seed) {
    const rng  = createRNG(seed + 7777);
    const size = gMap.size;
    const cx   = gMap.castlePos.ix;
    const cy   = gMap.castlePos.iy;

    // 1. Собрать кандидатов — plain или forest, далеко от замка
    const candidates = [];
    for (let iy = -size; iy <= size; iy++) {
        for (let ix = -size; ix <= size; ix++) {
            const t = gMap.getTile(ix, iy);
            if (t !== 'plain' && t !== 'forest') continue;
            const d2 = (ix - cx) ** 2 + (iy - cy) ** 2;
            if (d2 < MIN_DIST_CASTLE * MIN_DIST_CASTLE) continue;
            // Не слишком у края карты
            if (Math.abs(ix) > size - 12 || Math.abs(iy) > size - 12) continue;
            candidates.push([ix, iy]);
        }
    }

    // Перемешать кандидатов
    for (let i = candidates.length - 1; i > 0; i--) {
        const j = Math.floor(rng() * (i + 1));
        [candidates[i], candidates[j]] = [candidates[j], candidates[i]];
    }

    // 2. Выбрать 4 позиции
    const placed = []; // { ix, iy, sizeDef }
    const usedNames = new Set();

    for (const [vx, vy] of candidates) {
        if (placed.length >= 4) break;

        // Проверить мин. расстояние между деревнями
        let tooClose = false;
        for (const p of placed) {
            const d2 = (vx - p.ix) ** 2 + (vy - p.iy) ** 2;
            if (d2 < MIN_DIST_BETWEEN * MIN_DIST_BETWEEN) { tooClose = true; break; }
        }
        if (tooClose) continue;

        // Проверить что есть достаточно места (нет воды/камня в зоне)
        const sizeDef = SIZE_DEFS[placed.length];
        const half = Math.floor(sizeDef.tileSize / 2);
        let blocked = false;
        for (let dy = -half; dy <= half && !blocked; dy++) {
            for (let dx = -half; dx <= half && !blocked; dx++) {
                const t = gMap.getTile(vx + dx, vy + dy);
                if (t === 'water' || t === 'stone' || t === 'ice') blocked = true;
            }
        }
        if (blocked) continue;

        placed.push({ ix: vx, iy: vy, sizeDef });
    }

    // 3. Генерация деревень
    const villages = [];
    const namePool = [...VILLAGE_NAMES];
    // Перемешать имена
    for (let i = namePool.length - 1; i > 0; i--) {
        const j = Math.floor(rng() * (i + 1));
        [namePool[i], namePool[j]] = [namePool[j], namePool[i]];
    }

    for (let vi = 0; vi < placed.length; vi++) {
        const { ix: cix, iy: ciy, sizeDef } = placed[vi];
        const half = Math.floor(sizeDef.tileSize / 2);

        const tiles = [];
        const houseTiles = [];

        // Расчистить зону → plain, потом расставить тайлы деревни
        for (let dy = -half; dy <= half; dy++) {
            for (let dx = -half; dx <= half; dx++) {
                const tx = cix + dx, ty = ciy + dy;
                gMap._tiles[`${tx},${ty}`] = 'plain';
                // Высоту выровнять
                gMap._heightMap[`${tx},${ty}`] = Math.max(0, gMap.getHeight(tx, ty));
            }
        }

        // Центр 2×2 → village_square
        for (let dy = 0; dy <= 1; dy++) {
            for (let dx = 0; dx <= 1; dx++) {
                const tx = cix + dx, ty = ciy + dy;
                gMap._tiles[`${tx},${ty}`] = 'village_square';
                tiles.push({ ix: tx, iy: ty, type: 'village_square' });
            }
        }

        // Дороги: 4 направления от центра к краям
        const roadDirs = [[0, -1], [0, 1], [-1, 0], [1, 0]];
        for (const [rdx, rdy] of roadDirs) {
            for (let step = 1; step <= half; step++) {
                const tx = cix + rdx * step, ty = ciy + rdy * step;
                if (gMap.getTile(tx, ty) === 'village_square') continue;
                gMap._tiles[`${tx},${ty}`] = 'village_road';
                tiles.push({ ix: tx, iy: ty, type: 'village_road' });
            }
        }

        // Дома — случайные позиции внутри зоны (не на площади и не на дорогах)
        const houseCount = sizeDef.housesMin + Math.floor(rng() * (sizeDef.housesMax - sizeDef.housesMin + 1));
        const houseCandidates = [];
        for (let dy = -half; dy <= half; dy++) {
            for (let dx = -half; dx <= half; dx++) {
                const tx = cix + dx, ty = ciy + dy;
                const t = gMap.getTile(tx, ty);
                if (t !== 'plain') continue; // уже площадь или дорога
                houseCandidates.push([tx, ty]);
            }
        }
        // Перемешать
        for (let i = houseCandidates.length - 1; i > 0; i--) {
            const j = Math.floor(rng() * (i + 1));
            [houseCandidates[i], houseCandidates[j]] = [houseCandidates[j], houseCandidates[i]];
        }
        for (let h = 0; h < Math.min(houseCount, houseCandidates.length); h++) {
            const [tx, ty] = houseCandidates[h];
            gMap._tiles[`${tx},${ty}`] = 'village_house';
            tiles.push({ ix: tx, iy: ty, type: 'village_house' });
            houseTiles.push({ ix: tx, iy: ty });
        }

        // Оставшиеся plain тайлы в зоне → village_road (мощёная площадь)
        for (let dy = -half; dy <= half; dy++) {
            for (let dx = -half; dx <= half; dx++) {
                const tx = cix + dx, ty = ciy + dy;
                if (gMap.getTile(tx, ty) === 'plain') {
                    gMap._tiles[`${tx},${ty}`] = 'village_road';
                    tiles.push({ ix: tx, iy: ty, type: 'village_road' });
                }
            }
        }

        // 4. Зоны производства вокруг деревни
        const productionZoneTiles = {
            farm: null,
            mine: null,
            lumber: null,
        };

        // Ферма: найти 3×4 plain в радиусе size+3..size+8
        productionZoneTiles.farm = _placeProductionZone(
            gMap, rng, cix, ciy, half + 3, half + 8, 3, 4, 'farmland', 'plain'
        );

        // Шахта: если есть stone рядом → 2×3
        productionZoneTiles.mine = _placeProductionZone(
            gMap, rng, cix, ciy, half + 3, half + 12, 2, 3, 'mine_tile', 'stone'
        );

        // Лесоповал: если есть forest рядом → 3×3
        productionZoneTiles.lumber = _placeProductionZone(
            gMap, rng, cix, ciy, half + 3, half + 12, 3, 3, 'lumber_tile', 'forest'
        );

        // Ферма: часть тайлов → farmland_ripe
        if (productionZoneTiles.farm) {
            const ripeCount = Math.floor(productionZoneTiles.farm.length * 0.3);
            for (let r = 0; r < ripeCount && r < productionZoneTiles.farm.length; r++) {
                const ft = productionZoneTiles.farm[r];
                gMap._tiles[`${ft.ix},${ft.iy}`] = 'farmland_ripe';
                ft.type = 'farmland_ripe';
            }
        }

        const name = namePool[vi % namePool.length];
        const personality = PERSONALITIES[Math.floor(rng() * PERSONALITIES.length)];

        villages.push({
            id: `v${vi}`,
            name,
            personality,
            centerIx: cix,
            centerIy: ciy,
            sizeType: sizeDef.type,
            tileSize: sizeDef.tileSize,
            tiles,
            houseTiles,
            productionZoneTiles,
            neighbors: {},
        });
    }

    // 5. Заполнить neighbors
    for (const v of villages) {
        for (const other of villages) {
            if (v === other) continue;
            const dx = other.centerIx - v.centerIx;
            const dy = other.centerIy - v.centerIy;
            const dist = Math.round(Math.sqrt(dx * dx + dy * dy));
            v.neighbors[other.id] = {
                name: other.name,
                dist,
                dir: _getDirection(dx, dy),
            };
        }
    }

    return villages;
}

// ============================================================
//  ЗОНЫ ПРОИЗВОДСТВА
// ============================================================
function _placeProductionZone(gMap, rng, cx, cy, rMin, rMax, zw, zh, newTileType, requiredBiome) {
    // Ищем подходящее место: прямоугольник zw×zh, все тайлы = requiredBiome (или plain для фермы)
    const candidates = [];

    for (let dy = -rMax; dy <= rMax; dy++) {
        for (let dx = -rMax; dx <= rMax; dx++) {
            const d2 = dx * dx + dy * dy;
            if (d2 < rMin * rMin || d2 > rMax * rMax) continue;

            const ox = cx + dx, oy = cy + dy;
            if (!gMap.isInBounds(ox, oy) || !gMap.isInBounds(ox + zw - 1, oy + zh - 1)) continue;

            // Проверить все тайлы прямоугольника
            let ok = true;
            for (let zy = 0; zy < zh && ok; zy++) {
                for (let zx = 0; zx < zw && ok; zx++) {
                    const t = gMap.getTile(ox + zx, oy + zy);
                    if (requiredBiome === 'plain') {
                        if (t !== 'plain') ok = false;
                    } else {
                        // Для stone/forest — допускаем сам биом и plain
                        if (t !== requiredBiome && t !== 'plain') ok = false;
                    }
                }
            }
            if (ok) candidates.push([ox, oy]);
        }
    }

    if (candidates.length === 0) return null;

    const [bx, by] = candidates[Math.floor(rng() * candidates.length)];
    const tiles = [];
    for (let zy = 0; zy < zh; zy++) {
        for (let zx = 0; zx < zw; zx++) {
            const tx = bx + zx, ty = by + zy;
            gMap._tiles[`${tx},${ty}`] = newTileType;
            gMap._heightMap[`${tx},${ty}`] = Math.max(0, gMap.getHeight(tx, ty));
            tiles.push({ ix: tx, iy: ty, type: newTileType });
        }
    }
    return tiles;
}

// ============================================================
//  НАПРАВЛЕНИЕ (8 сторон)
// ============================================================
function _getDirection(dx, dy) {
    const angle = Math.atan2(-dy, dx); // -dy потому что iy растёт вниз
    const deg = ((angle * 180 / Math.PI) + 360) % 360;
    if (deg < 22.5 || deg >= 337.5) return 'E';
    if (deg < 67.5)  return 'NE';
    if (deg < 112.5) return 'N';
    if (deg < 157.5) return 'NW';
    if (deg < 202.5) return 'W';
    if (deg < 247.5) return 'SW';
    if (deg < 292.5) return 'S';
    return 'SE';
}
