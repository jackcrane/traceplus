'use strict';
const $ = (id) => document.getElementById(id);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmtTime = (iso) => new Date(iso).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
const hhmm = (min) => `${Math.floor(min / 60)}h ${String(Math.round(min % 60)).padStart(2, '0')}m`;
const state = { user: null, mode: 'login', current: null, savedId: null, activeAirport: 0 };

async function api(path, { method = 'GET', body } = {}) {
  const response = await fetch(path, { method, headers: body ? { 'content-type': 'application/json' } : {}, body: body ? JSON.stringify(body) : undefined, credentials: 'same-origin' });
  const traceId = response.headers.get('x-trace-id');
  const text = await response.text();
  let data; try { data = JSON.parse(text); } catch { data = text; }
  if (!response.ok) { const e = new Error(data.message || 'Request failed'); e.code = data.error; e.status = response.status; e.traceId = traceId; throw e; }
  if (data && typeof data === 'object') Object.defineProperty(data, '_traceId', { value: traceId, enumerable: false });
  return data;
}

function toast(message) {
  const el = Object.assign(document.createElement('div'), { className: 'toast', textContent: message });
  document.body.append(el); setTimeout(() => el.remove(), 3200);
}

// --- auth ---------------------------------------------------------------------------------------

function showSession() {
  $('auth').classList.toggle('hidden', !!state.user);
  $('app').classList.toggle('hidden', !state.user);
  $('session').innerHTML = state.user ? `<span>${esc(state.user.displayName)}</span><button id="logout">Sign out</button>` : '';
  if (state.user) $('logout').onclick = async () => { await api('/api/auth/logout', { method: 'POST', body: {} }); state.user = null; showSession(); };
}

function setAuthMode(mode) {
  state.mode = mode;
  $('auth-title').textContent = mode === 'login' ? 'Sign in' : 'Create your account';
  $('name-row').classList.toggle('hidden', mode === 'login');
  $('auth-toggle').textContent = mode === 'login' ? 'Create an account' : 'I already have an account';
  $('auth-error').textContent = '';
}

$('auth-toggle').onclick = () => setAuthMode(state.mode === 'login' ? 'register' : 'login');
$('auth-form').onsubmit = async (event) => {
  event.preventDefault();
  const form = Object.fromEntries(new FormData(event.target));
  try {
    const { user } = await api(`/api/auth/${state.mode}`, { method: 'POST', body: form });
    state.user = user; showSession(); event.target.reset(); bootApp();
  } catch (error) { $('auth-error').textContent = error.message; }
};

// --- planning form ------------------------------------------------------------------------------

let searchTimer;
for (const id of ['origin', 'destination']) {
  $(id).addEventListener('input', () => {
    clearTimeout(searchTimer);
    const q = $(id).value.trim();
    if (q.length < 2) return;
    searchTimer = setTimeout(async () => {
      try {
        const { results } = await api(`/api/airports/search?q=${encodeURIComponent(q)}`);
        $('airport-options').innerHTML = results.map((a) => `<option value="${esc(a.icao)}">${esc(a.name)} · ${esc(a.city)}, ${esc(a.state)}</option>`).join('');
      } catch { /* typeahead is best-effort */ }
    }, 180);
  });
}

function defaultDeparture() {
  const d = new Date(Date.now() + 3600000); d.setMinutes(0, 0, 0);
  $('departure').value = new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}

$('plan-form').onsubmit = async (event) => {
  event.preventDefault();
  const f = Object.fromEntries(new FormData(event.target));
  const request = {
    origin: f.origin.trim().toUpperCase(), destination: f.destination.trim().toUpperCase(), aircraft: f.aircraft, cruiseAltFt: Number(f.cruiseAltFt),
    departureTime: f.departureTime ? new Date(f.departureTime).toISOString() : undefined, frontLb: Number(f.frontLb), rearLb: Number(f.rearLb), baggageLb: Number(f.baggageLb),
  };
  $('plan-error').textContent = ''; $('plan-button').disabled = true;
  $('empty').classList.add('hidden'); $('result').classList.add('hidden'); $('loading').classList.remove('hidden');
  const started = performance.now();
  const ticker = setInterval(() => { $('loading-text').textContent = `Gathering weather and airport data… ${((performance.now() - started) / 1000).toFixed(1)}s`; }, 100);
  try {
    const result = await api('/api/plan', { method: 'POST', body: request });
    state.current = { request, result, traceId: result.traceId }; state.savedId = null; state.activeAirport = 0;
    render();
  } catch (error) {
    $('plan-error').textContent = error.message + (error.traceId ? ` (trace ${error.traceId.slice(0, 8)})` : '');
    $('empty').classList.remove('hidden');
  } finally { clearInterval(ticker); $('loading').classList.add('hidden'); $('plan-button').disabled = false; refreshCache(); }
};

// --- results ------------------------------------------------------------------------------------

function chip(category) { return category ? `<span class="chip ${esc(category)}">${esc(category)}</span>` : '<span class="chip low">N/A</span>'; }

function renderMap(r) {
  const pts = r.route.waypoints, airports = r.airports;
  const all = [...pts, ...airports];
  const lats = all.map((p) => p.lat), lons = all.map((p) => p.lon);
  const [minLat, maxLat, minLon, maxLon] = [Math.min(...lats), Math.max(...lats), Math.min(...lons), Math.max(...lons)];
  const kx = Math.cos(((minLat + maxLat) / 2) * Math.PI / 180), W = 640, pad = 40;
  const spanX = Math.max((maxLon - minLon) * kx, 0.5), spanY = Math.max(maxLat - minLat, 0.5), scale = Math.min((W - 2 * pad) / spanX, 300 / spanY), H = spanY * scale + 2 * pad;
  const x = (lon) => pad + (lon - minLon) * kx * scale + ((W - 2 * pad) - spanX * scale) / 2, y = (lat) => pad + (maxLat - lat) * scale;
  const line = pts.map((p) => `${x(p.lon).toFixed(1)},${y(p.lat).toFixed(1)}`).join(' ');
  const dots = airports.map((a) => {
    const color = `var(--${(a.metar?.flightCategory || 'VFR').toLowerCase()})`;
    const big = a.role === 'origin' || a.role === 'destination';
    return `<g><circle cx="${x(a.lon).toFixed(1)}" cy="${y(a.lat).toFixed(1)}" r="${big ? 7 : 4.5}" fill="${color}" stroke="var(--bg)" stroke-width="2"/>
      <text x="${(x(a.lon) + 9).toFixed(1)}" y="${(y(a.lat) + 4).toFixed(1)}" fill="var(--text)" font-size="11" font-family="monospace">${esc(a.icao)}</text></g>`;
  }).join('');
  return `<svg class="map" viewBox="0 0 ${W} ${H.toFixed(0)}" role="img" aria-label="Route map"><polyline points="${line}" fill="none" stroke="var(--accent)" stroke-width="2" stroke-dasharray="6 4"/>${dots}</svg>`;
}

function renderAirport(a, r) {
  const m = a.metar, t = a.taf;
  const period = a.tafAtEta;
  const perf = a.role === 'origin' ? r.performance.origin : a.role === 'destination' ? r.performance.destination : null;
  const wind = (x) => x ? `${typeof x.windDir !== 'number' ? 'VRB' : String(x.windDir).padStart(3, '0') + '°'} ${x.windKt ?? 0} kt${x.gustKt ? ' G' + x.gustKt : ''}` : '—';
  return `
    <div class="kv"><div><span>Role</span>${esc(a.role)}${a.distanceFromRouteNm ? ` · ${a.distanceFromRouteNm} nm off route` : ''}${a.distanceFromDestinationNm ? ` · ${Math.round(a.distanceFromDestinationNm)} nm from ${esc(r.destination.icao)}` : ''}</div>
      <div><span>Elevation / longest runway</span>${a.elevFt ?? '—'} ft · ${a.longestRunwayFt.toLocaleString()} ft${a.hasTower ? ' · tower' : ''}${a.crosswindKt != null ? ` · xwind ${a.crosswindKt} kt` : ''}</div>
      <div><span>Runways</span>${esc((a.runways ?? []).map((r) => `${r.id} (${r.lengthFt.toLocaleString()}×${r.widthFt})`).join(', ') || '—')}</div>
      <div><span>Expected here</span>${fmtTime(a.etaAt)}</div></div>
    <h3>Current weather ${m?.observedAt ? `· <span class="muted small">observed ${fmtTime(m.observedAt)}${(Date.now() - new Date(m.observedAt)) > 5400000 ? ' <b class="IFR">(old observation)</b>' : ''} · ${esc(m.cache)}</span>` : ''}</h3>
    ${m?.available ? `<div>${chip(m.flightCategory)}</div><div class="kv">
        <div><span>Wind</span>${wind(m)}</div><div><span>Visibility</span>${m.visibilitySm ?? '—'} SM</div>
        <div><span>Ceiling</span>${m.ceilingFt ? m.ceilingFt.toLocaleString() + ' ft' : 'None'}</div><div><span>Temp / dew</span>${m.tempC ?? '—'}° / ${m.dewpointC ?? '—'}°C</div>
        <div><span>Altimeter</span>${m.altimeterInHg ?? '—'} inHg</div>${m.weather ? `<div><span>Weather</span>${esc(m.weather)}</div>` : ''}</div><pre class="raw">${esc(m.raw)}</pre>` : `<p class="muted">No METAR available for this airport.</p>`}
    <h3>Forecast ${t ? `· <span class="muted small">${esc(t.source ?? '')}, ${esc(t.cache ?? '')}</span>` : ''}</h3>
    ${t?.available ? `${period ? `<div class="small muted">At the expected time: ${chip(period.flightCategory)} ${wind(period)}, ${period.visibilitySm ?? '—'} SM, ceiling ${period.ceilingFt ? period.ceilingFt.toLocaleString() + ' ft' : 'none'}</div>` : ''}<pre class="raw">${esc(t.raw)}</pre>` : `<p class="muted">No TAF issued for this airport.</p>`}
    ${perf ? `<h3>Runway performance</h3><div class="kv"><div><span>Density altitude</span>${perf.densityAltFt.toLocaleString()} ft</div>
      <div><span>${a.role === 'origin' ? 'Takeoff roll' : 'Landing roll'}</span>${(a.role === 'origin' ? perf.takeoffRollFt : perf.landingRollFt).toLocaleString()} ft</div>
      <div><span>Runway available</span>${perf.runwayAvailableFt.toLocaleString()} ft</div>
      <div><span>Safety margin</span>${(a.role === 'origin' ? perf.takeoffMarginRatio : perf.landingMarginRatio)}×</div></div>` : ''}`;
}

function render() {
  const { result: r, request, traceId } = state.current;
  const verdictClass = r.risk.verdict.replace('-', '');
  const wb = r.weightBalance, fuel = r.fuel;
  const rows = r.route.legs.map((l) => `<tr><td class="num">${l.fromNm}–${l.toNm}</td><td class="num">${l.courseDeg}°</td><td class="num">${l.windDir}° / ${l.windKt}</td><td class="num">${l.groundSpeedKt}</td><td class="num">${l.eteMin}</td></tr>`).join('');
  $('result').innerHTML = `
    <div class="card verdict ${esc(verdictClass)}">
      <div><div class="route">${esc(r.origin.icao)} → ${esc(r.destination.icao)}</div><div class="muted">${esc(r.origin.name)} to ${esc(r.destination.name)} · ${esc(r.aircraft.name)}</div></div>
      <div class="spacer"></div>
      <div><span class="big">${esc(r.risk.verdict)}</span> <span class="score">risk ${r.risk.score}/100</span></div>
      <div class="actions">
        ${state.savedId ? `<button id="refresh">Refresh briefing</button><button id="export">Download</button>` : `<button id="save">Save plan</button>`}
      </div>
    </div>
    <div class="card"><div class="stats">
      <div class="stat"><b>${Math.round(r.route.distanceNm)} nm</b><span>distance · ${r.route.trueCourse}° true</span></div>
      <div class="stat"><b>${hhmm(r.timing.eteMin)}</b><span>en route · ETA ${fmtTime(r.timing.eta)}</span></div>
      <div class="stat"><b>${fuel.requiredGal} gal</b><span>required of ${fuel.capacityGal}${fuel.alternateRequired ? ' · alternate needed' : ''}</span></div>
      <div class="stat"><b>${wb.takeoffWeightLb.toLocaleString()} lb</b><span>CG ${wb.cg} · ${wb.withinEnvelope ? 'in limits' : '<span class="high">OUT OF LIMITS</span>'}</span></div>
      <div class="stat"><b>${r.route.terrain.highestFt.toLocaleString()} ft</b><span>highest terrain · ${r.route.terrain.clearanceFt.toLocaleString()} ft clear</span></div>
      <div class="stat"><b>${r.timing.arrivalNight ? 'Night' : 'Day'}</b><span>arrival</span></div>
    </div>
    <h3>Why this call</h3>
    ${r.risk.factors.length ? `<ul class="factors">${r.risk.factors.map((f) => `<li><span class="impact">+${f.impact}</span><div><b>${esc(f.label)}</b><div class="muted">${esc(f.detail)}</div></div></li>`).join('')}</ul>` : '<p class="muted">Nothing concerning found.</p>'}
    </div>
    <div class="cols"><div class="card"><h2>Route</h2>${renderMap(r)}
        <details><summary class="muted small">Legs (${r.route.legs.length})</summary><table><tr><th>Dist nm</th><th class="num">Crs</th><th class="num">Wind</th><th class="num">GS</th><th class="num">Min</th></tr>${rows}</table></details></div>
      <div class="card"><h2>Alternates near ${esc(r.destination.icao)}</h2>
        <table><tr><th>Airport</th><th class="num">nm</th><th>At ETA</th><th class="num">Score</th></tr>${r.alternates.map((a, i) => `<tr><td>${i === 0 ? '★ ' : ''}<b>${esc(a.icao)}</b> <span class="muted small">${esc(a.name)}</span></td><td class="num">${a.distanceNm}</td><td>${chip(a.flightCategory)}</td><td class="num">${a.score}</td></tr>`).join('') || '<tr><td colspan="4" class="muted">None found</td></tr>'}</table>
        <p class="muted small">Lower score is better: distance, forecast at ETA, and whether it has a tower.</p></div></div>
    <div class="card"><h2>Airport briefings</h2>
      <div class="tabs">${r.airports.map((a, i) => `<button class="tab ${i === state.activeAirport ? 'active' : ''}" data-tab="${i}"><b>${esc(a.icao)}</b>${chip(a.metar?.flightCategory)}</button>`).join('')}</div>
      <div id="airport-panel"></div></div>
    <div class="card"><div class="trace">Trace <code>${esc(traceId)}</code> · ${r.cache.hits} cached, ${r.cache.misses} fetched${r.cache.stale ? `, ${r.cache.stale} stale` : ''} · generated ${fmtTime(r.generatedAt)}</div></div>`;
  const showAirport = () => { $('airport-panel').innerHTML = renderAirport(r.airports[state.activeAirport], r); };
  showAirport();
  document.querySelectorAll('.tab').forEach((b) => b.onclick = () => { state.activeAirport = Number(b.dataset.tab); render(); });
  $('result').classList.remove('hidden');
  if ($('save')) $('save').onclick = savePlan;
  if ($('refresh')) $('refresh').onclick = refreshPlan;
  if ($('export')) $('export').onclick = () => { location.href = `/api/plans/${state.savedId}/export`; };
}

// --- saved plans, cache, lab --------------------------------------------------------------------

async function savePlan() {
  const name = prompt('Name this plan', `${state.current.result.origin.icao} to ${state.current.result.destination.icao}`);
  if (name === null) return;
  try {
    const { plan } = await api('/api/plans', { method: 'POST', body: { name, request: state.current.request, result: state.current.result } });
    state.savedId = plan.id; render(); loadSaved(); toast('Plan saved');
  } catch (e) { toast(e.message); }
}

async function refreshPlan() {
  $('refresh').disabled = true;
  try {
    const { result } = await api(`/api/plans/${state.savedId}/refresh`, { method: 'POST', body: {} });
    state.current.result = result; state.current.traceId = result.traceId ?? state.current.traceId; render(); refreshCache(); toast('Briefing refreshed');
  } catch (e) { toast(e.message); render(); }
}

async function loadSaved() {
  const { plans } = await api('/api/plans');
  $('saved-empty').classList.toggle('hidden', plans.length > 0);
  $('saved').innerHTML = plans.map((p) => `<li data-id="${esc(p.id)}"><span class="name"><b>${esc(p.name)}</b><br><span class="muted small">${esc(p.origin)} → ${esc(p.destination)} · ${esc(p.aircraft)}</span></span><button class="x" data-del="${esc(p.id)}" title="Delete">✕</button></li>`).join('');
  $('saved').querySelectorAll('li').forEach((li) => li.onclick = async (e) => {
    if (e.target.dataset.del) {
      if (!confirm('Delete this plan?')) return;
      await api(`/api/plans/${e.target.dataset.del}`, { method: 'DELETE' }); if (state.savedId === e.target.dataset.del) { $('result').classList.add('hidden'); $('empty').classList.remove('hidden'); }
      return loadSaved();
    }
    const { plan } = await api(`/api/plans/${li.dataset.id}`);
    state.current = { request: plan.request, result: plan.result, traceId: '(saved briefing — refresh for a new trace)' }; state.savedId = plan.id; state.activeAirport = 0;
    $('empty').classList.add('hidden'); render();
  });
}

async function refreshCache() {
  try {
    const { kinds } = await api('/api/cache');
    $('cache-table').innerHTML = `<tr><th>Kind</th><th class="num">Entries</th><th class="num">Fresh</th><th class="num">Hits</th></tr>` +
      (kinds.map((k) => `<tr><td>${esc(k.kind)}</td><td class="num">${k.entries}</td><td class="num">${k.fresh}</td><td class="num">${k.hits}</td></tr>`).join('') || '<tr><td colspan="4" class="muted">Empty</td></tr>');
    $('cache-note').textContent = 'METAR 10 min · TAF 30 min · winds 1 h';
  } catch { /* ignore */ }
}

$('cache-clear').onclick = async () => {
  if (!confirm('Remove every cached weather and winds entry? The next briefing will refetch everything.')) return;
  try { const { removed } = await api('/api/cache', { method: 'DELETE' }); toast(`Cleared ${removed} cached entries`); refreshCache(); } catch (e) { toast(e.message); }
};

document.querySelectorAll('[data-lab]').forEach((select) => {
  select.onchange = async () => {
    const value = select.dataset.number !== undefined ? Number(select.value) : select.value;
    try { await api('/api/lab', { method: 'POST', body: { service: select.dataset.lab, faults: { [select.dataset.key]: value } } }); toast(`${select.dataset.lab}: ${select.dataset.key} = ${value}`); } catch (e) { toast(e.message); }
  };
});

async function bootApp() {
  defaultDeparture();
  const [{ aircraft }, lab] = await Promise.all([api('/api/aircraft'), api('/api/lab')]);
  $('aircraft').innerHTML = aircraft.map((a) => `<option value="${esc(a.key)}">${esc(a.name)}</option>`).join('');
  document.querySelectorAll('[data-lab]').forEach((s) => { const v = lab.faults[s.dataset.lab]?.[s.dataset.key]; if (v !== undefined) s.value = String(v); });
  loadSaved(); refreshCache();
}

(async () => {
  try { state.user = (await api('/api/auth/me')).user; } catch { state.user = null; }
  showSession();
  if (state.user) bootApp();
})();
