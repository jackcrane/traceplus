# TracePlus

A macOS SwiftUI shell for a fully local OpenTelemetry observability app.

## Run

Open `Package.swift` in Xcode and run the `TracePlus` scheme, double-click
`run-traceplus.command` in Finder, or use:

```sh
swift run
```

When run from the package, TracePlus explicitly activates itself so its window
is brought forward even though Swift Package Manager does not produce an `.app`
bundle.

TracePlus includes a local HTTP listener on `127.0.0.1:4318`. It accepts the
OTLP HTTP paths `/v1/traces`, `/v1/logs`, and `/v1/metrics`, responding with
`200 OK` and updating the overview counters. The persistence/query layer is
the next implementation step.

## Contrail (test app)

An interactive flight-planning web app (accounts, saved plans, live METAR/TAF briefings,
a Postgres cache) that exports OpenTelemetry traces, metrics and logs to TracePlus. It runs in
Docker: start and open it from the Telemetry Fountain window, or:

```sh
cd contrail
docker compose up --build    # http://localhost:4400
```

See [contrail/README.md](contrail/README.md) for the architecture and the signals it emits.

## Legacy native test emitter

Run `swift run TelemetryFountain` (or select its scheme in Xcode) to launch a
native macOS utility for individual trace, log, metric, or rotating-signal
testing. For realistic, correlated telemetry, use Contrail instead.
