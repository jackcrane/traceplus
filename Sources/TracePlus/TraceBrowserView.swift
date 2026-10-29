import AppKit
import SwiftUI
import TelemetryKit

struct TracesView: View {
    @Environment(CollectorState.self) var collector
    @State var selection: String?
    @State var selectedSpanID: CollectorState.TraceItem.ID?
    @State var hoveredSpanID: CollectorState.TraceItem.ID?
    @State var parentLinkTargetSpanID: CollectorState.TraceItem.ID?
    @State var blockedByLinkTargetSpanID: CollectorState.TraceItem.ID?
    @State var inspectorIsOpening = false
    @State var waterfallIsOpening = false
    @State var sortOrder: [KeyPathComparator<TraceSummary>] = [KeyPathComparator(\.start, order: .reverse)]
    @State var filters: [TraceFilter] = []
    @State var traceIndex = TraceIndex()

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
        .onAppear { rebuildTraceIndex() }
        .onChange(of: collector.spanCount) { _, _ in rebuildTraceIndex() }
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
        .onChange(of: filters) { _, _ in clearHiddenSelection() }
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
        VStack(spacing: 0) {
            filterBar
            Divider()
            Table(summaries, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Operation", value: \.operation) { Text($0.operation).lineLimit(1) }.width(min: 180, ideal: 280)
                TableColumn("Service", value: \.service) { Text($0.service).foregroundStyle(.secondary) }.width(min: 120, ideal: 160)
                TableColumn("Duration", value: \.duration) { Text(String(format: "%.2f ms", $0.duration)).monospacedDigit() }.width(110)
                TableColumn("Spans") { Text("\($0.spanCount)").monospacedDigit() }.width(60)
                TableColumn("Status") { item in Text(item.hasError ? "Error" : "OK").foregroundStyle(item.hasError ? .red : .green) }.width(70)
                TableColumn("Trace ID") { Text($0.id.prefix(12)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }.width(110)
                TableColumn("Time", value: \.start) { Text($0.start.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary) }.width(110)
            }
            .overlay {
                if collector.traces.isEmpty {
                    ContentUnavailableView("No traces yet", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Send a trace to the local receiver."))
                } else if summaries.isEmpty {
                    ContentUnavailableView("No matching traces", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try clearing a filter or broadening your search."))
                }
            }
        }
    }

}
