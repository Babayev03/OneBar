import AppKit
import Foundation

/// One thing sitting on a shelf.
///
/// A dropped **file is referenced, never copied** — `path` points at wherever it
/// already lives. Dropped text and image data have no file of their own, so one
/// is written for them under `ShelfStore.itemsDirectory` and flagged
/// `isMaterialised`; that flag is what makes the file ours to delete when the
/// item goes, and what lets a scrap of text be dragged into Finder at all.
struct ShelfItem: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case file
        case image
        case text
        case link

        var id: String { rawValue }

        var title: String {
            switch self {
            case .file: return "File"
            case .image: return "Image"
            case .text: return "Text"
            case .link: return "Link"
            }
        }
    }

    let id: UUID
    var kind: Kind
    var path: String?
    /// Resolves the item after the file is renamed or moved, which a bare path
    /// cannot. Stashing a file and then renaming it is an ordinary thing to do
    /// between dropping it on a shelf and dragging it back out.
    var bookmark: Data?
    var text: String?
    var rtfData: Data?
    var linkString: String?
    var title: String
    var byteSize: Int?
    var addedAt: Date
    var isMaterialised: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        path: String? = nil,
        bookmark: Data? = nil,
        text: String? = nil,
        rtfData: Data? = nil,
        linkString: String? = nil,
        title: String,
        byteSize: Int? = nil,
        addedAt: Date = Date(),
        isMaterialised: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.bookmark = bookmark
        self.text = text
        self.rtfData = rtfData
        self.linkString = linkString
        self.title = title
        self.byteSize = byteSize
        self.addedAt = addedAt
        self.isMaterialised = isMaterialised
    }

    /// Path first — it is the cheap check and it is right until the file moves;
    /// the bookmark is the fallback that survives a rename.
    func resolveURL() -> URL? {
        if let path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var isOnDisk: Bool { resolveURL() != nil }

    var linkURL: URL? {
        guard let linkString else { return nil }
        return URL(string: linkString)
    }

    /// What opening the item acts on: the file if there is one, else the link.
    /// A link never has a file, and a file is never opened as a URL string.
    var activationURL: URL? { resolveURL() ?? linkURL }

    var sizeString: String? {
        guard let byteSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    /// Second line of a cell: something identifying, never a repeat of the title.
    var subtitle: String? {
        switch kind {
        case .file, .image:
            return sizeString
        case .text:
            let count = text?.count ?? 0
            return count == 1 ? "1 character" : "\(count) characters"
        case .link:
            return linkURL?.host
        }
    }

    func hasSameShelfIdentity(as other: ShelfItem) -> Bool {
        switch kind {
        case .file, .image:
            guard other.kind == .file || other.kind == .image else { return false }
            return path != nil && path == other.path
        case .link:
            return other.kind == .link && linkString != nil && linkString == other.linkString
        case .text:
            return other.kind == .text && text == other.text
        }
    }
}


/// How a shelf lays its items out.
enum ShelfLayout: String, Codable, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Icons"
        case .list: return "List"
        }
    }

    var symbol: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

/// Whether the shelf colour came from OneBar's automatic palette or was
/// explicitly chosen by the user. This lets the global colour-label setting
/// change automatic labels without overwriting a user's customization.
enum ShelfColorSource: String, Codable, CaseIterable {
    case automatic
    case user
}

/// A shelf reduced to what survives being closed.
///
/// Pinned shelves come back at the next launch; unpinned ones go on a short
/// recents list so a shelf closed by accident is not a shelf lost.
struct ShelfSnapshot: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String?
    var colorName: String?
    var colorSource: ShelfColorSource
    var items: [ShelfItem]
    var originX: Double?
    var originY: Double?
    var isPinned: Bool
    var layout: ShelfLayout
    var keepInSpace: Bool
    var closedAt: Date?

    init(
        id: UUID,
        name: String? = nil,
        colorName: String? = nil,
        colorSource: ShelfColorSource = .automatic,
        items: [ShelfItem] = [],
        originX: Double? = nil,
        originY: Double? = nil,
        isPinned: Bool = false,
        layout: ShelfLayout = .grid,
        keepInSpace: Bool = false,
        closedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.colorSource = colorSource
        self.items = items
        self.originX = originX
        self.originY = originY
        self.isPinned = isPinned
        self.layout = layout
        self.keepInSpace = keepInSpace
        self.closedAt = closedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorName, colorSource, items, originX, originY
        case isPinned, layout, keepInSpace, closedAt
    }

    /// Shelf persistence is intentionally additive. A file written by an
    /// earlier phase must keep loading when a later phase adds a field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name)
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName)
        colorSource = try container.decodeIfPresent(ShelfColorSource.self, forKey: .colorSource) ?? .automatic
        items = try container.decodeIfPresent([ShelfItem].self, forKey: .items) ?? []
        originX = try container.decodeIfPresent(Double.self, forKey: .originX)
        originY = try container.decodeIfPresent(Double.self, forKey: .originY)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        layout = try container.decodeIfPresent(ShelfLayout.self, forKey: .layout) ?? .grid
        keepInSpace = try container.decodeIfPresent(Bool.self, forKey: .keepInSpace) ?? false
        closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
    }

    /// What the overflow list and Preferences show for a shelf with no name.
    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if items.count == 1 { return items[0].title }
        return items.isEmpty ? "Empty shelf" : "\(items.count) items"
    }
}
/// How hard the cursor has to be shaken before a shelf appears. The numbers are
/// a reversal count and the minimum travel each leg of the shake must cover —
/// a leg threshold is what separates a shake from hand tremor, which a plain
/// distance total does not.
enum ShakeSensitivity: String, Codable, CaseIterable, Identifiable {
    case normal
    case high
    case highest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Default"
        case .high: return "High"
        case .highest: return "Highest"
        }
    }

    var reversals: Int {
        switch self {
        case .normal: return 4
        case .high: return 3
        case .highest: return 3
        }
    }

    /// Points a leg must cover before its direction change counts.
    var minimumLeg: CGFloat {
        switch self {
        case .normal: return 70
        case .high: return 50
        case .highest: return 35
        }
    }
}

/// Where a shelf appears when it was not summoned by a shake — a shake always
/// places it under the cursor.
enum ShelfLocation: String, Codable, CaseIterable, Identifiable {
    case cursor
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case center

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: return "Near Cursor"
        case .topLeft: return "Top Left Corner"
        case .topRight: return "Top Right Corner"
        case .bottomLeft: return "Bottom Left Corner"
        case .bottomRight: return "Bottom Right Corner"
        case .center: return "Center"
        }
    }
}

/// What happens to a shelf once its contents have been dragged somewhere else.
/// macOS moves within a volume and copies across one, so "only when moved" is
/// the default: a copy leaves the shelf still holding something.
enum ShelfCloseBehavior: String, Codable, CaseIterable, Identifiable {
    case whenMoved
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whenMoved: return "Only when items are moved"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

/// Which side of a display a shelf collapses against.
enum ShelfEdge: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var title: String { self == .left ? "Left Edge" : "Right Edge" }
}

/// A shelf pushed aside. Docked leaves a small tab; retracted leaves enough of
/// the contents visible to identify the shelf.
enum ShelfCollapse: String, Codable, CaseIterable {
    case docked
    case retracted

    var visibleWidth: CGFloat {
        switch self {
        case .docked: return 24
        case .retracted: return 96
        }
    }

    var revealsOnPointerHover: Bool { self == .retracted }
}

enum ShelfHandlePresentation {
    static func label(
        shelfName: String?,
        itemTitles: [String],
        fallback: String
    ) -> String {
        if let shelfName {
            let trimmed = shelfName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let first = itemTitles.first else { return fallback }
        let remaining = itemTitles.count - 1
        return remaining == 0 ? first : "\(first) + \(remaining) more"
    }

    static func labelFrame(
        size: NSSize,
        shelfFrame: NSRect,
        edge: ShelfEdge,
        visibleFrame: NSRect,
        gap: CGFloat = 8
    ) -> NSRect {
        let preferredX = edge == .left
            ? shelfFrame.maxX + gap
            : shelfFrame.minX - size.width - gap
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let x = min(max(preferredX, visibleFrame.minX), maximumX)
        let preferredY = shelfFrame.midY - size.height / 2
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        let y = min(max(preferredY, visibleFrame.minY), maximumY)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

enum ShelfDoubleClickAction: String, Codable, CaseIterable, Identifiable {
    case none
    case dock
    case retract

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "No Action"
        case .dock: return "Dock Shelf"
        case .retract: return "Retract Shelf"
        }
    }
}

enum NotchHighlight: String, Codable, CaseIterable, Identifiable {
    case whileDragging
    case onHover
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whileDragging: return "Always While Dragging"
        case .onHover: return "When Hovering Over Notch"
        case .never: return "No Highlighting"
        }
    }

    func visualState(dragActive: Bool, targeted: Bool) -> NotchVisualState {
        switch self {
        case .whileDragging:
            if targeted { return .targeted }
            return dragActive ? .ambient : .hidden
        case .onHover:
            return targeted ? .targeted : .hidden
        case .never:
            return .hidden
        }
    }

    func isVisible(dragActive: Bool, targeted: Bool) -> Bool {
        visualState(dragActive: dragActive, targeted: targeted) != .hidden
    }
}

enum NotchVisualState: Equatable {
    case hidden
    case ambient
    case targeted
}

enum ShelfTransferOperation: Equatable {
    case move
    case copy

    var dragOperation: NSDragOperation { self == .copy ? .copy : .move }
}
