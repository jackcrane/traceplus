'use strict';
// One pool per service process. Queries are traced by the pg instrumentation,
// which also reports connection-pool metrics (db.client.connection.*).
const { Pool } = require('pg');
const { log } = require('./otel');

const connectionString = process.env.DATABASE_URL || 'postgres://localhost/contrail';
const pool = new Pool({ connectionString, max: Number(process.env.PG_POOL_MAX || 10), application_name: process.env.OTEL_SERVICE_NAME });
pool.on('error', (error) => log.error('Idle Postgres client error', { 'exception.message': error.message }));

const query = (text, params) => pool.query(text, params);

/** Run `fn(client)` in a transaction; rolls back on error. */
async function transaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

module.exports = { pool, query, transaction, connectionString };
