import AppKit
import SwiftUI
import TelemetryKit
struct SpanInspector: View {
    let span: CollectorState.TraceItem?
    let traceStart: Date?
    let parentSpan: CollectorState.TraceItem?
    let blockedBySpan: CollectorState.TraceItem?
    let descendantSpans: [CollectorState.TraceItem]
    let traceSpanCount: Int
    @Binding var selectedSpanID: CollectorState.TraceItem.ID?
    @Binding var hoveredSpanID: CollectorState.TraceItem.ID?
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

                            descendantSpansSection
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

    @ViewBuilder
    private var descendantSpansSection: some View {
        if !descendantSpans.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Descendant spans")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if descendantSpans.count * 2 > traceSpanCount {
                    Text("This span has too many descendants to display here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let timeline = DescendantTimeline(
                        spans: descendantSpans,
                        traceStart: traceStart ?? descendantSpans[0].time
                    )
                    TraceWaterfall(
                        spans: descendantSpans,
                        selectedSpanID: $selectedSpanID,
                        hoveredSpanID: $hoveredSpanID,
                        parentLinkTargetSpanID: nil,
                        blockedByLinkTargetSpanID: nil,
                        showsSpanLabels: false,
                        showsTimelineGrid: false,
                        // Crop the compact view to the descendant interval, but
                        // retain its trace-relative position in the ruler.
                        timelineStart: timeline.start,
                        timelineEnd: timeline.end,
                        timelineLeadingPadding: 2,
                        displayedTimelineStartMilliseconds: timeline.traceRelativeStartMilliseconds,
                        timelineTickCount: 3,
                        descendantTimeline: timeline,
                        showsDescendantHoverTooltip: true
                    )
                    .frame(height: min(160, CGFloat(descendantSpans.count * 22 + 30)))
                }
            }
        }
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

