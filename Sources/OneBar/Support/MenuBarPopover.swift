import AppKit

/// Closing the menu popover.
///
/// MenuBarExtra opens and closes the popover from its status item's own button
/// and keeps no other record of whether it is up. Ordering the window out
/// directly leaves that record saying "open", and the next click on the icon is
/// then spent putting it right rather than showing the popover — so the button
/// is what gets pressed.
@MainActor
enum MenuBarPopover {
    /// Closes the popover if one is showing. Safe to call when none is.
    static func close() {
        guard let popover = NSApp.windows.first(where: { $0.isVisible && isPopover($0) }) else { return }
        _ = close(popover)
    }

    /// Closes the popover and waits for it to actually leave the screen.
    /// `performClick` starts an *animated* dismissal, so anything that
    /// photographs the screen next — the interactive screenshot behind Scan
    /// Text and Scan QR — would otherwise catch the menu still fading out.
    static func closeAndWait() async {
        guard let popover = NSApp.windows.first(where: { $0.isVisible && isPopover($0) }) else { return }
        if !close(popover) { popover.orderOut(nil) }
        for _ in 0..<20 where popover.isVisible {
            try? await Task.sleep(for: .milliseconds(15))
        }
        // One more beat for the window server to composite the frame without it.
        try? await Task.sleep(for: .milliseconds(60))
    }

    static func isPopover(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).hasPrefix("MenuBarExtraWindow")
    }

    /// Returns false if the status item can't be found, leaving the caller to
    /// hide the window the blunt way.
    ///
    /// The item is picked by position: the popover hangs directly under the one
    /// it belongs to, which is what tells it apart from the status items
    /// Prevent Sleep and Auto Mouse Move add.
    @discardableResult
    static func close(_ popover: NSWindow) -> Bool {
        let anchor = popover.frame.midX
        let nearest = NSApp.windows
            .filter { $0.isVisible && String(describing: type(of: $0)) == "NSStatusBarWindow" }
            .min { abs($0.frame.midX - anchor) < abs($1.frame.midX - anchor) }
        guard let button = statusButton(in: nearest?.contentView) else { return false }
        button.performClick(nil)
        return true
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = statusButton(in: subview) { return found }
        }
        return nil
    }
}

