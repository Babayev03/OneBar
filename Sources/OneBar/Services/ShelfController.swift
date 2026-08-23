import AppKit
import Observation
import Quartz
import SwiftUI

enum ShelfRoute {
    case items
    case customize
}

@MainActor
@Observable
final class ShelfModel {
    var items: [ShelfItem] = []
    var selection: Set<UUID> = []
    var selectionAnchor: UUID?
    var isDropTargeted = false
    var isPresented = false

    var route: ShelfRoute = .items
    var name: String?
    var colorName: String?
    var colorSource: ShelfColorSource = .automatic
    var isPinned = false
    var layout: ShelfLayout = .grid
    var keepInSpace = false

    var totalSize: Int { items.compactMap(\.byteSize).reduce(0, +) }

    var selectedSize: Int {
        items.filter { selection.contains($0.id) }.compactMap(\.byteSize).reduce(0, +)
    }

    var color: Color { ShelfManager.color(named: colorName) }

    var title: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return "Shelf"
    }
}

/// One shelf: its panel, its placement, and the two halves of drag and drop.
@MainActor
final class ShelfController {
    let id: UUID
    let model = ShelfModel()
    private(set) var isActive = true

    static let width: CGFloat = 300
    private static let columns = 3
    static let cellHeight: CGFloat = 84
    private static let cellSpacing: CGFloat = 8
    static let rowHeight: CGFloat = 34
    private static let headerHeight: CGFloat = 38
    private static let footerHeight: CGFloat = 26
    private static let maximumHeight: CGFloat = 440

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private var positionPersistTask: Task<Void, Never>?
    private var previewObserver: NSObjectProtocol?
    private var previouslyFocusedApplication: NSRunningApplication?
    private var draggedOut: [ShelfItem] = []

    convenience init(at point: NSPoint?) {
        self.init(snapshot: nil, at: point)
    }

    convenience init(snapshot: ShelfSnapshot) {
        self.init(snapshot: snapshot, at: nil)
    }

    private init(snapshot: ShelfSnapshot?, at point: NSPoint?) {
        id = snapshot?.id ?? UUID()
        if let snapshot {
            model.items = snapshot.items
            model.name = snapshot.name
            model.colorName = snapshot.colorName
            model.colorSource = snapshot.colorSource
            model.isPinned = snapshot.isPinned
            model.layout = snapshot.layout
            model.keepInSpace = snapshot.keepInSpace
        } else {
            model.layout = AppState.shared.shelfLayout
        }

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

        panel.setContentSize(NSSize(width: Self.width, height: desiredHeight()))
        if let snapshot, let x = snapshot.originX, let y = snapshot.originY {
            panel.setFrame(clampedToScreen(NSRect(
                origin: NSPoint(x: x, y: y),
                size: panel.frame.size
            )), display: false)
        } else {
            position(near: point)
        }
        // Ordered front rather than made key: the shelf appears in the middle
        // of a drag out of another app, and taking focus there would end it.
        // The preference restores the old Dropover behaviour for anyone who
        // wants to type at it the moment it opens.
        if AppState.shared.shelfTakesFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            model.isPresented = true
        }
        installKeyMonitor()
        observePosition(of: panel)
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
        if event.keyCode == 53 {
            if model.route == .customize { showItems() } else { close() }
            return true
        }
        // The field editor must keep ordinary typing and its own edit commands.
        if panel?.firstResponder is NSTextView { return false }

        let store = ShortcutStore.shared
        func matches(_ action: ShortcutAction) -> Bool {
            store.binding(for: action).matches(event)
        }

        if matches(.shelfCloseAll) { ShelfManager.shared.closeAll(); return true }
        if matches(.shelfClose) { close(); return true }
        if matches(.shelfCustomize) { showCustomize(); return true }
        if matches(.shelfNewFromClipboard) { ShelfManager.shared.newShelfFromClipboard(); return true }
        if matches(.shelfSelectAll) {
            model.selection = Set(model.items.map(\.id))
            model.selectionAnchor = model.items.first?.id
            return true
        }
        if matches(.shelfClear) { clear(); return true }
        if matches(.shelfRemove) {
            guard !model.selection.isEmpty else { return false }
            remove(model.selection)
            return true
        }
        if matches(.shelfCopy) { copySelection(); return true }
        if matches(.shelfPaste) { addFromClipboard(); return true }
        if matches(.shelfQuickLook) { quickLook(); return true }
        return false
    }

    // MARK: - Clipboard and Quick Look

    private var actionItems: [ShelfItem] {
        model.selection.isEmpty
            ? model.items
            : model.items.filter { model.selection.contains($0.id) }
    }

    func copySelection() {
        let items = actionItems
        guard !items.isEmpty else { return }
        let writers = items.compactMap { pasteboardWriter(for: $0) }
        guard !writers.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)
        HUD.show(items.count == 1 ? "Copied" : "Copied \(items.count) items", symbol: "doc.on.doc")
    }

    func addFromClipboard() {
        ShelfItemReader.read(from: NSPasteboard.general) { [weak self] items in
            guard let self, self.isActive else {
                ShelfStore.shared.discard(items)
                return
            }
            if items.isEmpty {
                HUD.show("Nothing on the clipboard", symbol: "exclamationmark.circle")
            } else {
                self.add(items)
            }
        }
    }

    func quickLook() {
        guard !previewURLs.isEmpty, let panel else { return }
        if let preview = QLPreviewPanel.shared(), preview.isVisible {
            preview.orderOut(nil)
            stopPreviewObservation(restoreFocus: true)
            return
        }

        previouslyFocusedApplication = NSWorkspace.shared.frontmostApplication
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let preview = QLPreviewPanel.shared() else {
            restorePreviousApplication()
            return
        }
        previewObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: preview,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self, weak preview] in
                // Resigning key can also mean the user clicked another window
                // while keeping Quick Look open. Restore only after it hides.
                try? await Task.sleep(for: .milliseconds(50))
                guard preview?.isVisible != true else { return }
                self?.stopPreviewObservation(restoreFocus: true)
            }
        }
        preview.makeKeyAndOrderFront(nil)
    }

    var previewURLs: [URL] { actionItems.compactMap { $0.resolveURL() } }

    /// Quick Look calls this when the shelf gives up preview-panel control.
    /// It is the reliable close path; the window observer above remains a
    /// fallback for OS versions that only hide the shared panel.
    func previewDidEnd() {
        stopPreviewObservation(restoreFocus: true)
    }

    private func stopPreviewObservation(restoreFocus: Bool) {
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
        previewObserver = nil
        if restoreFocus { restorePreviousApplication() }
        else { previouslyFocusedApplication = nil }
    }

    private func restorePreviousApplication() {
        let application = previouslyFocusedApplication
        previouslyFocusedApplication = nil
        guard let application, application != NSRunningApplication.current else { return }
        application.activate(options: [])
    }

    // MARK: - Contents

    @discardableResult
    func add(_ incoming: [ShelfItem]) -> Bool {
        guard isActive, !incoming.isEmpty else {
            ShelfStore.shared.discard(incoming)
            return false
        }
        var added = false
        var rejected: [ShelfItem] = []
        for item in incoming {
            if contains(item) {
                rejected.append(item)
            } else {
                model.items.append(item)
                added = true
            }
        }
        ShelfStore.shared.discard(rejected, keeping: model.items)
        guard added else {
            HUD.show("Already on the shelf", symbol: "tray.full")
            return false
        }
        model.route = .items
        resize()
        persistIfPinned()
        return true
    }

    private func contains(_ item: ShelfItem) -> Bool {
        model.items.contains { item.hasSameShelfIdentity(as: $0) }
    }

    func remove(_ ids: Set<UUID>, deletingFiles: Bool = true) {
        let going = model.items.filter { ids.contains($0.id) }
        guard !going.isEmpty else { return }
        model.items.removeAll { ids.contains($0.id) }
        model.selection.subtract(ids)
        if let anchor = model.selectionAnchor, ids.contains(anchor) {
            model.selectionAnchor = model.selection.first
        }
        ShelfThumbnails.shared.forget(going)
        if deletingFiles { ShelfStore.shared.discard(going) }
        resize()
        persistIfPinned()
    }

    func clear() {
        remove(Set(model.items.map(\.id)))
    }

    func close() {
        ShelfManager.shared.close(self)
    }

    /// Called by the manager, which owns the lifetime — and which decides
    /// whether the items are kept, so nothing is deleted here.
    func tearDown() {
        isActive = false
        positionPersistTask?.cancel()
        positionPersistTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        stopPreviewObservation(restoreFocus: false)
        ShelfThumbnails.shared.forget(model.items)
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    func snapshot() -> ShelfSnapshot {
        ShelfSnapshot(
            id: id,
            name: model.name,
            colorName: model.colorName,
            colorSource: model.colorSource,
            items: model.items,
            originX: panel.map { Double($0.frame.origin.x) },
            originY: panel.map { Double($0.frame.origin.y) },
            isPinned: model.isPinned,
            layout: model.layout,
            keepInSpace: model.keepInSpace,
            closedAt: nil
        )
    }

    func togglePin() {
        model.isPinned.toggle()
        ShelfManager.shared.persist()
        HUD.show(model.isPinned ? "Shelf pinned" : "Shelf unpinned",
                 symbol: model.isPinned ? "pin.fill" : "pin.slash")
    }

    func setLayout(_ layout: ShelfLayout) {
        model.layout = layout
        resize()
        persistIfPinned()
    }

    func setName(_ name: String?) {
        model.name = name
        persistIfPinned()
    }

    func setColor(_ name: String, source: ShelfColorSource = .user) {
        model.colorName = name
        model.colorSource = source
        persistIfPinned()
    }

    func applyAutomaticColor(_ name: String?) {
        guard model.colorSource == .automatic else { return }
        model.colorName = name
        persistIfPinned()
    }

    func setKeepInSpace(_ keepInSpace: Bool) {
        model.keepInSpace = keepInSpace
        persistIfPinned()
    }

    private func persistIfPinned() {
        guard model.isPinned else { return }
        ShelfManager.shared.persist()
    }

    func showCustomize() {
        model.route = .customize
        resize()
        // Focus is needed for the name field, and only here: the shelf is
        // otherwise deliberately never made key.
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showItems() {
        model.route = .items
        resize()
    }

    /// Pulls the items from the last shelf that was closed into this one — the
    /// undo for closing a shelf you still needed.
    func restorePrevious() {
        guard let snapshot = ShelfManager.shared.mostRecentlyClosed else { return }
        ShelfManager.shared.forgetKeepingFiles(snapshot)
        add(snapshot.items)
    }

    // MARK: - Window persistence

    private func observePosition(of panel: NSPanel) {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePositionPersistence() }
        }
    }

    private func schedulePositionPersistence() {
        guard model.isPinned else { return }
        positionPersistTask?.cancel()
        positionPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.persistIfPinned()
        }
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
        if model.route == .customize { return Self.headerHeight + 216 }
        guard !model.items.isEmpty else {
            // The restore button only appears when there is something to
            // restore, and it needs the room.
            let restore: CGFloat = ShelfManager.shared.mostRecentlyClosed == nil ? 0 : 22
            return Self.headerHeight + 92 + restore
        }
        let content: CGFloat
        switch model.layout {
        case .grid:
            let rows = (model.items.count + Self.columns - 1) / Self.columns
            content = CGFloat(rows) * Self.cellHeight
                + CGFloat(max(0, rows - 1)) * Self.cellSpacing
                + 20
        case .list:
            let count = CGFloat(model.items.count)
            content = count * Self.rowHeight + max(0, count - 1) * 4 + 20
        }
        return min(Self.headerHeight + Self.footerHeight + content, Self.maximumHeight)
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
    /// Needed for the caret and focus ring in the Customize name field —
    /// the same reason `CanvasWindow` overrides it.
    override var canBecomeMain: Bool { true }
}
