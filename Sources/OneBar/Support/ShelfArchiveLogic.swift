import Foundation

/// Pure pinned/recent transitions, kept separate from panel ownership so the
/// persistence rules can be tested without creating AppKit windows.
enum ShelfArchiveLogic {
    static func recordClosed(
        _ input: ShelfSnapshot,
        pinned: inout [ShelfSnapshot],
        recent: inout [ShelfSnapshot],
        recentLimit: Int
    ) -> [ShelfItem] {
        pinned.removeAll { $0.id == input.id }
        recent.removeAll { $0.id == input.id }

        var snapshot = input
        if snapshot.isPinned {
            pinned.append(snapshot)
            return []
        }
        guard !snapshot.items.isEmpty else { return snapshot.items }

        snapshot.closedAt = Date()
        recent.insert(snapshot, at: 0)
        guard recent.count > recentLimit else { return [] }
        let evicted = recent.dropFirst(recentLimit).flatMap(\.items)
        recent = Array(recent.prefix(recentLimit))
        return evicted
    }

    @discardableResult
    static func take(
        id: UUID,
        pinned: inout [ShelfSnapshot],
        recent: inout [ShelfSnapshot]
    ) -> ShelfSnapshot? {
        if let index = pinned.firstIndex(where: { $0.id == id }) {
            return pinned.remove(at: index)
        }
        if let index = recent.firstIndex(where: { $0.id == id }) {
            return recent.remove(at: index)
        }
        return nil
    }

    /// Splits the pinned list at the number of shelves there is room to open.
    ///
    /// The remainder stays pinned rather than being dropped: a shelf the user
    /// asked to come back must not vanish because the limit happened to be
    /// lower than the number of them.
    static func split(
        pinned: [ShelfSnapshot],
        room: Int
    ) -> (open: [ShelfSnapshot], keptPinned: [ShelfSnapshot]) {
        let room = max(0, room)
        return (Array(pinned.prefix(room)), Array(pinned.dropFirst(room)))
    }
}
