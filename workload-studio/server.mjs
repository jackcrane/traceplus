#!/usr/bin/env node
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { dirname, extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.APP_PORT || 4319);
const collector = (process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://127.0.0.1:4318').replace(/\/$/, '');
const million = 1000000n;
const products = [
  ['desk-lamp', 'Halo Desk Lamp', 79, 'Office', 12, 'Adjustable warmth and focused light.'],
  ['field-notes', 'Field Notes Set', 18, 'Stationery', 48, 'Three linen-bound daily notebooks.'],
  ['orbit-mug', 'Orbit Mug', 28, 'Kitchen', 7, 'Ceramic, double-walled, very blue.'],
  ['linen-throw', 'Linen Throw', 120, 'Home', 4, 'Stonewashed flax for unhurried Sundays.'],
  ['mechanical-keyboard', 'Keyframe 75', 189, 'Office', 5, 'Quiet tactile switches in a compact frame.'],
  ['carry-pouch', 'Everyday Carry Pouch', 42, 'Travel', 21, 'Waxed canvas for the small important things.']
].map(function (row) { return { id: row[0], name: row[1], price: row[2], category: row[3], stock: row[4], description: row[5] }; });
const carts = new Map(), orders = [], activity = [], cache = new Map(), profiles = new Map();
const now = () => BigInt(Date.now()) * million;
const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const random = (low, high) => Math.round(low + Math.random() * (high - low));
const hex = bytes => Array.from({ length: bytes }, () => Math.floor(Math.random() * 256).toString(16).padStart(2, '0')).join('');
const text = (key, stringValue) => ({ key, value: { stringValue: String(stringValue) } });
const number = (key, intValue) => ({ key, value: { intValue: String(intValue) } });
const flag = (key, boolValue) => ({ key, value: { boolValue: boolValue } });
function profile(session) {
  const name = profiles.get(session) || 'normal';
  if (name === 'rush') return { name, label: 'Holiday rush', speed: 2.3, retry: .35, hit: .32 };
  if (name === 'carrier') return { name, label: 'Carrier incident', speed: 1.4, retry: .55, hit: .72 };
  return { name, label: 'Normal traffic', speed: 1, retry: .08, hit: .78 };
}
function cart(session) { if (!carts.has(session)) carts.set(session, []); return carts.get(session); }
function summary(lines) {
  const subtotal = lines.reduce((total, line) => total + line.price * line.quantity, 0);
  const tax = Math.round(subtotal * .0825 * 100) / 100;
  return { items: lines, count: lines.reduce((total, line) => total + line.quantity, 0), subtotal, tax, total: subtotal + tax };
}
function attributes(values) {
  return Object.entries(values).map(function (entry) {
    return typeof entry[1] === 'boolean' ? flag(entry[0], entry[1]) : typeof entry[1] === 'number' ? number(entry[0], entry[1]) : text(entry[0], entry[1]);
  });
}
function makeTrace(request, route, session) {
  return { request, route, session, traceId: hex(16), rootId: hex(8), started: now(), spans: [], logs: [], metrics: [], profile: profile(session) };
}
async function span(trace, details, work) {
  const record = { traceId: trace.traceId, spanId: hex(8), parentSpanId: details.parent ? details.parent.spanId : trace.rootId, name: details.name, kind: details.kind || 3,
    startTimeUnixNano: String(now()), attributes: [text('service.name', details.service)].concat(attributes(details.attributes || {})), events: [] };
  try {
    const result = await work(record);
    record.status = { code: 1 };
    return result;
  } catch (error) {
    record.status = { code: 2, message: error.message };
    record.events.push({ name: 'exception', timeUnixNano: String(now()), attributes: [text('exception.type', error.name), text('exception.message', error.message)] });
    throw error;
  } finally {
    record.endTimeUnixNano = String(now());
    trace.spans.push(record);
  }
}
function addLog(trace, severity, body, values) {
  trace.logs.push({ timeUnixNano: String(now()), severityNumber: severity === 'ERROR' ? 17 : 9, severityText: severity, body: { stringValue: body },
    attributes: [text('service.name', 'northstar-storefront')].concat(attributes(values || {})) });
}
function addMetric(trace, name, milliseconds, values) {
  trace.metrics.push({ name: name, unit: 'ms', histogram: { aggregationTemporality: 2, dataPoints: [{ timeUnixNano: String(now()), count: '1', sum: milliseconds, explicitBounds: [10, 25, 50, 100, 250, 500, 1000], bucketCounts: ['0', '0', '0', '0', '0', '0', '0', '1'], attributes: attributes(values || {}) }] } });
}
function exportTrace(trace, root) {
  const grouped = Map.groupBy([root].concat(trace.spans), item => item.attributes.find(attribute => attribute.key === 'service.name').value.stringValue);
  const payloads = [{ endpoint: '/v1/traces', body: { resourceSpans: Array.from(grouped).map(function (entry) { return { resource: { attributes: [text('service.name', entry[0]), text('service.namespace', 'northstar-local'), text('deployment.environment', 'local')] }, scopeSpans: [{ scope: { name: 'northstar.app', version: '2.0.0' }, spans: entry[1] }] }; }) } }];
  if (trace.logs.length) payloads.push({ endpoint: '/v1/logs', body: { resourceLogs: [{ resource: { attributes: [text('service.name', 'northstar-storefront')] }, scopeLogs: [{ scope: { name: 'northstar.app' }, logRecords: trace.logs }] }] } });
  if (trace.metrics.length) payloads.push({ endpoint: '/v1/metrics', body: { resourceMetrics: [{ resource: { attributes: [text('service.name', 'northstar-storefront')] }, scopeMetrics: [{ scope: { name: 'northstar.app' }, metrics: trace.metrics }] }] } });
  payloads.forEach(function (payload) { fetch(collector + payload.endpoint, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload.body) }).catch(() => {}); });
}
async function traced(request, route, session, workflow) {
  const trace = makeTrace(request, route, session);
  let result;
  try { result = await workflow(trace); }
  catch (error) { result = { status: 500, error: error.message || 'Unexpected workflow error' }; addLog(trace, 'ERROR', 'Unhandled application workflow error', { route: route, error: error.message }); }
  const ended = now(), status = result.status || 200, duration = Number((ended - trace.started) / million);
  const root = { traceId: trace.traceId, spanId: trace.rootId, name: route, kind: 2, startTimeUnixNano: String(trace.started), endTimeUnixNano: String(ended),
    attributes: [text('service.name', 'northstar-storefront'), text('http.request.method', request.method), text('http.route', route), number('http.response.status_code', status), text('northstar.profile', trace.profile.label)], status: { code: status >= 400 ? 2 : 1 } };
  addMetric(trace, 'northstar.request.duration', duration, { route: route, status: status });
  addLog(trace, status >= 400 ? 'ERROR' : 'INFO', 'Request completed: ' + route, { route: route, status: status, duration_ms: duration });
  exportTrace(trace, root);
  activity.unshift({ traceId: trace.traceId, route: route, duration: duration, status: status, spans: trace.spans.length + 1, logs: trace.logs.length, metrics: trace.metrics.length, profile: trace.profile.label, at: new Date().toLocaleTimeString() });
  activity.splice(18);
  return result;
}
async function productRead(trace, parent, productId) {
  return span(trace, { name: 'catalog.get_product', service: 'catalog-service', parent: parent, attributes: { 'product.id': productId } }, async catalogSpan => {
    const key = 'product:' + productId, found = cache.get(key);
    await span(trace, { name: found ? 'redis GET product (hit)' : 'redis GET product (miss)', service: 'catalog-cache', parent: catalogSpan, attributes: { 'db.system': 'redis', 'cache.hit': Boolean(found) } }, () => pause(random(3, 12)));
    if (found) return found;
    const product = await span(trace, { name: 'SELECT product', service: 'catalog-service', parent: catalogSpan, attributes: { 'db.system': 'postgresql', 'db.operation.name': 'SELECT' } }, async () => { await pause(random(18, 52)); return products.find(item => item.id === productId); });
    cache.set(key, product);
    return product;
  });
}
async function reserve(trace, parent, product) {
  return span(trace, { name: 'inventory.reserve', service: 'inventory-service', parent: parent, attributes: { 'product.id': product.id } }, async reservation => {
    await span(trace, { name: 'SELECT stock FOR UPDATE', service: 'inventory-service', parent: reservation, attributes: { 'db.system': 'postgresql', 'db.operation.name': 'SELECT' } }, () => pause(random(14, 40) * trace.profile.speed));
    if (Math.random() < trace.profile.retry) {
      addLog(trace, 'INFO', 'Inventory reservation encountered contention', { product_id: product.id });
      await span(trace, { name: 'inventory reservation retry', service: 'inventory-service', parent: reservation, attributes: { 'retry.attempt': 1, 'retry.reason': 'row_lock_contention' } }, () => pause(random(40, 120) * trace.profile.speed));
    }
    await span(trace, { name: 'UPDATE reservations', service: 'inventory-service', parent: reservation, attributes: { 'db.system': 'postgresql', 'db.operation.name': 'UPDATE' } }, () => pause(random(8, 26) * trace.profile.speed));
    return { id: 'rsrv-' + hex(5) };
  });
}
async function requestBody(request) {
  let data = '';
  for await (const chunk of request) { data += chunk; if (data.length > 100000) throw new Error('Request body is too large'); }
  return data ? JSON.parse(data) : {};
}
function send(response, status, data) { response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); response.end(JSON.stringify(data)); }
function respond(response, result) { send(response, result.status || 200, result); }
async function api(request, response) {
  const url = new URL(request.url, 'http://' + request.headers.host), session = request.headers['x-northstar-session'] || 'anonymous';
  if (request.method === 'PUT' && url.pathname === '/api/profile') {
    const data = await requestBody(request);
    if (!['normal', 'rush', 'carrier'].includes(data.profile)) return send(response, 400, { error: 'Unknown operating profile' });
    profiles.set(session, data.profile); return send(response, 200, { profile: data.profile });
  }
  if (request.method === 'GET' && url.pathname === '/api/products') return respond(response, await traced(request, 'GET /api/products', session, async trace => {
    const warm = Math.random() < trace.profile.hit;
    await span(trace, { name: warm ? 'catalog list cache hit' : 'catalog list cache miss', service: 'catalog-cache', attributes: { 'db.system': 'redis', 'cache.hit': warm } }, () => pause((warm ? random(2, 8) : random(20, 50)) * trace.profile.speed));
    if (!warm) await span(trace, { name: 'SELECT products by availability', service: 'catalog-service', attributes: { 'db.system': 'postgresql', 'db.operation.name': 'SELECT' } }, () => pause(random(20, 60) * trace.profile.speed));
    await span(trace, { name: 'recommendations.seed_collection', service: 'recommendation-service', attributes: { 'recommendation.surface': 'home' } }, () => pause(random(8, 24)));
    return { products: products };
  }));
  if (request.method === 'GET' && url.pathname.startsWith('/api/products/')) return respond(response, await traced(request, 'GET /api/products/:id', session, async trace => {
    const product = await productRead(trace, null, url.pathname.split('/').at(-1));
    if (!product) return { status: 404, error: 'Product not found' };
    await Promise.all([
      span(trace, { name: 'reviews.aggregate', service: 'review-service', attributes: { 'product.id': product.id, 'db.system': 'elasticsearch' } }, () => pause(random(20, 70) * trace.profile.speed)),
      span(trace, { name: 'inventory.available_to_sell', service: 'inventory-service', attributes: { 'product.id': product.id } }, () => pause(random(10, 36) * trace.profile.speed)),
      span(trace, { name: 'recommendations.related_products', service: 'recommendation-service', attributes: { 'product.id': product.id } }, () => pause(random(18, 56))),
    ]);
    return { product: product, related: products.filter(item => item.category === product.category && item.id !== product.id).slice(0, 3) };
  }));
  if (request.method === 'GET' && url.pathname === '/api/search') return respond(response, await traced(request, 'GET /api/search', session, async trace => {
    const query = (url.searchParams.get('q') || '').trim().toLowerCase();
    await span(trace, { name: 'search.normalize_query', service: 'search-api', attributes: { 'search.query': query } }, () => pause(random(2, 8)));
    const found = await span(trace, { name: 'search.products', service: 'search-api', attributes: { 'db.system': 'elasticsearch', 'search.query': query } }, async searchSpan => {
      await Promise.all([
        span(trace, { name: 'search.shard catalog-a', service: 'search-cluster', parent: searchSpan, attributes: { 'search.shard': 'catalog-a' } }, () => pause(random(18, 64) * trace.profile.speed)),
        span(trace, { name: 'search.shard catalog-b', service: 'search-cluster', parent: searchSpan, attributes: { 'search.shard': 'catalog-b' } }, () => pause(random(18, 64) * trace.profile.speed)),
      ]);
      return products.filter(product => (product.name + ' ' + product.category + ' ' + product.description).toLowerCase().includes(query));
    });
    await span(trace, { name: 'analytics.search_observed', service: 'analytics-pipeline', attributes: { 'messaging.system': 'kafka', 'search.query': query } }, () => pause(random(2, 10)));
    return { products: found };
  }));
  if (request.method === 'GET' && url.pathname === '/api/cart') return respond(response, await traced(request, 'GET /api/cart', session, async trace => {
    await span(trace, { name: 'cart.read', service: 'cart-service', attributes: { 'db.system': 'redis' } }, () => pause(random(4, 16)));
    return summary(cart(session));
  }));
  if (request.method === 'POST' && url.pathname === '/api/cart') return respond(response, await traced(request, 'POST /api/cart', session, async trace => {
    const data = await requestBody(request), product = await productRead(trace, null, data.productId);
    if (!product) return { status: 404, error: 'Product not found' };
    const lineItems = cart(session);
    const work = await Promise.all([
      reserve(trace, null, product),
      span(trace, { name: 'pricing.quote', service: 'pricing-service', attributes: { 'product.id': product.id } }, async pricing => Promise.all([
        span(trace, { name: 'promotion rules lookup', service: 'pricing-service', parent: pricing, attributes: { 'db.system': 'postgresql' } }, () => pause(random(8, 28))),
        span(trace, { name: 'tax category resolve', service: 'tax-service', parent: pricing }, () => pause(random(5, 16))),
      ])),
    ]);
    const line = lineItems.find(item => item.id === product.id);
    if (line) line.quantity += 1; else lineItems.push(Object.assign({}, product, { quantity: 1, reservation: work[0].id }));
    await Promise.all([
      span(trace, { name: 'cart.upsert_line', service: 'cart-service', attributes: { 'db.system': 'redis' } }, () => pause(random(5, 18))),
      span(trace, { name: 'analytics.cart_updated', service: 'analytics-pipeline', attributes: { 'messaging.system': 'kafka', 'product.id': product.id } }, () => pause(random(2, 9))),
    ]);
    return summary(lineItems);
  }));
  if (request.method === 'POST' && url.pathname === '/api/checkout') return respond(response, await traced(request, 'POST /api/checkout', session, async trace => {
    const input = await requestBody(request), lineItems = cart(session);
    if (!lineItems.length) return { status: 400, error: 'Your cart is empty.' };
    const order = await span(trace, { name: 'checkout.orchestrate', service: 'checkout-service', attributes: { 'cart.item_count': lineItems.length } }, async checkout => {
      await span(trace, { name: 'identity.resolve_customer', service: 'identity-service', parent: checkout }, () => pause(random(10, 36)));
      await Promise.all(lineItems.map(item => reserve(trace, checkout, item)));
      await span(trace, { name: 'fraud.screen_order', service: 'fraud-service', parent: checkout, attributes: { 'risk.model': 'v3' } }, async fraud => Promise.all([
        span(trace, { name: 'risk rules evaluate', service: 'fraud-service', parent: fraud, attributes: { 'db.system': 'postgresql' } }, () => pause(random(18, 58) * trace.profile.speed)),
        span(trace, { name: 'device reputation check', service: 'fraud-vendor', parent: fraud, attributes: { 'server.address': 'risk.vendor.local' } }, () => pause(random(24, 85) * trace.profile.speed)),
      ]));
      await span(trace, { name: 'payments.authorize', service: 'payment-service', parent: checkout, attributes: { 'payment.method': 'test_card' } }, async payment => {
        await span(trace, { name: 'gateway.authorize', service: 'payment-gateway', parent: payment, attributes: { 'server.address': 'payments.local' } }, () => pause(random(45, 135) * trace.profile.speed));
        if (Math.random() < trace.profile.retry) { addLog(trace, 'INFO', 'Payment gateway responded slowly; retrying authorization', { retry_attempt: 1 }); await span(trace, { name: 'gateway.authorize retry', service: 'payment-gateway', parent: payment, attributes: { 'retry.attempt': 1, 'retry.reason': 'upstream_timeout' } }, () => pause(random(80, 220) * trace.profile.speed)); }
      });
      const created = await span(trace, { name: 'orders.create_transaction', service: 'order-service', parent: checkout, attributes: { 'db.system': 'postgresql' } }, async transaction => {
        await span(trace, { name: 'INSERT order', service: 'order-service', parent: transaction, attributes: { 'db.operation.name': 'INSERT' } }, () => pause(random(12, 35)));
        await span(trace, { name: 'INSERT outbox event', service: 'order-service', parent: transaction, attributes: { 'db.operation.name': 'INSERT' } }, () => pause(random(6, 19)));
        return Object.assign({ id: 'NS-' + (1000 + orders.length), customer: input.customer || 'Guest', status: 'Paid', createdAt: new Date().toISOString(), items: structuredClone(lineItems) }, summary(lineItems));
      });
      await Promise.all([
        span(trace, { name: 'shipping.quote_fanout', service: 'shipping-service', parent: checkout }, async shipping => Promise.all([
          span(trace, { name: 'carrier rate Northline', service: 'carrier-northline', parent: shipping }, () => pause(random(30, 110) * trace.profile.speed)),
          span(trace, { name: 'carrier rate Parcelly', service: 'carrier-parcelly', parent: shipping }, () => pause(random(30, 110) * trace.profile.speed)),
        ])),
        span(trace, { name: 'publish order.created', service: 'order-service', parent: checkout, attributes: { 'messaging.system': 'kafka', 'messaging.destination.name': 'order.created' } }, () => pause(random(3, 14))),
        span(trace, { name: 'notifications.queue_receipt', service: 'notification-service', parent: checkout, attributes: { 'messaging.system': 'kafka' } }, () => pause(random(3, 12))),
      ]);
      return created;
    });
    orders.unshift(order); carts.set(session, []);
    return { order: order };
  }));
  if (request.method === 'GET' && url.pathname === '/api/orders') return respond(response, await traced(request, 'GET /api/orders', session, async trace => {
    await span(trace, { name: 'orders.list_recent', service: 'order-service', attributes: { 'db.system': 'postgresql' } }, () => pause(random(12, 40)));
    return { orders: orders };
  }));
  if (request.method === 'POST' && /^\/api\/orders\/[^/]+\/advance$/.test(url.pathname)) return respond(response, await traced(request, 'POST /api/orders/:id/advance', session, async trace => {
    const order = orders.find(item => item.id === url.pathname.split('/')[3]);
    if (!order) return { status: 404, error: 'Order not found' };
    if (order.status === 'Shipped') return { status: 409, error: 'Order is already shipped' };
    await span(trace, { name: 'fulfillment.plan_pick', service: 'warehouse-service', attributes: { 'order.id': order.id } }, async fulfillment => {
      await Promise.all(order.items.map(item => span(trace, { name: 'warehouse.allocate_bin', service: 'warehouse-service', parent: fulfillment, attributes: { 'product.id': item.id } }, () => pause(random(18, 55) * trace.profile.speed))));
      await span(trace, { name: 'carrier.create_label', service: 'shipping-service', parent: fulfillment, attributes: { 'order.id': order.id } }, async label => {
        await span(trace, { name: 'carrier label request', service: 'carrier-northline', parent: label }, () => pause(random(45, 145) * trace.profile.speed));
        if (trace.profile.name === 'carrier') await span(trace, { name: 'carrier label retry', service: 'carrier-northline', parent: label, attributes: { 'retry.attempt': 1, 'retry.reason': 'carrier_503' } }, () => pause(random(80, 220)));
      });
      await span(trace, { name: 'publish shipment.created', service: 'warehouse-service', parent: fulfillment, attributes: { 'messaging.system': 'kafka' } }, () => pause(random(3, 12)));
    });
    order.status = 'Shipped'; return { order: order };
  }));
  if (request.method === 'POST' && /^\/api\/orders\/[^/]+\/return$/.test(url.pathname)) return respond(response, await traced(request, 'POST /api/orders/:id/return', session, async trace => {
    const order = orders.find(item => item.id === url.pathname.split('/')[3]);
    if (!order) return { status: 404, error: 'Order not found' };
    if (order.status !== 'Shipped') return { status: 409, error: 'Only shipped orders can be returned' };
    await span(trace, { name: 'returns.authorize', service: 'returns-service', attributes: { 'order.id': order.id } }, async returns => {
      await span(trace, { name: 'eligibility.policy_evaluate', service: 'returns-service', parent: returns, attributes: { 'policy.version': '2026-10' } }, () => pause(random(12, 38)));
      await Promise.all([
        span(trace, { name: 'payments.create_refund', service: 'payment-service', parent: returns, attributes: { 'payment.method': 'test_card' } }, async refund => {
          await span(trace, { name: 'gateway.refund', service: 'payment-gateway', parent: refund, attributes: { 'server.address': 'payments.local' } }, () => pause(random(40, 120) * trace.profile.speed));
          if (Math.random() < trace.profile.retry) await span(trace, { name: 'gateway.refund retry', service: 'payment-gateway', parent: refund, attributes: { 'retry.attempt': 1, 'retry.reason': 'gateway_429' } }, () => pause(random(70, 190) * trace.profile.speed));
        }),
        span(trace, { name: 'returns.create_label', service: 'shipping-service', parent: returns }, async label => {
          await span(trace, { name: 'carrier return_label request', service: 'carrier-parcelly', parent: label }, () => pause(random(35, 115) * trace.profile.speed));
          await span(trace, { name: 'publish return.initiated', service: 'returns-service', parent: label, attributes: { 'messaging.system': 'kafka', 'messaging.destination.name': 'return.initiated' } }, () => pause(random(3, 12)));
        }),
      ]);
      await Promise.all(order.items.map(item => span(trace, { name: 'inventory.schedule_restock', service: 'inventory-service', parent: returns, attributes: { 'product.id': item.id } }, () => pause(random(12, 42)))));
      await span(trace, { name: 'notifications.queue_return_confirmation', service: 'notification-service', parent: returns, attributes: { 'messaging.system': 'kafka' } }, () => pause(random(3, 12)));
    });
    order.status = 'Return initiated'; return { order: order };
  }));
  if (request.method === 'GET' && url.pathname === '/api/activity') return send(response, 200, { activity: activity, profile: profile(session).name, collector: collector + '/v1/traces' });
  return send(response, 404, { error: 'Not found' });
}
async function staticFile(request, response) {
  const path = request.url === '/' ? 'index.html' : request.url.slice(1).split('?')[0];
  if (!/^[a-zA-Z0-9._/-]+$/.test(path) || path.includes('..')) return send(response, 404, { error: 'Not found' });
  try { const file = await readFile(join(directory, 'public', path)); response.writeHead(200, { 'content-type': extname(path) === '.js' ? 'text/javascript; charset=utf-8' : 'text/html; charset=utf-8' }); response.end(file); }
  catch { send(response, 404, { error: 'Not found' }); }
}
http.createServer((request, response) => request.url.startsWith('/api/') ? api(request, response).catch(error => send(response, 500, { error: error.message })) : staticFile(request, response))
  .listen(port, '127.0.0.1', () => console.log('Northstar Local is running at http://127.0.0.1:' + port));
