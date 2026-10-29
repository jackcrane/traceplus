import SwiftUI

/// Window-level composition; feature screens live in their own source files.
struct AppShellView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var selection: AppDestination? = .overview

    var body: some View {
        NavigationSplitView {
            DestinationSidebar(selection: $selection)
        } detail: {
            AppDetailView(selection: $selection) { openWindow(id: "emitter") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
