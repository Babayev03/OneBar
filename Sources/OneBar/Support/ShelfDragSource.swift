import AppKit
import SwiftUI

/// The drag-out half of a shelf cell.
///
/// An AppKit view rather than SwiftUI's `.draggable` because the whole point of
/// dragging off a shelf is the *operation*: SwiftUI hands over an
/// `NSItemProvider` and never says whether the destination moved or copied,
/// and it is that answer which decides whether the item stays on the shelf.
/// The view sits over the cell and so owns its clicks too, forwarding them back.
final class ShelfDragSourceView: NSView, NSDraggingSource {
    weak var controller: ShelfController?
    var itemID: UUID?
    var onSelect: ((NSEvent) -> Void)?
    var onClickRelease: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?
    private(set) var draggedItems: [ShelfItem] = []

    private var mouseDownPoint: NSPoint?
    private var beganDrag = false
    /// `NSMenuItem.target` is weak, so the menu's target has to be owned by
    /// something that outlives the menu.
    private var menuResponder: ShelfMenuResponder?

    /// The panel is movable by its background, and AppKit decides that from the
    /// view under the pointer before the view's own tracking runs — so without
    /// this, dragging an item just slides the whole shelf around. The header
    /// and the empty space around the grid still move it, which is where you
    /// would expect to grab a window anyway.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        beganDrag = false
        onSelect?(event)
        if ShelfSelectionLogic.shouldOpen(
            clickCount: event.clickCount,
            modifiers: event.modifierFlags
        ) {
            onDoubleClick?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = event.locationInWindow
        // A few points of slop, or selecting an item with a slightly unsteady
        // hand starts a drag nobody asked for.
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        mouseDownPoint = nil
        beganDrag = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !beganDrag { onClickRelease?(event) }
        mouseDownPoint = nil
        beganDrag = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller, let itemID else { return nil }
        // Finder's rule: a right-click outside the current selection acts on the
        // item under the pointer alone. Without it the menu would silently
        // apply to whatever happened to be selected somewhere else.
        if !controller.model.selection.contains(itemID) {
            controller.model.selection = [itemID]
            controller.model.selectionAnchor = itemID
        }
        let responder = ShelfMenuResponder(controller: controller, anchor: self)
        menuResponder = responder
        return ShelfActionMenu.menu(scope: .selection, controller: controller, target: responder)
    }

    private func beginDrag(with event: NSEvent) {
        guard let controller, let itemID else { return }
        let items = controller.dragItems(startingFrom: itemID)
        guard !items.isEmpty else { return }

        var draggingItems: [NSDraggingItem] = []
        var representedItems: [ShelfItem] = []
        for (index, item) in items.enumerated() {
            guard let writer = controller.pasteboardWriter(for: item) else { continue }
            let dragging = NSDraggingItem(pasteboardWriter: writer)
            // Fan a multi-item drag out slightly so it reads as a stack.
            let offset = CGFloat(index) * 5
            dragging.setDraggingFrame(
                bounds.offsetBy(dx: offset, dy: -offset),
                contents: ShelfThumbnails.shared.cached(for: item)
            )
            draggingItems.append(dragging)
            representedItems.append(item)
        }
        guard !draggingItems.isEmpty else { return }

        draggedItems = representedItems
        controller.willBeginDragOut(representedItems)
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            // Offering both is what buys native semantics for nothing: the
            // destination moves within a volume, copies across one, and copies
            // when ⌥ is held. Narrowing to `.copy` is the whole implementation
            // of the "always copy" preference.
            return AppState.shared.shelfAlwaysCopy ? .copy : [.copy, .move]
        case .withinApplication:
            // Shelf-to-shelf and shelf-to-notch use their own ownership-aware
            // transfer path. Move is the default; Option chooses copy.
            return [.copy, .move]
        @unknown default:
            return []
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        controller?.didEndDragOut(operation: operation)
        draggedItems = []
    }
}

/// Puts a `ShelfDragSourceView` over a SwiftUI cell.
struct ShelfDragSource: NSViewRepresentable {
    let itemID: UUID
    let controller: ShelfController
    var onSelect: (NSEvent) -> Void
    var onClickRelease: (NSEvent) -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView()
        view.itemID = itemID
        view.controller = controller
        view.onSelect = onSelect
        view.onClickRelease = onClickRelease
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        view.itemID = itemID
        view.controller = controller
        view.onSelect = onSelect
        view.onClickRelease = onClickRelease
        view.onDoubleClick = onDoubleClick
    }
}
