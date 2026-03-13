// ============================================================
//  СНАРЯД ЗАКЛИНАНИЯ — бросаемый снаряд для water/earth/wind
// ============================================================
import { GameObject } from './GameObject.js';
import {
    MAX_BOUNCES, PIXEL_SCALE, HEIGHT_TO_SCREEN,
    FIREBALL_MASS, FIREBALL_BOUNCINESS, FIREBALL_FRICTION,
} from './constants.js';
import {
    WATER_SPELL_PIXELS, WATER_SPELL_W, WATER_SPELL_H,
    EARTH_SPELL_PIXELS, EARTH_SPELL_W, EARTH_SPELL_H,
    WIND_SPELL_PIXELS, WIND_SPELL_W, WIND_SPELL_H,
} from './sprites.js?v=3';
import { ctx, drawPixelArt, drawItemShadow } from './renderer.js';
import { worldToScreen, screenToCanvas } from './isometry.js';

const TRAIL_MAX = 20;

const SPELL_SPRITES = {
    water: { pixels: WATER_SPELL_PIXELS, w: WATER_SPELL_W, h: WATER_SPELL_H, glow: '#3399ff', trail: '#3399ff' },
    earth: { pixels: EARTH_SPELL_PIXELS, w: EARTH_SPELL_W, h: EARTH_SPELL_H, glow: '#aa7744', trail: '#cc9955' },
    wind:  { pixels: WIND_SPELL_PIXELS,  w: WIND_SPELL_W,  h: WIND_SPELL_H,  glow: '#44cc66', trail: '#88ffaa' },
};

export class SpellProjectile extends GameObject {
    constructor() {
        super(0, 0, FIREBALL_MASS, FIREBALL_BOUNCINESS, FIREBALL_FRICTION);
        this.state = 'ready';
        this.spellType = null; // 'water' | 'earth' | 'wind'
        this.pendingExplosion = false;
        this._exploded = false;
        this.trail = [];
    }

    reset() {
        this.ix = 0; this.iy = 0; this.iz = 0;
        this.vx = 0; this.vy = 0; this.vz = 0;
        this.state = 'ready';
        this.stateTime = 0;
        this.liftProgress = 0;
        this.bounceCount = 0;
        this.spellType = null;
        this.pendingExplosion = false;
        this._exploded = false;
        this.trail = [];
    }

    onLand(impactVz) {
        if (!this._exploded) {
            this._exploded = true;
            this.vx = 0;
            this.vy = 0;
            this.bounceCount = MAX_BOUNCES + 1;
            this.pendingExplosion = true;
        }
    }

    update(dt, hand, triggerShake) {
        if (this.state === 'ready' || this.state === 'done') return;

        if (this.state === 'settling') {
            this.stateTime += dt;
            if (this.stateTime > 0.08) {
                this.state = 'done';
            }
            return;
        }

        this.updatePhysics(dt, hand, triggerShake);

        // Трейл — сохраняем позицию в полёте
        if (this.state === 'thrown' || this.state === 'bouncing' || this.state === 'sliding') {
            this.trail.push({ ix: this.ix, iy: this.iy, iz: this.iz });
            if (this.trail.length > TRAIL_MAX) this.trail.shift();
        }

        if (this.pendingExplosion && this.state !== 'done' && this.state !== 'settling') {
            this.state = 'settling';
            this.stateTime = 0;
            this.trail = [];
        }
    }

    draw(hand) {
        if (this.state === 'ready' || this.state === 'done') return;
        if (!this.spellType) return;

        const sp = SPELL_SPRITES[this.spellType];
        if (!sp) return;

        const s = worldToScreen(this.ix, this.iy);
        drawItemShadow(s.x, s.y, sp.w, sp.h, this.iz);

        let ox, oy;

        if (this.state === 'carried' || this.state === 'lifting') {
            const lerpT = this.state === 'lifting' ? (1 - Math.pow(1 - this.liftProgress, 2)) : 1;
            const cp = screenToCanvas(hand.screenX, hand.screenY);
            const groundOx = s.x - (sp.w * PIXEL_SCALE) / 2;
            const groundOy = s.y - (sp.h * PIXEL_SCALE) - 4;
            const handOx = cp.x - (sp.w * PIXEL_SCALE) / 2;
            const handOy = cp.y - (sp.h * PIXEL_SCALE) / 2 - 8;
            ox = groundOx + (handOx - groundOx) * lerpT;
            oy = groundOy + (handOy - groundOy) * lerpT;
        } else {
            const heightOffset = this.iz * HEIGHT_TO_SCREEN;
            ox = s.x - (sp.w * PIXEL_SCALE) / 2;
            oy = s.y - (sp.h * PIXEL_SCALE) - 4 - heightOffset;
        }

        // Трейл
        if (this.trail.length > 1) {
            const n = this.trail.length;
            for (let i = 0; i < n; i++) {
                const t = this.trail[i];
                const ts = worldToScreen(t.ix, t.iy);
                const frac = (i + 1) / n;
                ctx.save();
                ctx.globalAlpha = frac * 0.55;
                ctx.fillStyle = sp.trail;
                ctx.shadowColor = sp.trail;
                ctx.shadowBlur = 10;
                ctx.beginPath();
                ctx.arc(ts.x, ts.y - t.iz * HEIGHT_TO_SCREEN, frac * 5, 0, Math.PI * 2);
                ctx.fill();
                ctx.restore();
            }
        }

        ctx.save();
        ctx.shadowColor = sp.glow;
        ctx.shadowBlur = 18;
        drawPixelArt(ox, oy, sp.pixels, PIXEL_SCALE);
        ctx.restore();
    }
}
