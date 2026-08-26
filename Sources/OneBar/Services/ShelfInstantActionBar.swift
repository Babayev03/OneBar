import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ShelfInstantActionBarModel {
    var actions: [ShelfInstantAction] = []
    /// What the drag is carrying, so a button that cannot apply is dimmed
    /// before the pointer ever reaches it.
    var preview = ShelfDragPreview()
    var highlighted: Int?
    var isPresented = false
    /// The shelf's own indicator colour, so the strip reads as belonging to it.
    var color: Color = .accentColor

    /// Set by the Preferences preview, which is showing what the strip will
    /// look like rather than reacting to a drag there is no way to have.
    var forcesAvailable = false

    func isAvailable(_ index: Int) -> Bool {
        guard actions.indices.contains(index) else { return false }
        if forcesAvailable { return true }
        return actions[index].isAvailable(for: preview)
    }
}

/// The row of action buttons under a shelf summoned mid-drag.
///
/// A window of its own rather than part of the shelf. The shelf's whole content
/// view is already one drop target, and buttons drawn inside it would have to
/// carve hit regions out of that; a separate window gets its own destination,
/// and can appear and vanish without resizing the shelf while a drag is in the
/// user's hand. It is added as a child window, so it follows the shelf when the
/// shelf moves without any tracking of its own.
@MainActor
final class ShelfInstantActionBar {
    let model = ShelfInstantActionBarModel()

    private weak var controller: ShelfController?
    private weak var parent: NSPanel?
    private var panel: NSPanel?

    /// `nil` when there is nothing to show: the feature is off, every button
    /// has been removed, or the shelf has no screen to sit on.
    init?(controller: ShelfController, parent: NSPanel) {
        let actions = ShelfInstantAction.resolve(AppState.shared.shelfInstantActionIDs)
        guard AppState.shared.shelfInstantActions,
              !actions.isEmpty,
              let visible = (parent.screen ?? NSScreen.main)?.visibleFrame
        else { return nil }

        self.controller = controller
        self.parent = parent
        model.actions = actions
        model.color = controller.model.color
        model.preview = ShelfDragPreview.read(from: NSPasteboard(name: .drag))

        let size = ShelfInstantActionLayout.size(count: actions.count)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = parent.level
        panel.collectionBehavior = parent.collectionBehavior

        let drop = ShelfInstantActionDropView(frame: NSRect(origin: .zero, size: size))
        drop.bar = self
        drop.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: ShelfInstantActionBarView(model: model))
        hosting.frame = drop.bounds
        hosting.autoresizingMask = [.width, .height]
        drop.addSubview(hosting)
        panel.contentView = drop

        panel.setFrame(
            ShelfWindowGeometry.instantActionBarFrame(
                size: size,
                shelfFrame: parent.frame,
                in: visible
            ),
            display: false
        )
        self.panel = panel
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            model.isPresented = true
        }
    }

    // MARK: - Lifetime

    /// Only ever called through `ShelfController.dismissInstantActionBar`, which
    /// owns this object: dismissing here alone would leave the controller
    /// holding a bar whose window has gone.
    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        parent?.removeChildWindow(panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.contentView = nil
            panel.orderOut(nil)
        }
    }

    // MARK: - Dropping

    func updateHighlight(at point: NSPoint, pasteboard: NSPasteboard) -> Bool {
        model.preview = ShelfDragPreview.read(from: pasteboard)
        guard let index = ShelfInstantActionLayout.index(at: point, count: model.actions.count),
              model.isAvailable(index)
        else {
            model.highlighted = nil
            return false
        }
        model.highlighted = index
        return true
    }

    func clearHighlight() {
        model.highlighted = nil
    }

    func perform(at point: NSPoint, info: NSDraggingInfo) -> Bool {
        model.highlighted = nil
        guard let index = ShelfInstantActionLayout.index(at: point, count: model.actions.count),
              model.isAvailable(index),
              let controller
        else { return false }
        let action = model.actions[index]
        controller.dismissInstantActionBar()
        ShelfInstantActionRunner.run(action, from: info, in: controller)
        return true
    }
}

/// The bar's content view. Flipped so its hit rectangles are in the same
/// top-left space `ShelfInstantActionLayout` lays the buttons out in, which is
/// what keeps the tile you can see and the rectangle that takes the file the
/// same rectangle.
final class ShelfInstantActionDropView: NSView {
    weak var bar: ShelfInstantActionBar?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ShelfDropView.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        bar?.clearHighlight()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        bar?.clearHighlight()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !operation(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        bar?.perform(at: location(of: sender), info: sender) ?? false
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let hit = bar?.updateHighlight(
            at: location(of: sender),
            pasteboard: sender.draggingPasteboard
        ) ?? false
        return hit ? .copy : []
    }

    private func location(of sender: NSDraggingInfo) -> NSPoint {
        convert(sender.draggingLocation, from: nil)
    }
}
