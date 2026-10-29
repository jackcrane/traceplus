import Foundation

struct TraceSummary: Identifiable {
    let id: String
    let operation: String
    let service: String
    let start: Date
    let duration: Double
    let spanCount: Int
    let hasError: Bool
    let attributes: [String: [String]]
}

enum FilterField: Hashable, Identifiable {
    case operation, service, status, duration, spanCount, traceID, start
    case attribute(String)

    static let standardFields: [Self] = [.operation, .service, .status, .duration, .spanCount, .traceID, .start]

    var id: String {
        switch self {
        case .operation: "operation"
        case .service: "service"
        case .status: "status"
        case .duration: "duration"
        case .spanCount: "spanCount"
        case .traceID: "traceID"
        case .start: "start"
        case .attribute(let name): "attribute.\(name)"
        }
    }

    var title: String {
        switch self {
        case .operation: "Operation"
        case .service: "Service"
        case .status: "Status"
        case .duration: "Duration"
        case .spanCount: "Spans"
        case .traceID: "Trace ID"
        case .start: "Start time"
        case .attribute(let name): name
        }
    }

    var comparators: [FilterComparator] {
        switch self {
        case .operation, .service, .traceID, .attribute:
            [.equals, .isNot, .contains, .doesNotContain]
        case .status:
            [.equals, .isNot]
        case .duration, .spanCount:
            [.equals, .isNot, .greaterThan, .greaterThanOrEqualTo, .lessThan, .lessThanOrEqualTo]
        case .start:
            [.equals, .before, .after]
        }
    }
}

enum FilterComparator: String, Identifiable {
    case equals, isNot, contains, doesNotContain
    case greaterThan, greaterThanOrEqualTo, lessThan, lessThanOrEqualTo
    case before, after

    var id: Self { self }

    var title: String {
        switch self {
        case .equals: "is"
        case .isNot: "is not"
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .greaterThan: "is greater than"
        case .greaterThanOrEqualTo: "is at least"
        case .lessThan: "is less than"
        case .lessThanOrEqualTo: "is at most"
        case .before: "is before"
        case .after: "is after"
        }
    }
}

enum TraceStatus: String, CaseIterable, Identifiable {
    case ok = "OK"
    case error = "Error"

    var id: Self { self }
}

enum AttributeInput {
    case enumeration([String])
    case number
    case dateTime
    case text
}

struct TraceIndex {
    var summaries: [TraceSummary] = []
    var attributeInputs: [String: AttributeInput] = [:]
}

struct TraceFilter: Identifiable, Equatable {
    let id = UUID()
    var isEnabled = true
    var field: FilterField = .service
    var comparator: FilterComparator = .equals
    var textValue = ""
    var statusValue = TraceStatus.ok
    var dateValue = Date.now
}
