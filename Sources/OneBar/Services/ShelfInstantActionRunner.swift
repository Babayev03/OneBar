import AppKit
import Foundation

/// Runs an action against a drag that was dropped on a button rather than on
/// the shelf.
///
/// The shelf is still the host — it owns the progress window and Stop, and it
/// is what `ShelfActionRunner` writes results back to — but the dropped files
/// never become items on it. What happens to the shelf afterwards is decided by
/// where the output went, in `closeIfNothingLanded`.
@MainActor
enum ShelfInstantActionRunner {
    static func run(
        _ action: ShelfInstantAction,
        from info: NSDraggingInfo,
        in controller: ShelfController
    ) {
        var collected: [ShelfItem] = []
        ShelfItemReader.read(from: info) { items in
            collected.append(contentsOf: items)
        } finished: {
            run(action, on: collected, in: controller)
        }
    }

    /// Nothing here discards what OneBar materialised for a dropped selection.
    /// These items were never on a shelf, so `ShelfStore.sweep(keeping:)` clears
    /// them at the next launch — and deleting them inline would pull the file
    /// out from under a share sheet or a pasteboard that is still pointing at
    /// it. A dragged *file* materialises nothing at all, which is the case this
    /// almost always is.
    static func run(
        _ action: ShelfInstantAction,
        on items: [ShelfItem],
        in controller: ShelfController
    ) {
        guard controller.isActive else { return }
        guard !items.isEmpty else {
            HUD.show("Nothing was dropped", symbol: "exclamationmark.circle")
            closeIfNothingLanded(controller)
            return
        }

        let subject = ShelfActionSubject(items: items, shelfItemCount: 0)
        let folder = ShelfActionRunner.defaultFolder
        let reveal = AppState.shared.shelfOutputReveal
        var onFinish: (@MainActor () -> Void)?
        if !action.keepsShelfOpen {
            onFinish = { closeIfNothingLanded(controller) }
        }

        switch action.kind {
        case .action(let shelfAction):
            // The strip dims a button that does not apply, but the preview it
            // dims from is read off the pasteboard, and a promise only says what
            // it holds once it has been delivered.
            guard shelfAction.isAvailable(for: subject) else {
                HUD.show(
                    "\(shelfAction.title) does not apply to that",
                    symbol: "exclamationmark.triangle"
                )
                onFinish?()
                return
            }
            ShelfActionRunner.perform(
                shelfAction,
                on: subject,
                in: controller,
                onFinish: onFinish
            )
        case .convert(let format):
            ShelfActionRunner.convertImages(
                ImageActionRequest(
                    urls: subject.imageURLs,
                    format: format,
                    folder: folder,
                    reveal: reveal
                ),
                in: controller,
                onFinish: onFinish
            )
        case .resize(let resize):
            ShelfActionRunner.convertImages(
                ImageActionRequest(
                    urls: subject.imageURLs,
                    resize: resize,
                    folder: folder,
                    reveal: reveal
                ),
                in: controller,
                onFinish: onFinish
            )
        case .custom(let id):
            guard let custom = CustomActionStore.shared.action(id) else {
                HUD.show("That action has been removed", symbol: "exclamationmark.triangle")
                onFinish?()
                return
            }
            ShelfActionRunner.runCustom(custom, on: subject, in: controller, onFinish: onFinish)
        }
    }

    /// The shelf goes away exactly when it was made for this drag and has
    /// nothing to show for the action.
    ///
    /// It cannot close any earlier: it hosts the progress window and Stop for
    /// the whole run. It must not close when the output rule is "Shelf",
    /// because the result is then sitting on it — checking the items rather
    /// than re-reading the preference also covers an action that produced
    /// nothing, and one the user stopped. And it must never close a shelf the
    /// user already had: the strip is offered on any shelf a drag hovers, and
    /// running an action from one parked at the edge must leave it parked.
    private static func closeIfNothingLanded(_ controller: ShelfController) {
        guard controller.isActive, controller.isTransient, controller.model.items.isEmpty
        else { return }
        ShelfManager.shared.close(controller)
    }
}
