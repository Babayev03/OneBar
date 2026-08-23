import AppKit
import Foundation
import Observation

/// Owns every live shelf.
///
/// Shelves are deliberately transient — they do not survive a quit, which is
/// why `ShelfStore.sweep()` runs at launch: anything left in the items folder
/// belongs to a shelf that no longer exists.
@MainActor
@Observable
final class ShelfManager {
    static let shared = ShelfManager()

    private(set) var shelves: [ShelfController] = []

    /// Set while a drag is leaving one of our own shelves, so shaking on the
    /// way to the destination does not spawn another shelf.
    var isDraggingOut = false

    var ignoredApps: [IgnoredApp] {
        didSet { persistIgnoredApps() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "shelfIgnoredApps"),
           let decoded = try? JSONDecoder().decode([IgnoredApp].self, from: data) {
            ignoredApps = decoded
        } else {
            ignoredApps = []
        }
    }

    func start() {
        ShelfStore.shared.sweep()
        ShakeDetector.shared.restart()
    }

    func stop() {
        ShakeDetector.shared.stop()
        closeAll()
    }

    @discardableResult
    func newShelf(at point: NSPoint?) -> ShelfController {
        let controller = ShelfController(at: point)
        shelves.append(controller)
        return controller
    }

    func close(_ controller: ShelfController) {
        guard let index = shelves.firstIndex(where: { $0 === controller }) else { return }
        shelves.remove(at: index)
        controller.tearDown()
    }

    func closeAll() {
        let going = shelves
        shelves.removeAll()
        for controller in going { controller.tearDown() }
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

