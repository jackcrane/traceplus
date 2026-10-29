import AppKit
import SwiftUI
import TelemetryKit

extension TracesView {
func rebuildTraceIndex() {
    let summaries = Dictionary(grouping: collector.traces, by: \.traceID).map { id, spans in
        let ordered = spans.sorted { $0.time < $1.time }
        let start = ordered.first?.time ?? .now
        let end = ordered.map { $0.time.addingTimeInterval($0.durationMilliseconds / 1_000) }.max() ?? start
        let root = ordered.first { $0.parentSpanID == nil } ?? ordered.first!
        var attributes: [String: [String]] = [:]
        for span in spans {
            for (key, value) in span.attributes {
                attributes[key, default: []].append(value)
            }
        }
        attributes = attributes.mapValues { Array(Set($0)).sorted() }
        return TraceSummary(id: id, operation: root.name, service: root.service, start: start, duration: end.timeIntervalSince(start) * 1_000, spanCount: spans.count, hasError: spans.contains { $0.statusCode == 2 }, attributes: attributes)
    }
    var valuesByAttribute: [String: Set<String>] = [:]
    for summary in summaries {
        for (key, values) in summary.attributes {
            valuesByAttribute[key, default: []].formUnion(values)
        }
    }
    let inputs: [String: AttributeInput] = valuesByAttribute.mapValues { values in
        let values = Array(values).sorted()
        if values.count < 8 { return .enumeration(values) }
        if values.allSatisfy({ Double($0) != nil }) { return .number }
        if values.allSatisfy({ date(fromAttributeValue: $0) != nil }) { return .dateTime }
        return .text
    }
    traceIndex = TraceIndex(summaries: summaries, attributeInputs: inputs)
}
var attributeKeys: [String] {
    traceIndex.attributeInputs.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}
func attributeInput(for key: String) -> AttributeInput {
    traceIndex.attributeInputs[key] ?? .text
}
func comparators(for field: FilterField) -> [FilterComparator] {
    guard case .attribute(let key) = field else { return field.comparators }
    switch attributeInput(for: key) {
    case .enumeration: return [.equals, .isNot]
    case .number: return [.equals, .isNot, .greaterThan, .greaterThanOrEqualTo, .lessThan, .lessThanOrEqualTo]
    case .dateTime: return [.equals, .before, .after]
    case .text: return field.comparators
    }
}
var summaries: [TraceSummary] {
    traceIndex.summaries.filter { summary in
        filters.filter(\.isEnabled).allSatisfy { matches($0, summary: summary) }
    }.sorted(using: sortOrder)
}

private func matches(_ filter: TraceFilter, summary: TraceSummary) -> Bool {
    switch filter.field {
    case .operation:
        return matchesText(summary.operation, comparator: filter.comparator, value: filter.textValue)
    case .service:
        return matchesText(summary.service, comparator: filter.comparator, value: filter.textValue)
    case .traceID:
        return matchesText(summary.id, comparator: filter.comparator, value: filter.textValue)
    case .attribute(let key):
        return matchesAttribute(summary.attributes[key] ?? [], input: attributeInput(for: key), filter: filter)
    case .status:
        let status: TraceStatus = summary.hasError ? .error : .ok
        return filter.comparator == .equals ? status == filter.statusValue : status != filter.statusValue
    case .duration:
        guard let value = Double(filter.textValue) else { return true }
        return matchesNumber(summary.duration, comparator: filter.comparator, value: value)
    case .spanCount:
        guard let value = Double(filter.textValue) else { return true }
        return matchesNumber(Double(summary.spanCount), comparator: filter.comparator, value: value)
    case .start:
        switch filter.comparator {
        case .equals: return abs(summary.start.timeIntervalSince(filter.dateValue)) < 1
        case .before: return summary.start < filter.dateValue
        case .after: return summary.start > filter.dateValue
        default: return true
        }
    }
}

private func matchesText(_ source: String, comparator: FilterComparator, value: String) -> Bool {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return true }
    switch comparator {
    case .equals: return source.compare(value, options: .caseInsensitive) == .orderedSame
    case .isNot: return source.compare(value, options: .caseInsensitive) != .orderedSame
    case .contains: return source.localizedCaseInsensitiveContains(value)
    case .doesNotContain: return !source.localizedCaseInsensitiveContains(value)
    default: return true
    }
}

private func matchesAttribute(_ values: [String], input: AttributeInput, filter: TraceFilter) -> Bool {
    let value = filter.textValue.trimmingCharacters(in: .whitespacesAndNewlines)

    switch input {
    case .number:
        guard !value.isEmpty else { return true }
        guard let number = Double(value) else { return true }
        return values.compactMap(Double.init).contains { matchesNumber($0, comparator: filter.comparator, value: number) }
    case .dateTime:
        return values.compactMap { date(fromAttributeValue: $0) }.contains { date in
            switch filter.comparator {
            case .equals: abs(date.timeIntervalSince(filter.dateValue)) < 1
            case .before: date < filter.dateValue
            case .after: date > filter.dateValue
            default: false
            }
        }
    case .enumeration, .text:
        break
    }

    guard !value.isEmpty else { return true }

    switch filter.comparator {
    case .equals, .contains:
        return values.contains { matchesText($0, comparator: filter.comparator, value: value) }
    case .isNot, .doesNotContain:
        return values.allSatisfy { matchesText($0, comparator: filter.comparator, value: value) }
    default:
        return true
    }
}

private func date(fromAttributeValue value: String) -> Date? {
    ISO8601DateFormatter().date(from: value)
}

private func matchesNumber(_ source: Double, comparator: FilterComparator, value: Double) -> Bool {
    switch comparator {
    case .equals: return source == value
    case .isNot: return source != value
    case .greaterThan: return source > value
    case .greaterThanOrEqualTo: return source >= value
    case .lessThan: return source < value
    case .lessThanOrEqualTo: return source <= value
    default: return true
    }
}

func clearHiddenSelection() {
    guard let selection, !summaries.contains(where: { $0.id == selection }) else { return }
    self.selection = nil
    selectedSpanID = nil
}
}
