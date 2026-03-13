// ============================================================
//  МИНЬОН
// ============================================================
import {
    PIXEL_SCALE, HEIGHT_TO_SCREEN, MINION_SPEED, MINION_MAX_HP,
    FALL_DMG_MED_VZ, FALL_DMG_HI_VZ, FALL_DMG_MED, FALL_DMG_HI,
    SKELETON_RISE_DELAY, SKELETON_SPEED_FACTOR, SKELETON_MAX_HP,
    SKELETON_AGGRO_RANGE, SKELETON_ATTACK_RANGE, SKELETON_ATTACK_DAMAGE, SKELETON_ATTACK_CD,
    GOBLIN_ATTACK_DAMAGE, GOBLIN_ATTACK_CD, GOBLIN_ATTACK_RANGE,
    GOBLIN_AGGRO_RANGE, GOBLIN_RALLY_RANGE,
    WARRIOR_AGGRO_RANGE, WARRIOR_ATTACK_DAMAGE, WARRIOR_ATTACK_CD, WARRIOR_ATTACK_RANGE,
    WARRIOR_GUARD_RADIUS,
    SCOUT_LIFESPAN,
    FREE_PATROL_RADIUS, GATHER_ZONE_RADIUS,
    AUTO_ATTACK_RADIUS, AUTO_GATHER_RADIUS,
} from './constants.js';
import { gameMap } from './Map.js';
import { getTileEffect } from './tileEffects.js?v=2';
import {
    MINION_PIXELS, MINION_DEAD_PIXELS, MINION_W, MINION_H,
    TOMBSTONE_PIXELS, TOMBSTONE_W, TOMBSTONE_H,
    SKELETON_PIXELS, SKELETON_W, SKELETON_H,
    WARRIOR_HELMET_PIXELS, WARRIOR_HELMET_W,
    SCOUT_HOOD_PIXELS, SCOUT_HOOD_W,
    MONK_ROBE_PIXELS, MONK_ROBE_W,
} from './sprites.js?v=5';
import { GameObject } from './GameObject.js';
import { ctx, drawPixelArt, drawItemShadow, drawHighlight } from './renderer.js';
import { worldToScreen, screenToCanvas } from './isometry.js';

// Состояния в которых миньон находится в физическом режиме (не игровая логика)
const PHYSICS_STATES = new Set(['lifting', 'carried', 'thrown', 'bouncing', 'sliding']);
// Состояния в которых нельзя входить в бой
const COMBAT_BLOCKED_STATES = new Set(['carried', 'lifting', 'thrown', 'bouncing', 'sliding', 'settling', 'dead', 'crumbled', 'skeleton']);

// FREE_PATROL_RADIUS, GATHER_ZONE_RADIUS, AUTO_ATTACK_RADIUS, AUTO_GATHER_RADIUS — из constants.js

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
        this.scoutAge = 0;              // секунд прожито (только для разведчика)
        this.totemX = null;             // позиция тотема монахов (iso X)
        this.totemY = null;             // позиция тотема монахов (iso Y)

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

        // Тайловые эффекты
        this._currentSpeedMult = 1.0; // множитель скорости от тайла (обновляется каждый кадр)
        this.windPushed = false;      // флаг: отброшен ветром → нет урона от падения

        this.pickNewTarget();
    }

    // Проверяет, можно ли войти на тайл (стены непроходимы)
    _canMoveTo(ix, iy) {
        const tileType = gameMap.getTile(Math.round(ix), Math.round(iy));
        if (tileType === 'wall') return false;
        return true;
    }

    // Двигает юнита к цели с учётом непроходимости. Возвращает true если двигался.
    _moveToward(tx, ty, speed) {
        const dx = tx - this.ix;
        const dy = ty - this.iy;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < 0.001) return false;
        const step = Math.min(speed, dist);
        const nx = this.ix + (dx / dist) * step;
        const ny = this.iy + (dy / dist) * step;
        if (!this._canMoveTo(nx, ny)) {
            // Попробовать обойти: сдвиг перпендикулярно
            const px = -(dy / dist) * step;
            const py = (dx / dist) * step;
            if (this._canMoveTo(this.ix + px, this.iy + py)) {
                this.ix += px;
                this.iy += py;
            } else if (this._canMoveTo(this.ix - px, this.iy - py)) {
                this.ix -= px;
                this.iy -= py;
            }
            // Иначе — стоим на месте
            return false;
        }
        this.ix = nx;
        this.iy = ny;
        const lim = gameMap.size - 0.5;
        this.ix = Math.max(-lim, Math.min(lim, this.ix));
        this.iy = Math.max(-lim, Math.min(lim, this.iy));
        return true;
    }

    pickNewTarget() {
        if (this.isUndead || this.goblinClass === 'scout') {
            // Скелеты и разведчики бродят по всей карте
            const lim = gameMap.size - 1;
            this.targetX = (Math.random() * 2 - 1) * lim;
            this.targetY = (Math.random() * 2 - 1) * lim;
        } else if (this.goblinClass === 'monk') {
            // Монах не выбирает случайные цели — целью всегда является тотем
        } else {
            // Свободные гоблины патрулируют область вокруг замка
            this.targetX = gameMap.castlePos.ix + (Math.random() * 2 - 1) * FREE_PATROL_RADIUS;
            this.targetY = gameMap.castlePos.iy + (Math.random() * 2 - 1) * FREE_PATROL_RADIUS;
        }
    }

    // ── Боевая система ─────────────────────────────────────────

    // Войти в бой с врагом. Сохраняет текущее состояние для возврата после победы.
    enterCombat(enemy) {
        if (this.isUndead || this.dead) return;
        if (this.state === 'war' || this.state === 'fighting') return;
        if (COMBAT_BLOCKED_STATES.has(this.state)) return;

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
        // Монах возвращается к тотему
        if (this.goblinClass === 'monk') {
            this.state = 'monk_walking';
            this.stateTime = 0;
            this.savedState = null;
            this.savedTask = null;
            this.savedTargetItem = null;
            this.savedGathererMode = false;
            return;
        }
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
            } else if (this.savedState === 'moving_to_point') {
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
        let nearestEnemy = null, nearestEnemyDistSq = aggroRange * aggroRange;
        for (const m of allMinions) {
            if (m === this || !m.isUndead) continue;
            if (m.state !== 'skeleton') continue;
            const ddx = m.ix - this.ix;
            const ddy = m.iy - this.iy;
            const dSq = ddx * ddx + ddy * ddy;
            if (dSq < nearestEnemyDistSq) {
                nearestEnemyDistSq = dSq;
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
        let nearestDistSq = Infinity;
        for (const item of items) {
            if (!item.typeDef.gatherable) continue;
            if (item.state === 'carried' || item.state === 'lifting' || item.state === 'goblin_carried') continue;
            if (item.state === 'thrown' || item.state === 'bouncing') continue; // летящие предметы — не цель
            if (zoneOnly && (Math.abs(item.ix - gameMap.castlePos.ix) > GATHER_ZONE_RADIUS || Math.abs(item.iy - gameMap.castlePos.iy) > GATHER_ZONE_RADIUS)) continue;
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
            const distSq = dx * dx + dy * dy;
            if (distSq < nearestDistSq) {
                nearestDistSq = distSq;
                nearest = item;
            }
        }
        return nearest;
    }

    // Назначить задачу «добывать» (через флаг). Возвращает true если задача принята.
    assignGatherTask(items) {
        // Корректно сбрасываем переносимый предмет перед сменой задачи
        if (this.carriedItem) {
            this.carriedItem.state = 'thrown';
            this.carriedItem.vx = 0;
            this.carriedItem.vy = 0;
            this.carriedItem.vz = 0;
            this.carriedItem.stateTime = 0;
            this.carriedItem = null;
        }
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
        // Мягкая посадка после отталкивания ветром — нет урона от падения
        if (this.windPushed) {
            this.windPushed = false;
            return;
        }
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

    onSettle(items, allMinions) {
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
        // Монах возвращается к тотему
        if (this.goblinClass === 'monk') {
            this.state = 'monk_walking';
            this.stateTime = 0;
            return;
        }
        // Разведчик не собирает ресурсы — продолжает блуждать
        if (this.goblinClass === 'scout') {
            this.pickNewTarget();
            this.state = 'free';
            this.stateTime = 0;
            return;
        }
        // При приземлении проверяем ближайшего врага в радиусе AUTO_ATTACK_RADIUS — auto-attack
        if (allMinions) {
            let nearestEnemy = null, nearestEnemyDistSq = AUTO_ATTACK_RADIUS * AUTO_ATTACK_RADIUS;
            for (const m of allMinions) {
                if (m === this || !m.isUndead) continue;
                if (m.state !== 'skeleton') continue;
                const ddx = m.ix - this.ix;
                const ddy = m.iy - this.iy;
                const dSq = ddx * ddx + ddy * ddy;
                if (dSq < nearestEnemyDistSq) { nearestEnemyDistSq = dSq; nearestEnemy = m; }
            }
            if (nearestEnemy) { this.enterCombat(nearestEnemy); return; }
        }

        // При приземлении ищем ближайший ресурс в радиусе AUTO_GATHER_RADIUS
        let nearest = null, nearestDistSq = AUTO_GATHER_RADIUS * AUTO_GATHER_RADIUS;
        if (items) {
            for (const item of items) {
                if (!item.typeDef.gatherable) continue;
                if (item.state === 'carried' || item.state === 'lifting' || item.state === 'goblin_carried') continue;
                const dx = item.ix - this.ix;
                const dy = item.iy - this.iy;
                const distSq = dx * dx + dy * dy;
                if (distSq < nearestDistSq) { nearestDistSq = distSq; nearest = item; }
            }
        }
        if (nearest) {
            // Если ресурс в зоне 42×42 — после доставки продолжит сбор; снаружи — станет свободным
            this.gathererMode = Math.abs(nearest.ix - gameMap.castlePos.ix) <= GATHER_ZONE_RADIUS && Math.abs(nearest.iy - gameMap.castlePos.iy) <= GATHER_ZONE_RADIUS;
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
        if (!PHYSICS_STATES.has(this.state)) {
            this.stateTime += dt;
        }
        if (this.damageWobble > 0) this.damageWobble = Math.max(0, this.damageWobble - dt);

        // ── Тайловые эффекты (скорость, урон) ────────────────────
        this._currentSpeedMult = 1.0;
        if (!PHYSICS_STATES.has(this.state) && !this.dead && this.state !== 'crumbled') {
            const tileEff = getTileEffect(this.ix, this.iy);
            if (tileEff) {
                this._currentSpeedMult = tileEff.speedMult;
                // Урон от тайла (burning, swamp)
                if (tileEff.dps > 0) {
                    const prevHp = this.hp;
                    this.hp -= tileEff.dps * dt;
                    // Визуальная обратная связь: тряска + кровь каждые 10 HP урона
                    if (Math.floor(prevHp / 10) > Math.floor(this.hp / 10) && this.hp > 0) {
                        this.damageWobble = 0.3;
                        if (this.isUndead) {
                            this.pendingBoneEffect = { ix: this.ix, iy: this.iy };
                        } else {
                            this.pendingBloodEffect = { type: 'hit', ix: this.ix, iy: this.iy };
                        }
                    }
                    if (this.hp <= 0 && !this.dead) {
                        this.hp = 0;
                        if (this.isUndead) {
                            this.pendingBoneEffect = { ix: this.ix, iy: this.iy };
                            this.pendingRemove = true;
                            this.state = 'crumbled';
                        } else {
                            this.dead = true;
                            this.dropCarriedItem();
                            this.pendingBloodEffect = { type: 'death', ix: this.ix, iy: this.iy };
                            this.state = 'dead';
                            this.stateTime = 0;
                            this.deadTime = 0;
                        }
                        return;
                    }
                }
            }
        }

        // Разведчик стареет только в активных (не физических) состояниях.
        // В 'carried'/'lifting' возраст не растёт — чтобы не умирать в руке.
        if (this.goblinClass === 'scout' && !this.dead && !this.isUndead && !PHYSICS_STATES.has(this.state)) {
            this.scoutAge += dt;
            if (this.scoutAge >= SCOUT_LIFESPAN) {
                this.dropCarriedItem(); // не оставлять ресурс висеть в воздухе
                this.dead = true;
                this.state = 'dead';
                this.stateTime = 0;
                this.deadTime = 0;
                return;
            }
        }

        switch (this.state) {
            // ── 1. Свободен ─────────────────────────────────────────
            case 'free': {
                // Проактивный агро: свободные гоблины ищут врагов в зоне видимости
                if (this._tryAggro(allMinions)) break;

                const dx = this.targetX - this.ix;
                const dy = this.targetY - this.iy;
                if (dx * dx + dy * dy < 0.0625) {
                    this.pickNewTarget();
                } else {
                    const spd = MINION_SPEED * this._currentSpeedMult * dt;
                    this._moveToward(this.targetX, this.targetY, spd);
                }
                break;
            }

            // ── 2. Идёт к точке по команде ПКМ ─────────────────────
            case 'moving_to_point': {
                const dx = this.targetX - this.ix;
                const dy = this.targetY - this.iy;
                if (dx * dx + dy * dy < 0.0625) {
                    this.pickNewTarget();
                    this.state = 'free';
                    this.stateTime = 0;
                } else {
                    const spd = MINION_SPEED * this._currentSpeedMult * dt;
                    this._moveToward(this.targetX, this.targetY, spd);
                }
                break;
            }

            // ── 3. Занят: идёт к камню ──────────────────────────────
            case 'busy': {
                // Сборщики тоже реагируют на скелетов поблизости
                if (this._tryAggro(allMinions)) break;
                if (this.task === 'gather') {
                    // Проверяем что цель ещё доступна
                    if (!this.targetItem ||
                        this.targetItem.state === 'carried' ||
                        this.targetItem.state === 'lifting' ||
                        this.targetItem.state === 'goblin_carried' ||
                        this.targetItem.state === 'thrown' ||
                        this.targetItem.state === 'bouncing') {
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
                    const distSq = dx * dx + dy * dy;
                    const canPickUp = this.targetItem.state === 'idle' ||
                                      this.targetItem.state === 'settling' ||
                                      this.targetItem.state === 'sliding';
                    if (distSq < 0.36 && canPickUp) {
                        // Поднять ресурс; если он снаружи зоны 42×42 — после доставки станем свободным
                        this.gathererMode = this.gathererMode &&
                            Math.abs(this.targetItem.ix - gameMap.castlePos.ix) <= GATHER_ZONE_RADIUS &&
                            Math.abs(this.targetItem.iy - gameMap.castlePos.iy) <= GATHER_ZONE_RADIUS;
                        this.targetItem.state = 'goblin_carried';
                        this.targetItem.vx = 0;
                        this.targetItem.vy = 0;
                        this.targetItem.vz = 0;
                        this.carriedItem = this.targetItem;
                        this.targetItem = null;
                        this.state = 'returning';
                        this.stateTime = 0;
                    } else if (distSq > 0.000001) {
                        const spd = MINION_SPEED * this._currentSpeedMult * dt;
                        this._moveToward(this.targetItem.ix, this.targetItem.iy, spd);
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
                    const threshold = castle.baseRadius + this.radius;
                    if (dx * dx + dy * dy < threshold * threshold) {
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
                        const spd = MINION_SPEED * this._currentSpeedMult * dt;
                        this._moveToward(castle.ix, castle.iy, spd);
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
                if (ddx * ddx + ddy * ddy <= atkRange * atkRange) {
                    this.state = 'fighting';
                    this.stateTime = 0;
                } else {
                    const spd = MINION_SPEED * this._currentSpeedMult * dt;
                    this._moveToward(this.combatTarget.ix, this.combatTarget.iy, spd);
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

                if (ddx * ddx + ddy * ddy > atkRange * atkRange * 4) {
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
                        const spd = Math.min(MINION_SPEED * this._currentSpeedMult * dt, d);
                        this._moveToward(this.guardX, this.guardY, spd);
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
                    const spd = Math.min(MINION_SPEED * this._currentSpeedMult * dt, d);
                    this._moveToward(this.guardX, this.guardY, spd);
                }
                break;
            }

            // ── Монах: идёт к тотему ─────────────────────────────────
            case 'monk_walking': {
                if (this.totemX === null) break; // тотем ещё не установлен
                const dx = this.totemX - this.ix;
                const dy = this.totemY - this.iy;
                if (dx * dx + dy * dy < 1.0) {
                    this.state = 'monk_praying';
                    this.stateTime = 0;
                } else {
                    const spd = MINION_SPEED * this._currentSpeedMult * dt;
                    this._moveToward(this.totemX, this.totemY, spd);
                }
                break;
            }

            // ── Монах: молится у тотема ──────────────────────────────
            case 'monk_praying': {
                if (this.totemX !== null) {
                    const dx = this.totemX - this.ix;
                    const dy = this.totemY - this.iy;
                    if (dx * dx + dy * dy > 4.0) { // > 2 тайлов от тотема
                        this.state = 'monk_walking';
                        this.stateTime = 0;
                    }
                }
                // Мана восстанавливается в main.js подсчётом monk_praying гоблинов
                break;
            }

            case 'settling':
                if (this.stateTime > 0.3) {
                    this.onSettle(items, allMinions);
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
                let prey = null, preyDistSq = SKELETON_AGGRO_RANGE * SKELETON_AGGRO_RANGE;
                if (allMinions) {
                    for (const m of allMinions) {
                        if (m === this) continue;
                        if (m.isUndead || m.dead) continue;
                        if (m.state === 'carried' || m.state === 'lifting') continue;
                        // Пар скрывает гоблинов от скелетов
                        if (gameMap.getTile(Math.round(m.ix), Math.round(m.iy)) === 'steam') continue;
                        const ddx = m.ix - this.ix;
                        const ddy = m.iy - this.iy;
                        const dSq = ddx * ddx + ddy * ddy;
                        if (dSq < preyDistSq) {
                            preyDistSq = dSq;
                            prey = m;
                        }
                    }
                }

                if (prey && preyDistSq <= SKELETON_ATTACK_RANGE * SKELETON_ATTACK_RANGE) {
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
                            if (rdx * rdx + rdy * rdy <= rallyRange * rallyRange) {
                                m.enterCombat(this);
                            }
                        }
                    }
                } else if (prey) {
                    // Есть цель — идём к ней
                    const spd = MINION_SPEED * SKELETON_SPEED_FACTOR * this._currentSpeedMult * dt;
                    this._moveToward(prey.ix, prey.iy, spd);
                } else {
                    // Нет цели — свободное блуждание по карте
                    const dx = this.targetX - this.ix;
                    const dy = this.targetY - this.iy;
                    if (dx * dx + dy * dy < 0.0625) {
                        this.pickNewTarget();
                    } else {
                        const spd = MINION_SPEED * SKELETON_SPEED_FACTOR * this._currentSpeedMult * dt;
                        this._moveToward(this.targetX, this.targetY, spd);
                    }
                }
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

        // Покачивание монаха во время молитвы
        let praySwayX = 0;
        if (this.state === 'monk_praying') {
            praySwayX = Math.sin(performance.now() / 700 + index * 1.7) * 2;
        }

        const ox = s.x - (sprW * PIXEL_SCALE) / 2 + hitOffsetX + praySwayX;
        const oy = s.y - (sprH * PIXEL_SCALE) - 4 - heightOffset + hitOffsetY;

        // Рамка выделения — только для живых гоблинов
        if (!this.isUndead && hand.selectedMinions.includes(index)) {
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

        // Капюшон разведчика — накладывается поверх головы живого (не скелет) гоблина-разведчика
        if (this.goblinClass === 'scout' && !this.isUndead) {
            const hoodOx = Math.round(ox + (sprW - SCOUT_HOOD_W) / 2 * PIXEL_SCALE);
            drawPixelArt(hoodOx, oy, SCOUT_HOOD_PIXELS, PIXEL_SCALE);
        }

        // Балахон монаха — накладывается поверх головы живого гоблина-монаха
        if (this.goblinClass === 'monk' && !this.isUndead) {
            const robeOx = Math.round(ox + (sprW - MONK_ROBE_W) / 2 * PIXEL_SCALE);
            drawPixelArt(robeOx, oy, MONK_ROBE_PIXELS, PIXEL_SCALE);
        }
    }
}
