import AppKit
import Foundation
import Observation

/// The registered scripts, in `scripts.json` beside the clipboard history.
///
/// On disk rather than in `UserDefaults` for the same reason the click layouts
/// are: this is a list somebody assembled and would want to find, copy to
/// another Mac, or back up.
@MainActor
@Observable
final class CustomActionStore {
    static let shared = CustomActionStore()

    private let fileURL: URL
    private(set) var actions: [CustomShelfAction] = []

    private init() {
        fileURL = ClipboardStore.shared.baseDirectory.appendingPathComponent("scripts.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([CustomShelfAction].self, from: data) {
            actions = decoded
        }
    }

    func action(_ id: UUID) -> CustomShelfAction? {
        actions.first { $0.id == id }
    }

    @discardableResult
    func add(path: String, name: String = "", symbol: String = CustomShelfAction.defaultSymbol) -> CustomShelfAction? {
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let action = CustomShelfAction(
            name: CustomShelfAction.sanitised(name: name, path: path),
            symbol: symbol,
            path: url.standardizedFileURL.path,
            bookmark: try? url.bookmarkData()
        )
        actions.append(action)
        write()
        return action
    }

    func update(_ action: CustomShelfAction) {
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
        var updated = action
        updated.name = CustomShelfAction.sanitised(name: action.name, path: action.path)
        // Pointed at a different file, it needs that file's bookmark: keeping
        // the old one would leave the action quietly following the script it
        // used to be, the next time either of them moved.
        if updated.path != actions[index].path {
            updated.bookmark = try? URL(filePath: updated.path).bookmarkData()
        }
        actions[index] = updated
        write()
    }

    func remove(_ id: UUID) {
        actions.removeAll { $0.id == id }
        write()
        // A removed script may have been a button; the strip reads this list.
        AppState.shared.shelfInstantActionIDs.removeAll {
            $0 == ShelfInstantAction.customID(id)
        }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard actions.indices.contains(destination) else { return }
        actions.swapAt(index, destination)
        write()
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(actions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Where `scripts.json` lives, for the Reveal button in Preferences.
    var revealURL: URL { fileURL }
}
