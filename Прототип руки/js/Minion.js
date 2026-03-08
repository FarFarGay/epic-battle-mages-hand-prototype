// ============================================================
//  МИНЬОН
// ============================================================
import {
    PIXEL_SCALE, HEIGHT_TO_SCREEN, GRID_SIZE, MINION_SPEED, MINION_MAX_HP,
    FALL_DMG_MED_VZ, FALL_DMG_HI_VZ, FALL_DMG_MED, FALL_DMG_HI,
    CAMERA_OFFSET_Y
} from './constants.js';
import { MINION_PIXELS, MINION_DEAD_PIXELS, MINION_W, MINION_H } from './sprites.js';
import { GameObject } from './GameObject.js';
import { canvas, ctx, drawPixelArt, drawItemShadow, drawHighlight } from './renderer.js';
import { camera, isoToScreen } from './isometry.js';

function worldToScreen(wx, wy) {
    const iso = isoToScreen(wx, wy);
    return {
        x: iso.x + canvas.width / 2,
        y: iso.y + canvas.height / 2 - CAMERA_OFFSET_Y
    };
}

function screenToCanvas(sx, sy) {
    return {
        x: (sx - canvas.width / 2) / camera.zoom + canvas.width / 2,
        y: (sy - canvas.height / 2) / camera.zoom + canvas.height / 2,
    };
}

export class Minion extends GameObject {
    constructor(ix, iy) {
        super(ix, iy, 0.7, 0.25, 0.82);
        this.radius = 0.4; // для коллизий с замком
        this.state = 'wandering';
        this.targetX = ix;
        this.targetY = iy;
        this.pauseDuration = 1.0;
        this.hp = MINION_MAX_HP;
        this.dead = false;
        this.damageWobble = 0;        // таймер тряски при получении урона
        this.pendingBloodEffect = null; // { type: 'hit'|'death', ix, iy }
        this.pickNewTarget();
    }

    pickNewTarget() {
        const limit = GRID_SIZE - 1.0;
        this.targetX = (Math.random() * 2 - 1) * limit;
        this.targetY = (Math.random() * 2 - 1) * limit;
    }

    onLand(impactVz) {
        if (!this.dead) {
            const prevHp = this.hp;
            if (impactVz >= FALL_DMG_HI_VZ) {
                this.hp = Math.max(0, this.hp - FALL_DMG_HI);
            } else if (impactVz >= FALL_DMG_MED_VZ) {
                this.hp = Math.max(0, this.hp - FALL_DMG_MED);
            }
            if (this.hp < prevHp) {
                this.damageWobble = 0.4;
                if (this.hp <= 0) {
                    this.dead = true;
                    this.pendingBloodEffect = { type: 'death', ix: this.ix, iy: this.iy };
                } else {
                    this.pendingBloodEffect = { type: 'hit', ix: this.ix, iy: this.iy };
                }
            }
        }
        // Мёртвый гоблин — крови не оставляет
    }

    onSettle() {
        this.bounceCount = 0;
        this.stateTime = 0;
        if (this.dead) {
            this.state = 'dead';
        } else {
            this.pickNewTarget();
            this.state = 'wandering';
        }
    }

    update(dt, hand, flag, triggerShake) {
        this.stateTime += dt;
        if (this.damageWobble > 0) this.damageWobble = Math.max(0, this.damageWobble - dt);

        switch (this.state) {
            case 'wandering': {
                const flagActive = flag.state === 'placed';
                const tx = flagActive ? flag.ix : this.targetX;
                const ty = flagActive ? flag.iy : this.targetY;
                const dx = tx - this.ix;
                const dy = ty - this.iy;
                const dist = Math.sqrt(dx * dx + dy * dy);
                if (dist < 0.25) {
                    if (!flagActive) {
                        // Обычное блуждание: пауза и новая точка
                        this.state = 'paused';
                        this.pauseDuration = 0.5 + Math.random() * 1.5;
                        this.stateTime = 0;
                    }
                    // Если флаг стоит — стоим на месте
                } else {
                    const spd = MINION_SPEED * dt;
                    this.ix += (dx / dist) * spd;
                    this.iy += (dy / dist) * spd;
                    const lim = GRID_SIZE - 0.5;
                    this.ix = Math.max(-lim, Math.min(lim, this.ix));
                    this.iy = Math.max(-lim, Math.min(lim, this.iy));
                }
                break;
            }

            case 'paused':
                if (this.stateTime > this.pauseDuration) {
                    this.pickNewTarget();
                    this.state = 'wandering';
                    this.stateTime = 0;
                }
                break;

            case 'settling':
                if (this.stateTime > 0.3) {
                    this.onSettle();
                }
                break;

            case 'dead':
                this.iz = 0;
                this.vx = 0;
                this.vy = 0;
                this.vz = 0;
                break;

            default:
                // lifting, carried, thrown, bouncing, sliding — общая физика
                this.updatePhysics(dt, hand, triggerShake);
                break;
        }
    }

    draw(index, hand, hoveredMinion) {
        const s = worldToScreen(this.ix, this.iy);

        drawItemShadow(s.x, s.y, MINION_W, MINION_H, this.iz);

        const minionSprite = this.dead ? MINION_DEAD_PIXELS : MINION_PIXELS;

        if (this.state === 'carried' || this.state === 'lifting') {
            const time = performance.now() / 300;
            const wobbleX = Math.sin(time) * 1.5;
            const wobbleY = Math.cos(time * 1.3) * 1;
            const gripOffsetY = -8;
            const lerpT = this.state === 'lifting' ? (1 - Math.pow(1 - this.liftProgress, 2)) : 1;
            const canvasPos = screenToCanvas(hand.screenX, hand.screenY);
            const groundOx = s.x - (MINION_W * PIXEL_SCALE) / 2;
            const groundOy = s.y - (MINION_H * PIXEL_SCALE) - 4;
            const handOx = canvasPos.x - (MINION_W * PIXEL_SCALE) / 2 + wobbleX;
            const handOy = canvasPos.y - (MINION_H * PIXEL_SCALE) / 2 + gripOffsetY + wobbleY;
            const ox = groundOx + (handOx - groundOx) * lerpT;
            const oy = groundOy + (handOy - groundOy) * lerpT;
            drawPixelArt(ox, oy, minionSprite, PIXEL_SCALE);
            return;
        }

        const heightOffset = this.iz * HEIGHT_TO_SCREEN;

        // Тряска при получении урона
        let hitOffsetX = 0, hitOffsetY = 0;
        if (this.damageWobble > 0) {
            const t = performance.now();
            const shake = this.damageWobble * 7;
            hitOffsetX = Math.sin(t * 0.05) * shake;
            hitOffsetY = Math.cos(t * 0.07) * shake * 0.4;
        }

        const ox = s.x - (MINION_W * PIXEL_SCALE) / 2 + hitOffsetX;
        const oy = s.y - (MINION_H * PIXEL_SCALE) - 4 - heightOffset + hitOffsetY;

        if (hand.grabbedFlag && hand.selectedMinions.includes(index)) {
            ctx.save();
            const time = performance.now() / 400;
            ctx.globalAlpha = 0.35 + 0.2 * Math.sin(time);
            ctx.strokeStyle = '#44ff88';
            ctx.lineWidth = 2;
            ctx.strokeRect(ox - 5, oy - 5, MINION_W * PIXEL_SCALE + 10, MINION_H * PIXEL_SCALE + 10);
            ctx.restore();
        }

        if (index === hoveredMinion) {
            drawHighlight(ox, oy, MINION_W, MINION_H);
        }

        drawPixelArt(ox, oy, minionSprite, PIXEL_SCALE);
    }
}
