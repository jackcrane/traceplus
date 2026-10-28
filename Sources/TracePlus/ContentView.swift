import AppKit
import SwiftUI
import TelemetryKit

struct ContentView: View {
    @Environment(CollectorState.self) private var collector
    @Environment(TelemetryEmitter.self) private var emitter
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Destination? = .overview
    @State private var commandPressed = false
    @State private var modifierMonitor: Any?

    enum Destination: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case traces = "Traces"
        case logs = "Logs"
        case metrics = "Metrics"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: "rectangle.3.group"
            case .traces: "point.3.connected.trianglepath.dotted"
            case .logs: "text.alignleft"
            case .metrics: "chart.xyaxis.line"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $selection) { destination in
                Label(destination.rawValue, systemImage: destination.icon)
                    .tag(destination)
            }
            .navigationTitle("TracePlus")
            .listStyle(.sidebar)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView()
            case .traces: TracesView()
            case .logs: LogsView()
            case .metrics: MetricsView()
            }
        }
        .toolbar {
            if selection == .overview {
                ToolbarItem(placement: .primaryAction) {
                    Button(collector.status == .running ? "Stop receiver" : "Start receiver") {
                        collector.status == .running ? collector.stop() : collector.start()
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(commandPressed ? "Open Telemetry Fountain" : "Run realistic workload", systemImage: commandPressed ? "drop.fill" : "bolt.fill") {
                        if NSEvent.modifierFlags.contains(.command) {
                            openWindow(id: "emitter")
                        } else if !emitter.isSending {
                            emitter.sendRealisticWorkload()
                        }
                    }
                    .help(commandPressed ? "Open Telemetry Fountain" : "Send a 2,500-span realistic workload. Hold Command to open Telemetry Fountain.")
                }
            }
        }
        .onAppear {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                commandPressed = event.modifierFlags.contains(.command)
                return event
            }
        }
        .onDisappear {
            if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
            modifierMonitor = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OverviewView: View {
    @Environment(CollectorState.self) private var collector

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Local observability")
                            .font(.largeTitle.weight(.bold))
                        Text("Receive and explore OpenTelemetry signals without sending them anywhere else.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(status: collector.status)
                }

                HStack(spacing: 14) {
                    SignalCard(title: "Traces", value: collector.traceCount, icon: "point.3.connected.trianglepath.dotted", tint: .indigo)
                    SignalCard(title: "Spans", value: collector.spanCount, icon: "circle.dotted", tint: .teal)
                    SignalCard(title: "Logs", value: collector.logCount, icon: "text.alignleft", tint: .orange)
                }

                ReceiverCard()
            }
            .padding(32)
        }
        .navigationTitle("Overview")
    }
}

private struct ReceiverCard: View {
    @Environment(CollectorState.self) private var collector
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("OTLP receiver", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Text("OTLP/HTTP JSON :\(collector.httpPort)")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text("Start the receiver, then point any OpenTelemetry SDK at this Mac.")
                .foregroundStyle(.secondary)
            if let error = collector.receiverError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            Text(collector.environment)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                if collector.status != .running {
                    Button("Start local receiver") { collector.start() }
                        .buttonStyle(.borderedProminent)
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
        .padding(22)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
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

private struct TracesView: View {
    private struct TraceSummary: Identifiable {
        let id: String; let operation: String; let service: String; let start: Date; let duration: Double; let spanCount: Int; let hasError: Bool
    }
    @Environment(CollectorState.self) private var collector
    @State private var selection: String?
    @State private var selectedSpanID: CollectorState.TraceItem.ID?
    @State private var sortOrder: [KeyPathComparator<TraceSummary>] = [KeyPathComparator(\.start, order: .reverse)]

    private var summaries: [TraceSummary] {
        Dictionary(grouping: collector.traces, by: \.traceID).map { id, spans in
            let ordered = spans.sorted { $0.time < $1.time }
            let start = ordered.first?.time ?? .now
            let end = ordered.map { $0.time.addingTimeInterval($0.durationMilliseconds / 1_000) }.max() ?? start
            let root = ordered.first { $0.parentSpanID == nil } ?? ordered.first!
            return TraceSummary(id: id, operation: root.name, service: root.service, start: start, duration: end.timeIntervalSince(start) * 1_000, spanCount: spans.count, hasError: spans.contains { $0.statusCode == 2 })
        }.sorted(using: sortOrder)
    }
    private var selectedTrace: [CollectorState.TraceItem] {
        guard let selection else { return [] }
        return collector.traces.filter { $0.traceID == selection }.sorted { $0.time < $1.time }
    }
    private var selectedSpan: CollectorState.TraceItem? {
        selectedTrace.first { $0.id == selectedSpanID }
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if selectedSpan != nil {
                    NativeSplitView(isVertical: true, trailingFraction: 0.25) {
                        traceContent(height: proxy.size.height)
                            .frame(minWidth: 0, minHeight: 0)
                    } trailing: {
                        SpanInspector(span: selectedSpan, traceStart: selectedTrace.first?.time)
                            .frame(minWidth: 0, idealWidth: 300, minHeight: 0)
                            .background(PaneSizeObserver { size in
                                if size.width < 30 { selectedSpanID = nil }
                            })
                    }
                } else {
                    traceContent(height: proxy.size.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .onChange(of: selection) { oldValue, newValue in
            selectedSpanID = nil
        }
        .navigationTitle("Traces")
    }

    @ViewBuilder
    private func traceContent(height: CGFloat) -> some View {
        if selection != nil {
            NativeSplitView(isVertical: false, trailingFraction: 0.7) {
                traceTable
                    .frame(minWidth: 0, minHeight: 0)
            } trailing: {
                TraceWaterfall(spans: selectedTrace, selectedSpanID: $selectedSpanID)
                    .frame(minWidth: 0, minHeight: 0)
                    .background(PaneSizeObserver { size in
                        if size.height < 30 {
                            selection = nil
                            selectedSpanID = nil
                        }
                    })
            }
        } else {
            traceTable
        }
    }

    private var traceTable: some View {
        Table(summaries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Operation", value: \.operation) { Text($0.operation).lineLimit(1) }.width(min: 180, ideal: 280)
            TableColumn("Service", value: \.service) { Text($0.service).foregroundStyle(.secondary) }.width(min: 120, ideal: 160)
            TableColumn("Duration", value: \.duration) { Text(String(format: "%.2f ms", $0.duration)).monospacedDigit() }.width(110)
            TableColumn("Spans") { Text("\($0.spanCount)").monospacedDigit() }.width(60)
            TableColumn("Status") { item in Text(item.hasError ? "Error" : "OK").foregroundStyle(item.hasError ? .red : .green) }.width(70)
            TableColumn("Trace ID") { Text($0.id.prefix(12)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }.width(110)
            TableColumn("Time", value: \.start) { Text($0.start.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary) }.width(110)
        }
        .overlay { if collector.traces.isEmpty { ContentUnavailableView("No traces yet", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Send a trace to the local receiver.")) } }
    }
}

private struct PaneSizeObserver: View {
    let onChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size) }
                .onChange(of: proxy.size) { _, size in onChange(size) }
        }
    }
}

/// A native AppKit split view whose initial divider is positioned during its
/// first layout pass, before the view can be drawn. Subsequent resizing stays
/// entirely under the system split view's control.
private struct NativeSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    let isVertical: Bool
    let trailingFraction: CGFloat
    let leading: Leading
    let trailing: Trailing

    init(isVertical: Bool, trailingFraction: CGFloat, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.isVertical = isVertical
        self.trailingFraction = trailingFraction
        self.leading = leading()
        self.trailing = trailing()
    }

    func makeNSView(context: Context) -> NativeSplitContainer<Leading, Trailing> {
        NativeSplitContainer(isVertical: isVertical, trailingFraction: trailingFraction, leading: leading, trailing: trailing)
    }

    func updateNSView(_ view: NativeSplitContainer<Leading, Trailing>, context: Context) {
        view.leadingHost.rootView = leading
        view.trailingHost.rootView = trailing
    }
}

private final class NativeSplitContainer<Leading: View, Trailing: View>: NSView {
    let splitView: NSSplitView
    let leadingHost: NSHostingView<Leading>
    let trailingHost: NSHostingView<Trailing>
    private let trailingFraction: CGFloat
    private var positioned = false

    init(isVertical: Bool, trailingFraction: CGFloat, leading: Leading, trailing: Trailing) {
        self.trailingFraction = trailingFraction
        splitView = NSSplitView()
        splitView.isVertical = isVertical
        splitView.dividerStyle = .thin
        leadingHost = NSHostingView(rootView: leading)
        trailingHost = NSHostingView(rootView: trailing)
        super.init(frame: .zero)
        addSubview(splitView)
        splitView.addSubview(leadingHost)
        splitView.addSubview(trailingHost)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        splitView.frame = bounds
        guard !positioned else { return }
        let dimension = splitView.isVertical ? bounds.width : bounds.height
        guard dimension > 0 else { return }
        splitView.setPosition(dimension * (1 - trailingFraction), ofDividerAt: 0)
        positioned = true
    }
}

private struct TraceWaterfall: View {
    let spans: [CollectorState.TraceItem]
    @Binding var selectedSpanID: CollectorState.TraceItem.ID?
    @State private var hoveredSpanID: CollectorState.TraceItem.ID?
    @State private var timelineHoverLocation: CGPoint?
    private var start: Date { spans.map(\.time).min() ?? .now }
    private var end: Date { spans.map { $0.time.addingTimeInterval($0.durationMilliseconds / 1_000) }.max() ?? start.addingTimeInterval(0.001) }
    /// Reserve only the room needed by the widest span name. This keeps the
    /// waterfall as wide as possible while preventing an unusually long
    /// operation name from consuming the entire panel.
    private var labelWidth: CGFloat {
        let nameFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let headerWidth = ("SPAN" as NSString).size(withAttributes: [.font: nameFont]).width

        let widestLabel = spans.map { span in
            (span.name as NSString).size(withAttributes: [.font: nameFont]).width
        }.max() ?? 0

        return min(250, max(headerWidth, widestLabel))
    }

    var body: some View {
        Group {
            if spans.isEmpty {
                ContentUnavailableView("Select a trace", systemImage: "chart.bar.xaxis", description: Text("Choose a trace to inspect its span waterfall."))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    GeometryReader { viewport in
                        let duration = max(end.timeIntervalSince(start), 0.001)
                        let timelineWidth = max(300, viewport.size.width - labelWidth - 8)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Text("SPAN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .trailing)
                                TraceRuler(width: timelineWidth, durationMilliseconds: duration * 1_000)
                            }
                            .frame(height: 18)
                            .frame(width: viewport.size.width, alignment: .leading)
                            ScrollView(.vertical) {
                                VStack(spacing: 0) {
                                ForEach(spans) { span in
                                    HStack(spacing: 8) {
                                        Text(span.name)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(width: labelWidth, alignment: .trailing)
                                        ZStack(alignment: .leading) {
                                            TimelineGrid(width: timelineWidth)
                                            let elapsedMilliseconds: Double = span.time.timeIntervalSince(start) * 1_000
                                            let offset: CGFloat = max(0, timelineWidth * elapsedMilliseconds / (duration * 1_000))
                                            let width: CGFloat = max(3, timelineWidth * (span.durationMilliseconds / 1_000) / duration)
                                            WaterfallBar(span: span, width: width, offsetMilliseconds: elapsedMilliseconds, isSelected: selectedSpanID == span.id, select: { selectedSpanID = span.id })
                                                .offset(x: offset)
                                        }.frame(height: 18)
                                    }
                                    .frame(height: 22)
                                    .frame(width: viewport.size.width, alignment: .leading)
                                    .background(hoveredSpanID == span.id ? Color.gray.opacity(0.16) : .clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedSpanID = span.id }
                                    .onHover { isHovering in
                                        hoveredSpanID = isHovering ? span.id : nil
                                    }
                                }
                                }
                                .frame(minHeight: CGFloat(spans.count * 22))
                                .frame(width: viewport.size.width)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if let location = timelineHoverLocation, location.x >= labelWidth + 8, location.x <= labelWidth + 8 + timelineWidth {
                                let elapsedX = min(max(0, location.x - labelWidth - 8), timelineWidth)
                                ZStack(alignment: .topLeading) {
                                    Rectangle().fill(Color.gray.opacity(0.65)).frame(width: 1, height: viewport.size.height - 18).offset(x: location.x, y: 18)
                                    Text(String(format: "+%.2f ms", elapsedX / timelineWidth * duration * 1_000))
                                        .font(.system(size: 10, design: .monospaced)).padding(.horizontal, 5).padding(.vertical, 3)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                        .offset(x: location.x, y: 4)
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                timelineHoverLocation = (location.x >= labelWidth + 8 && location.x <= labelWidth + 8 + timelineWidth) ? location : nil
                            case .ended: timelineHoverLocation = nil
                            }
                        }
                    }
                }
            }
        }
    }

}

private struct WaterfallBar: View {
    let span: CollectorState.TraceItem
    let width: CGFloat
    let offsetMilliseconds: Double
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: select) {
            RoundedRectangle(cornerRadius: 3)
                .fill(span.statusCode == 2 ? Color.red : Color.accentColor)
                .frame(width: width, height: hovering || isSelected ? 18 : 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(isSelected ? Color.primary : Color.clear, lineWidth: 1))
                .shadow(color: hovering ? .accentColor.opacity(0.45) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(span.name)\nStarts +\(String(format: "%.2f", offsetMilliseconds)) ms\nDuration \(String(format: "%.2f", span.durationMilliseconds)) ms\nService: \(span.service)\nClick for full details")
    }
}

private struct TimelineGrid: View {
    let width: CGFloat
    var body: some View {
        HStack(spacing: 0) { ForEach(0..<5, id: \.self) { index in Rectangle().fill(.quaternary).frame(width: index == 0 ? 1 : 0.5); if index < 4 { Spacer(minLength: 0) } } }
            .frame(width: width, height: 18)
    }
}

private struct TraceRuler: View {
    let width: CGFloat
    let durationMilliseconds: Double
    var body: some View {
        HStack { ForEach(0...4, id: \.self) { tick in Text(String(format: "%.1f ms", durationMilliseconds * Double(tick) / 4)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary); if tick < 4 { Spacer(minLength: 0) } } }
            .frame(width: width, alignment: .leading)
    }
}

private struct SpanInspector: View {
    let span: CollectorState.TraceItem?
    let traceStart: Date?

    var body: some View {
        Group {
            if let span, let traceStart {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(span.name)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        HStack {
                            Text(span.service).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Label(span.statusCode == 2 ? "Error" : "OK", systemImage: span.statusCode == 2 ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(span.statusCode == 2 ? .red : .green)
                        }
                        Divider()

                        inspectorSection("Timing") {
                            detailRow("Start", "+\(String(format: "%.2f", span.time.timeIntervalSince(traceStart) * 1_000)) ms")
                            detailRow("Duration", String(format: "%.2f ms", span.durationMilliseconds))
                            detailRow("Timestamp", span.time.formatted(date: .abbreviated, time: .standard))
                        }
                        Divider()

                        inspectorSection("Identifiers") {
                            identifierRow("Span ID", span.spanID)
                            identifierRow("Trace ID", span.traceID)
                        }

                        if !span.attributes.isEmpty {
                            Divider()
                            inspectorSection("Attributes (\(span.attributes.count))") {
                                ForEach(span.attributes.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(key).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        Text(value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if key != span.attributes.keys.sorted().last { Divider() }
                                }
                            }
                        }

                        if !span.events.isEmpty {
                            Divider()
                            inspectorSection("Events (\(span.events.count))") {
                                ForEach(span.events, id: \.self) { event in
                                    Label(event, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .padding(18)
                }
            } else {
                EmptyView()
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func identifierRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
        }
    }
}

private struct LogsView: View {
    @Environment(CollectorState.self) private var collector
    var body: some View {
        List(collector.logs) { log in
            VStack(alignment: .leading, spacing: 5) { HStack { Text(log.severity).font(.caption.weight(.bold)).foregroundStyle(.orange); Text(log.message).font(.headline); Spacer() }; Text("\(log.service)  ·  \(log.time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 4)
        }.overlay { if collector.logs.isEmpty { ContentUnavailableView("No logs yet", systemImage: "text.alignleft", description: Text("Send a log to the local receiver.")) } }.navigationTitle("Logs")
    }
}

private struct MetricsView: View {
    @Environment(CollectorState.self) private var collector
    var body: some View {
        List(collector.metrics) { metric in
            HStack { VStack(alignment: .leading, spacing: 5) { Text(metric.name).font(.headline); Text("\(metric.service)  ·  \(metric.time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(metric.value.formatted()) \(metric.unit)").monospacedDigit().font(.title3) }.padding(.vertical, 4)
        }.overlay { if collector.metrics.isEmpty { ContentUnavailableView("No metrics yet", systemImage: "chart.xyaxis.line", description: Text("Send a metric to the local receiver.")) } }.navigationTitle("Metrics")
    }
}
