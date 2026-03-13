// ============================================================
//  ТАЙЛОВЫЕ ЭФФЕКТЫ — трансформации заклинаний и влияние на юнитов
// ============================================================
import { gameMap } from './Map.js';
import { activeTiles } from './World.js?v=3';

// ============================================================
//  ТАБЛИЦА ТРАНСФОРМАЦИЙ: spell × currentTile → newTile
// ============================================================
// null / undefined = нет эффекта, тайл не меняется
export const TILE_TRANSFORMS = {
    fire: {
        plain:    'burning',
        forest:   'burning',
        water:    'steam',
        village:  'burning',
        ice:      'puddle',
        swamp:    'burning',
        puddle:   'steam',
        // stone, wall, scorched, burning, rubble, steam — не реагируют
    },
    water: {
        plain:    'puddle',
        burning:  'steam',
        scorched: 'puddle',
        stone:    'puddle',
        swamp:    'water',
        // forest, ice, wall, puddle, steam, rubble — не реагируют
    },
    earth: {
        plain:    'wall',
        water:    'swamp',
        puddle:   'plain',
        forest:   'plain',      // + дроп ресурса дерева (обрабатывается вызывающим кодом)
        burning:  'scorched',
        swamp:    'plain',
        ice:      'stone',
        scorched: 'plain',
        // stone, wall, rubble — не реагируют
    },
    wind: {
        // Ветер НЕ трансформирует тайлы через эту таблицу.
        // Он сдувает пар и раздувает огонь — обрабатывается отдельной логикой.
        steam:    'plain',      // сдувает пар
    },
};

// ============================================================
//  ЭФФЕКТЫ ТАЙЛОВ НА ЮНИТОВ
// ============================================================
// speedMult — множитель скорости (1.0 = нормальная)
// dps — урон в секунду (0 = нет)
// passable — true если юнит может войти на тайл
export const TILE_EFFECTS = {
    burning:  { speedMult: 1.0, dps: 15, passable: true  },
    scorched: { speedMult: 0.9, dps: 0,  passable: true  },
    puddle:   { speedMult: 0.6, dps: 0,  passable: true  },
    steam:    { speedMult: 0.8, dps: 0,  passable: true  }, // + скрывает от скелетов
    swamp:    { speedMult: 0.3, dps: 2,  passable: true  },
    wall:     { speedMult: 0.0, dps: 0,  passable: false },
    water:    { speedMult: 0.4, dps: 0,  passable: true  },
    ice:      { speedMult: 1.4, dps: 0,  passable: true  },
    rubble:   { speedMult: 0.7, dps: 0,  passable: true  },
    // plain, forest, stone, village — без модификаторов (speedMult: 1.0, dps: 0)
};

// ============================================================
//  ТАЙМЕРЫ ВРЕМЕННЫХ ТАЙЛОВ
// ============================================================
const TILE_TIMERS = {
    burning: { maxTime: 5.0,  nextType: 'scorched' },
    puddle:  { maxTime: 10.0, nextType: 'plain' },
    steam:   { maxTime: 4.0,  nextType: 'plain' },
};

// ============================================================
//  ДЛИТЕЛЬНОСТИ ФАЗ (экспортируются для рендера в main.js)
// ============================================================
export const IMPACT_DUR = { burning: 0.5, puddle: 0.4, steam: 0.4 };
export const FADING_DUR = { burning: 1.0, puddle: 1.0, steam: 0.8 };

// ============================================================
//  ПРИМЕНЕНИЕ ЗАКЛИНАНИЯ К ТАЙЛУ
// ============================================================
// cause — источник: 'fire' | 'water' | 'earth' | 'wind' | 'artillery' | 'expire' | etc.
// Возвращает новый тип тайла (строку) или null если трансформации нет.
export function applySpellToTile(spell, ix, iy, cause) {
    const currentType = gameMap.getTile(ix, iy);
    if (!currentType) return null;

    const transforms = TILE_TRANSFORMS[spell];
    if (!transforms) return null;

    const newType = transforms[currentType];
    if (newType === undefined || newType === null) return null;

    gameMap.setTile(ix, iy, newType, cause ?? spell);

    // Если новый тайл временный — добавить таймер
    const timerInfo = TILE_TIMERS[newType];
    if (timerInfo) {
        // Убрать старый таймер для этого тайла если есть
        for (let i = activeTiles.length - 1; i >= 0; i--) {
            if (activeTiles[i].ix === ix && activeTiles[i].iy === iy) {
                activeTiles.splice(i, 1);
                break;
            }
        }
        const entry = {
            ix, iy,
            type: newType,
            timer: 0,
            maxTime: timerInfo.maxTime,
            nextType: timerInfo.nextType,
            phase: 'impact',
            phaseTimer: 0,
        };
        if (newType === 'burning') {
            entry.firePixels = Array.from({ length: 3 + Math.floor(Math.random() * 3) }, () => ({
                ox: (Math.random() - 0.5) * 0.6,
                oy: (Math.random() - 0.5) * 0.6,
                phase: Math.random() * Math.PI * 2,
                colorIdx: Math.floor(Math.random() * 5),
                size: 2 + Math.floor(Math.random() * 3),
            }));
        } else if (newType === 'steam') {
            entry.steamPuffs = Array.from({ length: 4 + Math.floor(Math.random() * 3) }, () => ({
                ox: (Math.random() - 0.5) * 0.5,
                oy: (Math.random() - 0.5) * 0.5,
                phase: Math.random() * 30,
                wobblePhase: Math.random() * Math.PI * 2,
                size: 4 + Math.floor(Math.random() * 5),
            }));
        } else if (newType === 'puddle') {
            entry.ripplePhase = Math.random() * 20;
        }
        activeTiles.push(entry);
    } else {
        // Постоянный тайл — убираем старый таймер если был
        for (let i = activeTiles.length - 1; i >= 0; i--) {
            if (activeTiles[i].ix === ix && activeTiles[i].iy === iy) {
                activeTiles.splice(i, 1);
                break;
            }
        }
    }

    return newType;
}

// ============================================================
//  ПРИМЕНЕНИЕ ЗАКЛИНАНИЯ В РАДИУСЕ
// ============================================================
// Возвращает количество трансформированных тайлов.
export function applySpellInRadius(spell, cx, cy, radius, cause) {
    const rcx = Math.round(cx);
    const rcy = Math.round(cy);
    const ri = Math.ceil(radius);
    const r2 = radius * radius;
    let count = 0;
    for (let dy = -ri; dy <= ri; dy++) {
        for (let dx = -ri; dx <= ri; dx++) {
            if (dx * dx + dy * dy > r2) continue;
            const tix = rcx + dx;
            const tiy = rcy + dy;
            if (!gameMap.isInBounds(tix, tiy)) continue;
            if (applySpellToTile(spell, tix, tiy, cause ?? spell)) count++;
        }
    }
    return count;
}

// ============================================================
//  ОБНОВЛЕНИЕ АКТИВНЫХ ТАЙЛОВ (вызывается каждый кадр)
// ============================================================
export function updateActiveTiles(dt) {
    for (let i = activeTiles.length - 1; i >= 0; i--) {
        const tile = activeTiles[i];
        tile.timer     += dt;
        tile.phaseTimer += dt;

        // Переходы между фазами
        if (tile.phase === 'impact') {
            const impactDur = IMPACT_DUR[tile.type] ?? 0.4;
            if (tile.phaseTimer >= impactDur) {
                tile.phase     = 'active';
                tile.phaseTimer = 0;
            }
        } else if (tile.phase === 'active') {
            const fadingDur = FADING_DUR[tile.type];
            if (fadingDur && tile.maxTime > 0 && tile.timer >= tile.maxTime - fadingDur) {
                tile.phase     = 'fading';
                tile.phaseTimer = 0;
            }
        }
        // 'fading' — без дополнительных переходов, тайл удаляется по maxTime

        // Распространение огня на лес
        if (tile.type === 'burning' && tile.timer > 1.0) {
            const neighbors = [
                [tile.ix - 1, tile.iy],
                [tile.ix + 1, tile.iy],
                [tile.ix, tile.iy - 1],
                [tile.ix, tile.iy + 1],
            ];
            for (const [nx, ny] of neighbors) {
                if (!gameMap.isInBounds(nx, ny)) continue;
                const nType = gameMap.getTile(nx, ny);
                if (nType === 'forest' && Math.random() < 0.3 * dt) {
                    applySpellToTile('fire', nx, ny, 'fire');
                }
            }
        }

        if (tile.timer >= tile.maxTime) {
            gameMap.setTile(tile.ix, tile.iy, tile.nextType, 'expire');
            activeTiles.splice(i, 1);
        }
    }
}

// ============================================================
//  ПОЛУЧИТЬ ЭФФЕКТ ТАЙЛА ПО ПОЗИЦИИ
// ============================================================
export function getTileEffect(ix, iy) {
    const tileType = gameMap.getTile(Math.round(ix), Math.round(iy));
    return TILE_EFFECTS[tileType] || null;
}
