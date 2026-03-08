// ============================================================
//  БАЗОВЫЙ КЛАСС — общая физика для предметов и миньонов
// ============================================================
import {
    GRAVITY, CARRY_HEIGHT, LIFT_SPEED, BOUNCE_MIN_VZ, MAX_BOUNCES,
    SLIDE_STOP, AIR_RESISTANCE, GRID_SIZE, WALL_BOUNCE
} from './constants.js';

export class GameObject {
    constructor(ix, iy, mass, bounciness, friction) {
        this.ix = ix;
        this.iy = iy;
        this.iz = 0;
        this.vx = 0;
        this.vy = 0;
        this.vz = 0;
        this.state = 'idle';
        this.stateTime = 0;
        this.liftProgress = 0;
        this.bounceCount = 0;
        this.mass = mass;
        this.bounciness = bounciness;
        this.friction = friction;
    }

    clampToGrid() {
        const limit = GRID_SIZE + 0.5; // чуть за краем тайлов
        if (this.ix < -limit) {
            this.ix = -limit;
            this.vx = Math.abs(this.vx) * WALL_BOUNCE;
        } else if (this.ix > limit) {
            this.ix = limit;
            this.vx = -Math.abs(this.vx) * WALL_BOUNCE;
        }
        if (this.iy < -limit) {
            this.iy = -limit;
            this.vy = Math.abs(this.vy) * WALL_BOUNCE;
        } else if (this.iy > limit) {
            this.iy = limit;
            this.vy = -Math.abs(this.vy) * WALL_BOUNCE;
        }
    }

    // Хуки — переопределяются в подклассах
    onLand(impactVz) {}   // вызывается при касании земли
    onSettle() {}         // вызывается после таймаута settling

    updatePhysics(dt, hand, triggerShake) {
        this.stateTime += dt;

        switch (this.state) {
            case 'lifting': {
                this.liftProgress += LIFT_SPEED * dt;
                if (this.liftProgress >= 1.0) {
                    this.liftProgress = 1.0;
                    this.state = 'carried';
                    this.stateTime = 0;
                }
                const t = 1 - Math.pow(1 - this.liftProgress, 2);
                this.iz = t * CARRY_HEIGHT;
                this.ix += (hand.isoX - this.ix) * Math.min(1, dt * 10);
                this.iy += (hand.isoY - this.iy) * Math.min(1, dt * 10);
                break;
            }

            case 'carried':
                this.ix = hand.isoX;
                this.iy = hand.isoY;
                this.iz = CARRY_HEIGHT;
                break;

            case 'thrown':
            case 'bouncing': {
                this.vz -= GRAVITY * dt;
                this.ix += this.vx * dt;
                this.iy += this.vy * dt;
                this.iz += this.vz * dt;

                // Лёгкое сопротивление воздуха (frame-rate независимо)
                const airFactor = Math.pow(AIR_RESISTANCE, dt * 60);
                this.vx *= airFactor;
                this.vy *= airFactor;

                // Отскок от стен
                this.clampToGrid();

                if (this.iz <= 0) {
                    this.iz = 0;
                    const impactVz = Math.abs(this.vz);

                    // Хук приземления (для урона миньонам)
                    this.onLand(impactVz);

                    if (impactVz > BOUNCE_MIN_VZ && this.bounceCount < MAX_BOUNCES) {
                        // Отскок
                        if (this.bounceCount === 0) {
                            triggerShake(this.mass * impactVz * 0.5);
                        }
                        this.vz = -this.vz * this.bounciness;
                        this.vx *= this.friction;
                        this.vy *= this.friction;
                        this.bounceCount++;
                        this.state = 'bouncing';
                        this.stateTime = 0;
                    } else {
                        this.vz = 0;
                        this.iz = 0;
                        const hSpeed = Math.sqrt(this.vx * this.vx + this.vy * this.vy);
                        if (hSpeed > SLIDE_STOP) {
                            this.state = 'sliding';
                        } else {
                            this.vx = 0;
                            this.vy = 0;
                            this.state = 'settling';
                        }
                        this.stateTime = 0;
                    }
                }
                break;
            }

            case 'sliding': {
                this.iz = 0;
                this.vz = 0;

                const frictionFactor = Math.pow(this.friction, dt * 5);
                this.vx *= frictionFactor;
                this.vy *= frictionFactor;

                this.ix += this.vx * dt;
                this.iy += this.vy * dt;

                // Отскок от стен
                this.clampToGrid();

                const hSpeed = Math.sqrt(this.vx * this.vx + this.vy * this.vy);
                if (hSpeed < SLIDE_STOP) {
                    this.vx = 0;
                    this.vy = 0;
                    this.state = 'settling';
                    this.stateTime = 0;
                }
                break;
            }
        }
    }
}
