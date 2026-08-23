import AppKit
import Foundation

/// Pure selection transitions shared by the AppKit drag surface and tests.
enum ShelfSelectionLogic {
    static func shouldOpen(clickCount: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        let selectionModifiers = modifiers.intersection([.command, .shift])
        return clickCount == 2 && selectionModifiers.isEmpty
    }

    static func mouseDown(
        on itemID: UUID,
        orderedIDs: [UUID],
        modifiers: NSEvent.ModifierFlags,
        selection: inout Set<UUID>,
        anchor: inout UUID?
    ) {
        let modifiers = modifiers.intersection([.command, .shift])

        if modifiers.contains(.shift),
           let anchorID = anchor ?? selection.first,
           let from = orderedIDs.firstIndex(of: anchorID),
           let to = orderedIDs.firstIndex(of: itemID) {
            let range = from <= to ? from...to : to...from
            let ranged = Set(orderedIDs[range])
            if modifiers.contains(.command) {
                selection.formUnion(ranged)
            } else {
                selection = ranged
            }
            anchor = anchorID
            return
        }

        if modifiers.contains(.command) {
            if selection.contains(itemID) {
                selection.remove(itemID)
                if anchor == itemID { anchor = selection.first }
            } else {
                selection.insert(itemID)
                anchor = itemID
            }
            return
        }

        // Keep an existing group intact until mouse-up. If the pointer turns
        // into a drag, every selected item leaves together.
        if selection.count > 1, selection.contains(itemID) { return }
        selection = [itemID]
        anchor = itemID
    }

    static func mouseUpWithoutDrag(
        on itemID: UUID,
        modifiers: NSEvent.ModifierFlags,
        selection: inout Set<UUID>,
        anchor: inout UUID?
    ) {
        let modifiers = modifiers.intersection([.command, .shift])
        guard modifiers.isEmpty, selection.count > 1, selection.contains(itemID) else { return }
        selection = [itemID]
        anchor = itemID
    }
}
