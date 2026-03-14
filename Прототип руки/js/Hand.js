// ============================================================
//  РУКА
// ============================================================
import {
    PIXEL_SCALE, THROW_VZ_BASE, THROW_SCALE, MAX_THROW_SPEED,
    VELOCITY_HISTORY
} from './constants.js';
import { HAND_OPEN_PIXELS, HAND_CLOSED_PIXELS } from './sprites.js?v=6';
import { drawPixelArt, drawShadow } from './renderer.js';
import { screenToCanvas } from './isometry.js';

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
        this.prevIsoX = 0;
        this.prevIsoY = 0;
        this.velocityHistory = [];
        this.selectedMinions = [];    // индексы выделенных миньонов (ПКМ-выделение)
        this.minionGrabIso = null;    // {ix, iy} — позиция подбора гоблина (для поддержки тумана)
        this.grabbedSpell = null;   // 'fireball' | 'water' | 'earth' | 'wind' | null
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

    draw() {
        this._drawHand();
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
