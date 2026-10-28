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
    @State private var hoveredSpanID: CollectorState.TraceItem.ID?
    @State private var parentLinkTargetSpanID: CollectorState.TraceItem.ID?
    @State private var inspectorIsOpening = false
    @State private var waterfallIsOpening = false
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
                if selection != nil {
                    HSplitView {
                        traceContent(height: proxy.size.height)
                            .frame(minWidth: 0, minHeight: 0)
                        Group {
                            if let selectedSpan {
                                SpanInspector(
                                    span: selectedSpan,
                                    traceStart: selectedTrace.first?.time,
                                    parentSpan: selectedTrace.first { $0.spanID == selectedSpan.parentSpanID },
                                    selectParent: { parent in selectedSpanID = parent.id },
                                    setHoveredSpan: { hoveredSpanID = $0 },
                                    setParentLinkTarget: { parentLinkTargetSpanID = $0 }
                                )
                            } else {
                                Color.clear.frame(width: 0)
                            }
                        }
                            .frame(minWidth: 0, idealWidth: selectedSpan == nil ? 0 : 300, minHeight: 0)
                            .background(NativeSplitPositionDriver(trailingFraction: selectedSpan == nil ? 0 : 0.25))
                            .background(PaneSizeObserver { size in
                                if selectedSpanID != nil, !inspectorIsOpening, size.width < 30 { selectedSpanID = nil }
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
            hoveredSpanID = nil
            parentLinkTargetSpanID = nil
            guard oldValue == nil, newValue != nil else { return }
            waterfallIsOpening = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                waterfallIsOpening = false
            }
        }
        .onChange(of: selectedSpanID) { oldValue, newValue in
            guard oldValue == nil, newValue != nil else { return }
            inspectorIsOpening = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                inspectorIsOpening = false
            }
        }
        .navigationTitle("Traces")
    }

    @ViewBuilder
    private func traceContent(height: CGFloat) -> some View {
        VSplitView {
            traceTable
                .frame(minWidth: 0, minHeight: 0)
            Group {
                if selection != nil {
                TraceWaterfall(
                    spans: selectedTrace,
                    selectedSpanID: $selectedSpanID,
                    hoveredSpanID: $hoveredSpanID,
                    parentLinkTargetSpanID: parentLinkTargetSpanID
                )
                    .frame(minWidth: 0, minHeight: 0)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .frame(minWidth: 0, minHeight: 0, idealHeight: selection == nil ? 0 : height * 0.7)
            .background(NativeSplitPositionDriver(trailingFraction: selection == nil ? 0 : 0.7))
            .background(PaneSizeObserver { size in
                if selection != nil, !waterfallIsOpening, size.height < 30 {
                    selection = nil
                    selectedSpanID = nil
                }
            })
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
                .onChange(of: proxy.size) { _, size in onChange(size) }
        }
    }
}

/// Drives an existing native split view between a collapsed detail pane and
/// its requested width, avoiding a new split view's default half-width frame.
private struct NativeSplitPositionDriver: NSViewRepresentable {
    let trailingFraction: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view, coordinator: context.coordinator)
    }

    private func apply(to view: NSView, coordinator: Coordinator) {
        guard coordinator.lastFraction != trailingFraction else { return }
        var ancestor = view.superview
        while let current = ancestor, !(current is NSSplitView) {
            ancestor = current.superview
        }
        guard let splitView = ancestor as? NSSplitView else { return }
        let dimension = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard dimension > 0 else { return }
        let position = dimension * (1 - trailingFraction)
        if coordinator.lastFraction == nil {
            splitView.setPosition(position, ofDividerAt: 0)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                splitView.animator().setPosition(position, ofDividerAt: 0)
            }
        }
        coordinator.lastFraction = trailingFraction
    }

    final class Coordinator { var lastFraction: CGFloat? }
}

private struct TraceWaterfall: View {
    let spans: [CollectorState.TraceItem]
    @Binding var selectedSpanID: CollectorState.TraceItem.ID?
    @Binding var hoveredSpanID: CollectorState.TraceItem.ID?
    let parentLinkTargetSpanID: CollectorState.TraceItem.ID?
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
                        let rowTrailingPadding: CGFloat = 2
                        let timelineWidth = max(300, viewport.size.width - labelWidth - 8 - rowTrailingPadding)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Text("SPAN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .trailing)
                                TraceRuler(width: timelineWidth, durationMilliseconds: duration * 1_000)
                            }
                            .frame(height: 18)
                            .frame(width: viewport.size.width, alignment: .leading)
                            ScrollView(.vertical) {
                                ZStack(alignment: .topLeading) {
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
                                            let spanEndOffset = min(timelineWidth, offset + width)
                                            WaterfallBar(
                                                span: span,
                                                width: width,
                                                offsetMilliseconds: elapsedMilliseconds,
                                                isSelected: selectedSpanID == span.id,
                                                isHovered: hoveredSpanID == span.id,
                                                select: { selectedSpanID = span.id }
                                            )
                                                .offset(x: offset)
                                            WaterfallTimingAnnotations(
                                                startMilliseconds: elapsedMilliseconds,
                                                endMilliseconds: elapsedMilliseconds + span.durationMilliseconds,
                                                spanStartX: offset,
                                                spanEndX: spanEndOffset,
                                                timelineWidth: timelineWidth,
                                                isVisible: hoveredSpanID == span.id
                                            )
                                        }.frame(height: 18)
                                    }
                                    .frame(height: 22)
                                    .frame(width: viewport.size.width, alignment: .leading)
                                    .background(selectedSpanID == span.id ? Color.gray.opacity(0.16) : hoveredSpanID == span.id ? Color.gray.opacity(0.08) : .clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedSpanID = span.id }
                                    .onHover { isHovering in
                                        hoveredSpanID = isHovering ? span.id : nil
                                    }
                                }
                                    }

                                    relationshipArrow(timelineWidth: timelineWidth, duration: duration)
                                }
                                .frame(minHeight: CGFloat(spans.count * 22))
                                .frame(width: viewport.size.width)
                            }
                        }
                        .overlay {
                            WaterfallCursorOverlay(
                                timelineStartX: labelWidth + 8,
                                timelineWidth: timelineWidth,
                                durationMilliseconds: duration * 1_000,
                                headerHeight: 18
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func relationshipArrow(timelineWidth: CGFloat, duration: TimeInterval) -> some View {
        if let selectedSpanID,
           let parentLinkTargetSpanID,
           let selectedIndex = spans.firstIndex(where: { $0.id == selectedSpanID }),
           let parentIndex = spans.firstIndex(where: { $0.id == parentLinkTargetSpanID }),
           selectedIndex - parentIndex > 1 {
            let selectedSpan = spans[selectedIndex]
            let selectedOffset = max(0, timelineWidth * selectedSpan.time.timeIntervalSince(start) / duration)
            let selectedWidth = max(3, timelineWidth * (selectedSpan.durationMilliseconds / 1_000) / duration)
            let barCenterX = labelWidth + 8 + selectedOffset + (selectedWidth / 2)
            let arrowStartY = CGFloat(selectedIndex * 22) - 5
            let arrowEndY = CGFloat(parentIndex * 22) + 26

            RelationshipArrow(start: CGPoint(x: barCenterX, y: arrowStartY), end: CGPoint(x: barCenterX, y: arrowEndY))
                .stroke(Color.gray.opacity(0.65), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
        }
    }

}

private struct RelationshipArrow: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        path.move(to: CGPoint(x: end.x - 5, y: end.y + 7))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x + 5, y: end.y + 7))
        return path
    }
}

private struct WaterfallTimingAnnotations: View {
    let startMilliseconds: Double
    let endMilliseconds: Double
    let spanStartX: CGFloat
    let spanEndX: CGFloat
    let timelineWidth: CGFloat
    let isVisible: Bool

    private let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    private let spanPadding: CGFloat = 4

    var body: some View {
        let startLabel = String(format: "+%.2f ms", startMilliseconds)
        let endLabel = String(format: "+%.2f ms", endMilliseconds)
        let durationLabel = String(format: "%.2f ms", endMilliseconds - startMilliseconds)
        // Reserve enough room for the timestamp, SF Symbol, and their spacing
        // before deciding whether an annotation can fit beside a span.
        let timestampWidth = max(
            (startLabel as NSString).size(withAttributes: [.font: font]).width,
            (endLabel as NSString).size(withAttributes: [.font: font]).width
        )
        let annotationWidth = ceil(timestampWidth) + 17
        let durationWidth = ceil((durationLabel as NSString).size(withAttributes: [.font: font]).width) + 24

        if isVisible, spanStartX >= annotationWidth + spanPadding {
            HStack(spacing: 2) {
                Text(startLabel)
                Image(systemName: "arrow.right.to.line")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: annotationWidth, alignment: .trailing)
            .offset(x: spanStartX - spanPadding - annotationWidth)
        }

        if isVisible, timelineWidth - spanEndX >= annotationWidth + spanPadding {
            HStack(spacing: 2) {
                Image(systemName: "arrow.left.to.line")
                Text(endLabel)
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: annotationWidth, alignment: .leading)
            .offset(x: spanEndX + spanPadding)
        }

        if isVisible, spanEndX - spanStartX >= durationWidth + (spanPadding * 2) {
            HStack(spacing: 2) {
                Image(systemName: "arrow.left")
                Text(durationLabel)
                Image(systemName: "arrow.right")
            }
            .font(.system(size: 9, design: .monospaced).weight(.medium))
            .foregroundStyle(.white)
            .frame(width: spanEndX - spanStartX - (spanPadding * 2))
            .offset(x: spanStartX + spanPadding)
        }
    }
}

/// Draws the waterfall time cursor outside SwiftUI's state/update cycle so its
/// label and vertical rule are positioned from the same mouse event.
private struct WaterfallCursorOverlay: NSViewRepresentable {
    let timelineStartX: CGFloat
    let timelineWidth: CGFloat
    let durationMilliseconds: Double
    let headerHeight: CGFloat

    func makeNSView(context: Context) -> CursorTrackingView {
        CursorTrackingView()
    }

    func updateNSView(_ view: CursorTrackingView, context: Context) {
        view.timelineStartX = timelineStartX
        view.timelineWidth = timelineWidth
        view.durationMilliseconds = durationMilliseconds
        view.headerHeight = headerHeight
    }
}

private final class CursorTrackingView: NSView {
    var timelineStartX: CGFloat = 0
    var timelineWidth: CGFloat = 0
    var durationMilliseconds: Double = 0
    var headerHeight: CGFloat = 18

    private let cursorRule = NSView()
    private let timeLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        cursorRule.wantsLayer = true
        cursorRule.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.65).cgColor
        cursorRule.isHidden = true
        addSubview(cursorRule)

        timeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .labelColor
        timeLabel.alignment = .center
        timeLabel.drawsBackground = false
        timeLabel.wantsLayer = true
        // A layer-backed fill remains visible while the label moves rapidly;
        // NSTextField's background drawing can be skipped during live tracking.
        timeLabel.layer?.backgroundColor = NSColor(calibratedWhite: 0.72, alpha: 0.72).cgColor
        timeLabel.layer?.cornerRadius = 4
        timeLabel.layer?.masksToBounds = true
        timeLabel.isHidden = true
        addSubview(timeLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hideCursor() }

    private func updateCursor(at location: NSPoint) {
        guard timelineWidth > 0,
              location.x >= timelineStartX,
              location.x <= timelineStartX + timelineWidth else {
            hideCursor()
            return
        }

        let elapsedX = min(max(0, location.x - timelineStartX), timelineWidth)
        let label = String(format: "+%.2f ms", elapsedX / timelineWidth * durationMilliseconds)
        let labelWidth = ceil((label as NSString).size(withAttributes: [.font: timeLabel.font!]).width) + 10
        let labelX = min(location.x, max(0, bounds.width - labelWidth))

        // These frames are committed together for the event, keeping the rule
        // and its value selector locked to the physical cursor position.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorRule.frame = NSRect(x: location.x, y: headerHeight, width: 1, height: max(0, bounds.height - headerHeight))
        timeLabel.stringValue = label
        timeLabel.frame = NSRect(x: labelX, y: 4, width: labelWidth, height: 17)
        cursorRule.isHidden = false
        timeLabel.isHidden = false
        CATransaction.commit()
    }

    private func hideCursor() {
        cursorRule.isHidden = true
        timeLabel.isHidden = true
    }
}

private struct WaterfallBar: View {
    let span: CollectorState.TraceItem
    let width: CGFloat
    let offsetMilliseconds: Double
    let isSelected: Bool
    let isHovered: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            let isActive = isSelected || isHovered || hovering
            RoundedRectangle(cornerRadius: 3)
                .fill(isActive ? Color.accentColor : Color.accentColor.opacity(0.18))
                .frame(width: width, height: isActive ? 18 : 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1))
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
    let parentSpan: CollectorState.TraceItem?
    let selectParent: (CollectorState.TraceItem) -> Void
    let setHoveredSpan: (CollectorState.TraceItem.ID?) -> Void
    let setParentLinkTarget: (CollectorState.TraceItem.ID?) -> Void
    @State private var isHoveringParentLink = false

    var body: some View {
        Group {
            if let span, let traceStart {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
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

                        Divider()
                        inspectorSection("Relationships") {
                            if let parentSpan {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Parent Span")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    VStack {
                                        Button {
                                            selectParent(parentSpan)
                                        } label: {
                                            HStack(spacing: 6) {
                                                Text(String(format: "%.2f ms", parentSpan.durationMilliseconds))
                                                    .font(.caption.monospaced().weight(.semibold))
                                                Spacer(minLength: 0)
                                                Image(systemName: "arrow.up")
                                                    .font(.caption.weight(.bold))
                                            }
                                            .foregroundStyle(isHoveringParentLink ? Color.white : Color.accentColor)
                                            .padding(.horizontal, 9)
                                            .frame(height: 24)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                isHoveringParentLink ? Color.accentColor : Color.accentColor.opacity(0.18),
                                                in: RoundedRectangle(cornerRadius: 3)
                                            )
                                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Open parent span: \(parentSpan.name)")
                                    }
                                    .padding(6)
                                    .background(isHoveringParentLink ? Color.gray.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(RoundedRectangle(cornerRadius: 6))
                                    .onHover { isHovering in
                                        isHoveringParentLink = isHovering
                                        setHoveredSpan(isHovering ? parentSpan.id : nil)
                                        setParentLinkTarget(isHovering ? parentSpan.id : nil)
                                    }
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active:
                                            NSCursor.pointingHand.set()
                                        case .ended:
                                            NSCursor.arrow.set()
                                        }
                                    }
                                }
                            }
                        }

                        if !span.attributes.isEmpty {
                            Divider()
                            inspectorSection("Attributes") {
                                ForEach(span.attributes.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(key).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        Text(value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .padding(12)
                    .onChange(of: parentSpan?.id) { _, parentID in
                        guard isHoveringParentLink else { return }
                        setHoveredSpan(parentID)
                        setParentLinkTarget(parentID)
                        if parentID != nil { NSCursor.pointingHand.set() }
                    }
                }
            } else {
                EmptyView()
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
