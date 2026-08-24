import AppKit
import SwiftUI

/// The item's name turned into an editable field in place, the way Finder
/// renames a file: the base name arrives selected and the extension does not,
/// so typing replaces the name and leaves `.png` alone.
///
/// AppKit rather than SwiftUI's `TextField` because that selection is the whole
/// point, and only the field editor can be told what to select.
struct ShelfRenameField: NSViewRepresentable {
    let name: String
    var centred: Bool
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: name)
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 10)
        field.alignment = centred ? .center : .left
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.drawsBackground = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The view is not in a window yet, and nothing can be made first
        // responder until it is.
        Task { @MainActor in
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            context.coordinator.selectBaseName(in: field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    /// Teardown is never a commit. Whatever removed the field — the shelf
    /// closing, the item going away — did not mean "keep what was typed", and
    /// clicking away has already committed through `controlTextDidEndEditing`
    /// before it gets here.
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.abandon()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var finished = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func abandon() { finished = true }

        func selectBaseName(in field: NSTextField) {
            guard let editor = field.currentEditor() else { return }
            let name = field.stringValue as NSString
            let base = name.deletingPathExtension as NSString
            // A name that is all extension — ".gitignore" — has no base to
            // single out, so the whole thing is selected instead.
            let length = base.length == 0 ? name.length : base.length
            editor.selectedRange = NSRange(location: 0, length: length)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish { self.onCommit(textView.string) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish { self.onCancel() }
                return true
            default:
                return false
            }
        }

        /// Clicking away keeps the name, as it does in Finder.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish { self.onCommit(field.stringValue) }
        }

        /// Committing also ends editing, so without this the name would be
        /// applied twice — the second time against an item that has already
        /// been renamed.
        private func finish(_ body: () -> Void) {
            guard !finished else { return }
            finished = true
            body()
        }
    }
}
