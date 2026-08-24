import AppKit
import Foundation

/// One entry in a shelf's action menu.
enum ShelfAction: String, CaseIterable, Identifiable {
    case open
    case openWith
    case quickLook
    case showInFinder
    case rename
    case copy
    case addFromClipboard
    case moveToNewShelf
    case copyToNewShelf
    case share
    case moveToTrash
    case removeFromShelf
    case clearShelf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "Open"
        case .openWith: return "Open With"
        case .quickLook: return "Quick Look"
        case .showInFinder: return "Show in Finder"
        case .rename: return "Rename…"
        case .copy: return "Copy"
        case .addFromClipboard: return "Add From Clipboard"
        case .moveToNewShelf: return "Move to New Shelf"
        case .copyToNewShelf: return "Copy to New Shelf"
        case .share: return "Share"
        case .moveToTrash: return "Move to Trash"
        case .removeFromShelf: return "Remove From Shelf"
        case .clearShelf: return "Clear Shelf"
        }
    }

    var symbol: String {
        switch self {
        case .open: return "arrow.up.forward.app"
        case .openWith: return "app.badge"
        case .quickLook: return "eye"
        case .showInFinder: return "folder"
        case .rename: return "pencil"
        case .copy: return "doc.on.doc"
        case .addFromClipboard: return "doc.on.clipboard"
        case .moveToNewShelf: return "tray.and.arrow.up"
        case .copyToNewShelf: return "tray.full"
        case .share: return "square.and.arrow.up"
        case .moveToTrash: return "trash"
        case .removeFromShelf: return "minus.circle"
        case .clearShelf: return "xmark.bin"
        }
    }

    /// Menu order, one inner array per divider-separated group.
    static let groups: [[ShelfAction]] = [
        [.open, .openWith, .quickLook],
        [.showInFinder, .rename],
        [.copy, .addFromClipboard],
        [.moveToNewShelf, .copyToNewShelf],
        [.share],
        [.moveToTrash, .removeFromShelf, .clearShelf],
    ]

    func isAvailable(for subject: ShelfActionSubject) -> Bool {
        switch self {
        case .open: return !subject.activationURLs.isEmpty
        case .openWith, .quickLook, .showInFinder: return !subject.fileURLs.isEmpty
        // Batch renaming is a different feature with a different UI; one file at
        // a time is what the menu can honestly offer.
        case .rename: return subject.items.count == 1 && !subject.fileURLs.isEmpty
        case .copy, .moveToNewShelf, .copyToNewShelf, .removeFromShelf:
            return !subject.items.isEmpty
        case .addFromClipboard: return true
        case .share: return subject.hasShareableContent
        // Only offered when there is a real user file to trash. An item OneBar
        // materialised itself lives in Application Support, and putting that in
        // the Trash would be a confusing thing to hand someone.
        case .moveToTrash: return !subject.userFileURLs.isEmpty
        case .clearShelf: return subject.shelfItemCount > 0
        }
    }
}

/// Which items an action menu was raised over.
enum ShelfActionScope: String {
    /// Raised on an item: acts on the selection, which the right-click has
    /// already been made to include.
    case selection
    /// Raised on empty shelf space: only shelf-wide actions apply, so nothing
    /// destructive can quietly run against every item at once.
    case shelf
}

/// What an action is being asked to act on. Split out from the controller so
/// the availability rules can be checked without a window on screen.
struct ShelfActionSubject {
    var items: [ShelfItem] = []
    var shelfItemCount: Int = 0

    /// What Open acts on: the file if there is one, else the link.
    var activationURLs: [URL] { items.compactMap(\.activationURL) }

    /// Only items backed by a file on disk right now.
    var fileURLs: [URL] { items.compactMap { $0.resolveURL() } }

    /// Files the user put on the shelf, as opposed to the ones OneBar wrote for
    /// dropped text and images.
    var userFileURLs: [URL] {
        items.filter { !$0.isMaterialised }.compactMap { $0.resolveURL() }
    }

    var hasShareableContent: Bool {
        !activationURLs.isEmpty || items.contains { $0.kind == .text && $0.text?.isEmpty == false }
    }
}
