// ============================================================
//  ЗАМОК
// ============================================================
import {
    CASTLE_BASE_RADIUS, CASTLE_TOWER_HEIGHT,
    WALL_BOUNCE,
    GOBLIN_MAX, GOBLIN_SPAWN_DURATION, GOBLIN_FOOD_COST, GOBLIN_FOOD_TYPE,
} from './constants.js';
import {
    CASTLE_PIXELS, CASTLE_W, CASTLE_H,
    CASTLE_CANNON_PIXELS,
} from './sprites.js?v=3';
import { ctx, drawPixelArt } from './renderer.js';
import { getDepth, worldToScreen } from './isometry.js';

export class Castle {
    constructor(ix, iy) {
        this.ix = ix;
        this.iy = iy;

        // Для будущего движения замка
        this.vx = 0;
        this.vy = 0;

        // Пушка
        this.cannon = {
            recoilTimer:    0,    // убывающий таймер анимации отдачи
            recoilDuration: 0.25, // длительность отдачи в секундах
        };

        // Коллизия
        this.baseRadius    = CASTLE_BASE_RADIUS;
        this.towerHeight   = CASTLE_TOWER_HEIGHT;

        // Производство гоблинов
        this.maxMinions  = GOBLIN_MAX;
        this.production  = {
            active:        false,           // игрок запустил производство
            progress:      0,              // секунд прогресса текущего гоблина (0 = не начат)
            duration:      GOBLIN_SPAWN_DURATION,
            cost:          GOBLIN_FOOD_COST,
            foodTypeIndex: GOBLIN_FOOD_TYPE,
        };
        this.pendingSpawn = false;         // true → main.js должен заспавнить гоблина
    }

    // Точка появления миньонов из замка (позиция перед воротами)
    get spawnPoint() {
        return { ix: this.ix, iy: this.iy + this.baseRadius + 0.5 };
    }

    // Обновление состояния
    update(dt, minions, castleResources) {
        if (this.cannon.recoilTimer > 0) {
            this.cannon.recoilTimer = Math.max(0, this.cannon.recoilTimer - dt);
        }

        // Производство гоблинов
        this.pendingSpawn = false;

        const prod = this.production;
        // Скелеты (isUndead) не занимают слоты живых гоблинов
        const aliveCount = minions.filter(m => m.state !== 'dead' && !m.isUndead).length;

        if (prod.progress > 0) {
            // Завершаем текущего (даже если производство на паузе или замок полон)
            prod.progress += dt;
            if (prod.progress >= prod.duration) {
                prod.progress = 0;
                if (aliveCount < this.maxMinions) {
                    this.pendingSpawn = true;
                }
                // Если замок полон — гоблин готов, но не спавнится. Еда уже потрачена.
            }
        } else if (prod.active && aliveCount < this.maxMinions && castleResources[prod.foodTypeIndex] >= prod.cost) {
            // Начинаем нового гоблина (только если есть место)
            castleResources[prod.foodTypeIndex] -= prod.cost;
            prod.progress += dt;
        }
    }

    // Инициировать выстрел пушки (вызывается из будущей системы атак)
    fireCannon() {
        this.cannon.recoilTimer = this.cannon.recoilDuration;
    }

    // ============================================================
    //  КОЛЛИЗИЯ
    // ============================================================
    // Разрешает столкновения замка со всеми переданными объектами
    pushObjects(objects) {
        for (const obj of objects) {
            if (obj.state === 'carried' || obj.state === 'lifting' || obj.state === 'goblin_carried' || obj.state === 'returning') continue;
            if (obj.iz > this.towerHeight) continue;

            const dx = obj.ix - this.ix;
            const dy = obj.iy - this.iy;
            const dist = Math.sqrt(dx * dx + dy * dy);
            const minDist = this.baseRadius + (obj.radius ?? 0.35);

            if (dist >= minDist || dist < 0.0001) continue;

            // Вытолкнуть объект за пределы радиуса замка
            const nx = dx / dist;
            const ny = dy / dist;
            const overlap = minDist - dist;
            obj.ix += nx * overlap;
            obj.iy += ny * overlap;

            // Отразить составляющую скорости вдоль нормали (как от стены)
            const dot = obj.vx * nx + obj.vy * ny;
            if (dot < 0) {
                obj.vx -= (1 + WALL_BOUNCE) * dot * nx;
                obj.vy -= (1 + WALL_BOUNCE) * dot * ny;

                // Разбудить лежащие объекты
                if (obj.state === 'idle' || obj.state === 'settling') {
                    obj.state = 'sliding';
                    obj.stateTime = 0;
                }
            }
        }
    }

    // ============================================================
    //  РЕНДЕР
    // ============================================================
    getRenderEntries() {
        const base = getDepth(this.ix, this.iy);
        return [{ type: 'castle', depth: base }];
    }

    draw() {
        const SCALE = 8; // 12 raw px × 8 = 96px = ровно 4× высота гоблина (8 px × 3 = 24px)
        const s = worldToScreen(this.ix, this.iy);
        const ox = Math.round(s.x - (CASTLE_W * SCALE) / 2);
        const oy = Math.round(s.y - CASTLE_H * SCALE - 4);

        // Тень замка на земле
        ctx.save();
        ctx.globalAlpha = 0.35;
        ctx.fillStyle = '#000';
        ctx.beginPath();
        ctx.ellipse(s.x, s.y + 6, CASTLE_W * SCALE * 0.44, CASTLE_W * SCALE * 0.17, 0, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();

        drawPixelArt(ox, oy, CASTLE_PIXELS, SCALE);

        // Ствол пушки с анимацией отдачи
        const recoilFrac = this.cannon.recoilDuration > 0
            ? this.cannon.recoilTimer / this.cannon.recoilDuration
            : 0;
        const recoilPx = Math.round(Math.sin(recoilFrac * Math.PI) * 4);
        const cannonOx = ox + 3 * SCALE - recoilPx;
        const cannonOy = oy + 4 * SCALE;
        drawPixelArt(cannonOx, cannonOy, CASTLE_CANNON_PIXELS, SCALE);
    }
}
