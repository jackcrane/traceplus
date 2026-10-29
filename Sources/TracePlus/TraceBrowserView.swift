import AppKit
import SwiftUI
import TelemetryKit

struct TracesView: View {
    private struct TraceSummary: Identifiable {
        let id: String; let operation: String; let service: String; let start: Date; let duration: Double; let spanCount: Int; let hasError: Bool; let attributes: [String: [String]]
    }

    private enum FilterField: Hashable, Identifiable {
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

    private enum FilterComparator: String, Identifiable {
        case equals
        case isNot
        case contains
        case doesNotContain
        case greaterThan
        case greaterThanOrEqualTo
        case lessThan
        case lessThanOrEqualTo
        case before
        case after

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

    private enum TraceStatus: String, CaseIterable, Identifiable {
        case ok = "OK"
        case error = "Error"

        var id: Self { self }
    }

    private struct TraceFilter: Identifiable, Equatable {
        let id = UUID()
        var isEnabled = true
        var field: FilterField = .service
        var comparator: FilterComparator = .equals
        var textValue = ""
        var statusValue = TraceStatus.ok
        var dateValue = Date.now
    }

    @Environment(CollectorState.self) private var collector
    @State private var selection: String?
    @State private var selectedSpanID: CollectorState.TraceItem.ID?
    @State private var hoveredSpanID: CollectorState.TraceItem.ID?
    @State private var parentLinkTargetSpanID: CollectorState.TraceItem.ID?
    @State private var blockedByLinkTargetSpanID: CollectorState.TraceItem.ID?
    @State private var inspectorIsOpening = false
    @State private var waterfallIsOpening = false
    @State private var sortOrder: [KeyPathComparator<TraceSummary>] = [KeyPathComparator(\.start, order: .reverse)]
    @State private var filters: [TraceFilter] = []

    private var allSummaries: [TraceSummary] {
        Dictionary(grouping: collector.traces, by: \.traceID).map { id, spans in
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
    }
    private var attributeKeys: [String] {
        Array(Set(allSummaries.flatMap { $0.attributes.keys })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var summaries: [TraceSummary] {
        allSummaries.filter { summary in
            filters.filter(\.isEnabled).allSatisfy { matches($0, summary: summary) }
        }.sorted(using: sortOrder)
    }
    private var selectedTrace: [CollectorState.TraceItem] {
        guard let selection else { return [] }
        return TraceSpanOrdering.parentFirst(collector.traces.filter { $0.traceID == selection })
    }
    private var selectedSpan: CollectorState.TraceItem? {
        selectedTrace.first { $0.id == selectedSpanID }
    }
    private var blockedBySpan: CollectorState.TraceItem? {
        guard let selectedSpan,
              let parentSpanID = selectedSpan.parentSpanID,
              let selectedIndex = selectedTrace.firstIndex(where: { $0.id == selectedSpan.id }),
              let parentIndex = selectedTrace.firstIndex(where: { $0.spanID == parentSpanID }),
              selectedIndex - parentIndex > 1 else {
            return nil
        }

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
    private var selectedSpanDescendants: [CollectorState.TraceItem] {
        guard let selectedSpan else { return [] }

        var knownIDs = Set([selectedSpan.id])
        var descendantIDs = Set<CollectorState.TraceItem.ID>()
        var parentSpanIDs = Set([selectedSpan.spanID])

        while true {
            let children = selectedTrace.filter { span in
                !knownIDs.contains(span.id) &&
                    span.parentSpanID.map(parentSpanIDs.contains) == true
            }
            guard !children.isEmpty else { break }
            knownIDs.formUnion(children.map(\.id))
            descendantIDs.formUnion(children.map(\.id))
            parentSpanIDs.formUnion(children.map(\.spanID))
        }

        // Preserve the exact ordering used by the primary waterfall, including
        // its ordering for spans with identical timestamps.
        return selectedTrace.filter { descendantIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            GeometryReader { proxy in
                Group {
                    if selection != nil {
                        HSplitView {
                            traceContent(height: proxy.size.height)
                                .frame(minWidth: 0, minHeight: 0)
                            Group {
                                if let selectedSpan {
                                    SpanInspector(
                                        span: selectedSpan,
                                        traceStart: selectedTrace.first?.time,
                                        parentSpan: selectedTrace.first { $0.spanID == selectedSpan.parentSpanID },
                                        blockedBySpan: blockedBySpan,
                                        descendantSpans: selectedSpanDescendants,
                                        traceSpanCount: selectedTrace.count,
                                        selectedSpanID: $selectedSpanID,
                                        hoveredSpanID: $hoveredSpanID,
                                        selectParent: { parent in selectedSpanID = parent.id },
                                        setHoveredSpan: { hoveredSpanID = $0 },
                                        setParentLinkTarget: { parentLinkTargetSpanID = $0 },
                                        setBlockedByLinkTarget: { blockedByLinkTargetSpanID = $0 }
                                    )
                                } else {
                                    Color.clear.frame(width: 0)
                                }
                            }
                                .frame(minWidth: 0, idealWidth: selectedSpan == nil ? 0 : 300, minHeight: 0)
                                .background(NativeSplitPositionDriver(trailingFraction: selectedSpan == nil ? 0 : 0.25))
                                .background(PaneSizeObserver { size in
                                    if selectedSpanID != nil, !inspectorIsOpening, size.width < 30 { selectedSpanID = nil }
                                })
                        }
                        .overlayPreferenceValue(DescendantTooltipAnchorPreference.self) { tooltip in
                            GeometryReader { overlayProxy in
                                if let tooltip {
                                    let spanRect = overlayProxy[tooltip.anchor]
                                    let tooltipWidth = DescendantSpanTooltip.width(for: tooltip.name)

                                    DescendantSpanTooltip(name: tooltip.name)
                                        .frame(width: tooltipWidth, height: 24)
                                        // The right chevron tip lands on the
                                        // hovered descendant's leading edge.
                                        .position(
                                            x: spanRect.minX - (tooltipWidth / 2),
                                            y: spanRect.midY
                                        )
                                        .allowsHitTesting(false)
                                        .zIndex(1)
                                }
                            }
                        }
                    } else {
                        traceContent(height: proxy.size.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .onChange(of: selection) { oldValue, newValue in
            selectedSpanID = nil
            hoveredSpanID = nil
            parentLinkTargetSpanID = nil
            blockedByLinkTargetSpanID = nil
            guard oldValue == nil, newValue != nil else { return }
            waterfallIsOpening = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                waterfallIsOpening = false
            }
        }
        .onChange(of: selectedSpanID) { oldValue, newValue in
            guard oldValue == nil, newValue != nil else { return }
            inspectorIsOpening = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                inspectorIsOpening = false
            }
        }
        .onChange(of: filters) { _, _ in clearHiddenSelection() }
    }

    @ViewBuilder
    private func traceContent(height: CGFloat) -> some View {
        VSplitView {
            traceTable
                .frame(minWidth: 0, minHeight: 0)
            Group {
                if selection != nil {
                TraceWaterfall(
                    spans: selectedTrace,
                    selectedSpanID: $selectedSpanID,
                    hoveredSpanID: $hoveredSpanID,
                    parentLinkTargetSpanID: parentLinkTargetSpanID,
                    blockedByLinkTargetSpanID: blockedByLinkTargetSpanID,
                    showsSpanLabels: true,
                    showsTimelineGrid: true,
                    timelineStart: nil,
                    timelineEnd: nil,
                    timelineLeadingPadding: 0,
                    displayedTimelineStartMilliseconds: 0,
                    timelineTickCount: 5,
                    descendantTimeline: nil,
                    showsDescendantHoverTooltip: false
                )
                    .frame(minWidth: 0, minHeight: 0)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .frame(minWidth: 0, minHeight: 0, idealHeight: selection == nil ? 0 : height * 0.7)
            .background(NativeSplitPositionDriver(trailingFraction: selection == nil ? 0 : 0.7))
            .background(PaneSizeObserver { size in
                if selection != nil, !waterfallIsOpening, size.height < 30 {
                    selection = nil
                    selectedSpanID = nil
                }
            })
        }
    }

    private var traceTable: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            Table(summaries, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Operation", value: \.operation) { Text($0.operation).lineLimit(1) }.width(min: 180, ideal: 280)
                TableColumn("Service", value: \.service) { Text($0.service).foregroundStyle(.secondary) }.width(min: 120, ideal: 160)
                TableColumn("Duration", value: \.duration) { Text(String(format: "%.2f ms", $0.duration)).monospacedDigit() }.width(110)
                TableColumn("Spans") { Text("\($0.spanCount)").monospacedDigit() }.width(60)
                TableColumn("Status") { item in Text(item.hasError ? "Error" : "OK").foregroundStyle(item.hasError ? .red : .green) }.width(70)
                TableColumn("Trace ID") { Text($0.id.prefix(12)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }.width(110)
                TableColumn("Time", value: \.start) { Text($0.start.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary) }.width(110)
            }
            .overlay {
                if collector.traces.isEmpty {
                    ContentUnavailableView("No traces yet", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Send a trace to the local receiver."))
                } else if summaries.isEmpty {
                    ContentUnavailableView("No matching traces", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try clearing a filter or broadening your search."))
                }
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if filters.isEmpty {
                Button("Add filter", systemImage: "plus", action: addFilter)
                    .buttonStyle(.bordered)
            }
            ForEach($filters) { $filter in
                filterRow(filter: $filter)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterRow(filter: Binding<TraceFilter>) -> some View {
        GeometryReader { proxy in
            let widths = filterRowWidths(for: proxy.size.width)

            HStack(spacing: 6) {
                Toggle("Enable filter", isOn: filter.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 24)
                    .help(filter.wrappedValue.isEnabled ? "Disable this filter" : "Enable this filter")

                NativePopupPicker(
                    entries: filterFieldEntries,
                    selection: filter.field,
                    onSelection: { field in
                        filter.wrappedValue.comparator = field.comparators[0]
                    }
                )
                .frame(width: widths.field, height: 22)

                NativePopupPicker(
                    entries: filter.wrappedValue.field.comparators.map { .option($0, $0.title) },
                    selection: filter.comparator
                )
                .frame(width: widths.comparator, height: 22)

                filterValueControl(filter: filter, width: widths.value)

                filterActionButton(icon: "minus", help: "Remove this filter") {
                    removeFilter(id: filter.wrappedValue.id)
                }
                .accessibilityLabel("Remove \(filter.wrappedValue.field.title) filter")

                filterActionButton(icon: "plus", help: "Add a filter below this one") {
                    addFilter(after: filter.wrappedValue.id)
                }
                .accessibilityLabel("Add filter")
            }
            .frame(width: proxy.size.width, height: 22, alignment: .leading)
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func filterValueControl(filter: Binding<TraceFilter>, width: CGFloat) -> some View {
        switch filter.wrappedValue.field {
        case .status:
            NativePopupPicker(
                entries: TraceStatus.allCases.map { .option($0, $0.rawValue) },
                selection: filter.statusValue
            )
            .frame(width: width, height: 22)
        case .start:
            NativeDatePicker(selection: filter.dateValue)
                .frame(width: width, height: 22)
        case .duration:
            TextField("Milliseconds", text: filter.textValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        case .spanCount:
            TextField("Number of spans", text: filter.textValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        case .operation, .service, .traceID, .attribute:
            TextField("Value", text: filter.textValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }

    private var filterFieldEntries: [NativePopupPicker<FilterField>.Entry] {
        var entries = FilterField.standardFields.map { NativePopupPicker<FilterField>.Entry.option($0, $0.title) }
        guard !attributeKeys.isEmpty else { return entries }
        entries.append(.separator)
        entries.append(contentsOf: attributeKeys.map { attribute in
            let field = FilterField.attribute(attribute)
            return .option(field, field.title)
        })
        return entries
    }

    private func filterActionButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(help)
    }

    private func filterRowWidths(for width: CGFloat) -> (field: CGFloat, comparator: CGFloat, value: CGFloat) {
        let checkboxWidth: CGFloat = 24
        let actionWidth: CGFloat = 28
        let spacing: CGFloat = 6
        let minimumFieldWidth: CGFloat = 80
        let preferredFieldWidth: CGFloat = 110
        let minimumComparatorWidth: CGFloat = 110
        // This accommodates the longest operator, "is greater than", without
        // truncation while remaining stable across every filter row.
        let preferredComparatorWidth: CGFloat = 150
        let minimumValueWidth: CGFloat = 120
        let nonSelectorWidth = checkboxWidth + (actionWidth * 2) + (spacing * 5) + minimumValueWidth
        let availableSelectorWidth = max(
            minimumFieldWidth + minimumComparatorWidth,
            width - nonSelectorWidth
        )
        let comparator = min(
            preferredComparatorWidth,
            max(minimumComparatorWidth, availableSelectorWidth - minimumFieldWidth)
        )
        let field = min(
            preferredFieldWidth,
            max(minimumFieldWidth, availableSelectorWidth - comparator)
        )
        let value = max(
            minimumValueWidth,
            width - checkboxWidth - field - comparator - (actionWidth * 2) - (spacing * 5)
        )
        return (field, comparator, value)
    }

    private func addFilter() {
        filters.append(TraceFilter())
    }

    private func addFilter(after id: TraceFilter.ID) {
        guard let index = filters.firstIndex(where: { $0.id == id }) else {
            addFilter()
            return
        }
        filters.insert(TraceFilter(), at: index + 1)
    }

    private func removeFilter(id: TraceFilter.ID) {
        filters.removeAll { $0.id == id }
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
            return matchesAttribute(summary.attributes[key] ?? [], comparator: filter.comparator, value: filter.textValue)
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

    private func matchesAttribute(_ values: [String], comparator: FilterComparator, value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }

        switch comparator {
        case .equals, .contains:
            return values.contains { matchesText($0, comparator: comparator, value: value) }
        case .isNot, .doesNotContain:
            return values.allSatisfy { matchesText($0, comparator: comparator, value: value) }
        default:
            return true
        }
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

    private func clearHiddenSelection() {
        guard let selection, !summaries.contains(where: { $0.id == selection }) else { return }
        self.selection = nil
        selectedSpanID = nil
    }
}

/// A native AppKit popup button that accepts SwiftUI's assigned width instead
/// of retaining the intrinsic width of its selected item.
private struct NativePopupPicker<Value: Hashable>: NSViewRepresentable {
    enum Entry {
        case option(Value, String)
        case separator
    }

    let entries: [Entry]
    @Binding var selection: Value
    var onSelection: ((Value) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        rebuild(button)
        selectCurrentValue(in: button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        rebuild(button)
        selectCurrentValue(in: button)
    }

    private func rebuild(_ button: NSPopUpButton) {
        button.removeAllItems()
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .option(_, let title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = index
                button.menu?.addItem(item)
            case .separator:
                button.menu?.addItem(.separator())
            }
        }
    }

    private func selectCurrentValue(in button: NSPopUpButton) {
        guard let index = entries.firstIndex(where: { entry in
            if case .option(let value, _) = entry { return value == selection }
            return false
        }) else { return }
        button.selectItem(withTag: index)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: NativePopupPicker

        init(_ parent: NativePopupPicker) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem,
                  item.tag < parent.entries.count,
                  case .option(let value, _) = parent.entries[item.tag] else { return }
            parent.selection = value
            parent.onSelection?(value)
        }
    }
}

/// A native date field that uses the full width allocated to a filter value.
private struct NativeDatePicker: NSViewRepresentable {
    @Binding var selection: Date

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: NSFont.systemFontSize)
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.dateChanged(_:))
        picker.dateValue = selection
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        if !Calendar.current.isDate(picker.dateValue, inSameDayAs: selection) {
            picker.dateValue = selection
        }
    }

    @MainActor final class Coordinator: NSObject {
        var parent: NativeDatePicker

        init(_ parent: NativeDatePicker) {
            self.parent = parent
        }

        @objc func dateChanged(_ sender: NSDatePicker) {
            parent.selection = sender.dateValue
        }
    }
}

