import AppKit
import CoreGraphics
import Foundation

struct ShelfTransferResolution: Equatable {
    var accepted: [ShelfItem]
    var rejected: [ShelfItem]
}

/// Pure transfer decisions shared by live drops and unit tests.
enum ShelfTransferLogic {
    static func resolve(
        incoming: [ShelfItem],
        existing: [ShelfItem]
    ) -> ShelfTransferResolution {
        var represented = existing
        var accepted: [ShelfItem] = []
        var rejected: [ShelfItem] = []

        for item in incoming {
            if represented.contains(where: { item.hasSameShelfIdentity(as: $0) }) {
                rejected.append(item)
            } else {
                represented.append(item)
                accepted.append(item)
            }
        }
        return ShelfTransferResolution(accepted: accepted, rejected: rejected)
    }

    static func operation(optionDown: Bool) -> ShelfTransferOperation {
        optionDown ? .copy : .move
    }

    /// Modifier state reported by the current AppKit event can lag while a
    /// drag belongs to Finder or another process. The combined-session flags
    /// are the authoritative state for a modifier pressed during that drag.
    static func currentOperation() -> ShelfTransferOperation {
        let eventOption = NSEvent.modifierFlags.contains(.option)
            || (NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
        let sessionOption = CGEventSource.flagsState(.combinedSessionState)
            .contains(.maskAlternate)
        return operation(optionDown: eventOption || sessionOption)
    }

    static func sourceIDsToRemove(
        accepted: [ShelfItem],
        operation: ShelfTransferOperation
    ) -> Set<UUID> {
        operation == .move ? Set(accepted.map(\.id)) : []
    }

    /// Moving only part of a shelf into another OneBar shelf must not make the
    /// remaining items disappear with their window. The user's close-after-
    /// drag preference still applies to external drags and to an internal move
    /// that emptied the source shelf.
    static func shouldApplyCloseBehavior(
        afterInternalTransfer: Bool,
        remainingItemCount: Int
    ) -> Bool {
        !afterInternalTransfer || remainingItemCount == 0
    }
}
