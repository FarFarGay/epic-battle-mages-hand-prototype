// ============================================================
//  ПРЕДМЕТ
// ============================================================
import { ITEM_TYPES, PIXEL_SCALE, HEIGHT_TO_SCREEN } from './constants.js';
import { GameObject } from './GameObject.js';
import { canvas, ctx, drawPixelArt, drawItemShadow, drawHighlight } from './renderer.js';
import { camera } from './isometry.js';
import { isoToScreen } from './isometry.js';
import { CAMERA_OFFSET_Y } from './constants.js';

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

export class Item extends GameObject {
    constructor(typeIndex, ix, iy) {
        const typeDef = ITEM_TYPES[typeIndex];
        super(ix, iy, typeDef.mass, typeDef.bounciness, typeDef.friction);
        this.typeIndex = typeIndex;
        this.grabbed = false;
        this.state = 'idle';
    }

    get typeDef() {
        return ITEM_TYPES[this.typeIndex];
    }

    update(dt, hand, triggerShake) {
        const type = this.typeDef;

        if (this.state === 'idle') {
            this.iz = 0;
            this.vx = 0;
            this.vy = 0;
            this.vz = 0;
            this.stateTime += dt;
            return;
        }

        if (this.state === 'settling') {
            this.stateTime += dt;
            if (this.stateTime > 0.15) {
                this.onSettle();
            }
            return;
        }

        this.updatePhysics(dt, hand, triggerShake);
    }

    onSettle() {
        this.state = 'idle';
        this.stateTime = 0;
        this.bounceCount = 0;
        this.grabbed = false;
    }

    draw(index, hand, hoveredItem) {
        const type = this.typeDef;
        const s = worldToScreen(this.ix, this.iy);

        // Тень на земле (с учётом высоты)
        drawItemShadow(s.x, s.y, type.w, type.h, this.iz);

        // Для переносимых/поднимаемых предметов — рисуем прямо в хватке руки
        if (this.state === 'carried' || this.state === 'lifting') {
            const time = performance.now() / 300;
            const wobbleX = hand.grabbedItem !== null ? Math.sin(time) * 1.5 : 0;
            const wobbleY = hand.grabbedItem !== null ? Math.cos(time * 1.3) * 1 : 0;

            const gripOffsetY = -8;
            const lerpT = this.state === 'lifting' ? (1 - Math.pow(1 - this.liftProgress, 2)) : 1;

            const canvasPos = screenToCanvas(hand.screenX, hand.screenY);
            const groundOx = s.x - (type.w * PIXEL_SCALE) / 2;
            const groundOy = s.y - (type.h * PIXEL_SCALE) - 4;
            const handOx = canvasPos.x - (type.w * PIXEL_SCALE) / 2 + wobbleX;
            const handOy = canvasPos.y - (type.h * PIXEL_SCALE) / 2 + gripOffsetY + wobbleY;

            const ox = groundOx + (handOx - groundOx) * lerpT;
            const oy = groundOy + (handOy - groundOy) * lerpT;

            drawPixelArt(ox, oy, type.pixels, PIXEL_SCALE);
            return;
        }

        // Смещение по высоте (для летящих/отскакивающих)
        const heightOffset = this.iz * HEIGHT_TO_SCREEN;

        const ox = s.x - (type.w * PIXEL_SCALE) / 2;
        const oy = s.y - (type.h * PIXEL_SCALE) - 4 - heightOffset;

        // Подсветка если наведено
        if (index === hoveredItem) {
            drawHighlight(ox, oy, type.w, type.h);
        }

        // Предмет
        drawPixelArt(ox, oy, type.pixels, PIXEL_SCALE);
    }
}
