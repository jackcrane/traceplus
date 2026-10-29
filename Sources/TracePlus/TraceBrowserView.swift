import AppKit
import SwiftUI
import TelemetryKit

struct TracesView: View {
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
        return TraceSpanOrdering.parentFirst(collector.traces.filter { $0.traceID == selection })
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
    private var selectedSpanDescendants: [CollectorState.TraceItem] {
        guard let selectedSpan else { return [] }

        var knownIDs = Set([selectedSpan.id])
        var descendantIDs = Set<CollectorState.TraceItem.ID>()
        var parentSpanIDs = Set([selectedSpan.spanID])

        while true {
            let children = selectedTrace.filter { span in
                !knownIDs.contains(span.id) &&
                    span.parentSpanID.map(parentSpanIDs.contains) == true
            }
            guard !children.isEmpty else { break }
            knownIDs.formUnion(children.map(\.id))
            descendantIDs.formUnion(children.map(\.id))
            parentSpanIDs.formUnion(children.map(\.spanID))
        }

        // Preserve the exact ordering used by the primary waterfall, including
        // its ordering for spans with identical timestamps.
        return selectedTrace.filter { descendantIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
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
                                        descendantSpans: selectedSpanDescendants,
                                        traceSpanCount: selectedTrace.count,
                                        selectedSpanID: $selectedSpanID,
                                        hoveredSpanID: $hoveredSpanID,
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
                        .overlayPreferenceValue(DescendantTooltipAnchorPreference.self) { tooltip in
                            GeometryReader { overlayProxy in
                                if let tooltip {
                                    let spanRect = overlayProxy[tooltip.anchor]
                                    let tooltipWidth = DescendantSpanTooltip.width(for: tooltip.name)

                                    DescendantSpanTooltip(name: tooltip.name)
                                        .frame(width: tooltipWidth, height: 24)
                                        // The right chevron tip lands on the
                                        // hovered descendant's leading edge.
                                        .position(
                                            x: spanRect.minX - (tooltipWidth / 2),
                                            y: spanRect.midY
                                        )
                                        .allowsHitTesting(false)
                                        .zIndex(1)
                                }
                            }
                        }
                    } else {
                        traceContent(height: proxy.size.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
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
                    blockedByLinkTargetSpanID: blockedByLinkTargetSpanID,
                    showsSpanLabels: true,
                    showsTimelineGrid: true,
                    timelineStart: nil,
                    timelineEnd: nil,
                    timelineLeadingPadding: 0,
                    displayedTimelineStartMilliseconds: 0,
                    timelineTickCount: 5,
                    descendantTimeline: nil,
                    showsDescendantHoverTooltip: false
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

