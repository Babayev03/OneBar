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
    /// The item whose name is being edited in place, if any.
    var renamingItemID: UUID?
    /// Set while an action that writes a file is running, so the footer can say
    /// so. One at a time per shelf — a second zip started over the first would
    /// race for the same output name.
    var activity: String?
    var name: String?
    var colorName: String?
    var colorSource: ShelfColorSource = .automatic
    var isPinned = false
    var layout: ShelfLayout = .grid
    var keepInSpace = false

    var collapse: ShelfCollapse?
    var collapseEdge: ShelfEdge?
    var isPeeking = false
    var hasAutoRetracted = false

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
    private weak var dropView: ShelfDropView?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var moveMouseUpMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private var screenObservers: [NSObjectProtocol] = []
    private var positionPersistTask: Task<Void, Never>?
    private var previewObserver: NSObjectProtocol?
    private var previewIndexObservation: NSKeyValueObservation?
    private var previouslyFocusedApplication: NSRunningApplication?
    private var shelfWasKeyBeforePreview = false
    private var hoverMonitors: [Any] = []
    private var collapseVisibleFrame: NSRect?
    private var collapseStackDepth = 0
    private var peekTask: Task<Void, Never>?
    private var expansionTask: Task<Void, Never>?
    private var frameAnimationTask: Task<Void, Never>?
    private var autoRetractTask: Task<Void, Never>?
    private var dockHandleLabelPanel: NSPanel?
    private var draggedOut: [ShelfItem] = []
    private var internalTransfer: (operation: ShelfTransferOperation, itemIDs: Set<UUID>)?
    private var userMoveCandidate = false
    private var isUserMoving = false
    private var snapSuppressedForMove = false
    private var needsScreenReclamp = false
    private var activityTask: Task<Void, Never>?

    private static let dockAnimationDuration = 0.22

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
            model.keepInSpace = AppState.shared.shelfKeepInSpace
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
        panel.collectionBehavior = ShelfWindowGeometry.collectionBehavior(
            keepInCurrentSpace: model.keepInSpace
        )
        panel.acceptsMouseMovedEvents = true

        let drop = ShelfDropView(frame: panel.contentLayoutRect)
        drop.controller = self
        drop.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: ShelfView(controller: self))
        hosting.frame = drop.bounds
        hosting.autoresizingMask = [.width, .height]
        drop.addSubview(hosting)

        panel.contentView = drop
        self.panel = panel
        self.dropView = drop

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
        installClickMonitor()
        observePosition(of: panel)
        observeScreenChanges(of: panel)
        applyCollectionBehavior()
    }

    // MARK: - Keyboard

    /// Observes shelf clicks without claiming the header from AppKit's window
    /// dragging. A click on a collapsed tab is consumed so it cannot expand the
    /// shelf and also activate a control that moved underneath the pointer.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]
        ) {
            [weak self] event in
            guard let self else { return event }

            // A right-click is an interaction like any other, so it commits a
            // peek. Without this the menu opens and the hover watch — which
            // sees the pointer move onto the menu, outside the shelf — slides
            // the shelf back under it. Committing keeps the peeked frame
            // exactly where it is, so nothing moves out from under the menu.
            if event.type == .rightMouseDown {
                if let panel = self.panel, event.window === panel {
                    self.cancelFrameAnimation()
                    self.commitPeekForInteraction()
                }
                return event
            }

            if event.type == .leftMouseUp {
                if self.userMoveCandidate || self.isUserMoving {
                    self.finishUserMove(modifiers: event.modifierFlags)
                }
                return event
            }

            guard let panel = self.panel, event.window === panel else { return event }
            self.commitRenameIfEditing(clickedAt: event.locationInWindow)
            // A real grab always wins over a peek, retract, dock, or snap
            // animation. Cancelling here prevents an old target from pulling
            // the shelf away after AppKit starts the user's window drag.
            self.cancelFrameAnimation()
            let headerBottom = panel.contentLayoutRect.height - Self.headerHeight
            if self.model.collapse != nil {
                if self.model.isPeeking {
                    // During a moving-window animation AppKit can report this
                    // event against the destination frame rather than the
                    // currently drawn frame, so a header-coordinate check is
                    // unreliable. Any click on a revealed shelf commits it;
                    // a header click then continues into the ordinary window
                    // drag, while an item click remains an item click.
                    self.commitPeekForInteraction()
                } else {
                    self.cancelUserMoveTracking()
                    self.expand()
                    return nil
                }
            }

            if event.clickCount == 2, event.locationInWindow.y >= headerBottom {
                self.cancelUserMoveTracking()
                self.performDoubleClickAction()
                return nil
            }

            self.userMoveCandidate = true
            self.isUserMoving = false
            self.snapSuppressedForMove = event.modifierFlags.contains(.command)
            return event
        }
    }

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
            // While a name is being edited Esc belongs to the field editor,
            // which cancels the rename. This monitor sees the key first, so it
            // has to decline it rather than close the shelf out from under it.
            if model.renamingItemID != nil { return false }
            if model.route == .customize { showItems() }
            else if model.collapse != nil { expand() }
            else { close() }
            return true
        }
        // The field editor must keep ordinary typing and its own edit commands.
        if panel?.firstResponder is NSTextView { return false }

        if handleSelectionArrow(event) { return true }

        let store = ShortcutStore.shared
        func matches(_ action: ShortcutAction) -> Bool {
            store.binding(for: action).matches(event)
        }

        if matches(.shelfCloseAll) { ShelfManager.shared.closeAll(); return true }
        if matches(.shelfClose) { close(); return true }
        if matches(.shelfCustomize) { showCustomize(); return true }
        if matches(.shelfDockLeft) { dock(to: .left); return true }
        if matches(.shelfDockRight) { dock(to: .right); return true }
        if matches(.shelfDock) { toggleDock(); return true }
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
        if matches(.shelfOpen) {
            ShelfActionRunner.perform(.open, scope: .selection, in: self)
            return true
        }
        if matches(.shelfShowInFinder) {
            ShelfActionRunner.perform(.showInFinder, scope: .selection, in: self)
            return true
        }
        if matches(.shelfRename) {
            ShelfActionRunner.perform(.rename, scope: .selection, in: self)
            return true
        }
        if matches(.shelfCommandBar) {
            ShelfActionRunner.showCommandBar(in: self)
            return true
        }
        if matches(.shelfGetInfo) {
            ShelfActionRunner.perform(.getInfo, scope: .selection, in: self)
            return true
        }
        return false
    }

    // MARK: - Clipboard and Quick Look

    private func handleSelectionArrow(_ event: NSEvent) -> Bool {
        let disallowed = event.modifierFlags.intersection([.command, .option, .control])
        guard disallowed.isEmpty else { return false }
        let direction: ShelfSelectionLogic.Direction
        switch event.keyCode {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: return false
        }
        ShelfSelectionLogic.move(
            direction: direction,
            orderedIDs: model.items.map(\.id),
            columnCount: model.layout == .grid ? Self.columns : 1,
            extending: event.modifierFlags.contains(.shift),
            selection: &model.selection,
            anchor: &model.selectionAnchor
        )
        return true
    }

    var actionItems: [ShelfItem] {
        model.selection.isEmpty
            ? model.items
            : model.items.filter { model.selection.contains($0.id) }
    }

    /// Something on screen for a popover-style sheet to hang off.
    var anchorView: NSView? { dropView }

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
        shelfWasKeyBeforePreview = panel.isKeyWindow
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let preview = QLPreviewPanel.shared(), let dropView else {
            restorePreviousApplication()
            return
        }
        // Do not rely on the responder-chain hand-off alone. A click in the
        // AppKit drag surface can leave Quick Look with its previous empty data
        // source, which displays “No Items Selected” even though the shelf has
        // a valid selection. Install the current shelf explicitly and reload it
        // before presenting the shared panel.
        preview.dataSource = dropView
        preview.delegate = dropView
        preview.reloadData()
        preview.currentPreviewItemIndex = previewSelectionIndex
        previewIndexObservation?.invalidate()
        previewIndexObservation = preview.observe(
            \.currentPreviewItemIndex,
            options: [.new]
        ) { [weak self] preview, _ in
            let index = preview.currentPreviewItemIndex
            Task { @MainActor [weak self] in
                self?.selectPreviewItem(at: index)
            }
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

    private var previewItems: [ShelfItem] {
        let previewable = model.items.filter { $0.resolveURL() != nil }
        guard previewable.contains(where: { model.selection.contains($0.id) }) else { return [] }
        return previewable
    }

    var previewURLs: [URL] { previewItems.compactMap { $0.resolveURL() } }

    var previewSelectionIndex: Int {
        max(0, previewItems.firstIndex(where: { model.selection.contains($0.id) }) ?? 0)
    }

    private func selectPreviewItem(at index: Int) {
        let items = previewItems
        guard items.indices.contains(index) else { return }
        let itemID = items[index].id
        model.selection = [itemID]
        model.selectionAnchor = itemID
    }

    /// Quick Look calls this when the shelf gives up preview-panel control.
    /// It is the reliable close path; the window observer above remains a
    /// fallback for OS versions that only hide the shared panel.
    func previewDidEnd() {
        stopPreviewObservation(restoreFocus: true)
    }

    private func stopPreviewObservation(restoreFocus: Bool) {
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
        previewObserver = nil
        previewIndexObservation?.invalidate()
        previewIndexObservation = nil
        if restoreFocus { restorePreviousApplication() }
        else { previouslyFocusedApplication = nil }
    }

    private func restorePreviousApplication() {
        let application = previouslyFocusedApplication
        previouslyFocusedApplication = nil
        let shouldRestoreShelfKey = shelfWasKeyBeforePreview
        shelfWasKeyBeforePreview = false
        if let application, application != NSRunningApplication.current {
            application.activate(options: [])
        }
        guard shouldRestoreShelfKey else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, self.isActive, let panel = self.panel, panel.isVisible else { return }
            // The shelf is a non-activating panel, so it can receive the next
            // Space/arrow key while the user's original application remains
            // frontmost, exactly as it did before Quick Look opened.
            panel.makeKey()
        }
    }

    // MARK: - Contents

    @discardableResult
    func add(_ incoming: [ShelfItem], discardRejected: Bool = true) -> [ShelfItem] {
        guard isActive, !incoming.isEmpty else {
            if discardRejected { ShelfStore.shared.discard(incoming) }
            return []
        }
        let wasEmpty = model.items.isEmpty
        let resolution = ShelfTransferLogic.resolve(incoming: incoming, existing: model.items)
        let accepted = resolution.accepted
        let rejected = resolution.rejected
        model.items.append(contentsOf: accepted)
        if discardRejected {
            ShelfStore.shared.discard(rejected, keeping: model.items)
        }
        guard !accepted.isEmpty else {
            HUD.show("Already on the shelf", symbol: "tray.full")
            return []
        }
        model.route = .items
        resize()
        persistIfPinned()

        if AppState.shared.shelfAutoRetract,
           wasEmpty,
           !model.hasAutoRetracted,
           model.collapse == nil {
            model.hasAutoRetracted = true
            autoRetractTask?.cancel()
            autoRetractTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, self.isActive, self.model.collapse == nil else { return }
                self.retract()
            }
        }
        return accepted
    }

    func canAccept(_ incoming: [ShelfItem]) -> Bool {
        isActive && !ShelfTransferLogic.resolve(
            incoming: incoming,
            existing: model.items
        ).accepted.isEmpty
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

    // MARK: - Renaming

    /// Turns the item's label into a field. Editing needs focus, which the
    /// shelf otherwise never takes — the same trade Customize makes.
    func beginRename(_ id: UUID) {
        guard isActive,
              let item = model.items.first(where: { $0.id == id }),
              item.resolveURL() != nil
        else { return }
        model.selection = [id]
        model.selectionAnchor = id
        model.renamingItemID = id
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancelRename() {
        model.renamingItemID = nil
    }

    /// A click anywhere but the field itself keeps what was typed, as it does
    /// in Finder. Resigning first responder is what commits it.
    private func commitRenameIfEditing(clickedAt point: NSPoint) {
        guard model.renamingItemID != nil, let panel, let content = panel.contentView else { return }
        let hit = content.hitTest(content.convert(point, from: nil))
        guard !(hit is NSTextView || hit is NSTextField) else { return }
        panel.makeFirstResponder(nil)
    }

    func commitRename(_ id: UUID, to entered: String) {
        model.renamingItemID = nil
        guard let item = model.items.first(where: { $0.id == id }),
              let url = item.resolveURL()
        else { return }

        let name = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        // A slash is a path separator, not a character: the rename would land
        // somewhere else entirely. A leading dot hides the file from Finder.
        guard !name.contains("/"), !name.hasPrefix(".") else {
            HUD.show("That name is not allowed", symbol: "exclamationmark.triangle")
            return
        }

        // Renaming inside the same folder is what keeps a materialised file a
        // child of OneBar's own directory, and so still owned by the store.
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            HUD.show(
                FileManager.default.fileExists(atPath: destination.path)
                    ? "A file with that name already exists"
                    : "Could not rename",
                symbol: "exclamationmark.triangle"
            )
            return
        }
        relocate(id, to: destination)
    }

    /// Points an item at the file it just became. The bookmark is rewritten too:
    /// the old one still resolves through the rename, but only until the file
    /// moves again, and a stale bookmark is the thing it exists to avoid.
    func relocate(_ id: UUID, to url: URL) {
        guard let index = model.items.firstIndex(where: { $0.id == id }) else { return }
        var item = model.items[index]
        item.path = url.path
        item.bookmark = try? url.bookmarkData()
        item.title = url.lastPathComponent
        item.byteSize = ShelfStore.shared.fileSize(of: url)
        ShelfThumbnails.shared.forget([item])
        model.items[index] = item
        persistIfPinned()
    }

    func close() {
        ShelfManager.shared.close(self)
    }

    /// Called by the manager, which owns the lifetime — and which decides
    /// whether the items are kept, so nothing is deleted here.
    func tearDown() {
        isActive = false
        activityTask?.cancel()
        activityTask = nil
        autoRetractTask?.cancel()
        autoRetractTask = nil
        peekTask?.cancel()
        peekTask = nil
        expansionTask?.cancel()
        expansionTask = nil
        cancelFrameAnimation()
        hideDockHandleLabel(animated: false)
        positionPersistTask?.cancel()
        positionPersistTask = nil
        cancelUserMoveTracking()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        stopHoverWatch()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        for observer in screenObservers { NotificationCenter.default.removeObserver(observer) }
        screenObservers.removeAll()
        stopPreviewObservation(restoreFocus: false)
        ShelfThumbnails.shared.forget(model.items)
        panel?.orderOut(nil)
        panel?.contentView = nil
        dropView = nil
        panel = nil
    }

    func snapshot() -> ShelfSnapshot {
        let persistedFrame = frameForPersistence
        return ShelfSnapshot(
            id: id,
            name: model.name,
            colorName: model.colorName,
            colorSource: model.colorSource,
            items: model.items,
            originX: persistedFrame.map { Double($0.origin.x) },
            originY: persistedFrame.map { Double($0.origin.y) },
            isPinned: model.isPinned,
            layout: model.layout,
            keepInSpace: model.keepInSpace,
            closedAt: nil
        )
    }

    private var frameForPersistence: NSRect? {
        guard let panel else { return nil }
        guard let edge = model.collapseEdge,
              let visible = collapseDisplayFrame(fallback: panel.frame)
        else {
            return panel.frame
        }
        return ShelfWindowGeometry.rested(panel.frame, edge: edge, in: visible)
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
        applyCollectionBehavior()
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

    // MARK: - Long-running actions

    enum ActivityStart {
        case started
        case busy
        /// The shelf this was asked of has since closed.
        case gone
    }

    /// One at a time, since two runs would race for the same output name.
    func beginActivity(_ label: String) -> ActivityStart {
        guard isActive else { return .gone }
        guard model.activity == nil else { return .busy }
        model.activity = label
        return .started
    }

    /// Held so a run that never finishes can still be got rid of — a flag with
    /// no way out would lock every later action on this shelf out for good.
    func registerActivity(_ task: Task<Void, Never>) {
        activityTask = task
    }

    func endActivity() {
        model.activity = nil
        activityTask = nil
    }

    func cancelActivity() {
        activityTask?.cancel()
        activityTask = nil
        model.activity = nil
        HUD.show("Stopped", symbol: "stop.circle")
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
            MainActor.assumeIsolated { self?.windowDidMove() }
        }
    }

    private func windowDidMove() {
        schedulePositionPersistence()

        guard userMoveCandidate, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        snapSuppressedForMove = snapSuppressedForMove || NSEvent.modifierFlags.contains(.command)
        guard !isUserMoving else { return }
        isUserMoving = true

        moveMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) {
            [weak self] event in
            Task { @MainActor in self?.finishUserMove(modifiers: event.modifierFlags) }
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

    private func finishUserMove(modifiers: NSEvent.ModifierFlags) {
        let shouldSnap = ShelfWindowGeometry.shouldSnap(
            isRealUserMove: isUserMoving,
            enabled: AppState.shared.shelfSnap,
            isCollapsed: model.collapse != nil,
            commandSuppressed: snapSuppressedForMove || modifiers.contains(.command)
        )
        let shouldReclamp = needsScreenReclamp
        needsScreenReclamp = false
        cancelUserMoveTracking()
        if shouldSnap { snapIntoPlace() }
        else if shouldReclamp { reclampForScreens() }
    }

    private func cancelUserMoveTracking() {
        if let moveMouseUpMonitor { NSEvent.removeMonitor(moveMouseUpMonitor) }
        moveMouseUpMonitor = nil
        userMoveCandidate = false
        isUserMoving = false
        snapSuppressedForMove = false
    }

    private func observeScreenChanges(of panel: NSPanel) {
        screenObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenChange() }
        })
        screenObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      !self.isUserMoving,
                      !self.userMoveCandidate,
                      NSEvent.pressedMouseButtons & 1 == 0
                else { return }
                self.reclampForScreens()
            }
        })
    }

    private func handleScreenChange() {
        if isUserMoving || userMoveCandidate || NSEvent.pressedMouseButtons & 1 == 1 {
            needsScreenReclamp = true
        } else {
            reclampForScreens()
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
        cancelUserMoveTracking()
        draggedOut = items
        internalTransfer = nil
        ShelfManager.shared.isDraggingOut = true
    }

    func registerInternalTransfer(
        operation: ShelfTransferOperation,
        itemIDs: Set<UUID>
    ) {
        internalTransfer = (operation, itemIDs)
    }

    func didEndDragOut(operation: NSDragOperation) {
        cancelUserMoveTracking()
        ShelfManager.shared.isDraggingOut = false
        let items = draggedOut
        draggedOut = []
        let completedTransfer = internalTransfer
        internalTransfer = nil
        guard !items.isEmpty else { return }

        let moved = completedTransfer.map { $0.operation == .move }
            ?? operation.contains(.move)
        let dropped = completedTransfer != nil || !operation.isEmpty

        if moved {
            // The destination has taken the file; our path now points at
            // nothing. Deleting on top of that would only fail, and would be
            // wrong if it somehow succeeded.
            remove(completedTransfer?.itemIDs ?? Set(items.map(\.id)), deletingFiles: false)
        }

        guard ShelfTransferLogic.shouldApplyCloseBehavior(
            afterInternalTransfer: completedTransfer != nil,
            remainingItemCount: model.items.count
        ) else { return }

        switch AppState.shared.shelfCloseBehavior {
        case .always: if dropped { close() }
        case .whenMoved: if moved { close() }
        case .never: break
        }
    }

    // MARK: - Docking, retracting and peeking

    func dock(to edge: ShelfEdge? = nil) { collapse(.docked, to: edge) }
    func retract(to edge: ShelfEdge? = nil) { collapse(.retracted, to: edge) }

    func toggleDock(_ edge: ShelfEdge? = nil) {
        if model.collapse == .docked { expand() } else { dock(to: edge) }
    }

    private func collapse(_ mode: ShelfCollapse, to requestedEdge: ShelfEdge?) {
        guard let panel else { return }
        expansionTask?.cancel()
        expansionTask = nil
        cancelFrameAnimation()
        hideDockHandleLabel(animated: false)
        let display = model.collapse == nil
            ? visibleFrame(for: panel.frame)
            : collapseDisplayFrame(fallback: panel.frame)
        guard let visible = display else { return }
        autoRetractTask?.cancel()
        let edge = requestedEdge ?? nearestEdge(in: visible)
        let baseFrame: NSRect
        if let oldEdge = model.collapseEdge {
            baseFrame = ShelfWindowGeometry.rested(panel.frame, edge: oldEdge, in: visible)
        } else {
            baseFrame = panel.frame
        }

        model.collapse = mode
        model.collapseEdge = edge
        model.isPeeking = false
        collapseStackDepth = 0
        collapseVisibleFrame = visible
        model.selection.removeAll()
        model.selectionAnchor = nil
        panel.setFrame(baseFrame, display: true)
        if mode.revealsOnPointerHover {
            startHoverWatch()
        } else {
            stopHoverWatch()
        }
        ShelfManager.shared.restackCollapsedShelves(animated: true)
    }

    func expand() {
        guard let panel,
              model.collapse != nil,
              let edge = model.collapseEdge,
              let visible = collapseDisplayFrame(fallback: panel.frame)
        else { return }

        expansionTask?.cancel()
        peekTask?.cancel()
        stopHoverWatch()
        hideDockHandleLabel()
        let target = ShelfWindowGeometry.rested(panel.frame, edge: edge, in: visible)

        // Render the full shelf at its still-collapsed position first. Waiting
        // one run-loop turn gives SwiftUI time to replace the narrow handle,
        // so the shelf itself is visible while AppKit slides the window in.
        model.isPeeking = true
        expansionTask = Task { @MainActor [weak self, weak panel] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  let panel,
                  self.panel === panel,
                  self.model.collapse != nil,
                  self.model.isPeeking
            else { return }

            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            self.setFrame(target, animated: true)
            try? await Task.sleep(for: .seconds(Self.dockAnimationDuration))
            guard !Task.isCancelled,
                  self.model.collapse != nil,
                  self.model.isPeeking
            else { return }

            self.model.collapse = nil
            self.model.collapseEdge = nil
            self.model.isPeeking = false
            self.collapseStackDepth = 0
            self.collapseVisibleFrame = nil
            self.expansionTask = nil
            ShelfManager.shared.restackCollapsedShelves(animated: true)
        }
    }

    /// Temporarily reveals a retracted shelf for the pointer, or either kind
    /// of collapsed shelf while a drag is over its drop destination.
    func peek(_ peeking: Bool) {
        peekTask?.cancel()
        guard let panel,
              let mode = model.collapse,
              let edge = model.collapseEdge,
              model.isPeeking != peeking,
              let visible = collapseDisplayFrame(fallback: panel.frame)
        else { return }

        model.isPeeking = peeking
        let target = peeking
            ? ShelfWindowGeometry.peeked(
                panel.frame,
                mode: mode,
                edge: edge,
                in: visible,
                stackDepth: collapseStackDepth
            )
            : ShelfWindowGeometry.collapsed(
                panel.frame,
                mode: mode,
                edge: edge,
                in: visible,
                stackDepth: collapseStackDepth
            )
        setFrame(target, animated: true)
    }

    func peekAfterDelay(_ seconds: Double = 0.25) {
        peekTask?.cancel()
        guard model.collapse != nil, model.isPeeking else { return }
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.model.collapse == .docked {
                self.peek(false)
            } else {
                self.updatePeekForCursor()
            }
        }
    }

    /// Turns a temporary hover reveal into an ordinary shelf without starting
    /// another frame animation. This is what makes it possible to hover a
    /// docked shelf and drag its header in one continuous gesture.
    private func commitPeekForInteraction() {
        guard let panel, model.collapse != nil, model.isPeeking else { return }
        expansionTask?.cancel()
        expansionTask = nil
        peekTask?.cancel()
        stopHoverWatch()
        cancelFrameAnimation()

        // The frame is now the real visible frame because our cancellable
        // animator writes each intermediate position directly to the panel.
        panel.setFrame(panel.frame, display: true)
        model.collapse = nil
        model.collapseEdge = nil
        model.isPeeking = false
        collapseStackDepth = 0
        collapseVisibleFrame = nil
        schedulePositionPersistence()
        ShelfManager.shared.restackCollapsedShelves(animated: true)
    }

    /// A separate click-through panel avoids the oversized speech-bubble tail
    /// supplied by `NSPopover`, while still allowing the label to sit outside
    /// the mostly off-screen shelf window.
    func setDockHandleHovered(_ hovered: Bool) {
        guard hovered else {
            hideDockHandleLabel()
            return
        }
        guard dockHandleLabelPanel == nil,
              let panel,
              model.collapse == .docked,
              !model.isPeeking,
              let edge = model.collapseEdge,
              let visible = collapseDisplayFrame(fallback: panel.frame)
        else { return }

        let label = ShelfHandlePresentation.label(
            shelfName: model.name,
            itemTitles: model.items.map(\.title),
            fallback: model.title
        )
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let measuredWidth = (label as NSString).size(withAttributes: [.font: font]).width
        let maximumWidth = min(360, visible.width - 32)
        let labelWidth = min(maximumWidth, ceil(measuredWidth) + 39)
        let labelSize = NSSize(width: labelWidth, height: 34)
        let labelFrame = ShelfHandlePresentation.labelFrame(
            size: labelSize,
            shelfFrame: panel.frame,
            edge: edge,
            visibleFrame: visible
        )
        let labelPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: labelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        labelPanel.isOpaque = false
        labelPanel.backgroundColor = .clear
        labelPanel.hasShadow = true
        labelPanel.ignoresMouseEvents = true
        labelPanel.hidesOnDeactivate = false
        labelPanel.level = panel.level
        labelPanel.collectionBehavior = panel.collectionBehavior
        labelPanel.contentView = NSHostingView(rootView: ShelfHandleLabelView(
            color: model.color,
            label: label,
            size: labelSize
        ))
        labelPanel.setFrame(labelFrame, display: false)
        labelPanel.alphaValue = 0
        dockHandleLabelPanel = labelPanel
        panel.addChildWindow(labelPanel, ordered: .above)
        labelPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            labelPanel.animator().alphaValue = 1
        }
    }

    private func hideDockHandleLabel(animated: Bool = true) {
        guard let labelPanel = dockHandleLabelPanel else { return }
        dockHandleLabelPanel = nil
        panel?.removeChildWindow(labelPanel)
        guard animated else {
            labelPanel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            labelPanel.animator().alphaValue = 0
        } completionHandler: {
            labelPanel.orderOut(nil)
        }
    }

    private func startHoverWatch() {
        guard hoverMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged],
            handler: { [weak self] _ in
                Task { @MainActor in self?.updatePeekForCursor() }
            }
        ) {
            hoverMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged],
            handler: { [weak self] event in
                self?.updatePeekForCursor()
                return event
            }
        ) {
            hoverMonitors.append(local)
        }
    }

    private func stopHoverWatch() {
        for monitor in hoverMonitors { NSEvent.removeMonitor(monitor) }
        hoverMonitors.removeAll()
    }

    private func updatePeekForCursor() {
        guard let panel,
              let mode = model.collapse,
              let edge = model.collapseEdge,
              mode.revealsOnPointerHover
        else { return }
        let interactionFrame = model.isPeeking
            ? panel.frame
            : ShelfWindowGeometry.collapsedInteractionFrame(
                panel.frame,
                mode: mode,
                edge: edge,
                stackDepth: collapseStackDepth
            )
        let isInside = interactionFrame.insetBy(dx: -6, dy: -6)
            .contains(NSEvent.mouseLocation)
        peek(isInside)
    }

    func performDoubleClickAction() {
        switch AppState.shared.shelfDoubleClick {
        case .none: break
        case .dock: toggleDock()
        case .retract:
            if model.collapse == .retracted { expand() } else { retract() }
        }
    }

    func applyCollectionBehavior() {
        panel?.collectionBehavior = ShelfWindowGeometry.collectionBehavior(
            keepInCurrentSpace: model.keepInSpace
        )
    }

    private func snapIntoPlace() {
        guard let panel, model.collapse == nil, let visible = visibleFrame(for: panel.frame) else { return }
        let others = ShelfManager.shared.shelves
            .filter { $0 !== self }
            .compactMap(\.frameOnScreen)
        let target = ShelfWindowGeometry.snapped(panel.frame, to: visible, otherFrames: others)
        guard target != panel.frame else { return }
        setFrame(target, animated: true)
    }

    var frameOnScreen: NSRect? { panel?.frame }

    var collapseStackData: (edge: ShelfEdge, visible: NSRect, frame: NSRect)? {
        guard model.collapse != nil,
              let edge = model.collapseEdge,
              let visible = collapseVisibleFrame,
              let frame = panel?.frame
        else { return nil }
        return (edge, visible, frame)
    }

    func applyCollapseStackDepth(_ depth: Int, animated: Bool) {
        collapseStackDepth = max(0, depth)
        guard let panel,
              !model.isPeeking,
              let mode = model.collapse,
              let edge = model.collapseEdge,
              let visible = collapseDisplayFrame(fallback: panel.frame)
        else { return }
        setFrame(
            ShelfWindowGeometry.collapsed(
                panel.frame,
                mode: mode,
                edge: edge,
                in: visible,
                stackDepth: collapseStackDepth
            ),
            animated: animated
        )
    }

    func reclampForScreens() {
        guard let panel else { return }
        let screenReference = model.collapse == nil ? panel.frame : (collapseVisibleFrame ?? panel.frame)
        guard let visible = ShelfWindowGeometry.targetVisibleFrame(
                for: screenReference,
                visibleFrames: NSScreen.screens.map(\.visibleFrame),
                cursor: NSEvent.mouseLocation
              )
        else { return }

        var target = ShelfWindowGeometry.clamped(panel.frame, to: visible)
        if let mode = model.collapse, let edge = model.collapseEdge {
            collapseVisibleFrame = visible
            target = model.isPeeking
                ? ShelfWindowGeometry.peeked(
                    target,
                    mode: mode,
                    edge: edge,
                    in: visible,
                    stackDepth: collapseStackDepth
                )
                : ShelfWindowGeometry.collapsed(
                    target,
                    mode: mode,
                    edge: edge,
                    in: visible,
                    stackDepth: collapseStackDepth
                )
        }
        setFrame(target, animated: false)
    }

    private func collapseDisplayFrame(fallback frame: NSRect) -> NSRect? {
        ShelfWindowGeometry.targetVisibleFrame(
            for: collapseVisibleFrame ?? frame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            cursor: NSEvent.mouseLocation
        )
    }

    private func nearestEdge(in visible: NSRect) -> ShelfEdge {
        guard let panel else { return .right }
        return panel.frame.midX < visible.midX ? .left : .right
    }

    private func setFrame(_ frame: NSRect, animated: Bool) {
        guard let panel else { return }
        cancelUserMoveTracking()
        cancelFrameAnimation()
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        let start = panel.frame
        guard start != frame else { return }
        let steps = max(1, Int(ceil(Self.dockAnimationDuration * 60)))
        let stepDuration = Self.dockAnimationDuration / Double(steps)
        frameAnimationTask = Task { @MainActor [weak self, weak panel] in
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(stepDuration))
                guard !Task.isCancelled, let self, let panel, self.panel === panel else { return }
                let progress = CGFloat(step) / CGFloat(steps)
                let remaining = 1 - progress
                let eased = 1 - remaining * remaining * remaining
                panel.setFrame(NSRect(
                    x: start.origin.x + (frame.origin.x - start.origin.x) * eased,
                    y: start.origin.y + (frame.origin.y - start.origin.y) * eased,
                    width: start.width + (frame.width - start.width) * eased,
                    height: start.height + (frame.height - start.height) * eased
                ), display: true)
            }
            self?.frameAnimationTask = nil
        }
    }

    private func cancelFrameAnimation() {
        frameAnimationTask?.cancel()
        frameAnimationTask = nil
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
        if let mode = model.collapse,
           let edge = model.collapseEdge,
           !model.isPeeking,
           let visible = collapseDisplayFrame(fallback: frame) {
            setFrame(
                ShelfWindowGeometry.collapsed(
                    frame,
                    mode: mode,
                    edge: edge,
                    in: visible,
                    stackDepth: collapseStackDepth
                ),
                animated: false
            )
        } else {
            setFrame(clampedToScreen(frame), animated: false)
        }
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
        var frame = clampedToScreen(NSRect(origin: origin, size: size))
        if point == nil {
            frame = ShelfWindowGeometry.avoidingOverlap(
                frame,
                in: visible,
                occupiedFrames: ShelfManager.shared.shelves.compactMap(\.frameOnScreen)
            )
        }
        panel.setFrame(frame, display: false)
    }

    private func clampedToScreen(_ frame: NSRect) -> NSRect {
        guard let visible = visibleFrame(for: frame) else { return frame }
        return ShelfWindowGeometry.clamped(frame, to: visible)
    }

    private func visibleFrame(for frame: NSRect) -> NSRect? {
        ShelfWindowGeometry.targetVisibleFrame(
            for: frame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            cursor: NSEvent.mouseLocation
        )
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

private struct ShelfHandleLabelView: View {
    let color: Color
    let label: String
    let size: NSSize

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
