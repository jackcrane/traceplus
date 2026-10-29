'use strict';
// planner: turns "KSFO to KSAN in a C172" into a full briefing. Stages (see the trace):
//   resolve -> route  ->  [corridor ‖ winds ‖ alternates ‖ terrain]  ->  [METARs ‖ TAFs]
//   -> performance -> weight & balance -> rank alternates -> risk -> briefing text
const { createService, AppError, call, PORTS } = require('../lib/http');
const { SpanKind } = require('@opentelemetry/api');
const { withSpan, spanSync, meter, durationHistogram, log } = require('../lib/otel');
const { createFaults } = require('../lib/sim');
const { distanceNm, initialCourse, interpolate, windTriangle, crosswindComponents, sunTimes } = require('../lib/geo');
const { CATEGORY_RANK, flightCategory } = require('../lib/wx');
const AIRCRAFT = require('../lib/aircraft');

const faults = createFaults({ routeSampleNm: 25 }); // smaller = more waypoints = more wind lookups
const plansGenerated = meter.createCounter('contrail.plans.generated', { description: 'Flight plans computed, by verdict.', unit: '{plan}' });
const planDuration = durationHistogram('contrail.plan.duration', 'End-to-end time to build a briefing.', [0.25, 0.5, 1, 2, 3, 5, 8, 13]);
const planDistance = meter.createHistogram('contrail.plan.distance', { description: 'Route length.', unit: '[nmi_i]', advice: { explicitBucketBoundaries: [50, 100, 200, 400, 800, 1200, 1800, 2500] } });
const airportsBriefed = meter.createHistogram('contrail.plan.airports_briefed', { description: 'Airports covered by one briefing.', unit: '{airport}', advice: { explicitBucketBoundaries: [2, 4, 6, 8, 10, 12] } });
const riskScore = meter.createHistogram('contrail.plan.risk_score', { description: 'Go/no-go risk score (0 safe - 100 severe).', unit: '1', advice: { explicitBucketBoundaries: [10, 20, 30, 45, 60, 80] } });

const round = (n, d = 0) => { const f = 10 ** d; return Math.round(n * f) / f; };
const hhmm = (min) => `${Math.floor(min / 60)}h ${String(Math.round(min % 60)).padStart(2, '0')}m`;

// --- stages --------------------------------------------------------------------------------------

function validate(body) {
  const aircraft = AIRCRAFT[body.aircraft ?? 'C172'];
  if (!body.origin || !body.destination) throw new AppError(400, 'missing_endpoints', 'Choose an origin and a destination');
  if (String(body.origin).toUpperCase() === String(body.destination).toUpperCase()) throw new AppError(422, 'same_airport', 'Origin and destination are the same airport');
  if (!aircraft) throw new AppError(422, 'unknown_aircraft', `Unknown aircraft ${body.aircraft}`);
  const cruiseAltFt = Number(body.cruiseAltFt ?? 6500);
  if (!(cruiseAltFt >= 1000 && cruiseAltFt <= aircraft.serviceCeilingFt)) throw new AppError(422, 'invalid_altitude', `Cruise altitude must be 1,000-${aircraft.serviceCeilingFt.toLocaleString()} ft for the ${aircraft.name}`);
  const departure = body.departureTime ? new Date(body.departureTime) : new Date(Date.now() + 3600000);
  if (Number.isNaN(departure.getTime())) throw new AppError(422, 'invalid_departure', 'Departure time is not a valid date');
  return { aircraft, aircraftKey: body.aircraft ?? 'C172', cruiseAltFt, departure };
}

function computeRoute(origin, destination, sampleNm) {
  return spanSync('plan.compute_route', (span) => {
    const total = distanceNm(origin, destination);
    const count = Math.min(60, Math.max(2, Math.ceil(total / sampleNm) + 1));
    const waypoints = Array.from({ length: count }, (_, i) => {
      const p = interpolate(origin, destination, i / (count - 1));
      return { lat: round(p.lat, 4), lon: round(p.lon, 4), distNm: round((total * i) / (count - 1), 1) };
    });
    span.setAttributes({ 'app.route.distance_nm': round(total), 'app.route.waypoints': count });
    return { distanceNm: round(total, 1), trueCourse: round(initialCourse(origin, destination)), waypoints };
  });
}

/** Real terrain elevations along the route from the Open-Meteo elevation API (a ~90 m DEM), sampled at up to 100 points. */
async function terrainProfile(route, cruiseAltFt) {
  return withSpan('plan.terrain_clearance', async (span) => {
    const count = Math.min(100, Math.max(8, Math.ceil(route.distanceNm / 10)));
    const samples = Array.from({ length: count }, (_, i) => {
      const f = i / (count - 1), segment = Math.min(route.waypoints.length - 2, Math.floor(f * (route.waypoints.length - 1)));
      return interpolate(route.waypoints[segment], route.waypoints[segment + 1], f * (route.waypoints.length - 1) - segment);
    });
    const url = `https://api.open-meteo.com/v1/elevation?latitude=${samples.map((p) => p.lat.toFixed(3)).join(',')}&longitude=${samples.map((p) => p.lon.toFixed(3)).join(',')}`;
    const data = await withSpan('terrain.upstream.request', { kind: SpanKind.CLIENT, attributes: { 'peer.service': 'open-meteo', 'url.template': '/v1/elevation', 'app.terrain.samples': count } }, async (s) => {
      const response = await fetch(url, { signal: AbortSignal.timeout(8000) });
      s.setAttribute('http.response.status_code', response.status);
      if (!response.ok) throw new AppError(502, 'terrain_unavailable', `Elevation provider returned ${response.status}`, { expected: false });
      return response.json();
    });
    const highestFt = Math.round(Math.max(...data.elevation) * 3.28084), clearanceFt = cruiseAltFt - highestFt;
    span.setAttributes({ 'app.terrain.highest_ft': highestFt, 'app.terrain.clearance_ft': clearanceFt, 'app.terrain.samples': count });
    return { highestFt, clearanceFt, samples: count };
  });
}

function buildLegs(route, winds, aircraft, departure) {
  return spanSync('plan.performance.legs', (span) => {
    let elapsed = 0;
    const legs = [];
    for (let i = 0; i < route.waypoints.length - 1; i++) {
      const a = route.waypoints[i], b = route.waypoints[i + 1], wa = winds[i], wb = winds[i + 1];
      const east = (-Math.sin((wa.dir * Math.PI) / 180) * wa.speedKt - Math.sin((wb.dir * Math.PI) / 180) * wb.speedKt) / 2;
      const north = (-Math.cos((wa.dir * Math.PI) / 180) * wa.speedKt - Math.cos((wb.dir * Math.PI) / 180) * wb.speedKt) / 2;
      const windKt = Math.hypot(east, north), windFrom = (Math.atan2(-east, -north) * 180 / Math.PI + 360) % 360;
      const course = initialCourse(a, b), dist = b.distNm - a.distNm;
      const tri = windTriangle(course, aircraft.tasKt, windFrom, windKt);
      const eteMin = (dist / tri.groundSpeedKt) * 60;
      legs.push({ fromNm: a.distNm, toNm: b.distNm, courseDeg: round(course), headingDeg: round(tri.heading), windDir: round(windFrom), windKt: round(windKt), groundSpeedKt: round(tri.groundSpeedKt), eteMin: round(eteMin, 1), etaAt: new Date(departure.getTime() + (elapsed + eteMin) * 60000).toISOString() });
      elapsed += eteMin;
    }
    // Climb/descent allowance: a flat 8 minutes.
    const eteMin = elapsed + 8;
    span.setAttributes({ 'app.route.ete_min': round(eteMin), 'app.route.legs': legs.length });
    return { legs, eteMin };
  });
}

const periodAt = (taf, when) => taf?.periods?.find((p) => new Date(p.from) <= when && when < new Date(p.to)) ?? taf?.periods?.at(-1) ?? null;

function groundPerformance(airport, metric, aircraft, weightLb, headwindKt) {
  const tempC = metric?.tempC ?? 15, qnh = metric?.altimeterInHg ?? 29.92;
  const elevFt = airport.elevFt ?? 0;
  const pressureAlt = elevFt + (29.92 - qnh) * 1000;
  const isa = 15 - 2 * (elevFt / 1000);
  const densityAltFt = Math.round(pressureAlt + 120 * (tempC - isa));
  const weightFactor = (weightLb / aircraft.maxGross) ** 2;
  const windFactor = Math.max(0.6, 1 - Math.max(0, headwindKt) / 9 * 0.1);
  const takeoffRollFt = Math.round(aircraft.takeoffRollFt * (1 + (Math.max(0, densityAltFt) / 1000) * 0.12) * weightFactor * windFactor);
  const landingRollFt = Math.round(aircraft.landingRollFt * (1 + (Math.max(0, densityAltFt) / 1000) * 0.05) * windFactor);
  const availableFt = airport.longestRunwayFt;
  return { densityAltFt, takeoffRollFt, landingRollFt, runwayAvailableFt: availableFt,
    takeoffMarginRatio: round(availableFt / (takeoffRollFt * 1.5), 2), landingMarginRatio: round(availableFt / (landingRollFt * 1.43), 2) };
}

function weightAndBalance(aircraft, loading, fuelGal) {
  return spanSync('plan.weight_balance', (span) => {
    const stations = [
      ['Empty aircraft', aircraft.emptyWeight, aircraft.emptyArm],
      ['Front seats', loading.frontLb, aircraft.arms.front], ['Rear seats', loading.rearLb, aircraft.arms.rear],
      ['Baggage', loading.baggageLb, aircraft.arms.baggage], ['Fuel', fuelGal * aircraft.fuelLbPerGal, aircraft.arms.fuel],
    ].map(([name, weight, arm]) => ({ name, weightLb: round(weight), arm, moment: round(weight * arm) }));
    const weight = stations.reduce((s, x) => s + x.weightLb, 0), cg = stations.reduce((s, x) => s + x.moment, 0) / weight;
    const withinEnvelope = weight <= aircraft.maxGross && cg >= aircraft.cgLimits[0] && cg <= aircraft.cgLimits[1];
    span.setAttributes({ 'app.wb.weight_lb': round(weight), 'app.wb.cg': round(cg, 2), 'app.wb.within_envelope': withinEnvelope });
    return { stations, takeoffWeightLb: round(weight), maxGrossLb: aircraft.maxGross, cg: round(cg, 2), cgLimits: aircraft.cgLimits, withinEnvelope, overweightLb: Math.max(0, round(weight - aircraft.maxGross)) };
  });
}

function rankAlternates(candidates, destination, aircraft) {
  return spanSync('plan.rank_alternates', { attributes: { 'app.alternates.candidates': candidates.length } }, () =>
    candidates.map((a) => {
      const cat = a.tafAtEta?.flightCategory ?? a.metar?.flightCategory ?? 'IFR';
      const score = a.distanceFromDestinationNm + CATEGORY_RANK[cat] * 40 + (a.hasTower ? 0 : 10) - (a.longestRunwayFt >= aircraft.minRunwayFt * 2 ? 5 : 0);
      return { icao: a.icao, name: a.name, distanceNm: round(a.distanceFromDestinationNm), flightCategory: cat, hasTower: a.hasTower, longestRunwayFt: a.longestRunwayFt, score: round(score) };
    }).sort((x, y) => x.score - y.score));
}

function assessRisk({ aircraft, aircraftKey, departure, eta, destination, origin, airports, terrain, fuel, wb, perf, route, arrivalNight, alternates }) {
  return spanSync('plan.assess_risk', (span) => {
    const factors = [];
    const add = (label, impact, detail) => impact && factors.push({ label, impact, detail });
    const dest = airports.find((a) => a.role === 'destination'), orig = airports.find((a) => a.role === 'origin');
    const destCat = dest.tafAtEta?.flightCategory ?? dest.metar?.flightCategory, origCat = orig.metar?.flightCategory;
    if (destCat === 'LIFR') add('Destination LIFR at ETA', 40, 'Below approach minimums for most operations'); else if (destCat === 'IFR') add('Destination IFR at ETA', 25, 'Instrument conditions forecast on arrival'); else if (destCat === 'MVFR') add('Destination marginal VFR', 8, 'Ceiling or visibility reduced at ETA');
    if (origCat === 'IFR' || origCat === 'LIFR') add(`Departure airport ${origCat}`, 15, 'Conditions below VFR at departure'); else if (origCat === 'MVFR') add('Departure marginal VFR', 5, 'Reduced ceiling or visibility at departure');
    const wind = dest.tafAtEta ?? dest.metar;
    if (wind?.windKt != null && typeof wind.windDir === 'number') {
      const { crosswindKt } = crosswindComponents(dest.runwayHeading, wind.windDir, wind.gustKt ?? wind.windKt);
      const detail = `${round(crosswindKt)} kt crosswind on the longest runway (limit ${aircraft.maxCrosswindKt} kt)`;
      if (crosswindKt > aircraft.maxCrosswindKt) add('Crosswind exceeds aircraft limit', 30, detail);
      else if (crosswindKt > aircraft.maxCrosswindKt * 0.75) add('Significant crosswind at destination', 10, detail);
      dest.crosswindKt = round(crosswindKt);
    }
    if ((wind?.gustKt ?? 0) >= 25) add('Strong gusts at destination', 10, `Gusts to ${wind.gustKt} kt`);
    if (arrivalNight) add('Night arrival', 8, 'Landing after sunset; confirm currency and lighting');
    const enrouteBad = airports.filter((a) => a.role === 'enroute' && ['IFR', 'LIFR'].includes(a.metar?.flightCategory));
    if (enrouteBad.length) add('IFR conditions en route', 8, enrouteBad.map((a) => a.icao).join(', '));
    if (perf.destination.landingMarginRatio < 1.5) add('Thin landing-distance margin', 15, `${perf.destination.runwayAvailableFt} ft available vs ${perf.destination.landingRollFt} ft roll`);
    if (perf.origin.takeoffMarginRatio < 1.5) add('Thin takeoff-distance margin', 15, `${perf.origin.runwayAvailableFt} ft available vs ${perf.origin.takeoffRollFt} ft roll`);
    if (terrain.clearanceFt < 2000) add('Low terrain clearance', terrain.clearanceFt < 1000 ? 30 : 12, `${terrain.clearanceFt} ft above the highest terrain sampled`);
    if (!fuel.sufficient) add('Insufficient fuel capacity', 45, `Needs ${fuel.requiredGal} gal, tanks hold ${fuel.capacityGal}`);
    if (!wb.withinEnvelope) add('Weight & balance out of limits', 40, wb.overweightLb ? `${wb.overweightLb} lb over gross` : `CG ${wb.cg} outside ${wb.cgLimits.join('-')}`);
    if (['IFR', 'LIFR'].includes(destCat) && !alternates.some((a) => a.flightCategory === 'VFR' || a.flightCategory === 'MVFR')) add('No good alternate', 15, 'Every candidate alternate is IFR or worse');
    const score = Math.min(100, factors.reduce((s, f) => s + f.impact, 0));
    const verdict = score < 25 ? 'GO' : score < 55 ? 'CAUTION' : 'NO-GO';
    span.setAttributes({ 'app.risk.score': score, 'app.risk.verdict': verdict, 'app.risk.factors': factors.length });
    return { score, verdict, factors: factors.sort((a, b) => b.impact - a.impact) };
  });
}

function renderBriefing(p) {
  return spanSync('plan.render_briefing', () => {
    const lines = [];
    lines.push(`FLIGHT BRIEFING  ${p.origin.icao} -> ${p.destination.icao}  (${p.aircraft.name})`);
    lines.push(`Departure ${p.timing.departure}  ETE ${hhmm(p.timing.eteMin)}  ETA ${p.timing.eta}`);
    lines.push(`Distance ${p.route.distanceNm} nm  Course ${p.route.trueCourse} deg true  Cruise ${p.cruiseAltFt} ft`);
    lines.push(`VERDICT: ${p.risk.verdict} (risk ${p.risk.score}/100)`);
    for (const f of p.risk.factors) lines.push(`  [+${f.impact}] ${f.label} - ${f.detail}`);
    lines.push('', `FUEL  trip ${p.fuel.tripGal} + reserve ${p.fuel.reserveGal} + alternate ${p.fuel.alternateGal} = ${p.fuel.requiredGal} gal (tanks ${p.fuel.capacityGal})`);
    lines.push(`W&B   ${p.weightBalance.takeoffWeightLb} / ${p.weightBalance.maxGrossLb} lb, CG ${p.weightBalance.cg} ${p.weightBalance.withinEnvelope ? 'in limits' : 'OUT OF LIMITS'}`);
    for (const a of p.airports) {
      lines.push('', `${a.icao} ${a.name} [${a.role}]`);
      lines.push(`  METAR ${a.metar?.raw ?? 'unavailable'}`);
      lines.push(`  TAF   ${a.taf?.raw ?? 'unavailable'}`);
    }
    lines.push('', 'Demonstration data only. Not for navigation.');
    return lines.join('\n');
  });
}

// --- orchestration -------------------------------------------------------------------------------

async function buildPlan(body) {
  const started = performance.now();
  const { aircraft, aircraftKey, cruiseAltFt, departure } = validate(body);
  const loading = { frontLb: Number(body.frontLb ?? 340), rearLb: Number(body.rearLb ?? 0), baggageLb: Number(body.baggageLb ?? 40) };

  const { airports: [origin, destination] } = await withSpan('plan.resolve_endpoints', async () => {
    const { airports } = await call('airports', '/resolve', { body: { codes: [body.origin, body.destination] } });
    const order = [body.origin, body.destination].map((c) => airports.find((a) => a.icao === c.toUpperCase() || a.iata === c.toUpperCase()));
    return { airports: order };
  });
  const route = computeRoute(origin, destination, faults.get('routeSampleNm'));

  // Stage A: three independent lookups at once.
  const [corridor, windsRes, near, terrain] = await withSpan('plan.gather_route_data', { attributes: { 'app.route.waypoints': route.waypoints.length } }, () => Promise.all([
    call('airports', '/corridor', { body: { path: route.waypoints, widthNm: 20, exclude: [origin.icao, destination.icao] } }),
    call('weather', '/winds', { body: { points: route.waypoints.map((w) => ({ lat: w.lat, lon: w.lon, altFt: cruiseAltFt })), when: departure.toISOString() } }),
    call('airports', '/nearby', { body: { lat: destination.lat, lon: destination.lon, radiusNm: 90, limit: 5, minRunwayFt: aircraft.minRunwayFt, exclude: [origin.icao, destination.icao] } }),
    terrainProfile(route, cruiseAltFt),
  ]));

  const enroute = pickEnroute(corridor.airports, route.distanceNm);
  const roster = [
    { ...origin, role: 'origin', alongTrackNm: 0, distanceFromRouteNm: 0 },
    ...enroute.map((a) => ({ ...a, role: 'enroute' })),
    { ...destination, role: 'destination', alongTrackNm: route.distanceNm, distanceFromRouteNm: 0 },
    ...near.airports.filter((a) => !enroute.some((e) => e.icao === a.icao)).map((a) => ({ ...a, role: 'alternate', distanceFromDestinationNm: a.distanceNm, alongTrackNm: route.distanceNm })),
  ];
  const ids = roster.map((a) => a.icao);

  // Stage B: current weather and forecasts for every airport, in parallel.
  const [metars, tafs] = await withSpan('plan.gather_airport_data', { attributes: { 'app.airports.count': ids.length } }, () => Promise.all([
    call('weather', `/metar?ids=${ids.join(',')}`, { method: 'GET' }),
    call('weather', `/taf?ids=${ids.join(',')}`, { method: 'GET' }),
  ]));

  const { legs, eteMin } = buildLegs(route, windsRes.winds, aircraft, departure);
  const eta = new Date(departure.getTime() + eteMin * 60000);
  const sun = sunTimes(destination.lat, destination.lon, eta);
  const arrivalNight = sun.sunset != null && (eta.getTime() > sun.sunset + 1800000 || eta.getTime() < sun.sunrise - 1800000);

  const airports = roster.map((a) => {
    const when = new Date(departure.getTime() + (a.alongTrackNm / route.distanceNm) * eteMin * 60000);
    return { ...a, etaAt: when.toISOString(), metar: metars.reports[a.icao], taf: tafs.reports[a.icao], tafAtEta: periodAt(tafs.reports[a.icao], when) };
  });
  const byRole = (role) => airports.find((a) => a.role === role);
  const destWx = byRole('destination').tafAtEta ?? byRole('destination').metar;
  const originWx = byRole('origin').metar;

  const alternates = rankAlternates(airports.filter((a) => a.role === 'alternate'), destination, aircraft);

  const fuel = spanSync('plan.fuel', (span) => {
    const tripGal = round((eteMin / 60) * aircraft.burnGph, 1);
    const needAlternate = (destWx?.ceilingFt ?? 99999) < 2000 || (destWx?.visibilitySm ?? 10) < 3; // the "1-2-3" rule
    const alternateGal = needAlternate && alternates[0] ? round(((alternates[0].distanceNm / aircraft.tasKt) * 60 / 60 + 0.1) * aircraft.burnGph, 1) : 0;
    const reserveGal = round(aircraft.burnGph * (arrivalNight ? 0.75 : 0.5), 1);
    const requiredGal = round(tripGal + reserveGal + alternateGal, 1);
    span.setAttributes({ 'app.fuel.trip_gal': tripGal, 'app.fuel.required_gal': requiredGal, 'app.fuel.alternate_required': needAlternate });
    return { tripGal, reserveGal, alternateGal, alternateRequired: needAlternate, requiredGal, capacityGal: aircraft.fuelCapGal, sufficient: requiredGal <= aircraft.fuelCapGal };
  });
  const wb = weightAndBalance(aircraft, loading, Math.min(aircraft.fuelCapGal, fuel.requiredGal * 1.1));

  const perf = spanSync('plan.performance.airports', () => ({
    origin: groundPerformance(byRole('origin'), originWx, aircraft, wb.takeoffWeightLb, (originWx?.windKt ?? 0) * 0.6),
    destination: groundPerformance(byRole('destination'), destWx, aircraft, wb.takeoffWeightLb - fuel.tripGal * aircraft.fuelLbPerGal, (destWx?.windKt ?? 0) * 0.6),
  }));

  const risk = assessRisk({ aircraft, aircraftKey, departure, eta, destination, origin, airports, terrain, fuel, wb, perf, route, arrivalNight, alternates });
  const cacheTotals = ['metar', 'taf'].reduce((acc, k) => {
    const c = (k === 'metar' ? metars : tafs).cache; acc.hits += c.hits; acc.misses += c.misses; acc.stale += c.stale; return acc;
  }, { hits: 0, misses: 0, stale: 0 });

  const result = {
    origin, destination, aircraftKey, aircraft: { name: aircraft.name, tasKt: aircraft.tasKt, burnGph: aircraft.burnGph }, cruiseAltFt,
    route: { ...route, legs, terrain, windsValid: windsRes.valid }, timing: { departure: departure.toISOString(), eta: eta.toISOString(), eteMin: round(eteMin), arrivalNight, sunset: sun.sunset ? new Date(sun.sunset).toISOString() : null },
    fuel, weightBalance: wb, performance: perf, airports: airports.map(({ metar, taf, ...a }) => ({ ...a, metar, taf })), alternates, risk,
    cache: cacheTotals, generatedAt: new Date().toISOString(),
  };
  result.briefingText = renderBriefing(result);

  const seconds = (performance.now() - started) / 1000;
  plansGenerated.add(1, { 'app.risk.verdict': risk.verdict, 'app.aircraft': aircraftKey });
  planDuration.record(seconds, { 'app.risk.verdict': risk.verdict });
  planDistance.record(route.distanceNm); airportsBriefed.record(airports.length); riskScore.record(risk.score, { 'app.aircraft': aircraftKey });
  log.info('Plan built', { 'app.route': `${origin.icao}-${destination.icao}`, 'app.aircraft': aircraftKey, 'app.risk.verdict': risk.verdict, 'app.risk.score': risk.score, 'app.plan.airports': airports.length, 'app.plan.duration_ms': Math.round(seconds * 1000) });
  return result;
}

/** Up to three en-route airports, spaced along the route and preferring longer runways. */
function pickEnroute(candidates, totalNm) {
  return spanSync('plan.pick_enroute_airports', { attributes: { 'app.candidates': candidates.length } }, () => {
    const chosen = [];
    for (const target of [0.25, 0.5, 0.75]) {
      const pool = candidates.filter((a) => !chosen.includes(a) && Math.abs(a.alongTrackNm - totalNm * target) < totalNm * 0.12);
      const best = pool.sort((a, b) => b.longestRunwayFt - a.longestRunwayFt)[0];
      if (best) chosen.push(best);
    }
    return chosen;
  });
}

createService({
  name: 'planner', port: PORTS.planner, faults,
  routes: [
    ['POST', '/plan', async ({ body }) => buildPlan(body)],
    ['GET', '/aircraft', () => ({ aircraft: Object.entries(AIRCRAFT).map(([key, a]) => ({ key, name: a.name, tasKt: a.tasKt, serviceCeilingFt: a.serviceCeilingFt, fuelCapGal: a.fuelCapGal })) })],
  ],
});
