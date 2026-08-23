import AppKit
import Foundation
import UniformTypeIdentifiers

/// Files OneBar writes on a shelf's behalf.
///
/// A shelf holds references, so this only ever sees the drops that arrive as
/// raw bytes — selected text, an image dragged out of a browser, a promised
/// file from Photos or Mail. Those have no file anywhere, and without one they
/// could never be dragged into Finder.
final class ShelfStore {
    static let shared = ShelfStore()

    /// Beside `history.json` and `click-layouts.json`, for the same reason: a
    /// stashed file is the sort of thing worth being able to find on disk.
    let itemsDirectory: URL
    private let shelvesURL: URL

    /// Pinned shelves come back at the next launch; recents are the short
    /// undo list for a shelf closed by accident.
    struct Persisted: Codable {
        var pinned: [ShelfSnapshot] = []
        var recent: [ShelfSnapshot] = []

        init(pinned: [ShelfSnapshot] = [], recent: [ShelfSnapshot] = []) {
            self.pinned = pinned
            self.recent = recent
        }

        private enum CodingKeys: String, CodingKey { case pinned, recent }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pinned = try container.decodeIfPresent([ShelfSnapshot].self, forKey: .pinned) ?? []
            recent = try container.decodeIfPresent([ShelfSnapshot].self, forKey: .recent) ?? []
        }
    }

    private convenience init() {
        self.init(baseDirectory: ClipboardStore.shared.baseDirectory)
    }

    /// Internal for isolated persistence tests; production uses `shared`.
    init(baseDirectory base: URL) {
        itemsDirectory = base.appendingPathComponent("shelf-items", isDirectory: true)
        shelvesURL = base.appendingPathComponent("shelves.json")
        try? FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
    }

    func loadPersisted() -> Persisted {
        guard let data = try? Data(contentsOf: shelvesURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return Persisted() }
        return decoded
    }

    func savePersisted(_ persisted: Persisted) {
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: shelvesURL, options: .atomic)
    }

    /// Writes `data` into a uniquely-named subfolder so the file keeps the name
    /// the user will see in Finder — two drops called `Screenshot.png` must not
    /// collide, and renaming one of them to `Screenshot-2.png` would be a lie
    /// about what was dragged.
    func materialise(_ data: Data, name: String) -> URL? {
        let folder = itemsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(sanitised(name))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Somewhere a promised file can be delivered before it becomes an item.
    func promiseDestination() -> URL? {
        let folder = itemsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return nil }
        return folder
    }

    /// Removes an abandoned promise delivery directory. It is deliberately
    /// restricted to a direct child of `shelf-items`.
    func discardPromiseDestination(_ url: URL) {
        guard isDirectChildOfItemsDirectory(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes only what we wrote. A referenced file is the user's, and removing
    /// an item from a shelf must never touch it.
    func discard(_ items: [ShelfItem], keeping retainedItems: [ShelfItem] = []) {
        let retainedPaths = Set(retainedItems.compactMap { item -> String? in
            guard item.isMaterialised, let path = item.path else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        })
        for item in items where item.isMaterialised {
            guard let path = item.path else { continue }
            let url = URL(fileURLWithPath: path)
            // A recovered snapshot can contain the exact materialisation that
            // is already represented in the destination shelf. Rejecting that
            // duplicate must not delete the file underneath the retained item.
            guard !retainedPaths.contains(url.standardizedFileURL.path) else { continue }
            let folder = url.deletingLastPathComponent()
            // Never trust the persisted flag alone: deletion is only allowed
            // inside OneBar's own shelf-items directory.
            if isDirectChildOfItemsDirectory(folder) {
                try? FileManager.default.removeItem(at: folder)
            } else if isDirectChildOfItemsDirectory(url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Deletes every materialised file not belonging to a shelf that survived.
    /// Run at launch, where anything unaccounted for is the residue of a shelf
    /// that was open when the app last quit.
    func sweep(keeping snapshots: [ShelfSnapshot]) {
        let kept = Set(snapshots.flatMap(\.items).compactMap { item -> String? in
            guard item.isMaterialised, let path = item.path else { return nil }
            return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        })
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: itemsDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where !kept.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func fileSize(of url: URL) -> Int? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isDirectory == true { return directorySize(of: url) }
        return values.totalFileAllocatedSize ?? values.fileSize
    }

    /// A folder's own size never moves however much is inside it, so a dropped
    /// folder has to be measured by its contents to show anything useful.
    private func directorySize(of url: URL) -> Int? {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return nil }
        var total = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
        }
        return total
    }

    private func sanitised(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(200))
    }

    private func isDirectChildOfItemsDirectory(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == itemsDirectory.standardizedFileURL
    }
}
