import Foundation

/// One row in the ⌘K bar. Presets are rows of their own, so typing "webp" or
/// "50%" reaches the thing itself rather than the submenu it lives under.
enum ShelfCommandKind: Equatable, Hashable {
    case action(ShelfAction)
    case convert(ImageFormat)
    case resize(ImageResize)
}

struct ShelfCommand: Identifiable, Equatable {
    let kind: ShelfCommandKind
    let title: String
    /// The action a preset belongs to, shown greyed beside it.
    let subtitle: String?
    let symbol: String
    /// Words that should find this row but are not in its title.
    let keywords: [String]

    var id: String {
        switch kind {
        case .action(let action): return "action.\(action.rawValue)"
        case .convert(let format): return "convert.\(format.rawValue)"
        case .resize(let resize): return "resize.\(resize.title)"
        }
    }
}

enum ShelfCommandSearch {
    /// Everything currently possible, in menu order. Presets follow the action
    /// they expand, so an unfiltered bar reads like the menu does.
    static func commands(for subject: ShelfActionSubject) -> [ShelfCommand] {
        var commands: [ShelfCommand] = []
        for action in ShelfAction.groups.flatMap({ $0 })
        where action.isAvailable(for: subject) {
            commands.append(ShelfCommand(
                kind: .action(action),
                title: action == .convertImage || action == .resizeImage
                    ? "\(action.title)…"
                    : action.title,
                subtitle: nil,
                symbol: action.symbol,
                keywords: keywords(for: action)
            ))
            if action == .convertImage {
                for format in ImageFormat.available {
                    commands.append(ShelfCommand(
                        kind: .convert(format),
                        title: "Convert to \(format.title)",
                        subtitle: "Convert Image",
                        symbol: action.symbol,
                        keywords: [format.fileExtension]
                    ))
                }
            }
            if action == .resizeImage {
                for resize in ImageResize.presets {
                    commands.append(ShelfCommand(
                        kind: .resize(resize),
                        title: "Resize to \(resize.title)",
                        subtitle: "Resize Image",
                        symbol: action.symbol,
                        keywords: ["scale", "smaller"]
                    ))
                }
            }
        }
        return commands
    }

    /// Substring matching over the title and the synonyms, ranked so a typed
    /// prefix beats a match buried in the middle of a word.
    static func rank(_ commands: [ShelfCommand], query: String) -> [ShelfCommand] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return commands }

        return commands.enumerated().compactMap { index, command -> (Int, Int, ShelfCommand)? in
            guard let score = score(command, query: query) else { return nil }
            return (score, index, command)
        }
        // Menu order breaks ties, so equally good matches keep a stable and
        // familiar order rather than whatever sort felt like.
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map(\.2)
    }

    /// Lower is better.
    private static func score(_ command: ShelfCommand, query: String) -> Int? {
        let title = command.title.lowercased()
        if title.hasPrefix(query) { return 0 }
        // A word inside the title: "trash" should find "Move to Trash" as
        // readily as it finds a title that happens to start with it.
        if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 1 }
        if title.contains(query) { return 2 }
        for keyword in command.keywords {
            let keyword = keyword.lowercased()
            if keyword.hasPrefix(query) { return 3 }
            if keyword.contains(query) { return 4 }
        }
        return nil
    }

    private static func keywords(for action: ShelfAction) -> [String] {
        switch action {
        case .open: return ["launch", "run"]
        case .openWith: return ["application", "app"]
        case .quickLook: return ["preview", "peek", "space"]
        case .getInfo: return ["details", "properties", "size", "dimensions", "exif"]
        case .showInFinder: return ["reveal", "locate", "where"]
        case .rename: return ["name", "title"]
        case .copyPath: return ["location", "directory", "folder"]
        case .copy: return ["clipboard", "duplicate"]
        case .addFromClipboard: return ["paste", "clipboard"]
        case .moveToNewShelf: return ["split", "separate"]
        case .copyToNewShelf: return ["duplicate", "split"]
        case .share: return ["airdrop", "mail", "message", "send"]
        case .compress: return ["zip", "archive", "shrink"]
        case .convertImage: return ["format", "jpeg", "jpg", "png", "heic", "webp", "avif", "tiff"]
        case .resizeImage: return ["scale", "shrink", "smaller", "dimensions", "pixels"]
        case .removeMetadata: return ["exif", "gps", "strip", "privacy", "location", "camera"]
        case .mergePDF: return ["combine", "stitch", "join", "pdf"]
        case .moveToTrash: return ["delete", "bin", "discard"]
        case .removeFromShelf: return ["take off", "drop"]
        case .clearShelf: return ["empty", "reset"]
        }
    }
}
