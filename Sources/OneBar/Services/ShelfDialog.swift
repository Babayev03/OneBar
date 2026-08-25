import AppKit
import SwiftUI

/// A small floating window for the things a shelf asks you before it acts, and
/// for Get Info.
///
/// A window rather than another `ShelfRoute`: the options are about the files,
/// not about the shelf, and swapping the shelf's own contents for a form hides
/// the very items being converted. One at a time — a second would be a second
/// answer to a question already on screen.
@MainActor
final class ShelfDialog {
    static let shared = ShelfDialog()

    private var panel: NSPanel?
    private var escapeMonitor: Any?
    private var hasSized = false

    private init() {}

    var isPresented: Bool { panel != nil }

    func present(
        title: String,
        subtitle: String?,
        width: CGFloat = 340,
        near owner: NSWindow?,
        @ViewBuilder content: () -> some View
    ) {
        dismiss()

        let panel = DialogPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the shelves it was raised from, or it opens behind them.
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The height comes from the laid-out content rather than a guess:
        // `fittingSize` on an unconstrained hosting view answers for whatever
        // width SwiftUI picked, which is not the width the window will have.
        // Reading it back also handles rows that come and go — the pixel field,
        // the quality slider — without a second size to keep in step.
        let hosting = NSHostingView(rootView: AnyView(
            ShelfDialogChrome(title: title, subtitle: subtitle, content: content) { [weak self] in
                self?.apply(height: $0, to: panel, near: owner)
            }
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        installEscapeMonitor()
    }

    /// First report positions and shows the window; later ones resize it from
    /// the top edge, so the dialog does not walk up the screen as rows appear.
    private func apply(height: CGFloat, to panel: NSPanel, near owner: NSWindow?) {
        guard self.panel === panel, height > 1 else { return }
        guard hasSized else {
            hasSized = true
            let size = NSSize(width: panel.frame.width, height: height)
            panel.setFrame(Self.centred(size, near: owner), display: false)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    func dismiss() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        hasSized = false
    }

    /// Esc closes it, as it closes every other transient surface in the app.
    /// The monitor is local only: the dialog is key while it is up, so a global
    /// one would be claiming a key it has no business seeing.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil, event.keyCode == 53 else { return event }
            self.dismiss()
            return nil
        }
    }

    /// Centred over the shelf that raised it where there is one, else on the
    /// screen the pointer is on — never on whichever screen AppKit felt like.
    private static func centred(_ size: NSSize, near owner: NSWindow?) -> NSRect {
        let reference = owner?.frame
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = NSRect(
            x: reference.midX - size.width / 2,
            y: reference.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let visible = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?
            .visibleFrame ?? frame
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - size.width - 8)
        frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - size.height - 8)
        return frame
    }
}

/// Borderless windows are not key by default, and everything in here needs
/// typing or a focus ring.
private final class DialogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Title, subtitle and the glass surface, so each dialog only supplies its rows.
private struct ShelfDialogChrome<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
    }
}
