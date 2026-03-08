// ============================================================
//  MAIN — точка входа, игровой цикл
// ============================================================
import { ITEM_TYPES, PIXEL_SCALE, HEIGHT_TO_SCREEN, CAMERA_OFFSET_Y } from './constants.js';
import { FLAG_PIXELS, FLAG_W as SPR_FLAG_W, FLAG_H as SPR_FLAG_H } from './sprites.js';
import { canvas, ctx, resize, drawPixelArt, drawItemShadow, drawFloor } from './renderer.js';
import { camera, isoToScreen, screenToIso, getDepth } from './isometry.js';
import { Hand } from './Hand.js';
import { items, minions, flag, screenShake, triggerScreenShake, updateScreenShake, resolveItemCollisions, initWorld } from './World.js';
import { initInput } from './input.js';

// ============================================================
//  ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (worldToScreen, screenToCanvas)
// ============================================================
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

// ============================================================
//  СОСТОЯНИЕ ВВОДА / UI
// ============================================================
const statusEl = document.getElementById('status');

let mouseX = canvas.width / 2;
let mouseY = canvas.height / 2;
let mouseDown = false;
let hoveredItem = null;
let hoveredMinion = null;

const selection = {
    active: false,
    startX: 0, startY: 0,
    endX: 0, endY: 0,
};

const flagEffect = {
    active: false,
    originX: 0, originY: 0,
    t: 0,
    duration: 0.5,
    particles: [],
};

// ============================================================
//  РУКА
// ============================================================
const hand = new Hand();

// ============================================================
//  ФЛАГ — рисование
// ============================================================
function drawFlagAt(sx, sy, isHovered) {
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

function drawFlagInWorld(isHovered) {
    const s = worldToScreen(flag.ix, flag.iy);
    drawItemShadow(s.x, s.y, SPR_FLAG_W, SPR_FLAG_H, flag.iz);
    const heightOffset = flag.iz * HEIGHT_TO_SCREEN;
    const ox = s.x - (SPR_FLAG_W * PIXEL_SCALE) / 2;
    const oy = s.y - (SPR_FLAG_H * PIXEL_SCALE) - 4 - heightOffset;
    drawFlagAt(ox, oy, isHovered);
}

// ============================================================
//  ВСТРЯХИВАНИЕ ФЛАГА
// ============================================================
function dismissFlag() {
    const cp = screenToCanvas(hand.screenX, hand.screenY);
    flagEffect.active = true;
    flagEffect.originX = cp.x - (SPR_FLAG_W * PIXEL_SCALE) / 2;
    flagEffect.originY = cp.y - (SPR_FLAG_H * PIXEL_SCALE) / 2 - 8;
    flagEffect.t = 0;
    flagEffect.particles = FLAG_PIXELS.map(p => ({
        x: p[0] * PIXEL_SCALE,
        y: p[1] * PIXEL_SCALE,
        vx: (Math.random() - 0.5) * 80,
        vy: (Math.random() - 0.5) * 80 - 30,
        color: p[2],
    }));

    flag.state = 'docked';
    hand.grabbedFlag = false;
    hand.state = 'opening';
    hand.animProgress = 0;
    hand.shakeHistory = [];
    hand.selectedMinions = [];

    for (const m of minions) {
        if (m.state === 'wandering' || m.state === 'paused') {
            m.pickNewTarget();
        }
    }

    statusEl.textContent = 'Флаг рассеян!';
}

// ============================================================
//  ИНИЦИАЛИЗАЦИЯ
// ============================================================
resize();
window.addEventListener('resize', resize);
ctx.imageSmoothingEnabled = false;

initWorld();

// Объект мирового состояния для input.js
const world = {
    items,
    minions,
    flag,
    screenShake,
    selection,
    flagEffect,
    get hoveredItem() { return hoveredItem; },
    set hoveredItem(v) { hoveredItem = v; },
    get hoveredMinion() { return hoveredMinion; },
    set hoveredMinion(v) { hoveredMinion = v; },
    get mouseX() { return mouseX; },
    set mouseX(v) { mouseX = v; },
    get mouseY() { return mouseY; },
    set mouseY(v) { mouseY = v; },
    get mouseDown() { return mouseDown; },
    set mouseDown(v) { mouseDown = v; },
};

initInput(canvas, hand, world, camera, statusEl);

// ============================================================
//  ОБНОВЛЕНИЕ
// ============================================================
function update(dt) {
    // Обновляем руку (движение, iso-координаты, анимация)
    hand.update(dt, mouseX, mouseY, canvas, screenToIso);

    // Детектор встряхивания флага
    if (hand.grabbedFlag) {
        hand.checkFlagShake(dismissFlag);
    } else {
        hand.prevScreenXForShake = hand.screenX;
    }

    // Обновление эффекта растворения флага
    if (flagEffect.active) {
        flagEffect.t += dt;
        if (flagEffect.t >= flagEffect.duration) {
            flagEffect.active = false;
        } else {
            for (const p of flagEffect.particles) {
                p.x += p.vx * dt;
                p.y += p.vy * dt;
                p.vy += 120 * dt; // гравитация частиц
            }
        }
    }

    // Обновляем физику всех предметов
    for (let i = 0; i < items.length; i++) {
        items[i].update(dt, hand, triggerScreenShake);
    }

    // Коллизии между предметами
    resolveItemCollisions();

    // Обновляем миньонов
    for (let i = 0; i < minions.length; i++) {
        minions[i].update(dt, hand, flag, triggerScreenShake);
    }

    // Проверяем наведение на предметы и миньонов
    hoveredItem = null;
    hoveredMinion = null;
    if (hand.grabbedItem === null && hand.grabbedMinion === null && !hand.grabbedFlag) {
        let minDist = 1.5;
        for (let i = 0; i < items.length; i++) {
            const it = items[i];
            if (it.state === 'carried' || it.state === 'lifting') continue;
            if (it.iz > 2.0) continue;
            const dx = hand.isoX - it.ix;
            const dy = hand.isoY - it.iy;
            const dist = Math.sqrt(dx * dx + dy * dy);
            if (dist < minDist) {
                minDist = dist;
                hoveredItem = i;
                hoveredMinion = null;
            }
        }
        for (let i = 0; i < minions.length; i++) {
            const m = minions[i];
            if (m.state === 'carried' || m.state === 'lifting') continue;
            if (m.iz > 2.0) continue;
            const dx = hand.isoX - m.ix;
            const dy = hand.isoY - m.iy;
            const dist = Math.sqrt(dx * dx + dy * dy);
            if (dist < minDist) {
                minDist = dist;
                hoveredItem = null;
                hoveredMinion = i;
            }
        }
    }

    // Тряска экрана
    updateScreenShake(dt);

    // Плавный зум
    camera.zoom += (camera.targetZoom - camera.zoom) * Math.min(1, dt * 8);

    // Обновляем статус
    const nothingHeld = hand.grabbedItem === null && hand.grabbedMinion === null && !hand.grabbedFlag;
    if (hand.grabbedFlag) {
        statusEl.textContent = 'Флаг в руке — кликни чтобы установить';
    } else if (nothingHeld && hoveredItem !== null) {
        statusEl.textContent = `Навести: ${ITEM_TYPES[items[hoveredItem].typeIndex].name} [зажми ЛКМ]`;
    } else if (nothingHeld && hoveredMinion !== null) {
        statusEl.textContent = 'Навести: Миньон [зажми ЛКМ]';
    } else if (nothingHeld) {
        statusEl.textContent = 'Рука открыта';
    }
}

// ============================================================
//  ОТРИСОВКА
// ============================================================
function render() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.imageSmoothingEnabled = false;

    // Зум камеры + тряска экрана
    ctx.save();
    ctx.translate(canvas.width / 2 + screenShake.offsetX, canvas.height / 2 + screenShake.offsetY);
    ctx.scale(camera.zoom, camera.zoom);
    ctx.translate(-canvas.width / 2, -canvas.height / 2);

    // Пол
    drawFloor();

    // Собираем все объекты для сортировки по глубине
    const renderList = [];

    // Предметы (не в состоянии carried/lifting — те рисуются с рукой)
    for (let i = 0; i < items.length; i++) {
        if (items[i].state === 'carried' || items[i].state === 'lifting') continue;
        renderList.push({
            type: 'item',
            index: i,
            depth: getDepth(items[i].ix, items[i].iy)
        });
    }

    // Миньоны
    for (let i = 0; i < minions.length; i++) {
        if (minions[i].state === 'carried' || minions[i].state === 'lifting') continue;
        renderList.push({
            type: 'minion',
            index: i,
            depth: getDepth(minions[i].ix, minions[i].iy)
        });
    }

    // Флаг на поле
    if (flag.state === 'placed') {
        renderList.push({
            type: 'flag',
            depth: getDepth(flag.ix, flag.iy)
        });
    }

    // Рука (и захваченный объект рисуются вместе)
    renderList.push({
        type: 'hand',
        depth: getDepth(hand.isoX, hand.isoY)
    });

    // Сортируем по глубине
    renderList.sort((a, b) => a.depth - b.depth);

    // Рисуем
    for (const obj of renderList) {
        if (obj.type === 'item') {
            items[obj.index].draw(obj.index, hand, hoveredItem);
        } else if (obj.type === 'minion') {
            minions[obj.index].draw(obj.index, hand, hoveredMinion);
        } else if (obj.type === 'flag') {
            drawFlagInWorld(false);
        } else if (obj.type === 'hand') {
            if (hand.grabbedItem !== null) {
                items[hand.grabbedItem].draw(hand.grabbedItem, hand, hoveredItem);
            } else if (hand.grabbedMinion !== null) {
                minions[hand.grabbedMinion].draw(hand.grabbedMinion, hand, hoveredMinion);
            }
            hand.draw();
        }
    }

    // Эффект растворения флага
    if (flagEffect.active) {
        const alpha = Math.pow(1 - flagEffect.t / flagEffect.duration, 1.5);
        ctx.save();
        ctx.globalAlpha = alpha;
        for (const p of flagEffect.particles) {
            ctx.fillStyle = p.color;
            ctx.fillRect(
                Math.floor(flagEffect.originX + p.x),
                Math.floor(flagEffect.originY + p.y),
                PIXEL_SCALE, PIXEL_SCALE
            );
        }
        ctx.restore();
    }

    ctx.restore();

    // Рамка выделения (screen space, поверх всего)
    if (selection.active) {
        const sx = Math.min(selection.startX, selection.endX);
        const sy = Math.min(selection.startY, selection.endY);
        const sw = Math.abs(selection.endX - selection.startX);
        const sh = Math.abs(selection.endY - selection.startY);
        ctx.save();
        ctx.setLineDash([4, 4]);
        ctx.strokeStyle = '#ffff44';
        ctx.lineWidth = 1;
        ctx.globalAlpha = 0.8;
        ctx.strokeRect(sx, sy, sw, sh);
        ctx.fillStyle = '#ffff44';
        ctx.globalAlpha = 0.06;
        ctx.fillRect(sx, sy, sw, sh);
        ctx.restore();
    }

    // Курсор-точка (вне зума и тряски — стабильный)
    ctx.fillStyle = '#ff4444';
    ctx.fillRect(mouseX - 1, mouseY - 1, 3, 3);

    // Индикатор зума
    if (Math.abs(camera.zoom - 1.0) > 0.01) {
        ctx.fillStyle = '#aab';
        ctx.font = '12px monospace';
        ctx.fillText(`Зум: ${Math.round(camera.zoom * 100)}%`, 16, canvas.height - 16);
    }
}

// ============================================================
//  GAME LOOP
// ============================================================
let lastTime = performance.now();

function gameLoop(now) {
    const dt = Math.min((now - lastTime) / 1000, 0.05);
    lastTime = now;

    update(dt);
    render();

    requestAnimationFrame(gameLoop);
}

requestAnimationFrame(gameLoop);
