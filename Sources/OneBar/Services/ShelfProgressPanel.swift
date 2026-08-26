import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ShelfProgressModel {
    var title = ""
    var detail: String?
    var completed = 0
    /// Zero means there is no honest fraction to show. `ditto` reports nothing
    /// about how far into an archive it is, and guessing from the output size
    /// would be a bar that lies for anything compressible.
    var total = 0
    var finished: String?

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}

/// A window of its own for a running action, rather than a line in the shelf.
///
/// Separate from `ShelfDialog` on purpose: that one is exclusive, so opening
/// ⌘K during a run would tear the progress down, and finishing a run would
/// close a dialog the user had opened since.
@MainActor
final class ShelfProgressPanel {
    static let shared = ShelfProgressPanel()

    let model = ShelfProgressModel()
    private var panel: NSPanel?
    private var onStop: (() -> Void)?
    private var closeTask: Task<Void, Never>?

    private init() {}

    func begin(title: String, near owner: NSWindow?, onStop: @escaping () -> Void) {
        closeTask?.cancel()
        self.onStop = onStop
        model.title = title
        model.detail = nil
        model.completed = 0
        model.total = 0
        model.finished = nil
        show(near: owner)
    }

    func report(completed: Int, total: Int, detail: String?) {
        guard model.finished == nil else { return }
        model.completed = completed
        model.total = total
        model.detail = detail
    }

    /// Holds the result on screen briefly so a fast action still says what it
    /// did, rather than flashing a window nobody could read.
    func finish(_ message: String) {
        guard panel != nil else { return }
        model.finished = message
        model.detail = nil
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        closeTask?.cancel()
        closeTask = nil
        onStop = nil
        panel?.orderOut(nil)
        panel = nil
    }

    fileprivate func stop() {
        onStop?()
        dismiss()
    }

    private func show(near owner: NSWindow?) {
        guard panel == nil else { return }
        let size = NSSize(width: 300, height: 92)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: ShelfProgressView(model: model, onStop: { [weak self] in
            self?.stop()
        }))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(Self.placement(size, near: owner), display: false)
        // Never made key: a progress window that steals the keyboard while you
        // carry on working would be worse than no window.
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Just under the shelf that started it, so it is obvious which one is
    /// working, falling back to the pointer's screen.
    private static func placement(_ size: NSSize, near owner: NSWindow?) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame: NSRect
        if let owner {
            frame = NSRect(
                x: owner.frame.midX - size.width / 2,
                y: owner.frame.minY - size.height - 10,
                width: size.width,
                height: size.height
            )
        } else {
            frame = NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - size.width - 8)
        frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - size.height - 8)
        return frame
    }
}

private struct ShelfProgressView: View {
    let model: ShelfProgressModel
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.finished == nil ? "gearshape.2" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(model.finished == nil ? Color.secondary : .green)
                Text(model.finished ?? model.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if model.finished == nil {
                    Button(action: onStop) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }
            }

            if let fraction = model.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else if model.finished == nil {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var caption: String {
        if model.finished != nil { return " " }
        if let detail = model.detail {
            guard model.total > 1 else { return detail }
            return "\(model.completed + 1) of \(model.total) — \(detail)"
        }
        return "Working…"
    }
}
