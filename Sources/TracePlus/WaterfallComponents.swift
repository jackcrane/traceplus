import AppKit
import SwiftUI
import TelemetryKit
struct WaterfallBar: View {
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

struct DescendantSpanTooltip: View {
    let name: String

    static func width(for name: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let textWidth = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        // Text, compact left/right padding, and the chevron point.
        return textWidth + 8 + 6 + 8
    }

    var body: some View {
        Text(name)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.white, in: DescendantTooltipChevron())
            .overlay(DescendantTooltipChevron().stroke(.gray.opacity(0.4), lineWidth: 1))
    }
}

struct DescendantTooltipChevron: Shape {
    func path(in rect: CGRect) -> Path {
        let pointWidth = min(8, rect.width / 4)
        let cornerRadius = min(5, rect.height / 4)
        let tipBaseX = rect.maxX - pointWidth
        let centerY = rect.midY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: tipBaseX - cornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: tipBaseX, y: rect.minY + cornerRadius),
            control: CGPoint(x: tipBaseX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: centerY))
        path.addLine(to: CGPoint(x: tipBaseX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: tipBaseX - cornerRadius, y: rect.maxY),
            control: CGPoint(x: tipBaseX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

struct TimelineGrid: View {
    let width: CGFloat
    var body: some View {
        HStack(spacing: 0) { ForEach(0..<5, id: \.self) { index in Rectangle().fill(.quaternary).frame(width: index == 0 ? 1 : 0.5); if index < 4 { Spacer(minLength: 0) } } }
            .frame(width: width, height: 18)
    }
}

struct TraceRuler: View {
    let width: CGFloat
    let durationMilliseconds: Double
    let startMilliseconds: Double
    let tickCount: Int
    var body: some View {
        ZStack {
            ForEach(0..<tickCount, id: \.self) { tick in
                let fraction = Double(tick) / Double(tickCount - 1)
                Text(String(format: "%.1f ms", startMilliseconds + (durationMilliseconds * fraction)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: width, alignment: tick == 0 ? .leading : tick == tickCount - 1 ? .trailing : .center)
                    .offset(x: tick == 0 || tick == tickCount - 1 ? 0 : width * (fraction - 0.5))
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

