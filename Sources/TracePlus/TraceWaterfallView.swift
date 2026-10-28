import AppKit
import SwiftUI
import TelemetryKit
struct TraceWaterfall: View {
    let spans: [CollectorState.TraceItem]
    @Binding var selectedSpanID: CollectorState.TraceItem.ID?
    @Binding var hoveredSpanID: CollectorState.TraceItem.ID?
    let parentLinkTargetSpanID: CollectorState.TraceItem.ID?
    let blockedByLinkTargetSpanID: CollectorState.TraceItem.ID?
    let showsSpanLabels: Bool
    let showsTimelineGrid: Bool
    let timelineStart: Date?
    let timelineEnd: Date?
    let timelineLeadingPadding: CGFloat
    let displayedTimelineStartMilliseconds: Double
    let timelineTickCount: Int
    let descendantTimeline: DescendantTimeline?
    let showsDescendantHoverTooltip: Bool
    private var start: Date { timelineStart ?? spans.map(\.time).min() ?? .now }
    private var end: Date { max(timelineEnd ?? spans.map { $0.time.addingTimeInterval($0.durationMilliseconds / 1_000) }.max() ?? start, start.addingTimeInterval(0.001)) }
    /// Reserve only the room needed by the widest span name. This keeps the
    /// waterfall as wide as possible while preventing an unusually long
    /// operation name from consuming the entire panel.
    private var labelWidth: CGFloat {
        guard showsSpanLabels else { return 0 }
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
                        let labelSpacing: CGFloat = showsSpanLabels ? 8 : 0
                        let minimumTimelineWidth: CGFloat = showsSpanLabels ? 300 : 1
                        let timelineWidth = max(minimumTimelineWidth, viewport.size.width - labelWidth - labelSpacing - timelineLeadingPadding - rowTrailingPadding)
                        let timelineStartX = labelWidth + labelSpacing + timelineLeadingPadding
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: labelSpacing) {
                                if showsSpanLabels {
                                    Text("SPAN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .trailing)
                                }
                                HStack(spacing: 0) {
                                    Color.clear.frame(width: timelineLeadingPadding)
                                    TraceRuler(
                                        width: timelineWidth,
                                        durationMilliseconds: duration * 1_000,
                                        startMilliseconds: displayedTimelineStartMilliseconds,
                                        tickCount: timelineTickCount
                                    )
                                }
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
                                        timelineStartX: timelineStartX,
                                        duration: duration,
                                        bottomExtension: selectedBottomExtension
                                    )
                                    if hoveredSpanID != selectedSpanID {
                                        descendantGroupBox(
                                            groupedSpans: hoveredGroup,
                                            timelineWidth: timelineWidth,
                                            timelineStartX: timelineStartX,
                                            duration: duration,
                                            bottomExtension: hoveredBottomExtension
                                        )
                                    }

                                    VStack(spacing: 0) {
                                    ForEach(spans) { span in
                                    HStack(spacing: labelSpacing) {
                                        if showsSpanLabels {
                                            Text(span.name)
                                                .font(.caption)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .frame(width: labelWidth, alignment: .trailing)
                                        }
                                        HStack(spacing: 0) {
                                            Color.clear.frame(width: timelineLeadingPadding)
                                            ZStack(alignment: .leading) {
                                                if showsTimelineGrid {
                                                    TimelineGrid(width: timelineWidth)
                                                }
                                            let elapsedMilliseconds: Double = span.time.timeIntervalSince(start) * 1_000
                                            let position = descendantTimeline.map { $0.position(for: span) }
                                                ?? elapsedMilliseconds / (duration * 1_000)
                                            let offset: CGFloat = min(timelineWidth, max(0, timelineWidth * position))
                                            let width: CGFloat = min(
                                                max(0, timelineWidth - offset),
                                                max(3, timelineWidth * (span.durationMilliseconds / 1_000) / duration)
                                            )
                                            let spanEndOffset = min(timelineWidth, offset + width)
                                            HStack(spacing: 0) {
                                                Color.clear.frame(width: offset)
                                                WaterfallBar(
                                                    span: span,
                                                    width: width,
                                                    offsetMilliseconds: displayedTimelineStartMilliseconds + elapsedMilliseconds,
                                                    isSelected: selectedSpanID == span.id,
                                                    isHovered: hoveredSpanID == span.id,
                                                    select: { selectedSpanID = span.id }
                                                )
                                                .anchorPreference(
                                                    key: DescendantTooltipAnchorPreference.self,
                                                    value: .bounds
                                                ) { anchor in
                                                    guard showsDescendantHoverTooltip, hoveredSpanID == span.id else {
                                                        return nil
                                                    }
                                                    return DescendantTooltipAnchor(name: span.name, anchor: anchor)
                                                }
                                                Spacer(minLength: 0)
                                            }
                                            .frame(width: timelineWidth, alignment: .leading)
                                            WaterfallTimingAnnotations(
                                                startMilliseconds: displayedTimelineStartMilliseconds + elapsedMilliseconds,
                                                endMilliseconds: displayedTimelineStartMilliseconds + elapsedMilliseconds + span.durationMilliseconds,
                                                spanStartX: offset,
                                                spanEndX: spanEndOffset,
                                                timelineWidth: timelineWidth,
                                                isVisible: hoveredSpanID == span.id || selectedSpanID == span.id,
                                                endLabelPadding: endLabelPadding(for: span, timelineWidth: timelineWidth, duration: duration)
                                            )
                                            }.frame(width: timelineWidth, height: 18)
                                        }
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
                                timelineStartX: timelineStartX,
                                timelineWidth: timelineWidth,
                                durationMilliseconds: duration * 1_000,
                                startMilliseconds: displayedTimelineStartMilliseconds,
                                headerHeight: 18
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func descendantGroupBox(groupedSpans: [CollectorState.TraceItem], timelineWidth: CGFloat, timelineStartX: CGFloat, duration: TimeInterval, bottomExtension: CGFloat) -> some View {
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
                let x = timelineStartX + horizontalBounds.min - padding
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

