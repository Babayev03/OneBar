import AppKit
import QuickLookThumbnailing

/// Icons for shelf cells, cached per item.
///
/// Quick Look rather than `NSWorkspace.icon(forFile:)` because a shelf full of
/// identical generic document icons tells you nothing about what you stashed —
/// a photo should look like the photo.
@MainActor
final class ShelfThumbnails {
    static let shared = ShelfThumbnails()

    private var cache: [UUID: NSImage] = [:]
    private var inFlight: Set<UUID> = []

    private init() {}

    /// Whatever is ready right now — used for the drag image, which cannot wait.
    func cached(for item: ShelfItem) -> NSImage? {
        cache[item.id] ?? fallback(for: item)
    }

    func thumbnail(for item: ShelfItem, size: CGSize) async -> NSImage? {
        if let hit = cache[item.id] { return hit }
        guard !inFlight.contains(item.id) else { return fallback(for: item) }

        guard let url = item.resolveURL() else { return fallback(for: item) }
        inFlight.insert(item.id)
        defer { inFlight.remove(item.id) }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request)
        else { return fallback(for: item) }

        let image = NSImage(cgImage: representation.cgImage, size: size)
        cache[item.id] = image
        return image
    }

    func forget(_ items: [ShelfItem]) {
        for item in items { cache.removeValue(forKey: item.id) }
    }

    private func fallback(for item: ShelfItem) -> NSImage? {
        if let url = item.resolveURL() {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let symbol: String
        switch item.kind {
        case .link: symbol = "globe"
        case .text: symbol = "doc.text"
        case .image: symbol = "photo"
        case .file: symbol = "doc"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: item.title)
    }
}

