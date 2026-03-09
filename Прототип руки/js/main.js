// ============================================================
//  MAIN — точка входа, игровой цикл
// ============================================================
import { ITEM_TYPES, PIXEL_SCALE, HEIGHT_TO_SCREEN, CAMERA_OFFSET_Y } from './constants.js';
import { FLAG_PIXELS, FLAG_W as SPR_FLAG_W, FLAG_H as SPR_FLAG_H } from './sprites.js';
import { canvas, ctx, resize, drawPixelArt, drawItemShadow } from './renderer.js';
import { gameMap, FOG } from './Map.js';
import { camera, isoToScreen, screenToIso, getDepth } from './isometry.js';
import { Hand } from './Hand.js';
import { items, minions, flag, castle, screenShake, triggerScreenShake, updateScreenShake, resolveItemCollisions, resolveCastleCollisions, initWorld, bloodParticles, bloodPuddles } from './World.js';
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
        x: (sx - canvas.width / 2 + camera.x) / camera.zoom + canvas.width / 2,
        y: (sy - canvas.height / 2 + camera.y) / camera.zoom + canvas.height / 2,
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
let hoveredFlag = false;

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
function spawnFlagParticles(originX, originY) {
    flagEffect.active = true;
    flagEffect.originX = originX;
    flagEffect.originY = originY;
    flagEffect.t = 0;
    flagEffect.particles = FLAG_PIXELS.map(p => ({
        x: p[0] * PIXEL_SCALE,
        y: p[1] * PIXEL_SCALE,
        vx: (Math.random() - 0.5) * 80,
        vy: (Math.random() - 0.5) * 80 - 30,
        color: p[2],
    }));
}

// Эффект рассеивания флага в руке (при встряхивании или выдаче задачи с рукой)
function triggerFlagEffectAtHand() {
    const cp = screenToCanvas(hand.screenX, hand.screenY);
    spawnFlagParticles(
        cp.x - (SPR_FLAG_W * PIXEL_SCALE) / 2,
        cp.y - (SPR_FLAG_H * PIXEL_SCALE) / 2 - 8
    );
}

// Эффект рассеивания флага на поле (когда флаг стоит на земле)
function triggerFlagEffectAtWorld(ix, iy) {
    const s = worldToScreen(ix, iy);
    spawnFlagParticles(
        s.x - (SPR_FLAG_W * PIXEL_SCALE) / 2,
        s.y - (SPR_FLAG_H * PIXEL_SCALE) - 4
    );
}

function dismissFlag() {
    triggerFlagEffectAtHand();

    flag.state = 'docked';
    hand.grabbedFlag = false;
    hand.state = 'opening';
    hand.animProgress = 0;
    hand.shakeHistory = [];
    hand.selectedMinions = [];

    for (const m of minions) {
        if (m.state === 'listening' || m.state === 'moving' || m.state === 'waiting') {
            m.pickNewTarget();
            m.state = 'free';
            m.stateTime = 0;
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
    triggerFlagEffectAtWorld,
    triggerFlagEffectAtHand,
    get hoveredItem() { return hoveredItem; },
    set hoveredItem(v) { hoveredItem = v; },
    get hoveredMinion() { return hoveredMinion; },
    set hoveredMinion(v) { hoveredMinion = v; },
    get hoveredFlag() { return hoveredFlag; },
    set hoveredFlag(v) { hoveredFlag = v; },
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

    // Коллизии с замком
    resolveCastleCollisions();
    castle.update(dt);

    // Обновляем миньонов
    for (let i = 0; i < minions.length; i++) {
        minions[i].update(dt, hand, triggerScreenShake, items, castle);
    }

    // Проверяем наведение на предметы, миньонов и флаг
    hoveredItem = null;
    hoveredMinion = null;
    hoveredFlag = false;
    if (hand.grabbedItem === null && hand.grabbedMinion === null && !hand.grabbedFlag) {
        let minDist = 1.5;
        for (let i = 0; i < items.length; i++) {
            const it = items[i];
            if (it.state === 'carried' || it.state === 'lifting' || it.state === 'goblin_carried') continue;
            if (it.iz > 2.0) continue;
            if (gameMap.getFog(Math.round(it.ix), Math.round(it.iy)) !== FOG.VISIBLE) continue;
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
            if (gameMap.getFog(Math.round(m.ix), Math.round(m.iy)) !== FOG.VISIBLE) continue;
            const dx = hand.isoX - m.ix;
            const dy = hand.isoY - m.iy;
            const dist = Math.sqrt(dx * dx + dy * dy);
            if (dist < minDist) {
                minDist = dist;
                hoveredItem = null;
                hoveredMinion = i;
            }
        }
        // Флаг на земле — наведение для подбора
        if (hoveredItem === null && hoveredMinion === null && flag.state === 'placed') {
            const dx = hand.isoX - flag.ix;
            const dy = hand.isoY - flag.iy;
            if (Math.sqrt(dx * dx + dy * dy) < 1.2) hoveredFlag = true;
        }
    } else if (hand.grabbedFlag) {
        // С флагом в руке — подсвечиваем ближайший видимый добываемый ресурс
        let minDist = 1.5;
        for (let i = 0; i < items.length; i++) {
            const it = items[i];
            if (!it.typeDef.gatherable) continue;
            if (it.state === 'carried' || it.state === 'lifting' || it.state === 'goblin_carried') continue;
            if (it.iz > 2.0) continue;
            if (gameMap.getFog(Math.round(it.ix), Math.round(it.iy)) !== FOG.VISIBLE) continue;
            const dx = hand.isoX - it.ix;
            const dy = hand.isoY - it.iy;
            const dist = Math.sqrt(dx * dx + dy * dy);
            if (dist < minDist) {
                minDist = dist;
                hoveredItem = i;
            }
        }
    }

    // Эффекты крови от миньонов
    for (const minion of minions) {
        if (minion.pendingBloodEffect) {
            const effect = minion.pendingBloodEffect;
            minion.pendingBloodEffect = null;
            const s = worldToScreen(effect.ix, effect.iy);
            const isDeath = effect.type === 'death';
            const count    = isDeath ? 20 : 8;
            const maxLife  = isDeath ? 0.65 : 0.4;
            const spawnY   = s.y - PIXEL_SCALE * 4;
            for (let i = 0; i < count; i++) {
                bloodParticles.push({
                    x: s.x + (Math.random() - 0.5) * 6,
                    y: spawnY,
                    vx: (Math.random() - 0.5) * 90,
                    vy: -20 - Math.random() * 70,
                    life: maxLife * (0.6 + Math.random() * 0.4),
                    maxLife,
                    size: isDeath ? PIXEL_SCALE * 1.5 : PIXEL_SCALE,
                });
            }
            // Генерируем рваный пиксельный паттерн лужицы один раз при создании
            const rx = isDeath ? 30 : 15;  // полуширина px
            const ry = isDeath ? 11 : 5;   // полувысота px (плоский эллипс)
            const puddlePixels = [];
            const puddleColors = ['#880000', '#770000', '#990000', '#660000'];
            for (let py = -ry - PIXEL_SCALE; py <= ry + PIXEL_SCALE; py += PIXEL_SCALE) {
                for (let px = -rx - PIXEL_SCALE; px <= rx + PIXEL_SCALE; px += PIXEL_SCALE) {
                    const nx = px / rx;
                    const ny = py / ry;
                    const d  = nx * nx + ny * ny;
                    const color = puddleColors[Math.floor(Math.random() * puddleColors.length)];
                    if (d <= 0.65) {
                        // Ядро — всегда заполнено
                        puddlePixels.push({ dx: px, dy: py, color });
                    } else if (d <= 1.1) {
                        // Внутренний край — 65% шанс (рваность)
                        if (Math.random() < 0.65) puddlePixels.push({ dx: px, dy: py, color });
                    } else if (d <= 1.6) {
                        // Внешние брызги — 20% шанс
                        if (Math.random() < 0.20) puddlePixels.push({ dx: px, dy: py, color: '#550000' });
                    }
                }
            }
            bloodPuddles.push({
                ix: effect.ix,
                iy: effect.iy,
                pixels: puddlePixels,
                duration: isDeath ? 4.0 : 2.0,
                t: 0,
            });
        }
    }

    // Обновляем частицы крови
    for (let i = bloodParticles.length - 1; i >= 0; i--) {
        const p = bloodParticles[i];
        p.x  += p.vx * dt;
        p.y  += p.vy * dt;
        p.vy += 150 * dt; // гравитация частиц
        p.life -= dt;
        if (p.life <= 0) bloodParticles.splice(i, 1);
    }

    // Обновляем лужицы крови
    for (let i = bloodPuddles.length - 1; i >= 0; i--) {
        bloodPuddles[i].t += dt;
        if (bloodPuddles[i].t >= bloodPuddles[i].duration) bloodPuddles.splice(i, 1);
    }

    // Туман войны — замок видит 21×21 тайл (квадрат), живые миньоны — круг радиусом 2
    // Рука собственной видимостью не обладает
    const fogSources = [
        { ix: gameMap.castlePos.ix, iy: gameMap.castlePos.iy, radius: 10, shape: 'square' },
        ...minions
            .filter(m => m.state !== 'dead')
            .map(m => ({ ix: m.ix, iy: m.iy, radius: 2 })),
    ];
    gameMap.tickFog(fogSources);

    // Тряска экрана
    updateScreenShake(dt);

    // Плавный зум
    camera.zoom += (camera.targetZoom - camera.zoom) * Math.min(1, dt * 8);

    // Edge scroll — камера движется если рука у края экрана
    const EDGE_ZONE = 0.12; // 12% экрана с каждого края
    const PAN_SPEED = 600;  // px/сек в screen space
    const edgeW = canvas.width  * EDGE_ZONE;
    const edgeH = canvas.height * EDGE_ZONE;
    let panX = 0, panY = 0;
    if (hand.screenX < edgeW) {
        panX = -(1 - hand.screenX / edgeW) * PAN_SPEED;
    } else if (hand.screenX > canvas.width - edgeW) {
        panX =  (1 - (canvas.width  - hand.screenX) / edgeW) * PAN_SPEED;
    }
    if (hand.screenY < edgeH) {
        panY = -(1 - hand.screenY / edgeH) * PAN_SPEED;
    } else if (hand.screenY > canvas.height - edgeH) {
        panY =  (1 - (canvas.height - hand.screenY) / edgeH) * PAN_SPEED;
    }
    camera.x += panX * dt;
    camera.y += panY * dt;

    // Обновляем статус
    const nothingHeld = hand.grabbedItem === null && hand.grabbedMinion === null && !hand.grabbedFlag;
    if (hand.grabbedFlag) {
        if (hoveredItem !== null && hand.selectedMinions.length > 0) {
            statusEl.textContent = `Кликни — ${hand.selectedMinions.length} гоблин(а) начнут добычу!`;
        } else if (hoveredItem !== null) {
            statusEl.textContent = 'Ресурс — выдели гоблинов лассо для отправки на добычу';
        } else {
            statusEl.textContent = 'Флаг в руке — кликни чтобы установить';
        }
    } else if (nothingHeld && hoveredFlag) {
        statusEl.textContent = 'Флаг [зажми ЛКМ чтобы подобрать]';
    } else if (nothingHeld && hoveredItem !== null) {
        statusEl.textContent = `Навести: ${ITEM_TYPES[items[hoveredItem].typeIndex].name} [зажми ЛКМ]`;
    } else if (nothingHeld && hoveredMinion !== null) {
        statusEl.textContent = 'Навести: Миньон [зажми ЛКМ]';
    } else if (nothingHeld) {
        const waitingCount = minions.filter(m => m.state === 'waiting').length;
        if (waitingCount > 0) {
            statusEl.textContent = `${waitingCount} гоблин(а) ждут задачу [1 — добывать]`;
        } else {
            statusEl.textContent = 'Рука открыта';
        }
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
    ctx.translate(canvas.width / 2 + screenShake.offsetX - camera.x, canvas.height / 2 + screenShake.offsetY - camera.y);
    ctx.scale(camera.zoom, camera.zoom);
    ctx.translate(-canvas.width / 2, -canvas.height / 2);

    // Пол
    gameMap.draw();

    // Собираем все объекты для сортировки по глубине
    const renderList = [];

    // Предметы (не в состоянии carried/lifting — те рисуются с рукой)
    for (let i = 0; i < items.length; i++) {
        if (items[i].state === 'carried' || items[i].state === 'lifting') continue;
        if (gameMap.getFog(Math.round(items[i].ix), Math.round(items[i].iy)) !== FOG.VISIBLE) continue;
        renderList.push({
            type: 'item',
            index: i,
            depth: getDepth(items[i].ix, items[i].iy)
        });
    }

    // Миньоны
    for (let i = 0; i < minions.length; i++) {
        if (minions[i].state === 'carried' || minions[i].state === 'lifting') continue;
        if (gameMap.getFog(Math.round(minions[i].ix), Math.round(minions[i].iy)) !== FOG.VISIBLE) continue;
        renderList.push({
            type: 'minion',
            index: i,
            depth: getDepth(minions[i].ix, minions[i].iy)
        });
    }

    // Лужицы крови (рисуются ниже всех объектов)
    for (let i = 0; i < bloodPuddles.length; i++) {
        renderList.push({
            type: 'bloodPuddle',
            index: i,
            depth: getDepth(bloodPuddles[i].ix, bloodPuddles[i].iy) - 0.01,
        });
    }

    // Флаг на поле (виден только если тайл в зоне прямой видимости)
    if (flag.state === 'placed' && gameMap.getFog(Math.round(flag.ix), Math.round(flag.iy)) === FOG.VISIBLE) {
        renderList.push({
            type: 'flag',
            depth: getDepth(flag.ix, flag.iy)
        });
    }

    // Замок (два слоя: основание и башня)
    for (const entry of castle.getRenderEntries()) {
        renderList.push(entry);
    }

    // Рука всегда поверх всего
    renderList.push({
        type: 'hand',
        depth: Infinity,
    });

    // Сортируем по глубине
    renderList.sort((a, b) => a.depth - b.depth);

    // Рисуем
    for (const obj of renderList) {
        if (obj.type === 'item') {
            items[obj.index].draw(obj.index, hand, hoveredItem);
        } else if (obj.type === 'minion') {
            minions[obj.index].draw(obj.index, hand, hoveredMinion);
        } else if (obj.type === 'bloodPuddle') {
            const p = bloodPuddles[obj.index];
            const s = worldToScreen(p.ix, p.iy);
            const alpha = Math.pow(1 - p.t / p.duration, 0.5) * 0.82;
            ctx.save();
            ctx.globalAlpha = alpha;
            for (const px of p.pixels) {
                ctx.fillStyle = px.color;
                ctx.fillRect(
                    Math.round(s.x + px.dx),
                    Math.round(s.y - 2 + px.dy),
                    PIXEL_SCALE, PIXEL_SCALE
                );
            }
            ctx.restore();
        } else if (obj.type === 'castle') {
            castle.draw();
        } else if (obj.type === 'flag') {
            drawFlagInWorld(hoveredFlag);
        } else if (obj.type === 'hand') {
            if (hand.grabbedItem !== null) {
                items[hand.grabbedItem].draw(hand.grabbedItem, hand, hoveredItem);
            } else if (hand.grabbedMinion !== null) {
                minions[hand.grabbedMinion].draw(hand.grabbedMinion, hand, hoveredMinion);
            }
            hand.draw();
        }
    }

    // Частицы крови
    for (const p of bloodParticles) {
        const alpha = Math.pow(p.life / p.maxLife, 0.5) * 0.9;
        ctx.save();
        ctx.globalAlpha = alpha;
        ctx.fillStyle = '#cc1111';
        ctx.fillRect(Math.round(p.x - p.size / 2), Math.round(p.y - p.size / 2), p.size, p.size);
        ctx.restore();
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
