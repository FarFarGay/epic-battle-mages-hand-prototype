// ============================================================
//  MAIN — точка входа, игровой цикл
// ============================================================
import {
    ITEM_TYPES, PIXEL_SCALE, HEIGHT_TO_SCREEN, CAMERA_OFFSET_Y, GRAVITY, TILE_W, TILE_H,
    ARTILLERY_BLAST_RADIUS, ARTILLERY_DAMAGE, ARTILLERY_RETURN_DELAY,
    ARTILLERY_GRAB_RADIUS,
} from './constants.js';
import { FLAG_PIXELS, FLAG_W as SPR_FLAG_W, FLAG_H as SPR_FLAG_H, MINION_PIXELS, MINION_W, MINION_H, CANNONBALL_PIXELS, CANNONBALL_W, CANNONBALL_H } from './sprites.js';
import { canvas, ctx, resize, drawPixelArt, drawItemShadow } from './renderer.js';
import { gameMap, FOG } from './Map.js';
import { camera, isoToScreen, screenToIso, getDepth } from './isometry.js';
import { Hand } from './Hand.js';
import { items, minions, flag, castle, screenShake, triggerScreenShake, updateScreenShake, resolveItemCollisions, resolveCastleCollisions, initWorld, bloodParticles, bloodPuddles, castleResources, spawnMinion, artilleryMode } from './World.js';
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

// Области HUD (обновляются при рендере)
const goblinHudRect = { x: 0, y: 0, w: 0, h: 0 };
const hudPanelRect  = { x: 0, y: 0, w: 0, h: 0 }; // весь правый HUD-панель (блокирует edge scroll)

// Клик по кнопке гоблина — перехватываем ДО input.js (capture phase)
canvas.addEventListener('mousedown', (e) => {
    const mx = e.clientX, my = e.clientY;
    if (
        mx >= goblinHudRect.x && mx <= goblinHudRect.x + goblinHudRect.w &&
        my >= goblinHudRect.y && my <= goblinHudRect.y + goblinHudRect.h
    ) {
        castle.production.active = !castle.production.active;
        e.stopImmediatePropagation();
    }
}, true);

initInput(canvas, hand, world, camera, statusEl);

// ============================================================
//  АРТИЛЛЕРИЯ — обновление
// ============================================================
function updateArtillery(dt) {
    const art = artilleryMode;

    if (art.state === 'aiming') {
        // Обновляем позицию прицела из мыши
        const iso = screenToIso(mouseX, mouseY, canvas);
        art.crosshairX = iso.x;
        art.crosshairY = iso.y;

        // Камера управляется edge scroll (как в обычном режиме)
    }

    if (art.state === 'flying') {
        art.timer += dt;
        const proj = art.projectile;

        // Физика снаряда
        proj.vz -= GRAVITY * dt;
        proj.ix += proj.vx * dt;
        proj.iy += proj.vy * dt;
        proj.iz += proj.vz * dt;

        // Камера следует за снарядом (iso-координаты × zoom)
        const projIso = isoToScreen(proj.ix, proj.iy);
        const targetCamX = projIso.x * camera.zoom;
        const targetCamY = projIso.y * camera.zoom;
        camera.x += (targetCamX - camera.x) * Math.min(1, dt * 4);
        camera.y += (targetCamY - camera.y) * Math.min(1, dt * 4);

        // Приземление
        if (proj.iz <= 0 && art.timer > 0.05) {
            proj.iz = 0;
            art.state = 'aftermath';
            art.timer = 0;

            // Взрыв
            const expl = art.explosion;
            expl.active = true;
            expl.ix = proj.ix;
            expl.iy = proj.iy;
            expl.t = 0;
            expl.duration = 1.0;

            // Частицы взрыва
            expl.particles = [];
            const colors = ['#ff4400', '#ff6600', '#ffaa00', '#ffcc00', '#ff2200', '#aa3300', '#883300'];
            for (let i = 0; i < 60; i++) {
                const angle = Math.random() * Math.PI * 2;
                const speed = 40 + Math.random() * 120;
                expl.particles.push({
                    x: 0, y: 0,
                    vx: Math.cos(angle) * speed,
                    vy: Math.sin(angle) * speed * 0.5 - Math.random() * 60,
                    life: 0.5 + Math.random() * 0.6,
                    maxLife: 0.5 + Math.random() * 0.6,
                    size: PIXEL_SCALE * (1 + Math.random() * 2),
                    color: colors[Math.floor(Math.random() * colors.length)],
                });
            }
            // Частицы земли/обломков
            for (let i = 0; i < 30; i++) {
                const angle = Math.random() * Math.PI * 2;
                const speed = 20 + Math.random() * 80;
                expl.particles.push({
                    x: 0, y: 0,
                    vx: Math.cos(angle) * speed,
                    vy: Math.sin(angle) * speed * 0.5 - 40 - Math.random() * 80,
                    life: 0.6 + Math.random() * 0.5,
                    maxLife: 0.6 + Math.random() * 0.5,
                    size: PIXEL_SCALE,
                    color: ['#554433', '#443322', '#665544', '#332211'][Math.floor(Math.random() * 4)],
                });
            }

            // Тряска экрана
            triggerScreenShake(15);

            // Урон миньонам в радиусе взрыва
            for (const m of minions) {
                if (m.state === 'dead' || m.state === 'crumbled') continue;
                const mdx = m.ix - proj.ix;
                const mdy = m.iy - proj.iy;
                const mdist = Math.sqrt(mdx * mdx + mdy * mdy);
                if (mdist <= ARTILLERY_BLAST_RADIUS) {
                    const prevHp = m.hp;
                    m.hp = Math.max(0, m.hp - ARTILLERY_DAMAGE);
                    if (m.hp < prevHp) {
                        m.damageWobble = 0.4;
                        if (m.hp <= 0 && !m.dead) {
                            m.dead = true;
                            m.pendingBloodEffect = { type: 'death', ix: m.ix, iy: m.iy };
                            m.dropCarriedItem();
                            m.state = 'dead';
                            m.stateTime = 0;
                            m.deadTime = 0;
                        } else {
                            m.pendingBloodEffect = { type: 'hit', ix: m.ix, iy: m.iy };
                        }
                    }
                    // Отбросить
                    if (mdist > 0.01) {
                        const pushForce = (1 - mdist / ARTILLERY_BLAST_RADIUS) * 6;
                        m.vx = (mdx / mdist) * pushForce;
                        m.vy = (mdy / mdist) * pushForce;
                        m.vz = pushForce * 0.5;
                        if (m.state !== 'dead') {
                            m.state = 'thrown';
                            m.stateTime = 0;
                            m.bounceCount = 0;
                        }
                    }
                }
            }

            statusEl.textContent = 'Попадание!';
        }
    }

    if (art.state === 'aftermath') {
        art.timer += dt;

        // Обновляем частицы взрыва
        const expl = art.explosion;
        if (expl.active) {
            expl.t += dt;
            for (const p of expl.particles) {
                p.x += p.vx * dt;
                p.y += p.vy * dt;
                p.vy += 120 * dt; // гравитация
                p.life -= dt;
            }
            if (expl.t >= expl.duration) {
                expl.active = false;
            }
        }

        // После задержки возвращаем камеру к замку
        if (art.timer >= ARTILLERY_RETURN_DELAY) {
            const castleIso = isoToScreen(castle.ix, castle.iy);
            const targetCamX = castleIso.x * camera.zoom;
            const targetCamY = castleIso.y * camera.zoom;
            camera.x += (targetCamX - camera.x) * Math.min(1, dt * 3);
            camera.y += (targetCamY - camera.y) * Math.min(1, dt * 3);

            const camDx = Math.abs(camera.x - targetCamX);
            const camDy = Math.abs(camera.y - targetCamY);
            if (camDx < 5 && camDy < 5) {
                art.state = 'aiming';
                statusEl.textContent = 'Готов к выстрелу (Q — выход)';
            }
        }
    }
}

// ============================================================
//  ОБНОВЛЕНИЕ
// ============================================================
function update(dt) {
    // ── АРТИЛЛЕРИЯ — обновление ──────────────────────────────────
    if (artilleryMode.active) {
        updateArtillery(dt);
    }

    // Обновляем руку (движение, iso-координаты, анимация)
    if (!artilleryMode.active) {
        hand.update(dt, mouseX, mouseY, canvas, screenToIso);
    } else {
        // Рука зафиксирована на замке
        // isoToScreen → canvas position = isoX*zoom + canvasW/2 - camera.x
        const cs = isoToScreen(castle.ix, castle.iy);
        const handTargetX = cs.x * camera.zoom + canvas.width / 2 - camera.x;
        const handTargetY = cs.y * camera.zoom + canvas.height / 2 - camera.y;
        hand.screenX += (handTargetX - hand.screenX) * Math.min(1, dt * 12);
        hand.screenY += (handTargetY - hand.screenY) * Math.min(1, dt * 12);
        hand.isoX = castle.ix;
        hand.isoY = castle.iy;
        // Анимация закрытия
        if (hand.state === 'closing') {
            hand.animProgress += dt * 5;
            if (hand.animProgress >= 1) {
                hand.animProgress = 1;
                hand.state = 'closed';
            }
        }
    }

    // Рука вне зоны видимости — принудительно роняем предмет или миньона
    if (gameMap.getFog(Math.round(hand.isoX), Math.round(hand.isoY)) !== FOG.VISIBLE) {
        if (hand.grabbedItem !== null) {
            const item = items[hand.grabbedItem];
            item.grabbed = false;
            item.vx = 0; item.vy = 0; item.vz = 0;
            item.state = 'thrown';
            item.stateTime = 0;
            item.bounceCount = 0;
            hand.grabbedItem = null;
            hand.state = 'opening';
            hand.animProgress = 0;
            hand.velocityHistory = [];
        }
        if (hand.grabbedMinion !== null) {
            const minion = minions[hand.grabbedMinion];
            minion.vx = 0; minion.vy = 0; minion.vz = 0;
            minion.state = 'thrown';
            minion.stateTime = 0;
            minion.bounceCount = 0;
            hand.grabbedMinion = null;
            hand.minionGrabIso = null;
            hand.state = 'opening';
            hand.animProgress = 0;
            hand.velocityHistory = [];
        }
    }

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
    castle.update(dt, minions, castleResources);

    // Спавн гоблинов из замка
    if (castle.pendingSpawn) {
        const sp = castle.spawnPoint;
        spawnMinion(sp.ix, sp.iy);
    }

    // Обновляем миньонов
    for (let i = 0; i < minions.length; i++) {
        minions[i].update(dt, hand, triggerScreenShake, items, castle);
    }

    // Учитываем доставленные в замок ресурсы
    for (const minion of minions) {
        if (minion.pendingDelivery !== null) {
            castleResources[minion.pendingDelivery]++;
            minion.pendingDelivery = null;
        }
    }

    // Проверяем наведение на предметы, миньонов и флаг
    hoveredItem = null;
    hoveredMinion = null;
    hoveredFlag = false;
    if (artilleryMode.active) {
        // В режиме артиллерии наведение отключено
    } else if (hand.grabbedItem === null && hand.grabbedMinion === null && !hand.grabbedFlag) {
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
            if (m.state === 'dead' || m.state === 'crumbled') continue; // труп/надгробие нельзя взять
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

    // Эффект разрушения скелета — разлёт костей
    for (const minion of minions) {
        if (minion.pendingBoneEffect) {
            const effect = minion.pendingBoneEffect;
            minion.pendingBoneEffect = null;
            const s = worldToScreen(effect.ix, effect.iy);
            for (let i = 0; i < 18; i++) {
                bloodParticles.push({
                    x: s.x + (Math.random() - 0.5) * 10,
                    y: s.y - PIXEL_SCALE * 4,
                    vx: (Math.random() - 0.5) * 110,
                    vy: -35 - Math.random() * 65,
                    life: 0.7 * (0.6 + Math.random() * 0.4),
                    maxLife: 0.7,
                    size: PIXEL_SCALE,
                    color: ['#d8d0bc', '#c8c0ac', '#e0d8c4', '#b8b0a0'][Math.floor(Math.random() * 4)],
                });
            }
        }
    }

    // Удаляем скелетов помеченных на удаление (после разрушения)
    for (let i = minions.length - 1; i >= 0; i--) {
        if (!minions[i].pendingRemove) continue;
        if (hand.grabbedMinion === i) {
            hand.grabbedMinion = null;
            hand.minionGrabIso = null;
            hand.state = 'opening';
            hand.animProgress = 0;
            hand.velocityHistory = [];
        } else if (hand.grabbedMinion !== null && hand.grabbedMinion > i) {
            hand.grabbedMinion--;
        }
        minions.splice(i, 1);
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
    // Гоблин в руке не раскрывает туман. После смерти видимость угасает за 10 секунд.
    const FOG_DEATH_FADE = 10; // секунды
    const fogSources = [
        { ix: gameMap.castlePos.ix, iy: gameMap.castlePos.iy, radius: 10, shape: 'square' },
    ];
    for (const m of minions) {
        if (m.state === 'carried' || m.state === 'lifting') continue;
        if (m.isUndead) continue; // скелеты не раскрывают туман
        if (m.state === 'dead') {
            const r = 2 * Math.max(0, 1 - m.deadTime / FOG_DEATH_FADE);
            if (r > 0) fogSources.push({ ix: m.ix, iy: m.iy, radius: r });
        } else {
            fogSources.push({ ix: m.ix, iy: m.iy, radius: 2 });
        }
    }
    // Точка подбора гоблина остаётся освещённой пока он в руке —
    // иначе гоблин гасит собственный туман и рука мгновенно его роняет
    if (hand.grabbedMinion !== null && hand.minionGrabIso !== null) {
        fogSources.push({ ix: hand.minionGrabIso.ix, iy: hand.minionGrabIso.iy, radius: 2 });
    }
    gameMap.tickFog(fogSources);

    // Тряска экрана
    updateScreenShake(dt);

    // Плавный зум
    camera.zoom += (camera.targetZoom - camera.zoom) * Math.min(1, dt * 8);

    // Edge scroll — камера движется если мышь у края экрана
    {
    const EDGE_ZONE = 0.12; // 12% экрана с каждого края
    const PAN_SPEED = 600;  // px/сек в screen space
    const edgeW = canvas.width  * EDGE_ZONE;
    const edgeH = canvas.height * EDGE_ZONE;
    let panX = 0, panY = 0;
    // В режиме артиллерии используем мышь вместо руки (рука зафиксирована на замке)
    const edgeSrcX = artilleryMode.active ? mouseX : hand.screenX;
    const edgeSrcY = artilleryMode.active ? mouseY : hand.screenY;
    const overHud = !artilleryMode.active
        && mouseX >= hudPanelRect.x && mouseY >= hudPanelRect.y
        && mouseX <= hudPanelRect.x + hudPanelRect.w
        && mouseY <= hudPanelRect.y + hudPanelRect.h;
    if (!overHud) {
        if (edgeSrcX < edgeW) {
            panX = -(1 - edgeSrcX / edgeW) * PAN_SPEED;
        } else if (edgeSrcX > canvas.width - edgeW) {
            panX =  (1 - (canvas.width  - edgeSrcX) / edgeW) * PAN_SPEED;
        }
        if (edgeSrcY < edgeH) {
            panY = -(1 - edgeSrcY / edgeH) * PAN_SPEED;
        } else if (edgeSrcY > canvas.height - edgeH) {
            panY =  (1 - (canvas.height - edgeSrcY) / edgeH) * PAN_SPEED;
        }
    }
    camera.x += panX * dt;
    camera.y += panY * dt;
    }

    // Обновляем статус
    if (artilleryMode.active) {
        // Статус управляется артиллерией (updateArtillery / input.js)
    } else {
        const nothingHeld = hand.grabbedItem === null && hand.grabbedMinion === null && !hand.grabbedFlag;
        // Проверяем наведение на замок
        let hoveredCastle = false;
        if (nothingHeld && castle) {
            const cdx = hand.isoX - castle.ix;
            const cdy = hand.isoY - castle.iy;
            hoveredCastle = Math.sqrt(cdx * cdx + cdy * cdy) < ARTILLERY_GRAB_RADIUS;
        }
        if (hand.grabbedFlag) {
            if (hoveredItem !== null && hand.selectedMinions.length > 0) {
                statusEl.textContent = `Кликни — ${hand.selectedMinions.length} гоблин(а) начнут добычу!`;
            } else if (hoveredItem !== null) {
                statusEl.textContent = 'Ресурс — выдели гоблинов лассо для отправки на добычу';
            } else {
                statusEl.textContent = 'Флаг в руке — кликни чтобы установить';
            }
        } else if (nothingHeld && hoveredCastle) {
            statusEl.textContent = 'Замок [ЛКМ — режим стрельбы]';
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

    // Флаг всегда виден над туманом войны (игрок должен знать куда поставил флаг)
    if (flag.state === 'placed') {
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

    // Частицы крови (и костей)
    for (const p of bloodParticles) {
        const alpha = Math.pow(p.life / p.maxLife, 0.5) * 0.9;
        ctx.save();
        ctx.globalAlpha = alpha;
        ctx.fillStyle = p.color ?? '#cc1111';
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

    // ── АРТИЛЛЕРИЯ — рендер ────────────────────────────────────
    if (artilleryMode.active) {
        const art = artilleryMode;

        // Прицел (изометрический ромб)
        if (art.state === 'aiming') {
            const cs = worldToScreen(art.crosshairX, art.crosshairY);
            const now = performance.now();
            const pulse = 0.6 + 0.4 * Math.sin(now / 200);

            // Круг зоны поражения (7×7 тайлов)
            ctx.save();
            ctx.globalAlpha = 0.12 * pulse;
            ctx.fillStyle = '#ff2200';
            ctx.beginPath();
            // Радиус в пикселях (ARTILLERY_BLAST_RADIUS iso-тайлов)
            const blastPxW = ARTILLERY_BLAST_RADIUS * (TILE_W / 2);
            const blastPxH = ARTILLERY_BLAST_RADIUS * (TILE_H / 2);
            ctx.ellipse(cs.x, cs.y, blastPxW, blastPxH, 0, 0, Math.PI * 2);
            ctx.fill();
            ctx.restore();

            // Контур зоны
            ctx.save();
            ctx.globalAlpha = 0.4 * pulse;
            ctx.strokeStyle = '#ff4400';
            ctx.lineWidth = 2;
            ctx.setLineDash([6, 4]);
            ctx.beginPath();
            ctx.ellipse(cs.x, cs.y, blastPxW, blastPxH, 0, 0, Math.PI * 2);
            ctx.stroke();
            ctx.restore();

            // Перекрестие
            ctx.save();
            ctx.globalAlpha = 0.8;
            ctx.strokeStyle = '#ff4400';
            ctx.lineWidth = 2;
            const crossSize = 12;
            ctx.beginPath();
            ctx.moveTo(cs.x - crossSize, cs.y);
            ctx.lineTo(cs.x + crossSize, cs.y);
            ctx.moveTo(cs.x, cs.y - crossSize);
            ctx.lineTo(cs.x, cs.y + crossSize);
            ctx.stroke();
            // Центральная точка
            ctx.fillStyle = '#ff2200';
            ctx.fillRect(cs.x - 2, cs.y - 2, 4, 4);
            ctx.restore();
        }

        // Снаряд в полёте
        if (art.state === 'flying') {
            const proj = art.projectile;
            const ps = worldToScreen(proj.ix, proj.iy);
            const heightOffset = proj.iz * HEIGHT_TO_SCREEN;

            // Тень на земле
            drawItemShadow(ps.x, ps.y, CANNONBALL_W, CANNONBALL_H, proj.iz);

            // Ядро
            const ballOx = ps.x - (CANNONBALL_W * PIXEL_SCALE) / 2;
            const ballOy = ps.y - CANNONBALL_H * PIXEL_SCALE - 4 - heightOffset;
            drawPixelArt(ballOx, ballOy, CANNONBALL_PIXELS, PIXEL_SCALE);

            // Дымовой след
            ctx.save();
            ctx.globalAlpha = 0.3;
            ctx.fillStyle = '#888888';
            for (let i = 0; i < 5; i++) {
                const t = i * 0.03;
                const trailX = proj.ix - proj.vx * t;
                const trailY = proj.iy - proj.vy * t;
                const trailZ = proj.iz - proj.vz * t + GRAVITY * t * t * 0.5;
                if (trailZ < 0) continue;
                const ts = worldToScreen(trailX, trailY);
                const tho = trailZ * HEIGHT_TO_SCREEN;
                const size = PIXEL_SCALE * (1 + i * 0.3);
                ctx.globalAlpha = 0.25 - i * 0.04;
                ctx.fillRect(ts.x - size / 2, ts.y - 4 - tho - size / 2, size, size);
            }
            ctx.restore();
        }

        // Взрыв
        if (art.explosion.active) {
            const expl = art.explosion;
            const es = worldToScreen(expl.ix, expl.iy);

            // Вспышка
            if (expl.t < 0.15) {
                const flashAlpha = (1 - expl.t / 0.15) * 0.6;
                ctx.save();
                ctx.globalAlpha = flashAlpha;
                ctx.fillStyle = '#ffdd44';
                ctx.beginPath();
                const flashR = 40 + expl.t * 300;
                ctx.ellipse(es.x, es.y, flashR, flashR * 0.5, 0, 0, Math.PI * 2);
                ctx.fill();
                ctx.restore();
            }

            // Частицы
            for (const p of expl.particles) {
                if (p.life <= 0) continue;
                const alpha = Math.pow(p.life / p.maxLife, 0.5) * 0.9;
                ctx.save();
                ctx.globalAlpha = alpha;
                ctx.fillStyle = p.color;
                ctx.fillRect(
                    Math.round(es.x + p.x - p.size / 2),
                    Math.round(es.y + p.y - p.size / 2),
                    p.size, p.size
                );
                ctx.restore();
            }

            // Гарь на земле
            if (expl.t > 0.2) {
                ctx.save();
                ctx.globalAlpha = Math.min(0.3, (expl.t - 0.2) * 0.6) * (1 - expl.t / expl.duration);
                ctx.fillStyle = '#111100';
                const blastPxW = ARTILLERY_BLAST_RADIUS * (TILE_W / 2) * 0.8;
                const blastPxH = ARTILLERY_BLAST_RADIUS * (TILE_H / 2) * 0.8;
                ctx.beginPath();
                ctx.ellipse(es.x, es.y, blastPxW, blastPxH, 0, 0, Math.PI * 2);
                ctx.fill();
                ctx.restore();
            }
        }
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

    // HUD ресурсов — правый верхний угол (screen space)
    {
        const HUD_SCALE = 2;
        const HUD_MARGIN = 40;
        const HUD_ROW_H = 22;
        const maxW = Math.max(...ITEM_TYPES.map(t => t.w)) * HUD_SCALE;
        const totalH = ITEM_TYPES.length * HUD_ROW_H + 4;
        const hudX = canvas.width - HUD_MARGIN - maxW - 50;
        const hudY = HUD_MARGIN;

        // Фон
        ctx.save();
        ctx.globalAlpha = 0.55;
        ctx.fillStyle = '#0a0a18';
        ctx.fillRect(hudX - 8, hudY - 4, maxW + 60, totalH);
        ctx.restore();

        ctx.font = '13px monospace';
        ctx.textAlign = 'left';
        for (let i = 0; i < ITEM_TYPES.length; i++) {
            const type = ITEM_TYPES[i];
            const rowY = hudY + i * HUD_ROW_H;
            const iconH = type.h * HUD_SCALE;
            const iconY = rowY + Math.max(0, (HUD_ROW_H - iconH) / 2);
            drawPixelArt(hudX, iconY, type.pixels, HUD_SCALE);
            ctx.fillStyle = '#ffffff';
            ctx.fillText(`× ${castleResources[i] ?? 0}`, hudX + type.w * HUD_SCALE + 6, iconY + iconH / 2 + 4);
        }
    }

    // HUD производства гоблинов — под HUD ресурсов
    {
        const HUD_SCALE = 2;
        const HUD_MARGIN = 40;
        const HUD_ROW_H = 22;
        const maxW = Math.max(...ITEM_TYPES.map(t => t.w)) * HUD_SCALE;
        const resBlockH = ITEM_TYPES.length * HUD_ROW_H + 4;
        const hudX = canvas.width - HUD_MARGIN - maxW - 50;

        const gobY = HUD_MARGIN + resBlockH + 10;
        const blockW = maxW + 50;
        const barH = 8;
        const blockH = MINION_H * HUD_SCALE + barH + 20;

        // Обновляем rect (используется для кликов и hover)
        goblinHudRect.x = hudX - 8;
        goblinHudRect.y = gobY - 4;
        goblinHudRect.w = blockW + 16;
        goblinHudRect.h = blockH + 8;

        const isHovered = mouseX >= goblinHudRect.x && mouseX <= goblinHudRect.x + goblinHudRect.w
            && mouseY >= goblinHudRect.y && mouseY <= goblinHudRect.y + goblinHudRect.h;

        // Фон (ярче при наведении)
        ctx.save();
        ctx.globalAlpha = isHovered ? 0.80 : 0.55;
        ctx.fillStyle = isHovered ? '#151530' : '#0a0a18';
        ctx.fillRect(goblinHudRect.x, goblinHudRect.y, goblinHudRect.w, goblinHudRect.h);
        ctx.restore();

        // Рамка — подсвечивается при наведении
        ctx.save();
        ctx.strokeStyle = isHovered ? '#aaaaff' : '#333355';
        ctx.lineWidth = 1;
        ctx.strokeRect(goblinHudRect.x + 0.5, goblinHudRect.y + 0.5, goblinHudRect.w - 1, goblinHudRect.h - 1);
        ctx.restore();

        // Иконка гоблина
        drawPixelArt(hudX, gobY, MINION_PIXELS, HUD_SCALE);

        // Счётчик живых гоблинов
        const aliveCount = minions.filter(m => m.state !== 'dead' && !m.isUndead).length;
        ctx.fillStyle = '#ffffff';
        ctx.font = '12px monospace';
        ctx.textAlign = 'left';
        ctx.fillText(`${aliveCount} / ${castle.maxMinions}`, hudX + MINION_W * HUD_SCALE + 6, gobY + 12);

        // Прогресс-бар
        const prod = castle.production;
        const barY = gobY + MINION_H * HUD_SCALE + 4;
        const barW = blockW;
        ctx.fillStyle = '#222244';
        ctx.fillRect(hudX, barY, barW, barH);
        if (prod.progress > 0) {
            ctx.fillStyle = prod.active ? '#44aa44' : '#aa8833';
            ctx.fillRect(hudX, barY, barW * (prod.progress / prod.duration), barH);
        }

        // Статус / подсказка действия
        ctx.fillStyle = prod.active ? '#88ff88' : '#ffaa44';
        ctx.font = '11px monospace';
        ctx.textAlign = 'left';
        ctx.fillText(prod.active ? '⏸ Остановить' : '▶ Запустить', hudX, barY + barH + 12);

        // Курсор: pointer над кнопкой, none в игровой зоне
        canvas.style.cursor = isHovered ? 'pointer' : 'none';

        // Обновляем общий HUD-панель (resource + goblin) — блокирует edge scroll
        hudPanelRect.x = hudX - 8;
        hudPanelRect.y = HUD_MARGIN - 4;
        hudPanelRect.w = goblinHudRect.w;
        hudPanelRect.h = goblinHudRect.y + goblinHudRect.h - (HUD_MARGIN - 4);
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

    try {
        update(dt);
        render();
    } catch (err) {
        statusEl.textContent = 'ОШИБКА: ' + err.message;
        console.error('[gameLoop]', err);
    }

    requestAnimationFrame(gameLoop);
}

requestAnimationFrame(gameLoop);
