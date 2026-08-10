import Foundation

/// Persistence for clipboard history. Unpinned items are dropped when the Mac
/// has rebooted since the history was written; pinned items always survive.
final class ClipboardStore {
    private struct Payload: Codable {
        var bootTime: TimeInterval
        var items: [ClipboardItem]
    }

    static let shared = ClipboardStore()

    let baseDirectory: URL
    let imagesDirectory: URL
    private var historyURL: URL { baseDirectory.appendingPathComponent("history.json") }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDirectory = appSupport.appendingPathComponent("OneBar", isDirectory: true)
        imagesDirectory = baseDirectory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    func load() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: historyURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [] }

        var items = payload.items
        let currentBoot = BootTime.timestamp
        // Allow a small tolerance; kern.boottime can jitter by a second across sleeps.
        if abs(payload.bootTime - currentBoot) > 5 {
            let dropped = items.filter { !$0.isPinned }
            items = items.filter(\.isPinned)
            deleteImageFiles(for: dropped)
        }
        // Drop any image items whose backing file disappeared.
        items.removeAll { item in
            if item.kind == .image, let name = item.imageFilename {
                return !FileManager.default.fileExists(atPath: imagesDirectory.appendingPathComponent(name).path)
            }
            return false
        }
        return items
    }

    func save(_ items: [ClipboardItem]) {
        let payload = Payload(bootTime: BootTime.timestamp, items: items)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    func writeImage(_ data: Data) -> String? {
        let filename = UUID().uuidString + ".png"
        let url = imagesDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let name = item.imageFilename else { return nil }
        return imagesDirectory.appendingPathComponent(name)
    }

    func deleteImageFiles(for items: [ClipboardItem]) {
        for item in items {
            if let name = item.imageFilename {
                try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
            }
        }
    }
}
