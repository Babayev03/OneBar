import AppKit
import Foundation
import Observation
import SwiftUI

/// Owns every live shelf, plus the two lists a closed one can land on.
///
/// A **pinned** shelf comes back at the next launch. An unpinned one goes onto
/// a short **recents** list instead, so a shelf closed by accident is not a
/// shelf lost. Only a shelf that falls off the end of recents has the files
/// OneBar wrote for it deleted.
@MainActor
@Observable
final class ShelfManager {
    static let shared = ShelfManager()

    private(set) var shelves: [ShelfController] = []
    private(set) var recent: [ShelfSnapshot] = []
    /// Pinned shelves that are not currently on screen.
    private(set) var pinned: [ShelfSnapshot] = []

    /// Set while a drag is leaving one of our own shelves, so shaking on the
    /// way to the destination does not spawn another shelf.
    var isDraggingOut = false

    var ignoredApps: [IgnoredApp] {
        didSet { persistIgnoredApps() }
    }

    private static let recentLimit = 10

    private init() {
        if let data = UserDefaults.standard.data(forKey: "shelfIgnoredApps"),
           let decoded = try? JSONDecoder().decode([IgnoredApp].self, from: data) {
            ignoredApps = decoded
        } else {
            ignoredApps = []
        }
    }

    func start() {
        let persisted = ShelfStore.shared.loadPersisted()
        recent = persisted.recent
        pinned = persisted.pinned
        ShelfStore.shared.sweep(keeping: persisted.pinned + persisted.recent)

        if AppState.shared.shelfEnabled { reopenAllPinned() }
        persist()

        ShelfDragObserver.shared.restart()
    }

    func stop() {
        persist()
        ShelfDragObserver.shared.stop()
        let transient = shelves
            .filter { !$0.model.isPinned }
            .flatMap { $0.model.items }
        for controller in shelves { controller.tearDown() }
        shelves.removeAll()
        ShelfStore.shared.discard(transient)
    }

    // MARK: - Opening

    @discardableResult
    func newShelf(at point: NSPoint?) -> ShelfController? {
        guard AppState.shared.shelfEnabled else { return nil }
        let controller = ShelfController(at: point)
        controller.model.colorSource = .automatic
        if AppState.shared.shelfColorLabels {
            controller.model.colorName = nextColorName()
        }
        shelves.append(controller)
        return controller
    }

    func newShelfFromClipboard() {
        guard AppState.shared.shelfEnabled else { return }
        ShelfItemReader.read(from: NSPasteboard.general) { items in
            guard !items.isEmpty else {
                HUD.show("Nothing on the clipboard", symbol: "exclamationmark.circle")
                return
            }
            guard let shelf = ShelfManager.shared.newShelf(at: nil) else {
                ShelfStore.shared.discard(items)
                return
            }
            shelf.add(items)
        }
    }

    @discardableResult
    func reopen(_ snapshot: ShelfSnapshot) -> ShelfController? {
        guard AppState.shared.shelfEnabled else { return nil }
        let archived = ShelfArchiveLogic.take(id: snapshot.id, pinned: &pinned, recent: &recent) ?? snapshot
        let controller = open(archived)
        persist()
        return controller
    }

    @discardableResult
    private func open(_ snapshot: ShelfSnapshot) -> ShelfController {
        if let existing = shelves.first(where: { $0.id == snapshot.id }) { return existing }
        let controller = ShelfController(snapshot: snapshot)
        shelves.append(controller)
        if controller.model.colorSource == .automatic {
            controller.applyAutomaticColor(
                AppState.shared.shelfColorLabels ? nextColorName(excluding: controller) : nil
            )
        }
        return controller
    }

    private func reopenAllPinned() {
        let snapshots = pinned
        pinned.removeAll()
        for snapshot in snapshots { _ = open(snapshot) }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            reopenAllPinned()
        } else {
            closeAll()
        }
        ShelfDragObserver.shared.restart()
        persist()
    }

    // MARK: - Closing

    func close(_ controller: ShelfController) {
        guard let index = shelves.firstIndex(where: { $0 === controller }) else { return }
        let snapshot = controller.snapshot()
        shelves.remove(at: index)
        controller.tearDown()
        restackCollapsedShelves(animated: true)
        let evicted = ShelfArchiveLogic.recordClosed(
            snapshot,
            pinned: &pinned,
            recent: &recent,
            recentLimit: Self.recentLimit
        )
        ShelfStore.shared.discard(evicted)
        persist()
    }

    func closeAll() {
        for controller in shelves.reversed() { close(controller) }
    }

    /// Drops a snapshot for good, deleting anything OneBar wrote for it.
    func forget(_ snapshot: ShelfSnapshot) {
        recent.removeAll { $0.id == snapshot.id }
        pinned.removeAll { $0.id == snapshot.id }
        ShelfStore.shared.discard(snapshot.items)
        persist()
    }

    /// Takes a snapshot off the lists without deleting anything, for when its
    /// items are being handed to a live shelf rather than thrown away.
    func forgetKeepingFiles(_ snapshot: ShelfSnapshot) {
        recent.removeAll { $0.id == snapshot.id }
        pinned.removeAll { $0.id == snapshot.id }
        persist()
    }

    func clearRecents() {
        for snapshot in recent { ShelfStore.shared.discard(snapshot.items) }
        recent.removeAll()
        persist()
    }

    var mostRecentlyClosed: ShelfSnapshot? { recent.first }

    // MARK: - Collapsed shelf stacks

    /// Vertically separated edge shelves remain independent. If the edge has
    /// filled and two collapsed shelves occupy the same row, they become a
    /// horizontal card stack: the newest stays at the edge and older cards are
    /// shifted inward far enough to expose their titles.
    func restackCollapsedShelves(animated: Bool) {
        var clusters: [[ShelfController]] = []
        for controller in shelves where controller.collapseStackData != nil {
            let matching = clusters.indices.filter { index in
                clusters[index].contains { sameStackRow($0, controller) }
            }
            guard let first = matching.first else {
                clusters.append([controller])
                continue
            }
            clusters[first].append(controller)
            for index in matching.dropFirst().reversed() {
                clusters[first].append(contentsOf: clusters.remove(at: index))
            }
        }

        for cluster in clusters {
            // `shelves` is creation order, so reversing it puts the newest card
            // at depth zero, directly against the display edge.
            for (depth, controller) in cluster.reversed().enumerated() {
                controller.applyCollapseStackDepth(depth, animated: animated)
            }
        }
    }

    private func sameStackRow(_ first: ShelfController, _ second: ShelfController) -> Bool {
        guard let a = first.collapseStackData,
              let b = second.collapseStackData,
              a.edge == b.edge,
              a.visible == b.visible
        else { return false }
        return max(a.frame.minY, b.frame.minY) < min(a.frame.maxY, b.frame.maxY)
    }

    // MARK: - Internal transfers

    /// Moves or copies items between two live shelves without round-tripping
    /// through file URLs, which would lose OneBar's materialization ownership.
    @discardableResult
    func transfer(
        _ items: [ShelfItem],
        from source: ShelfController,
        to destination: ShelfController,
        operation: ShelfTransferOperation
    ) -> Bool {
        guard AppState.shared.shelfEnabled,
              source !== destination,
              source.isActive,
              destination.isActive,
              !items.isEmpty
        else { return false }

        switch operation {
        case .move:
            let accepted = destination.add(items, discardRejected: false)
            guard !accepted.isEmpty else { return false }
            source.registerInternalTransfer(
                operation: operation,
                itemIDs: Set(accepted.map(\.id))
            )
            return true

        case .copy:
            let candidates = items.compactMap { item -> (sourceID: UUID, copy: ShelfItem)? in
                guard destination.canAccept([item]),
                      let copy = ShelfStore.shared.copyForShelf(item)
                else { return nil }
                return (item.id, copy)
            }
            guard !candidates.isEmpty else { return false }

            let accepted = destination.add(candidates.map(\.copy))
            let acceptedCopyIDs = Set(accepted.map(\.id))
            let copiedSourceIDs = Set(candidates.compactMap {
                acceptedCopyIDs.contains($0.copy.id) ? $0.sourceID : nil
            })
            guard !copiedSourceIDs.isEmpty else { return false }
            source.registerInternalTransfer(
                operation: operation,
                itemIDs: copiedSourceIDs
            )
            return true
        }
    }

    // MARK: - Appearance

    /// First colour no open shelf is already using, so two shelves side by side
    /// are never the same colour.
    func nextColorName() -> String {
        let used = Set(shelves.compactMap(\.model.colorName))
        let names = AppState.accentChoices.map(\.name)
        return names.first { !used.contains($0) } ?? names.randomElement() ?? "blue"
    }

    static func color(named name: String?) -> Color {
        AppState.accentChoices.first { $0.name == name }?.color ?? AppState.shared.accentColor
    }

    func setColorLabels(_ enabled: Bool) {
        for controller in shelves where controller.model.colorSource == .automatic {
            controller.applyAutomaticColor(enabled ? nextColorName(excluding: controller) : nil)
        }
        persist()
    }

    private func nextColorName(excluding controller: ShelfController) -> String {
        let used = Set(shelves.filter { $0 !== controller }.compactMap(\.model.colorName))
        let names = AppState.accentChoices.map(\.name)
        return names.first { !used.contains($0) } ?? names.randomElement() ?? "blue"
    }

    // MARK: - Persistence

    func persist() {
        var byID: [UUID: ShelfSnapshot] = [:]
        for snapshot in pinned { byID[snapshot.id] = snapshot }
        for controller in shelves where controller.model.isPinned {
            byID[controller.id] = controller.snapshot()
        }
        ShelfStore.shared.savePersisted(.init(
            pinned: byID.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending },
            recent: recent
        ))
    }

    // MARK: - Ignored apps

    func addIgnoredApp(bundleID: String, name: String, path: String) {
        guard !ignoredApps.contains(where: { $0.bundleID == bundleID }) else { return }
        ignoredApps.append(IgnoredApp(bundleID: bundleID, name: name, path: path))
    }

    func removeIgnoredApp(_ app: IgnoredApp) {
        ignoredApps.removeAll { $0.bundleID == app.bundleID }
    }

    private func persistIgnoredApps() {
        guard let data = try? JSONEncoder().encode(ignoredApps) else { return }
        UserDefaults.standard.set(data, forKey: "shelfIgnoredApps")
    }
}
