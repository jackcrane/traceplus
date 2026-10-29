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
    @Binding var selection: AppDestination?
    let openEmitter: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if selection == .overview {
                ReceiverToolbar(openEmitter: openEmitter) { selection = .overview }
            } else if let selection {
                PageHeader(title: selection.rawValue) { self.selection = .overview }
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
    let showOverview: () -> Void
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
            ClearStoredSignalsButton(showOverview: showOverview)
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
    let showOverview: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.title2.weight(.semibold))
            Spacer()
            ClearStoredSignalsButton(showOverview: showOverview)
        }
            .padding(.horizontal, 16).frame(height: 52)
    }
}

private struct ClearStoredSignalsButton: View {
    @Environment(CollectorState.self) private var collector
    let showOverview: () -> Void
    @State private var showingConfirmation = false

    var body: some View {
        Button("Clear stored telemetry", systemImage: "trash") {
            showingConfirmation = true
        }
        .labelStyle(.iconOnly)
        .help("Delete all stored traces, metrics, and logs")
        .accessibilityLabel("Delete all stored telemetry")
        .disabled(collector.traces.isEmpty && collector.logs.isEmpty && collector.metrics.isEmpty)
        .confirmationDialog(
            "Delete all stored telemetry?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                collector.clearStoredSignals()
                showOverview()
            }
        } message: {
            Text("This permanently removes all traces, metrics, and logs currently held in memory.")
        }
    }
}
