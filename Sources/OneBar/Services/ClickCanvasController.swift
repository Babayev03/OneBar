import AppKit
import Observation
import SwiftUI

extension NSScreen {
    /// This screen's top-left corner in CoreGraphics event space, where the
    /// primary display's top-left is the origin and y grows downward — the
    /// opposite of AppKit's bottom-left-origin global frame. Nodes are stored in
    /// event space, so this is what converts them into view coordinates.
    var eventSpaceOrigin: CGPoint {
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? frame.height
        return CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
    }
}

/// A borderless window refuses key status by default, which would leave the
/// canvas toolbar's buttons and keyboard shortcuts inert.
private final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Editing state that has to be shared across the per-screen canvas windows —
/// selecting a node on one display must deselect on the others.
@MainActor
@Observable
final class ClickCanvasModel {
    static let shared = ClickCanvasModel()
    var selection: UUID?
    private init() {}
}

/// Owns one full-screen transparent window per display: the surface you drop
/// click points onto and drag into place.
@MainActor
final class ClickCanvasController {
    static let shared = ClickCanvasController()

    private var windows: [NSWindow] = []
    private var screenObserver: NSObjectProtocol?
    private(set) var isOpen = false

    private init() {}

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        AppState.shared.autoClickEditing = true
        build()

        // Plugging in or unplugging a display leaves the old windows sized to
        // screens that no longer exist.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in ClickCanvasController.shared.rebuild() }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        AppState.shared.autoClickEditing = false
        ClickCanvasModel.shared.selection = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        teardown()
    }

    /// While the sequence runs the canvas has to stop swallowing mouse events,
    /// or it eats the very clicks we're posting underneath it.
    func setPassthrough(_ passthrough: Bool) {
        for window in windows {
            window.ignoresMouseEvents = passthrough
        }
    }

    private func rebuild() {
        teardown()
        build()
    }

    private func build() {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        for screen in NSScreen.screens {
            let window = CanvasWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            // Above ordinary windows so points can be placed over any app, but
            // below the screen-saver level the cleaning overlay uses — this one
            // is an editor, not a blocker.
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = AutoClickService.shared.isRunning
            window.contentView = NSHostingView(
                rootView: ClickCanvasView(screen: screen, isPrimary: screen == primary)
            )
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            if screen == primary { window.makeKey() }
            windows.append(window)
        }
    }

    private func teardown() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }
}
