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

## Test emitter

Run `swift run TelemetryFountain` (or select its scheme in Xcode) to launch a
native macOS test application. It posts valid OTLP/HTTP JSON requests to the
configured endpoint, defaulting to `http://127.0.0.1:4318`, and can emit a
trace, log, metric, or a rotating stream every two seconds.
