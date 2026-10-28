import AppKit
import SwiftUI
import TelemetryKit

@main
struct TelemetryFountainApp: App {
    @State private var emitter = TelemetryEmitter()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Telemetry Fountain") {
            EmitterView()
                .environment(emitter)
                .frame(minWidth: 650, minHeight: 520)
        }
    }
}
