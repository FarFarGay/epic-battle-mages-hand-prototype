// ============================================================
//  МИНЬОН
// ============================================================
import {
    PIXEL_SCALE, HEIGHT_TO_SCREEN, MINION_SPEED, MINION_MAX_HP,
    FALL_DMG_MED_VZ, FALL_DMG_HI_VZ, FALL_DMG_MED, FALL_DMG_HI,
    CAMERA_OFFSET_Y, SKELETON_RISE_DELAY, SKELETON_SPEED_FACTOR, SKELETON_MAX_HP,
    SKELETON_AGGRO_RANGE, SKELETON_ATTACK_RANGE, SKELETON_ATTACK_DAMAGE, SKELETON_ATTACK_CD,
    GOBLIN_ATTACK_DAMAGE, GOBLIN_ATTACK_CD, GOBLIN_ATTACK_RANGE,
    GOBLIN_AGGRO_RANGE, GOBLIN_RALLY_RANGE,
    WARRIOR_AGGRO_RANGE, WARRIOR_ATTACK_DAMAGE, WARRIOR_ATTACK_CD, WARRIOR_ATTACK_RANGE,
    WARRIOR_GUARD_RADIUS,
} from './constants.js';
import { gameMap } from './Map.js';
import {
    MINION_PIXELS, MINION_DEAD_PIXELS, MINION_W, MINION_H,
    TOMBSTONE_PIXELS, TOMBSTONE_W, TOMBSTONE_H,
    SKELETON_PIXELS, SKELETON_W, SKELETON_H,
    WARRIOR_HELMET_PIXELS, WARRIOR_HELMET_W,
} from './sprites.js';
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

        // Класс гоблина
        this.goblinClass = 'basic';     // 'basic' | 'warrior' | 'scout' | 'monk'
        this.guardX = null;             // позиция охраны воина (iso X)
        this.guardY = null;             // позиция охраны воина (iso Y)

        // Скелет
        this.isUndead = false;          // true = скелет (после воскрешения)
        this.pendingBoneEffect = null;  // { ix, iy } — разлёт костей при разрушении
        this.pendingRemove = false;     // пометка на удаление из массива
        this.attackCooldown = 0;        // таймер между ударами (скелет и гоблин)

        // Боевая система гоблинов
        this.combatTarget = null;       // ссылка на врага (Minion) в бою
        this.savedState = null;         // состояние до входа в бой
        this.savedTask = null;          // задача до входа в бой
        this.savedTargetItem = null;    // цель-предмет до входа в бой
        this.savedGathererMode = false; // режим сборщика до входа в бой

        // Система задач
        this.task = null;          // null | 'gather'
        this.targetItem = null;    // ссылка на предмет-цель
        this.carriedItem = null;   // ссылка на переносимый предмет
        this.gathererMode = false; // true = назначен флагом (цикличный сбор в 42×42)
        this.pendingDelivery = null; // typeIndex ресурса, сданного в замок в этом кадре

        this.pickNewTarget();
    }

    pickNewTarget() {
        if (this.isUndead) {
            // Скелеты бродят по всей карте
            const lim = gameMap.size - 1;
            this.targetX = (Math.random() * 2 - 1) * lim;
            this.targetY = (Math.random() * 2 - 1) * lim;
        } else {
            // Свободные гоблины патрулируют 21×21 область вокруг замка (0,0)
            this.targetX = (Math.random() * 2 - 1) * FREE_PATROL_RADIUS;
            this.targetY = (Math.random() * 2 - 1) * FREE_PATROL_RADIUS;
        }
    }

    // ── Боевая система ─────────────────────────────────────────

    // Войти в бой с врагом. Сохраняет текущее состояние для возврата после победы.
    enterCombat(enemy) {
        if (this.isUndead || this.dead) return;
        if (this.state === 'war' || this.state === 'fighting') return;
        const BLOCKED = ['carried', 'lifting', 'thrown', 'bouncing', 'sliding', 'settling', 'dead', 'crumbled', 'skeleton'];
        if (BLOCKED.includes(this.state)) return;

        // Сохраняем состояние
        this.savedState = this.state;
        this.savedTask = this.task;
        this.savedTargetItem = this.targetItem;
        this.savedGathererMode = this.gathererMode;

        // Бросаем переносимый предмет (без очистки task — он уже сохранён)
        if (this.carriedItem) {
            this.carriedItem.state = 'thrown';
            this.carriedItem.vx = 0;
            this.carriedItem.vy = 0;
            this.carriedItem.vz = 0;
            this.carriedItem.stateTime = 0;
            this.carriedItem = null;
        }

        this.combatTarget = enemy;
        this.state = 'war';
        this.stateTime = 0;
    }

    // Выйти из боя, вернуться к предыдущему занятию.
    exitCombat() {
        this.combatTarget = null;
        this.attackCooldown = 0;
        // Воины всегда возвращаются на пост охраны
        if (this.goblinClass === 'warrior') {
            this.state = 'warrior_returning';
            this.stateTime = 0;
            this.savedState = null;
            this.savedTask = null;
            this.savedTargetItem = null;
            this.savedGathererMode = false;
            return;
        }
        if (this.savedState) {
            if (this.savedTask === 'gather') {
                // Возврат к сбору — ищем новый ресурс в 'busy'
                this.task = 'gather';
                this.gathererMode = this.savedGathererMode;
                this.targetItem = null;
                this.state = 'busy';
            } else if (this.savedState === 'listening' || this.savedState === 'waiting' || this.savedState === 'moving') {
                // Восстановить назначенное игроком состояние
                this.state = this.savedState;
            } else {
                this.state = 'free';
                this.pickNewTarget();
            }
            this.savedState = null;
            this.savedTask = null;
            this.savedTargetItem = null;
            this.savedGathererMode = false;
        } else {
            this.state = 'free';
            this.pickNewTarget();
        }
        this.stateTime = 0;
    }

    // Проверка: цель боя ещё жива и доступна?
    isCombatTargetValid() {
        const t = this.combatTarget;
        return t && !t.dead && !t.pendingRemove && t.state !== 'crumbled';
    }

    // Проактивный агро: ищем ближайшего скелета в зоне видимости.
    // Возвращает true если гоблин вступил в бой.
    _tryAggro(allMinions) {
        if (!allMinions || this.isUndead || this.dead) return false;
        const aggroRange = this.goblinClass === 'warrior' ? WARRIOR_AGGRO_RANGE : GOBLIN_AGGRO_RANGE;
        let nearestEnemy = null, nearestEnemyDist = aggroRange;
        for (const m of allMinions) {
            if (m === this || !m.isUndead) continue;
            if (m.state !== 'skeleton') continue;
            const ddx = m.ix - this.ix;
            const ddy = m.iy - this.iy;
            const d = Math.sqrt(ddx * ddx + ddy * ddy);
            if (d < nearestEnemyDist) {
                nearestEnemyDist = d;
                nearestEnemy = m;
            }
        }
        if (nearestEnemy) {
            this.enterCombat(nearestEnemy);
            return true;
        }
        return false;
    }

    // ── Задачи ──────────────────────────────────────────────────

    // Найти ближайший добываемый ресурс не занятый рукой или другим гоблином.
    // zoneOnly=true — искать только в зоне 42×42 (±GATHER_ZONE_RADIUS) вокруг замка.
    findNearestResource(items, zoneOnly = false, allMinions = null) {
        let nearest = null;
        let nearestDist = Infinity;
        for (const item of items) {
            if (!item.typeDef.gatherable) continue;
            if (item.state === 'carried' || item.state === 'lifting' || item.state === 'goblin_carried') continue;
            if (zoneOnly && (Math.abs(item.ix) > GATHER_ZONE_RADIUS || Math.abs(item.iy) > GATHER_ZONE_RADIUS)) continue;
            // Пропускаем ресурс, если другой гоблин уже идёт к нему
            if (allMinions) {
                let taken = false;
                for (const m of allMinions) {
                    if (m === this) continue;
                    if (m.targetItem === item && (m.state === 'busy')) {
                        taken = true;
                        break;
                    }
                }
                if (taken) continue;
            }
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
        if (this.isUndead) {
            // Скелет получает урон от падения как гоблин
            const prevHp = this.hp;
            if (impactVz >= FALL_DMG_HI_VZ) {
                this.hp = Math.max(0, this.hp - FALL_DMG_HI);
            } else if (impactVz >= FALL_DMG_MED_VZ) {
                this.hp = Math.max(0, this.hp - FALL_DMG_MED);
            }
            if (this.hp < prevHp) {
                this.damageWobble = 0.4;
                if (this.hp <= 0) {
                    this.pendingBoneEffect = { ix: this.ix, iy: this.iy };
                    this.pendingRemove = true;
                    this.state = 'crumbled';
                } else {
                    this.pendingBoneEffect = { ix: this.ix, iy: this.iy };
                }
            }
            return;
        }
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
    }

    onSettle(items) {
        this.bounceCount = 0;
        this.stateTime = 0;
        this.dropCarriedItem(); // бросаем камень если несли
        this.combatTarget = null;
        this.savedState = null;
        this.savedTask = null;
        this.savedTargetItem = null;
        this.savedGathererMode = false;
        if (this.state === 'crumbled') return; // скелет уже разрушен в onLand
        if (this.isUndead) {
            // Скелет после приземления — продолжает бродить
            this.pickNewTarget();
            this.state = 'skeleton';
            return;
        }
        if (this.dead) {
            this.state = 'dead';
            return;
        }
        // Воин возвращается на пост (не подбирает ресурсы)
        if (this.goblinClass === 'warrior') {
            this.state = 'warrior_returning';
            this.stateTime = 0;
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

    update(dt, hand, triggerShake, items, castle, allMinions) {
        // stateTime инкрементируется здесь только для нефизических состояний;
        // для физических (lifting/carried/thrown/bouncing/sliding) — в updatePhysics
        const physicsStates = ['lifting', 'carried', 'thrown', 'bouncing', 'sliding'];
        if (!physicsStates.includes(this.state)) {
            this.stateTime += dt;
        }
        if (this.damageWobble > 0) this.damageWobble = Math.max(0, this.damageWobble - dt);

        switch (this.state) {
            // ── 1. Свободен ─────────────────────────────────────────
            case 'free': {
                // Проактивный агро: свободные гоблины ищут врагов в зоне видимости
                if (this._tryAggro(allMinions)) break;

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
                // Сборщики тоже реагируют на скелетов поблизости
                if (this._tryAggro(allMinions)) break;
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
                // Носильщики тоже реагируют на скелетов поблизости
                if (this._tryAggro(allMinions)) break;
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
                        const deliveredTypeIndex = this.carriedItem.typeIndex;
                        const idx = items.indexOf(this.carriedItem);
                        if (idx !== -1) {
                            items.splice(idx, 1);
                            // Корректируем индекс в руке: splice сдвигает все элементы после idx
                            if (hand.grabbedItem !== null) {
                                if (hand.grabbedItem === idx) {
                                    hand.grabbedItem = null;
                                } else if (hand.grabbedItem > idx) {
                                    hand.grabbedItem--;
                                }
                            }
                        }
                        this.pendingDelivery = deliveredTypeIndex;
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

            // ── 7. Идёт к врагу ───────────────────────────────────────
            case 'war': {
                if (!this.isCombatTargetValid()) {
                    this.exitCombat();
                    break;
                }
                const atkRange = this.goblinClass === 'warrior' ? WARRIOR_ATTACK_RANGE : GOBLIN_ATTACK_RANGE;
                const ddx = this.combatTarget.ix - this.ix;
                const ddy = this.combatTarget.iy - this.iy;
                const dist = Math.sqrt(ddx * ddx + ddy * ddy);
                if (dist <= atkRange) {
                    this.state = 'fighting';
                    this.stateTime = 0;
                } else {
                    const spd = MINION_SPEED * dt;
                    this.ix += (ddx / dist) * spd;
                    this.iy += (ddy / dist) * spd;
                    const lim = gameMap.size - 0.5;
                    this.ix = Math.max(-lim, Math.min(lim, this.ix));
                    this.iy = Math.max(-lim, Math.min(lim, this.iy));
                }
                break;
            }

            // ── 8. Сражается ─────────────────────────────────────────
            case 'fighting': {
                if (this.attackCooldown > 0) this.attackCooldown -= dt;

                if (!this.isCombatTargetValid()) {
                    this.exitCombat();
                    break;
                }
                const atkRange = this.goblinClass === 'warrior' ? WARRIOR_ATTACK_RANGE : GOBLIN_ATTACK_RANGE;
                const atkDmg   = this.goblinClass === 'warrior' ? WARRIOR_ATTACK_DAMAGE : GOBLIN_ATTACK_DAMAGE;
                const atkCd    = this.goblinClass === 'warrior' ? WARRIOR_ATTACK_CD : GOBLIN_ATTACK_CD;
                const ddx = this.combatTarget.ix - this.ix;
                const ddy = this.combatTarget.iy - this.iy;
                const dist = Math.sqrt(ddx * ddx + ddy * ddy);

                if (dist > atkRange * 2) {
                    // Враг отошёл — догоняем
                    this.state = 'war';
                    this.stateTime = 0;
                    break;
                }

                if (this.attackCooldown <= 0) {
                    this.attackCooldown = atkCd;
                    const target = this.combatTarget;
                    target.hp = Math.max(0, target.hp - atkDmg);
                    target.damageWobble = 0.4;

                    if (target.hp <= 0) {
                        if (target.isUndead) {
                            target.pendingBoneEffect = { ix: target.ix, iy: target.iy };
                            target.pendingRemove = true;
                            target.state = 'crumbled';
                        }
                        this.exitCombat();
                    } else {
                        if (target.isUndead) {
                            target.pendingBoneEffect = { ix: target.ix, iy: target.iy };
                        } else {
                            target.pendingBloodEffect = { type: 'hit', ix: target.ix, iy: target.iy };
                        }
                    }
                }
                break;
            }

            // ── 9. Воин: стоит на посту ──────────────────────────────
            case 'guarding': {
                if (this._tryAggro(allMinions)) break;
                // Держимся у позиции охраны (небольшие поправки если сдвинулись)
                if (this.guardX !== null) {
                    const dx = this.guardX - this.ix;
                    const dy = this.guardY - this.iy;
                    const d = Math.sqrt(dx * dx + dy * dy);
                    if (d > 0.3) {
                        const spd = MINION_SPEED * dt;
                        this.ix += (dx / d) * Math.min(spd, d);
                        this.iy += (dy / d) * Math.min(spd, d);
                    }
                }
                break;
            }

            // ── 10. Воин: возвращается на пост после боя ─────────────
            case 'warrior_returning': {
                if (this._tryAggro(allMinions)) break;
                if (this.guardX === null) {
                    // Нет позиции — просто стоим у замка
                    this.state = 'free';
                    break;
                }
                const dx = this.guardX - this.ix;
                const dy = this.guardY - this.iy;
                const d = Math.sqrt(dx * dx + dy * dy);
                if (d < 0.3) {
                    this.state = 'guarding';
                    this.stateTime = 0;
                } else {
                    const spd = MINION_SPEED * dt;
                    this.ix += (dx / d) * Math.min(spd, d);
                    this.iy += (dy / d) * Math.min(spd, d);
                    const lim = gameMap.size - 0.5;
                    this.ix = Math.max(-lim, Math.min(lim, this.ix));
                    this.iy = Math.max(-lim, Math.min(lim, this.iy));
                }
                break;
            }

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
                // Через SKELETON_RISE_DELAY — восстать скелетом
                if (this.deadTime >= SKELETON_RISE_DELAY) {
                    this.isUndead = true;
                    this.dead = false;
                    this.hp = SKELETON_MAX_HP;
                    this.state = 'skeleton';
                    this.stateTime = 0;
                    // Очистка stale-полей от прошлой жизни гоблина
                    this.combatTarget = null;
                    this.savedState = null;
                    this.savedTask = null;
                    this.savedTargetItem = null;
                    this.savedGathererMode = false;
                    this.task = null;
                    this.targetItem = null;
                    this.carriedItem = null;
                    this.gathererMode = false;
                    this.pickNewTarget();
                }
                break;

            // ── Скелет (автономный — бродит и атакует гоблинов) ─────
            case 'skeleton': {
                if (this.attackCooldown > 0) this.attackCooldown -= dt;

                // Ищем ближайшего живого гоблина (не скелета, не мёртвого, не в руке)
                let prey = null, preyDist = SKELETON_AGGRO_RANGE;
                if (allMinions) {
                    for (const m of allMinions) {
                        if (m === this) continue;
                        if (m.isUndead || m.dead) continue;
                        if (m.state === 'carried' || m.state === 'lifting') continue;
                        const ddx = m.ix - this.ix;
                        const ddy = m.iy - this.iy;
                        const d = Math.sqrt(ddx * ddx + ddy * ddy);
                        if (d < preyDist) {
                            preyDist = d;
                            prey = m;
                        }
                    }
                }

                if (prey && preyDist <= SKELETON_ATTACK_RANGE) {
                    // В радиусе удара — атаковать
                    if (this.attackCooldown <= 0) {
                        this.attackCooldown = SKELETON_ATTACK_CD;
                        prey.hp = Math.max(0, prey.hp - SKELETON_ATTACK_DAMAGE);
                        prey.damageWobble = 0.4;

                        if (prey.hp <= 0) {
                            prey.dead = true;
                            prey.pendingBloodEffect = { type: 'death', ix: prey.ix, iy: prey.iy };
                            prey.dropCarriedItem();
                            prey.state = 'dead';
                            prey.stateTime = 0;
                            prey.deadTime = 0;
                        } else {
                            prey.pendingBloodEffect = { type: 'hit', ix: prey.ix, iy: prey.iy };
                            // Жертва даёт отпор
                            prey.enterCombat(this);
                        }

                        // Призыв на помощь:
                        // — обычные гоблины в GOBLIN_RALLY_RANGE вступают в бой
                        // — воины откликаются со всей зоны охраны (WARRIOR_GUARD_RADIUS)
                        for (const m of allMinions) {
                            if (m === prey || m === this) continue;
                            if (m.isUndead || m.dead) continue;
                            const rdx = m.ix - prey.ix;
                            const rdy = m.iy - prey.iy;
                            const rallyRange = m.goblinClass === 'warrior' ? WARRIOR_GUARD_RADIUS : GOBLIN_RALLY_RANGE;
                            if (Math.sqrt(rdx * rdx + rdy * rdy) <= rallyRange) {
                                m.enterCombat(this);
                            }
                        }
                    }
                } else if (prey) {
                    // Есть цель — идём к ней
                    const ddx = prey.ix - this.ix;
                    const ddy = prey.iy - this.iy;
                    const spd = MINION_SPEED * SKELETON_SPEED_FACTOR * dt;
                    this.ix += (ddx / preyDist) * spd;
                    this.iy += (ddy / preyDist) * spd;
                } else {
                    // Нет цели — свободное блуждание по карте
                    const dx = this.targetX - this.ix;
                    const dy = this.targetY - this.iy;
                    const dist = Math.sqrt(dx * dx + dy * dy);
                    if (dist < 0.25) {
                        this.pickNewTarget();
                    } else {
                        const spd = MINION_SPEED * SKELETON_SPEED_FACTOR * dt;
                        this.ix += (dx / dist) * spd;
                        this.iy += (dy / dist) * spd;
                    }
                }

                const lim = gameMap.size - 0.5;
                this.ix = Math.max(-lim, Math.min(lim, this.ix));
                this.iy = Math.max(-lim, Math.min(lim, this.iy));
                break;
            }

            case 'crumbled':
                // Конечное состояние скелета — ожидает удаления из массива
                this.iz = 0;
                this.vx = 0;
                this.vy = 0;
                this.vz = 0;
                break;

            default:
                // lifting, carried, thrown, bouncing, sliding — общая физика
                this.updatePhysics(dt, hand, triggerShake);
                break;
        }
    }

    draw(index, hand, hoveredMinion) {
        if (this.state === 'crumbled') return;

        const s = worldToScreen(this.ix, this.iy);

        // ── Анимация смерти: труп → надгробие → скелет ─────────────
        if (this.state === 'dead') {
            const t = this.deadTime;
            const corpseOx = Math.round(s.x - (MINION_W * PIXEL_SCALE) / 2);
            const corpseOy = s.y - MINION_H * PIXEL_SCALE - 4;
            const tombOx   = Math.round(s.x - (TOMBSTONE_W * PIXEL_SCALE) / 2);
            const tombOy   = s.y - TOMBSTONE_H * PIXEL_SCALE - 4;
            const skelOx   = Math.round(s.x - (SKELETON_W * PIXEL_SCALE) / 2);
            const skelOy   = s.y - SKELETON_H * PIXEL_SCALE - 4;

            if (t < 1.0) {
                // Труп
                drawPixelArt(corpseOx, corpseOy, MINION_DEAD_PIXELS, PIXEL_SCALE);
            } else if (t < 1.4) {
                // Переход: труп → надгробие
                const fadeIn = (t - 1.0) / 0.4;
                ctx.save(); ctx.globalAlpha = 1 - fadeIn;
                drawPixelArt(corpseOx, corpseOy, MINION_DEAD_PIXELS, PIXEL_SCALE);
                ctx.restore();
                ctx.save(); ctx.globalAlpha = fadeIn;
                drawPixelArt(tombOx, tombOy, TOMBSTONE_PIXELS, PIXEL_SCALE);
                ctx.restore();
            } else if (t < 2.0) {
                // Надгробие
                drawPixelArt(tombOx, tombOy, TOMBSTONE_PIXELS, PIXEL_SCALE);
            } else if (t < 2.4) {
                // Переход: надгробие → скелет
                const fadeIn = (t - 2.0) / 0.4;
                ctx.save(); ctx.globalAlpha = 1 - fadeIn;
                drawPixelArt(tombOx, tombOy, TOMBSTONE_PIXELS, PIXEL_SCALE);
                ctx.restore();
                ctx.save(); ctx.globalAlpha = fadeIn;
                drawPixelArt(skelOx, skelOy, SKELETON_PIXELS, PIXEL_SCALE);
                ctx.restore();
            } else {
                // Скелет проявился — ждём окончательного перехода
                drawPixelArt(skelOx, skelOy, SKELETON_PIXELS, PIXEL_SCALE);
            }
            return;
        }

        // ── Выбор спрайта (гоблин или скелет) ───────────────────────
        const sprW = this.isUndead ? SKELETON_W : MINION_W;
        const sprH = this.isUndead ? SKELETON_H : MINION_H;
        const spr  = this.isUndead ? SKELETON_PIXELS : MINION_PIXELS;

        drawItemShadow(s.x, s.y, sprW, sprH, this.iz);

        if (this.state === 'carried' || this.state === 'lifting') {
            const time = performance.now() / 300;
            const wobbleX = Math.sin(time) * 1.5;
            const wobbleY = Math.cos(time * 1.3) * 1;
            const gripOffsetY = -8;
            const lerpT = this.state === 'lifting' ? (1 - Math.pow(1 - this.liftProgress, 2)) : 1;
            const canvasPos = screenToCanvas(hand.screenX, hand.screenY);
            const groundOx = s.x - (sprW * PIXEL_SCALE) / 2;
            const groundOy = s.y - (sprH * PIXEL_SCALE) - 4;
            const handOx = canvasPos.x - (sprW * PIXEL_SCALE) / 2 + wobbleX;
            const handOy = canvasPos.y - (sprH * PIXEL_SCALE) / 2 + gripOffsetY + wobbleY;
            const ox = groundOx + (handOx - groundOx) * lerpT;
            const oy = groundOy + (handOy - groundOy) * lerpT;
            drawPixelArt(ox, oy, spr, PIXEL_SCALE);
            return;
        }

        const heightOffset = this.iz * HEIGHT_TO_SCREEN;

        let hitOffsetX = 0, hitOffsetY = 0;
        if (this.damageWobble > 0) {
            const now = performance.now();
            const shake = this.damageWobble * 7;
            hitOffsetX = Math.sin(now * 0.05) * shake;
            hitOffsetY = Math.cos(now * 0.07) * shake * 0.4;
        }

        const ox = s.x - (sprW * PIXEL_SCALE) / 2 + hitOffsetX;
        const oy = s.y - (sprH * PIXEL_SCALE) - 4 - heightOffset + hitOffsetY;

        // Рамка выделения — только для живых гоблинов
        if (!this.isUndead && hand.grabbedFlag && hand.selectedMinions.includes(index)) {
            ctx.save();
            const time = performance.now() / 400;
            ctx.globalAlpha = 0.35 + 0.2 * Math.sin(time);
            ctx.strokeStyle = '#44ff88';
            ctx.lineWidth = 2;
            ctx.strokeRect(ox - 5, oy - 5, sprW * PIXEL_SCALE + 10, sprH * PIXEL_SCALE + 10);
            ctx.restore();
        }

        if (index === hoveredMinion) {
            drawHighlight(ox, oy, sprW, sprH);
        }

        drawPixelArt(ox, oy, spr, PIXEL_SCALE);

        // Шлем воина — накладывается поверх головы живого (не скелет) гоблина-воина
        if (this.goblinClass === 'warrior' && !this.isUndead) {
            const helmetOx = Math.round(ox + (sprW - WARRIOR_HELMET_W) / 2 * PIXEL_SCALE);
            drawPixelArt(helmetOx, oy, WARRIOR_HELMET_PIXELS, PIXEL_SCALE);
        }
    }
}
