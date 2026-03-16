// ============================================================
//  РЕНДЕРЕР — canvas, ctx и все функции отрисовки примитивов
// ============================================================
import { TILE_W, TILE_H, PIXEL_SCALE } from './constants.js';

export const canvas = document.getElementById('game');
export const ctx = canvas.getContext('2d');

export function resize() {
    canvas.width = window.innerWidth;
    canvas.height = window.innerHeight;
}

// Пиксельный рендер (без сглаживания)
ctx.imageSmoothingEnabled = false;

// ============================================================
//  РИСОВАНИЕ ПИКСЕЛЕЙ
// ============================================================
export function drawPixel(x, y, color, scale = PIXEL_SCALE) {
    ctx.fillStyle = color;
    ctx.fillRect(Math.floor(x), Math.floor(y), scale, scale);
}

// Кэш спрайтов: pixels array → Map(scale → {img, w, h})
const _spriteCache = new Map();

function _renderSpriteToCache(pixels, scale) {
    // Определяем bounds спрайта
    let maxX = 0, maxY = 0;
    for (const p of pixels) {
        if (p[0] + 1 > maxX) maxX = p[0] + 1;
        if (p[1] + 1 > maxY) maxY = p[1] + 1;
    }
    const w = maxX * scale;
    const h = maxY * scale;

    const offCanvas = document.createElement('canvas');
    offCanvas.width = w;
    offCanvas.height = h;
    const offCtx = offCanvas.getContext('2d');

    for (const p of pixels) {
        if (!p[2]) continue;
        offCtx.fillStyle = p[2];
        offCtx.fillRect(p[0] * scale, p[1] * scale, scale, scale);
    }

    return { img: offCanvas, w, h };
}

export function drawPixelArt(screenX, screenY, pixels, scale = PIXEL_SCALE) {
    let scaleMap = _spriteCache.get(pixels);
    if (!scaleMap) {
        scaleMap = new Map();
        _spriteCache.set(pixels, scaleMap);
    }
    let cached = scaleMap.get(scale);
    if (!cached) {
        cached = _renderSpriteToCache(pixels, scale);
        scaleMap.set(scale, cached);
    }
    ctx.drawImage(cached.img, Math.floor(screenX), Math.floor(screenY));
}

export function clearSpriteCache() {
    _spriteCache.clear();
}

export function drawIsoDiamond(cx, cy, fillColor, strokeColor) {
    ctx.beginPath();
    ctx.moveTo(cx, cy - TILE_H / 2);
    ctx.lineTo(cx + TILE_W / 2, cy);
    ctx.lineTo(cx, cy + TILE_H / 2);
    ctx.lineTo(cx - TILE_W / 2, cy);
    ctx.closePath();
    ctx.fillStyle = fillColor;
    ctx.fill();
    ctx.strokeStyle = strokeColor;
    ctx.lineWidth = 1;
    ctx.stroke();
}

// ============================================================
//  ТЕНЬ (с учётом высоты)
// ============================================================
export function drawShadow(sx, sy, w, h) {
    ctx.save();
    ctx.globalAlpha = 0.25;
    ctx.fillStyle = '#000';
    ctx.beginPath();
    ctx.ellipse(sx, sy + 8, w * PIXEL_SCALE * 0.5, h * PIXEL_SCALE * 0.2, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
}

export function drawItemShadow(sx, sy, w, h, height) {
    ctx.save();
    const heightFactor = 1 / (1 + height * 0.8);
    const alpha = 0.25 * heightFactor;
    const scaleW = w * PIXEL_SCALE * 0.5 * heightFactor;
    const scaleH = h * PIXEL_SCALE * 0.2 * heightFactor;

    ctx.globalAlpha = Math.max(alpha, 0.05);
    ctx.fillStyle = '#000';
    ctx.beginPath();
    ctx.ellipse(sx, sy + 8, Math.max(scaleW, 3), Math.max(scaleH, 1.5), 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
}

// ============================================================
//  ПОДСВЕТКА
// ============================================================
export function drawHighlight(sx, sy, w, h) {
    ctx.save();
    const time = performance.now() / 500;
    ctx.globalAlpha = 0.3 + 0.15 * Math.sin(time);
    ctx.strokeStyle = '#ffff44';
    ctx.lineWidth = 2;
    const pw = w * PIXEL_SCALE;
    const ph = h * PIXEL_SCALE;
    ctx.strokeRect(sx - 4, sy - 4, pw + 8, ph + 8);
    ctx.restore();
}
