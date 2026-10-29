'use strict';
// Spherical-earth navigation maths. Distances in nautical miles, angles in degrees.
const R_NM = 3440.065;
const rad = (d) => (d * Math.PI) / 180;
const deg = (r) => (r * 180) / Math.PI;
const norm360 = (d) => ((d % 360) + 360) % 360;

function distanceNm(a, b) {
  const dLat = rad(b.lat - a.lat), dLon = rad(b.lon - a.lon);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R_NM * Math.asin(Math.min(1, Math.sqrt(h)));
}

function initialCourse(a, b) {
  const y = Math.sin(rad(b.lon - a.lon)) * Math.cos(rad(b.lat));
  const x = Math.cos(rad(a.lat)) * Math.sin(rad(b.lat)) - Math.sin(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.cos(rad(b.lon - a.lon));
  return norm360(deg(Math.atan2(y, x)));
}

function interpolate(a, b, fraction) {
  const d = distanceNm(a, b) / R_NM;
  if (d === 0) return { ...a };
  const A = Math.sin((1 - fraction) * d) / Math.sin(d), B = Math.sin(fraction * d) / Math.sin(d);
  const x = A * Math.cos(rad(a.lat)) * Math.cos(rad(a.lon)) + B * Math.cos(rad(b.lat)) * Math.cos(rad(b.lon));
  const y = A * Math.cos(rad(a.lat)) * Math.sin(rad(a.lon)) + B * Math.cos(rad(b.lat)) * Math.sin(rad(b.lon));
  const z = A * Math.sin(rad(a.lat)) + B * Math.sin(rad(b.lat));
  return { lat: deg(Math.atan2(z, Math.hypot(x, y))), lon: deg(Math.atan2(y, x)) };
}

/** Cross-track (perpendicular) and along-track distance of `p` relative to the great circle a->b. */
function trackDistances(a, b, p) {
  const d13 = distanceNm(a, p) / R_NM;
  const t13 = rad(initialCourse(a, p)), t12 = rad(initialCourse(a, b));
  const xt = Math.asin(Math.sin(d13) * Math.sin(t13 - t12));
  const at = Math.acos(Math.min(1, Math.max(-1, Math.cos(d13) / Math.cos(xt))));
  return { crossTrackNm: Math.abs(xt) * R_NM, alongTrackNm: at * R_NM * (Math.cos(t13 - t12) < 0 ? -1 : 1) };
}

/** Wind triangle: true heading, ground speed and wind-correction angle. */
function windTriangle(courseDeg, tasKt, windFromDeg, windKt) {
  const wca = deg(Math.asin(Math.max(-1, Math.min(1, (windKt / tasKt) * Math.sin(rad(windFromDeg - courseDeg))))));
  const heading = norm360(courseDeg + wca);
  const gs = tasKt * Math.cos(rad(wca)) - windKt * Math.cos(rad(windFromDeg - courseDeg));
  return { heading, wcaDeg: wca, groundSpeedKt: Math.max(30, gs) };
}

function crosswindComponents(runwayHeadingDeg, windFromDeg, windKt) {
  const angle = rad(windFromDeg - runwayHeadingDeg);
  return { headwindKt: windKt * Math.cos(angle), crosswindKt: Math.abs(windKt * Math.sin(angle)) };
}

/** Runway designators from a magnetic heading, e.g. 100 -> ['10', '28']. */
function runwayIds(heading) {
  const a = Math.max(1, Math.round(heading / 10) % 36 || 36);
  const b = ((a + 18 - 1) % 36) + 1;
  const pad = (n) => String(n).padStart(2, '0');
  return [pad(Math.min(a, b)), pad(Math.max(a, b))];
}

/** Sunrise/sunset in UTC ms for the date of `when` (NOAA approximation, good to ~1 min). */
function sunTimes(lat, lon, when) {
  const day = Date.UTC(when.getUTCFullYear(), when.getUTCMonth(), when.getUTCDate());
  const n = Math.floor((day - Date.UTC(when.getUTCFullYear(), 0, 0)) / 86400000);
  const gamma = (2 * Math.PI / 365) * (n - 1);
  const eqTime = 229.18 * (0.000075 + 0.001868 * Math.cos(gamma) - 0.032077 * Math.sin(gamma) - 0.014615 * Math.cos(2 * gamma) - 0.040849 * Math.sin(2 * gamma));
  const decl = 0.006918 - 0.399912 * Math.cos(gamma) + 0.070257 * Math.sin(gamma) - 0.006758 * Math.cos(2 * gamma) + 0.000907 * Math.sin(2 * gamma);
  const cosH = (Math.cos(rad(90.833)) / (Math.cos(rad(lat)) * Math.cos(decl))) - Math.tan(rad(lat)) * Math.tan(decl);
  if (cosH > 1) return { polar: 'night' };
  if (cosH < -1) return { polar: 'day' };
  const ha = deg(Math.acos(cosH));
  const sunrise = day + (720 - 4 * (lon + ha) - eqTime) * 60000;
  const sunset = day + (720 - 4 * (lon - ha) - eqTime) * 60000;
  return { sunrise, sunset };
}

module.exports = { distanceNm, initialCourse, interpolate, trackDistances, windTriangle, crosswindComponents, runwayIds, sunTimes, norm360 };
