// ============================================================
//  МИР — предметы, миньоны, тряска экрана
// ============================================================
import { gameMap } from './Map.js';
import {
    ITEM_TYPES, WARRIOR_GUARD_RADIUS, WARRIOR_WALL_STEP, MANA_MAX,
    WATER_SPELL_COOLDOWN, EARTH_SPELL_COOLDOWN, WIND_SPELL_COOLDOWN,
} from './constants.js';
import { Item } from './Item.js';
import { Minion } from './Minion.js';
import { Castle } from './Castle.js';
import { Fireball } from './Fireball.js';

// ============================================================
//  СОСТОЯНИЕ МИРА
// ============================================================
export const items = [];
export const minions = [];

export const screenShake = {
    intensity: 0,
    offsetX: 0,
    offsetY: 0,
};

export const bloodParticles = [];  // { x, y, vx, vy, life, maxLife, size }
export const bloodPuddles   = [];  // { ix, iy, size, t, duration }

// Огненный шар
export const fireball = new Fireball();

// Огненные пятна после взрыва (DEPRECATED — заменено тайловыми трансформациями)
export const firePatches = [];

// Состояния заклинаний (кроме огненного шара — он в Fireball.js)
export const spellStates = {
    water: { cooldown: 0, maxCooldown: WATER_SPELL_COOLDOWN },
    earth: { cooldown: 0, maxCooldown: EARTH_SPELL_COOLDOWN },
    wind:  { cooldown: 0, maxCooldown: WIND_SPELL_COOLDOWN },
};

// Режим артиллерии замка
export const artilleryMode = {
    active: false,
    state: 'aiming',     // 'aiming' | 'flying' | 'aftermath'
    // Прицел (iso координаты)
    crosshairX: 0,
    crosshairY: 0,
    // Снаряд
    projectile: { ix: 0, iy: 0, iz: 0, vx: 0, vy: 0, vz: 0 },
    // Цель
    targetX: 0,
    targetY: 0,
    // Таймеры
    timer: 0,
    flightDuration: 0,
    fogRevealTimer: 0,    // секунды туманоснятия после взрыва
    // Взрыв
    explosion: {
        active: false,
        ix: 0, iy: 0,
        t: 0,
        duration: 1.0,
        particles: [],
    },
    // Сохранённая камера
    savedCameraX: 0,
    savedCameraY: 0,
    savedZoom: 1.0,
};

// Счётчики ресурсов: castleResources[typeIndex] = количество доставленных в замок
export const castleResources = [];

// Мана игрока
export const manaPool = { value: MANA_MAX };

// Тотем монахов
export const monkTotem = { active: false, ix: 0, iy: 0 };

// Маркеры команд ПКМ: { ix, iy, timer, maxTime, type: 'gather'|'attack'|'move' }
export const commandMarkers = [];

// Активные тайлы с таймерами: { ix, iy, type, timer, maxTime, nextType }
export const activeTiles = [];

export let castle = null;

// ============================================================
//  СТЕНА ВОИНОВ — позиции охраны на границе WARRIOR_GUARD_RADIUS
// ============================================================
const warriorWall = {
    baseAngle: Math.random() * Math.PI * 2, // случайное начальное направление стены
    count: 0,                                // сколько воинов уже поставлено
};

// Возвращает следующую позицию охраны для нового воина.
// Воины выстраиваются в линию вдоль периметра окружности радиуса WARRIOR_GUARD_RADIUS.
export function getNextWarriorGuardPos() {
    const angle = warriorWall.baseAngle + warriorWall.count * WARRIOR_WALL_STEP;
    warriorWall.count++;
    return {
        ix: Math.cos(angle) * WARRIOR_GUARD_RADIUS,
        iy: Math.sin(angle) * WARRIOR_GUARD_RADIUS,
    };
}

export function resetWarriorWall() {
    warriorWall.baseAngle = Math.random() * Math.PI * 2;
    warriorWall.count = 0;
}

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
        screenShake.intensity *= Math.exp(-3 * dt); // эквивалентно pow(0.05, dt), но быстрее
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

            // Предметы в руке или у гоблина не участвуют в коллизиях
            if (a.state === 'carried' || a.state === 'lifting' || a.state === 'goblin_carried') continue;
            if (b.state === 'carried' || b.state === 'lifting' || b.state === 'goblin_carried') continue;

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
    initWorld();

    // Сброс руки
    hand.grabbedItem = null;
    hand.grabbedMinion = null;
    hand.state = 'open';
    hand.animProgress = 0;
    hand.velocityHistory = [];
    hand.selectedMinions = [];
    hand.grabbedSpell = null;

    statusEl.textContent = 'Карта перезапущена!';
}

// ============================================================
//  СПАВН МИНЬОНОВ
// ============================================================
export function spawnMinion(ix, iy) {
    minions.push(new Minion(ix, iy));
}

// ============================================================
//  ИНИЦИАЛИЗАЦИЯ МИРА
// ============================================================
export function initWorld() {
    items.length = 0;
    for (const pos of gameMap.initialItems) {
        items.push(new Item(pos.type, pos.ix, pos.iy));
    }

    minions.length = 0;
    for (const pos of gameMap.initialMinions) {
        minions.push(new Minion(pos.ix, pos.iy));
    }

    screenShake.intensity = 0;
    screenShake.offsetX = 0;
    screenShake.offsetY = 0;

    bloodParticles.length = 0;
    bloodPuddles.length = 0;

    castleResources.length = 0;
    for (let i = 0; i < ITEM_TYPES.length; i++) castleResources.push(0);

    castle = new Castle(gameMap.castlePos.ix, gameMap.castlePos.iy);
    resetWarriorWall();

    artilleryMode.active = false;
    artilleryMode.state = 'aiming';
    artilleryMode.explosion.active = false;
    artilleryMode.fogRevealTimer = 0;

    fireball.reset();
    firePatches.length = 0;
    activeTiles.length = 0;

    spellStates.water.cooldown = 0;
    spellStates.earth.cooldown = 0;
    spellStates.wind.cooldown = 0;

    // Сброс всех тайлов к исходным типам
    gameMap._tiles = {};

    manaPool.value = MANA_MAX;

    monkTotem.active = false;
    monkTotem.ix = 0;
    monkTotem.iy = 0;

    commandMarkers.length = 0;
}
