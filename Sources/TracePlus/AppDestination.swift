import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case traces = "Traces"
    case logs = "Logs"
    case metrics = "Metrics"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .traces: "point.3.connected.trianglepath.dotted"
        case .logs: "text.alignleft"
        case .metrics: "chart.xyaxis.line"
        }
    }
}
