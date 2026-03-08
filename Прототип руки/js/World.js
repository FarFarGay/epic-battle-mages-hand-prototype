// ============================================================
//  МИР — предметы, миньоны, флаг, тряска экрана
// ============================================================
import { INITIAL_POSITIONS, INITIAL_MINION_POSITIONS } from './constants.js';
import { Item } from './Item.js';
import { Minion } from './Minion.js';
import { Castle } from './Castle.js';

// ============================================================
//  СОСТОЯНИЕ МИРА
// ============================================================
export const items = [];
export const minions = [];

export const flag = {
    state: 'docked', // 'docked' | 'carried' | 'placed'
    ix: 0, iy: 0, iz: 0,
};

export const screenShake = {
    intensity: 0,
    offsetX: 0,
    offsetY: 0,
};

export const bloodParticles = [];  // { x, y, vx, vy, life, maxLife, size }
export const bloodPuddles   = [];  // { ix, iy, size, t, duration }

export let castle = null;

// ============================================================
//  ТРЯСКА ЭКРАНА
// ============================================================
export function triggerScreenShake(intensity) {
    screenShake.intensity = Math.min(intensity, 15);
}

export function updateScreenShake(dt) {
    if (screenShake.intensity > 0.1) {
        screenShake.offsetX = (Math.random() - 0.5) * screenShake.intensity * 2;
        screenShake.offsetY = (Math.random() - 0.5) * screenShake.intensity * 2;
        screenShake.intensity *= Math.pow(0.01, dt);
    } else {
        screenShake.intensity = 0;
        screenShake.offsetX = 0;
        screenShake.offsetY = 0;
    }
}

// ============================================================
//  КОЛЛИЗИИ МЕЖДУ ПРЕДМЕТАМИ
// ============================================================
export function resolveItemCollisions() {
    for (let i = 0; i < items.length; i++) {
        for (let j = i + 1; j < items.length; j++) {
            const a = items[i];
            const b = items[j];

            // Предметы в руке не участвуют в коллизиях
            if (a.state === 'carried' || a.state === 'lifting') continue;
            if (b.state === 'carried' || b.state === 'lifting') continue;

            const typeA = a.typeDef;
            const typeB = b.typeDef;
            const minDist = typeA.radius + typeB.radius;

            // Проверяем высоту — сталкиваются только если на одном уровне
            if (Math.abs(a.iz - b.iz) > minDist * 0.5) continue;

            const dx = b.ix - a.ix;
            const dy = b.iy - a.iy;
            const dist = Math.sqrt(dx * dx + dy * dy);

            if (dist >= minDist || dist < 0.0001) continue;

            // Нормаль столкновения
            const nx = dx / dist;
            const ny = dy / dist;

            // Раздвигаем предметы пропорционально массам
            const overlap = minDist - dist;
            const totalMass = typeA.mass + typeB.mass;
            a.ix -= nx * overlap * (typeB.mass / totalMass);
            a.iy -= ny * overlap * (typeB.mass / totalMass);
            b.ix += nx * overlap * (typeA.mass / totalMass);
            b.iy += ny * overlap * (typeA.mass / totalMass);

            // Импульс только если предметы сближаются
            const dvx = b.vx - a.vx;
            const dvy = b.vy - a.vy;
            const dot = dvx * nx + dvy * ny;
            if (dot >= 0) continue;

            const restitution = Math.min(typeA.bounciness, typeB.bounciness);
            const impulse = -(1 + restitution) * dot / totalMass;

            a.vx -= impulse * typeB.mass * nx;
            a.vy -= impulse * typeB.mass * ny;
            b.vx += impulse * typeA.mass * nx;
            b.vy += impulse * typeA.mass * ny;

            // Будим неподвижные предметы
            if (a.state === 'idle' || a.state === 'settling') {
                a.state = 'sliding';
                a.stateTime = 0;
            }
            if (b.state === 'idle' || b.state === 'settling') {
                b.state = 'sliding';
                b.stateTime = 0;
            }

            // Тряска экрана при сильном ударе тяжёлых предметов
            const impactSpeed = Math.abs(dot);
            if (impactSpeed > 2.0) {
                triggerScreenShake(Math.min(typeA.mass, typeB.mass) * impactSpeed * 0.2);
            }
        }
    }
}

// ============================================================
//  КОЛЛИЗИИ С ЗАМКОМ
// ============================================================
export function resolveCastleCollisions() {
    if (!castle) return;
    castle.pushObjects(items);
    castle.pushObjects(minions);
}

// ============================================================
//  РЕСТАРТ КАРТЫ
// ============================================================
export function restartMap(hand, statusEl) {
    // Сброс предметов на начальные позиции
    items.length = 0;
    for (const pos of INITIAL_POSITIONS) {
        items.push(new Item(pos.type, pos.ix, pos.iy));
    }

    // Сброс миньонов
    minions.length = 0;
    for (const pos of INITIAL_MINION_POSITIONS) {
        minions.push(new Minion(pos.ix, pos.iy));
    }

    // Сброс флага
    flag.state = 'docked';
    flag.ix = 0;
    flag.iy = 0;
    flag.iz = 0;

    // Сброс руки
    hand.grabbedItem = null;
    hand.grabbedMinion = null;
    hand.grabbedFlag = false;
    hand.state = 'open';
    hand.animProgress = 0;
    hand.velocityHistory = [];

    // Сброс тряски
    screenShake.intensity = 0;
    screenShake.offsetX = 0;
    screenShake.offsetY = 0;

    // Сброс крови
    bloodParticles.length = 0;
    bloodPuddles.length = 0;

    // Сброс shake-детектора, выделения
    hand.shakeHistory = [];
    hand.prevScreenXForShake = 0;
    hand.selectedMinions = [];

    castle = new Castle(0, -6);

    statusEl.textContent = 'Карта перезапущена!';
}

// ============================================================
//  ИНИЦИАЛИЗАЦИЯ МИРА
// ============================================================
export function initWorld() {
    items.length = 0;
    for (const pos of INITIAL_POSITIONS) {
        items.push(new Item(pos.type, pos.ix, pos.iy));
    }

    minions.length = 0;
    for (const pos of INITIAL_MINION_POSITIONS) {
        minions.push(new Minion(pos.ix, pos.iy));
    }

    flag.state = 'docked';
    flag.ix = 0;
    flag.iy = 0;
    flag.iz = 0;

    bloodParticles.length = 0;
    bloodPuddles.length = 0;

    castle = new Castle(0, -6);
}
