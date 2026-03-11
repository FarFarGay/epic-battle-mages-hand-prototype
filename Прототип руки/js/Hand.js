// ============================================================
//  РУКА
// ============================================================
import {
    PIXEL_SCALE, THROW_VZ_BASE, THROW_SCALE, MAX_THROW_SPEED,
    VELOCITY_HISTORY
} from './constants.js';
import { FLAG_PIXELS, HAND_OPEN_PIXELS, HAND_CLOSED_PIXELS, FLAG_W as SPR_FLAG_W, FLAG_H as SPR_FLAG_H } from './sprites.js';
import { canvas, ctx, drawPixelArt, drawShadow } from './renderer.js';
import { camera } from './isometry.js';

// Re-export so other modules can use FLAG_W/FLAG_H from sprites via Hand if needed
// (they're also exported from constants.js directly)

function screenToCanvas(sx, sy) {
    return {
        x: (sx - canvas.width / 2 + camera.x) / camera.zoom + canvas.width / 2,
        y: (sy - canvas.height / 2 + camera.y) / camera.zoom + canvas.height / 2,
    };
}

export class Hand {
    constructor() {
        this.screenX = 0;
        this.screenY = 0;
        this.isoX = 0;
        this.isoY = 0;
        this.state = 'open'; // 'open', 'closing', 'closed', 'opening'
        this.animProgress = 0;
        this.grabbedItem = null;
        this.grabbedMinion = null;
        this.grabbedFlag = false;
        this.prevIsoX = 0;
        this.prevIsoY = 0;
        this.velocityHistory = [];
        this.prevScreenXForShake = 0;
        this.shakeHistory = [];       // { dx, t } для определения встряхивания
        this.selectedMinions = [];    // индексы выделенных миньонов (пока флаг в руке)
        this.minionGrabIso = null;    // {ix, iy} — позиция подбора гоблина (для поддержки тумана)
    }

    update(dt, mouseX, mouseY, canvas, screenToIso) {
        // Плавное движение руки к курсору
        const lerp = 1 - Math.pow(0.001, dt);
        this.screenX += (mouseX - this.screenX) * lerp;
        this.screenY += (mouseY - this.screenY) * lerp;

        // Конвертируем позицию руки в изометрические координаты
        const iso = screenToIso(this.screenX, this.screenY, canvas);
        this.isoX = iso.x;
        this.isoY = iso.y;

        // Трекинг скорости руки для расчёта броска
        if (dt > 0) {
            const hvx = (this.isoX - this.prevIsoX) / dt;
            const hvy = (this.isoY - this.prevIsoY) / dt;
            this.velocityHistory.push({ vx: hvx, vy: hvy, dt: dt });
            if (this.velocityHistory.length > VELOCITY_HISTORY) {
                this.velocityHistory.shift();
            }
        }
        this.prevIsoX = this.isoX;
        this.prevIsoY = this.isoY;

        // Анимация захвата/отпускания
        if (this.state === 'closing' || this.state === 'opening') {
            this.animProgress += dt * 5;
            if (this.animProgress >= 1) {
                this.animProgress = 1;
                this.state = this.state === 'closing' ? 'closed' : 'open';
            }
        }
    }

    calculateThrowVelocity(typeDef) {
        const history = this.velocityHistory;
        if (history.length === 0) return { vx: 0, vy: 0, vz: THROW_VZ_BASE };

        let totalWeight = 0;
        let avgVx = 0;
        let avgVy = 0;

        for (let i = 0; i < history.length; i++) {
            const weight = (i + 1);
            avgVx += history[i].vx * weight;
            avgVy += history[i].vy * weight;
            totalWeight += weight;
        }

        avgVx /= totalWeight;
        avgVy /= totalWeight;

        const massScale = 1.0 / Math.sqrt(typeDef.mass);
        const speed = Math.sqrt(avgVx * avgVx + avgVy * avgVy);

        let tvx = avgVx * THROW_SCALE * massScale;
        let tvy = avgVy * THROW_SCALE * massScale;
        let tvz = THROW_VZ_BASE * massScale + speed * 0.3;

        // Ограничиваем максимальную скорость
        const tSpeed = Math.sqrt(tvx * tvx + tvy * tvy);
        if (tSpeed > MAX_THROW_SPEED) {
            const scale = MAX_THROW_SPEED / tSpeed;
            tvx *= scale;
            tvy *= scale;
        }

        return { vx: tvx, vy: tvy, vz: Math.min(tvz, MAX_THROW_SPEED) };
    }

    checkFlagShake(dismissCallback) {
        const dsx = this.screenX - this.prevScreenXForShake;
        const now = performance.now();
        if (Math.abs(dsx) > 2) {
            this.shakeHistory.push({ dx: dsx, t: now });
        }
        // Держим только последние 0.6с
        const cutoff = now - 600;
        while (this.shakeHistory.length > 0 && this.shakeHistory[0].t < cutoff) {
            this.shakeHistory.shift();
        }
        // Считаем смены направления
        let signChanges = 0;
        let prevSign = 0;
        for (const h of this.shakeHistory) {
            const s = Math.sign(h.dx);
            if (prevSign !== 0 && s !== prevSign) signChanges++;
            prevSign = s;
        }
        if (signChanges >= 5) {
            this.shakeHistory = [];
            dismissCallback();
        }
        this.prevScreenXForShake = this.screenX;
    }

    draw() {
        // Рисуем захваченные предметы и руку
        // Захваченные объекты рисуются внешними методами (Item.draw / Minion.draw)
        // Флаг в руке
        if (this.grabbedFlag) {
            const cp = screenToCanvas(this.screenX, this.screenY);
            const wobbleX = Math.sin(performance.now() / 300) * 1.5;
            const wobbleY = Math.cos(performance.now() / 230) * 1;
            this._drawFlagAt(
                cp.x - (SPR_FLAG_W * PIXEL_SCALE) / 2 + wobbleX,
                cp.y - (SPR_FLAG_H * PIXEL_SCALE) / 2 - 8 + wobbleY,
                false
            );
        }
        this._drawHand();
    }

    _drawFlagAt(sx, sy, isHovered) {
        if (isHovered) {
            ctx.save();
            ctx.globalAlpha = 0.3 + 0.15 * Math.sin(performance.now() / 300);
            ctx.strokeStyle = '#ffff44';
            ctx.lineWidth = 2;
            ctx.strokeRect(sx - 4, sy - 4, SPR_FLAG_W * PIXEL_SCALE + 8, SPR_FLAG_H * PIXEL_SCALE + 8);
            ctx.restore();
        }
        drawPixelArt(sx, sy, FLAG_PIXELS, PIXEL_SCALE);
    }

    _drawHand() {
        const canvasPos = screenToCanvas(this.screenX, this.screenY);
        const sx = canvasPos.x;
        const sy = canvasPos.y;

        // Тень руки
        drawShadow(sx, sy + 15, 10, 11);

        const handW = 10;
        const handH = 12;

        let pixels;
        if (this.state === 'open') {
            pixels = HAND_OPEN_PIXELS;
        } else if (this.state === 'closed') {
            pixels = HAND_CLOSED_PIXELS;
        } else {
            // Анимация — интерполяция между открытой и закрытой
            const t = this.state === 'closing' ? this.animProgress : 1 - this.animProgress;
            pixels = t < 0.5 ? HAND_OPEN_PIXELS : HAND_CLOSED_PIXELS;
        }

        // Рисуем руку центрируя на курсоре
        const ox = sx - (handW * PIXEL_SCALE) / 2;
        const oy = sy - (handH * PIXEL_SCALE) / 2 - 20; // поднимаем руку над поверхностью

        // Если что-то захвачено, немного покачиваем
        let wobbleX = 0, wobbleY = 0;
        if (this.grabbedItem !== null) {
            const time = performance.now() / 300;
            wobbleX = Math.sin(time) * 1.5;
            wobbleY = Math.cos(time * 1.3) * 1;
        }

        drawPixelArt(ox + wobbleX, oy + wobbleY, pixels, PIXEL_SCALE);
    }
}
