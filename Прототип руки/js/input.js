// ============================================================
//  ВВОД — все обработчики событий
// ============================================================
import {
    ITEM_TYPES, PIXEL_SCALE, CAMERA_OFFSET_Y, GRAVITY,
    ARTILLERY_GRAB_RADIUS, ARTILLERY_FLIGHT_TIME_K,
    ARTILLERY_MIN_FLIGHT, ARTILLERY_MAX_FLIGHT,
} from './constants.js';
import { MINION_H } from './sprites.js';
import { isoToScreen, screenToIso } from './isometry.js';
import { camera } from './isometry.js';
import { restartMap, flag, items, minions, castle, artilleryMode, triggerScreenShake } from './World.js';

function worldToScreen(wx, wy, canvas) {
    const iso = isoToScreen(wx, wy);
    return {
        x: iso.x + canvas.width / 2,
        y: iso.y + canvas.height / 2 - CAMERA_OFFSET_Y
    };
}

function screenToCanvas(sx, sy, canvas) {
    return {
        x: (sx - canvas.width / 2 + camera.x) / camera.zoom + canvas.width / 2,
        y: (sy - canvas.height / 2 + camera.y) / camera.zoom + canvas.height / 2,
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

        // ── Артиллерия: выстрел ──────────────────────────────────
        if (artilleryMode.active && artilleryMode.state === 'aiming') {
            const iso = screenToIso(world.mouseX, world.mouseY, canvas);
            artilleryMode.targetX = iso.x;
            artilleryMode.targetY = iso.y;

            // Рассчитываем траекторию
            const dx = iso.x - castle.ix;
            const dy = iso.y - castle.iy;
            const dist = Math.sqrt(dx * dx + dy * dy);
            const T = Math.max(ARTILLERY_MIN_FLIGHT, Math.min(ARTILLERY_MAX_FLIGHT, dist * ARTILLERY_FLIGHT_TIME_K));

            const proj = artilleryMode.projectile;
            proj.ix = castle.ix;
            proj.iy = castle.iy;
            proj.iz = 0;
            proj.vx = dx / T;
            proj.vy = dy / T;
            proj.vz = 0.5 * GRAVITY * T; // чтобы приземлиться точно через T секунд

            artilleryMode.flightDuration = T;
            artilleryMode.timer = 0;
            artilleryMode.state = 'flying';

            castle.fireCannon();
            triggerScreenShake(5);
            statusEl.textContent = 'Огонь!';
            return;
        }

        // В режиме полёта/взрыва — игнорируем клики
        if (artilleryMode.active) return;

        const handFree = hand.grabbedItem === null && hand.grabbedMinion === null && !hand.grabbedFlag;

        // ── Артиллерия: захват замка ─────────────────────────────
        if (handFree && castle) {
            const dx = hand.isoX - castle.ix;
            const dy = hand.isoY - castle.iy;
            if (Math.sqrt(dx * dx + dy * dy) < ARTILLERY_GRAB_RADIUS) {
                artilleryMode.active = true;
                artilleryMode.state = 'aiming';
                hand.state = 'closed';
                hand.animProgress = 1;
                statusEl.textContent = 'Режим стрельбы — наведи прицел и нажми ЛКМ (Q — выход)';
                return;
            }
        }

        if (hand.grabbedFlag && world.hoveredItem !== null && hand.selectedMinions.length > 0) {
            // Флаг + ресурс + выбранные гоблины → мгновенная задача «добывать»
            let count = 0;
            for (const idx of hand.selectedMinions) {
                const m = minions[idx];
                if (m.state === 'listening') {
                    if (m.assignGatherTask(items)) count++;
                }
            }
            world.triggerFlagEffectAtHand();
            flag.state = 'docked';
            hand.grabbedFlag = false;
            hand.state = 'opening';
            hand.animProgress = 0;
            hand.velocityHistory = [];
            hand.selectedMinions = [];
            statusEl.textContent = count > 0
                ? `${count} гоблин(а) начинают добычу!`
                : 'Нет доступных ресурсов';
        } else if (hand.grabbedFlag && world.hoveredMinion === null) {
            // Устанавливаем флаг кликом на свободное место (или ресурс без гоблинов)
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
            if (minion.state !== 'carried' && minion.state !== 'lifting' && minion.state !== 'dead') {
                minion.dropCarriedItem(); // бросить камень если нёс
                hand.grabbedMinion = world.hoveredMinion;
                hand.minionGrabIso = { ix: minion.ix, iy: minion.iy };
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
        } else if (world.hoveredFlag && handFree) {
            // Подбираем флаг с земли — возвращаем гоблинов в ожидание
            flag.state = 'docked';
            hand.grabbedFlag = true;
            hand.state = 'closing';
            hand.animProgress = 0;
            hand.velocityHistory = [];
            hand.selectedMinions = [];
            for (let i = 0; i < minions.length; i++) {
                const m = minions[i];
                if (m.state === 'moving' || m.state === 'waiting') {
                    m.state = 'listening';
                    m.stateTime = 0;
                    hand.selectedMinions.push(i);
                }
            }
            statusEl.textContent = hand.selectedMinions.length > 0
                ? `Флаг подобран — ${hand.selectedMinions.length} гоблин(а) ждут приказа`
                : 'Флаг подобран';
        } else if (handFree) {
            // Начинаем выделение рамкой — от позиции мыши (не руки, чтобы координаты совпадали)
            selection.active = true;
            selection.startX = world.mouseX;
            selection.startY = world.mouseY;
            selection.endX = world.mouseX;
            selection.endY = world.mouseY;
        }
    });

    canvas.addEventListener('mouseup', (e) => {
        if (e.button !== 0) return;
        world.mouseDown = false;
        if (artilleryMode.active) return;
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
            hand.minionGrabIso = null;
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
                const SELECTABLE = ['free', 'listening', 'moving', 'waiting', 'busy', 'returning', 'war', 'fighting'];
                hand.selectedMinions = [];
                for (let i = 0; i < minions.length; i++) {
                    const m = minions[i];
                    if (!SELECTABLE.includes(m.state)) continue;
                    if (m.isUndead) continue;             // скелеты не выделяются лассо
                    if (m.goblinClass === 'warrior') continue; // воины автономны
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
                        m.dropCarriedItem(); // бросить камень если нёс
                        m.state = 'listening';
                        m.stateTime = 0;
                    }
                    hand.grabbedFlag = true;
                    hand.state = 'closing';
                    hand.animProgress = 0;
                    hand.velocityHistory = [];
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
        // Выход из режима артиллерии
        if ((e.key === 'q' || e.key === 'й') && artilleryMode.active) {
            // Сброс снаряда на позицию замка (чтобы не осталось stale-данных)
            const proj = artilleryMode.projectile;
            proj.ix = castle.ix; proj.iy = castle.iy; proj.iz = 0;
            proj.vx = 0; proj.vy = 0; proj.vz = 0;
            artilleryMode.active = false;
            artilleryMode.state = 'aiming';
            artilleryMode.timer = 0;
            artilleryMode.explosion.active = false;
            artilleryMode.explosion.particles.length = 0;
            hand.state = 'open';
            hand.animProgress = 0;
            statusEl.textContent = 'Режим стрельбы отменён';
            return;
        }

        if (e.key === 'z' || e.key === 'я') {
            cam.targetZoom = Math.max(cam.targetZoom * 0.9, 0.2);
        } else if (e.key === 'x' || e.key === 'ч') {
            cam.targetZoom = Math.min(cam.targetZoom * 1.1, 3.0);
        } else if (e.key === 'c' || e.key === 'с') {
            cam.targetZoom = 1.0;
        } else if (e.key === '1') {
            // Назначить задачу «добывать» всем ожидающим гоблинам
            let count = 0;
            for (const m of minions) {
                if (m.state === 'waiting') {
                    if (m.assignGatherTask(items)) count++;
                }
            }
            if (count > 0) {
                statusEl.textContent = `${count} гоблин(а) начинают добычу камней`;
                // Флаг больше не нужен — убираем с поля с эффектом рассеивания
                if (flag.state === 'placed') {
                    world.triggerFlagEffectAtWorld(flag.ix, flag.iy);
                    flag.state = 'docked';
                }
            } else {
                statusEl.textContent = 'Нет гоблинов ожидающих задачу';
            }
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
