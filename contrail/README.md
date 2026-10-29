# Contrail

An interactive flight-planning web app that exists to give TracePlus (or any OTLP backend)
telemetry that looks like a real system. Sign up, type an origin and destination, and get a
briefing: route, winds, fuel, weight and balance, METAR and TAF for the departure,
destination, alternates and airports along the way, and a go / no-go call.

```sh
docker compose up --build        # then open http://localhost:4400
```

Or start and open it from the Telemetry Fountain window (Start, then Open App).
Everything runs in containers (the app and Postgres) with no volumes; `docker compose down` wipes it.

Telemetry goes to `OTEL_EXPORTER_OTLP_ENDPOINT`, by default `http://host.docker.internal:4318`
(TracePlus on your Mac), as OTLP/HTTP JSON. Run TracePlus first.

## Data sources

Everything comes from a live API; nothing is seeded or simulated, and there are no fallbacks. If a
provider fails (after one retry) the request fails with an error.

| Data | Source |
| --- | --- |
| Airports (any airport, runways, tower, position) | aviationweather.gov `airport` API, looked up on first use and cached in Postgres |
| Nearby / along-route airports | aviationweather.gov METAR bounding-box API (stations that report weather) |
| METAR, TAF | aviationweather.gov |
| Winds aloft | aviationweather.gov `windtemp` (FD winds table), interpolated between stations and altitudes |
| Terrain | Open-Meteo elevation API |

There are no NOTAMs: the only real source (the FAA NOTAM API) needs a key.
Demonstration only. Not for navigation.

## Services

| Service | Port | Role |
| --- | --- | --- |
| `contrail-web` | 4400 | UI + public API. Auth (scrypt, sessions in Postgres), saved plans, cache admin, test lab |
| `contrail-planner` | 4404 | Orchestrates a briefing; route, terrain, performance, fuel, W&B, risk |
| `contrail-airports` | 4401 | Airport lookup (API + Postgres cache), nearby and along-route discovery |
| `contrail-weather` | 4402 | METAR/TAF/winds with a Postgres read-through cache |
| `contrail-migrate` | – | Schema on start (its own trace) |

W3C trace context flows across real HTTP calls, so one click is one trace over four services, Postgres and three external APIs.

## What to look for in a trace

- **Parallel fan-out**: the planner runs corridor ‖ winds ‖ alternates, then METARs ‖ TAFs; terrain elevation is fetched in the same stage.
- **Sequential pipeline**: resolve → route → terrain → gather → performance → W&B → rank → risk → briefing.
- **CPU-bound work**: password hashing (`auth.hash_password`), wind-table parsing and interpolation, corridor geometry.
- **Cache behaviour**: `cache.get_many` attributes (`cache.hits`, `cache.misses`, `cache.stale`); a cold plan takes seconds, a warm one tens of milliseconds. The **Clear cache** button is `DELETE /api/cache`.
- **Failure**: upstream calls retry once with backoff, then the whole request errors (no fallback). Break the weather provider in the **Test lab** panel and replan to see the error trace. "No report" and "unknown airport" answers are negatively cached.
- **Auth**: rate-limited logins, constant-time failure path, throttled session touch, `enduser.id` on spans.
- **Background jobs**: `auth.sweep_sessions` and `weather.refresh_cycle` are their own root traces.
- **Business errors vs failures**: bad password, unknown airport... annotate spans but are not ERROR; upstream outages are.

The response header `x-trace-id` (also shown at the bottom of each briefing) finds the trace.

## Telemetry reference

Resource: `service.name`, `service.namespace=contrail`, `service.version`, `service.instance.id`, `deployment.environment.name`, plus SDK-detected host/process attributes.
Traces: HTTP (stable semconv) and Postgres (database semconv + pool metrics) auto-instrumentation, plus the business spans above.
Logs: structured, correlated by `trace_id`/`span_id`.

| Metric | Type |
| --- | --- |
| `contrail.plans.generated` (`app.risk.verdict`, `app.aircraft`) | counter |
| `contrail.plan.duration`, `.distance`, `.airports_briefed`, `.risk_score` | histogram |
| `contrail.cache.requests` (`cache.kind`, `cache.result`), `contrail.cache.entries_cleared` | counter |
| `contrail.upstream.requests`, `contrail.upstream.duration` | counter / histogram |
| `contrail.weather.reports` (flight category), `contrail.airports.lookups` (`source`: database / api) | counter |
| `contrail.auth.attempts`, `contrail.sessions.active`, `contrail.users` | counter / gauges |
| `db.client.operation.duration`, `db.client.connection.*`, `http.server/client.request.duration`, `nodejs.eventloop.*`, `v8js.*` | standard |

## Layout

```
src/telemetry.js   SDK bootstrap (preloaded): resource, exporters, instrumentations
src/lib/           otel helpers, http router, pg pool, cache, geo maths, aircraft data
src/db/            schema and migration
src/services/      web, planner, airports, weather
src/main.js        process supervisor (container entrypoint)
public/            the single-page UI
```
