import AppKit
import SwiftUI
import TelemetryKit
struct RelationshipArrow: Shape {
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

struct BlockingSpanArrow: Shape {
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

struct WaterfallTimingAnnotations: View {
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
