import AppKit
import SwiftUI
import TelemetryKit

extension TracesView {
var filterBar: some View {
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
                    filter.wrappedValue.comparator = comparators(for: field)[0]
                }
            )
            .frame(width: widths.field, height: 22)

            NativePopupPicker(
                entries: comparators(for: filter.wrappedValue.field).map { .option($0, $0.title) },
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
    case .attribute(let key):
        attributeValueControl(filter: filter, key: key, width: width)
    case .operation, .service, .traceID:
        TextField("Value", text: filter.textValue)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
    }
}

@ViewBuilder
private func attributeValueControl(filter: Binding<TraceFilter>, key: String, width: CGFloat) -> some View {
    switch attributeInput(for: key) {
    case .enumeration(let values):
        NativePopupPicker(
            entries: values.map { .option($0, $0) },
            selection: filter.textValue
        )
        .frame(width: width, height: 22)
    case .number:
        TextField("Number", text: filter.textValue)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
    case .dateTime:
        NativeDatePicker(selection: filter.dateValue)
            .frame(width: width, height: 22)
    case .text:
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

}
