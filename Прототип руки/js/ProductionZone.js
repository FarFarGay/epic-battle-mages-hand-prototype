// ============================================================
//  ЗОНА ПРОИЗВОДСТВА — рост ресурсов + магия
// ============================================================
import { gameMap } from './Map.js';
import { decorations } from './decorations.js?v=10';

// Период роста (секунды до +1 harvestReady при rate=1.0, efficiency=1.0)
const GROWTH_PERIOD = { farm: 30, mine: 45, lumber: 35 };

// Тайлы, считающиеся «уничтоженными» для зоны
const DEAD_TILES = new Set([
    'burning', 'rubble', 'swamp', 'water', 'scorched', 'steam', 'puddle',
]);

// Спрайты ресурсов по типу зоны
const ZONE_SPRITES = {
    lumber: ['TREE_1', 'TREE_2', 'TREE_3'],
    mine:   ['ROCK_1', 'ROCK_2'],
};

// Тип тайла зоны (для проверки что тайл жив)
const ZONE_TILE_TYPE = {
    lumber: 'lumber_tile',
    mine:   'mine_tile',
};

export class ProductionZone {
    /**
     * @param {string} id           — уникальный id (напр. "v0_farm")
     * @param {'farm'|'mine'|'lumber'} type
     * @param {number} centerIx
     * @param {number} centerIy
     * @param {{ix:number, iy:number}[]} tiles
     * @param {string} villageId
     */
    constructor(id, type, centerIx, centerIy, tiles, villageId) {
        this.id         = id;
        this.type       = type;
        this.centerIx   = centerIx;
        this.centerIy   = centerIy;
        this.tiles      = tiles;
        this.villageId  = villageId;

        this.growthTimer   = 0;
        this.growthRate    = 1.0;
        this.harvestReady  = 0;
        this.maxHarvest    = 10;

        this.damaged       = false;
        this.boosted       = false;
        this.boostTimer    = 0;
        this.boostMult     = 1.0;

        // Кэш: последний синхронизированный визуал (тайлы для farm, декорации для lumber/mine)
        this._lastSyncCount = 0;

        // Set координат тайлов зоны (для быстрого поиска декораций)
        this._tileKeys = new Set(tiles.map(t => `${t.ix},${t.iy}`));
    }

    // ── Тик производства ─────────────────────────────────────
    updateProduction(dt) {
        if (this.damaged) return;

        // Считаем живые тайлы
        let alive = 0;
        for (const t of this.tiles) {
            const tileType = gameMap.getTile(t.ix, t.iy);
            if (!DEAD_TILES.has(tileType)) alive++;
        }

        if (alive === 0) {
            this.damaged = true;
            return;
        }

        const efficiency = alive / this.tiles.length;
        const rate = this.growthRate * (this.boosted ? this.boostMult : 1.0) * efficiency;
        const period = GROWTH_PERIOD[this.type];

        this.growthTimer += dt * rate;

        if (this.growthTimer >= period) {
            this.growthTimer -= period;
            if (this.harvestReady < this.maxHarvest) {
                this.harvestReady++;
            }
        }

        // Буст-таймер
        if (this.boosted) {
            this.boostTimer -= dt;
            if (this.boostTimer <= 0) {
                this.boosted   = false;
                this.boostMult = 1.0;
                this.boostTimer = 0;
            }
        }

        // Синхронизация визуала
        if (this.type === 'farm') {
            this._syncFarmVisual();
        } else {
            this._syncResourceVisual();
        }
    }

    // ── Синхронизация визуала фермы ──────────────────────────
    // farmland ↔ farmland_ripe через setTile → onTileChanged → декорации
    _syncFarmVisual() {
        const targetRipe = Math.min(this.harvestReady, this.tiles.length);
        if (targetRipe === this._lastSyncCount) return;

        let currentRipe = 0;
        for (const t of this.tiles) {
            if (gameMap.getTile(t.ix, t.iy) === 'farmland_ripe') currentRipe++;
        }

        if (currentRipe < targetRipe) {
            for (const t of this.tiles) {
                if (currentRipe >= targetRipe) break;
                if (gameMap.getTile(t.ix, t.iy) === 'farmland') {
                    gameMap.setTile(t.ix, t.iy, 'farmland_ripe', 'growth');
                    currentRipe++;
                }
            }
        } else if (currentRipe > targetRipe) {
            for (const t of this.tiles) {
                if (currentRipe <= targetRipe) break;
                if (gameMap.getTile(t.ix, t.iy) === 'farmland_ripe') {
                    gameMap.setTile(t.ix, t.iy, 'farmland', 'harvest');
                    currentRipe--;
                }
            }
        }

        this._lastSyncCount = targetRipe;
    }

    // ── Синхронизация визуала шахты/лесоповала ───────────────
    // Добавляет/не трогает декорации (TREE/ROCK) на тайлах зоны
    _syncResourceVisual() {
        const targetCount = Math.min(this.harvestReady, this.tiles.length);
        if (targetCount === this._lastSyncCount) return;

        const spriteKeys = ZONE_SPRITES[this.type];
        const tileType   = ZONE_TILE_TYPE[this.type];
        const spriteSet  = new Set(spriteKeys);

        // Подсчёт текущих декораций зоны
        const tilesWithDeco = new Set();
        for (const d of decorations) {
            if (this._tileKeys.has(`${d.tileIx},${d.tileIy}`) && spriteSet.has(d.spriteKey)) {
                tilesWithDeco.add(`${d.tileIx},${d.tileIy}`);
            }
        }

        let currentCount = tilesWithDeco.size;

        if (currentCount < targetCount) {
            // Нужно больше декораций — добавить на тайлы без них
            for (const t of this.tiles) {
                if (currentCount >= targetCount) break;
                const key = `${t.ix},${t.iy}`;
                if (tilesWithDeco.has(key)) continue;
                if (gameMap.getTile(t.ix, t.iy) !== tileType) continue;

                const spriteKey = spriteKeys[Math.floor(Math.random() * spriteKeys.length)];
                decorations.push({
                    ix: t.ix + (Math.random() - 0.5) * 0.3,
                    iy: t.iy + (Math.random() - 0.5) * 0.3,
                    tileIx: t.ix, tileIy: t.iy,
                    spriteKey,
                });
                currentCount++;
            }
        }
        // Не убираем лишние — они удаляются при ручном сборе или разрушении тайлов

        this._lastSyncCount = targetCount;
    }

    // ── Секунды до следующего harvestReady (для дебага) ─────
    get timeToNext() {
        if (this.damaged || this.harvestReady >= this.maxHarvest) return -1;
        const period = GROWTH_PERIOD[this.type];
        const remaining = period - this.growthTimer;
        return remaining;
    }

    // ── Сбор урожая ──────────────────────────────────────────
    harvest(amount) {
        const collected = Math.min(amount, this.harvestReady);
        this.harvestReady -= collected;
        if (this.type === 'farm') this._syncFarmVisual();
        return collected;
    }

    // ── Буст от магии ────────────────────────────────────────
    applyBoost(multiplier, duration) {
        this.boosted   = true;
        this.boostMult = multiplier;
        this.boostTimer = duration;
    }
}
