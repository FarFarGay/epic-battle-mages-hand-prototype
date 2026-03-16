// ============================================================
//  ЗОНА ПРОИЗВОДСТВА — рост ресурсов + магия
// ============================================================
import { gameMap } from './Map.js';

// Период роста (секунды до +1 harvestReady при rate=1.0, efficiency=1.0)
const GROWTH_PERIOD = { farm: 30, mine: 45, lumber: 35 };

// Тайлы, считающиеся «уничтоженными» для зоны
const DEAD_TILES = new Set([
    'burning', 'rubble', 'swamp', 'water', 'scorched', 'steam', 'puddle',
]);

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

        // Кэш: последнее известное число «ripe» тайлов (для визуала фермы)
        this._lastRipeCount = 0;
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

        // Визуал фермы: синхронизировать farmland ↔ farmland_ripe
        if (this.type === 'farm') {
            this._syncFarmVisual();
        }
    }

    // ── Синхронизация визуала фермы ──────────────────────────
    // Когда harvestReady растёт → превращаем farmland → farmland_ripe
    // Когда harvestReady падает → превращаем farmland_ripe → farmland
    _syncFarmVisual() {
        // Считаем сколько тайлов должны быть ripe
        const targetRipe = Math.min(this.harvestReady, this.tiles.length);
        if (targetRipe === this._lastRipeCount) return;

        let currentRipe = 0;
        for (const t of this.tiles) {
            if (gameMap.getTile(t.ix, t.iy) === 'farmland_ripe') currentRipe++;
        }

        if (currentRipe < targetRipe) {
            // Нужно больше ripe — превращаем farmland → farmland_ripe
            for (const t of this.tiles) {
                if (currentRipe >= targetRipe) break;
                if (gameMap.getTile(t.ix, t.iy) === 'farmland') {
                    gameMap.setTile(t.ix, t.iy, 'farmland_ripe', 'growth');
                    currentRipe++;
                }
            }
        } else if (currentRipe > targetRipe) {
            // Нужно меньше ripe — превращаем farmland_ripe → farmland
            for (const t of this.tiles) {
                if (currentRipe <= targetRipe) break;
                if (gameMap.getTile(t.ix, t.iy) === 'farmland_ripe') {
                    gameMap.setTile(t.ix, t.iy, 'farmland', 'harvest');
                    currentRipe--;
                }
            }
        }

        this._lastRipeCount = targetRipe;
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
