'use strict';
// airports: reference data for any airport, pulled from the aviationweather.gov airport API on
// first use and cached in Postgres. There is no seed list: whatever you ask for is looked up.
// Spatial queries discover stations from the METAR bounding-box API, then fetch their details.
const { SpanKind } = require('@opentelemetry/api');
const { createService, AppError, PORTS } = require('../lib/http');
const { withSpan, spanSync, meter, durationHistogram, log } = require('../lib/otel');
const { query } = require('../lib/pg');
const cache = require('../lib/cache');
const { sleep, between } = require('../lib/sim');
const { distanceNm, trackDistances } = require('../lib/geo');

const BASE = process.env.WEATHER_BASE_URL || 'https://aviationweather.gov/api/data';
const REFRESH_AFTER = '30 days'; // runways rarely change; older rows are refetched, and an API failure is an error
const lookups = meter.createCounter('contrail.airports.lookups', { description: 'Airport lookups by where the record came from.', unit: '{airport}' });
const upstreamRequests = meter.createCounter('contrail.upstream.requests', { description: 'Calls to external data providers.', unit: '{request}' });
const upstreamDuration = durationHistogram('contrail.upstream.duration', 'Latency of external data providers.');

const titleCase = (s) => s.toLowerCase().replace(/\b[a-z]/g, (c) => c.toUpperCase()).replace(/\bIntl\b/, 'Intl').trim();
const COLUMNS = `icao, iata, name, city, state, country, lat, lon, elev_ft AS "elevFt", longest_rwy_ft AS "longestRunwayFt", rwy_heading AS "runwayHeading",
  has_tower AS "hasTower", runways, magdec, freqs`;

/** "SFO" -> "KSFO"; four-character identifiers are used as given. */
function normalizeCode(code) {
  const c = String(code).trim().toUpperCase();
  return /^[A-Z][A-Z0-9]{2}$/.test(c) ? `K${c}` : c;
}

async function awc(path, params, attributes) {
  const url = `${BASE}/${path}?${new URLSearchParams({ ...params, format: 'json' })}`;
  for (let attempt = 1; ; attempt++) {
    const started = performance.now();
    try {
      return await withSpan('airports.upstream.request', { kind: SpanKind.CLIENT, attributes: { 'peer.service': 'aviationweather.gov', 'url.template': `/api/data/${path}`, 'http.request.resend_count': attempt - 1, ...attributes } }, async (span) => {
        const response = await fetch(url, { signal: AbortSignal.timeout(6000), headers: { 'user-agent': 'contrail-demo/1.0' } });
        span.setAttribute('http.response.status_code', response.status);
        if (response.status === 204) return [];
        if (!response.ok) throw new Error(`aviationweather.gov returned ${response.status}`);
        const data = await response.json();
        upstreamRequests.add(1, { 'peer.service': 'aviationweather.gov', outcome: 'ok' });
        return data;
      });
    } catch (error) {
      upstreamRequests.add(1, { 'peer.service': 'aviationweather.gov', outcome: 'error' });
      if (attempt >= 2) throw new AppError(502, 'airport_data_unavailable', `Airport data provider failed: ${error.message}`, { expected: false });
      log.warn('Airport API failed, retrying', { 'exception.message': error.message });
      await withSpan('airports.retry_backoff', () => sleep(200 * between(0.8, 1.4)));
    } finally { upstreamDuration.record((performance.now() - started) / 1000, { 'peer.service': 'aviationweather.gov', 'url.template': `/api/data/${path}` }); }
  }
}

function normalizeAirport(a) {
  const runways = (a.runways ?? []).map((r) => {
    const [length, width] = String(r.dimension ?? '0x0').split('x').map(Number);
    return { id: r.id, lengthFt: length || 0, widthFt: width || 0, surface: r.surface, headingTrue: r.alignment };
  });
  const longest = runways.reduce((best, r) => (r.lengthFt > (best?.lengthFt ?? -1) ? r : best), null);
  const [city, ...rest] = String(a.name ?? '').split('/');
  return { icao: a.icaoId, iata: a.iataId || null, faa_id: a.faaId || null, name: titleCase(rest.length ? rest.join('/') : city), city: titleCase(city), state: a.state, country: a.country,
    lat: a.lat, lon: a.lon, elev_ft: a.elev == null ? null : Math.round(a.elev * 3.28084), magdec: a.magdec ?? null, has_tower: a.tower === 'T',
    longest_rwy_ft: longest?.lengthFt ?? 0, rwy_heading: longest?.headingTrue ?? null, runways, freqs: a.freqs ?? null };
}

/** Read-through lookup of full airport records. Missing identifiers are simply absent from the result. */
async function getAirports(codes) {
  const ids = [...new Set(codes.map(normalizeCode))];
  return withSpan('airports.get', { attributes: { 'app.airports.requested': ids.length } }, async (span) => {
    const { rows } = await query(`SELECT ${COLUMNS} FROM airports WHERE icao = ANY($1::text[]) AND fetched_at > now() - $2::interval`, [ids, REFRESH_AFTER]);
    const found = new Map(rows.map((r) => [r.icao, r]));
    let missing = ids.filter((id) => !found.has(id));
    lookups.add(found.size, { source: 'database' });
    if (missing.length) {
      // Identifiers the API already told us it does not know (e.g. non-US wind stations): don't ask again for a day.
      const known = await cache.getMany('airport-miss', missing.map((id) => `airport-miss:${id}`));
      missing = missing.filter((id) => !known.get(`airport-miss:${id}`)?.fresh);
    }
    if (missing.length) {
      const batches = [];
      for (let i = 0; i < missing.length; i += 100) batches.push(missing.slice(i, i + 100));
      const fetched = (await Promise.all(batches.map((batch) => awc('airport', { ids: batch.join(',') }, { 'app.airports.requested': batch.length })))).flat();
      const records = spanSync('airports.normalize', (s) => { const out = fetched.filter((a) => a.icaoId && a.lat != null).map(normalizeAirport); s.setAttribute('app.airports.normalized', out.length); return out; });
      const unknown = missing.filter((id) => !fetched.some((a) => a.icaoId === id));
      await cache.putMany('airport-miss', unknown.map((id) => ({ key: `airport-miss:${id}`, payload: { icao: id } })), 86400);
      if (records.length) {
        await query(
          `INSERT INTO airports (icao, iata, faa_id, name, city, state, country, lat, lon, elev_ft, magdec, has_tower, longest_rwy_ft, rwy_heading, runways, freqs, fetched_at)
           SELECT icao, iata, faa_id, name, city, state, country, lat, lon, elev_ft, magdec, has_tower, longest_rwy_ft, rwy_heading, runways, freqs, now()
           FROM jsonb_to_recordset($1::jsonb) AS x(icao text, iata text, faa_id text, name text, city text, state text, country text, lat float8, lon float8, elev_ft int, magdec text,
             has_tower bool, longest_rwy_ft int, rwy_heading int, runways jsonb, freqs text)
           ON CONFLICT (icao) DO UPDATE SET iata = EXCLUDED.iata, name = EXCLUDED.name, city = EXCLUDED.city, lat = EXCLUDED.lat, lon = EXCLUDED.lon, elev_ft = EXCLUDED.elev_ft,
             magdec = EXCLUDED.magdec, has_tower = EXCLUDED.has_tower, longest_rwy_ft = EXCLUDED.longest_rwy_ft, rwy_heading = EXCLUDED.rwy_heading,
             runways = EXCLUDED.runways, freqs = EXCLUDED.freqs, fetched_at = now()`, [JSON.stringify(records)]);
        const { rows: stored } = await query(`SELECT ${COLUMNS} FROM airports WHERE icao = ANY($1::text[])`, [records.map((r) => r.icao)]);
        for (const row of stored) found.set(row.icao, row);
        lookups.add(stored.length, { source: 'api' });
      }
    }
    span.setAttributes({ 'app.airports.from_db': rows.length, 'app.airports.from_api': found.size - rows.length, 'app.airports.unknown': ids.filter((id) => !found.has(id)).length });
    return found;
  });
}

async function resolve(codes, { lenient = false } = {}) {
  const ids = codes.map(normalizeCode);
  const found = await getAirports(ids);
  const missing = ids.filter((id) => !found.has(id));
  if (missing.length && !lenient) {
    log.warn('Unknown airport requested', { 'app.airport.codes': missing.join(',') });
    throw new AppError(404, 'unknown_airport', `No airport found for ${missing.join(', ')}. Use an ICAO code such as KSFO.`, { details: { missing } });
  }
  return ids.filter((id) => found.has(id)).map((id) => found.get(id));
}

/**
 * Reporting stations inside a box, from the METAR bbox API (the stations that can give you weather).
 * Boxes are snapped outward to a 0.5-degree grid and cached for a day: the station list rarely changes.
 */
async function stationsInBox(minLat, minLon, maxLat, maxLon) {
  const snap = (v, fn) => fn(v * 2) / 2;
  const box = [snap(minLat, Math.floor), snap(minLon, Math.floor), snap(maxLat, Math.ceil), snap(maxLon, Math.ceil)];
  const key = `box:${box.join(',')}`;
  const cached = await cache.getMany('station-box', [key]);
  if (cached.get(key)?.fresh) return cached.get(key).payload;
  const data = await awc('metar', { bbox: box.join(',') }, { 'app.box.area_deg2': Math.round((box[2] - box[0]) * (box[3] - box[1]) * 10) / 10 });
  const stations = [...new Map(data.filter((m) => /^[KP][A-Z0-9]{3}$/.test(m.icaoId)).map((m) => [m.icaoId, { icao: m.icaoId, lat: m.lat, lon: m.lon }])).values()];
  await cache.putMany('station-box', [{ key, payload: stations }], 86400);
  return stations;
}

const boxAround = (lat, lon, radiusNm) => {
  const dLat = radiusNm / 60, dLon = radiusNm / (60 * Math.max(0.2, Math.cos((lat * Math.PI) / 180)));
  return [lat - dLat, lon - dLon, lat + dLat, lon + dLon];
};

async function nearby({ lat, lon, radiusNm = 50, limit = 6, minRunwayFt = 0, exclude = [] }) {
  const stations = (await stationsInBox(...boxAround(lat, lon, radiusNm)))
    .map((s) => ({ ...s, distanceNm: distanceNm({ lat, lon }, s) })).filter((s) => s.distanceNm <= radiusNm && !exclude.includes(s.icao)).sort((a, b) => a.distanceNm - b.distanceNm);
  const details = await getAirports(stations.slice(0, limit * 4).map((s) => s.icao));
  return stations.map((s) => details.get(s.icao) && { ...details.get(s.icao), distanceNm: Math.round(s.distanceNm * 10) / 10 })
    .filter((a) => a && a.longestRunwayFt >= minRunwayFt && a.runwayHeading != null).slice(0, limit);
}

/** Airports within `widthNm` of a polyline: station discovery per route chunk (in parallel), exact distance here. */
async function corridor({ path, widthNm = 25, minRunwayFt = 0, exclude = [] }) {
  const chunkCount = Math.min(10, Math.max(1, Math.ceil((path.at(-1).distNm ?? 0) / 150)));
  const step = Math.ceil((path.length - 1) / chunkCount);
  const boxes = [];
  for (let i = 0; i < path.length - 1; i += step) {
    const pts = path.slice(i, Math.min(path.length, i + step + 1));
    const lats = pts.map((p) => p.lat), lons = pts.map((p) => p.lon), midLat = (Math.min(...lats) + Math.max(...lats)) / 2;
    const pad = widthNm / 60, padLon = pad / Math.max(0.2, Math.cos((midLat * Math.PI) / 180));
    boxes.push([Math.min(...lats) - pad, Math.min(...lons) - padLon, Math.max(...lats) + pad, Math.max(...lons) + padLon]);
  }
  const stations = [...new Map((await withSpan('airports.discover_stations', { attributes: { 'app.corridor.boxes': boxes.length } }, () =>
    Promise.all(boxes.map((b) => stationsInBox(...b))))).flat().map((s) => [s.icao, s])).values()].filter((s) => !exclude.includes(s.icao));

  const kept = spanSync('airports.corridor_filter', { attributes: { 'app.corridor.candidates': stations.length, 'app.corridor.width_nm': widthNm, 'app.corridor.segments': path.length - 1 } }, (span) => {
    const out = [];
    for (const station of stations) {
      let best = null;
      for (let i = 0; i < path.length - 1; i++) {
        const a = path[i], b = path[i + 1], segLen = distanceNm(a, b);
        const { crossTrackNm, alongTrackNm } = trackDistances(a, b, station);
        const inside = alongTrackNm >= 0 && alongTrackNm <= segLen;
        const off = inside ? crossTrackNm : Math.min(distanceNm(a, station), distanceNm(b, station));
        if (!best || off < best.off) best = { off, along: (a.distNm ?? 0) + Math.min(Math.max(alongTrackNm, 0), segLen) };
      }
      if (best.off <= widthNm) out.push({ icao: station.icao, off: best.off, along: best.along });
    }
    span.setAttribute('app.corridor.kept', out.length);
    return out;
  });
  const details = await getAirports(kept.map((k) => k.icao));
  return kept.map((k) => details.get(k.icao) && { ...details.get(k.icao), distanceFromRouteNm: Math.round(k.off * 10) / 10, alongTrackNm: Math.round(k.along) })
    .filter((a) => a && a.longestRunwayFt >= minRunwayFt && a.runwayHeading != null).sort((x, y) => x.alongTrackNm - y.alongTrackNm);
}

async function search(q) {
  const term = q.trim().slice(0, 40);
  if (term.length < 2) return [];
  const { rows } = await query(
    `SELECT ${COLUMNS} FROM airports WHERE icao ILIKE $1 || '%' OR iata ILIKE $1 || '%' OR name ILIKE '%' || $1 || '%' OR city ILIKE $1 || '%' ORDER BY (icao = $2 OR iata = $2) DESC, longest_rwy_ft DESC LIMIT 8`,
    [term, term.toUpperCase()]);
  // The API only supports lookups by identifier, so a code-shaped query also checks it directly.
  if (/^[A-Za-z][A-Za-z0-9]{2,3}$/.test(term) && !rows.some((r) => r.icao === normalizeCode(term))) {
    const [airport] = await resolve([term], { lenient: true });
    if (airport) rows.unshift(airport);
  }
  return rows;
}

createService({
  name: 'airports', port: PORTS.airports,
  routes: [
    ['GET', '/search', async ({ query: q }) => ({ results: await search(q.get('q') ?? '') })],
    ['POST', '/resolve', async ({ body }) => ({ airports: await resolve(body.codes ?? [], { lenient: body.lenient }) })],
    ['POST', '/nearby', async ({ body }) => ({ airports: await nearby(body) })],
    ['POST', '/corridor', async ({ body }) => ({ airports: await corridor(body) })],
  ],
});
