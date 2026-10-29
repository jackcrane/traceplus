'use strict';
// web: the public face. Serves the single-page app and the JSON API; owns authentication
// (scrypt passwords, opaque session tokens stored hashed in Postgres) and saved plans.
const crypto = require('node:crypto');
const { promisify } = require('node:util');
const { ROOT_CONTEXT, context, trace } = require('@opentelemetry/api');
const { createService, AppError, reply, call, PORTS, urlOf } = require('../lib/http');
const { withSpan, tracer, meter, log } = require('../lib/otel');
const { query, transaction } = require('../lib/pg');
const cache = require('../lib/cache');
const path = require('node:path');

const scrypt = promisify(crypto.scrypt);
const SESSION_COOKIE = 'contrail_session';
const SESSION_DAYS = 7;
const MAX_FAILED_LOGINS = 5;

const authAttempts = meter.createCounter('contrail.auth.attempts', { description: 'Registrations and logins by outcome.', unit: '{attempt}' });
let activeSessions = 0, registeredUsers = 0;
meter.createObservableGauge('contrail.sessions.active', { description: 'Unexpired sessions.', unit: '{session}' }).addCallback((r) => r.observe(activeSessions));
meter.createObservableGauge('contrail.users', { description: 'Registered users.', unit: '{user}' }).addCallback((r) => r.observe(registeredUsers));

// --- passwords & sessions ------------------------------------------------------------------------

async function hashPassword(password, saltHex = crypto.randomBytes(16).toString('hex')) {
  return withSpan('auth.hash_password', { attributes: { 'app.auth.algorithm': 'scrypt' } }, async () => {
    const key = await scrypt(password, Buffer.from(saltHex, 'hex'), 64, { N: 16384, r: 8, p: 1 });
    return `scrypt$${saltHex}$${key.toString('hex')}`;
  });
}

async function verifyPassword(password, stored) {
  const [, salt, expected] = stored.split('$');
  const actual = (await hashPassword(password, salt)).split('$')[2];
  return crypto.timingSafeEqual(Buffer.from(actual, 'hex'), Buffer.from(expected, 'hex'));
}

const sha256 = (value) => crypto.createHash('sha256').update(value).digest('hex');

async function createSession(userId, userAgent) {
  return withSpan('auth.create_session', async () => {
    const token = crypto.randomBytes(32).toString('base64url');
    await query(`INSERT INTO sessions (token_hash, user_id, expires_at, user_agent) VALUES ($1, $2, now() + make_interval(days => $3), $4)`, [sha256(token), userId, SESSION_DAYS, userAgent?.slice(0, 200)]);
    return token;
  });
}

const cookieFor = (token, maxAge = SESSION_DAYS * 86400) => ({ 'set-cookie': `${SESSION_COOKIE}=${token}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${maxAge}` });

async function authenticate(ctx) {
  const token = ctx.cookies[SESSION_COOKIE];
  if (!token) return null;
  return withSpan('auth.authenticate', async (span) => {
    const { rows } = await query(
      `SELECT u.id, u.email, u.display_name AS "displayName", s.last_seen_at < now() - interval '1 minute' AS touch
       FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = $1 AND s.expires_at > now()`, [sha256(token)]);
    const user = rows[0];
    span.setAttribute('app.auth.session_valid', Boolean(user));
    if (user?.touch) await query('UPDATE sessions SET last_seen_at = now() WHERE token_hash = $1', [sha256(token)]); // throttled write
    if (user) trace.getActiveSpan()?.setAttribute('enduser.id', user.id);
    return user ?? null;
  });
}

const PUBLIC = new Set(['POST /api/auth/register', 'POST /api/auth/login', 'GET /api/auth/me', 'POST /api/auth/logout']);

async function guard(ctx, entry) {
  if (!entry.route.startsWith('/api/')) return;
  ctx.user = await authenticate(ctx);
  if (!ctx.user && !PUBLIC.has(`${entry.method} ${entry.route}`)) throw new AppError(401, 'unauthenticated', 'Please sign in');
  if (ctx.user) trace.getActiveSpan()?.setAttribute('enduser.id', ctx.user.id);
}

// --- handlers ------------------------------------------------------------------------------------

async function register({ body, req }) {
  const email = String(body.email ?? '').trim().toLowerCase(), name = String(body.displayName ?? '').trim(), password = String(body.password ?? '');
  try {
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new AppError(422, 'invalid_email', 'Enter a valid email address');
    if (name.length < 2) throw new AppError(422, 'invalid_name', 'Enter your name');
    if (password.length < 8) throw new AppError(422, 'weak_password', 'Password must be at least 8 characters');
    const hash = await hashPassword(password);
    const { rows } = await query(`INSERT INTO users (email, display_name, password_hash) VALUES ($1, $2, $3) ON CONFLICT (email) DO NOTHING RETURNING id`, [email, name, hash]);
    if (!rows[0]) throw new AppError(409, 'email_taken', 'An account with that email already exists');
    const token = await createSession(rows[0].id, req.headers['user-agent']);
    authAttempts.add(1, { 'app.auth.operation': 'register', outcome: 'success' });
    log.info('User registered', { 'enduser.id': rows[0].id });
    registeredUsers++;
    return reply(201, { user: { id: rows[0].id, email, displayName: name } }, cookieFor(token));
  } catch (error) { if (error.code) authAttempts.add(1, { 'app.auth.operation': 'register', outcome: error.code }); throw error; }
}

async function login({ body, req }) {
  const email = String(body.email ?? '').trim().toLowerCase(), password = String(body.password ?? '');
  const { rows: [{ failures }] } = await query(`SELECT count(*)::int AS failures FROM login_attempts WHERE email = $1 AND NOT succeeded AND at > now() - interval '15 minutes'`, [email]);
  if (failures >= MAX_FAILED_LOGINS) {
    authAttempts.add(1, { 'app.auth.operation': 'login', outcome: 'rate_limited' });
    log.warn('Login blocked by rate limit', { 'app.auth.failures': failures });
    throw new AppError(429, 'too_many_attempts', 'Too many failed attempts. Try again in 15 minutes.');
  }
  const { rows } = await query('SELECT id, email, display_name AS "displayName", password_hash FROM users WHERE email = $1', [email]);
  // Hash even for unknown emails so response time does not reveal which accounts exist.
  const ok = rows[0] ? await verifyPassword(password, rows[0].password_hash) : (await hashPassword(password), false);
  await query('INSERT INTO login_attempts (email, succeeded) VALUES ($1, $2)', [email, ok]);
  if (!ok) {
    authAttempts.add(1, { 'app.auth.operation': 'login', outcome: 'bad_credentials' });
    log.warn('Login failed', { 'app.auth.failures': failures + 1 });
    throw new AppError(401, 'bad_credentials', 'Incorrect email or password');
  }
  const token = await createSession(rows[0].id, req.headers['user-agent']);
  authAttempts.add(1, { 'app.auth.operation': 'login', outcome: 'success' });
  log.info('User signed in', { 'enduser.id': rows[0].id });
  return reply(200, { user: { id: rows[0].id, email, displayName: rows[0].displayName } }, cookieFor(token));
}

const withTrace = (result) => ({ ...result, traceId: trace.getActiveSpan()?.spanContext().traceId });

async function runPlan(request, user) {
  const started = performance.now();
  const result = await call('planner', '/plan', { body: request, timeoutMs: 45_000 });
  await query(`INSERT INTO plan_runs (user_id, origin, destination, aircraft, verdict, risk_score, duration_ms) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [user.id, result.origin.icao, result.destination.icao, result.aircraftKey, result.risk.verdict, result.risk.score, Math.round(performance.now() - started)]);
  return result;
}

const PLAN_COLUMNS = `id, name, origin, destination, aircraft, created_at AS "createdAt"`;

createService({
  name: 'web', port: PORTS.web, staticDir: path.join(__dirname, '..', '..', 'public'), beforeEach: guard,
  routes: [
    ['POST', '/api/auth/register', register],
    ['POST', '/api/auth/login', login],
    ['POST', '/api/auth/logout', async ({ cookies }) => {
      if (cookies[SESSION_COOKIE]) await query('DELETE FROM sessions WHERE token_hash = $1', [sha256(cookies[SESSION_COOKIE])]);
      return reply(200, { ok: true }, cookieFor('', 0));
    }],
    ['GET', '/api/auth/me', ({ user }) => ({ user: user ? { id: user.id, email: user.email, displayName: user.displayName } : null })],

    ['GET', '/api/airports/search', async ({ query: q }) => call('airports', `/search?q=${encodeURIComponent(q.get('q') ?? '')}`, { method: 'GET' })],
    ['GET', '/api/aircraft', () => call('planner', '/aircraft', { method: 'GET' })],
    ['POST', '/api/plan', async ({ body, user }) => withTrace(await runPlan(body, user))],

    ['GET', '/api/plans', async ({ user }) => ({ plans: (await query(`SELECT ${PLAN_COLUMNS} FROM plans WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50`, [user.id])).rows })],
    ['POST', '/api/plans', async ({ body, user }) => {
      if (!body.request || !body.result) throw new AppError(400, 'invalid_plan', 'request and result are required');
      const name = String(body.name || `${body.result.origin.icao} to ${body.result.destination.icao}`).slice(0, 80);
      const { rows } = await query(`INSERT INTO plans (user_id, name, origin, destination, aircraft, request, result) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING ${PLAN_COLUMNS}`,
        [user.id, name, body.result.origin.icao, body.result.destination.icao, body.result.aircraftKey, body.request, body.result]);
      log.info('Plan saved', { 'app.plan.id': rows[0].id, 'app.route': `${rows[0].origin}-${rows[0].destination}` });
      return reply(201, { plan: rows[0] });
    }],
    ['GET', '/api/plans/:id', async ({ params, user }) => {
      const { rows } = await query(`SELECT ${PLAN_COLUMNS}, request, result FROM plans WHERE id::text = $1 AND user_id = $2`, [params.id, user.id]);
      if (!rows[0]) throw new AppError(404, 'plan_not_found', 'No such saved plan');
      return { plan: rows[0] };
    }],
    ['POST', '/api/plans/:id/refresh', async ({ params, user }) => {
      const { rows } = await query('SELECT request FROM plans WHERE id::text = $1 AND user_id = $2', [params.id, user.id]);
      if (!rows[0]) throw new AppError(404, 'plan_not_found', 'No such saved plan');
      const request = { ...rows[0].request, departureTime: undefined }; // re-brief against "now"
      const result = await runPlan(request, user);
      await query('UPDATE plans SET result = $3, request = $4 WHERE id::text = $1 AND user_id = $2', [params.id, user.id, result, request]);
      return withTrace({ result });
    }],
    ['DELETE', '/api/plans/:id', async ({ params, user }) => {
      const { rowCount } = await query('DELETE FROM plans WHERE id::text = $1 AND user_id = $2', [params.id, user.id]);
      if (!rowCount) throw new AppError(404, 'plan_not_found', 'No such saved plan');
      return { deleted: true };
    }],
    ['GET', '/api/plans/:id/export', async ({ params, user }) => {
      const { rows } = await query('SELECT result FROM plans WHERE id::text = $1 AND user_id = $2', [params.id, user.id]);
      if (!rows[0]) throw new AppError(404, 'plan_not_found', 'No such saved plan');
      return reply(200, rows[0].result.briefingText, { 'content-disposition': 'attachment; filename="briefing.txt"' });
    }],

    ['GET', '/api/cache', async () => ({ kinds: await cache.stats() })],
    ['DELETE', '/api/cache', async ({ user }) => {
      const removed = await cache.clear();
      log.warn('Cache cleared', { 'enduser.id': user.id, 'cache.entries_removed': removed });
      return { removed };
    }],

    ['GET', '/api/lab', async () => {
      const services = ['weather', 'planner'];
      const entries = await Promise.all(services.map(async (s) => [s, await fetch(urlOf(s) + '/admin/faults').then((r) => r.json())]));
      return { faults: Object.fromEntries(entries) };
    }],
    ['POST', '/api/lab', async ({ body, user }) => {
      if (!['weather', 'planner'].includes(body.service)) throw new AppError(422, 'unknown_service', 'Unknown service');
      const response = await fetch(urlOf(body.service) + '/admin/faults', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body.faults ?? {}) });
      log.warn('Fault injection changed', { 'enduser.id': user.id, 'app.lab.service': body.service, 'app.lab.faults': JSON.stringify(body.faults) });
      return { faults: await response.json() };
    }],
  ],
}).then(() => {
  const refreshGauges = async () => {
    const [{ rows: [s] }, { rows: [u] }] = await Promise.all([query('SELECT count(*)::int AS n FROM sessions WHERE expires_at > now()'), query('SELECT count(*)::int AS n FROM users')]);
    activeSessions = s.n; registeredUsers = u.n;
  };
  refreshGauges().catch(() => {});
  // Background job: sweep expired sessions. A root span, because no request caused it.
  setInterval(() => {
    const span = tracer.startSpan('auth.sweep_sessions', { root: true });
    context.with(trace.setSpan(ROOT_CONTEXT, span), async () => {
      try {
        const swept = await transaction(async (client) => (await client.query('DELETE FROM sessions WHERE expires_at < now()')).rowCount);
        await query(`DELETE FROM login_attempts WHERE at < now() - interval '1 day'`);
        await refreshGauges();
        span.setAttribute('app.sessions.swept', swept);
        if (swept) log.info('Expired sessions removed', { 'app.sessions.swept': swept });
      } catch (error) { span.recordException(error); log.error('Session sweep failed', { 'exception.message': error.message }); }
      finally { span.end(); }
    });
  }, 30_000).unref();
});
