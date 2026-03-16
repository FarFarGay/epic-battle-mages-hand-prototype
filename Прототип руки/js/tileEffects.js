// ============================================================
//  ТАЙЛОВЫЕ ЭФФЕКТЫ — трансформации заклинаний и влияние на юнитов
// ============================================================
import { gameMap } from './Map.js';
import { activeTiles, findZoneAtTile } from './World.js?v=11';

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
        // Поля и деревни
        farmland:       'burning',
        farmland_ripe:  'burning',
        lumber_tile:    'burning',
        village_square: 'burning',
        village_house:  'burning',
        village_road:   'scorched',
        // stone, wall, scorched, burning, rubble, steam, mine_tile — не реагируют
    },
    water: {
        plain:    'puddle',
        burning:  'steam',
        scorched: 'puddle',
        stone:    'puddle',
        swamp:    'water',
        // farmland — НЕ трансформируется, вода бустит зону производства (handleSpellOnZone)
        // forest, ice, wall, puddle, steam, rubble — не реагируют
    },
    earth: {
        plain:    'rubble',     // след валуна
        forest:   'plain',     // повалил деревья (+ дроп дерева)
        water:    'swamp',
        village:  'rubble',    // разрушил деревню
        burning:  'scorched',
        puddle:   'swamp',
        swamp:    'plain',
        scorched: 'plain',
        // Камень → камнепад (тайл остаётся stone, но спавним камни)
        stone:    'stone',     // маркер: onTileChanged увидит stone→stone
        // Деревня — повреждение по тайлам
        village_square: 'rubble',
        village_house:  'rubble',
        village_road:   'rubble',
        // Производственные тайлы
        lumber_tile:    'plain',   // повалил деревья
        mine_tile:      'rubble',  // камнепад
        farmland:       'rubble',
        farmland_ripe:  'rubble',
        // ice — ускорение валуна, не трансформация
        // wall, rubble — остановка / не реагируют
    },
    wind: {
        steam:    'plain',      // сдувает пар
        // Ветер валит деревья в лесу
        forest:         'plain',
        lumber_tile:    'plain',
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
                const flammable = nType === 'forest' || nType === 'lumber_tile' ||
                    nType === 'farmland' || nType === 'farmland_ripe' ||
                    nType === 'village_house' || nType === 'village_road';
                if (flammable && Math.random() < 0.3 * dt) {
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

// ============================================================
//  ВЗАИМОДЕЙСТВИЕ ЗАКЛИНАНИЙ С ЗОНАМИ ПРОИЗВОДСТВА
// ============================================================
// Вызывается ДО applySpellToTile для каждого затронутого тайла.
// Возвращает true если зона была затронута.
export function handleSpellOnZone(spell, ix, iy) {
    const zone = findZoneAtTile(ix, iy);
    if (!zone) return false;

    switch (spell) {
        case 'water':
            if (zone.type === 'farm') {
                zone.applyBoost(2.0, 60); // ×2 скорость роста на 60 сек
            }
            break;

        case 'wind':
            if (zone.type === 'farm') {
                zone.applyBoost(1.5, 30); // ×1.5 на 30 сек
            }
            break;

        case 'earth':
        case 'fire':
        case 'artillery':
            // Физические эффекты (дроп ресурсов, разрушение) уже обработаны
            // через TILE_TRANSFORMS → onTileChanged → _dropWood/_dropRocks/_dropWheat.
            // Зона пометится damaged автоматически в updateProduction.
            break;
    }

    return true;
}
