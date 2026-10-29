import TelemetryKit

extension TracesView {
    var selectedTrace: [CollectorState.TraceItem] {
        guard let selection else { return [] }
        return TraceSpanOrdering.parentFirst(collector.traces.filter { $0.traceID == selection })
    }

    var selectedSpan: CollectorState.TraceItem? {
        selectedTrace.first { $0.id == selectedSpanID }
    }

    var blockedBySpan: CollectorState.TraceItem? {
        guard let selectedSpan,
              let parentSpanID = selectedSpan.parentSpanID,
              let selectedIndex = selectedTrace.firstIndex(where: { $0.id == selectedSpan.id }),
              let parentIndex = selectedTrace.firstIndex(where: { $0.spanID == parentSpanID }),
              selectedIndex - parentIndex > 1 else { return nil }

        return selectedTrace
            .filter { candidate in
                candidate.id != selectedSpan.id &&
                    candidate.parentSpanID == selectedSpan.parentSpanID &&
                    candidate.time.addingTimeInterval(candidate.durationMilliseconds / 1_000) < selectedSpan.time &&
                    selectedSpan.time.timeIntervalSince(candidate.time.addingTimeInterval(candidate.durationMilliseconds / 1_000)) <= 0.010
            }
            .max { lhs, rhs in
                lhs.time.addingTimeInterval(lhs.durationMilliseconds / 1_000) <
                    rhs.time.addingTimeInterval(rhs.durationMilliseconds / 1_000)
            }
    }

    var selectedSpanDescendants: [CollectorState.TraceItem] {
        guard let selectedSpan else { return [] }
        var knownIDs = Set([selectedSpan.id])
        var descendantIDs = Set<CollectorState.TraceItem.ID>()
        var parentSpanIDs = Set([selectedSpan.spanID])

        while true {
            let children = selectedTrace.filter {
                !knownIDs.contains($0.id) && $0.parentSpanID.map(parentSpanIDs.contains) == true
            }
            guard !children.isEmpty else { break }
            knownIDs.formUnion(children.map(\.id))
            descendantIDs.formUnion(children.map(\.id))
            parentSpanIDs.formUnion(children.map(\.spanID))
        }
        return selectedTrace.filter { descendantIDs.contains($0.id) }
    }
}
