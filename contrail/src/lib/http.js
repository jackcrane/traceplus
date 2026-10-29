'use strict';
// A tiny router so the services stay readable. Server spans are created by the
// OpenTelemetry http instrumentation; this layer names them by route
// (low-cardinality, per the HTTP semantic conventions) and handles errors.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { trace } = require('@opentelemetry/api');
const { log } = require('./otel');

class AppError extends Error {
  /** `expected` = a normal outcome (bad password, unknown airport), not a bug. */
  constructor(status, code, message, { expected = status < 500, details } = {}) {
    super(message);
    this.name = 'AppError';
    this.status = status;
    this.code = code;
    this.expected = expected;
    this.details = details;
  }
}

/** Handlers return a plain body (200) or reply(status, body, headers). */
class Reply { constructor(status, body, headers = {}) { this.status = status; this.body = body; this.headers = headers; } }
const reply = (status, body, headers) => new Reply(status, body, headers);

function compile(route) {
  const names = [];
  const pattern = route.replace(/:([a-z]+)/gi, (_, name) => { names.push(name); return '([^/]+)'; });
  return { regex: new RegExp(`^${pattern}$`), names };
}

async function readJson(req) {
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 200_000) throw new AppError(413, 'payload_too_large', 'Request body too large');
  }
  if (!raw) return {};
  try { return JSON.parse(raw); } catch { throw new AppError(400, 'invalid_json', 'Body is not valid JSON'); }
}

function parseCookies(header = '') {
  return Object.fromEntries(header.split(';').map((c) => c.trim().split('=')).filter(([k]) => k).map(([k, ...v]) => [k, decodeURIComponent(v.join('='))]));
}

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };

function createService({ name, port, routes, faults, staticDir, beforeEach }) {
  const table = routes.map(([method, route, handler]) => ({ method, route, handler, ...compile(route) }));

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const span = trace.getActiveSpan();
    const send = (status, body, headers = {}) => {
      const traceId = span?.spanContext().traceId;
      const isText = typeof body === 'string';
      res.writeHead(status, {
        'content-type': isText ? 'text/plain; charset=utf-8' : 'application/json',
        'cache-control': 'no-store',
        ...(traceId ? { 'x-trace-id': traceId } : {}),
        ...headers,
      });
      res.end(isText ? body : JSON.stringify(body));
    };

    if (url.pathname === '/healthz') return send(200, { status: 'ok', service: name });
    if (url.pathname === '/admin/faults' && faults) {
      if (req.method === 'POST') { const body = await readJson(req); body.reset ? faults.reset() : faults.set(body); }
      return send(200, faults.snapshot());
    }

    const match = table.map((entry) => ({ entry, m: entry.method === req.method && entry.regex.exec(url.pathname) })).find((x) => x.m);
    if (!match) {
      if (staticDir && req.method === 'GET') {
        const file = path.join(staticDir, url.pathname === '/' ? 'index.html' : path.normalize(url.pathname).replace(/^(\.\.[/\\])+/, ''));
        span?.updateName('GET static');
        span?.setAttribute('http.route', 'static');
        if (file.startsWith(staticDir) && fs.existsSync(file) && fs.statSync(file).isFile()) {
          res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-cache' });
          return fs.createReadStream(file).pipe(res);
        }
      }
      return send(404, { error: 'not_found' });
    }

    const { entry, m } = match;
    // Name the span by the route template, never the raw path (cardinality!).
    span?.updateName(`${req.method} ${entry.route}`);
    span?.setAttribute('http.route', entry.route);

    try {
      const params = Object.fromEntries(entry.names.map((n, i) => [n, decodeURIComponent(m[i + 1])]));
      const body = req.method === 'GET' || req.method === 'DELETE' ? {} : await readJson(req);
      const context = { params, body, query: url.searchParams, req, cookies: parseCookies(req.headers.cookie) };
      if (beforeEach) await beforeEach(context, entry);
      const result = await entry.handler(context);
      result instanceof Reply ? send(result.status, result.body, result.headers) : send(200, result ?? {});
    } catch (error) {
      if (error instanceof AppError) {
        span?.setAttribute('error.type', error.code);
        if (error.expected) log.warn(error.message, { 'error.code': error.code, ...error.details });
        else { span?.recordException(error); log.error(error.message, { 'error.code': error.code, ...error.details }); }
        return send(error.status, { error: error.code, message: error.message, ...error.details });
      }
      span?.recordException(error);
      log.error('Unhandled error', { 'exception.type': error.name, 'exception.message': error.message, 'exception.stacktrace': error.stack });
      send(500, { error: 'internal_error', message: 'Something went wrong' });
    }
  });

  const host = process.env.HOST || '127.0.0.1';
  return new Promise((resolve) => server.listen(port, host, () => {
    log.info('Service listening', { 'server.address': host, 'server.port': port });
    resolve(server);
  }));
}

const PORTS = { web: 4400, airports: 4401, weather: 4402, planner: 4404 };
const urlOf = (service) => process.env[`${service.toUpperCase()}_URL`] || `http://127.0.0.1:${PORTS[service]}`;

/** JSON call to a sibling service. Trace context is propagated by the undici instrumentation. */
async function call(service, route, { method = 'POST', body, timeoutMs = 20_000 } = {}) {
  const response = await fetch(urlOf(service) + route, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new AppError(response.status, payload.error || 'upstream_error', payload.message || `${service} returned ${response.status}`, {
      expected: response.status < 500,
      details: { 'peer.service': service },
    });
  }
  return payload;
}

module.exports = { AppError, reply, createService, call, PORTS, urlOf, parseCookies };
