// ============================================================
//  ЖИТЕЛЬ ДЕРЕВНИ — автономный юнит, работает в зонах производства
// ============================================================
import { GameObject } from './GameObject.js';
import { PIXEL_SCALE, HEIGHT_TO_SCREEN } from './constants.js';
import { gameMap } from './Map.js';
import { getTileEffect } from './tileEffects.js?v=2';
import { worldToScreen, screenToCanvas } from './isometry.js';
import { ctx, drawPixelArt, drawItemShadow } from './renderer.js';
import {
    VILLAGER_SPRITES,
    VILLAGER_DEAD_PIXELS, VILLAGER_DEAD_W, VILLAGER_DEAD_H,
    RESOURCE_ICONS, RESOURCE_ICON_W, RESOURCE_ICON_H,
} from './villageSprites.js';

// ============================================================
//  КОНСТАНТЫ
// ============================================================
const VILLAGER_SPEED      = 1.2;    // iso units/sec
const ARRIVE_DIST         = 0.8;
const DEAD_REMOVE_TIME    = 10;     // сек до удаления трупа
const ASSIGN_INTERVAL     = 5.0;    // сек между назначениями рабочих
const MAX_WORKERS_PER_ZONE = 3;

const TYPE_HP = { worker: 30, carrier: 30, militia: 60, refugee: 15 };

const PHYSICS_STATES = new Set(['lifting', 'carried', 'thrown', 'bouncing', 'sliding']);

// ============================================================
//  КЛАСС
// ============================================================
export class Villager extends GameObject {
    constructor(ix, iy, villageId, type) {
        super(ix, iy, 0.7, 0.25, 0.82);

        this.villageId = villageId;
        this.type = type;               // 'worker' | 'carrier' | 'militia' | 'refugee'
        this.homeIx = ix;
        this.homeIy = iy;

        // Физика
        this.radius = 0.3;

        // HP
        this.hp = TYPE_HP[type] || 30;
        this.maxHp = this.hp;
        this.dead = false;
        this.pendingRemove = false;
        this.deadTime = 0;
        this.damageWobble = 0;

        // Стейт-машина
        this.state = 'idle';
        this.stateTime = 0;
        this.targetIx = null;
        this.targetIy = null;
        this.targetZone = null;
        this.carriedResource = null;    // 'farm' | 'mine' | 'lumber' | null

        // Для carrier
        this.payload = null;
        this.onArrive = null;

        // Для refugee
        this.targetVillage = null;

        // Для militia
        this.attackDamage = type === 'militia' ? 8 : 0;
        this.attackRange = 0.6;
        this.attackCD = 1.2;
        this.attackTimer = 0;
        this.combatTarget = null;

        // Wander
        this._wanderTarget = null;
        this._wanderTimer = 0;
    }

    // ── Урон от падения ─────────────────────────────────────
    onLand(impactVz) {
        if (impactVz > 2.5) this.hp -= 25;
        if (impactVz > 5.0) this.hp -= 50;
        if (this.hp <= 0) {
            this.hp = 0;
            this.dead = true;
        }
    }

    // ── После приземления ───────────────────────────────────
    onSettle() {
        if (this.dead) {
            this.state = 'dead';
            this.deadTime = 0;
            return;
        }
        this.state = 'idle';
        this.stateTime = 0;
    }

    // ── Единый метод урона ──────────────────────────────────
    takeDamage(amount) {
        if (this.dead || this.pendingRemove) return false;
        if (amount <= 0) return false;
        this.hp = Math.max(0, this.hp - amount);
        this.damageWobble = 0.4;
        if (this.hp <= 0) {
            this.dead = true;
            this.state = 'dead';
            this.stateTime = 0;
            this.deadTime = 0;
            this.carriedResource = null;
            return true;
        }
        return false;
    }

    // ============================================================
    //  UPDATE
    // ============================================================
    update(dt, village, hand, triggerShake) {
        // Физика — приоритет
        if (PHYSICS_STATES.has(this.state)) {
            this.updatePhysics(dt, hand, triggerShake);
            return;
        }

        // Wobble затухание
        if (this.damageWobble > 0) {
            this.damageWobble = Math.max(0, this.damageWobble - dt * 2);
        }

        // Мёртв
        if (this.dead) {
            this.deadTime += dt;
            if (this.deadTime > DEAD_REMOVE_TIME) this.pendingRemove = true;
            return;
        }

        this.stateTime += dt;

        // Урон от тайла (burning, swamp)
        const tileEff = getTileEffect(this.ix, this.iy);
        if (tileEff && tileEff.dps > 0) {
            this.hp -= tileEff.dps * dt;
            if (this.hp <= 0) {
                this.hp = 0;
                this.takeDamage(0.01);
                return;
            }
        }

        switch (this.state) {
            case 'settling':
                if (this.stateTime > 0.3) {
                    this.onSettle();
                }
                break;
            case 'idle':
                this._doIdle(dt, village);
                break;
            case 'working':
                this._doWorking(dt, village);
                break;
            case 'returning':
                this._doReturning(dt, village);
                break;
            case 'carrying':
                this._doCarrying(dt);
                break;
            case 'fleeing':
                this._doFleeing(dt);
                break;
            case 'extinguishing':
                this._doExtinguishing(dt, village);
                break;
            case 'patrolling':
                this._doPatrolling(dt, village);
                break;
            case 'fighting':
                this._doFighting(dt);
                break;
        }
    }

    // ============================================================
    //  СОСТОЯНИЯ
    // ============================================================

    _doIdle(dt, village) {
        if (!this._wanderTarget || this._wanderTimer <= 0) {
            this._wanderTarget = {
                ix: this.homeIx + (Math.random() - 0.5) * 8,
                iy: this.homeIy + (Math.random() - 0.5) * 8,
            };
            this._wanderTimer = 3 + Math.random() * 5;
        }
        this._wanderTimer -= dt;
        this._moveToward(this._wanderTarget.ix, this._wanderTarget.iy, dt, VILLAGER_SPEED * 0.5);
    }

    _doWorking(dt, village) {
        if (!this.targetZone) { this.state = 'idle'; return; }

        this._moveToward(this.targetIx, this.targetIy, dt, VILLAGER_SPEED);

        if (this._distTo(this.targetIx, this.targetIy) < ARRIVE_DIST) {
            if (this.targetZone.harvestReady > 0) {
                this.targetZone.harvest(1);
                this.carriedResource = this.targetZone.type;
                this.state = 'returning';
                this.targetIx = village.centerIx;
                this.targetIy = village.centerIy;
                this.stateTime = 0;
            } else {
                this.state = 'idle';
                this.targetZone = null;
            }
        }
    }

    _doReturning(dt, village) {
        this._moveToward(this.targetIx, this.targetIy, dt, VILLAGER_SPEED);

        if (this._distTo(this.targetIx, this.targetIy) < ARRIVE_DIST) {
            if (this.carriedResource && village) {
                village.addResource(this.carriedResource, 1);
                this.carriedResource = null;
            }
            this.state = 'idle';
            this.targetZone = null;
            this.stateTime = 0;
        }
    }

    _doCarrying(dt) {
        this._moveToward(this.targetIx, this.targetIy, dt, VILLAGER_SPEED * 1.2);

        if (this._distTo(this.targetIx, this.targetIy) < ARRIVE_DIST + 1.0) {
            if (this.onArrive) this.onArrive();
            this.pendingRemove = true;
        }
    }

    _doFleeing(dt) {
        this._moveToward(this.targetIx, this.targetIy, dt, VILLAGER_SPEED * 0.8);

        if (this._distTo(this.targetIx, this.targetIy) < ARRIVE_DIST) {
            if (this.onArrive) this.onArrive();
            this.pendingRemove = true;
        }
    }

    _doExtinguishing(dt, village) {
        this._moveToward(this.targetIx, this.targetIy, dt, VILLAGER_SPEED * 1.3);

        if (this._distTo(this.targetIx, this.targetIy) < ARRIVE_DIST) {
            const tix = Math.round(this.targetIx);
            const tiy = Math.round(this.targetIy);
            if (gameMap.getTile(tix, tiy) === 'burning') {
                gameMap.setTile(tix, tiy, 'plain', 'extinguish');
            }
            this.state = 'returning';
            if (village) {
                this.targetIx = village.centerIx;
                this.targetIy = village.centerIy;
            }
            this.stateTime = 0;
        }
    }

    _doPatrolling(dt, village) {
        if (!this._wanderTarget || this._wanderTimer <= 0) {
            const angle = Math.random() * Math.PI * 2;
            const r = 6 + Math.random() * 4;
            const cx = village ? village.centerIx : this.homeIx;
            const cy = village ? village.centerIy : this.homeIy;
            this._wanderTarget = {
                ix: cx + Math.cos(angle) * r,
                iy: cy + Math.sin(angle) * r,
            };
            this._wanderTimer = 4 + Math.random() * 4;
        }
        this._wanderTimer -= dt;
        this._moveToward(this._wanderTarget.ix, this._wanderTarget.iy, dt, VILLAGER_SPEED);
    }

    _doFighting(dt) {
        if (!this.combatTarget || this.combatTarget.dead || this.combatTarget.pendingRemove) {
            this.combatTarget = null;
            this.state = 'patrolling';
            this.stateTime = 0;
            return;
        }
        const target = this.combatTarget;
        const dist = this._distTo(target.ix, target.iy);

        if (dist > this.attackRange) {
            this._moveToward(target.ix, target.iy, dt, VILLAGER_SPEED);
        }

        this.attackTimer -= dt;
        if (this.attackTimer <= 0 && dist <= this.attackRange + 0.3) {
            this.attackTimer = this.attackCD;
            if (target.takeDamage) {
                target.takeDamage(this.attackDamage);
            }
        }
    }

    // ============================================================
    //  УТИЛИТЫ
    // ============================================================

    _moveToward(tx, ty, dt, speed) {
        const dx = tx - this.ix;
        const dy = ty - this.iy;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < 0.01) return;

        // Замедление от тайла
        const tileEff = getTileEffect(this.ix, this.iy);
        const speedMult = (tileEff && tileEff.speedMult) ? tileEff.speedMult : 1.0;

        const actualSpeed = speed * speedMult;
        const step = Math.min(actualSpeed * dt, dist);
        this.ix += (dx / dist) * step;
        this.iy += (dy / dist) * step;
    }

    _distTo(tx, ty) {
        const dx = this.ix - tx;
        const dy = this.iy - ty;
        return Math.sqrt(dx * dx + dy * dy);
    }

    // ============================================================
    //  РЕНДЕР
    // ============================================================

    draw(hand) {
        const s = worldToScreen(this.ix, this.iy);
        const sprite = VILLAGER_SPRITES[this.type] || VILLAGER_SPRITES.worker;

        if (this.dead) {
            // Труп — лежащий спрайт
            const ox = s.x - (VILLAGER_DEAD_W * PIXEL_SCALE) / 2;
            const oy = s.y - VILLAGER_DEAD_H * PIXEL_SCALE;
            drawPixelArt(ox, oy, VILLAGER_DEAD_PIXELS, PIXEL_SCALE);
            return;
        }

        // Тень
        drawItemShadow(s.x, s.y, sprite.w, sprite.h, this.iz);

        // При захвате — рисуем под рукой (как гоблин)
        if (this.state === 'carried' || this.state === 'lifting') {
            const time = performance.now() / 300;
            const wobbleX = Math.sin(time) * 1.5;
            const wobbleY = Math.cos(time * 1.3) * 1;
            const gripOffsetY = -8;
            const lerpT = this.state === 'lifting' ? (1 - Math.pow(1 - this.liftProgress, 2)) : 1;
            const canvasPos = screenToCanvas(hand.screenX, hand.screenY);
            const groundOx = s.x - (sprite.w * PIXEL_SCALE) / 2;
            const groundOy = s.y - (sprite.h * PIXEL_SCALE) - 4;
            const handOx = canvasPos.x - (sprite.w * PIXEL_SCALE) / 2 + wobbleX;
            const handOy = canvasPos.y - (sprite.h * PIXEL_SCALE) / 2 + gripOffsetY + wobbleY;
            const ox = groundOx + (handOx - groundOx) * lerpT;
            const oy = groundOy + (handOy - groundOy) * lerpT;
            drawPixelArt(ox, oy, sprite.pixels, PIXEL_SCALE);
            return;
        }

        // Позиция спрайта
        const heightOffset = this.iz * HEIGHT_TO_SCREEN;
        let ox = s.x - (sprite.w * PIXEL_SCALE) / 2;
        let oy = s.y - (sprite.h * PIXEL_SCALE) - heightOffset;

        // Damage wobble
        if (this.damageWobble > 0) {
            ox += Math.sin(performance.now() * 0.03) * this.damageWobble * 3;
        }

        drawPixelArt(ox, oy, sprite.pixels, PIXEL_SCALE);

        // Переносимый ресурс — маленький значок над головой
        if (this.carriedResource) {
            const resSprite = RESOURCE_ICONS[this.carriedResource];
            if (resSprite) {
                const iconScale = 2;
                const iconX = s.x - (RESOURCE_ICON_W * iconScale) / 2;
                const iconY = oy - RESOURCE_ICON_H * iconScale - 2;
                drawPixelArt(iconX, iconY, resSprite, iconScale);
            }
        }

        // HP бар (если повреждён)
        if (this.hp < this.maxHp) {
            const barW = sprite.w * PIXEL_SCALE;
            const barH = 2;
            const barX = ox;
            const barY = oy - 4;
            const hpFrac = Math.max(0, this.hp / this.maxHp);
            ctx.fillStyle = '#1a1a2a';
            ctx.fillRect(barX, barY, barW, barH);
            ctx.fillStyle = hpFrac > 0.5 ? '#44aa44' : hpFrac > 0.25 ? '#aaaa33' : '#cc3333';
            ctx.fillRect(barX, barY, barW * hpFrac, barH);
        }
    }
}

// ============================================================
//  НАЗНАЧЕНИЕ РАБОЧИХ НА ЗОНЫ (вызывается из main.js)
// ============================================================
export function assignWorkers(village, villagers, productionZones) {
    // Рабочие этой деревни, которые стоят без дела
    const idle = [];
    for (const w of villagers) {
        if (w.villageId !== village.id) continue;
        if (w.type !== 'worker') continue;
        if (w.dead || w.pendingRemove) continue;
        if (w.state !== 'idle') continue;
        idle.push(w);
    }
    if (idle.length === 0) return;

    // Зоны этой деревни с готовым урожаем
    const ready = [];
    for (const z of productionZones) {
        if (z.villageId !== village.id) continue;
        if (z.harvestReady <= 0 || z.damaged) continue;
        ready.push(z);
    }
    // Сортируем: сначала самые полные
    ready.sort((a, b) => b.harvestReady - a.harvestReady);

    let workerIdx = 0;
    for (const zone of ready) {
        // Сколько рабочих уже идут в эту зону
        let alreadyAssigned = 0;
        for (const w of villagers) {
            if (w.villageId !== village.id) continue;
            if (w.targetZone === zone && w.state === 'working') alreadyAssigned++;
        }
        const needed = Math.min(MAX_WORKERS_PER_ZONE, zone.harvestReady) - alreadyAssigned;

        for (let i = 0; i < needed && workerIdx < idle.length; i++) {
            const worker = idle[workerIdx++];
            worker.targetZone = zone;
            worker.targetIx = zone.centerIx + (Math.random() - 0.5) * 2;
            worker.targetIy = zone.centerIy + (Math.random() - 0.5) * 2;
            worker.state = 'working';
            worker.stateTime = 0;
        }
    }
}

// Интервал назначения
export const ASSIGN_WORKER_INTERVAL = ASSIGN_INTERVAL;
