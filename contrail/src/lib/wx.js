'use strict';
// Weather helpers shared by services: flight category and unit conversions.
function parseVisibilitySm(value) {
  if (value == null) return null;
  if (typeof value === 'number') return value;
  const text = String(value).replace('+', '').trim();
  if (text.includes('/')) { const [n, d] = text.split('/').map(Number); return n / d; }
  return Number(text);
}

/** Lowest broken/overcast/vertical-visibility layer, in feet AGL (null = no ceiling). */
function ceilingFt(clouds = [], vertVis) {
  const layers = clouds.filter((c) => ['BKN', 'OVC', 'OVX'].includes(c.cover) && c.base != null).map((c) => c.base);
  if (vertVis != null) layers.push(vertVis * 100);
  return layers.length ? Math.min(...layers) : null;
}

function flightCategory(visSm, ceiling) {
  const v = visSm ?? 10, c = ceiling ?? Infinity;
  if (c < 500 || v < 1) return 'LIFR';
  if (c < 1000 || v < 3) return 'IFR';
  if (c <= 3000 || v <= 5) return 'MVFR';
  return 'VFR';
}

const CATEGORY_RANK = { VFR: 0, MVFR: 1, IFR: 2, LIFR: 3 };
const hpaToInHg = (hpa) => Math.round(hpa * 0.02953 * 100) / 100;

module.exports = { parseVisibilitySm, ceilingFt, flightCategory, CATEGORY_RANK, hpaToInHg };
