import AppKit
import SwiftUI
import TelemetryKit
struct PaneSizeObserver: View {
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
struct NativeSplitPositionDriver: NSViewRepresentable {
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

struct DescendantTimeline {
    let start: Date
    let end: Date
    let traceRelativeStartMilliseconds: Double

    init(spans: [CollectorState.TraceItem], traceStart: Date) {
        precondition(!spans.isEmpty, "A descendant timeline requires at least one span.")
        start = spans.map(\.time).min()!
        end = spans
            .map { $0.time.addingTimeInterval($0.durationMilliseconds / 1_000) }
            .max()!
        traceRelativeStartMilliseconds = start.timeIntervalSince(traceStart) * 1_000
    }

    func position(for span: CollectorState.TraceItem) -> Double {
        span.time.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
}

struct DescendantTooltipAnchor {
    let name: String
    let anchor: Anchor<CGRect>
}

struct DescendantTooltipAnchorPreference: PreferenceKey {
    static let defaultValue: DescendantTooltipAnchor? = nil

    static func reduce(value: inout DescendantTooltipAnchor?, nextValue: () -> DescendantTooltipAnchor?) {
        value = nextValue() ?? value
    }
}

