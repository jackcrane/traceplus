'use strict';
// Preloaded with `node --require ./src/telemetry.js` so the SDK is running (and
// http/undici are patched) before any application module is loaded.
//
// Configuration follows the OpenTelemetry environment-variable spec wherever it
// can: OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES, OTEL_EXPORTER_OTLP_ENDPOINT,
// OTEL_METRIC_EXPORT_INTERVAL, OTEL_TRACES_SAMPLER, ... all work as documented.
const os = require('node:os');
const { randomUUID } = require('node:crypto');
const { diag, DiagConsoleLogger, DiagLogLevel } = require('@opentelemetry/api');
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { resourceFromAttributes } = require('@opentelemetry/resources');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-http');
const { OTLPLogExporter } = require('@opentelemetry/exporter-logs-otlp-http');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');
const { BatchSpanProcessor } = require('@opentelemetry/sdk-trace');
const { BatchLogRecordProcessor } = require('@opentelemetry/sdk-logs');
const { HttpInstrumentation } = require('@opentelemetry/instrumentation-http');
const { UndiciInstrumentation } = require('@opentelemetry/instrumentation-undici');
const { PgInstrumentation } = require('@opentelemetry/instrumentation-pg');
const { RuntimeNodeInstrumentation } = require('@opentelemetry/instrumentation-runtime-node');

// Use the stable HTTP and database semantic conventions.
process.env.OTEL_SEMCONV_STABILITY_OPT_IN ||= 'http,database';
process.env.OTEL_EXPORTER_OTLP_ENDPOINT ||= 'http://127.0.0.1:4318';
// Demo-friendly: the spec default of 60s makes metrics feel broken in a UI.
process.env.OTEL_METRIC_EXPORT_INTERVAL ||= '5000';
// Batch processors flush every second so a live viewer stays close to real time.
const flushMs = Number(process.env.OTEL_BSP_SCHEDULE_DELAY || 1000);

if (process.env.OTEL_DEBUG) diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.DEBUG);

const serviceName = process.env.OTEL_SERVICE_NAME || 'contrail-unknown';

const sdk = new NodeSDK({
  // Merged on top of the SDK's env/host/process detectors, so host.name,
  // process.pid, telemetry.sdk.* etc. are added automatically.
  resource: resourceFromAttributes({
    'service.name': serviceName,
    'service.namespace': 'contrail',
    'service.version': require('../package.json').version,
    'service.instance.id': randomUUID(),
    'deployment.environment.name': process.env.DEPLOYMENT_ENVIRONMENT || 'local',
    'host.name': os.hostname(),
  }),
  // Explicit JSON-over-HTTP exporters. Endpoint/headers/timeouts come from OTEL_EXPORTER_OTLP_*.
  spanProcessors: [new BatchSpanProcessor({ exporter: new OTLPTraceExporter(), scheduledDelayMillis: flushMs })],
  metricReaders: [new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter(),
    exportIntervalMillis: Number(process.env.OTEL_METRIC_EXPORT_INTERVAL),
  })],
  logRecordProcessors: [new BatchLogRecordProcessor({ exporter: new OTLPLogExporter(), scheduledDelayMillis: flushMs })],
  instrumentations: [
    new HttpInstrumentation({
      // Health checks and the admin plane are noise in a trace view.
      ignoreIncomingRequestHook: (req) => req.url === '/healthz' || req.url.startsWith('/admin'),
    }),
    new UndiciInstrumentation({ ignoreRequestHook: (req) => req.path.startsWith('/admin') }), // global fetch()
    new PgInstrumentation(), // spans + connection-pool metrics for every query
    new RuntimeNodeInstrumentation(), // event-loop delay/utilisation, GC, ...
  ],
});

sdk.start();

// Flush everything on exit so the last seconds of a run are not lost.
let closing = false;
async function shutdown(signal) {
  if (closing) return;
  closing = true;
  try { await sdk.shutdown(); } catch (error) { console.error('otel shutdown failed', error); }
  if (signal) process.exit(0);
}
process.once('SIGTERM', () => shutdown('SIGTERM'));
process.once('SIGINT', () => shutdown('SIGINT'));
process.once('beforeExit', () => shutdown());
