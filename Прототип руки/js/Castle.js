// ============================================================
//  ЗАМОК
// ============================================================
import {
    PIXEL_SCALE, CAMERA_OFFSET_Y,
    CASTLE_BASE_RADIUS, CASTLE_TOWER_HEIGHT,
    WALL_BOUNCE,
} from './constants.js';
import {
    CASTLE_PIXELS, CASTLE_W, CASTLE_H,
    CASTLE_CANNON_PIXELS,
} from './sprites.js';
import { canvas, ctx, drawPixelArt } from './renderer.js';
import { isoToScreen, getDepth } from './isometry.js';

function worldToScreen(wx, wy) {
    const iso = isoToScreen(wx, wy);
    return {
        x: iso.x + canvas.width / 2,
        y: iso.y + canvas.height / 2 - CAMERA_OFFSET_Y,
    };
}

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
    }

    // Точка появления миньонов из замка (позиция перед воротами)
    get spawnPoint() {
        return { ix: this.ix, iy: this.iy + this.baseRadius + 0.5 };
    }

    // Обновление состояния (будущее: движение, поворот пушки, тайминг выстрелов)
    update(dt) {
        if (this.cannon.recoilTimer > 0) {
            this.cannon.recoilTimer = Math.max(0, this.cannon.recoilTimer - dt);
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
            if (obj.state === 'carried' || obj.state === 'lifting') continue;
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
