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

    private init() {
        itemsDirectory = ClipboardStore.shared.baseDirectory
            .appendingPathComponent("shelf-items", isDirectory: true)
        try? FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
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

    /// Deletes only what we wrote. A referenced file is the user's, and removing
    /// an item from a shelf must never touch it.
    func discard(_ items: [ShelfItem]) {
        for item in items where item.isMaterialised {
            guard let path = item.path else { continue }
            let url = URL(fileURLWithPath: path)
            // The per-item folder, not just the file, or the wrappers pile up.
            let folder = url.deletingLastPathComponent()
            if folder.deletingLastPathComponent().standardizedFileURL == itemsDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: folder)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Shelves do not survive a quit, so everything left here at launch belongs
    /// to a shelf that no longer exists.
    func sweep() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: itemsDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
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
}

