// ============================================================
//  МИР — предметы, миньоны, тряска экрана
// ============================================================
import { gameMap, setTileChangedCallback } from './Map.js';
import {
    ITEM_TYPES, WARRIOR_GUARD_RADIUS, WARRIOR_WALL_STEP, MANA_MAX,
    WATER_SPELL_COOLDOWN, EARTH_SPELL_COOLDOWN, WIND_SPELL_COOLDOWN,
} from './constants.js';
import { Item } from './Item.js';
import { Minion } from './Minion.js';
import { Castle } from './Castle.js';
import { Fireball } from './Fireball.js';
import { SpellProjectile } from './SpellProjectile.js';
import { generateMap, placeResources, placeDecorations, lastVillages } from './mapGenerator.js?v=11';
import { ProductionZone } from './ProductionZone.js';
import { onTileChanged, decoParticles, setItemSpawnCallback } from './decorations.js?v=10';
export { decoParticles };

// Регистрируем callback изменения тайлов → обновление декораций
setTileChangedCallback(onTileChanged);

// Регистрируем callback спавна предметов из декораций
setItemSpawnCallback((typeIndex, ix, iy, vx, vy, vz) => {
    const item = new Item(typeIndex, ix, iy);
    item.vx = vx;
    item.vy = vy;
    item.vz = vz;
    item.state = vz > 0 ? 'thrown' : 'idle';
    item.bounceCount = 0;
    items.push(item);
});

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

export const bloodParticles = [];
export const bloodPuddles   = [];

export const fireball = new Fireball();
export const spellProjectile = new SpellProjectile();

// (DEPRECATED — заменено тайловыми трансформациями)
export const firePatches = [];

export const spellFogReveals = [];
export const debugFlags = { fogDisabled: false, showVillages: false };

export const spellStates = {
    water: { cooldown: 0, maxCooldown: WATER_SPELL_COOLDOWN },
    earth: { cooldown: 0, maxCooldown: EARTH_SPELL_COOLDOWN },
    wind:  { cooldown: 0, maxCooldown: WIND_SPELL_COOLDOWN },
};

export const artilleryMode = {
    active: false,
    state: 'aiming',
    crosshairX: 0, crosshairY: 0,
    projectile: { ix: 0, iy: 0, iz: 0, vx: 0, vy: 0, vz: 0 },
    targetX: 0, targetY: 0,
    timer: 0, flightDuration: 0, fogRevealTimer: 0,
    explosion: { active: false, ix: 0, iy: 0, t: 0, duration: 1.0, particles: [] },
    savedCameraX: 0, savedCameraY: 0, savedZoom: 1.0,
};

export const castleResources = [];
export const manaPool        = { value: MANA_MAX };
export const monkTotem       = { active: false, ix: 0, iy: 0 };
export const commandMarkers  = [];
export const activeTiles     = [];
export let   villages        = [];
export let   productionZones = [];

export let castle = null;

// ============================================================
//  ПОИСК ЗОНЫ ПО ТАЙЛУ
// ============================================================
// Кэш: координаты → зона (перестраивается при initWorld)
const _tileToZone = new Map();

export function findZoneAtTile(ix, iy) {
    return _tileToZone.get(`${ix},${iy}`) || null;
}

function _rebuildTileToZoneCache() {
    _tileToZone.clear();
    for (const z of productionZones) {
        for (const t of z.tiles) {
            _tileToZone.set(`${t.ix},${t.iy}`, z);
        }
    }
}

// ============================================================
//  СТЕНА ВОИНОВ
// ============================================================
const warriorWall = {
    baseAngle: Math.random() * Math.PI * 2,
    count: 0,
};

export function getNextWarriorGuardPos() {
    const angle = warriorWall.baseAngle + warriorWall.count * WARRIOR_WALL_STEP;
    warriorWall.count++;
    // Позиция относительно замка (не относительно (0,0)!)
    return {
        ix: gameMap.castlePos.ix + Math.cos(angle) * WARRIOR_GUARD_RADIUS,
        iy: gameMap.castlePos.iy + Math.sin(angle) * WARRIOR_GUARD_RADIUS,
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
        screenShake.intensity *= Math.exp(-3 * dt);
    } else {
        screenShake.intensity = 0;
        screenShake.offsetX   = 0;
        screenShake.offsetY   = 0;
    }
}

// ============================================================
//  КОЛЛИЗИИ МЕЖДУ ПРЕДМЕТАМИ
// ============================================================
export function resolveItemCollisions() {
    for (let i = 0; i < items.length; i++) {
        for (let j = i + 1; j < items.length; j++) {
            const a = items[i], b = items[j];
            if (a.state === 'carried' || a.state === 'lifting' || a.state === 'goblin_carried') continue;
            if (b.state === 'carried' || b.state === 'lifting' || b.state === 'goblin_carried') continue;

            const typeA = a.typeDef, typeB = b.typeDef;
            const minDist = typeA.radius + typeB.radius;

            if (Math.abs(a.iz - b.iz) > minDist * 0.5) continue;

            const dx = b.ix - a.ix, dy = b.iy - a.iy;
            const dist = Math.sqrt(dx * dx + dy * dy);
            if (dist >= minDist || dist < 0.0001) continue;

            const nx = dx / dist, ny = dy / dist;
            const overlap = minDist - dist;
            const totalMass = typeA.mass + typeB.mass;
            a.ix -= nx * overlap * (typeB.mass / totalMass);
            a.iy -= ny * overlap * (typeB.mass / totalMass);
            b.ix += nx * overlap * (typeA.mass / totalMass);
            b.iy += ny * overlap * (typeA.mass / totalMass);

            const dvx = b.vx - a.vx, dvy = b.vy - a.vy;
            const dot = dvx * nx + dvy * ny;
            if (dot >= 0) continue;

            const restitution = Math.min(typeA.bounciness, typeB.bounciness);
            const impulse = -(1 + restitution) * dot / totalMass;

            a.vx -= impulse * typeB.mass * nx;
            a.vy -= impulse * typeB.mass * ny;
            b.vx += impulse * typeA.mass * nx;
            b.vy += impulse * typeA.mass * ny;

            if (a.state === 'idle' || a.state === 'settling') { a.state = 'sliding'; a.stateTime = 0; }
            if (b.state === 'idle' || b.state === 'settling') { b.state = 'sliding'; b.stateTime = 0; }

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

    hand.grabbedItem     = null;
    hand.grabbedMinion   = null;
    hand.state           = 'open';
    hand.animProgress    = 0;
    hand.velocityHistory = [];
    hand.selectedMinions = [];
    hand.grabbedSpell    = null;

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
    // 1. Генерация карты (биомы + высоты + деревни)
    generateMap(gameMap.seed);
    villages = lastVillages;

    // 1b. Зоны производства из деревень
    productionZones = [];
    for (const v of villages) {
        const pzt = v.productionZoneTiles;
        for (const zoneType of ['farm', 'mine', 'lumber']) {
            const tiles = pzt[zoneType];
            if (!tiles || tiles.length === 0) continue;
            // Центр зоны — среднее координат тайлов
            let sx = 0, sy = 0;
            for (const t of tiles) { sx += t.ix; sy += t.iy; }
            const zone = new ProductionZone(
                `${v.id}_${zoneType}`, zoneType,
                Math.round(sx / tiles.length), Math.round(sy / tiles.length),
                tiles, v.id
            );
            // Начальный harvestReady для ферм с farmland_ripe
            if (zoneType === 'farm') {
                let ripe = 0;
                for (const t of tiles) {
                    if (gameMap.getTile(t.ix, t.iy) === 'farmland_ripe') ripe++;
                }
                zone.harvestReady = ripe;
                zone._lastRipeCount = ripe;
            }
            productionZones.push(zone);
        }
    }
    _rebuildTileToZoneCache();

    // 2. Декорации
    placeDecorations(gameMap.seed);

    // 3. Ресурсы
    const resourcePositions = placeResources(gameMap.seed);
    items.length = 0;
    for (const pos of resourcePositions) {
        items.push(new Item(pos.type, pos.ix, pos.iy));
    }

    // 4. Миньоны
    minions.length = 0;
    for (const pos of gameMap.initialMinions) {
        minions.push(new Minion(pos.ix, pos.iy));
    }

    // 5. Сброс состояния экрана
    screenShake.intensity = 0;
    screenShake.offsetX   = 0;
    screenShake.offsetY   = 0;

    bloodParticles.length = 0;
    bloodPuddles.length   = 0;
    decoParticles.length  = 0;

    // 6. Замок
    castleResources.length = 0;
    for (let i = 0; i < ITEM_TYPES.length; i++) castleResources.push(0);
    castle = new Castle(gameMap.castlePos.ix, gameMap.castlePos.iy);
    resetWarriorWall();

    // 7. Заклинания и артиллерия
    artilleryMode.active = false;
    artilleryMode.state  = 'aiming';
    artilleryMode.explosion.active = false;
    artilleryMode.fogRevealTimer   = 0;

    fireball.reset();
    spellProjectile.reset();
    firePatches.length   = 0;
    activeTiles.length   = 0;
    spellFogReveals.length = 0;

    spellStates.water.cooldown = 0;
    spellStates.earth.cooldown = 0;
    spellStates.wind.cooldown  = 0;

    // 8. Сброс тайлов заклинаний (декорации уже обновлены через generateMap)
    // (generateMap сам сбрасывает _tiles, так что здесь не нужно)

    manaPool.value = MANA_MAX;

    monkTotem.active = false;
    monkTotem.ix     = 0;
    monkTotem.iy     = 0;

    commandMarkers.length = 0;

    // 9. Туман войны — полный сброс
    gameMap._fog = {};
    gameMap._visibleKeys.clear();
}
