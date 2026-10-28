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
    @State private var blockedByLinkTargetSpanID: CollectorState.TraceItem.ID?
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
    private var blockedBySpan: CollectorState.TraceItem? {
        guard let selectedSpan,
              let parentSpanID = selectedSpan.parentSpanID,
              let selectedIndex = selectedTrace.firstIndex(where: { $0.id == selectedSpan.id }),
              let parentIndex = selectedTrace.firstIndex(where: { $0.spanID == parentSpanID }),
              selectedIndex - parentIndex > 1 else {
            return nil
        }

        return selectedTrace
            .filter { candidate in
                candidate.id != selectedSpan.id &&
                    candidate.parentSpanID == selectedSpan.parentSpanID &&
                    candidate.time.addingTimeInterval(candidate.durationMilliseconds / 1_000) < selectedSpan.time &&
                    selectedSpan.time.timeIntervalSince(candidate.time.addingTimeInterval(candidate.durationMilliseconds / 1_000)) <= 0.010
            }
            .max { lhs, rhs in
                lhs.time.addingTimeInterval(lhs.durationMilliseconds / 1_000) <
                    rhs.time.addingTimeInterval(rhs.durationMilliseconds / 1_000)
            }
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
                                    blockedBySpan: blockedBySpan,
                                    selectParent: { parent in selectedSpanID = parent.id },
                                    setHoveredSpan: { hoveredSpanID = $0 },
                                    setParentLinkTarget: { parentLinkTargetSpanID = $0 },
                                    setBlockedByLinkTarget: { blockedByLinkTargetSpanID = $0 }
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
            blockedByLinkTargetSpanID = nil
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
                    parentLinkTargetSpanID: parentLinkTargetSpanID,
                    blockedByLinkTargetSpanID: blockedByLinkTargetSpanID
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
    let blockedByLinkTargetSpanID: CollectorState.TraceItem.ID?
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
                                let selectedGroup = spanAndDescendants(rootSpanID: selectedSpanID)
                                let hoveredGroup = spanAndDescendants(rootSpanID: hoveredSpanID)
                                let groupsShareBottom = selectedSpanID != hoveredSpanID &&
                                    lastRowIndex(in: selectedGroup) == lastRowIndex(in: hoveredGroup)
                                let selectedBottomExtension: CGFloat = groupsShareBottom && selectedGroup.count > hoveredGroup.count ? 3 : 0
                                let hoveredBottomExtension: CGFloat = groupsShareBottom && hoveredGroup.count > selectedGroup.count ? 3 : 0
                                ZStack(alignment: .topLeading) {
                                    descendantGroupBox(
                                        groupedSpans: selectedGroup,
                                        timelineWidth: timelineWidth,
                                        duration: duration,
                                        bottomExtension: selectedBottomExtension
                                    )
                                    if hoveredSpanID != selectedSpanID {
                                        descendantGroupBox(
                                            groupedSpans: hoveredGroup,
                                            timelineWidth: timelineWidth,
                                            duration: duration,
                                            bottomExtension: hoveredBottomExtension
                                        )
                                    }

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
                                                isVisible: hoveredSpanID == span.id || selectedSpanID == span.id,
                                                endLabelPadding: endLabelPadding(for: span, timelineWidth: timelineWidth, duration: duration)
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
                                    blockedByArrow(timelineWidth: timelineWidth, duration: duration)
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
    private func descendantGroupBox(groupedSpans: [CollectorState.TraceItem], timelineWidth: CGFloat, duration: TimeInterval, bottomExtension: CGFloat) -> some View {
        if groupedSpans.count > 1, groupedSpans.count * 2 < spans.count {
            let spanIDs = Set(groupedSpans.map(\.id))
            let includedIndices = spans.indices.filter { spanIDs.contains(spans[$0].id) }
            if let firstIndex = includedIndices.min(), let lastIndex = includedIndices.max() {
                let horizontalBounds = groupedSpans.reduce(into: (min: CGFloat.greatestFiniteMagnitude, max: CGFloat.leastNormalMagnitude)) { bounds, span in
                    let offset = max(0, timelineWidth * span.time.timeIntervalSince(start) / duration)
                    let width = max(3, timelineWidth * (span.durationMilliseconds / 1_000) / duration)
                    bounds.min = min(bounds.min, offset)
                    bounds.max = max(bounds.max, min(timelineWidth, offset + width))
                }
                let padding: CGFloat = 2
                let x = labelWidth + 8 + horizontalBounds.min - padding
                let y = CGFloat(firstIndex * 22) + 2 - padding
                let width = horizontalBounds.max - horizontalBounds.min + (padding * 2)
                let height = CGFloat((lastIndex - firstIndex) * 22) + 18 + (padding * 2) + bottomExtension

                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                    .frame(width: width, height: height)
                    .offset(x: x, y: y)
                    .allowsHitTesting(false)
            }
        }
    }

    private func spanAndDescendants(rootSpanID: CollectorState.TraceItem.ID?) -> [CollectorState.TraceItem] {
        guard let rootSpanID,
              let rootSpan = spans.first(where: { $0.id == rootSpanID }) else {
            return []
        }

        var groupedSpans = [rootSpan]
        var includedIDs = Set([rootSpan.id])
        var parentSpanIDs = Set([rootSpan.spanID])

        while true {
            let children = spans.filter { span in
                !includedIDs.contains(span.id) &&
                    span.parentSpanID.map(parentSpanIDs.contains) == true
            }
            guard !children.isEmpty else { break }
            groupedSpans.append(contentsOf: children)
            includedIDs.formUnion(children.map(\.id))
            parentSpanIDs.formUnion(children.map(\.spanID))
        }

        return groupedSpans
    }

    private func lastRowIndex(in groupedSpans: [CollectorState.TraceItem]) -> Int? {
        let spanIDs = Set(groupedSpans.map(\.id))
        return spans.indices.last { spanIDs.contains(spans[$0].id) }
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

    @ViewBuilder
    private func blockedByArrow(timelineWidth: CGFloat, duration: TimeInterval) -> some View {
        if let selectedSpanID,
           let blockedByLinkTargetSpanID,
           let selectedIndex = spans.firstIndex(where: { $0.id == selectedSpanID }),
           let blockedByIndex = spans.firstIndex(where: { $0.id == blockedByLinkTargetSpanID }) {
            let selectedSpan = spans[selectedIndex]
            let blockingSpan = spans[blockedByIndex]
            let selectedOffset = max(0, timelineWidth * selectedSpan.time.timeIntervalSince(start) / duration)
            let selectedWidth = max(3, timelineWidth * (selectedSpan.durationMilliseconds / 1_000) / duration)
            let blockingOffset = max(0, timelineWidth * blockingSpan.time.timeIntervalSince(start) / duration)
            let blockingWidth = max(3, timelineWidth * (blockingSpan.durationMilliseconds / 1_000) / duration)
            let turnRadius: CGFloat = 6
            let arrowEndX = blockingOffset + blockingWidth + 5
            let startPoint = CGPoint(
                x: labelWidth + 8 + selectedOffset + (selectedWidth / 2),
                y: CGFloat(selectedIndex * 22) - 5
            )
            let endPoint = CGPoint(
                x: labelWidth + 8 + arrowEndX,
                y: CGFloat(blockedByIndex * 22) + 11
            )

            BlockingSpanArrow(start: startPoint, end: endPoint, turnRadius: turnRadius)
                .stroke(Color.gray.opacity(0.65), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
        }
    }

    private func endLabelPadding(for span: CollectorState.TraceItem, timelineWidth: CGFloat, duration: TimeInterval) -> CGFloat {
        guard span.id == blockedByLinkTargetSpanID,
              let selectedSpanID,
              let selectedSpan = spans.first(where: { $0.id == selectedSpanID }) else {
            return 4
        }

        let selectedOffset = max(0, timelineWidth * selectedSpan.time.timeIntervalSince(start) / duration)
        let selectedWidth = max(3, timelineWidth * (selectedSpan.durationMilliseconds / 1_000) / duration)
        let blockingOffset = max(0, timelineWidth * span.time.timeIntervalSince(start) / duration)
        let blockingWidth = max(3, timelineWidth * (span.durationMilliseconds / 1_000) / duration)
        let blockingEnd = blockingOffset + blockingWidth
        let arrowRightEdge = selectedOffset + (selectedWidth / 2)

        // Keep the annotation beyond the routed arrow's vertical leg, which
        // is the arrow's rightmost point.
        return max(4, arrowRightEdge - blockingEnd + 8)
    }

}

private struct RelationshipArrow: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        path.move(to: CGPoint(x: end.x - 3.5, y: end.y + 4.9))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x + 3.5, y: end.y + 4.9))
        return path
    }
}

private struct BlockingSpanArrow: Shape {
    let start: CGPoint
    let end: CGPoint
    let turnRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let bendStart = CGPoint(x: start.x, y: end.y + turnRadius)
        let bendEnd = CGPoint(x: start.x - turnRadius, y: end.y)
        let controlOffset = turnRadius * 0.552_284_75
        let control1 = CGPoint(x: bendStart.x, y: bendStart.y - controlOffset)
        let control2 = CGPoint(x: bendEnd.x + controlOffset, y: bendEnd.y)
        var path = Path()
        path.move(to: start)
        path.addLine(to: bendStart)

        if bendEnd.x >= end.x {
            path.addCurve(to: bendEnd, control1: control1, control2: control2)
            path.addLine(to: end)
        } else if bendStart.x > end.x {
            // The turn would pass the terminator. Draw only the portion of
            // the Bézier curve before it reaches the terminator's x-position.
            let clippedCurve = curveClipped(atX: end.x, from: bendStart, control1: control1, control2: control2, to: bendEnd)
            path.addCurve(to: clippedCurve.end, control1: clippedCurve.control1, control2: clippedCurve.control2)
        }

        path.move(to: CGPoint(x: end.x, y: end.y - 3.5))
        path.addLine(to: CGPoint(x: end.x, y: end.y + 3.5))
        return path
    }

    private func curveClipped(atX x: CGFloat, from start: CGPoint, control1: CGPoint, control2: CGPoint, to end: CGPoint) -> (control1: CGPoint, control2: CGPoint, end: CGPoint) {
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<16 {
            let midpoint = (lower + upper) / 2
            if cubicPoint(at: midpoint, start: start, control1: control1, control2: control2, end: end).x > x {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }

        let t = (lower + upper) / 2
        let first = interpolate(start, control1, t)
        let second = interpolate(control1, control2, t)
        let third = interpolate(control2, end, t)
        let fourth = interpolate(first, second, t)
        let fifth = interpolate(second, third, t)
        let clippedEnd = interpolate(fourth, fifth, t)
        return (first, fourth, CGPoint(x: x, y: clippedEnd.y))
    }

    private func cubicPoint(at t: CGFloat, start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) -> CGPoint {
        let first = interpolate(start, control1, t)
        let second = interpolate(control1, control2, t)
        let third = interpolate(control2, end, t)
        return interpolate(interpolate(first, second, t), interpolate(second, third, t), t)
    }

    private func interpolate(_ first: CGPoint, _ second: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: first.x + ((second.x - first.x) * t), y: first.y + ((second.y - first.y) * t))
    }
}

private struct WaterfallTimingAnnotations: View {
    let startMilliseconds: Double
    let endMilliseconds: Double
    let spanStartX: CGFloat
    let spanEndX: CGFloat
    let timelineWidth: CGFloat
    let isVisible: Bool
    let endLabelPadding: CGFloat

    private let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    private let spanPadding: CGFloat = 4
    private let iconWidth: CGFloat = 11
    private let iconSpacing: CGFloat = 2
    private let iconPadding: CGFloat = 4

    private struct LabelVariant {
        let text: String?
        let includesIcon: Bool
        let width: CGFloat
    }

    var body: some View {
        let startVariant = outsideLabel(
            milliseconds: startMilliseconds,
            availableWidth: spanStartX - spanPadding
        )
        let endVariant = outsideLabel(
            milliseconds: endMilliseconds,
            availableWidth: timelineWidth - spanEndX - endLabelPadding
        )
        let durationVariant = durationLabel(
            milliseconds: endMilliseconds - startMilliseconds,
            availableWidth: spanEndX - spanStartX - (spanPadding * 2)
        )

        if isVisible, let startVariant {
            HStack(spacing: 2) {
                if let text = startVariant.text { Text(text) }
                if startVariant.includesIcon { Image(systemName: "arrow.right.to.line") }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: startVariant.width, alignment: .trailing)
            .offset(x: spanStartX - spanPadding - startVariant.width)
        }

        if isVisible, let endVariant {
            HStack(spacing: 2) {
                if endVariant.includesIcon { Image(systemName: "arrow.left.to.line") }
                if let text = endVariant.text { Text(text) }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: endVariant.width, alignment: .leading)
            .offset(x: spanEndX + endLabelPadding)
        }

        if isVisible, let durationVariant {
            HStack(spacing: 2) {
                if durationVariant.includesIcon { Image(systemName: "arrow.left") }
                if let text = durationVariant.text { Text(text) }
                if durationVariant.includesIcon { Image(systemName: "arrow.right") }
            }
            .font(.system(size: 9, design: .monospaced).weight(.medium))
            .foregroundStyle(.white)
            .frame(width: spanEndX - spanStartX - (spanPadding * 2))
            .offset(x: spanStartX + spanPadding)
        }
    }

    private func outsideLabel(milliseconds: Double, availableWidth: CGFloat) -> LabelVariant? {
        let variants: [(String?, Bool)] = [
            (String(format: "+%.2f ms", milliseconds), true),
            (String(format: "%.2f ms", milliseconds), true),
            (String(format: "%.0f ms", milliseconds), true),
            (String(format: "%.0f", milliseconds), true),
            (nil, true)
        ]
        return firstFittingVariant(in: variants, availableWidth: availableWidth)
    }

    private func durationLabel(milliseconds: Double, availableWidth: CGFloat) -> LabelVariant? {
        let variants: [(String?, Bool)] = [
            (String(format: "%.2f ms", milliseconds), true),
            (String(format: "%.2f ms", milliseconds), false),
            (String(format: "%.0f ms", milliseconds), false),
            (String(format: "%.0f", milliseconds), false)
        ]
        return firstFittingVariant(in: variants, availableWidth: availableWidth)
    }

    private func firstFittingVariant(in variants: [(String?, Bool)], availableWidth: CGFloat) -> LabelVariant? {
        for (text, includesIcon) in variants {
            let textWidth = text.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) } ?? 0
            let width = textWidth + (includesIcon ? iconWidth + iconPadding + (text == nil ? 0 : iconSpacing) : 0)
            if width <= availableWidth {
                return LabelVariant(text: text, includesIcon: includesIcon, width: width)
            }
        }
        return nil
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
            let tint = span.statusCode == 2 ? Color(nsColor: .systemRed) : Color.accentColor
            RoundedRectangle(cornerRadius: 3)
                .fill(isActive ? tint : tint.opacity(0.18))
                .frame(width: width, height: isActive ? 18 : 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(tint, lineWidth: 1))
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
    let blockedBySpan: CollectorState.TraceItem?
    let selectParent: (CollectorState.TraceItem) -> Void
    let setHoveredSpan: (CollectorState.TraceItem.ID?) -> Void
    let setParentLinkTarget: (CollectorState.TraceItem.ID?) -> Void
    let setBlockedByLinkTarget: (CollectorState.TraceItem.ID?) -> Void
    @State private var isHoveringParentLink = false
    @State private var isHoveringBlockedByLink = false

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
                                .foregroundStyle(span.statusCode == 2 ? Color(nsColor: .systemRed) : .green)
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
                                let tint = parentSpan.statusCode == 2 ? Color(nsColor: .systemRed) : Color.accentColor
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Parent Span")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    VStack {
                                        Button {
                                            selectParent(parentSpan)
                                        } label: {
                                            HStack(spacing: 6) {
                                                Text(parentSpan.name)
                                                    .font(.caption.weight(.semibold))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                                    .layoutPriority(1)
                                                Spacer(minLength: 0)
                                                Image(systemName: "arrow.up")
                                                    .font(.caption.weight(.bold))
                                            }
                                            .foregroundStyle(isHoveringParentLink ? Color.white : tint)
                                            .padding(.horizontal, 9)
                                            .frame(height: 24)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                isHoveringParentLink ? tint : tint.opacity(0.18),
                                                in: RoundedRectangle(cornerRadius: 3)
                                            )
                                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(tint, lineWidth: 1))
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

                            if let blockedBySpan {
                                let tint = blockedBySpan.statusCode == 2 ? Color(nsColor: .systemRed) : Color.accentColor
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Blocked by")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    VStack {
                                        Button {
                                            selectParent(blockedBySpan)
                                        } label: {
                                            HStack(spacing: 6) {
                                                Text(blockedBySpan.name)
                                                    .font(.caption.weight(.semibold))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                                    .layoutPriority(1)
                                                Spacer(minLength: 0)
                                                Image(systemName: "arrow.up")
                                                    .font(.caption.weight(.bold))
                                            }
                                            .foregroundStyle(isHoveringBlockedByLink ? Color.white : tint)
                                            .padding(.horizontal, 9)
                                            .frame(height: 24)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                isHoveringBlockedByLink ? tint : tint.opacity(0.18),
                                                in: RoundedRectangle(cornerRadius: 3)
                                            )
                                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(tint, lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Open blocking span: \(blockedBySpan.name)")
                                    }
                                    .padding(6)
                                    .background(isHoveringBlockedByLink ? Color.gray.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(RoundedRectangle(cornerRadius: 6))
                                    .onHover { isHovering in
                                        isHoveringBlockedByLink = isHovering
                                        setHoveredSpan(isHovering ? blockedBySpan.id : nil)
                                        setBlockedByLinkTarget(isHovering ? blockedBySpan.id : nil)
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
                    .onChange(of: blockedBySpan?.id) { _, blockedByID in
                        guard isHoveringBlockedByLink else { return }
                        setHoveredSpan(blockedByID)
                        setBlockedByLinkTarget(blockedByID)
                        if blockedByID != nil { NSCursor.pointingHand.set() }
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
