import AppKit
import SwiftUI
import TelemetryKit

struct DestinationSidebar: View {
    @Binding var selection: AppDestination?

    var body: some View {
        List(AppDestination.allCases, selection: $selection) { destination in
            Label(destination.rawValue, systemImage: destination.icon).tag(destination)
        }
        .listStyle(.sidebar)
    }
}

struct AppDetailView: View {
    let selection: AppDestination?
    let openEmitter: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if selection == .overview {
                ReceiverToolbar(openEmitter: openEmitter)
            } else if let selection {
                PageHeader(title: selection.rawValue)
            }
            DestinationContent(selection: selection)
        }
        // The hidden title bar still reserves its top safe area after the
        // native toolbar is removed. Let our header occupy that space.
        .ignoresSafeArea(edges: .top)
    }
}

private struct ReceiverToolbar: View {
    @Environment(CollectorState.self) private var collector
    @Environment(TelemetryEmitter.self) private var emitter
    let openEmitter: () -> Void
    @State private var commandPressed = false
    @State private var modifierMonitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(collector.status == .running ? "Stop receiver" : "Start receiver") {
                collector.status == .running ? collector.stop() : collector.start()
            }
            .keyboardShortcut("r", modifiers: [.command])
            Button(commandPressed ? "Open Telemetry Fountain" : "Run realistic workload", systemImage: commandPressed ? "drop.fill" : "bolt.fill") {
                commandPressed ? openEmitter() : sendWorkload()
            }
            .help(commandPressed ? "Open Telemetry Fountain" : "Send a 2,500-span realistic workload. Hold Command to open Telemetry Fountain.")
        }
        .padding(.horizontal, 16).frame(height: 52)
        .onAppear { installModifierMonitor() }
        .onDisappear { removeModifierMonitor() }
        Divider()
    }

    private func sendWorkload() {
        if !emitter.isSending { emitter.sendRealisticWorkload() }
    }

    private func installModifierMonitor() {
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            commandPressed = event.modifierFlags.contains(.command)
            return event
        }
    }

    private func removeModifierMonitor() {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
    }
}

private struct DestinationContent: View {
    let selection: AppDestination?

    var body: some View {
        switch selection ?? .overview {
        case .overview: OverviewView()
        case .traces: TracesView()
        case .logs: LogsView()
        case .metrics: MetricsView()
        }
    }
}

struct PageHeader: View {
    let title: String

    var body: some View {
        HStack { Text(title).font(.title2.weight(.semibold)); Spacer() }
            .padding(.horizontal, 16).frame(height: 52)
    }
}
