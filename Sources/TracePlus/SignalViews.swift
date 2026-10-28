import AppKit
import SwiftUI
import TelemetryKit
struct LogsView: View {
    @Environment(CollectorState.self) private var collector
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            List(collector.logs) { log in
                VStack(alignment: .leading, spacing: 5) { HStack { Text(log.severity).font(.caption.weight(.bold)).foregroundStyle(.orange); Text(log.message).font(.headline); Spacer() }; Text("\(log.service)  ·  \(log.time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 4)
            }.overlay { if collector.logs.isEmpty { ContentUnavailableView("No logs yet", systemImage: "text.alignleft", description: Text("Send a log to the local receiver.")) } }
        }
    }
}

struct MetricsView: View {
    @Environment(CollectorState.self) private var collector
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            List(collector.metrics) { metric in
                HStack { VStack(alignment: .leading, spacing: 5) { Text(metric.name).font(.headline); Text("\(metric.service)  ·  \(metric.time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(metric.value.formatted()) \(metric.unit)").monospacedDigit().font(.title3) }.padding(.vertical, 4)
            }.overlay { if collector.metrics.isEmpty { ContentUnavailableView("No metrics yet", systemImage: "chart.xyaxis.line", description: Text("Send a metric to the local receiver.")) } }
        }
    }
}
