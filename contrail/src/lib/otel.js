'use strict';
// Thin helpers over the OpenTelemetry API. Nothing here configures the SDK
// (that is src/telemetry.js); services only depend on the vendor-neutral API.
const { trace, metrics, logs, context, SpanStatusCode, SeverityNumber } = require('@opentelemetry/api');

const SCOPE = 'contrail';
const tracer = trace.getTracer(SCOPE);
const meter = metrics.getMeter(SCOPE);
const logger = logs.getLogger(SCOPE);

/**
 * Run `fn(span)` inside a new active span. The span is ended exactly once, and a
 * thrown error is recorded as an exception event + ERROR status before being
 * re-thrown. Errors flagged `expected` (business outcomes such as a declined
 * card) are annotated but not marked as span failures.
 */
function withSpan(name, options, fn) {
  if (typeof options === 'function') [fn, options] = [options, {}];
  return tracer.startActiveSpan(name, options, async (span) => {
    try {
      return await fn(span);
    } catch (error) {
      markError(span, error);
      throw error;
    } finally {
      span.end();
    }
  });
}

/** Synchronous twin of withSpan for pure CPU work: returns the value directly. */
function spanSync(name, options, fn) {
  if (typeof options === 'function') [fn, options] = [options, {}];
  return tracer.startActiveSpan(name, options, (span) => {
    try {
      return fn(span);
    } catch (error) {
      markError(span, error);
      throw error;
    } finally {
      span.end();
    }
  });
}

function markError(span, error) {
  span.setAttribute('error.type', error.code || error.name || 'Error');
  if (error.expected) {
    span.addEvent('business.rejection', { 'rejection.reason': error.code, 'rejection.message': error.message });
    return;
  }
  span.recordException(error);
  span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
}

const SEVERITY = {
  DEBUG: SeverityNumber.DEBUG,
  INFO: SeverityNumber.INFO,
  WARN: SeverityNumber.WARN,
  ERROR: SeverityNumber.ERROR,
};

// Structured logging: a short constant message + queryable attributes. Records
// emitted while a span is active automatically carry its trace_id and span_id.
function emit(severityText, body, attributes = {}) {
  logger.emit({
    severityNumber: SEVERITY[severityText],
    severityText,
    body,
    attributes,
    context: context.active(),
  });
  if (process.env.LOG_STDOUT !== '0') {
    const extra = Object.entries(attributes).map(([k, v]) => `${k}=${v}`).join(' ');
    console.log(`${severityText.padEnd(5)} ${body}${extra ? '  ' + extra : ''}`);
  }
}

const log = {
  debug: (body, attributes) => emit('DEBUG', body, attributes),
  info: (body, attributes) => emit('INFO', body, attributes),
  warn: (body, attributes) => emit('WARN', body, attributes),
  error: (body, attributes) => emit('ERROR', body, attributes),
};

// Latency buckets in seconds, tuned for request-ish work (5ms .. 30s).
const LATENCY_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30];

function durationHistogram(name, description, boundaries = LATENCY_BUCKETS) {
  return meter.createHistogram(name, { description, unit: 's', advice: { explicitBucketBoundaries: boundaries } });
}

module.exports = { trace, context, tracer, meter, log, withSpan, spanSync, durationHistogram, SpanStatusCode, LATENCY_BUCKETS };
