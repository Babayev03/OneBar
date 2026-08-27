import Foundation

/// What an `onebar://` link is asking for.
///
/// Parsing is separated from doing so the awkward part — which is entirely in
/// the URL, not in the shelf — can be tested. `URL` splits a link into a host
/// and a path, but which half a word lands in depends on how many slashes were
/// typed, and both `onebar://shelf/add` and `onebar:///shelf/add` are things
/// somebody will write.
enum ShelfURLCommand: Equatable {
    case newShelf
    case add(paths: [String], text: String?, newShelf: Bool)
    case fromClipboard
    case closeAll
    case clipboardPanel
    case unrecognised

    static func parse(_ url: URL) -> ShelfURLCommand {
        guard url.scheme?.lowercased() == "onebar" else { return .unrecognised }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []

        var words = [url.host].compactMap { $0 }
        words += url.pathComponents.filter { $0 != "/" }
        let command = words.map { $0.lowercased() }

        let paths = query.filter { $0.name == "path" }.compactMap(\.value)
            .filter { !$0.isEmpty }
        let text = query.first { $0.name == "text" }?.value
        let wantsNew = query.first { $0.name == "new" }?.value?.lowercased() == "true"

        switch command.first {
        case nil:
            return .newShelf
        case "clipboard":
            return .clipboardPanel
        case "shelf":
            return shelf(Array(command.dropFirst()), paths: paths, text: text, wantsNew: wantsNew)
        default:
            return .unrecognised
        }
    }

    private static func shelf(
        _ command: [String],
        paths: [String],
        text: String?,
        wantsNew: Bool
    ) -> ShelfURLCommand {
        let hasContent = !paths.isEmpty || !(text ?? "").isEmpty
        switch command.first {
        case "clipboard":
            return .fromClipboard
        case "close":
            return .closeAll
        case "new":
            // A new shelf with nothing to put on it is an ordinary thing to ask
            // a launcher for, so it is not an error.
            return hasContent ? .add(paths: paths, text: text, newShelf: true) : .newShelf
        case "add", nil:
            return hasContent
                ? .add(paths: paths, text: text, newShelf: wantsNew)
                : .newShelf
        default:
            return .unrecognised
        }
    }
}
