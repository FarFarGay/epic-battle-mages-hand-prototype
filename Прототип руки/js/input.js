// ============================================================
//  ВВОД — все обработчики событий
// ============================================================
import { ITEM_TYPES, PIXEL_SCALE, CAMERA_OFFSET_Y } from './constants.js';
import { MINION_H } from './sprites.js';
import { isoToScreen } from './isometry.js';
import { camera } from './isometry.js';
import { restartMap, flag, items, minions } from './World.js';

function worldToScreen(wx, wy, canvas) {
    const iso = isoToScreen(wx, wy);
    return {
        x: iso.x + canvas.width / 2,
        y: iso.y + canvas.height / 2 - CAMERA_OFFSET_Y
    };
}

function screenToCanvas(sx, sy, canvas) {
    return {
        x: (sx - canvas.width / 2) / camera.zoom + canvas.width / 2,
        y: (sy - canvas.height / 2) / camera.zoom + canvas.height / 2,
    };
}

export function initInput(canvas, hand, world, cam, statusEl) {
    // world = { items, minions, flag, screenShake, selection, flagEffect, hoveredItem, hoveredMinion }
    // cam = camera object (for zoom)
    const { selection, flagEffect } = world;

    canvas.addEventListener('mousemove', (e) => {
        world.mouseX = e.clientX;
        world.mouseY = e.clientY;
        if (selection.active) {
            selection.endX = world.mouseX;
            selection.endY = world.mouseY;
        }
    });

    canvas.addEventListener('mousedown', (e) => {
        if (e.button !== 0) return;
        world.mouseDown = true;
        const handFree = hand.grabbedItem === null && hand.grabbedMinion === null && !hand.grabbedFlag;

        if (hand.grabbedFlag && world.hoveredItem === null && world.hoveredMinion === null) {
            // Устанавливаем флаг кликом на свободное место
            flag.ix = hand.isoX;
            flag.iy = hand.isoY;
            flag.iz = 0;
            flag.state = 'placed';
            // Выбранные гоблины переходят в состояние «передвигается» к флагу
            for (const idx of hand.selectedMinions) {
                const m = minions[idx];
                if (m.state === 'listening') {
                    m.targetX = flag.ix;
                    m.targetY = flag.iy;
                    m.state = 'moving';
                    m.stateTime = 0;
                }
            }
            hand.grabbedFlag = false;
            hand.state = 'opening';
            hand.animProgress = 0;
            hand.velocityHistory = [];
            hand.selectedMinions = [];
            statusEl.textContent = 'Флаг установлен';
        } else if (world.hoveredItem !== null && handFree) {
            const item = items[world.hoveredItem];
            if (item.state !== 'carried' && item.state !== 'lifting') {
                hand.grabbedItem = world.hoveredItem;
                item.grabbed = true;
                item.state = 'lifting';
                item.stateTime = 0;
                item.liftProgress = 0;
                item.vx = 0;
                item.vy = 0;
                item.vz = 0;
                item.bounceCount = 0;
                hand.state = 'closing';
                hand.animProgress = 0;
                hand.velocityHistory = [];
                statusEl.textContent = `Захвачено: ${ITEM_TYPES[item.typeIndex].name}`;
            }
        } else if (world.hoveredMinion !== null && handFree) {
            const minion = minions[world.hoveredMinion];
            if (minion.state !== 'carried' && minion.state !== 'lifting') {
                hand.grabbedMinion = world.hoveredMinion;
                minion.state = 'lifting';
                minion.stateTime = 0;
                minion.liftProgress = 0;
                minion.vx = 0;
                minion.vy = 0;
                minion.vz = 0;
                minion.bounceCount = 0;
                hand.state = 'closing';
                hand.animProgress = 0;
                hand.velocityHistory = [];
                statusEl.textContent = 'Захвачено: Миньон';
            }
        } else if (handFree) {
            // Начинаем выделение рамкой — от позиции руки
            selection.active = true;
            selection.startX = hand.screenX;
            selection.startY = hand.screenY;
            selection.endX = world.mouseX;
            selection.endY = world.mouseY;
        }
    });

    canvas.addEventListener('mouseup', (e) => {
        if (e.button !== 0) return;
        world.mouseDown = false;
        if (hand.grabbedItem !== null) {
            const item = items[hand.grabbedItem];
            const type = item.typeDef;

            item.grabbed = false;
            item.iz = 0;

            const throwVel = hand.calculateThrowVelocity(type);
            item.vx = throwVel.vx;
            item.vy = throwVel.vy;
            item.vz = throwVel.vz;
            item.state = 'thrown';
            item.stateTime = 0;
            item.bounceCount = 0;

            hand.grabbedItem = null;
            hand.state = 'opening';
            hand.animProgress = 0;
            hand.velocityHistory = [];

            const speed = Math.sqrt(throwVel.vx ** 2 + throwVel.vy ** 2);
            if (speed > 2) {
                statusEl.textContent = `Брошено: ${type.name}!`;
            } else {
                statusEl.textContent = `Отпущено: ${type.name}`;
            }
        } else if (hand.grabbedMinion !== null) {
            const minion = minions[hand.grabbedMinion];
            minion.iz = 0;
            const throwVel = hand.calculateThrowVelocity({ mass: minion.mass });
            minion.vx = throwVel.vx;
            minion.vy = throwVel.vy;
            minion.vz = throwVel.vz;
            minion.state = 'thrown';
            minion.stateTime = 0;
            minion.bounceCount = 0;

            hand.grabbedMinion = null;
            hand.state = 'opening';
            hand.animProgress = 0;
            hand.velocityHistory = [];

            const speed = Math.sqrt(throwVel.vx ** 2 + throwVel.vy ** 2);
            statusEl.textContent = speed > 2 ? 'Брошен: Миньон!' : 'Отпущен: Миньон';
        } else if (selection.active) {
            selection.active = false;
            const selW = Math.abs(selection.endX - selection.startX);
            const selH = Math.abs(selection.endY - selection.startY);
            if (selW > 5 || selH > 5) {
                const tl = screenToCanvas(
                    Math.min(selection.startX, selection.endX),
                    Math.min(selection.startY, selection.endY),
                    canvas
                );
                const br = screenToCanvas(
                    Math.max(selection.startX, selection.endX),
                    Math.max(selection.startY, selection.endY),
                    canvas
                );
                const SELECTABLE = ['free', 'listening', 'moving', 'busy', 'returning', 'war', 'fighting'];
                hand.selectedMinions = [];
                for (let i = 0; i < minions.length; i++) {
                    const m = minions[i];
                    if (!SELECTABLE.includes(m.state)) continue;
                    const s = worldToScreen(m.ix, m.iy, canvas);
                    const mx = s.x;
                    const my = s.y - (MINION_H * PIXEL_SCALE) / 2;
                    if (mx >= tl.x && mx <= br.x && my >= tl.y && my <= br.y) {
                        hand.selectedMinions.push(i);
                    }
                }
                if (hand.selectedMinions.length > 0) {
                    // Выбранные гоблины переходят в состояние «слушает»
                    for (const idx of hand.selectedMinions) {
                        const m = minions[idx];
                        m.state = 'listening';
                        m.stateTime = 0;
                    }
                    hand.grabbedFlag = true;
                    hand.state = 'closing';
                    hand.animProgress = 0;
                    if (flag.state === 'placed') {
                        flag.state = 'docked';
                        // Остальные двигавшиеся к старому флагу → свободны
                        for (const m of minions) {
                            if (m.state === 'moving') {
                                m.pickNewTarget();
                                m.state = 'free';
                                m.stateTime = 0;
                            }
                        }
                    }
                    statusEl.textContent = `Выделено ${hand.selectedMinions.length} миньон(а) — кликни чтобы поставить флаг`;
                }
            }
        }
    });

    // Зум камеры: Z — отдалить, X — приблизить, C — сброс
    // Рестарт карты: R
    window.addEventListener('keydown', (e) => {
        if (e.key === 'z' || e.key === 'я') {
            cam.targetZoom = Math.max(cam.targetZoom * 0.9, 0.2);
        } else if (e.key === 'x' || e.key === 'ч') {
            cam.targetZoom = Math.min(cam.targetZoom * 1.1, 3.0);
        } else if (e.key === 'c' || e.key === 'с') {
            cam.targetZoom = 1.0;
        } else if (e.key === 'r' || e.key === 'к') {
            restartMap(hand, statusEl);
            // Сбрасываем наведение и выделение
            world.hoveredItem = null;
            world.hoveredMinion = null;
            selection.active = false;
            flagEffect.active = false;
            cam.zoom = 1.0;
            cam.targetZoom = 1.0;
        }
    });
}
