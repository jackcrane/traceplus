'use strict';
// Postgres-backed read-through cache shared by the weather service.
// Entries are JSONB with an expiry. Expired rows are kept (not deleted) so a
// failing upstream can still be answered with stale data.
const { query } = require('./pg');
const { withSpan, meter } = require('./otel');

const requests = meter.createCounter('contrail.cache.requests', { description: 'Cache lookups by result (hit, stale, miss).', unit: '{lookup}' });
const cleared = meter.createCounter('contrail.cache.entries_cleared', { description: 'Cache entries removed by an explicit clear.', unit: '{entry}' });

/** @returns Map<key, {payload, fresh, fetchedAt}> for keys present in the cache (fresh or stale). */
async function getMany(kind, keys) {
  return withSpan('cache.get_many', { attributes: { 'cache.kind': kind, 'cache.keys_requested': keys.length } }, async (span) => {
    const found = new Map();
    if (keys.length) {
      const { rows } = await query(
        `UPDATE cache_entries SET hits = hits + 1 WHERE kind = $1 AND key = ANY($2::text[])
         RETURNING key, payload, fetched_at, expires_at > now() AS fresh`, [kind, keys]);
      for (const row of rows) found.set(row.key, { payload: row.payload, fresh: row.fresh, fetchedAt: row.fetched_at });
    }
    let hit = 0, stale = 0;
    for (const key of keys) {
      const entry = found.get(key);
      const result = !entry ? 'miss' : entry.fresh ? 'hit' : 'stale';
      if (result === 'hit') hit++; else if (result === 'stale') stale++;
      requests.add(1, { 'cache.kind': kind, 'cache.result': result });
    }
    span.setAttributes({ 'cache.hits': hit, 'cache.stale': stale, 'cache.misses': keys.length - hit - stale });
    return found;
  });
}

async function putMany(kind, entries, ttlSeconds) {
  if (!entries.length) return;
  await withSpan('cache.put_many', { attributes: { 'cache.kind': kind, 'cache.entries': entries.length, 'cache.ttl_seconds': ttlSeconds } }, () =>
    query(
      `INSERT INTO cache_entries (key, kind, payload, fetched_at, expires_at)
       SELECT k, $1, p::jsonb, now(), now() + make_interval(secs => $4) FROM unnest($2::text[], $3::text[]) AS t(k, p)
       ON CONFLICT (key) DO UPDATE SET payload = EXCLUDED.payload, fetched_at = now(), expires_at = EXCLUDED.expires_at`,
      [kind, entries.map((e) => e.key), entries.map((e) => JSON.stringify(e.payload)), ttlSeconds]));
}

async function stats() {
  const { rows } = await query(
    `SELECT kind, count(*)::int AS entries, count(*) FILTER (WHERE expires_at > now())::int AS fresh,
            coalesce(sum(hits), 0)::int AS hits, min(fetched_at) AS oldest, max(fetched_at) AS newest
     FROM cache_entries GROUP BY kind ORDER BY kind`);
  return rows;
}

async function clear(kind) {
  return withSpan('cache.clear', { attributes: { 'cache.kind': kind ?? 'all' } }, async (span) => {
    const result = kind ? await query('DELETE FROM cache_entries WHERE kind = $1', [kind]) : await query('DELETE FROM cache_entries');
    cleared.add(result.rowCount);
    span.setAttribute('cache.entries_removed', result.rowCount);
    return result.rowCount;
  });
}

module.exports = { getMany, putMany, stats, clear };
