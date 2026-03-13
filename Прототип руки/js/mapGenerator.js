// ============================================================
//  ГЕНЕРАТОР КАРТЫ — биомы, высоты, ресурсы, декорации
// ============================================================
import { SimplexNoise, fbm, createRNG } from './noise.js';
import { gameMap } from './Map.js';
import { decorations } from './decorations.js?v=3';

// ============================================================
//  БИОМ ПО СЛОЯМ ШУМА
// ============================================================
function getBiome(elevation, moisture) {
    if (elevation < -0.3)                          return 'water';
    if (elevation > 0.6 && moisture > 0.2)         return 'ice';
    if (elevation > 0.5)                           return 'stone';
    if (moisture > 0.15 && elevation > -0.1)       return 'forest';
    return 'plain';
}

// ============================================================
//  ГЕНЕРАЦИЯ КАРТЫ
// ============================================================
export function generateMap(seed) {
    const rng  = createRNG(seed);
    const size = gameMap.size;

    const elevNoise  = new SimplexNoise(seed);
    const moistNoise = new SimplexNoise(seed + 1000);
    const detailNoise = new SimplexNoise(seed + 2000);

    // Сбрасываем тайлы и кэш
    gameMap._tiles      = {};
    gameMap._colorCache = {};
    gameMap._heightMap  = {};

    // Заполняем биомы и высоты
    for (let iy = -size; iy <= size; iy++) {
        for (let ix = -size; ix <= size; ix++) {
            const elev = fbm(elevNoise,  ix * 0.03, iy * 0.03, 4);
            const mois = fbm(moistNoise, ix * 0.04, iy * 0.04, 3);
            const det  = fbm(detailNoise, ix * 0.08, iy * 0.08, 2);

            const biome = getBiome(elev, mois);
            if (biome !== 'plain') {
                gameMap._tiles[`${ix},${iy}`] = biome;
            }

            // Высота: water сидит на -0.3, остальное пропорционально elev
            const rawH = biome === 'water' ? -0.5 : Math.max(-0.3, elev * 1.4);
            gameMap._heightMap[`${ix},${iy}`] = Math.min(1.0, rawH);

            // Вариация цвета: ±8% яркости через detail-шум
            gameMap._colorCache[`${ix},${iy}`] = det * 0.08;
        }
    }

    // Расчистить зону вокруг замка игрока
    _clearZone(gameMap.castlePos.ix, gameMap.castlePos.iy, 8);

    // Расставить деревни
    _placeVillages(rng);

    // Проверить проходимость; при провале — сгладить водные/каменные блоки
    if (!_checkPassability()) {
        _fixPassability();
    }
}

function _clearZone(cx, cy, radius) {
    const r2 = radius * radius;
    for (let dy = -radius; dy <= radius; dy++) {
        for (let dx = -radius; dx <= radius; dx++) {
            if (dx * dx + dy * dy <= r2) {
                const key = `${cx + dx},${cy + dy}`;
                gameMap._tiles[key]  = 'plain'; // явно ставим plain
                // (delete оставило бы дефолт 'plain' через getTile, но явная запись нужна для цветового кэша)
                const h = gameMap._heightMap[key] || 0;
                gameMap._heightMap[key] = Math.max(0, h); // убираем ямы под замком
            }
        }
    }
}

function _placeVillages(rng) {
    const size = gameMap.size;
    const { ix: cx, iy: cy } = gameMap.castlePos;
    const candidates = [];
    const fallback = []; // plain-тайлы без nearBiome — запасной вариант

    for (let iy = -size; iy <= size; iy++) {
        for (let ix = -size; ix <= size; ix++) {
            if (gameMap.getTile(ix, iy) !== 'plain') continue;
            const dCastle = (ix - cx) ** 2 + (iy - cy) ** 2;
            if (dCastle < 225) continue; // < 15 тайлов

            // Проверить есть ли лес или вода в радиусе 5
            let nearBiome = false;
            outer: for (let dy = -5; dy <= 5; dy++) {
                for (let dx = -5; dx <= 5; dx++) {
                    const t = gameMap.getTile(ix + dx, iy + dy);
                    if (t === 'forest' || t === 'water') { nearBiome = true; break outer; }
                }
            }
            if (nearBiome) candidates.push([ix, iy]);
            else fallback.push([ix, iy]);
        }
    }

    const count = 3 + Math.floor(rng() * 4); // 3–6

    // Если кандидатов у биомов мало — добавить fallback
    if (candidates.length < count * 3) {
        for (const fb of fallback) candidates.push(fb);
    }
    const placed = [];

    for (let v = 0; v < count && candidates.length > 0; v++) {
        const idx = Math.floor(rng() * candidates.length);
        const [vx, vy] = candidates[idx];

        // Мин. расстояние 12 тайлов между деревнями
        let tooClose = false;
        for (const [ex, ey] of placed) {
            if ((vx - ex) ** 2 + (vy - ey) ** 2 < 144) { tooClose = true; break; }
        }
        candidates.splice(idx, 1);
        if (tooClose) { v--; continue; }

        placed.push([vx, vy]);
        // Кластер 3×3
        for (let dy = -1; dy <= 1; dy++) {
            for (let dx = -1; dx <= 1; dx++) {
                const key = `${vx + dx},${vy + dy}`;
                gameMap._tiles[key] = 'village';
            }
        }
    }
}

// BFS от позиции замка; возвращает false если связность < 40% тайлов
function _checkPassability() {
    const size   = gameMap.size;
    const total  = (2 * size + 1) ** 2;
    const stride = 2 * size + 1;
    const { ix: sx, iy: sy } = gameMap.castlePos;

    // Кодируем (x,y) в неотрицательный индекс; работает для x,y ∈ [-size, size]
    const encode = (x, y) => (x + size) * stride + (y + size);

    const visited = new Set();
    visited.add(encode(sx, sy));
    const queue = [encode(sx, sy)];

    let head = 0;
    while (head < queue.length) {
        const code = queue[head++];
        const x = Math.floor(code / stride) - size;
        const y = (code % stride) - size;
        for (const [dx, dy] of [[1,0],[-1,0],[0,1],[0,-1]]) {
            const nx = x + dx, ny = y + dy;
            if (!gameMap.isInBounds(nx, ny)) continue;
            const t = gameMap.getTile(nx, ny);
            if (t === 'water' || t === 'stone') continue;
            const ncode = encode(nx, ny);
            if (visited.has(ncode)) continue;
            visited.add(ncode);
            queue.push(ncode);
        }
    }
    return visited.size >= total * 0.4;
}

// Если карта слишком фрагментирована — убираем одиночные водные/каменные тайлы
function _fixPassability() {
    const size = gameMap.size;
    for (let iy = -size; iy <= size; iy++) {
        for (let ix = -size; ix <= size; ix++) {
            const t = gameMap.getTile(ix, iy);
            if (t !== 'water' && t !== 'stone') continue;
            // Считаем соседей того же типа
            let same = 0;
            for (const [dx, dy] of [[1,0],[-1,0],[0,1],[0,-1]]) {
                if (gameMap.getTile(ix + dx, iy + dy) === t) same++;
            }
            // Одиночный непроходимый тайл — заменяем plain
            if (same === 0) {
                gameMap._tiles[`${ix},${iy}`] = 'plain';
            }
        }
    }
}

// ============================================================
//  РАЗМЕЩЕНИЕ РЕСУРСОВ ПО БИОМАМ
// ============================================================
// Возвращает массив { type, ix, iy }
export function placeResources(seed) {
    const rng  = createRNG(seed + 9999);
    const size = gameMap.size;
    const { ix: cx, iy: cy } = gameMap.castlePos;
    const result = [];
    const occupied = new Set();

    // Собираем тайлы по типам (один проход)
    const byBiome = { plain: [], forest: [], stone: [], village: [], any: [] };
    for (let iy = -size; iy <= size; iy++) {
        for (let ix = -size; ix <= size; ix++) {
            const t = gameMap.getTile(ix, iy);
            if (t === 'water') continue;
            const d2 = (ix - cx) ** 2 + (iy - cy) ** 2;
            if (d2 < 9) continue; // < 3 тайла от замка
            if (byBiome[t]) byBiome[t].push([ix, iy]);
            byBiome.any.push([ix, iy]);
        }
    }

    // Граничные тайлы (лес ↔ равнина, камень ↔ равнина)
    const forestEdge = byBiome.forest.filter(([ix, iy]) => {
        for (const [dx, dy] of [[1,0],[-1,0],[0,1],[0,-1]]) {
            if (gameMap.getTile(ix + dx, iy + dy) === 'plain') return true;
        }
        return false;
    });
    const stoneEdge = byBiome.stone.filter(([ix, iy]) => {
        for (const [dx, dy] of [[1,0],[-1,0],[0,1],[0,-1]]) {
            if (gameMap.getTile(ix + dx, iy + dy) === 'plain') return true;
        }
        return false;
    });

    // Пшеница (typeIndex 0): plain + village, кластеры 3-5
    _scatter(rng, [...byBiome.plain, ...byBiome.village], 0, 80, 120, 4, 2, occupied, result);
    // Камень (typeIndex 1): stone + stoneEdge, кластеры 2-4
    _scatter(rng, [...byBiome.stone, ...stoneEdge], 1, 60, 80, 3, 2, occupied, result);
    // Дерево (typeIndex 2): forest + forestEdge, кластеры 3-6
    _scatter(rng, [...byBiome.forest, ...forestEdge], 2, 60, 80, 4, 2, occupied, result);
    // Железо (typeIndex 3): stone, далеко от замка
    const deepStone = byBiome.stone.filter(([ix, iy]) => (ix - cx) ** 2 + (iy - cy) ** 2 > 400);
    _scatter(rng, deepStone, 3, 20, 30, 2, 1, occupied, result);
    // Свитки (typeIndex 4): любой тайл, далеко, одиночные
    const farAny = byBiome.any.filter(([ix, iy]) => (ix - cx) ** 2 + (iy - cy) ** 2 > 625);
    _scatter(rng, farAny, 4, 10, 15, 1, 1, occupied, result);

    return result;
}

function _scatter(rng, tiles, typeIdx, minTotal, maxTotal, clusterSize, clusterRadius, occupied, out) {
    if (tiles.length === 0) return;
    const target = minTotal + Math.floor(rng() * (maxTotal - minTotal + 1));
    let placed = 0;
    let attempts = 0;

    while (placed < target && attempts < target * 20) {
        attempts++;
        const [bx, by] = tiles[Math.floor(rng() * tiles.length)];
        const count = 1 + Math.floor(rng() * clusterSize);
        for (let k = 0; k < count && placed < target; k++) {
            const ox = Math.round((rng() - 0.5) * clusterRadius * 2);
            const oy = Math.round((rng() - 0.5) * clusterRadius * 2);
            const ix = bx + ox, iy = by + oy;
            if (!gameMap.isInBounds(ix, iy)) continue;
            if (gameMap.getTile(ix, iy) === 'water') continue;
            const key = `${ix},${iy}`;
            if (occupied.has(key)) continue;
            occupied.add(key);
            out.push({ type: typeIdx, ix, iy });
            placed++;
        }
    }
}

// ============================================================
//  РАЗМЕЩЕНИЕ ДЕКОРАЦИЙ
// ============================================================
export function placeDecorations(seed) {
    const rng  = createRNG(seed + 77777);
    const size = gameMap.size;

    decorations.length = 0;

    // Вероятности, спрайты и разброс позиции по биому.
    // offset = радиус случайного смещения (±offset тайлов).
    // plain: prob=0.25, список 4:1 → ~20% GRASS_1, ~5% TREE_3 на тайл.
    const decoByBiome = {
        forest:  { prob: 0.50, sprites: ['TREE_1', 'TREE_2', 'TREE_3'],                    offset: 0.4 },
        stone:   { prob: 0.30, sprites: ['ROCK_1', 'ROCK_2'],                              offset: 0.3 },
        plain:   { prob: 0.25, sprites: ['GRASS_1','GRASS_1','GRASS_1','GRASS_1','TREE_3'], offset: 0.2 },
        village: { prob: 0.80, sprites: ['HOUSE_1', 'HOUSE_2'],                            offset: 0.4 },
        ice:     { prob: 0.15, sprites: ['ICE_CRACK'],                                     offset: 0.2 },
    };

    // Viewport/bound-check: только внутри карты
    for (let iy = -size; iy <= size; iy++) {
        for (let ix = -size; ix <= size; ix++) {
            const tileType = gameMap.getTile(ix, iy);
            const rule = decoByBiome[tileType];
            if (!rule) continue;
            if (rng() > rule.prob) continue;

            const spriteKey = rule.sprites[Math.floor(rng() * rule.sprites.length)];
            const sp = rule.offset;
            const offsetX = (rng() - 0.5) * sp * 2;
            const offsetY = (rng() - 0.5) * sp * 2;
            decorations.push({ ix: ix + offsetX, iy: iy + offsetY, tileIx: ix, tileIy: iy, spriteKey });
        }
    }

    // Пустые village-тайлы (без дома) получают каменные плитки
    for (let iy = -size; iy <= size; iy++) {
        for (let ix = -size; ix <= size; ix++) {
            if (gameMap.getTile(ix, iy) !== 'village') continue;
            const hasDeco = decorations.some(d => d.tileIx === ix && d.tileIy === iy);
            if (hasDeco) continue;
            decorations.push({
                ix: ix + (rng() - 0.5) * 0.3,
                iy: iy + (rng() - 0.5) * 0.3,
                tileIx: ix, tileIy: iy,
                spriteKey: 'SLAB_1',
            });
        }
    }
}
