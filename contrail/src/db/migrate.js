'use strict';
// Creates the database if needed and applies the schema.
// Idempotent: safe to run on every start.
const { Client } = require('pg');
const { withSpan, log } = require('../lib/otel');
const { pool, connectionString } = require('../lib/pg');

const SCHEMA = `
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL UNIQUE,
  display_name text NOT NULL,
  password_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS sessions (
  token_hash text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  user_agent text
);
CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions (expires_at);
CREATE TABLE IF NOT EXISTS login_attempts (
  id bigserial PRIMARY KEY,
  email text NOT NULL,
  succeeded boolean NOT NULL,
  at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS login_attempts_email_at ON login_attempts (email, at DESC);
-- Airport reference data is pulled from the aviationweather.gov airport API on first use and cached here.
CREATE TABLE IF NOT EXISTS airports (
  icao text PRIMARY KEY, iata text, faa_id text, name text NOT NULL, city text, state text, country text,
  lat double precision NOT NULL, lon double precision NOT NULL, elev_ft int, magdec text, has_tower boolean NOT NULL DEFAULT false,
  longest_rwy_ft int NOT NULL DEFAULT 0, rwy_heading int, runways jsonb NOT NULL DEFAULT '[]', freqs text,
  fetched_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS airports_iata ON airports (iata);
CREATE TABLE IF NOT EXISTS cache_entries (
  key text PRIMARY KEY, kind text NOT NULL, payload jsonb NOT NULL,
  fetched_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL, hits int NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS cache_entries_kind ON cache_entries (kind);
CREATE TABLE IF NOT EXISTS plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name text NOT NULL, origin text NOT NULL, destination text NOT NULL, aircraft text NOT NULL,
  request jsonb NOT NULL, result jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS plans_user ON plans (user_id, created_at DESC);
CREATE TABLE IF NOT EXISTS plan_runs (
  id bigserial PRIMARY KEY, user_id uuid, origin text, destination text, aircraft text,
  verdict text, risk_score int, duration_ms int, created_at timestamptz NOT NULL DEFAULT now()
);
`;

async function ensureDatabase() {
  const url = new URL(connectionString);
  const name = url.pathname.slice(1);
  url.pathname = '/postgres';
  const client = new Client({ connectionString: url.toString() });
  await client.connect();
  try {
    const { rowCount } = await client.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
    if (!rowCount) { await client.query(`CREATE DATABASE "${name.replace(/"/g, '')}"`); log.info('Created database', { 'db.namespace': name }); }
  } finally { await client.end(); }
}

async function main() {
  await withSpan('db.migrate', async (span) => {
    await withSpan('db.ensure_database', ensureDatabase);
    await withSpan('db.apply_schema', () => pool.query(SCHEMA));
    log.info('Database ready');
  });
}

main().then(() => pool.end(), (error) => { log.error('Migration failed', { 'exception.message': error.message }); console.error(error); process.exit(1); });
