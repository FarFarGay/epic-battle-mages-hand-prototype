// ============================================================
//  МИНЬОН
// ============================================================
import {
    PIXEL_SCALE, HEIGHT_TO_SCREEN, MINION_SPEED, MINION_MAX_HP,
    FALL_DMG_MED_VZ, FALL_DMG_HI_VZ, FALL_DMG_MED, FALL_DMG_HI,
    CAMERA_OFFSET_Y
} from './constants.js';
import { gameMap } from './Map.js';
import { MINION_PIXELS, MINION_DEAD_PIXELS, MINION_W, MINION_H } from './sprites.js';
import { GameObject } from './GameObject.js';
import { canvas, ctx, drawPixelArt, drawItemShadow, drawHighlight } from './renderer.js';
import { camera, isoToScreen } from './isometry.js';

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

// Зоны патруля (iso-тайлы от замка в центре 0,0)
const FREE_PATROL_RADIUS = 10;  // свободный гоблин: 21×21 тайл вокруг замка
const GATHER_ZONE_RADIUS = 21;  // сборщик: 42×42 тайл вокруг замка

export class Minion extends GameObject {
    constructor(ix, iy) {
        super(ix, iy, 0.7, 0.25, 0.82);
        this.radius = 0.4; // для коллизий с замком
        this.state = 'free';
        this.targetX = ix;
        this.targetY = iy;
        this.hp = MINION_MAX_HP;
        this.dead = false;
        this.deadTime = 0;            // секунды с момента смерти (для угасания тумана)
        this.damageWobble = 0;        // таймер тряски при получении урона
        this.pendingBloodEffect = null; // { type: 'hit'|'death', ix, iy }

        // Система задач
        this.task = null;          // null | 'gather'
        this.targetItem = null;    // ссылка на предмет-цель
        this.carriedItem = null;   // ссылка на переносимый предмет
        this.gathererMode = false; // true = назначен флагом (цикличный сбор в 42×42)

        this.pickNewTarget();
    }

    pickNewTarget() {
        // Свободные гоблины патрулируют 21×21 область вокруг замка (0,0)
        this.targetX = (Math.random() * 2 - 1) * FREE_PATROL_RADIUS;
        this.targetY = (Math.random() * 2 - 1) * FREE_PATROL_RADIUS;
    }

    // ── Задачи ──────────────────────────────────────────────────

    // Найти ближайший добываемый ресурс не занятый рукой или другим гоблином.
    // zoneOnly=true — искать только в зоне 42×42 (±GATHER_ZONE_RADIUS) вокруг замка.
    findNearestResource(items, zoneOnly = false) {
        let nearest = null;
        let nearestDist = Infinity;
        for (const item of items) {
            if (!item.typeDef.gatherable) continue;
            if (item.state === 'carried' || item.state === 'lifting' || item.state === 'goblin_carried') continue;
            if (zoneOnly && (Math.abs(item.ix) > GATHER_ZONE_RADIUS || Math.abs(item.iy) > GATHER_ZONE_RADIUS)) continue;
            const dx = item.ix - this.ix;
            const dy = item.iy - this.iy;
            const dist = Math.sqrt(dx * dx + dy * dy);
            if (dist < nearestDist) {
                nearestDist = dist;
                nearest = item;
            }
        }
        return nearest;
    }

    // Назначить задачу «добывать» (через флаг). Возвращает true если задача принята.
    assignGatherTask(items) {
        this.gathererMode = true; // назначен флагом → цикличный сбор в зоне 42×42
        this.task = 'gather';
        const stone = this.findNearestResource(items, true);
        if (!stone) {
            this.task = null;
            this.gathererMode = false;
            this.state = 'free';
            this.stateTime = 0;
            return false;
        }
        this.targetItem = stone;
        this.carriedItem = null;
        this.state = 'busy';
        this.stateTime = 0;
        return true;
    }

    // Бросить переносимый предмет (если есть) — вызывается при захвате рукой или переназначении
    dropCarriedItem() {
        if (this.carriedItem) {
            this.carriedItem.state = 'thrown';
            this.carriedItem.vx = 0;
            this.carriedItem.vy = 0;
            this.carriedItem.vz = 0;
            this.carriedItem.stateTime = 0;
            this.carriedItem = null;
        }
        this.targetItem = null;
        this.task = null;
    }

    onLand(impactVz) {
        if (!this.dead) {
            const prevHp = this.hp;
            if (impactVz >= FALL_DMG_HI_VZ) {
                this.hp = Math.max(0, this.hp - FALL_DMG_HI);
            } else if (impactVz >= FALL_DMG_MED_VZ) {
                this.hp = Math.max(0, this.hp - FALL_DMG_MED);
            }
            if (this.hp < prevHp) {
                this.damageWobble = 0.4;
                if (this.hp <= 0) {
                    this.dead = true;
                    this.pendingBloodEffect = { type: 'death', ix: this.ix, iy: this.iy };
                } else {
                    this.pendingBloodEffect = { type: 'hit', ix: this.ix, iy: this.iy };
                }
            }
        }
        // Мёртвый гоблин — крови не оставляет
    }

    onSettle(items) {
        this.bounceCount = 0;
        this.stateTime = 0;
        this.dropCarriedItem(); // бросаем камень если несли
        if (this.dead) {
            this.state = 'dead';
            return;
        }
        // При приземлении ищем ближайший ресурс в радиусе 1.5 тайла
        const AUTO_GATHER_RADIUS = 1.5;
        let nearest = null, nearestDist = AUTO_GATHER_RADIUS;
        if (items) {
            for (const item of items) {
                if (!item.typeDef.gatherable) continue;
                if (item.state === 'carried' || item.state === 'lifting' || item.state === 'goblin_carried') continue;
                const dx = item.ix - this.ix;
                const dy = item.iy - this.iy;
                const dist = Math.sqrt(dx * dx + dy * dy);
                if (dist < nearestDist) { nearestDist = dist; nearest = item; }
            }
        }
        if (nearest) {
            // Если ресурс в зоне 42×42 — после доставки продолжит сбор; снаружи — станет свободным
            this.gathererMode = Math.abs(nearest.ix) <= GATHER_ZONE_RADIUS && Math.abs(nearest.iy) <= GATHER_ZONE_RADIUS;
            this.task = 'gather';
            this.targetItem = nearest;
            this.carriedItem = null;
            this.state = 'busy';
        } else {
            this.pickNewTarget();
            this.state = 'free';
        }
    }

    update(dt, hand, triggerShake, items, castle) {
        this.stateTime += dt;
        if (this.damageWobble > 0) this.damageWobble = Math.max(0, this.damageWobble - dt);

        switch (this.state) {
            // ── 1. Свободен ─────────────────────────────────────────
            case 'free': {
                const dx = this.targetX - this.ix;
                const dy = this.targetY - this.iy;
                const dist = Math.sqrt(dx * dx + dy * dy);
                if (dist < 0.25) {
                    this.pickNewTarget();
                } else {
                    const spd = MINION_SPEED * dt;
                    this.ix += (dx / dist) * spd;
                    this.iy += (dy / dist) * spd;
                    const lim = gameMap.size - 0.5;
                    this.ix = Math.max(-lim, Math.min(lim, this.ix));
                    this.iy = Math.max(-lim, Math.min(lim, this.iy));
                }
                break;
            }

            // ── 2. Слушает ──────────────────────────────────────────
            case 'listening':
                // Стоит на месте, ждёт команду игрока
                break;

            // ── 3. Передвигается ────────────────────────────────────
            case 'moving': {
                const dx = this.targetX - this.ix;
                const dy = this.targetY - this.iy;
                const dist = Math.sqrt(dx * dx + dy * dy);
                if (dist < 0.25) {
                    // Дошёл до флага → ждёт задачу рядом
                    this.state = 'waiting';
                    this.stateTime = 0;
                } else {
                    const spd = MINION_SPEED * dt;
                    this.ix += (dx / dist) * spd;
                    this.iy += (dy / dist) * spd;
                    const lim = gameMap.size - 0.5;
                    this.ix = Math.max(-lim, Math.min(lim, this.ix));
                    this.iy = Math.max(-lim, Math.min(lim, this.iy));
                }
                break;
            }

            // ── 4. Ожидает задачу ───────────────────────────────────
            case 'waiting':
                // Стоит у флага, ждёт задачу от игрока
                break;

            // ── 5. Занят: идёт к камню ──────────────────────────────
            case 'busy': {
                if (this.task === 'gather') {
                    // Проверяем что цель ещё доступна
                    if (!this.targetItem ||
                        this.targetItem.state === 'carried' ||
                        this.targetItem.state === 'lifting' ||
                        this.targetItem.state === 'goblin_carried') {
                        const stone = this.findNearestResource(items, this.gathererMode);
                        if (!stone) {
                            this.task = null;
                            this.gathererMode = false;
                            this.state = 'free';
                            this.stateTime = 0;
                        } else {
                            this.targetItem = stone;
                        }
                        break;
                    }
                    const dx = this.targetItem.ix - this.ix;
                    const dy = this.targetItem.iy - this.iy;
                    const dist = Math.sqrt(dx * dx + dy * dy);
                    const canPickUp = this.targetItem.state === 'idle' ||
                                      this.targetItem.state === 'settling' ||
                                      this.targetItem.state === 'sliding';
                    if (dist < 0.6 && canPickUp) {
                        // Поднять ресурс; если он снаружи зоны 42×42 — после доставки станем свободным
                        this.gathererMode = this.gathererMode &&
                            Math.abs(this.targetItem.ix) <= GATHER_ZONE_RADIUS &&
                            Math.abs(this.targetItem.iy) <= GATHER_ZONE_RADIUS;
                        this.targetItem.state = 'goblin_carried';
                        this.targetItem.vx = 0;
                        this.targetItem.vy = 0;
                        this.targetItem.vz = 0;
                        this.carriedItem = this.targetItem;
                        this.targetItem = null;
                        this.state = 'returning';
                        this.stateTime = 0;
                    } else {
                        const spd = MINION_SPEED * dt;
                        this.ix += (dx / dist) * spd;
                        this.iy += (dy / dist) * spd;
                        const lim = gameMap.size - 0.5;
                        this.ix = Math.max(-lim, Math.min(lim, this.ix));
                        this.iy = Math.max(-lim, Math.min(lim, this.iy));
                    }
                }
                break;
            }

            // ── 6. Возвращается: несёт камень в замок ───────────────
            case 'returning': {
                if (this.task === 'gather' && this.carriedItem) {
                    // Камень следует за гоблином
                    this.carriedItem.ix = this.ix;
                    this.carriedItem.iy = this.iy;
                    this.carriedItem.iz = 0.5;

                    if (!castle) break;

                    const dx = castle.ix - this.ix;
                    const dy = castle.iy - this.iy;
                    const dist = Math.sqrt(dx * dx + dy * dy);

                    if (dist < castle.baseRadius + this.radius) {
                        // Сдать камень
                        const idx = items.indexOf(this.carriedItem);
                        if (idx !== -1) {
                            items.splice(idx, 1);
                            // Корректируем индекс в руке: splice сдвигает все элементы после idx
                            if (hand.grabbedItem !== null && hand.grabbedItem > idx) {
                                hand.grabbedItem--;
                            }
                        }
                        this.carriedItem = null;

                        // Искать следующий ресурс (только в зоне 42×42 если gathererMode)
                        const stone = this.findNearestResource(items, this.gathererMode);
                        if (stone && this.gathererMode) {
                            this.targetItem = stone;
                            this.state = 'busy';
                            this.stateTime = 0;
                        } else {
                            // Ресурсов в зоне нет или ручной гоблин → стать свободным
                            this.task = null;
                            this.gathererMode = false;
                            this.state = 'free';
                            this.stateTime = 0;
                        }
                    } else {
                        const spd = MINION_SPEED * dt;
                        this.ix += (dx / dist) * spd;
                        this.iy += (dy / dist) * spd;
                        const lim = gameMap.size - 0.5;
                        this.ix = Math.max(-lim, Math.min(lim, this.ix));
                        this.iy = Math.max(-lim, Math.min(lim, this.iy));
                    }
                }
                break;
            }

            // ── 7–8. Заглушки ───────────────────────────────────────
            case 'war':        // видит врага (будущее)
            case 'fighting':   // сражается (будущее)
                break;

            case 'settling':
                if (this.stateTime > 0.3) {
                    this.onSettle(items);
                }
                break;

            case 'dead':
                this.iz = 0;
                this.vx = 0;
                this.vy = 0;
                this.vz = 0;
                this.deadTime += dt;
                break;

            default:
                // lifting, carried, thrown, bouncing, sliding — общая физика
                this.updatePhysics(dt, hand, triggerShake);
                break;
        }
    }

    draw(index, hand, hoveredMinion) {
        const s = worldToScreen(this.ix, this.iy);

        drawItemShadow(s.x, s.y, MINION_W, MINION_H, this.iz);

        const minionSprite = this.dead ? MINION_DEAD_PIXELS : MINION_PIXELS;

        if (this.state === 'carried' || this.state === 'lifting') {
            const time = performance.now() / 300;
            const wobbleX = Math.sin(time) * 1.5;
            const wobbleY = Math.cos(time * 1.3) * 1;
            const gripOffsetY = -8;
            const lerpT = this.state === 'lifting' ? (1 - Math.pow(1 - this.liftProgress, 2)) : 1;
            const canvasPos = screenToCanvas(hand.screenX, hand.screenY);
            const groundOx = s.x - (MINION_W * PIXEL_SCALE) / 2;
            const groundOy = s.y - (MINION_H * PIXEL_SCALE) - 4;
            const handOx = canvasPos.x - (MINION_W * PIXEL_SCALE) / 2 + wobbleX;
            const handOy = canvasPos.y - (MINION_H * PIXEL_SCALE) / 2 + gripOffsetY + wobbleY;
            const ox = groundOx + (handOx - groundOx) * lerpT;
            const oy = groundOy + (handOy - groundOy) * lerpT;
            drawPixelArt(ox, oy, minionSprite, PIXEL_SCALE);
            return;
        }

        const heightOffset = this.iz * HEIGHT_TO_SCREEN;

        // Тряска при получении урона
        let hitOffsetX = 0, hitOffsetY = 0;
        if (this.damageWobble > 0) {
            const t = performance.now();
            const shake = this.damageWobble * 7;
            hitOffsetX = Math.sin(t * 0.05) * shake;
            hitOffsetY = Math.cos(t * 0.07) * shake * 0.4;
        }

        const ox = s.x - (MINION_W * PIXEL_SCALE) / 2 + hitOffsetX;
        const oy = s.y - (MINION_H * PIXEL_SCALE) - 4 - heightOffset + hitOffsetY;

        if (hand.grabbedFlag && hand.selectedMinions.includes(index)) {
            ctx.save();
            const time = performance.now() / 400;
            ctx.globalAlpha = 0.35 + 0.2 * Math.sin(time);
            ctx.strokeStyle = '#44ff88';
            ctx.lineWidth = 2;
            ctx.strokeRect(ox - 5, oy - 5, MINION_W * PIXEL_SCALE + 10, MINION_H * PIXEL_SCALE + 10);
            ctx.restore();
        }

        if (index === hoveredMinion) {
            drawHighlight(ox, oy, MINION_W, MINION_H);
        }

        drawPixelArt(ox, oy, minionSprite, PIXEL_SCALE);
    }
}
