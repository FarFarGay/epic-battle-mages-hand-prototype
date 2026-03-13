// ============================================================
//  MAIN — точка входа, игровой цикл
// ============================================================
import {
    ITEM_TYPES, PIXEL_SCALE, HEIGHT_TO_SCREEN, GRAVITY, TILE_W, TILE_H,
    ARTILLERY_BLAST_RADIUS, ARTILLERY_DAMAGE, ARTILLERY_RETURN_DELAY,
    ARTILLERY_GRAB_RADIUS,
    WARRIOR_UPGRADE_INTERVAL, WARRIOR_IRON_COST,
    SCOUT_MAX_COUNT, SCOUT_UPGRADE_INTERVAL, SCOUT_WOOD_COST, SCOUT_FOOD_COST, SCOUT_FOG_RADIUS,
    FIREBALL_BLAST_RADIUS, FIREBALL_BLAST_DAMAGE,
    FIREBALL_COOLDOWN, FIREBALL_TILE_RADIUS,
    MANA_MAX, MANA_FIREBALL_COST, MANA_WATER_COST, MANA_EARTH_COST, MANA_WIND_COST,
    WATER_SPELL_COOLDOWN, WATER_SPELL_RADIUS,
    EARTH_SPELL_COOLDOWN, EARTH_SPELL_RADIUS,
    WIND_SPELL_COOLDOWN, WIND_SPELL_RADIUS, WIND_KNOCKBACK_FORCE,
    MONK_MAX_COUNT, MONK_MANA_REGEN, MONK_UPGRADE_INTERVAL, MONK_FOOD_COST,
    MONK_TOTEM_MIN_DIST, MONK_TOTEM_MAX_DIST,
    MINION_MAX_HP, SKELETON_MAX_HP,
} from './constants.js';
import { MINION_PIXELS, MINION_W, MINION_H, CANNONBALL_PIXELS, CANNONBALL_W, CANNONBALL_H, WARRIOR_HELMET_PIXELS, WARRIOR_HELMET_W, SCOUT_HOOD_PIXELS, SCOUT_HOOD_W, FIREBALL_PIXELS, FIREBALL_W, FIREBALL_H, MONK_ROBE_PIXELS, MONK_ROBE_W, MONK_TOTEM_PIXELS, MONK_TOTEM_W, MONK_TOTEM_H, WATER_SPELL_PIXELS, WATER_SPELL_W, WATER_SPELL_H, EARTH_SPELL_PIXELS, EARTH_SPELL_W, EARTH_SPELL_H, WIND_SPELL_PIXELS, WIND_SPELL_W, WIND_SPELL_H } from './sprites.js?v=3';
import { canvas, ctx, resize, drawPixelArt, drawItemShadow } from './renderer.js';
import { gameMap, FOG } from './Map.js';
import { camera, isoToScreen, screenToIso, getDepth, worldToScreen } from './isometry.js';
import { Hand } from './Hand.js';
import { items, minions, castle, screenShake, triggerScreenShake, updateScreenShake, resolveItemCollisions, resolveCastleCollisions, initWorld, bloodParticles, bloodPuddles, castleResources, spawnMinion, artilleryMode, getNextWarriorGuardPos, fireball, spellProjectile, manaPool, spellStates, activeTiles, spellFogReveals, debugFlags, monkTotem, commandMarkers, decoParticles } from './World.js?v=3';
import { initInput } from './input.js';
import { updateActiveTiles, applySpellInRadius, applySpellToTile, IMPACT_DUR, FADING_DUR } from './tileEffects.js?v=2';
import { Item } from './Item.js';
import { addDecorationsToRenderList } from './decorations.js?v=3';

// Тайловые частицы — одноразовые эффекты (всплеск воды, взрыв ветра)
const tileParticles = [];

// Палитры для тайловых эффектов (module-level, не аллоцируются в game loop)
const _FIRE_COLORS   = ['#ff4400', '#ff6600', '#ff8800', '#ffaa00', '#ffcc00'];
const _FIRE_FADING   = ['#882200', '#661100', '#441100', '#552200', '#331100'];
const _SPLASH_COLORS = ['#3388cc', '#55aaee', '#77ccff', '#2266aa'];
const _WIND_COLORS   = ['#aaffbb', '#88eebb', '#bbffcc', '#77ddaa'];
const _EARTH_COLORS  = ['#aa8855', '#887744', '#cc9955', '#665533', '#998855'];

// Кэшируемые HUD-значения (статические — вычислить один раз)
const _HUD_ITEM_MAX_W = Math.max(...ITEM_TYPES.map(t => t.w)); // макс. ширина спрайта ресурса (px)
// Spell states как массив для итерации без Object.keys() каждый кадр
const _SPELL_STATES = [spellStates.water, spellStates.earth, spellStates.wind];

// ============================================================
//  СОСТОЯНИЕ ВВОДА / UI
// ============================================================
const statusEl = document.getElementById('status');

let mouseX = canvas.width / 2;
let mouseY = canvas.height / 2;
let mouseDown = false;
let hoveredItem = null;
let hoveredMinion = null;

// Таймер апгрейда обычных гоблинов в воинов
let warriorUpgradeTimer = WARRIOR_UPGRADE_INTERVAL * Math.random(); // стагрированный старт

// Таймер производства разведчиков
let scoutUpgradeTimer = SCOUT_UPGRADE_INTERVAL * Math.random();

// Таймер производства монахов
let monkUpgradeTimer = MONK_UPGRADE_INTERVAL * Math.random();

// Попытаться превратить случайного свободного гоблина в воина.
// Стоимость: 1 железо (typeIndex 3). Гоблин марширует на пост у границы WARRIOR_GUARD_RADIUS.
function tryUpgradeWarrior() {
    if (!warriorProduction.active) return;
    if (castleResources[3] < WARRIOR_IRON_COST) return;
    const eligible = [];
    for (const m of minions) {
        if (m.goblinClass === 'basic' && !m.isUndead && !m.dead && m.state !== 'carried' && m.state !== 'lifting') {
            eligible.push(m);
        }
    }
    if (eligible.length === 0) return;
    const goblin = eligible[Math.floor(Math.random() * eligible.length)];
    castleResources[3] -= WARRIOR_IRON_COST;
    goblin.goblinClass = 'warrior';
    const pos = getNextWarriorGuardPos();
    goblin.guardX = pos.ix;
    goblin.guardY = pos.iy;
    goblin.state = 'warrior_returning';
    goblin.stateTime = 0;
}

// Попытаться превратить свободного гоблина в разведчика.
// Стоимость: 4 дерева (typeIndex 2) + 1 пшеница (typeIndex 0). Макс. 5 разведчиков.
function tryUpgradeScout() {
    if (!scoutProduction.active) return;
    const currentScouts = minions.filter(m => m.goblinClass === 'scout' && !m.dead && !m.isUndead).length;
    if (currentScouts >= SCOUT_MAX_COUNT) return;
    if (castleResources[2] < SCOUT_WOOD_COST) return; // дерево
    if (castleResources[0] < SCOUT_FOOD_COST) return; // пшеница
    const eligible = [];
    for (const m of minions) {
        if (m.goblinClass === 'basic' && !m.isUndead && !m.dead && m.state !== 'carried' && m.state !== 'lifting') {
            eligible.push(m);
        }
    }
    if (eligible.length === 0) return;
    const goblin = eligible[Math.floor(Math.random() * eligible.length)];
    castleResources[2] -= SCOUT_WOOD_COST;
    castleResources[0] -= SCOUT_FOOD_COST;
    goblin.goblinClass = 'scout';
    goblin.scoutAge = 0;
    goblin.pickNewTarget();
    goblin.state = 'free';
    goblin.stateTime = 0;
}

// Попытаться превратить гоблина в монаха-молельщика.
// Стоимость: 1 базовый гоблин + 1 пшеница (typeIndex 0). Макс. 5 монахов.
// Первый монах устанавливает тотем в случайной точке 10–25 тайлов от замка.
function tryUpgradeMonk() {
    if (!monkProduction.active) return;
    const currentMonks = minions.filter(m => m.goblinClass === 'monk' && !m.dead && !m.isUndead).length;
    if (currentMonks >= MONK_MAX_COUNT) return;
    if (castleResources[0] < MONK_FOOD_COST) return; // пшеница
    const eligible = [];
    for (const m of minions) {
        if (m.goblinClass === 'basic' && !m.isUndead && !m.dead && m.state !== 'carried' && m.state !== 'lifting') {
            eligible.push(m);
        }
    }
    if (eligible.length === 0) return;
    const goblin = eligible[Math.floor(Math.random() * eligible.length)];
    castleResources[0] -= MONK_FOOD_COST;
    goblin.goblinClass = 'monk';

    // Если тотем ещё не установлен — первый монах ставит его
    if (!monkTotem.active) {
        const angle = Math.random() * Math.PI * 2;
        const dist = MONK_TOTEM_MIN_DIST + Math.random() * (MONK_TOTEM_MAX_DIST - MONK_TOTEM_MIN_DIST);
        monkTotem.ix = Math.cos(angle) * dist;
        monkTotem.iy = Math.sin(angle) * dist;
        monkTotem.active = true;
    }

    goblin.totemX = monkTotem.ix;
    goblin.totemY = monkTotem.iy;
    goblin.state = 'monk_walking';
    goblin.stateTime = 0;
}

const selection = {
    active: false,
    startX: 0, startY: 0,
    endX: 0, endY: 0,
};

// ============================================================
//  РУКА
// ============================================================
const hand = new Hand();

// ============================================================
//  ИНИЦИАЛИЗАЦИЯ
// ============================================================
resize();
window.addEventListener('resize', resize);
ctx.imageSmoothingEnabled = false;

initWorld();
tileParticles.length = 0;

// Объект мирового состояния для input.js
const world = {
    items,
    minions,
    screenShake,
    selection,
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

// Области HUD (обновляются при рендере)
const goblinHudRect    = { x: 0, y: 0, w: 0, h: 0 };
const warriorHudRect   = { x: 0, y: 0, w: 0, h: 0 };
const scoutHudRect     = { x: 0, y: 0, w: 0, h: 0 };
const monkHudRect      = { x: 0, y: 0, w: 0, h: 0 };
const hudPanelRect     = { x: 0, y: 0, w: 0, h: 0 }; // весь правый HUD-панель (блокирует edge scroll)
const spellPanelRect   = { x: 0, y: 0, w: 0, h: 0 }; // левая панель заклинаний
const spellSlotRects   = [{}, {}, {}, {}]; // 4 слота: fire, water, earth, wind
const selectionBarRects = [];                          // слоты иконок выделенных гоблинов
const selectionBarPanel = { x: 0, y: 0, w: 0, h: 0 }; // вся панель выделения (блокирует edge scroll)

// Производство воинов: active = автоматически апгрейдить гоблинов при наличии железа
const warriorProduction = { active: false };

/// Производство разведчиков: active = автоматически превращать гоблинов в разведчиков
const scoutProduction = { active: false };

// Производство монахов: active = автоматически превращать гоблинов в монахов-молельщиков
const monkProduction = { active: false };

// Клик по кнопкам HUD — перехватываем ДО input.js (capture phase)
canvas.addEventListener('mousedown', (e) => {
    const mx = e.clientX, my = e.clientY;

    // Панель выделения — клик по слоту исключает гоблина из выделения
    for (let i = 0; i < selectionBarRects.length; i++) {
        const r = selectionBarRects[i];
        if (mx >= r.x && mx <= r.x + r.w && my >= r.y && my <= r.y + r.h) {
            hand.selectedMinions.splice(r.selIdx, 1);
            e.stopImmediatePropagation();
            return;
        }
    }

    if (
        mx >= goblinHudRect.x && mx <= goblinHudRect.x + goblinHudRect.w &&
        my >= goblinHudRect.y && my <= goblinHudRect.y + goblinHudRect.h
    ) {
        castle.production.active = !castle.production.active;
        e.stopImmediatePropagation();
        return;
    }
    if (
        mx >= warriorHudRect.x && mx <= warriorHudRect.x + warriorHudRect.w &&
        my >= warriorHudRect.y && my <= warriorHudRect.y + warriorHudRect.h
    ) {
        warriorProduction.active = !warriorProduction.active;
        e.stopImmediatePropagation();
        return;
    }
    if (
        mx >= scoutHudRect.x && mx <= scoutHudRect.x + scoutHudRect.w &&
        my >= scoutHudRect.y && my <= scoutHudRect.y + scoutHudRect.h
    ) {
        scoutProduction.active = !scoutProduction.active;
        e.stopImmediatePropagation();
        return;
    }
    if (
        mx >= monkHudRect.x && mx <= monkHudRect.x + monkHudRect.w &&
        my >= monkHudRect.y && my <= monkHudRect.y + monkHudRect.h
    ) {
        monkProduction.active = !monkProduction.active;
        e.stopImmediatePropagation();
        return;
    }

    // Захват заклинания из панели (4 слота)
    if (hand.grabbedItem === null && hand.grabbedMinion === null && !artilleryMode.active) {
        for (const sr of spellSlotRects) {
            if (!sr.key) continue;
            if (mx < sr.x || mx > sr.x + sr.w || my < sr.y || my > sr.y + sr.h) continue;
            if (manaPool.value < sr.cost) break;

            if (sr.key === 'fire') {
                if (fireball.state !== 'ready') break;
                manaPool.value -= sr.cost;
                fireball.ix = hand.isoX;
                fireball.iy = hand.isoY;
                fireball.iz = 0;
                fireball.state = 'lifting';
                fireball.stateTime = 0;
                fireball.liftProgress = 0;
                fireball.vx = 0; fireball.vy = 0; fireball.vz = 0;
                fireball.bounceCount = 0;
                fireball.pendingExplosion = false;
                fireball._exploded = false;
                hand.grabbedSpell = 'fireball';
                hand.state = 'closing';
                hand.animProgress = 0;
                hand.velocityHistory = [];
            } else if (sr.key === 'water' || sr.key === 'earth' || sr.key === 'wind') {
                const ss = spellStates[sr.key];
                if (ss.cooldown > 0) break;
                if (spellProjectile.state !== 'ready') break;
                manaPool.value -= sr.cost;
                // Инициализируем снаряд — как фаербол
                spellProjectile.spellType = sr.key;
                spellProjectile.ix = hand.isoX;
                spellProjectile.iy = hand.isoY;
                spellProjectile.iz = 0;
                spellProjectile.state = 'lifting';
                spellProjectile.stateTime = 0;
                spellProjectile.liftProgress = 0;
                spellProjectile.vx = 0; spellProjectile.vy = 0; spellProjectile.vz = 0;
                spellProjectile.bounceCount = 0;
                spellProjectile.pendingExplosion = false;
                spellProjectile._exploded = false;
                hand.grabbedSpell = sr.key;
                hand.state = 'closing';
                hand.animProgress = 0;
                hand.velocityHistory = [];
            }

            e.stopImmediatePropagation();
            return;
        }
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

            // Рваные края гари и вспышки (pre-generated, чтобы не мерцать)
            expl.scorchPoints = Array.from({ length: 28 }, () => 0.5 + Math.random() * 1.0);
            expl.flashPoints  = Array.from({ length: 18 }, () => 0.6 + Math.random() * 0.8);

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

            // Туман войны — открываем зону взрыва на 5 секунд
            art.fogRevealTimer = 5.0;

            // Урон миньонам и скелетам в радиусе взрыва
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
                        if (m.hp <= 0) {
                            if (m.isUndead) {
                                // Скелет разрушается
                                m.pendingBoneEffect = { ix: m.ix, iy: m.iy };
                                m.pendingRemove = true;
                                m.state = 'crumbled';
                            } else if (!m.dead) {
                                // Гоблин умирает
                                m.dead = true;
                                m.pendingBloodEffect = { type: 'death', ix: m.ix, iy: m.iy };
                                m.dropCarriedItem();
                                m.state = 'dead';
                                m.stateTime = 0;
                                m.deadTime = 0;
                            }
                        } else {
                            if (m.isUndead) {
                                m.pendingBoneEffect = { ix: m.ix, iy: m.iy };
                            } else {
                                m.pendingBloodEffect = { type: 'hit', ix: m.ix, iy: m.iy };
                            }
                        }
                    }
                    // Отбросить
                    if (mdist > 0.01 && m.state !== 'crumbled') {
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

            // Тайлы: стены в радиусе взрыва → щебень
            {
                const blastR = Math.ceil(ARTILLERY_BLAST_RADIUS);
                const blastR2 = ARTILLERY_BLAST_RADIUS * ARTILLERY_BLAST_RADIUS;
                const bix = Math.round(proj.ix), biy = Math.round(proj.iy);
                for (let dx = -blastR; dx <= blastR; dx++) {
                    for (let dy = -blastR; dy <= blastR; dy++) {
                        if (dx * dx + dy * dy > blastR2) continue;
                        if (gameMap.getTile(bix + dx, biy + dy) === 'wall')
                            gameMap.setTile(bix + dx, biy + dy, 'rubble', 'artillery');
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

    // Апгрейд гоблинов в воинов (случайный, стоит 1 железо)
    warriorUpgradeTimer -= dt;
    if (warriorUpgradeTimer <= 0) {
        warriorUpgradeTimer = WARRIOR_UPGRADE_INTERVAL;
        tryUpgradeWarrior();
    }

    // Производство разведчиков (стоит 4 дерева + 1 пшеница)
    scoutUpgradeTimer -= dt;
    if (scoutUpgradeTimer <= 0) {
        scoutUpgradeTimer = SCOUT_UPGRADE_INTERVAL;
        tryUpgradeScout();
    }

    // Производство монахов
    monkUpgradeTimer -= dt;
    if (monkUpgradeTimer <= 0) {
        monkUpgradeTimer = MONK_UPGRADE_INTERVAL;
        tryUpgradeMonk();
    }

    // ── МАНА — восстановление монахами ─────────────────────────
    let prayingMonks = 0;
    for (const m of minions) {
        if (m.goblinClass === 'monk' && m.state === 'monk_praying' && !m.dead && !m.isUndead) prayingMonks++;
    }
    if (prayingMonks > 0) {
        manaPool.value = Math.min(MANA_MAX, manaPool.value + prayingMonks * MONK_MANA_REGEN * dt);
    }

    // ── ПЕРЕЗАРЯДКА ЗАКЛИНАНИЙ ──────────────────────────────────
    for (const ss of _SPELL_STATES) {
        if (ss.cooldown > 0) ss.cooldown = Math.max(0, ss.cooldown - dt);
    }

    // ── ОБНОВЛЕНИЕ АКТИВНЫХ ТАЙЛОВ (burning → scorched, puddle → plain и т.д.)
    updateActiveTiles(dt);

    // ── ОГНЕННЫЙ ШАР — обновление ──────────────────────────────
    fireball.update(dt, hand, triggerScreenShake);

    // Обрабатываем взрыв
    if (fireball.pendingExplosion) {
        fireball.pendingExplosion = false;
        const ex = fireball.ix, ey = fireball.iy;

        triggerScreenShake(10);

        // Урон от взрыва
        for (const m of minions) {
            if (m.dead || m.pendingRemove) continue;
            if (m.state === 'carried' || m.state === 'lifting') continue;
            const dx = m.ix - ex, dy = m.iy - ey;
            const dist = Math.sqrt(dx * dx + dy * dy);
            if (dist < FIREBALL_BLAST_RADIUS) {
                const dmg = Math.round((1 - dist / FIREBALL_BLAST_RADIUS) * FIREBALL_BLAST_DAMAGE);
                if (dmg > 0) {
                    m.hp -= dmg;
                    if (m.hp <= 0) {
                        m.hp = 0;
                        if (m.isUndead) {
                            m.pendingBoneEffect = { ix: m.ix, iy: m.iy };
                            m.pendingRemove = true;
                            m.state = 'crumbled';
                        } else {
                            m.dead = true;
                            m.pendingBloodEffect = { type: 'death', ix: m.ix, iy: m.iy };
                        }
                    } else {
                        if (m.isUndead) {
                            m.pendingBoneEffect = { ix: m.ix, iy: m.iy };
                        } else {
                            m.pendingBloodEffect = { type: 'hit', ix: m.ix, iy: m.iy };
                        }
                    }
                }
            }
        }

        // Трансформация тайлов в зоне взрыва (burning, steam и т.д.)
        applySpellInRadius('fire', ex, ey, FIREBALL_TILE_RADIUS, 'fire');
    }

    // ── СНАРЯД ЗАКЛИНАНИЯ — обновление ────────────────────────
    spellProjectile.update(dt, hand, triggerScreenShake);

    // Обрабатываем приземление снаряда
    if (spellProjectile.pendingExplosion) {
        spellProjectile.pendingExplosion = false;
        const ex = spellProjectile.ix, ey = spellProjectile.iy;
        const spellKey = spellProjectile.spellType;

        // Ставим кулдаун
        spellStates[spellKey].cooldown = spellStates[spellKey].maxCooldown;

        triggerScreenShake(4);

        const spellRadius = spellKey === 'water' ? WATER_SPELL_RADIUS
                          : spellKey === 'earth' ? EARTH_SPELL_RADIUS
                          : WIND_SPELL_RADIUS;

        if (spellKey === 'earth') {
            // Per-tile чтобы отследить вырубку леса → дроп дерева
            const rcx = Math.round(ex), rcy = Math.round(ey);
            const ri = Math.ceil(EARTH_SPELL_RADIUS);
            const r2 = EARTH_SPELL_RADIUS * EARTH_SPELL_RADIUS;
            for (let dy = -ri; dy <= ri; dy++) {
                for (let dx = -ri; dx <= ri; dx++) {
                    if (dx * dx + dy * dy > r2) continue;
                    const tix = rcx + dx, tiy = rcy + dy;
                    if (!gameMap.isInBounds(tix, tiy)) continue;
                    const oldType = gameMap.getTile(tix, tiy);
                    if (!applySpellToTile('earth', tix, tiy, 'earth')) continue;
                    // Пыль при ударе земли
                    {
                        const dustCount = 2 + Math.floor(Math.random() * 3);
                        for (let d = 0; d < dustCount; d++) {
                            const da = Math.random() * Math.PI * 2;
                            const ds = 28 + Math.random() * 32;
                            const sc2 = worldToScreen(tix + (Math.random() - 0.5) * 0.4, tiy + (Math.random() - 0.5) * 0.4);
                            tileParticles.push({
                                type: 'dust',
                                x: sc2.x, y: sc2.y,
                                vx: Math.cos(da) * ds,
                                vy: Math.sin(da) * ds * 0.5 - 8,
                                life: 0.45 + Math.random() * 0.20,
                                maxLife: 0.65,
                                size: 2 + Math.floor(Math.random() * 2),
                                color: _EARTH_COLORS[Math.floor(Math.random() * _EARTH_COLORS.length)],
                            });
                        }
                    }
                    if (oldType === 'forest') {
                        const count = 1 + Math.floor(Math.random() * 2);
                        for (let i = 0; i < count; i++) {
                            items.push(new Item(2,
                                tix + (Math.random() - 0.5) * 0.8,
                                tiy + (Math.random() - 0.5) * 0.8));
                        }
                    }
                }
            }
        } else {
            applySpellInRadius(spellKey, ex, ey, spellRadius, spellKey);
        }

        // Туман войны: вода и ветер — временно, земля — навсегда
        {
            const fogTimer  = spellKey === 'earth' ? -1        // навсегда
                            : spellKey === 'water' ? 8.0
                            : 6.0; // wind
            const fogRadius = spellKey === 'water' ? WATER_SPELL_RADIUS + 1
                            : spellKey === 'wind'  ? WIND_SPELL_RADIUS  + 2
                            : EARTH_SPELL_RADIUS + 1;
            spellFogReveals.push({ ix: ex, iy: ey, radius: fogRadius, timer: fogTimer });
        }

        // Ветер: отбросить юнитов в радиусе
        if (spellKey === 'wind') {
            const r2 = WIND_SPELL_RADIUS * WIND_SPELL_RADIUS;
            for (const m of minions) {
                if (m.dead || m.pendingRemove || m.state === 'crumbled') continue;
                if (m.state === 'carried' || m.state === 'lifting') continue;
                const dx = m.ix - ex, dy = m.iy - ey;
                const d2 = dx * dx + dy * dy;
                if (d2 > r2 || d2 < 0.01) continue;
                const dist = Math.sqrt(d2);
                const nx = dx / dist, ny = dy / dist;
                const force = WIND_KNOCKBACK_FORCE * (1 - dist / WIND_SPELL_RADIUS);
                m.vx = nx * force;
                m.vy = ny * force;
                m.vz = force * 0.4;
                m.iz = 0.1;
                m.state = 'thrown';
                m.stateTime = 0;
                m.bounceCount = 0;
                m.windPushed = true;
            }
        }

        // Ветер раздувает огонь: burning-тайлы распространяют огонь «по ветру»
        if (spellKey === 'wind') {
            const windIx = Math.round(ex), windIy = Math.round(ey);
            const ri = Math.ceil(WIND_SPELL_RADIUS);
            const r2 = WIND_SPELL_RADIUS * WIND_SPELL_RADIUS;
            for (let dy = -ri; dy <= ri; dy++) {
                for (let dx = -ri; dx <= ri; dx++) {
                    if (dx * dx + dy * dy > r2) continue;
                    const tx = windIx + dx, ty = windIy + dy;
                    if (gameMap.getTile(tx, ty) !== 'burning') continue;

                    // Направление «по ветру» — от центра взрыва через горящий тайл
                    const len = Math.sqrt(dx * dx + dy * dy);
                    if (len < 0.01) continue;
                    const ndx = Math.round(dx / len);
                    const ndy = Math.round(dy / len);

                    // Поджигаем три тайла «впереди» горящего (прямо + чуть по бокам)
                    for (const [nx, ny] of [
                        [tx + ndx,       ty + ndy      ],
                        [tx + ndx + ndy, ty + ndy - ndx],
                        [tx + ndx - ndy, ty + ndy + ndx],
                    ]) {
                        if (!gameMap.isInBounds(nx, ny)) continue;
                        const nt = gameMap.getTile(nx, ny);
                        if (nt === 'forest' || nt === 'plain' || nt === 'village')
                            applySpellToTile('fire', nx, ny, 'wind');
                    }
                }
            }
        }

        // Вода: всплеск при приземлении
        if (spellKey === 'water') {
            const sc = worldToScreen(ex, ey);
            for (let i = 0; i < 10; i++) {
                const angle = Math.random() * Math.PI * 2;
                const speed = 35 + Math.random() * 45;
                tileParticles.push({
                    type: 'splash',
                    x: sc.x + (Math.random() - 0.5) * 4,
                    y: sc.y,
                    vx: Math.cos(angle) * speed,
                    vy: Math.sin(angle) * speed * 0.4 - 25,
                    life: 0.45 + Math.random() * 0.1,
                    maxLife: 0.55,
                    size: 2 + Math.floor(Math.random() * 2),
                    color: _SPLASH_COLORS[Math.floor(Math.random() * _SPLASH_COLORS.length)],
                });
            }
        }

        // Ветер: ударное кольцо + закрученные частицы-лепестки при приземлении
        if (spellKey === 'wind') {
            const sc = worldToScreen(ex, ey);
            // Расширяющееся кольцо ударной волны
            tileParticles.push({
                type: 'windRing',
                x: sc.x, y: sc.y,
                maxRx: WIND_SPELL_RADIUS * TILE_W / 2,
                maxRy: WIND_SPELL_RADIUS * TILE_H / 2,
                life: 0.35, maxLife: 0.35,
            });
            // Спиральные частицы
            for (let i = 0; i < 14; i++) {
                const angle = (i / 14) * Math.PI * 2 + Math.random() * 0.3;
                const speed = 60 + Math.random() * 40;
                tileParticles.push({
                    type: 'wind',
                    x: sc.x,
                    y: sc.y,
                    vx: Math.cos(angle) * speed,
                    vy: Math.sin(angle) * speed * 0.5,
                    life: 0.6 + Math.random() * 0.3,
                    maxLife: 0.9,
                    size: 1 + Math.floor(Math.random() * 2),
                    color: _WIND_COLORS[Math.floor(Math.random() * _WIND_COLORS.length)],
                    angularSpeed: 2 + Math.random() * 3,
                });
            }
        }
    }

    // После settling — сбрасываем снаряд
    if (spellProjectile.state === 'done') {
        spellProjectile.reset();
    }

    // Обновляем миньонов
    for (let i = 0; i < minions.length; i++) {
        minions[i].update(dt, hand, triggerScreenShake, items, castle, minions);
    }

    // Очищаем мёртвых/нежить из выделенных миньонов (могли умереть в этом кадре)
    if (hand.selectedMinions.length > 0) {
        hand.selectedMinions = hand.selectedMinions.filter(idx => {
            const m = minions[idx];
            return m && !m.dead && !m.isUndead;
        });
    }

    // Учитываем доставленные в замок ресурсы
    for (const minion of minions) {
        if (minion.pendingDelivery !== null) {
            castleResources[minion.pendingDelivery]++;
            minion.pendingDelivery = null;
        }
    }

    // Проверяем наведение на предметы и миньонов
    hoveredItem = null;
    hoveredMinion = null;
    if (artilleryMode.active) {
        // В режиме артиллерии наведение отключено
    } else if (hand.grabbedItem === null && hand.grabbedMinion === null) {
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
            if (m.state === 'dead' || m.state === 'crumbled') continue;
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
        // Корректируем индексы выделенных миньонов
        const newSelected = [];
        for (const idx of hand.selectedMinions) {
            if (idx === i) continue; // удалённый — пропускаем
            newSelected.push(idx > i ? idx - 1 : idx);
        }
        hand.selectedMinions = newSelected;
        // Корректируем hoveredMinion
        if (hoveredMinion === i) {
            hoveredMinion = null;
        } else if (hoveredMinion !== null && hoveredMinion > i) {
            hoveredMinion--;
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

    // Обновляем тайловые частицы (всплеск воды, взрыв ветра, пыль земли, кольцо ветра)
    for (let i = tileParticles.length - 1; i >= 0; i--) {
        const p = tileParticles[i];
        p.life -= dt;
        if (p.life <= 0) { tileParticles.splice(i, 1); continue; }
        if (p.type === 'windRing') continue; // без физики — только таймер
        if (p.type === 'wind') {
            const perpX = -p.vy * p.angularSpeed * dt;
            const perpY =  p.vx * p.angularSpeed * dt * 0.5;
            p.vx = (p.vx + perpX) * 0.97;
            p.vy = (p.vy + perpY) * 0.97;
        } else {
            p.vy += 150 * dt; // гравитация (splash, dust)
        }
        p.x += p.vx * dt;
        p.y += p.vy * dt;
    }

    // Обновляем частицы разрушения декораций
    for (let i = decoParticles.length - 1; i >= 0; i--) {
        const p = decoParticles[i];
        p.life -= dt;
        if (p.life <= 0) { decoParticles.splice(i, 1); continue; }
        p.vy += p.gravity * dt;
        p.x  += p.vx * dt;
        p.y  += p.vy * dt;
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
            const fogR = m.goblinClass === 'scout' ? SCOUT_FOG_RADIUS : 2;
            fogSources.push({ ix: m.ix, iy: m.iy, radius: fogR });
        }
    }
    // Точка подбора гоблина остаётся освещённой пока он в руке —
    // иначе гоблин гасит собственный туман и рука мгновенно его роняет
    if (hand.grabbedMinion !== null && hand.minionGrabIso !== null) {
        fogSources.push({ ix: hand.minionGrabIso.ix, iy: hand.minionGrabIso.iy, radius: 2 });
    }
    // Летящий артиллерийский снаряд рассеивает туман
    if (artilleryMode.active && artilleryMode.state === 'flying') {
        fogSources.push({ ix: artilleryMode.projectile.ix, iy: artilleryMode.projectile.iy, radius: 3 });
    }
    // Зона взрыва артиллерии остаётся открытой после попадания
    if (artilleryMode.fogRevealTimer > 0) {
        artilleryMode.fogRevealTimer -= dt;
        fogSources.push({ ix: artilleryMode.explosion.ix, iy: artilleryMode.explosion.iy, radius: ARTILLERY_BLAST_RADIUS + 2 });
    }
    // Летящий огненный шар рассеивает туман войны
    if (fireball.state === 'thrown' || fireball.state === 'bouncing') {
        fogSources.push({ ix: fireball.ix, iy: fireball.iy, radius: 3 });
    }
    // Летящий снаряд заклинания рассеивает туман
    if (spellProjectile.state === 'thrown' || spellProjectile.state === 'bouncing') {
        fogSources.push({ ix: spellProjectile.ix, iy: spellProjectile.iy, radius: 2 });
    }
    // Горящие тайлы рассеивают туман до потухания
    for (const tile of activeTiles) {
        if (tile.type === 'burning') {
            fogSources.push({ ix: tile.ix, iy: tile.iy, radius: 1.5 });
        }
    }
    // Заклинания: вода/ветер — временно, земля — навсегда
    for (let i = spellFogReveals.length - 1; i >= 0; i--) {
        const r = spellFogReveals[i];
        fogSources.push({ ix: r.ix, iy: r.iy, radius: r.radius });
        if (r.timer >= 0) {
            r.timer -= dt;
            if (r.timer <= 0) spellFogReveals.splice(i, 1);
        }
    }
    if (debugFlags.fogDisabled) {
        // P — туман отключён: добавляем источник, покрывающий всю карту
        fogSources.push({ ix: gameMap.castlePos.ix, iy: gameMap.castlePos.iy, radius: 200 });
    }
    gameMap.tickFog(fogSources);

    // Обновляем маркеры команд (таймер, удаляем истёкшие)
    for (let i = commandMarkers.length - 1; i >= 0; i--) {
        commandMarkers[i].timer += dt;
        if (commandMarkers[i].timer >= commandMarkers[i].maxTime) {
            commandMarkers.splice(i, 1);
        }
    }

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
    const overHud = !artilleryMode.active && (
        (mouseX >= hudPanelRect.x && mouseY >= hudPanelRect.y
            && mouseX <= hudPanelRect.x + hudPanelRect.w
            && mouseY <= hudPanelRect.y + hudPanelRect.h)
        ||
        (mouseX >= spellPanelRect.x && mouseY >= spellPanelRect.y
            && mouseX <= spellPanelRect.x + spellPanelRect.w
            && mouseY <= spellPanelRect.y + spellPanelRect.h)
        ||
        (selectionBarPanel.w > 0
            && mouseX >= selectionBarPanel.x && mouseY >= selectionBarPanel.y
            && mouseX <= selectionBarPanel.x + selectionBarPanel.w
            && mouseY <= selectionBarPanel.y + selectionBarPanel.h)
    );
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
        const nothingHeld = hand.grabbedItem === null && hand.grabbedMinion === null;
        // Проверяем наведение на замок
        let hoveredCastle = false;
        if (nothingHeld && castle) {
            const cdx = hand.isoX - castle.ix;
            const cdy = hand.isoY - castle.iy;
            hoveredCastle = Math.sqrt(cdx * cdx + cdy * cdy) < ARTILLERY_GRAB_RADIUS;
        }
        if (nothingHeld && hoveredCastle) {
            statusEl.textContent = 'Замок [ЛКМ — режим стрельбы]';
        } else if (nothingHeld && hoveredItem !== null) {
            statusEl.textContent = `Навести: ${ITEM_TYPES[items[hoveredItem].typeIndex].name} [зажми ЛКМ]`;
        } else if (nothingHeld && hoveredMinion !== null) {
            statusEl.textContent = 'Навести: Миньон [зажми ЛКМ]';
        } else if (nothingHeld && hand.selectedMinions.length > 0) {
            statusEl.textContent = `Выделено ${hand.selectedMinions.length} гоблин(а) — ПКМ для команды`;
        } else if (nothingHeld) {
            statusEl.textContent = 'Рука открыта';
        }
    }
}

// ============================================================
//  ПАНЕЛЬ ВЫДЕЛЕНИЯ
// ============================================================
function drawSelectionBar() {
    const sel = hand.selectedMinions;
    selectionBarRects.length = 0;

    if (sel.length === 0) {
        selectionBarPanel.w = 0;
        return;
    }

    const HS = 2;           // HUD_SCALE
    const HP_H = 4;         // высота HP-бара
    const PAD_X = 5;        // горизонтальный отступ внутри слота
    const PAD_Y = 5;        // вертикальный отступ внутри слота
    const GAP = 4;          // расстояние между слотами
    const PANEL_PAD = 8;    // отступ панели

    const slotW = MINION_W * HS + PAD_X * 2;
    const slotH = MINION_H * HS + HP_H + 5 + PAD_Y * 2;
    const totalW = sel.length * slotW + (sel.length - 1) * GAP + PANEL_PAD * 2;
    const totalH = slotH + PANEL_PAD * 2;
    const panelX = Math.round(canvas.width / 2 - totalW / 2);
    const panelY = canvas.height - totalH - 12;

    selectionBarPanel.x = panelX;
    selectionBarPanel.y = panelY;
    selectionBarPanel.w = totalW;
    selectionBarPanel.h = totalH;

    // Фон панели
    ctx.save();
    ctx.globalAlpha = 0.75;
    ctx.fillStyle = '#0a0a18';
    ctx.fillRect(panelX, panelY, totalW, totalH);
    ctx.globalAlpha = 1;
    ctx.strokeStyle = '#44ff88';
    ctx.lineWidth = 1;
    ctx.strokeRect(panelX + 0.5, panelY + 0.5, totalW - 1, totalH - 1);
    ctx.restore();

    for (let i = 0; i < sel.length; i++) {
        const mIdx = sel[i];
        const m = minions[mIdx];
        if (!m) continue;

        const slotX = panelX + PANEL_PAD + i * (slotW + GAP);
        const slotY = panelY + PANEL_PAD;

        selectionBarRects.push({ x: slotX, y: slotY, w: slotW, h: slotH, selIdx: i });

        const isHov = mouseX >= slotX && mouseX <= slotX + slotW
                   && mouseY >= slotY && mouseY <= slotY + slotH;

        // Фон слота
        ctx.save();
        ctx.globalAlpha = isHov ? 0.55 : 0.3;
        ctx.fillStyle = isHov ? '#1a2a1a' : '#111122';
        ctx.fillRect(slotX, slotY, slotW, slotH);
        ctx.globalAlpha = 1;
        ctx.strokeStyle = isHov ? '#88ffaa' : '#2a4a2a';
        ctx.lineWidth = 1;
        ctx.strokeRect(slotX + 0.5, slotY + 0.5, slotW - 1, slotH - 1);
        ctx.restore();

        // Спрайт гоблина
        const sprX = Math.round(slotX + (slotW - MINION_W * HS) / 2);
        const sprY = slotY + PAD_Y;
        drawPixelArt(sprX, sprY, MINION_PIXELS, HS);

        // Наложение класса
        if (m.goblinClass === 'warrior') {
            const ox = Math.round(sprX + (MINION_W - WARRIOR_HELMET_W) / 2 * HS);
            drawPixelArt(ox, sprY, WARRIOR_HELMET_PIXELS, HS);
        } else if (m.goblinClass === 'scout') {
            const ox = Math.round(sprX + (MINION_W - SCOUT_HOOD_W) / 2 * HS);
            drawPixelArt(ox, sprY, SCOUT_HOOD_PIXELS, HS);
        } else if (m.goblinClass === 'monk') {
            const ox = Math.round(sprX + (MINION_W - MONK_ROBE_W) / 2 * HS);
            drawPixelArt(ox, sprY, MONK_ROBE_PIXELS, HS);
        }

        // HP-бар
        const barX = slotX + PAD_X;
        const barW = slotW - PAD_X * 2;
        const barY = sprY + MINION_H * HS + 4;
        const maxHp = m.isUndead ? SKELETON_MAX_HP : MINION_MAX_HP;
        const hpFrac = Math.max(0, m.hp / maxHp);
        ctx.fillStyle = '#1a1a2a';
        ctx.fillRect(barX, barY, barW, HP_H);
        if (hpFrac > 0) {
            ctx.fillStyle = hpFrac > 0.5 ? '#44cc44' : hpFrac > 0.25 ? '#ccaa22' : '#cc3322';
            ctx.fillRect(barX, barY, Math.round(barW * hpFrac), HP_H);
        }

        // × при наведении
        if (isHov) {
            ctx.save();
            ctx.fillStyle = 'rgba(220, 60, 60, 0.85)';
            ctx.font = 'bold 10px monospace';
            ctx.textAlign = 'right';
            ctx.textBaseline = 'top';
            ctx.fillText('×', slotX + slotW - 2, slotY + 2);
            ctx.restore();
            canvas.style.cursor = 'pointer';
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

    // Огненный шар в полёте
    if (fireball.state !== 'ready' && fireball.state !== 'done' &&
        fireball.state !== 'lifting' && fireball.state !== 'carried') {
        renderList.push({
            type: 'fireball',
            depth: getDepth(fireball.ix, fireball.iy) + fireball.iz * 0.1,
        });
    }

    // Снаряд заклинания в полёте
    if (spellProjectile.state !== 'ready' && spellProjectile.state !== 'done' &&
        spellProjectile.state !== 'lifting' && spellProjectile.state !== 'carried') {
        renderList.push({
            type: 'spellProjectile',
            depth: getDepth(spellProjectile.ix, spellProjectile.iy) + spellProjectile.iz * 0.1,
        });
    }

    // Тотем монахов
    if (monkTotem.active) {
        renderList.push({
            type: 'monkTotem',
            depth: getDepth(monkTotem.ix, monkTotem.iy),
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

    // Декорации (деревья, камни, домики)
    addDecorationsToRenderList(renderList, canvas);

    // Тайловые визуальные эффекты — огонь, пар, рябь (world space, через draw-closure)
    for (const tile of activeTiles) {
        if (gameMap.getFog(tile.ix, tile.iy) !== FOG.VISIBLE) continue;
        const t = tile;

        if (t.type === 'burning') {
            renderList.push({ depth: t.ix + t.iy + 0.05, draw() {
                const now = performance.now() * 0.001;
                const sc  = worldToScreen(t.ix, t.iy);

                if (t.phase === 'impact') {
                    // Вспышка: оранжевый эллипс затухает
                    const imp   = IMPACT_DUR.burning ?? 0.5;
                    const prog  = Math.max(0, 1 - t.phaseTimer / imp);
                    ctx.save();
                    ctx.globalAlpha = prog * 0.65;
                    ctx.fillStyle   = '#ffdd44';
                    ctx.beginPath();
                    ctx.ellipse(sc.x, sc.y, Math.max(1, (TILE_W / 4) * prog), Math.max(1, (TILE_H / 4) * prog), 0, 0, Math.PI * 2);
                    ctx.fill();
                    ctx.restore();
                } else if ((t.phase === 'active' || t.phase === 'fading') && t.firePixels) {
                    const fadeFrac = t.phase === 'fading'
                        ? Math.min(1, t.phaseTimer / (FADING_DUR.burning ?? 1.0))
                        : 0;
                    const alphaScale = 1 - fadeFrac * 0.85;
                    const palette    = fadeFrac > 0.5 ? _FIRE_FADING : _FIRE_COLORS;
                    for (const px of t.firePixels) {
                        const psc  = worldToScreen(t.ix + px.ox, t.iy + px.oy);
                        const yOff = -Math.abs(Math.sin(now * 6 + px.phase)) * 8 * (1 - fadeFrac * 0.7);
                        const a    = (0.6 + 0.4 * (0.5 + 0.5 * Math.sin(now * 8 + px.phase))) * alphaScale;
                        ctx.globalAlpha = Math.max(0, a);
                        ctx.fillStyle   = palette[px.colorIdx % palette.length];
                        const sz = Math.max(1, px.size * (1 - fadeFrac * 0.5));
                        ctx.fillRect(Math.round(psc.x - sz / 2), Math.round(psc.y + yOff - sz / 2), sz, sz);
                    }
                    ctx.globalAlpha = 1;
                }
            }});
        } else if (t.type === 'steam' && t.steamPuffs) {
            renderList.push({ depth: t.ix + t.iy + 0.05, draw() {
                const now = performance.now() * 0.001;
                const sc  = worldToScreen(t.ix, t.iy);

                if (t.phase === 'impact') {
                    // Белая вспышка
                    const imp  = IMPACT_DUR.steam ?? 0.4;
                    const prog = Math.max(0, 1 - t.phaseTimer / imp);
                    ctx.save();
                    ctx.globalAlpha = prog * 0.5;
                    ctx.fillStyle   = '#ddddee';
                    ctx.beginPath();
                    ctx.ellipse(sc.x, sc.y, Math.max(1, (TILE_W / 5) * prog), Math.max(1, (TILE_H / 5) * prog), 0, 0, Math.PI * 2);
                    ctx.fill();
                    ctx.restore();
                } else {
                    const fadeFrac = t.phase === 'fading'
                        ? Math.min(1, t.phaseTimer / (FADING_DUR.steam ?? 0.8))
                        : 0;
                    for (const puff of t.steamPuffs) {
                        const psc    = worldToScreen(t.ix + puff.ox, t.iy + puff.oy);
                        const yOff   = -(((now * 15) + puff.phase) % 30);
                        const baseA  = 0.35 * (1 - (-yOff) / 30);
                        const alpha  = baseA * (1 - fadeFrac);
                        if (alpha < 0.01) continue;
                        const xWobble = Math.sin(now * 2 + puff.wobblePhase) * 3;
                        const sz      = (puff.size / 2) * (1 + fadeFrac * 0.6);
                        ctx.globalAlpha = alpha;
                        ctx.fillStyle   = '#ccccdd';
                        ctx.beginPath();
                        ctx.arc(psc.x + xWobble, psc.y + yOff, sz, 0, Math.PI * 2);
                        ctx.fill();
                    }
                    ctx.globalAlpha = 1;
                }
            }});
        } else if (t.type === 'puddle' && t.ripplePhase !== undefined) {
            renderList.push({ depth: t.ix + t.iy - 0.01, draw() {
                const now = performance.now() * 0.001;
                const sc  = worldToScreen(t.ix, t.iy);

                if (t.phase === 'impact') {
                    // Яркое голубое кольцо расширяется
                    const imp  = IMPACT_DUR.puddle ?? 0.4;
                    const prog = Math.max(0, t.phaseTimer / imp); // 0 → 1
                    const rx   = prog * (TILE_W / 3);
                    const ry   = prog * (TILE_H / 3);
                    ctx.save();
                    ctx.globalAlpha = (1 - prog) * 0.65;
                    ctx.strokeStyle = '#77ddff';
                    ctx.lineWidth   = 2;
                    ctx.beginPath();
                    ctx.ellipse(sc.x, sc.y, Math.max(1, rx), Math.max(1, ry), 0, 0, Math.PI * 2);
                    ctx.stroke();
                    ctx.restore();
                } else {
                    const fadeFrac  = t.phase === 'fading'
                        ? Math.min(1, t.phaseTimer / (FADING_DUR.puddle ?? 1.0))
                        : 0;
                    const speedMult = 1 - fadeFrac * 0.6; // замедление ряби
                    const ringR     = ((now * 20 * speedMult + t.ripplePhase) % 20);
                    const alpha     = 0.35 * (1 - ringR / 20) * (1 - fadeFrac);
                    const rx        = (ringR / 20) * (TILE_W / 2);
                    const ry        = (ringR / 20) * (TILE_H / 2);
                    ctx.globalAlpha = alpha;
                    ctx.strokeStyle = '#77bbee';
                    ctx.lineWidth   = 1;
                    ctx.beginPath();
                    ctx.ellipse(sc.x, sc.y, Math.max(1, rx), Math.max(1, ry), 0, 0, Math.PI * 2);
                    ctx.stroke();
                    ctx.globalAlpha = 1;
                }
            }});
        }
    }

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
        } else if (obj.type === 'monkTotem') {
            const s = worldToScreen(monkTotem.ix, monkTotem.iy);
            const TOTEM_SCALE = 3;
            const tx = Math.round(s.x - (MONK_TOTEM_W * TOTEM_SCALE) / 2);
            const ty = Math.round(s.y - MONK_TOTEM_H * TOTEM_SCALE);
            drawPixelArt(tx, ty, MONK_TOTEM_PIXELS, TOTEM_SCALE);
        } else if (obj.type === 'fireball') {
            fireball.draw(hand);
        } else if (obj.type === 'spellProjectile') {
            spellProjectile.draw(hand);
        } else if (obj.type === 'hand') {
            if (hand.grabbedItem !== null) {
                items[hand.grabbedItem].draw(hand.grabbedItem, hand, hoveredItem);
            } else if (hand.grabbedMinion !== null) {
                minions[hand.grabbedMinion].draw(hand.grabbedMinion, hand, hoveredMinion);
            } else if (hand.grabbedSpell === 'fireball') {
                fireball.draw(hand);
            } else if (hand.grabbedSpell === 'water' || hand.grabbedSpell === 'earth' || hand.grabbedSpell === 'wind') {
                spellProjectile.draw(hand);
            }
            hand.draw();
        } else if (typeof obj.draw === 'function') {
            obj.draw();
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

    // Тайловые частицы — всплеск воды, взрыв ветра, пыль земли, кольцо ветра
    for (const p of tileParticles) {
        if (p.type === 'windRing') {
            const progress = 1 - p.life / p.maxLife;
            const alpha = (1 - progress) * 0.55;
            const rx = Math.max(1, progress * p.maxRx);
            const ry = Math.max(1, progress * p.maxRy);
            ctx.save();
            ctx.globalAlpha = alpha;
            ctx.strokeStyle = '#88ffaa';
            ctx.lineWidth = Math.max(1, 2 * (1 - progress));
            ctx.beginPath();
            ctx.ellipse(p.x, p.y, rx, ry, 0, 0, Math.PI * 2);
            ctx.stroke();
            ctx.restore();
        } else {
            const alpha = Math.pow(p.life / p.maxLife, 0.5) * 0.9;
            ctx.save();
            ctx.globalAlpha = alpha;
            ctx.fillStyle = p.color;
            ctx.fillRect(Math.round(p.x - p.size / 2), Math.round(p.y - p.size / 2), p.size, p.size);
            ctx.restore();
        }
    }

    // Частицы разрушения декораций
    for (const p of decoParticles) {
        const alpha = Math.pow(p.life / p.maxLife, 0.6) * 0.92;
        ctx.save();
        ctx.globalAlpha = alpha;
        ctx.fillStyle = p.color;
        ctx.fillRect(Math.round(p.x - p.size / 2), Math.round(p.y - p.size / 2), p.size, p.size);
        ctx.restore();
    }

    // ── МАРКЕРЫ КОМАНД ─────────────────────────────────────────
    for (const m of commandMarkers) {
        const s = worldToScreen(m.ix, m.iy);
        const progress = m.timer / m.maxTime;
        const alpha = (1 - progress) * 0.7;
        const pulse = 0.5 + 0.5 * Math.sin(performance.now() / 200);
        const color = m.type === 'attack' ? '#ff4444'
                    : m.type === 'gather' ? '#ffcc44'
                    : '#44ff88';
        const r = (8 + pulse * 4) * (1 - progress * 0.5);
        ctx.save();
        ctx.globalAlpha = alpha;
        ctx.strokeStyle = color;
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(s.x, s.y, r, 0, Math.PI * 2);
        ctx.stroke();
        ctx.globalAlpha = alpha * 0.25;
        ctx.fillStyle = color;
        ctx.fill();
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

            // Вспышка (рваная форма)
            if (expl.t < 0.15) {
                const flashAlpha = (1 - expl.t / 0.15) * 0.6;
                ctx.save();
                ctx.globalAlpha = flashAlpha;
                ctx.fillStyle = '#ffdd44';
                ctx.beginPath();
                const flashR = 40 + expl.t * 300;
                const FN = expl.flashPoints.length;
                for (let i = 0; i <= FN; i++) {
                    const angle = (i % FN) / FN * Math.PI * 2;
                    const r = expl.flashPoints[i % FN];
                    const x = es.x + Math.cos(angle) * flashR * r;
                    const y = es.y + Math.sin(angle) * flashR * 0.5 * r;
                    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
                }
                ctx.closePath();
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

            // Гарь на земле (рваные края)
            if (expl.t > 0.2) {
                ctx.save();
                ctx.globalAlpha = Math.min(0.3, (expl.t - 0.2) * 0.6) * (1 - expl.t / expl.duration);
                ctx.fillStyle = '#111100';
                const blastPxW = ARTILLERY_BLAST_RADIUS * (TILE_W / 2) * 0.8;
                const blastPxH = ARTILLERY_BLAST_RADIUS * (TILE_H / 2) * 0.8;
                ctx.beginPath();
                const SN = expl.scorchPoints.length;
                for (let i = 0; i <= SN; i++) {
                    const angle = (i % SN) / SN * Math.PI * 2;
                    const r = expl.scorchPoints[i % SN];
                    const x = es.x + Math.cos(angle) * blastPxW * r;
                    const y = es.y + Math.sin(angle) * blastPxH * r;
                    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
                }
                ctx.closePath();
                ctx.fill();
                ctx.restore();
            }
        }
    }

    ctx.restore();

    // Сбрасываем курсор в начале screen-space HUD (каждый блок ниже может включить pointer)
    canvas.style.cursor = 'none';

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

    // Подсчёт гоблинов для HUD — один проход вместо 5 отдельных filter()
    let _aliveCount = 0, _warriorCount = 0, _totalGoblins = 0, _scoutCount = 0, _monkCount = 0;
    for (const m of minions) {
        if (m.isUndead || m.dead) continue;
        _aliveCount++;
        _totalGoblins++;
        if (m.goblinClass === 'warrior') _warriorCount++;
        else if (m.goblinClass === 'scout') _scoutCount++;
        else if (m.goblinClass === 'monk') _monkCount++;
    }

    // HUD ресурсов — правый верхний угол (screen space)
    {
        const HUD_SCALE = 2;
        const HUD_MARGIN = 40;
        const HUD_ROW_H = 22;
        const maxW = _HUD_ITEM_MAX_W * HUD_SCALE;
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
        const maxW = _HUD_ITEM_MAX_W * HUD_SCALE;
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
        const aliveCount = _aliveCount;
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

        // Курсор — goblin-блок только включает pointer, сброс делается в начале render()
        if (isHovered) canvas.style.cursor = 'pointer';

        // Обновляем общий HUD-панель (resource + goblin) — будет расширен warrior-блоком ниже
        hudPanelRect.x = hudX - 8;
        hudPanelRect.y = HUD_MARGIN - 4;
        hudPanelRect.w = goblinHudRect.w;
        hudPanelRect.h = goblinHudRect.y + goblinHudRect.h - (HUD_MARGIN - 4);
    }

    // HUD производства воинов — под HUD гоблинов
    {
        const HUD_SCALE = 2;
        const HUD_MARGIN = 40;
        const maxW = _HUD_ITEM_MAX_W * HUD_SCALE;
        const hudX = canvas.width - HUD_MARGIN - maxW - 50;
        const blockW = maxW + 50;
        const barH = 8;
        const blockH = MINION_H * HUD_SCALE + barH + 20;

        const warY = goblinHudRect.y + goblinHudRect.h + 10;

        warriorHudRect.x = hudX - 8;
        warriorHudRect.y = warY - 4;
        warriorHudRect.w = blockW + 16;
        warriorHudRect.h = blockH + 8;

        const isHovered = mouseX >= warriorHudRect.x && mouseX <= warriorHudRect.x + warriorHudRect.w
            && mouseY >= warriorHudRect.y && mouseY <= warriorHudRect.y + warriorHudRect.h;

        // Фон
        ctx.save();
        ctx.globalAlpha = isHovered ? 0.80 : 0.55;
        ctx.fillStyle = isHovered ? '#1a1520' : '#0a0a18';
        ctx.fillRect(warriorHudRect.x, warriorHudRect.y, warriorHudRect.w, warriorHudRect.h);
        ctx.restore();

        // Рамка
        ctx.save();
        ctx.strokeStyle = isHovered ? '#ccaa44' : '#443322';
        ctx.lineWidth = 1;
        ctx.strokeRect(warriorHudRect.x + 0.5, warriorHudRect.y + 0.5, warriorHudRect.w - 1, warriorHudRect.h - 1);
        ctx.restore();

        // Иконка воина (гоблин + шлем)
        drawPixelArt(hudX, warY, MINION_PIXELS, HUD_SCALE);
        const helmetOx = Math.round(hudX + (MINION_W - WARRIOR_HELMET_W) / 2 * HUD_SCALE);
        drawPixelArt(helmetOx, warY, WARRIOR_HELMET_PIXELS, HUD_SCALE);

        // Счётчик: воины в строю / всего гоблинов
        const warriorCount = _warriorCount;
        const totalGoblins = _totalGoblins;
        ctx.fillStyle = '#ffffff';
        ctx.font = '12px monospace';
        ctx.textAlign = 'left';
        ctx.fillText(`${warriorCount} / ${totalGoblins}`, hudX + MINION_W * HUD_SCALE + 6, warY + 12);

        // Прогресс-бар следующего апгрейда
        const barY = warY + MINION_H * HUD_SCALE + 4;
        ctx.fillStyle = '#221c0a';
        ctx.fillRect(hudX, barY, blockW, barH);
        if (warriorProduction.active && castleResources[3] >= WARRIOR_IRON_COST) {
            const progress = 1 - (warriorUpgradeTimer / WARRIOR_UPGRADE_INTERVAL);
            ctx.fillStyle = '#cc9922';
            ctx.fillRect(hudX, barY, blockW * Math.max(0, Math.min(1, progress)), barH);
        }

        // Кнопка запуска/остановки
        ctx.fillStyle = warriorProduction.active ? '#88ff88' : '#ffaa44';
        ctx.font = '11px monospace';
        ctx.textAlign = 'left';
        ctx.fillText(warriorProduction.active ? '⏸ Остановить' : '▶ Запустить', hudX, barY + barH + 12);

        // Курсор: если warrior-панель под мышью — pointer (goblin-блок мог поставить none)
        if (isHovered) canvas.style.cursor = 'pointer';

        // Обновляем общий HUD-панель (scout-блок ниже дополнит)
        hudPanelRect.h = warriorHudRect.y + warriorHudRect.h - (HUD_MARGIN - 4);
    }

    // HUD производства разведчиков — под HUD воинов
    {
        const HUD_SCALE = 2;
        const HUD_MARGIN = 40;
        const maxW = _HUD_ITEM_MAX_W * HUD_SCALE;
        const hudX = canvas.width - HUD_MARGIN - maxW - 50;
        const blockW = maxW + 50;
        const barH = 8;
        const blockH = MINION_H * HUD_SCALE + barH + 20;

        const scoutY = warriorHudRect.y + warriorHudRect.h + 10;

        scoutHudRect.x = hudX - 8;
        scoutHudRect.y = scoutY - 4;
        scoutHudRect.w = blockW + 16;
        scoutHudRect.h = blockH + 8;

        const isHovered = mouseX >= scoutHudRect.x && mouseX <= scoutHudRect.x + scoutHudRect.w
            && mouseY >= scoutHudRect.y && mouseY <= scoutHudRect.y + scoutHudRect.h;

        // Фон
        ctx.save();
        ctx.globalAlpha = isHovered ? 0.80 : 0.55;
        ctx.fillStyle = isHovered ? '#0f1a12' : '#0a0a18';
        ctx.fillRect(scoutHudRect.x, scoutHudRect.y, scoutHudRect.w, scoutHudRect.h);
        ctx.restore();

        // Рамка
        ctx.save();
        ctx.strokeStyle = isHovered ? '#44cc66' : '#224433';
        ctx.lineWidth = 1;
        ctx.strokeRect(scoutHudRect.x + 0.5, scoutHudRect.y + 0.5, scoutHudRect.w - 1, scoutHudRect.h - 1);
        ctx.restore();

        // Иконка разведчика (гоблин + капюшон)
        drawPixelArt(hudX, scoutY, MINION_PIXELS, HUD_SCALE);
        const hoodOx = Math.round(hudX + (MINION_W - SCOUT_HOOD_W) / 2 * HUD_SCALE);
        drawPixelArt(hoodOx, scoutY, SCOUT_HOOD_PIXELS, HUD_SCALE);

        // Счётчик: живые разведчики / макс
        const scoutCount = _scoutCount;
        ctx.fillStyle = '#ffffff';
        ctx.font = '12px monospace';
        ctx.textAlign = 'left';
        ctx.fillText(`${scoutCount} / ${SCOUT_MAX_COUNT}`, hudX + MINION_W * HUD_SCALE + 6, scoutY + 12);

        // Прогресс-бар следующего разведчика
        const barY = scoutY + MINION_H * HUD_SCALE + 4;
        ctx.fillStyle = '#0a1a0e';
        ctx.fillRect(hudX, barY, blockW, barH);
        const canProduce = castleResources[2] >= SCOUT_WOOD_COST && castleResources[0] >= SCOUT_FOOD_COST && scoutCount < SCOUT_MAX_COUNT;
        if (scoutProduction.active && canProduce) {
            const progress = 1 - (scoutUpgradeTimer / SCOUT_UPGRADE_INTERVAL);
            ctx.fillStyle = '#33cc66';
            ctx.fillRect(hudX, barY, blockW * Math.max(0, Math.min(1, progress)), barH);
        }

        // Кнопка запуска/остановки
        ctx.fillStyle = scoutProduction.active ? '#88ff88' : '#ffaa44';
        ctx.font = '11px monospace';
        ctx.textAlign = 'left';
        ctx.fillText(scoutProduction.active ? '⏸ Остановить' : '▶ Запустить', hudX, barY + barH + 12);

        if (isHovered) canvas.style.cursor = 'pointer';

        // Обновляем общий HUD-панель, включая scout-блок
        hudPanelRect.h = scoutHudRect.y + scoutHudRect.h - (HUD_MARGIN - 4);
    }

    // HUD производства монахов — под HUD разведчиков
    {
        const HUD_SCALE = 2;
        const HUD_MARGIN = 40;
        const maxW = _HUD_ITEM_MAX_W * HUD_SCALE;
        const hudX = canvas.width - HUD_MARGIN - maxW - 50;
        const blockW = maxW + 50;
        const barH = 8;
        const blockH = MINION_H * HUD_SCALE + barH + 20;

        const monkY = scoutHudRect.y + scoutHudRect.h + 10;

        monkHudRect.x = hudX - 8;
        monkHudRect.y = monkY - 4;
        monkHudRect.w = blockW + 16;
        monkHudRect.h = blockH + 8;

        const isHovered = mouseX >= monkHudRect.x && mouseX <= monkHudRect.x + monkHudRect.w
            && mouseY >= monkHudRect.y && mouseY <= monkHudRect.y + monkHudRect.h;

        // Фон
        ctx.save();
        ctx.globalAlpha = isHovered ? 0.80 : 0.55;
        ctx.fillStyle = isHovered ? '#1a1208' : '#100e06';
        ctx.fillRect(monkHudRect.x, monkHudRect.y, monkHudRect.w, monkHudRect.h);
        ctx.restore();

        // Рамка
        ctx.save();
        ctx.strokeStyle = isHovered ? '#cc8844' : '#443322';
        ctx.lineWidth = 1;
        ctx.strokeRect(monkHudRect.x + 0.5, monkHudRect.y + 0.5, monkHudRect.w - 1, monkHudRect.h - 1);
        ctx.restore();

        // Иконка монаха (гоблин + балахон)
        drawPixelArt(hudX, monkY, MINION_PIXELS, HUD_SCALE);
        const robeOx = Math.round(hudX + (MINION_W - MONK_ROBE_W) / 2 * HUD_SCALE);
        drawPixelArt(robeOx, monkY, MONK_ROBE_PIXELS, HUD_SCALE);

        // Счётчик: живые монахи / макс
        const monkCount = _monkCount;
        ctx.fillStyle = '#ffffff';
        ctx.font = '12px monospace';
        ctx.textAlign = 'left';
        ctx.fillText(`${monkCount} / ${MONK_MAX_COUNT}`, hudX + MINION_W * HUD_SCALE + 6, monkY + 12);

        // Прогресс-бар следующего монаха
        const barY = monkY + MINION_H * HUD_SCALE + 4;
        ctx.fillStyle = '#1a1008';
        ctx.fillRect(hudX, barY, blockW, barH);
        const canProduce = castleResources[0] >= MONK_FOOD_COST && monkCount < MONK_MAX_COUNT;
        if (monkProduction.active && canProduce) {
            const progress = 1 - (monkUpgradeTimer / MONK_UPGRADE_INTERVAL);
            ctx.fillStyle = '#cc8844';
            ctx.fillRect(hudX, barY, blockW * Math.max(0, Math.min(1, progress)), barH);
        }

        // Кнопка запуска/остановки
        ctx.fillStyle = monkProduction.active ? '#ffcc88' : '#ffaa44';
        ctx.font = '11px monospace';
        ctx.textAlign = 'left';
        ctx.fillText(monkProduction.active ? '⏸ Остановить' : '▶ Запустить', hudX, barY + barH + 12);

        if (isHovered) canvas.style.cursor = 'pointer';

        hudPanelRect.h = monkHudRect.y + monkHudRect.h - (HUD_MARGIN - 4);
    }

    // ── ПАНЕЛЬ ЗАКЛИНАНИЙ — левая сторона (4 слота) ────────────
    {
        const HUD_MARGIN = 40;
        const SLOT_SIZE = 42;
        const SLOT_GAP = 4;
        const COLS = 2, ROWS = 2;
        const PANEL_W = COLS * SLOT_SIZE + (COLS - 1) * SLOT_GAP + 16;
        const PANEL_H = ROWS * SLOT_SIZE + (ROWS - 1) * SLOT_GAP + 30;
        const panelX = HUD_MARGIN;
        const panelY = HUD_MARGIN;

        spellPanelRect.x = panelX - 4;
        spellPanelRect.y = panelY - 4;
        spellPanelRect.w = PANEL_W + 8;
        spellPanelRect.h = PANEL_H + 8;

        const isHov = mouseX >= spellPanelRect.x && mouseX <= spellPanelRect.x + spellPanelRect.w
            && mouseY >= spellPanelRect.y && mouseY <= spellPanelRect.y + spellPanelRect.h;

        // Фон панели
        ctx.save();
        ctx.globalAlpha = isHov ? 0.82 : 0.58;
        ctx.fillStyle = '#120808';
        ctx.fillRect(spellPanelRect.x, spellPanelRect.y, spellPanelRect.w, spellPanelRect.h);
        ctx.globalAlpha = 1;
        ctx.strokeStyle = isHov ? '#886633' : '#441100';
        ctx.lineWidth = 1;
        ctx.strokeRect(spellPanelRect.x + 0.5, spellPanelRect.y + 0.5, spellPanelRect.w - 1, spellPanelRect.h - 1);
        ctx.restore();

        // Заголовок
        ctx.fillStyle = '#cc8844';
        ctx.font = '9px monospace';
        ctx.textAlign = 'center';
        ctx.fillText('Магия', panelX + PANEL_W / 2, panelY + 11);

        // Определения 4 слотов: [key, label, pixels, sprW, sprH, glowColor, readyBg, manaCost, cooldownMax, getReady, getCooldown]
        const spellSlots = [
            {
                key: 'fire', label: 'Огонь', pixels: FIREBALL_PIXELS, sprW: FIREBALL_W, sprH: FIREBALL_H,
                glow: '#ff6600', readyBg: '#2a1000', borderReady: '#883300', borderHov: '#ff6600',
                cost: MANA_FIREBALL_COST, cdMax: FIREBALL_COOLDOWN,
                isReady: () => fireball.state === 'ready',
                isActive: () => fireball.state !== 'ready' && fireball.state !== 'done',
                getCd: () => fireball.cooldown,
            },
            {
                key: 'water', label: 'Вода', pixels: WATER_SPELL_PIXELS, sprW: WATER_SPELL_W, sprH: WATER_SPELL_H,
                glow: '#4488ff', readyBg: '#001a2a', borderReady: '#224488', borderHov: '#4488ff',
                cost: MANA_WATER_COST, cdMax: WATER_SPELL_COOLDOWN,
                isReady: () => spellStates.water.cooldown <= 0,
                isActive: () => false,
                getCd: () => spellStates.water.cooldown,
            },
            {
                key: 'earth', label: 'Земля', pixels: EARTH_SPELL_PIXELS, sprW: EARTH_SPELL_W, sprH: EARTH_SPELL_H,
                glow: '#aa8855', readyBg: '#1a1200', borderReady: '#665533', borderHov: '#aa8855',
                cost: MANA_EARTH_COST, cdMax: EARTH_SPELL_COOLDOWN,
                isReady: () => spellStates.earth.cooldown <= 0,
                isActive: () => false,
                getCd: () => spellStates.earth.cooldown,
            },
            {
                key: 'wind', label: 'Ветер', pixels: WIND_SPELL_PIXELS, sprW: WIND_SPELL_W, sprH: WIND_SPELL_H,
                glow: '#88cc88', readyBg: '#0a1a0a', borderReady: '#446644', borderHov: '#88cc88',
                cost: MANA_WIND_COST, cdMax: WIND_SPELL_COOLDOWN,
                isReady: () => spellStates.wind.cooldown <= 0,
                isActive: () => false,
                getCd: () => spellStates.wind.cooldown,
            },
        ];

        const ICON_SCALE = 3;
        const slotsStartX = panelX + (PANEL_W - COLS * SLOT_SIZE - (COLS - 1) * SLOT_GAP) / 2;
        const slotsStartY = panelY + 16;

        for (let si = 0; si < spellSlots.length; si++) {
            const slot = spellSlots[si];
            const col = si % COLS;
            const row = Math.floor(si / COLS);
            const slotX = slotsStartX + col * (SLOT_SIZE + SLOT_GAP);
            const slotY = slotsStartY + row * (SLOT_SIZE + SLOT_GAP);

            const ready = slot.isReady();
            const active = slot.isActive();
            const cd = slot.getCd();
            const onCooldown = cd > 0 && !active;
            const hasEnoughMana = manaPool.value >= slot.cost;

            // Проверяем наведение на конкретный слот
            const slotHov = mouseX >= slotX && mouseX <= slotX + SLOT_SIZE
                && mouseY >= slotY && mouseY <= slotY + SLOT_SIZE;

            // Фон слота
            ctx.save();
            ctx.globalAlpha = 0.5;
            ctx.fillStyle = ready ? slot.readyBg : '#0d0d0d';
            ctx.fillRect(slotX, slotY, SLOT_SIZE, SLOT_SIZE);
            ctx.strokeStyle = ready ? (slotHov ? slot.borderHov : slot.borderReady) : '#221100';
            ctx.lineWidth = ready && slotHov ? 2 : 1;
            ctx.strokeRect(slotX + 0.5, slotY + 0.5, SLOT_SIZE - 1, SLOT_SIZE - 1);
            ctx.restore();

            // Спрайт
            const iconX = Math.round(slotX + (SLOT_SIZE - slot.sprW * ICON_SCALE) / 2);
            const iconY = Math.round(slotY + (SLOT_SIZE - slot.sprH * ICON_SCALE) / 2) - 4;
            if (ready && hasEnoughMana) {
                ctx.save();
                ctx.shadowColor = slot.glow;
                ctx.shadowBlur = 8;
                drawPixelArt(iconX, iconY, slot.pixels, ICON_SCALE);
                ctx.restore();
            } else {
                ctx.save();
                ctx.globalAlpha = 0.3;
                drawPixelArt(iconX, iconY, slot.pixels, ICON_SCALE);
                ctx.restore();
            }

            // Оверлей перезарядки
            if (onCooldown) {
                const cdFraction = cd / slot.cdMax;
                ctx.save();
                ctx.globalAlpha = cdFraction * 0.55;
                ctx.fillStyle = '#000000';
                ctx.fillRect(slotX, slotY, SLOT_SIZE, SLOT_SIZE);
                ctx.restore();
                ctx.fillStyle = '#ffaa44';
                ctx.font = 'bold 10px monospace';
                ctx.textAlign = 'center';
                ctx.fillText(Math.ceil(cd) + 'с', slotX + SLOT_SIZE / 2, slotY + SLOT_SIZE / 2 + 3);
            }

            // Оверлей «мало маны»
            if (ready && !hasEnoughMana && !onCooldown) {
                ctx.save();
                ctx.globalAlpha = 0.5;
                ctx.fillStyle = '#000044';
                ctx.fillRect(slotX, slotY, SLOT_SIZE, SLOT_SIZE);
                ctx.restore();
                ctx.fillStyle = '#6688ff';
                ctx.font = 'bold 8px monospace';
                ctx.textAlign = 'center';
                ctx.fillText('мана', slotX + SLOT_SIZE / 2, slotY + SLOT_SIZE / 2 + 3);
            }

            // Подпись
            ctx.fillStyle = ready ? '#ccaa66' : '#554433';
            ctx.font = '8px monospace';
            ctx.textAlign = 'center';
            ctx.fillText(slot.label, slotX + SLOT_SIZE / 2, slotY + SLOT_SIZE + 9);

            // Курсор
            if (ready && hasEnoughMana && slotHov) canvas.style.cursor = 'pointer';

            // Запоминаем rect для клика (используем spellSlotRects[si])
            spellSlotRects[si] = { x: slotX, y: slotY, w: SLOT_SIZE, h: SLOT_SIZE, key: slot.key, cost: slot.cost };
        }
    }

    // ── ПОЛОСА МАНЫ — справа от панели заклинаний ─────────────
    {
        const barX = spellPanelRect.x + spellPanelRect.w + 4;
        const barY = spellPanelRect.y;
        const barW = 12;
        const barH = spellPanelRect.h;
        const manaFrac = manaPool.value / MANA_MAX;
        const fillH = Math.round(barH * manaFrac);

        // Фон
        ctx.save();
        ctx.globalAlpha = 0.65;
        ctx.fillStyle = '#08081a';
        ctx.fillRect(barX, barY, barW, barH);
        ctx.globalAlpha = 1;
        // Заполнение снизу вверх
        if (fillH > 0) {
            const grad = ctx.createLinearGradient(barX, barY + barH, barX, barY);
            grad.addColorStop(0, '#1a33bb');
            grad.addColorStop(1, '#7799ff');
            ctx.fillStyle = grad;
            ctx.fillRect(barX, barY + barH - fillH, barW, fillH);
        }
        // Граница
        ctx.globalAlpha = 1;
        ctx.strokeStyle = '#223366';
        ctx.lineWidth = 1;
        ctx.strokeRect(barX + 0.5, barY + 0.5, barW - 1, barH - 1);
        ctx.restore();
        // Подпись «М» над баром
        ctx.fillStyle = '#5577ee';
        ctx.font = '8px monospace';
        ctx.textAlign = 'center';
        ctx.fillText('М', barX + barW / 2, barY - 3);
    }

    // ── ПАНЕЛЬ ВЫДЕЛЕНИЯ — нижний центр экрана ─────────────────
    drawSelectionBar();

    // Курсор-точка (вне зума и тряски — стабильный)
    ctx.fillStyle = '#ff4444';
    ctx.fillRect(mouseX - 1, mouseY - 1, 3, 3);

    // Индикатор зума
    if (Math.abs(camera.zoom - 1.0) > 0.01) {
        ctx.fillStyle = '#aab';
        ctx.font = '12px monospace';
        ctx.fillText(`Зум: ${Math.round(camera.zoom * 100)}%`, 16, canvas.height - 16);
    }

    // Seed display
    ctx.fillStyle = '#889';
    ctx.font = '10px monospace';
    ctx.textAlign = 'left';
    ctx.fillText(`Seed: ${gameMap.seed}  [R] restart  [N] new map`, 8, 14);
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
