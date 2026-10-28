import AppKit
import SwiftUI
import TelemetryKit
struct WaterfallCursorOverlay: NSViewRepresentable {
    let timelineStartX: CGFloat
    let timelineWidth: CGFloat
    let durationMilliseconds: Double
    let startMilliseconds: Double
    let headerHeight: CGFloat

    func makeNSView(context: Context) -> CursorTrackingView {
        CursorTrackingView()
    }

    func updateNSView(_ view: CursorTrackingView, context: Context) {
        view.timelineStartX = timelineStartX
        view.timelineWidth = timelineWidth
        view.durationMilliseconds = durationMilliseconds
        view.startMilliseconds = startMilliseconds
        view.headerHeight = headerHeight
    }
}

final class CursorTrackingView: NSView {
    var timelineStartX: CGFloat = 0
    var timelineWidth: CGFloat = 0
    var durationMilliseconds: Double = 0
    var startMilliseconds: Double = 0
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
        let label = String(format: "+%.2f ms", startMilliseconds + (elapsedX / timelineWidth * durationMilliseconds))
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

