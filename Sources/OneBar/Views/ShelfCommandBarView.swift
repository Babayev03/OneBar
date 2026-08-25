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
    @FocusState private var fieldFocused: Bool

    private var results: [ShelfCommand] {
        ShelfCommandSearch.rank(commands, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Run an action…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($fieldFocused)
                    .onSubmit { run() }
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
        .onAppear { fieldFocused = true }
        .background { KeyCatcher(onMove: move, onRun: run) }
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

/// Arrows and Return belong to the list, not to the field editor, which would
/// otherwise move the caret and do nothing useful.
private struct KeyCatcher: NSViewRepresentable {
    let onMove: (Int) -> Void
    let onRun: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(onMove: onMove, onRun: onRun)
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.install(onMove: onMove, onRun: onRun)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        private var monitor: Any?
        private var onMove: ((Int) -> Void)?
        private var onRun: (() -> Void)?

        func install(onMove: @escaping (Int) -> Void, onRun: @escaping () -> Void) {
            self.onMove = onMove
            self.onRun = onRun
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 126: self.onMove?(-1); return nil
                case 125: self.onMove?(1); return nil
                case 36, 76: self.onRun?(); return nil
                default: return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
