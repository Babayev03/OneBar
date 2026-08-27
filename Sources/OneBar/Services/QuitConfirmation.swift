import AppKit

/// ⌘Q asks before it quits. For a menubar app the shortcut is almost always a
/// misfire: it arrives from the Preferences window, the clipboard panel or the
/// menu popover, which look like ordinary windows, and quitting takes the
/// clipboard history, the global shortcuts and the menubar stats down with it.
/// Only the ⌘Q key equivalent is routed through here — the menu's own Quit
/// means it, and Force Quit never reaches our code at all.
@MainActor
enum QuitConfirmation {
    static func requestQuit() {
        switch AppState.shared.quitShortcutBehavior {
        case .quit:
            NSApp.terminate(nil)
        case .ignore:
            // A remembered "Hide" has to still hide: ⌘Q that leaves the window
            // it was pressed in sitting there reads as the shortcut being
            // broken, not as a choice the user made earlier.
            hideFront(NSApp.keyWindow)
        case .ask:
            ask()
        }
    }

    private static func ask() {
        // Captured before the alert, which becomes the key window itself and
        // may leave none behind when it closes.
        let front = NSApp.keyWindow

        // The panel is non-activating and dismisses on a click outside it, so
        // it has to go before a modal window takes the focus from under it.
        ClipboardPanelController.shared.hide()

        let alert = NSAlert()
        alert.messageText = "Quit OneBar?"
        alert.informativeText = """
            OneBar lives in the menu bar. Hiding leaves it running there; \
            quitting stops the clipboard history, the global shortcuts and \
            the menu bar stats.
            """
        alert.alertStyle = .warning
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        // Hide goes first so it is the default button: a stray ⌘Q followed by
        // a stray Return must still not quit.
        let hide = alert.addButton(withTitle: "Hide")
        let quit = alert.addButton(withTitle: "Quit")
        quit.keyEquivalent = ""
        quit.hasDestructiveAction = true

        // Esc means "no" here, but AppKit only wires it to a button titled
        // Cancel, so it is put onto Hide by hand. A local monitor still runs
        // inside a modal session, and clicking the button ends that session
        // the same way the mouse would.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            hide.performClick(nil)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }

        // An accessory app has no window of its own in front, so without this
        // the alert can open behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)

        let quitting = alert.runModal() == .alertSecondButtonReturn
        if alert.suppressionButton?.state == .on {
            AppState.shared.quitShortcutBehavior = quitting ? .quit : .ignore
        }
        if quitting {
            NSApp.terminate(nil)
        } else {
            hideFront(front)
        }
    }

    /// The Hide half of the choice: put away the window ⌘Q arrived from and
    /// leave everything else running.
    private static func hideFront(_ window: NSWindow?) {
        ClipboardPanelController.shared.hide()

        guard let window, window.isVisible else { return }

        if MenuBarPopover.isPopover(window), MenuBarPopover.close(window) { return }

        // Ordered out rather than closed, so the menu can open it again.
        window.orderOut(nil)
    }
}
