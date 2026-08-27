import AppKit
import Foundation
import Observation

/// The configured folder watches, in `watches.json` beside the other lists.
@MainActor
@Observable
final class FolderWatchStore {
    static let shared = FolderWatchStore()

    private let fileURL: URL
    private(set) var watches: [ShelfFolderWatch] = []

    private init() {
        fileURL = ClipboardStore.shared.baseDirectory.appendingPathComponent("watches.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ShelfFolderWatch].self, from: data) {
            watches = decoded
        }
    }

    var screenshotWatch: ShelfFolderWatch? { watches.first(where: \.isScreenshotWatch) }

    var folderWatches: [ShelfFolderWatch] { watches.filter { !$0.isScreenshotWatch } }

    @discardableResult
    func add(path: String) -> ShelfFolderWatch? {
        let url = URL(filePath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        let standardised = url.standardizedFileURL.path
        guard !watches.contains(where: { $0.path == standardised }) else { return nil }
        let watch = ShelfFolderWatch(
            path: standardised,
            bookmark: try? url.bookmarkData()
        )
        watches.append(watch)
        persist()
        return watch
    }

    /// Turning the screenshot shelf on creates its watch; turning it off takes
    /// the whole thing away rather than leaving a disabled row that means
    /// nothing to anybody.
    func setScreenshotWatchEnabled(_ enabled: Bool) {
        guard enabled else {
            watches.removeAll(where: \.isScreenshotWatch)
            persist()
            return
        }
        guard screenshotWatch == nil else { return }
        watches.append(ShelfFolderWatch(
            name: "Screenshots",
            path: ScreenshotLocation.current().standardizedFileURL.path,
            isScreenshotWatch: true
        ))
        persist()
    }

    /// The screenshot folder is a system setting that can change while OneBar
    /// is running, and the watch is only useful pointing at wherever it is now.
    func refreshScreenshotLocation() {
        guard let index = watches.firstIndex(where: \.isScreenshotWatch) else { return }
        let current = ScreenshotLocation.current().standardizedFileURL.path
        guard watches[index].path != current else { return }
        watches[index].path = current
        watches[index].bookmark = try? URL(filePath: current).bookmarkData()
        persist()
    }

    func update(_ watch: ShelfFolderWatch) {
        guard let index = watches.firstIndex(where: { $0.id == watch.id }) else { return }
        watches[index] = watch
        persist()
    }

    func remove(_ id: UUID) {
        watches.removeAll { $0.id == id }
        persist()
    }

    func watch(_ id: UUID) -> ShelfFolderWatch? {
        watches.first { $0.id == id }
    }

    /// Watching the screenshot folder by hand as well would deliver every
    /// screenshot twice, so the two are kept apart rather than both firing.
    func conflictsWithScreenshotWatch(_ path: String) -> Bool {
        guard let screenshot = screenshotWatch else { return false }
        return URL(filePath: path).standardizedFileURL.path
            == URL(filePath: screenshot.path).standardizedFileURL.path
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(watches) {
            try? data.write(to: fileURL, options: .atomic)
        }
        FolderWatchService.shared.restart()
    }
}
