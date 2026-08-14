import AppKit
import SwiftUI

struct ShortcutsPane: View {
    private var store: ShortcutStore { ShortcutStore.shared }

    @State private var recordingAction: ShortcutAction?
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    group("Global", actions: ShortcutAction.allCases.filter(\.isGlobal))

                    group("Clipboard History", actions: ShortcutAction.allCases.filter { !$0.isGlobal })
                        .padding(.top, 12)
                }
                .padding(20)
            }

            // Outside the scroll view: while recording this is the only thing
            // telling you how to get out of it, so it can't scroll away.
            Text(recordingAction == nil
                 ? "Click a key to change it. The trash button restores the default. Global shortcuts need at least one modifier (⌘⌥⌃⇧)."
                 : "Press the new key combination… (Esc to cancel)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .onDisappear { stopRecording() }
    }

    private func group(_ title: String, actions: [ShortcutAction]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.bottom, 6)

                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    if index > 0 { Divider() }
                    shortcutRow(action)
                }
            }
            .padding(6)
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        HStack {
            Text(action.title)
                .font(.system(size: 13))

            Spacer()

            Button {
                if recordingAction == action {
                    stopRecording()
                } else {
                    beginRecording(action)
                }
            } label: {
                Text(recordingAction == action ? "…" : store.binding(for: action).display)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(recordingAction == action
                                       ? Color.blue.opacity(0.3)
                                       : Color.primary.opacity(0.08))
                    )
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                store.reset(action)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Restore default")
        }
        .padding(.vertical, 8)
    }

    private func beginRecording(_ action: ShortcutAction) {
        stopRecording()
        recordingAction = action
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels
                stopRecording()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if action.isGlobal && mods.isEmpty {
                NSSound.beep()
                return nil
            }
            store.set(KeyBinding(keyCode: event.keyCode, modifiers: mods), for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        recordingAction = nil
    }
}
