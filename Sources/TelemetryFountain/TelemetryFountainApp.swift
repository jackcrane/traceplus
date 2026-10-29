import AppKit
import SwiftUI
import TelemetryKit

@main
struct TelemetryFountainApp: App {
    @State private var emitter = TelemetryEmitter()
    @State private var ramen = ContrailRunner()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Telemetry Fountain") {
            EmitterView()
                .environment(emitter)
                .environment(ramen)
                .frame(minWidth: 650, minHeight: 760)
        }
    }
}
