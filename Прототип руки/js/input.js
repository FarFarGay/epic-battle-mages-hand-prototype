// ============================================================
//  ВВОД — все обработчики событий
// ============================================================
import {
    ITEM_TYPES, PIXEL_SCALE, GRAVITY,
    ARTILLERY_GRAB_RADIUS, ARTILLERY_FLIGHT_TIME_K,
    ARTILLERY_MIN_FLIGHT, ARTILLERY_MAX_FLIGHT,
    MONK_TOTEM_MIN_DIST, MONK_TOTEM_MAX_DIST,
} from './constants.js';
import { MINION_H } from './sprites.js';
import { screenToIso, worldToScreen, screenToCanvas } from './isometry.js';
import { restartMap, items, minions, castle, artilleryMode, triggerScreenShake, fireball, spellProjectile, monkTotem, commandMarkers, debugFlags } from './World.js';
import { applySpellToTile } from './tileEffects.js';
import { gameMap } from './Map.js';

const RMB_DRAG_THRESHOLD = 5;

let rmbStart = null; // { x, y } — начало ПКМ нажатия

// ── Вспомогательные функции ────────────────────────────────

function findEnemyAt(ix, iy) {
    const RADIUS = 1.5;
    const rSq = RADIUS * RADIUS;
    for (const m of minions) {
        if (!m.isUndead || m.state !== 'skeleton') continue;
        const dx = m.ix - ix;
        const dy = m.iy - iy;
        if (dx * dx + dy * dy <= rSq) return m;
    }
    return null;
}

function findResourceAt(ix, iy) {
    const RADIUS = 1.5;
    let nearest = null, nearestDistSq = RADIUS * RADIUS;
    for (const item of items) {
        if (!item.typeDef.gatherable) continue;
        if (item.state === 'carried' || item.state === 'lifting' || item.state === 'goblin_carried') continue;
        const dx = item.ix - ix;
        const dy = item.iy - iy;
        const dSq = dx * dx + dy * dy;
        if (dSq < nearestDistSq) { nearestDistSq = dSq; nearest = item; }
    }
    return nearest;
}

// Ищет до count ближайших миньонов к точке (ix, iy), удовлетворяющих фильтру
function findNearestMinions(ix, iy, count, filter) {
    const candidates = [];
    for (let i = 0; i < minions.length; i++) {
        const m = minions[i];
        if (!filter(m)) continue;
        const dx = m.ix - ix;
        const dy = m.iy - iy;
        candidates.push({ idx: i, distSq: dx * dx + dy * dy });
    }
    candidates.sort((a, b) => a.distSq - b.distSq);
    return candidates.slice(0, count).map(c => c.idx);
}

function handleRMBCommand(ix, iy, hand, statusEl) {
    const SELECTABLE = ['free', 'moving_to_point', 'busy', 'returning', 'war', 'fighting',
                        'guarding', 'warrior_returning', 'monk_walking', 'monk_praying'];

    const enemy = findEnemyAt(ix, iy);
    const resource = enemy ? null : findResourceAt(ix, iy);

    let targetIdxs = hand.selectedMinions.slice();

    if (targetIdxs.length === 0) {
        // Нет выделения — берём 2-3 ближайших подходящих гоблина
        if (enemy) {
            targetIdxs = findNearestMinions(ix, iy, 3,
                m => !m.isUndead && !m.dead && SELECTABLE.includes(m.state) && m.goblinClass !== 'warrior');
        } else if (resource) {
            targetIdxs = findNearestMinions(ix, iy, 3,
                m => !m.isUndead && !m.dead && SELECTABLE.includes(m.state) && m.goblinClass === 'basic');
        } else {
            targetIdxs = findNearestMinions(ix, iy, 2,
                m => !m.isUndead && !m.dead && SELECTABLE.includes(m.state));
        }
    }

    if (targetIdxs.length === 0) return;

    if (enemy) {
        // Атаковать врага
        for (const idx of targetIdxs) {
            const m = minions[idx];
            if (!m || m.isUndead || m.dead) continue;
            m.enterCombat(enemy);
        }
        commandMarkers.push({ ix, iy, timer: 0, maxTime: 3, type: 'attack' });
        statusEl.textContent = `${targetIdxs.length} гоблин(а) атакуют!`;

    } else if (resource) {
        // Добывать ресурс
        let count = 0;
        for (const idx of targetIdxs) {
            const m = minions[idx];
            if (!m || m.isUndead || m.dead) continue;
            if (m.goblinClass === 'warrior') { m.state = 'warrior_returning'; m.stateTime = 0; continue; }
            if (m.goblinClass === 'scout')   { m.pickNewTarget(); m.state = 'free'; m.stateTime = 0; continue; }
            if (m.goblinClass === 'monk')    { m.state = 'monk_walking'; m.stateTime = 0; continue; }
            if (m.assignGatherTask(items)) count++;
        }
        commandMarkers.push({ ix, iy, timer: 0, maxTime: 3, type: 'gather' });
        statusEl.textContent = count > 0 ? `${count} гоблин(а) начинают добычу!` : 'Нет доступных ресурсов';

    } else {
        // Идти к точке: монахи — тотем, воины — кольцо, остальные — move_to_point
        const monkIdxs = targetIdxs.filter(idx => minions[idx].goblinClass === 'monk');
        if (monkIdxs.length > 0) {
            const dx = ix - castle.ix, dy = iy - castle.iy;
            const dist = Math.sqrt(dx * dx + dy * dy);
            const clampedDist = Math.max(MONK_TOTEM_MIN_DIST, Math.min(MONK_TOTEM_MAX_DIST, dist));
            const angle = dist > 0.01 ? Math.atan2(dy, dx) : 0;
            monkTotem.ix = castle.ix + Math.cos(angle) * clampedDist;
            monkTotem.iy = castle.iy + Math.sin(angle) * clampedDist;
            monkTotem.active = true;
            for (const m of minions) {
                if (m.goblinClass === 'monk' && !m.dead && !m.isUndead) {
                    m.totemX = monkTotem.ix;
                    m.totemY = monkTotem.iy;
                    m.state = 'monk_walking';
                    m.stateTime = 0;
                }
            }
        }

        const warriorIdxs = targetIdxs.filter(idx => minions[idx].goblinClass === 'warrior');
        const Nw = warriorIdxs.length;
        const warRadius = Nw <= 1 ? 0 : Math.max(5, Nw * 10 / (2 * Math.PI));
        warriorIdxs.forEach((idx, i) => {
            const m = minions[idx];
            const angle = (2 * Math.PI * i / Math.max(1, Nw));
            m.guardX = ix + (Nw > 1 ? warRadius * Math.cos(angle) : 0);
            m.guardY = iy + (Nw > 1 ? warRadius * Math.sin(angle) : 0);
            m.state = 'warrior_returning';
            m.stateTime = 0;
        });

        for (const idx of targetIdxs) {
            const m = minions[idx];
            if (!m || m.isUndead || m.dead) continue;
            if (m.goblinClass === 'warrior' || m.goblinClass === 'monk') continue;
            m.targetX = ix;
            m.targetY = iy;
            m.state = 'moving_to_point';
            m.stateTime = 0;
        }

        commandMarkers.push({ ix, iy, timer: 0, maxTime: 3, type: 'move' });
        statusEl.textContent = monkIdxs.length > 0
            ? 'Тотем перемещён'
            : Nw > 0
                ? 'Воины идут в строй'
                : `${targetIdxs.length} гоблин(а) идут к точке`;
    }
}

function finishLassoSelection(selection, hand, statusEl) {
    selection.active = false;
    const selW = Math.abs(selection.endX - selection.startX);
    const selH = Math.abs(selection.endY - selection.startY);
    if (selW <= 5 && selH <= 5) return;

    const SELECTABLE = ['free', 'moving_to_point', 'busy', 'returning', 'war', 'fighting',
                        'guarding', 'warrior_returning', 'monk_walking', 'monk_praying'];
    const tl = screenToCanvas(
        Math.min(selection.startX, selection.endX),
        Math.min(selection.startY, selection.endY)
    );
    const br = screenToCanvas(
        Math.max(selection.startX, selection.endX),
        Math.max(selection.startY, selection.endY)
    );
    hand.selectedMinions = [];
    for (let i = 0; i < minions.length; i++) {
        const m = minions[i];
        if (!SELECTABLE.includes(m.state)) continue;
        if (m.isUndead) continue;
        const s = worldToScreen(m.ix, m.iy);
        const mx = s.x;
        const my = s.y - (MINION_H * PIXEL_SCALE) / 2;
        if (mx >= tl.x && mx <= br.x && my >= tl.y && my <= br.y) {
            hand.selectedMinions.push(i);
        }
    }
    if (hand.selectedMinions.length > 0) {
        statusEl.textContent = `Выделено ${hand.selectedMinions.length} миньон(а) — ПКМ для команды`;
    }
}

export function initInput(canvas, hand, world, cam, statusEl) {
    const { selection } = world;

    canvas.addEventListener('mousemove', (e) => {
        world.mouseX = e.clientX;
        world.mouseY = e.clientY;
        if (selection.active) {
            selection.endX = world.mouseX;
            selection.endY = world.mouseY;
        }
    });

    // Подавляем контекстное меню ПКМ
    canvas.addEventListener('contextmenu', (e) => e.preventDefault());

    canvas.addEventListener('mousedown', (e) => {
        // ── ПКМ нажатие: начало RMB (клик или лассо) ─────────────
        if (e.button === 2) {
            rmbStart = { x: e.clientX, y: e.clientY };
            selection.active = true;
            selection.startX = e.clientX;
            selection.startY = e.clientY;
            selection.endX = e.clientX;
            selection.endY = e.clientY;
            return;
        }

        if (e.button !== 0) return;
        world.mouseDown = true;

        // ── Артиллерия: выстрел ──────────────────────────────────
        if (artilleryMode.active && artilleryMode.state === 'aiming') {
            const iso = screenToIso(world.mouseX, world.mouseY, canvas);
            artilleryMode.targetX = iso.x;
            artilleryMode.targetY = iso.y;

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
            proj.vz = 0.5 * GRAVITY * T;

            artilleryMode.flightDuration = T;
            artilleryMode.timer = 0;
            artilleryMode.state = 'flying';

            castle.fireCannon();
            triggerScreenShake(5);
            statusEl.textContent = 'Огонь!';
            return;
        }

        if (artilleryMode.active) return;

        const handFree = hand.grabbedItem === null && hand.grabbedMinion === null;

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

        if (world.hoveredItem !== null && handFree) {
            const item = items[world.hoveredItem];
            if (item.state !== 'carried' && item.state !== 'lifting') {
                hand.grabbedItem = world.hoveredItem;
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
                minion.dropCarriedItem();
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
        }
    });

    canvas.addEventListener('mouseup', (e) => {
        // ── ПКМ отпущена ─────────────────────────────────────────
        if (e.button === 2) {
            if (!rmbStart) return;
            const dx = e.clientX - rmbStart.x;
            const dy = e.clientY - rmbStart.y;
            const dragDist = Math.sqrt(dx * dx + dy * dy);
            rmbStart = null;

            if (dragDist < RMB_DRAG_THRESHOLD) {
                // Клик — команда
                selection.active = false;
                const iso = screenToIso(e.clientX, e.clientY, canvas);
                handleRMBCommand(iso.x, iso.y, hand, statusEl);
            } else {
                // Перетаскивание — лассо-выделение
                finishLassoSelection(selection, hand, statusEl);
            }
            return;
        }

        if (e.button !== 0) return;
        world.mouseDown = false;
        if (artilleryMode.active) return;

        // Бросок огненного шара
        if (hand.grabbedSpell === 'fireball') {
            const throwVel = hand.calculateThrowVelocity({ mass: fireball.mass });
            fireball.iz = 0;
            fireball.vx = throwVel.vx;
            fireball.vy = throwVel.vy;
            fireball.vz = throwVel.vz;
            fireball.state = 'thrown';
            fireball.stateTime = 0;
            fireball.bounceCount = 0;
            fireball.pendingExplosion = false;
            fireball._exploded = false;
            hand.grabbedSpell = null;
            hand.state = 'opening';
            hand.animProgress = 0;
            hand.velocityHistory = [];
            statusEl.textContent = 'Огненный шар!';
            return;
        }

        // Бросок заклинания (water/earth/wind) — физика как у фаербола
        if (hand.grabbedSpell === 'water' || hand.grabbedSpell === 'earth' || hand.grabbedSpell === 'wind') {
            const throwVel = hand.calculateThrowVelocity({ mass: spellProjectile.mass });
            spellProjectile.iz = 0;
            spellProjectile.vx = throwVel.vx;
            spellProjectile.vy = throwVel.vy;
            spellProjectile.vz = throwVel.vz;
            spellProjectile.state = 'thrown';
            spellProjectile.stateTime = 0;
            spellProjectile.bounceCount = 0;
            spellProjectile.pendingExplosion = false;
            spellProjectile._exploded = false;
            hand.grabbedSpell = null;
            hand.state = 'opening';
            hand.animProgress = 0;
            hand.velocityHistory = [];
            const spellNames = { water: 'Водный поток!', earth: 'Каменная стена!', wind: 'Порыв ветра!' };
            statusEl.textContent = spellNames[spellProjectile.spellType] ?? 'Заклинание!';
            return;
        }

        if (hand.grabbedItem !== null) {
            const item = items[hand.grabbedItem];
            const type = item.typeDef;

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
            statusEl.textContent = speed > 2 ? `Брошено: ${type.name}!` : `Отпущено: ${type.name}`;

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
        }
    });

    // Зум камеры: Z — отдалить, X — приблизить, C — сброс; R — рестарт
    window.addEventListener('keydown', (e) => {
        if (document.activeElement && document.activeElement.tagName === 'INPUT') return;

        if ((e.key === 'q' || e.key === 'й') && artilleryMode.active) {
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
        } else if (e.key === 'r' || e.key === 'к') {
            restartMap(hand, statusEl);
            world.hoveredItem = null;
            world.hoveredMinion = null;
            selection.active = false;
            cam.zoom = 1.0;
            cam.targetZoom = 1.0;
        } else if (e.key === 'n' || e.key === 'т') {
            gameMap.seed = Math.floor(Math.random() * 1_000_000);
            restartMap(hand, statusEl);
            world.hoveredItem = null;
            world.hoveredMinion = null;
            selection.active = false;
            cam.zoom = 1.0;
            cam.targetZoom = 1.0;
            statusEl.textContent = `Новая карта! Seed: ${gameMap.seed}`;
        } else if (e.key === 'p' || e.key === 'з') {
            debugFlags.fogDisabled = !debugFlags.fogDisabled;
            statusEl.textContent = debugFlags.fogDisabled ? '[debug] Туман войны отключён' : '[debug] Туман войны включён';
        }

        // ── Дебаг: F1–F4 — применить стихию к тайлу под курсором ──
        const debugSpells = { F1: 'fire', F2: 'water', F3: 'earth', F4: 'wind' };
        if (debugSpells[e.key]) {
            const iso = screenToIso(world.mouseX, world.mouseY, canvas);
            const tix = Math.round(iso.x), tiy = Math.round(iso.y);
            const result = applySpellToTile(debugSpells[e.key], tix, tiy);
            statusEl.textContent = result
                ? `[debug] ${debugSpells[e.key]} → (${tix},${tiy}) = ${result}`
                : `[debug] ${debugSpells[e.key]} → (${tix},${tiy}) — нет эффекта`;
        }
    });
}
