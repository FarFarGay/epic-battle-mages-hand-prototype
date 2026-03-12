// ============================================================
//  ОГНЕННЫЙ ШАР — снаряд-заклинание
// ============================================================
import { GameObject } from './GameObject.js';
import {
    MAX_BOUNCES, PIXEL_SCALE, HEIGHT_TO_SCREEN,
    FIREBALL_MASS, FIREBALL_BOUNCINESS, FIREBALL_FRICTION, FIREBALL_COOLDOWN,
} from './constants.js';
import { FIREBALL_PIXELS, FIREBALL_W, FIREBALL_H } from './sprites.js';
import { ctx, drawPixelArt, drawItemShadow } from './renderer.js';
import { worldToScreen, screenToCanvas } from './isometry.js';

export class Fireball extends GameObject {
    constructor() {
        super(0, 0, FIREBALL_MASS, FIREBALL_BOUNCINESS, FIREBALL_FRICTION);
        this.state = 'ready';
        this.cooldown = 0;
        this.pendingExplosion = false;
        this._exploded = false;
    }

    reset() {
        this.ix = 0; this.iy = 0; this.iz = 0;
        this.vx = 0; this.vy = 0; this.vz = 0;
        this.state = 'ready';
        this.stateTime = 0;
        this.liftProgress = 0;
        this.bounceCount = 0;
        this.cooldown = 0;
        this.pendingExplosion = false;
        this._exploded = false;
    }

    onLand(impactVz) {
        // Взрываемся при первом касании земли
        if (!this._exploded) {
            this._exploded = true;
            this.vx = 0;
            this.vy = 0;
            this.bounceCount = MAX_BOUNCES + 1; // предотвращаем отскок
            this.pendingExplosion = true;
        }
    }

    update(dt, hand, triggerShake) {
        // Обратный отсчёт перезарядки
        if (this.cooldown > 0) {
            this.cooldown = Math.max(0, this.cooldown - dt);
            if (this.cooldown === 0 && this.state === 'done') {
                this.state = 'ready';
            }
        }

        if (this.state === 'ready' || this.state === 'done') return;

        if (this.state === 'settling') {
            this.stateTime += dt;
            if (this.stateTime > 0.08) {
                this.state = 'done';
                this.cooldown = FIREBALL_COOLDOWN;
            }
            return;
        }

        this.updatePhysics(dt, hand, triggerShake);

        // После физики: если взрыв помечен — переходим к settling
        if (this.pendingExplosion && this.state !== 'done' && this.state !== 'settling') {
            this.state = 'settling';
            this.stateTime = 0;
        }
    }

    draw(hand) {
        if (this.state === 'ready' || this.state === 'done') return;

        const s = worldToScreen(this.ix, this.iy);
        drawItemShadow(s.x, s.y, FIREBALL_W, FIREBALL_H, this.iz);

        let ox, oy;

        if (this.state === 'carried' || this.state === 'lifting') {
            const lerpT = this.state === 'lifting' ? (1 - Math.pow(1 - this.liftProgress, 2)) : 1;
            const cp = screenToCanvas(hand.screenX, hand.screenY);
            const groundOx = s.x - (FIREBALL_W * PIXEL_SCALE) / 2;
            const groundOy = s.y - (FIREBALL_H * PIXEL_SCALE) - 4;
            const handOx = cp.x - (FIREBALL_W * PIXEL_SCALE) / 2;
            const handOy = cp.y - (FIREBALL_H * PIXEL_SCALE) / 2 - 8;
            ox = groundOx + (handOx - groundOx) * lerpT;
            oy = groundOy + (handOy - groundOy) * lerpT;
        } else {
            const heightOffset = this.iz * HEIGHT_TO_SCREEN;
            ox = s.x - (FIREBALL_W * PIXEL_SCALE) / 2;
            oy = s.y - (FIREBALL_H * PIXEL_SCALE) - 4 - heightOffset;
        }

        ctx.save();
        ctx.shadowColor = '#ff6600';
        ctx.shadowBlur = 18;
        drawPixelArt(ox, oy, FIREBALL_PIXELS, PIXEL_SCALE);
        ctx.restore();
    }
}
