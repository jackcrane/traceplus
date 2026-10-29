import AppKit
import SwiftUI

/// A native AppKit popup button that expands to SwiftUI's assigned width.
struct NativePopupPicker<Value: Hashable>: NSViewRepresentable {
    enum Entry: Equatable { case option(Value, String); case separator }
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
        context.coordinator.entries = entries
        selectCurrentValue(in: button)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.entries != entries { rebuild(button); context.coordinator.entries = entries }
        selectCurrentValue(in: button)
    }
    private func rebuild(_ button: NSPopUpButton) {
        button.removeAllItems()
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .option(_, let title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = index; button.menu?.addItem(item)
            case .separator: button.menu?.addItem(.separator())
            }
        }
    }
    private func selectCurrentValue(in button: NSPopUpButton) {
        guard let index = entries.firstIndex(where: { if case .option(let value, _) = $0 { return value == selection }; return false }) else { return }
        if button.selectedTag() != index { button.selectItem(withTag: index) }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: NativePopupPicker
        var entries: [Entry] = []
        init(_ parent: NativePopupPicker) { self.parent = parent }
        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem, item.tag < parent.entries.count,
                  case .option(let value, _) = parent.entries[item.tag] else { return }
            parent.selection = value; parent.onSelection?(value)
        }
    }
}

/// A native, stretchable date-and-time field.
struct NativeDatePicker: NSViewRepresentable {
    @Binding var selection: Date
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single; picker.controlSize = .small
        picker.font = .systemFont(ofSize: NSFont.systemFontSize)
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.target = context.coordinator; picker.action = #selector(Coordinator.dateChanged(_:)); picker.dateValue = selection
        return picker
    }
    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        if !Calendar.current.isDate(picker.dateValue, inSameDayAs: selection) { picker.dateValue = selection }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: NativeDatePicker
        init(_ parent: NativeDatePicker) { self.parent = parent }
        @objc func dateChanged(_ sender: NSDatePicker) { parent.selection = sender.dateValue }
    }
}
