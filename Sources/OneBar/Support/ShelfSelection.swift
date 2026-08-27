import AppKit
import Foundation

/// Pure selection transitions shared by the AppKit drag surface and tests.
enum ShelfSelectionLogic {
    enum Direction {
        case left
        case right
        case up
        case down
    }

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

    static func move(
        direction: Direction,
        orderedIDs: [UUID],
        columnCount: Int,
        extending: Bool,
        selection: inout Set<UUID>,
        anchor: inout UUID?
    ) {
        guard !orderedIDs.isEmpty else { return }
        let columns = max(1, columnCount)
        let isBackward = direction == .left || direction == .up

        guard !selection.isEmpty else {
            let itemID = isBackward ? orderedIDs[orderedIDs.count - 1] : orderedIDs[0]
            selection = [itemID]
            anchor = itemID
            return
        }

        let selectedIndices = orderedIDs.indices.filter { selection.contains(orderedIDs[$0]) }
        guard !selectedIndices.isEmpty else {
            selection.removeAll()
            anchor = nil
            move(
                direction: direction,
                orderedIDs: orderedIDs,
                columnCount: columns,
                extending: extending,
                selection: &selection,
                anchor: &anchor
            )
            return
        }

        let currentIndex: Int
        if extending {
            currentIndex = isBackward ? selectedIndices.min()! : selectedIndices.max()!
        } else if let anchor, let index = orderedIDs.firstIndex(of: anchor) {
            currentIndex = index
        } else {
            currentIndex = isBackward ? selectedIndices.min()! : selectedIndices.max()!
        }

        let targetIndex: Int
        switch direction {
        case .left:
            if columns > 1, currentIndex % columns == 0 { return }
            targetIndex = max(0, currentIndex - 1)
        case .right:
            if columns > 1,
               (currentIndex % columns == columns - 1 || currentIndex == orderedIDs.count - 1) {
                return
            }
            targetIndex = min(orderedIDs.count - 1, currentIndex + 1)
        case .up:
            targetIndex = max(0, currentIndex - columns)
        case .down:
            targetIndex = min(orderedIDs.count - 1, currentIndex + columns)
        }

        let targetID = orderedIDs[targetIndex]
        if extending {
            let anchorID = anchor.flatMap { orderedIDs.contains($0) ? $0 : nil }
                ?? orderedIDs[currentIndex]
            guard let anchorIndex = orderedIDs.firstIndex(of: anchorID) else { return }
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selection = Set(orderedIDs[range])
            anchor = anchorID
        } else {
            selection = [targetID]
            anchor = targetID
        }
    }
}
