import Foundation

/// A script the user registered, offered beside the built-in actions.
///
/// The whole contract is deliberately small: the files arrive as arguments, and
/// anything left in `ONEBAR_OUTPUT_DIR` comes back. Nothing is parsed out of the
/// script and nothing is inferred about what it does, so a shell one-liner and a
/// large Automator workflow are registered the same way.
struct CustomShelfAction: Identifiable, Codable, Equatable {
    /// How the file is started. Chosen from the file rather than stored, so
    /// renaming one to `.workflow` changes how it runs.
    enum Runner: Equatable {
        case shell
        case automator
    }

    var id = UUID()
    var name: String
    var symbol: String
    var path: String
    /// Follows the script through a rename or a move, the same way a shelf item
    /// follows a file. The path is tried first because it is the cheap check and
    /// right until the file moves.
    var bookmark: Data?

    var runner: Runner { Self.runner(forPath: path) }

    static func runner(forPath path: String) -> Runner {
        URL(filePath: path).pathExtension.lowercased() == "workflow" ? .automator : .shell
    }

    /// The default icon for a newly added action, and the list the picker
    /// offers. Kept short — this is a label, not an icon browser.
    static let symbolChoices = [
        "gearshape", "terminal", "wand.and.stars", "bolt", "scissors",
        "photo", "film", "doc.text", "arrow.up.circle", "paintbrush",
        "square.and.arrow.up", "folder",
    ]

    static let defaultSymbol = "gearshape"

    /// A name that will fit under a 64pt tile and read in a menu. Falls back to
    /// the file's own name, which is what someone adding a script in a hurry
    /// would expect.
    static func sanitised(name: String, path: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return URL(filePath: path).deletingPathExtension().lastPathComponent
        }
        return String(trimmed.prefix(40))
    }

    func resolveURL() -> URL? {
        let direct = URL(filePath: path)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let bookmark else { return nil }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    /// Only ever run against real files: a script is handed paths, and there is
    /// nothing to hand it for a dragged link or a piece of text that has not
    /// been written anywhere yet.
    func isAvailable(for subject: ShelfActionSubject) -> Bool {
        !subject.fileURLs.isEmpty
    }
}
