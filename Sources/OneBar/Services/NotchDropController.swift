import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class NotchDropModel {
    var isDragActive = false
    var isTargeted = false
    var housingDepth: CGFloat = 0
    var housingWidth: CGFloat = 0
}

/// A drag-only target occupying the physical notch. It is fed by the generic
/// drag observer, so it remains available when shake recognition is disabled
/// or the source application is ignored for shaking.
@MainActor
final class NotchDropController {
    static let shared = NotchDropController()

    let model = NotchDropModel()
    private var window: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var endPending = false

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAvailability() }
        }
    }

    func dragBegan() {
        endPending = false
        model.isDragActive = true
        refreshAvailability()
    }

    func dragEnded() {
        // Finder can temporarily make `pressedMouseButtons` read as zero while
        // its NSDraggingSession is still over our destination. The destination
        // callbacks own `isTargeted`, so a drag currently on the notch is not
        // over yet — hold the ending until they say it left.
        endPending = true
        if !model.isTargeted { finishEnd() }
    }

    fileprivate func setTargeted(_ targeted: Bool) {
        model.isTargeted = targeted
        if !targeted, endPending { finishEnd() }
    }

    private func finishEnd() {
        endPending = false
        model.isDragActive = false
    }

    /// Keep a transparent registered drop view over the physical black notch
    /// and the small activation strip below it whenever notch dropping is
    /// enabled. Finder chooses its drag destinations as a session begins, so
    /// creating the window after the pasteboard changes is too late even when
    /// the visual target appears in time.
    func refreshAvailability() {
        guard AppState.shared.shelfEnabled,
              AppState.shared.shelfNotchDrop,
              let rect = notchRect()
        else {
            destroyWindow()
            return
        }

        if let window {
            // Nothing to do unless the displays themselves moved. The window
            // deliberately keeps one frame for its whole life: re-framing or
            // re-ordering it mid-drag is what cost the glow its layer, and
            // AppKit can also drop destinations that change under a session.
            if window.frame != rect { window.setFrame(rect, display: true) }
            return
        }
        destroyWindow()

        let window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.canHide = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let dropView = NotchDropView(frame: NSRect(origin: .zero, size: rect.size))
        dropView.controller = self
        dropView.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: NotchDropTarget(model: model))
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        dropView.addSubview(hosting)

        window.contentView = dropView
        window.registerForDraggedTypes(ShelfDropView.acceptedTypes)
        window.delegate = dropView
        window.orderFrontRegardless()
        self.window = window
    }

    func stop() {
        endPending = false
        model.isDragActive = false
        destroyWindow()
    }

    private func destroyWindow() {
        model.isTargeted = false
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    fileprivate func receiveExternal(from sender: NSDraggingInfo) -> Bool {
        var targetShelf: ShelfController?
        ShelfItemReader.read(from: sender) { items in
            guard !items.isEmpty else { return }
            if targetShelf == nil {
                targetShelf = ShelfManager.shared.newShelf(at: nil, focus: .afterFirstDrop)
            }
            guard let targetShelf, targetShelf.isActive else {
                ShelfStore.shared.discard(items)
                return
            }
            targetShelf.add(items)
        }
        dragEnded()
        return true
    }

    fileprivate func receiveInternal(
        from source: ShelfDragSourceView,
        operation: ShelfTransferOperation
    ) -> Bool {
        guard let sourceController = source.controller,
              let targetShelf = ShelfManager.shared.newShelf(at: nil, focus: .afterFirstDrop)
        else { return false }

        let transferred = ShelfManager.shared.transfer(
            source.draggedItems,
            from: sourceController,
            to: targetShelf,
            operation: operation
        )
        if !transferred { ShelfManager.shared.close(targetShelf) }
        dragEnded()
        return transferred
    }

    /// Prefer the notched display under the pointer, then the main notched
    /// display. This updates safely when displays are connected or removed.
    private func notchRect() -> NSRect? {
        // One size for the whole life of the window. It used to shrink while
        // idle so it would not swallow clicks; `hitTest` does that job now
        // without ever moving the frame.
        let activationDepth = ShelfWindowGeometry.notchActivationDepth
        let notched = NSScreen.screens.compactMap { screen -> (NSScreen, NSRect)? in
            guard screen.safeAreaInsets.top > 0,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea
            else { return nil }
            guard let target = ShelfWindowGeometry.notchTargetRect(
                screenFrame: screen.frame,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryLeft: left,
                auxiliaryRight: right,
                activationDepth: activationDepth
            ) else { return nil }
            return (screen, target)
        }

        let selected = notched.first(where: { $0.0.frame.contains(NSEvent.mouseLocation) })
            ?? notched.first(where: { $0.0 === NSScreen.main })
            ?? notched.first
        guard let selected else { return nil }
        model.housingDepth = selected.0.safeAreaInsets.top
        if let left = selected.0.auxiliaryTopLeftArea,
           let right = selected.0.auxiliaryTopRightArea {
            model.housingWidth = right.minX - left.maxX
        }
        return selected.1
    }
}

private final class NotchDropView: NSView, NSWindowDelegate {
    weak var controller: NotchDropController?

    /// The window is permanently the full drag-target size so its frame never
    /// changes, which means it also permanently covers a strip of menu bar and
    /// desktop below the notch. Stay transparent to ordinary clicks there
    /// while no drag is in flight; AppKit re-hit-tests throughout a session,
    /// so the destination is live again as soon as one starts.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let controller,
              controller.model.isDragActive || controller.model.isTargeted
        else { return nil }
        return super.hitTest(point)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ShelfDropView.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = operation(for: sender)
        controller?.setTargeted(!operation.isEmpty)
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = operation(for: sender)
        controller?.setTargeted(!operation.isEmpty)
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // AppKit can issue an exit while Finder redraws its dragging image.
        // If the cursor is still inside this unchanged destination, keep the
        // targeted state rather than extinguishing a stationary highlight.
        if let sender {
            let point = convert(sender.draggingLocation, from: nil)
            if bounds.contains(point) { return }
        }
        controller?.setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.setTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !operation(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller else { return false }
        controller.setTargeted(false)
        if let source = sender.draggingSource as? ShelfDragSourceView {
            return controller.receiveInternal(from: source, operation: transferOperation())
        }
        return controller.receiveExternal(from: sender)
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        if let source = sender.draggingSource as? ShelfDragSourceView {
            guard !source.draggedItems.isEmpty else { return [] }
            return transferOperation().dragOperation
        }
        return .copy
    }

    private func transferOperation() -> ShelfTransferOperation {
        ShelfTransferLogic.currentOperation()
    }
}

private struct NotchDropTarget: View {
    let model: NotchDropModel

    var body: some View {
        let state = AppState.shared.shelfNotchHighlight.visualState(
            dragActive: model.isDragActive,
            targeted: model.isTargeted
        )
        let accent = AppState.shared.accentColor
        // Exactly the obscured housing, straight from NSScreen. Everything is
        // drawn on that rect and allowed to overflow it: the visible highlight
        // is precisely the part that overflows, since the housing hides the
        // rest. Nothing here is inset or estimated.
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: ShelfWindowGeometry.notchCornerRadius,
            bottomTrailingRadius: ShelfWindowGeometry.notchCornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )

        ZStack(alignment: .top) {
            // Ambient: the drag has begun but has not reached the notch. Just
            // a bloom, which reads as light spilling out from behind the
            // housing onto the menu bar and the desktop below it. The fill
            // itself is never seen — the housing covers it — so the shadow is
            // the whole effect. It is a shadow rather than a `blur` because a
            // blur is an offscreen filter pass that this window was observed
            // to drop mid-drag, extinguishing the glow in a single frame while
            // the unblurred rim kept drawing.
            shape
                .fill(accent)
                .frame(width: model.housingWidth, height: model.housingDepth)
                .shadow(color: accent, radius: ShelfWindowGeometry.notchBloomBlur)
                .opacity(state == .hidden ? 0 : 1)

            // Targeted: the same bloom gains a crisp rim centred on the notch
            // boundary. Only its outer half is visible, tracing the housing's
            // sides and bottom edge.
            shape
                .stroke(accent, lineWidth: ShelfWindowGeometry.notchRimWidth)
                .frame(width: model.housingWidth, height: model.housingDepth)
                .opacity(state == .targeted ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.18), value: state)
    }
}
