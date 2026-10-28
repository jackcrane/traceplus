import AppKit
import SwiftUI

struct OverviewView: View {
    @Environment(CollectorState.self) private var collector

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                OverviewHero(status: collector.status)
                SignalSummaryRow(
                    traceCount: collector.traceCount,
                    spanCount: collector.spanCount,
                    logCount: collector.logCount
                )
                ReceiverCard()
            }
            .padding(32)
        }
    }
}

private struct OverviewHero: View {
    let status: CollectorState.Status

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Local observability")
                    .font(.largeTitle.weight(.bold))
                Text("Receive and explore OpenTelemetry signals without sending them anywhere else.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: status)
        }
    }
}

private struct SignalSummaryRow: View {
    let traceCount: Int
    let spanCount: Int
    let logCount: Int

    var body: some View {
        HStack(spacing: 14) {
            SignalCard(title: "Traces", value: traceCount, icon: "point.3.connected.trianglepath.dotted", tint: .indigo)
            SignalCard(title: "Spans", value: spanCount, icon: "circle.dotted", tint: .teal)
            SignalCard(title: "Logs", value: logCount, icon: "text.alignleft", tint: .orange)
        }
    }
}

private struct ReceiverCard: View {
    @Environment(CollectorState.self) private var collector
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("OTLP receiver", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                Spacer()
                Text("OTLP/HTTP JSON :\(collector.httpPort)").font(.subheadline.monospaced()).foregroundStyle(.secondary)
            }
            Text("Start the receiver, then point any OpenTelemetry SDK at this Mac.").foregroundStyle(.secondary)
            if let error = collector.receiverError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.red)
            }
            Text(collector.environment)
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                if collector.status != .running {
                    Button("Start local receiver") { collector.start() }.buttonStyle(.borderedProminent)
                }
                Button(copied ? "Copied" : "Copy environment") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(collector.environment, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(22).background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }
}

private struct SignalCard: View {
    let title: String
    let value: Int
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: icon).foregroundStyle(tint).font(.title2)
            Text("\(value)").font(.system(size: 34, weight: .bold, design: .rounded))
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct StatusBadge: View {
    let status: CollectorState.Status

    var body: some View {
        Label(status.rawValue, systemImage: status == .running ? "checkmark.circle.fill" : "circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(status == .running ? .green : .secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.quaternary, in: Capsule())
    }
}
