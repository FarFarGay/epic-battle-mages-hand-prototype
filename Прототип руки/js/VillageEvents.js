// ============================================================
//  СОБЫТИЯ ДЕРЕВЕНЬ — детектирование, лог, отношения к магу
// ============================================================
import { villages } from './World.js?v=12';

export const VILLAGE_SIGHT = 20; // тайлов — радиус «зрения» деревни

// ── Таблица дельт loyalty ─────────────────────────────────────
const LOY_DELTA = {
    extinguish:      +15,
    kill_skel:       +10,
    water_farm:       +5,
    wind_farm:        +3,
    burn_forest:     -10,
    burn_village:    -25,
    boulder:         -15,
    kill_villager:   -30,
    destroy_house:   -20,
    destroy_farm:    -15,
    artillery:        -5,
    fire:             -5,
    wind:             -2,
};

// ── Таблица дельт fear ────────────────────────────────────────
const FEAR_DELTA = {
    artillery:       +20,
    boulder:         +15,
    burn_village:    +25,
    fire:            +10,
    destroy_house:   +15,
    tower_approach:  +10,
    kill_skel:        -5,
    extinguish:       -5,
    water_farm:       -3,
};

// ── Направление от деревни к событию (8 сторон) ───────────────
function getDirection(dx, dy) {
    const angle = Math.atan2(dy, dx) * 180 / Math.PI;
    if (angle > -22.5 && angle <= 22.5)    return 'E';
    if (angle > 22.5 && angle <= 67.5)     return 'SE';
    if (angle > 67.5 && angle <= 112.5)    return 'S';
    if (angle > 112.5 && angle <= 157.5)   return 'SW';
    if (angle > 157.5 || angle <= -157.5)  return 'W';
    if (angle > -157.5 && angle <= -112.5) return 'NW';
    if (angle > -112.5 && angle <= -67.5)  return 'N';
    return 'NE';
}

// ── Clamp ─────────────────────────────────────────────────────
function clamp(v, min, max) { return Math.max(min, Math.min(max, v)); }

// ── Обновление числовых отношений ─────────────────────────────
function updateRelations(village, code, dist) {
    // Loyalty
    const lDelta = LOY_DELTA[code] || 0;
    if (lDelta !== 0) {
        const distMult = 1.0 - (dist / VILLAGE_SIGHT) * 0.5;
        village.loy = clamp(village.loy + lDelta * distMult, -100, 100);
    }

    // Fear
    const fDelta = FEAR_DELTA[code] || 0;
    if (fDelta !== 0) {
        const distMult = 1.0 - (dist / VILLAGE_SIGHT) * 0.5;
        village.fear = clamp(village.fear + fDelta * distMult, 0, 100);
    }

    // Trust — медленно, ±1-2 за событие
    if (lDelta > 0) village.trust = clamp(village.trust + 1, 0, 100);
    if (lDelta < 0) village.trust = clamp(village.trust - 2, 0, 100);
}

// ── Главная функция — уведомить деревни о событии ─────────────
// event: { code, ix, iy, src, gameTime }
export function notifyVillages(event) {
    for (const v of villages) {
        if (v.abandoned) continue;

        const dx = event.ix - v.centerIx;
        const dy = event.iy - v.centerIy;
        const distSq = dx * dx + dy * dy;

        if (distSq > VILLAGE_SIGHT * VILLAGE_SIGHT) continue;

        const dist = Math.sqrt(distSq);
        const dir = getDirection(dx, dy);

        // Добавить событие в лог
        v.knownEvents.push({
            t: Math.round(event.gameTime || 0),
            code: event.code,
            dist: Math.round(dist),
            dir: dir,
            src: event.src || 'player',
            isNew: true,
        });

        // Обрезать до 15
        if (v.knownEvents.length > 15) {
            v.knownEvents = v.knownEvents.slice(-15);
        }

        // Обновить числовые отношения
        updateRelations(v, event.code, dist);
    }
}

// ── Детектирование событий при смене тайла ────────────────────
// Вызывается из обёртки над onTileChanged
export function detectTileEvent(ix, iy, oldType, newType, cause, gameTime) {
    let code = null;

    if (newType === 'burning' && (oldType === 'forest' || oldType === 'lumber_tile')) {
        code = 'burn_forest';
    } else if (newType === 'burning' && (oldType === 'village_house' || oldType === 'village_square')) {
        code = 'burn_village';
    } else if (newType === 'rubble' && (oldType === 'village_house' || oldType === 'village_square')) {
        code = 'destroy_house';
    } else if ((newType === 'burning' || newType === 'rubble' || newType === 'scorched') &&
               (oldType === 'farmland' || oldType === 'farmland_ripe')) {
        code = 'destroy_farm';
    } else if (oldType === 'burning' && (newType === 'plain' || newType === 'steam') && cause === 'water') {
        code = 'extinguish';
    }

    if (code) {
        const src = (cause === 'fire' || cause === 'water' || cause === 'earth' || cause === 'wind' || cause === 'artillery')
            ? 'player' : 'nature';
        notifyVillages({ code, ix, iy, src, gameTime });
    }
}
