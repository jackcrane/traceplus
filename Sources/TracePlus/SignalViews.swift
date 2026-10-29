import AppKit
import SwiftUI
import TelemetryKit
struct LogsView: View {
    @Environment(CollectorState.self) private var collector
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            List(collector.logs) { log in
                VStack(alignment: .leading, spacing: 5) { HStack { Text(log.severity).font(.caption.weight(.bold)).foregroundStyle(.orange); Text(log.message).font(.headline); Spacer() }; Text("\(log.service)  ·  \(log.time.formatted(date: .omitted, time: .standard))" + (log.traceID.map { "  ·  trace \($0.prefix(8))" } ?? "")).font(.caption).foregroundStyle(.secondary); if !log.attributes.isEmpty { Text(log.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2) } }.padding(.vertical, 4)
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
                HStack { VStack(alignment: .leading, spacing: 5) { Text(metric.name).font(.headline); Text("\(metric.service)  ·  \(metric.kind)  ·  \(metric.time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary); if !metric.attributes.isEmpty { Text(metric.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1) } }; Spacer(); Text("\(metric.value.formatted()) \(metric.unit)").monospacedDigit().font(.title3) }.padding(.vertical, 4)
            }.overlay { if collector.metrics.isEmpty { ContentUnavailableView("No metrics yet", systemImage: "chart.xyaxis.line", description: Text("Send a metric to the local receiver.")) } }
        }
    }
}
