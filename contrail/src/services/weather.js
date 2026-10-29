'use strict';
// weather: METAR, TAF and winds aloft from aviationweather.gov, behind a Postgres read-through cache.
// There is no fallback: if the provider fails (after one retry), the request fails.
const { SpanKind, ROOT_CONTEXT, context, trace } = require('@opentelemetry/api');
const { createService, AppError, PORTS } = require('../lib/http');
const { withSpan, spanSync, tracer, meter, durationHistogram, log } = require('../lib/otel');
const { query } = require('../lib/pg');
const cache = require('../lib/cache');
const { sleep, between, createFaults } = require('../lib/sim');
const { distanceNm } = require('../lib/geo');
const { parseVisibilitySm, ceilingFt, flightCategory, hpaToInHg } = require('../lib/wx');

const faults = createFaults({ upstream: 'ok' }); // ok | slow | failing
const BASE = process.env.WEATHER_BASE_URL || 'https://aviationweather.gov/api/data';
const TTL = { metar: 600, taf: 1800, winds: 3600, negative: 300 };

const upstreamRequests = meter.createCounter('contrail.upstream.requests', { description: 'Calls to external data providers.', unit: '{request}' });
const upstreamDuration = durationHistogram('contrail.upstream.duration', 'Latency of external data providers.');
const categories = meter.createCounter('contrail.weather.reports', { description: 'Decoded METARs by flight category.', unit: '{report}' });

// --- upstream ------------------------------------------------------------------------------------

async function fetchUpstream(path, params, { text = false, attributes = {} } = {}) {
  const url = `${BASE}/${path}?${new URLSearchParams(params)}`;
  for (let attempt = 1; ; attempt++) {
    const started = performance.now();
    try {
      return await withSpan('weather.upstream.request', {
        kind: SpanKind.CLIENT,
        attributes: { 'peer.service': 'aviationweather.gov', 'url.template': `/api/data/${path}`, 'http.request.resend_count': attempt - 1, ...attributes },
      }, async (span) => {
        if (faults.get('upstream') === 'slow') await sleep(2500);
        if (faults.get('upstream') === 'failing') throw new Error('injected upstream failure');
        const response = await fetch(url, { signal: AbortSignal.timeout(8000), headers: { 'user-agent': 'contrail-demo/1.0' } });
        span.setAttribute('http.response.status_code', response.status);
        if (response.status === 204) return text ? '' : [];
        if (!response.ok) throw new Error(`aviationweather.gov returned ${response.status}`);
        const body = text ? await response.text() : await response.json();
        upstreamRequests.add(1, { 'peer.service': 'aviationweather.gov', outcome: 'ok' });
        return body;
      });
    } catch (error) {
      upstreamRequests.add(1, { 'peer.service': 'aviationweather.gov', outcome: 'error' });
      if (attempt >= 2) throw new AppError(502, 'weather_unavailable', `Weather provider failed: ${error.message}`, { expected: false });
      log.warn('Weather upstream failed, retrying', { 'url.template': `/api/data/${path}`, 'exception.message': error.message });
      await withSpan('weather.retry_backoff', { attributes: { 'retry.attempt': attempt } }, () => sleep(150 * between(0.8, 1.4)));
    } finally {
      upstreamDuration.record((performance.now() - started) / 1000, { 'peer.service': 'aviationweather.gov', 'url.template': `/api/data/${path}` });
    }
  }
}

// --- METAR / TAF ---------------------------------------------------------------------------------

function decodeMetar(m) {
  const clouds = (m.clouds ?? []).map((c) => ({ cover: c.cover, base: c.base }));
  const visibilitySm = parseVisibilitySm(m.visib), ceiling = ceilingFt(clouds);
  return {
    icao: m.icaoId, available: true, source: 'aviationweather.gov', raw: m.rawOb, observedAt: new Date(m.obsTime * 1000).toISOString(),
    windDir: typeof m.wdir === 'number' ? m.wdir : null, windKt: m.wspd ?? 0, gustKt: m.wgst ?? null, visibilitySm, clouds, ceilingFt: ceiling,
    tempC: m.temp, dewpointC: m.dewp, altimeterInHg: m.altim ? hpaToInHg(m.altim) : null, weather: m.wxString ?? null,
    flightCategory: m.fltCat ?? flightCategory(visibilitySm, ceiling),
  };
}

function decodeTaf(t) {
  const periods = (t.fcsts ?? []).map((f) => {
    const clouds = (f.clouds ?? []).map((c) => ({ cover: c.cover, base: c.base }));
    const visibilitySm = parseVisibilitySm(f.visib), ceiling = ceilingFt(clouds, f.vertVis);
    return { from: new Date(f.timeFrom * 1000).toISOString(), to: new Date(f.timeTo * 1000).toISOString(), windDir: typeof f.wdir === 'number' ? f.wdir : null, windKt: f.wspd ?? 0,
      gustKt: f.wgst ?? null, visibilitySm, ceilingFt: ceiling, weather: f.wxString ?? null, flightCategory: flightCategory(visibilitySm, ceiling) };
  });
  return { icao: t.icaoId, available: true, source: 'aviationweather.gov', raw: t.rawTAF, issuedAt: t.issueTime, periods };
}

async function lookup(kind, ids) {
  ids = [...new Set(ids.map((i) => i.toUpperCase()))].slice(0, 40);
  const cached = await cache.getMany(kind, ids.map((id) => `${kind}:${id}`));
  const reports = {}, toFetch = [];
  let hits = 0;
  for (const id of ids) {
    const entry = cached.get(`${kind}:${id}`);
    if (entry?.fresh) { reports[id] = { ...entry.payload, cache: 'hit' }; hits++; } else toFetch.push(id);
  }
  if (toFetch.length) {
    const fetched = await fetchUpstream(kind, { ids: toFetch.join(','), format: 'json' }, { attributes: { 'app.weather.kind': kind, 'app.weather.stations': toFetch.length } });
    const decode = kind === 'metar' ? decodeMetar : decodeTaf;
    const byId = new Map(fetched.map((r) => [r.icaoId, decode(r)]));
    const writes = toFetch.map((id) => ({ key: `${kind}:${id}`, payload: byId.get(id) ?? { icao: id, available: false, source: 'aviationweather.gov', note: 'No report issued for this station' } }));
    for (const w of writes) reports[w.payload.icao] = { ...w.payload, cache: 'miss' };
    await cache.putMany(kind, writes.filter((w) => w.payload.available), TTL[kind]);
    await cache.putMany(kind, writes.filter((w) => !w.payload.available), TTL.negative); // negative caching
  }
  if (kind === 'metar') for (const r of Object.values(reports)) if (r.available) categories.add(1, { 'app.weather.flight_category': r.flightCategory });
  return { reports, cache: { hits, misses: toFetch.length, stale: 0, requested: ids.length } };
}

// --- winds aloft ---------------------------------------------------------------------------------

const LEVELS = [3000, 6000, 9000, 12000, 18000, 24000, 30000, 34000, 39000];
const FIELD = [[4, 8], [9, 16], [17, 24], [25, 32], [33, 40], [41, 48], [49, 55], [56, 62], [63, 69]]; // fixed-width columns of the FD table

/** Decode "2112+14", "9900" (light & variable), "7312-20" (direction +50 = 100+ kt), "244537" (temp negative implied aloft). */
function decodeWind(field, level) {
  const f = field.trim();
  if (f.length < 4) return null;
  if (f.startsWith('9900')) return { dir: 0, speedKt: 0, tempC: f.length > 4 ? Number(f.slice(4)) : null };
  let dir = Number(f.slice(0, 2)) * 10, speed = Number(f.slice(2, 4));
  if (dir >= 510) { dir -= 500; speed += 100; }
  let tempC = null;
  if (f.length >= 7) tempC = Number(f.slice(4));
  else if (f.length === 6) tempC = -Number(f.slice(4));
  return Number.isNaN(dir) || Number.isNaN(speed) ? null : { dir: dir || 360, speedKt: speed, tempC };
}

function parseWindTable(text) {
  return spanSync('weather.winds.parse', (span) => {
    const stations = {};
    for (const line of text.split('\n')) {
      if (!/^[A-Z]{3}\s/.test(line + ' ')) continue;
      const code = line.slice(0, 3);
      if (code === 'FT ') continue;
      const levels = {};
      FIELD.forEach(([a, b], i) => { const w = decodeWind(line.slice(a, b), LEVELS[i]); if (w) levels[LEVELS[i]] = w; });
      if (Object.keys(levels).length) stations[code] = levels;
    }
    span.setAttribute('app.winds.stations', Object.keys(stations).length);
    return stations;
  });
}

/** The wind-forecast table plus station coordinates (looked up by the airports service), cached as one entry. */
async function windGrid(forecastHours) {
  const key = `winds:grid:${forecastHours}`;
  const cached = await cache.getMany('winds', [key]);
  if (cached.get(key)?.fresh) return cached.get(key).payload;
  const text = await fetchUpstream('windtemp', { region: 'all', level: 'low', fcst: String(forecastHours).padStart(2, '0') }, { text: true, attributes: { 'app.weather.kind': 'winds', 'app.winds.forecast_hours': forecastHours } });
  const table = parseWindTable(text);
  const codes = Object.keys(table);
  // Station coordinates in one bulk call; stations the API does not know (Pacific/Alaska prefixes) are simply absent.
  const info = await fetchUpstream('stationinfo', { ids: codes.map((c) => `K${c}`).join(','), format: 'json' }, { attributes: { 'app.weather.kind': 'stationinfo', 'app.weather.stations': codes.length } });
  const grid = {
    forecastHours, fetchedAt: new Date().toISOString(), validLine: (text.match(/VALID [^\n]+/) ?? [''])[0].trim(),
    stations: info.map((a) => ({ code: a.icaoId, lat: a.lat, lon: a.lon, levels: table[a.icaoId.slice(1)] })).filter((s) => s.levels && s.lat != null),
  };
  await cache.putMany('winds', [{ key, payload: grid }], TTL.winds);
  return grid;
}

/** Inverse-distance-weighted vector average of the nearest stations, interpolated between the two bracketing levels. */
function windAt(grid, lat, lon, altFt) {
  const near = grid.stations.map((s) => ({ s, d: distanceNm({ lat, lon }, s) })).sort((a, b) => a.d - b.d).slice(0, 4);
  if (!near.length || near[0].d > 400) throw new AppError(502, 'no_wind_data', `No winds-aloft station within 400 nm of ${lat.toFixed(1)}, ${lon.toFixed(1)}`, { expected: false });
  const at = (level) => {
    let u = 0, v = 0, t = 0, tw = 0, w = 0;
    for (const { s, d } of near) {
      const x = s.levels[level]; if (!x) continue;
      const weight = 1 / Math.max(d, 5) ** 2, rad = (x.dir * Math.PI) / 180;
      u += -Math.sin(rad) * x.speedKt * weight; v += -Math.cos(rad) * x.speedKt * weight; w += weight;
      if (x.tempC != null) { t += x.tempC * weight; tw += weight; }
    }
    return w ? { u: u / w, v: v / w, tempC: tw ? t / tw : null } : null;
  };
  const lower = [...LEVELS].reverse().find((l) => l <= altFt) ?? LEVELS[0], upper = LEVELS.find((l) => l >= altFt) ?? LEVELS.at(-1);
  const a = at(lower) ?? at(upper), b = at(upper) ?? a;
  if (!a) throw new AppError(502, 'no_wind_data', 'Winds aloft table has no data at this altitude', { expected: false });
  const f = upper === lower ? 0 : (altFt - lower) / (upper - lower);
  const u = a.u + (b.u - a.u) * f, v = a.v + (b.v - a.v) * f;
  const tempC = a.tempC == null ? null : a.tempC + ((b.tempC ?? a.tempC) - a.tempC) * f;
  return { dir: Math.round(((Math.atan2(-u, -v) * 180) / Math.PI + 360) % 360) || 360, speedKt: Math.round(Math.hypot(u, v)), tempC: tempC == null ? null : Math.round(tempC) };
}

async function winds(points, when) {
  const hoursAhead = (when.getTime() - Date.now()) / 3600000;
  const forecastHours = hoursAhead <= 9 ? 6 : hoursAhead <= 18 ? 12 : 24;
  const grid = await windGrid(forecastHours);
  return spanSync('weather.winds.interpolate', { attributes: { 'app.winds.points': points.length, 'app.winds.stations': grid.stations.length, 'app.winds.forecast_hours': forecastHours } }, () =>
    ({ valid: grid.validLine, winds: points.map((p) => ({ ...windAt(grid, p.lat, p.lon, p.altFt), lat: p.lat, lon: p.lon, altFt: p.altFt, source: 'aviationweather.gov' })) }));
}

createService({
  name: 'weather', port: PORTS.weather, faults,
  routes: [
    ['GET', '/metar', ({ query: q }) => lookup('metar', (q.get('ids') ?? '').split(',').filter(Boolean))],
    ['GET', '/taf', ({ query: q }) => lookup('taf', (q.get('ids') ?? '').split(',').filter(Boolean))],
    ['POST', '/winds', async ({ body }) => {
      if (!Array.isArray(body.points) || !body.points.length) throw new AppError(400, 'no_points', 'points[] is required');
      return winds(body.points.slice(0, 80), new Date(body.when ?? Date.now()));
    }],
  ],
}).then(() => {
  // Background job: keep METARs warm for airports in saved plans. Each cycle is its own root trace.
  setInterval(() => {
    const span = tracer.startSpan('weather.refresh_cycle', { root: true });
    context.with(trace.setSpan(ROOT_CONTEXT, span), async () => {
      try {
        const { rows } = await query(`SELECT DISTINCT a FROM plans, unnest(ARRAY[origin, destination]) AS a WHERE created_at > now() - interval '7 days' LIMIT 12`);
        const stale = await query(`SELECT replace(key, 'metar:', '') AS icao FROM cache_entries WHERE kind = 'metar' AND expires_at < now() + interval '1 minute' AND replace(key, 'metar:', '') = ANY($1::text[])`, [rows.map((r) => r.a)]);
        span.setAttribute('app.refresh.airports', stale.rowCount);
        if (stale.rowCount) { await lookup('metar', stale.rows.map((r) => r.icao)); log.info('Refreshed METARs for saved plans', { 'app.refresh.airports': stale.rowCount }); }
      } catch (error) { span.recordException(error); log.error('Weather refresh failed', { 'exception.message': error.message }); }
      finally { span.end(); }
    });
  }, 60_000).unref();
});
