import AppKit
import SwiftUI

/// ⌘K: type what you want done instead of hunting for it.
///
/// The list is the same one the menus build, so nothing can be reachable here
/// and missing there. Presets are rows of their own, which is the point —
/// typing "webp" should convert, not open a submenu.
struct ShelfCommandBarView: View {
    let controller: ShelfController
    let commands: [ShelfCommand]

    @State private var query = ""
    @State private var selection = 0

    private var results: [ShelfCommand] {
        ShelfCommandSearch.rank(commands, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ShelfSearchField(
                    text: $query,
                    placeholder: "Run an action…",
                    onMove: move,
                    onRun: run,
                    onCancel: { ShelfDialog.shared.dismiss() }
                )
                .frame(height: 20)
                .onChange(of: query) { selection = 0 }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            if !results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                // A Button rather than a tap gesture: only a
                                // real control carries an accessibility action,
                                // and without one the list cannot be operated
                                // by anything but a mouse.
                                Button {
                                    selection = index
                                    run()
                                } label: {
                                    row(command, isSelected: index == selection)
                                }
                                .buttonStyle(.plain)
                                .id(command.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(results.count) * 29 + 12, 250))
                    .onChange(of: selection) {
                        guard results.indices.contains(selection) else { return }
                        proxy.scrollTo(results[selection].id)
                    }
                }
            } else {
                Divider()
                Text("No matching action")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
            }
        }
    }

    private func row(_ command: ShelfCommand, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: command.symbol)
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(isSelected ? Color.white : .secondary)
            Text(command.title)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white : .primary)
            if let subtitle = command.subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? controller.model.color : Color.clear)
        }
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        let results = results
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
    }

    private func run() {
        let results = results
        guard results.indices.contains(selection) else { return }
        let command = results[selection]
        ShelfDialog.shared.dismiss()
        ShelfActionRunner.run(command, in: controller)
    }
}

/// The search field, in AppKit.
///
/// SwiftUI's `TextField` cannot do either half of this: `@FocusState` does not
/// take in a borderless panel that is made key after the first layout pass, and
/// the arrows never reach the view because the field editor keeps them for
/// moving the caret. The field editor reports both through `doCommandBy`.
private struct ShelfSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onRun: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true

        // The window is made key only once its height is known, so asking for
        // first responder now would be asking a window that cannot give it.
        Task { @MainActor in
            for _ in 0..<40 {
                if let window = field.window, window.isKeyWindow {
                    window.makeFirstResponder(field)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ShelfSearchField

        init(_ parent: ShelfSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onRun()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
