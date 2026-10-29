import AppKit
import SwiftUI
import TelemetryKit

@main
struct TracePlusApp: App {
    @State private var collector = CollectorState()
    @State private var emitter = TelemetryEmitter()
    @State private var ramen = ContrailRunner()

    init() {
        // Swift Package executables are not launched by LaunchServices like an
        // .app bundle. Explicit activation makes `swift run` present a window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(collector)
                .environment(emitter)
                .frame(minWidth: 980, minHeight: 680)
                .task {
                    collector.start()
                }
        }
        .windowStyle(.hiddenTitleBar)

        WindowGroup("Telemetry Fountain", id: "emitter") {
            EmitterView()
                .environment(emitter)
                .environment(ramen)
                .frame(minWidth: 650, minHeight: 760)
        }
    }
}
