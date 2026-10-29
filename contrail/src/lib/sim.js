'use strict';
// Helpers that make the fake world behave like a real one: skewed latencies,
// CPU-bound work, bounded resources and switchable faults.
const { meter } = require('./otel');

const TIME_SCALE = Number(process.env.TIME_SCALE || 1);

const sleep = (ms, signal) =>
  new Promise((resolve) => {
    if (signal?.aborted) return resolve('aborted');
    const timer = setTimeout(() => resolve('done'), ms * TIME_SCALE);
    signal?.addEventListener('abort', () => { clearTimeout(timer); resolve('aborted'); }, { once: true });
  });

const between = (low, high) => low + Math.random() * (high - low);
const chance = (probability) => Math.random() < probability;
const pick = (list) => list[Math.floor(Math.random() * list.length)];
const id = (prefix) => `${prefix}_${Math.random().toString(36).slice(2, 8)}`;

// Real latencies have a long tail: mostly near `typical`, occasionally several times slower.
function latency(typical, spread = 0.35, tailChance = 0.04, tailFactor = 4) {
  const base = typical * (1 + (Math.random() * 2 - 1) * spread);
  return chance(tailChance) ? base * tailFactor : base;
}

/** Deliberately blocks the event loop (stands in for regex, JSON, crypto or rules-engine CPU work). */
function burnCpu(ms) {
  const until = performance.now() + ms;
  let n = 0;
  while (performance.now() < until) n += Math.sqrt(n + 1);
  return n;
}

/**
 * Counting semaphore with FIFO waiters; models ovens, pots, cooks, connection pools.
 * `onChange` receives queue/in-use state so owners can publish gauges.
 */
class Semaphore {
  constructor(capacity) { this.capacity = capacity; this.inUse = 0; this.waiters = []; }
  get queued() { return this.waiters.length; }
  async acquire() {
    if (this.inUse < this.capacity) { this.inUse++; return; }
    await new Promise((resolve) => this.waiters.push(resolve));
  }
  release() {
    const next = this.waiters.shift();
    if (next) next(); // hand the slot straight to the next waiter
    else this.inUse--;
  }
}

// Fault injection: tweakable at runtime via POST /admin/faults so scenarios can create incidents.
function createFaults(defaults) {
  const current = { ...defaults };
  return {
    defaults,
    get: (key) => current[key],
    set: (values) => { for (const key of Object.keys(values)) if (key in defaults) current[key] = values[key]; },
    reset: () => Object.assign(current, defaults),
    snapshot: () => ({ ...current }),
  };
}

module.exports = { sleep, between, chance, pick, id, latency, burnCpu, Semaphore, createFaults, TIME_SCALE, meter };
