#!/usr/bin/env node
'use strict';
// Process supervisor: applies the database migration, then starts the five services,
// each as its own process with its own telemetry pipeline. Runs as the container's entrypoint.
const { spawn } = require('node:child_process');
const path = require('node:path');
const net = require('node:net');
const { PORTS } = require('./lib/http');

const endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://127.0.0.1:4318';
const COLORS = { migrate: 90, web: 36, airports: 35, weather: 34, planner: 32 };
const children = [];
let shuttingDown = false;

function start(name, script) {
  const child = spawn(process.execPath, ['--require', path.join(__dirname, 'telemetry.js'), path.join(__dirname, script)], {
    env: { ...process.env, OTEL_SERVICE_NAME: `contrail-${name}`, OTEL_EXPORTER_OTLP_ENDPOINT: endpoint },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const prefix = `\x1b[${COLORS[name]}m${name.padEnd(8)}\x1b[0m │ `;
  for (const stream of [child.stdout, child.stderr]) {
    stream.on('data', (chunk) => String(chunk).split('\n').filter(Boolean).forEach((line) => console.log(prefix + line)));
  }
  children.push(child);
  return new Promise((resolve) => child.on('exit', (code) => {
    if (!shuttingDown && name !== 'migrate') console.log(`${prefix}exited with code ${code}`);
    resolve(code);
  }));
}

const waitForPort = (port) => new Promise((resolve) => {
  const attempt = () => {
    const socket = net.connect(port, '127.0.0.1').once('connect', () => { socket.destroy(); resolve(); }).once('error', () => setTimeout(attempt, 150));
  };
  attempt();
});

const reachable = (url) => new Promise((resolve) => {
  const { hostname, port } = new URL(url);
  net.connect(Number(port) || 80, hostname).setTimeout(1500).once('connect', function () { this.destroy(); resolve(true); }).once('error', () => resolve(false)).once('timeout', () => resolve(false));
});

function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log('\nShutting down (flushing telemetry)...');
  children.forEach((child) => child.kill('SIGTERM')); // SIGTERM lets each SDK flush
  setTimeout(() => process.exit(0), 3000).unref();
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

(async () => {
  console.log(`Contrail → OTLP/HTTP JSON → ${endpoint}`);
  if (!(await reachable(endpoint))) console.log(`\x1b[33m! Nothing is listening on ${endpoint}. Start TracePlus first, or telemetry will be dropped.\x1b[0m`);
  for (let attempt = 1; attempt <= 30; attempt++) { // Postgres may still be starting
    if ((await start('migrate', 'db/migrate.js')) === 0) break;
    if (attempt === 30) { console.error('Database never became ready'); process.exit(1); }
    await new Promise((r) => setTimeout(r, 1000));
  }
  for (const name of Object.keys(PORTS)) start(name, `services/${name}.js`).then(() => shutdown());
  await Promise.all(Object.values(PORTS).map(waitForPort));
  console.log(`\n  Contrail is ready → http://localhost:${PORTS.web}\n`);
})();
