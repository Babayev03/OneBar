import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ShelfModel {
    var items: [ShelfItem] = []
    var selection: Set<UUID> = []
    var isDropTargeted = false
    var isPresented = false

    var totalSize: Int { items.compactMap(\.byteSize).reduce(0, +) }
}

/// One shelf: its panel, its placement, and the two halves of drag and drop.
@MainActor
final class ShelfController {
    let id = UUID()
    let model = ShelfModel()

    static let width: CGFloat = 300
    private static let columns = 3
    private static let cellHeight: CGFloat = 84
    private static let cellSpacing: CGFloat = 8
    private static let headerHeight: CGFloat = 38
    private static let footerHeight: CGFloat = 26
    private static let maximumHeight: CGFloat = 440

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var draggedOut: [ShelfItem] = []

    init(at point: NSPoint?) {
        let panel = ShelfPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.headerHeight + 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let drop = ShelfDropView(frame: panel.contentLayoutRect)
        drop.controller = self
        drop.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: ShelfView(controller: self))
        hosting.frame = drop.bounds
        hosting.autoresizingMask = [.width, .height]
        drop.addSubview(hosting)

        panel.contentView = drop
        self.panel = panel

        position(near: point)
        // Ordered front rather than made key: the shelf appears in the middle
        // of a drag out of another app, and taking focus there would end it.
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            model.isPresented = true
        }
        installKeyMonitor()
    }

    // MARK: - Keyboard

    /// Every shelf installs one, and each guards on being the key window, so
    /// only the shelf you last clicked responds. A borderless non-activating
    /// panel becomes key on click without activating the app.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53:                                  // Esc
            close()
            return true
        case 51, 117:                             // Delete, forward delete
            guard !model.selection.isEmpty else { return false }
            remove(model.selection)
            return true
        case 0 where command:                     // ⌘A
            model.selection = Set(model.items.map(\.id))
            return true
        default:
            return false
        }
    }

    // MARK: - Contents

    func add(_ incoming: [ShelfItem]) {
        guard !incoming.isEmpty else { return }
        var added = false
        for item in incoming where !contains(item) {
            model.items.append(item)
            added = true
        }
        guard added else {
            HUD.show("Already on the shelf", symbol: "tray.full")
            return
        }
        resize()
    }

    private func contains(_ item: ShelfItem) -> Bool {
        model.items.contains { existing in
            switch item.kind {
            case .file, .image:
                return existing.path != nil && existing.path == item.path
            case .link:
                return existing.linkString == item.linkString
            case .text:
                return existing.kind == .text && existing.text == item.text
            }
        }
    }

    func remove(_ ids: Set<UUID>, deletingFiles: Bool = true) {
        let going = model.items.filter { ids.contains($0.id) }
        guard !going.isEmpty else { return }
        model.items.removeAll { ids.contains($0.id) }
        model.selection.subtract(ids)
        ShelfThumbnails.shared.forget(going)
        if deletingFiles { ShelfStore.shared.discard(going) }
        resize()
    }

    func clear() {
        remove(Set(model.items.map(\.id)))
    }

    func close() {
        ShelfManager.shared.close(self)
    }

    /// Called by the manager, which owns the lifetime.
    func tearDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        ShelfThumbnails.shared.forget(model.items)
        ShelfStore.shared.discard(model.items)
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    // MARK: - Drag out

    func dragItems(startingFrom id: UUID) -> [ShelfItem] {
        if model.selection.contains(id), model.selection.count > 1 {
            return model.items.filter { model.selection.contains($0.id) }
        }
        return model.items.filter { $0.id == id }
    }

    func pasteboardWriter(for item: ShelfItem) -> NSPasteboardWriting? {
        switch item.kind {
        case .file, .image:
            guard let url = item.resolveURL() else { return nil }
            return url as NSURL

        case .text:
            let pasteboardItem = NSPasteboardItem()
            // String first: whichever destination is under the cursor takes the
            // first type it understands, and a text view should receive the
            // text rather than open the file we happen to have written for it.
            if let text = item.text { pasteboardItem.setString(text, forType: .string) }
            if let rtf = item.rtfData { pasteboardItem.setData(rtf, forType: .rtf) }
            if let url = item.resolveURL() {
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
            }
            return pasteboardItem

        case .link:
            guard let link = item.linkString else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(link, forType: .URL)
            pasteboardItem.setString(link, forType: .string)
            return pasteboardItem
        }
    }

    func willBeginDragOut(_ items: [ShelfItem]) {
        draggedOut = items
        ShelfManager.shared.isDraggingOut = true
    }

    func didEndDragOut(operation: NSDragOperation) {
        ShelfManager.shared.isDraggingOut = false
        let items = draggedOut
        draggedOut = []
        guard !items.isEmpty else { return }

        let moved = operation.contains(.move)
        let dropped = !operation.isEmpty

        if moved {
            // The destination has taken the file; our path now points at
            // nothing. Deleting on top of that would only fail, and would be
            // wrong if it somehow succeeded.
            remove(Set(items.map(\.id)), deletingFiles: false)
        }

        switch AppState.shared.shelfCloseBehavior {
        case .always: if dropped { close() }
        case .whenMoved: if moved { close() }
        case .never: break
        }
    }

    // MARK: - Geometry

    /// The panel grows downward from a fixed top edge, so items appearing never
    /// shift the header out from under the cursor that is dropping them.
    private func resize() {
        guard let panel else { return }
        let height = desiredHeight()
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(clampedToScreen(frame), display: true)
    }

    private func desiredHeight() -> CGFloat {
        guard !model.items.isEmpty else { return Self.headerHeight + 92 }
        let rows = (model.items.count + Self.columns - 1) / Self.columns
        let grid = CGFloat(rows) * Self.cellHeight
            + CGFloat(max(0, rows - 1)) * Self.cellSpacing
            + 20
        return min(Self.headerHeight + Self.footerHeight + grid, Self.maximumHeight)
    }

    private func position(near point: NSPoint?) {
        guard let panel else { return }
        let size = panel.frame.size
        let cursor = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame

        let origin: NSPoint
        let location = point == nil ? AppState.shared.shelfLocation : .cursor
        switch location {
        case .cursor:
            origin = NSPoint(x: cursor.x - size.width / 2, y: cursor.y - size.height / 2)
        case .topLeft:
            origin = NSPoint(x: visible.minX + 20, y: visible.maxY - size.height - 20)
        case .topRight:
            origin = NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20)
        case .bottomLeft:
            origin = NSPoint(x: visible.minX + 20, y: visible.minY + 20)
        case .bottomRight:
            origin = NSPoint(x: visible.maxX - size.width - 20, y: visible.minY + 20)
        case .center:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        panel.setFrame(clampedToScreen(NSRect(origin: origin, size: size)), display: false)
    }

    private func clampedToScreen(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let screen else { return frame }
        let visible = screen.visibleFrame
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
        return frame
    }
}

/// Borderless panels refuse key status, and the shelf needs it for the rename
/// field and the keyboard actions that come with it.
private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

