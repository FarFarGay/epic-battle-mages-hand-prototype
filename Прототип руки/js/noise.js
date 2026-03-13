// ============================================================
//  SIMPLEX NOISE 2D — детерминированный по seed
// ============================================================

const F2 = 0.5 * (Math.sqrt(3.0) - 1.0);
const G2 = (3.0 - Math.sqrt(3.0)) / 6.0;

// 12 градиентных направлений для 2D
const GRAD3 = [
    [1, 1], [-1, 1], [1, -1], [-1, -1],
    [1, 0], [-1, 0], [1, 0],  [-1, 0],
    [0, 1], [0, -1], [0, 1],  [0, -1],
];

export class SimplexNoise {
    constructor(seed = 0) {
        const p = new Uint8Array(256);
        for (let i = 0; i < 256; i++) p[i] = i;

        // xorshift32 PRNG для тасования
        let s = (seed >>> 0) || 1337;
        const rand = () => {
            s ^= s << 13; s >>>= 0;
            s ^= s >>> 17;
            s ^= s << 5;  s >>>= 0;
            return s / 4294967296;
        };

        // Fisher-Yates shuffle
        for (let i = 255; i > 0; i--) {
            const j = Math.floor(rand() * (i + 1));
            const tmp = p[i]; p[i] = p[j]; p[j] = tmp;
        }

        this._perm = new Uint8Array(512);
        this._grad = new Array(512);
        for (let i = 0; i < 512; i++) {
            this._perm[i] = p[i & 255];
            this._grad[i] = GRAD3[this._perm[i] % 12];
        }
    }

    noise2D(xin, yin) {
        let n0, n1, n2;

        // Смещаем входное пространство
        const s  = (xin + yin) * F2;
        const i  = Math.floor(xin + s);
        const j  = Math.floor(yin + s);
        const t  = (i + j) * G2;

        // Первый угол симплекса
        const x0 = xin - (i - t);
        const y0 = yin - (j - t);

        // Определяем какой из двух симплексов (треугольников) содержит точку
        let i1, j1;
        if (x0 > y0) { i1 = 1; j1 = 0; }
        else          { i1 = 0; j1 = 1; }

        // Второй и третий углы
        const x1 = x0 - i1 + G2;
        const y1 = y0 - j1 + G2;
        const x2 = x0 - 1.0 + 2.0 * G2;
        const y2 = y0 - 1.0 + 2.0 * G2;

        // Индексы градиентов
        const ii  = i & 255;
        const jj  = j & 255;
        const gi0 = this._grad[ii      + this._perm[jj]];
        const gi1 = this._grad[ii + i1 + this._perm[jj + j1]];
        const gi2 = this._grad[ii + 1  + this._perm[jj + 1]];

        // Вклад каждого угла
        let t0 = 0.5 - x0 * x0 - y0 * y0;
        if (t0 < 0) {
            n0 = 0;
        } else {
            t0 *= t0;
            n0 = t0 * t0 * (gi0[0] * x0 + gi0[1] * y0);
        }

        let t1 = 0.5 - x1 * x1 - y1 * y1;
        if (t1 < 0) {
            n1 = 0;
        } else {
            t1 *= t1;
            n1 = t1 * t1 * (gi1[0] * x1 + gi1[1] * y1);
        }

        let t2 = 0.5 - x2 * x2 - y2 * y2;
        if (t2 < 0) {
            n2 = 0;
        } else {
            t2 *= t2;
            n2 = t2 * t2 * (gi2[0] * x2 + gi2[1] * y2);
        }

        // Масштабируем к [-1, 1]
        return 70.0 * (n0 + n1 + n2);
    }
}

// ============================================================
//  FRACTAL BROWNIAN MOTION (многооктавный шум)
// ============================================================
export function fbm(noise, x, y, octaves = 4, lacunarity = 2.0, gain = 0.5) {
    let value = 0, amplitude = 1, frequency = 1, maxValue = 0;
    for (let i = 0; i < octaves; i++) {
        value    += noise.noise2D(x * frequency, y * frequency) * amplitude;
        maxValue += amplitude;
        amplitude  *= gain;
        frequency  *= lacunarity;
    }
    return value / maxValue; // нормализовано в [-1, 1]
}

// ============================================================
//  SEEDED PRNG (mulberry32) — для генератора карты
// ============================================================
export function createRNG(seed) {
    let s = (seed ^ 0xdeadbeef) >>> 0;
    if (s === 0) s = 1;
    return function () {
        s  |= 0;
        s   = s + 0x6D2B79F5 | 0;
        let t = Math.imul(s ^ (s >>> 15), 1 | s);
        t = t + Math.imul(t ^ (t >>> 7), 61 | t) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}
