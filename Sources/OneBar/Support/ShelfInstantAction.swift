import AppKit
import Foundation
import UniformTypeIdentifiers

/// What a drag is carrying, read while it is still in the user's hand.
///
/// Deliberately *not* `ShelfItemReader.read`: that materialises dropped text and
/// image data to disk, and merely dragging past a button must not write a file.
/// Everything here is answerable from the pasteboard's own type list.
struct ShelfDragPreview: Equatable {
    var fileURLs: [URL] = []
    var hasImageData = false
    var hasText = false
    var hasLink = false
    /// Photos, Mail and some browsers promise a file rather than naming one, so
    /// what is coming — and how much of it — is not knowable until the drop.
    var hasPromises = false

    var isEmpty: Bool {
        fileURLs.isEmpty && !hasImageData && !hasText && !hasLink && !hasPromises
    }

    /// Whether there will be a file to work on once the drop lands, whether or
    /// not there is one now. A bare link is the only thing that never becomes
    /// one.
    var producesFiles: Bool {
        !fileURLs.isEmpty || hasImageData || hasText || hasPromises
    }

    var imageURLs: [URL] { fileURLs.filter { $0.conformsToType(.image) } }

    var printableURLs: [URL] {
        fileURLs.filter { $0.conformsToType(.image) || $0.conformsToType(.pdf) }
    }

    var producesImages: Bool { !imageURLs.isEmpty || hasImageData || hasPromises }

    @MainActor
    static func read(from pasteboard: NSPasteboard) -> ShelfDragPreview {
        var preview = ShelfDragPreview()
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            preview.fileURLs = urls
        }
        let types = Set(pasteboard.types ?? [])
        preview.hasImageData = types.contains(.png) || types.contains(.tiff)
        preview.hasText = types.contains(.string)
        preview.hasLink = preview.fileURLs.isEmpty && types.contains(.URL)
        let promised = Set(NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })
        preview.hasPromises = !types.isDisjoint(with: promised)
        return preview
    }
}

/// One button in the strip that appears under a shelf summoned mid-drag.
///
/// An instant action is an ordinary shelf action reached by a different route,
/// so the list is built out of `ShelfCommandKind` rather than a parallel set of
/// its own — nothing can be offered here that the menus and ⌘K do not have.
struct ShelfInstantAction: Identifiable, Equatable {
    enum Category: String, CaseIterable, Identifiable {
        case image
        case document
        case share
        case other
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .image: return "Image"
            case .document: return "Document"
            case .share: return "Share"
            case .other: return "Other"
            case .custom: return "Custom"
            }
        }
    }

    /// Stable across releases: this is what is persisted, and what an action
    /// dropped from the catalogue (WebP without `cwebp`) is recognised by.
    let id: String
    let kind: ShelfCommandKind
    /// Short enough to sit under a tile without truncating.
    let title: String
    let symbol: String
    let category: Category

    /// Every action that can run from a drop with nothing further to ask.
    /// `Convert Image…` and `Resize Image…` themselves are absent on purpose:
    /// they open a dialog, and a drop that opens a form is not instant.
    @MainActor
    static var catalogue: [ShelfInstantAction] {
        var actions: [ShelfInstantAction] = [
            ShelfInstantAction(
                id: "compress",
                kind: .action(.compress),
                title: "Zip",
                symbol: ShelfAction.compress.symbol,
                category: .other
            )
        ]
        for format in ImageFormat.available {
            actions.append(ShelfInstantAction(
                id: "convert.\(format.rawValue)",
                kind: .convert(format),
                title: format.title,
                symbol: ShelfAction.convertImage.symbol,
                category: .image
            ))
        }
        for resize in ImageResize.presets {
            actions.append(ShelfInstantAction(
                id: "resize.\(resize.persistenceKey)",
                kind: .resize(resize),
                title: resize.title,
                symbol: ShelfAction.resizeImage.symbol,
                category: .image
            ))
        }
        actions.append(contentsOf: [
            ShelfInstantAction(
                id: "removeMetadata",
                kind: .action(.removeMetadata),
                title: "Strip EXIF",
                symbol: ShelfAction.removeMetadata.symbol,
                category: .image
            ),
            ShelfInstantAction(
                id: "mergePDF",
                kind: .action(.mergePDF),
                title: "PDF",
                symbol: ShelfAction.mergePDF.symbol,
                category: .document
            ),
            ShelfInstantAction(
                id: "share",
                kind: .action(.share),
                title: "Share",
                symbol: ShelfAction.share.symbol,
                category: .share
            ),
            ShelfInstantAction(
                id: "copy",
                kind: .action(.copy),
                title: "Copy",
                symbol: ShelfAction.copy.symbol,
                category: .other
            ),
            ShelfInstantAction(
                id: "moveToTrash",
                kind: .action(.moveToTrash),
                title: "Trash",
                symbol: ShelfAction.moveToTrash.symbol,
                category: .other
            ),
        ])
        for custom in CustomActionStore.shared.actions {
            actions.append(ShelfInstantAction(
                id: customID(custom.id),
                kind: .custom(custom.id),
                title: custom.name,
                symbol: custom.symbol,
                category: .custom
            ))
        }
        return actions
    }

    /// The persisted id of a custom action's button. Derived rather than stored
    /// so removing a script can find and drop its button.
    static func customID(_ id: UUID) -> String { "custom.\(id.uuidString)" }

    static let defaultIDs = ["compress", "convert.jpeg", "mergePDF", "share"]

    /// The strip is centred under a 300pt shelf, so it can be wider than the
    /// shelf without looking wrong — but not indefinitely. Eight tiles is about
    /// where it stops reading as belonging to the shelf beneath it.
    static let maxCount = 8

    /// Ids the user chose, in their order, dropping any the catalogue no longer
    /// offers. A saved WebP button on a Mac without `cwebp` disappears rather
    /// than sitting there failing every drop.
    @MainActor
    static func resolve(_ ids: [String]) -> [ShelfInstantAction] {
        let byID = Dictionary(catalogue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Whether this button applies to what is being dragged. The rules answer
    /// from the pasteboard alone, so a promise — where the file does not exist
    /// yet — is taken at its word for anything a file can do, and only Merge to
    /// PDF, which needs to *count* them, refuses it.
    func isAvailable(for preview: ShelfDragPreview) -> Bool {
        guard !preview.isEmpty else { return false }
        switch kind {
        case .convert, .resize:
            return preview.producesImages
        // A script is handed paths, so it needs something that will be a file
        // by the time it runs — which everything except a bare link becomes.
        case .custom:
            return preview.producesFiles
        case .action(let action):
            switch action {
            case .compress: return preview.producesFiles
            case .removeMetadata: return preview.producesImages
            case .mergePDF: return preview.printableURLs.count > 1
            case .share, .copy: return true
            // Only ever a file the user already had: nothing OneBar wrote for a
            // dropped selection is worth putting in someone's Trash.
            case .moveToTrash: return !preview.fileURLs.isEmpty
            default: return preview.producesFiles
            }
        }
    }

    /// Two actions leave the shelf standing after they run. Share anchors its
    /// picker to the shelf's own view, so closing the window would take the
    /// sheet with it; Move to Trash reports what it managed to trash from a
    /// callback that checks the shelf is still alive first, and would otherwise
    /// finish in silence.
    var keepsShelfOpen: Bool {
        kind == .action(.share) || kind == .action(.moveToTrash)
    }

    /// What the progress window is titled while this runs.
    var activityLabel: String {
        switch kind {
        case .action(let action): return action.title
        case .convert(let format): return "Convert to \(format.title)"
        case .resize(let resize): return "Resize to \(resize.title)"
        case .custom: return title
        }
    }
}

extension ImageResize {
    /// A stable key for the button id. `title` is what the user reads and could
    /// reasonably be reworded; this cannot be, without orphaning saved buttons.
    var persistenceKey: String {
        switch self {
        case .original: return "original"
        case .percent(let value): return "p\(value)"
        case .longestEdge(let value): return "e\(value)"
        }
    }
}

/// Where the buttons sit inside the strip. Shared by the SwiftUI content and
/// the AppKit view that catches the drop, so the tile you see and the rectangle
/// that accepts a file are the same rectangle by construction.
///
/// Top-left origin, which is SwiftUI's space and — because the drop view is
/// flipped — the drop view's too.
enum ShelfInstantActionLayout {
    static let cellWidth: CGFloat = 64
    static let cellHeight: CGFloat = 70
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 11
    /// Between the bottom of the shelf and the top of the strip.
    static let gap: CGFloat = 10

    static func size(count: Int) -> NSSize {
        let columns = max(count, 1)
        return NSSize(
            width: padding * 2 + CGFloat(columns) * cellWidth + CGFloat(columns - 1) * spacing,
            height: padding * 2 + cellHeight
        )
    }

    static func cellFrame(at index: Int) -> NSRect {
        NSRect(
            x: padding + CGFloat(index) * (cellWidth + spacing),
            y: padding,
            width: cellWidth,
            height: cellHeight
        )
    }

    static func index(at point: NSPoint, count: Int) -> Int? {
        (0..<count).first { cellFrame(at: $0).contains(point) }
    }
}
