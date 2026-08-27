import Foundation
import UniformTypeIdentifiers

/// What a rule is being tested against. A plain value rather than a URL so the
/// matching is a pure function — a rule can be checked without a file system,
/// and the file only has to be interrogated once however many rules there are.
struct WatchedFile: Equatable {
    var name: String
    var byteSize: Int
    var isDirectory: Bool
    var contentType: UTType?

    var fileExtension: String { (name as NSString).pathExtension }
    var baseName: String { (name as NSString).deletingPathExtension }

    static func read(_ url: URL) -> WatchedFile {
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .isDirectoryKey, .contentTypeKey, .totalFileAllocatedSizeKey,
        ])
        return WatchedFile(
            name: url.lastPathComponent,
            byteSize: values?.fileSize ?? values?.totalFileAllocatedSize ?? 0,
            isDirectory: values?.isDirectory ?? false,
            contentType: values?.contentType
        )
    }
}

/// The broad categories a rule can ask about, rather than raw UTIs — "is an
/// image" is what someone wants to say, and `public.image` is not.
enum WatchedFileKind: String, Codable, CaseIterable, Identifiable {
    case image
    case video
    case audio
    case document
    case archive
    case folder
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .archive: return "Archive"
        case .folder: return "Folder"
        case .other: return "Anything else"
        }
    }

    static func of(_ file: WatchedFile) -> WatchedFileKind {
        if file.isDirectory, file.contentType?.conforms(to: .bundle) != true { return .folder }
        guard let type = file.contentType else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        // Checked last: a PDF is an archive to nobody, but plenty of document
        // formats conform to `.data` and would fall through to "anything else".
        if type.conforms(to: .pdf) || type.conforms(to: .text)
            || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .compositeContent) {
            return .document
        }
        return .other
    }
}

enum ShelfWatchField: String, Codable, CaseIterable, Identifiable {
    case name
    case fileExtension
    case size
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .fileExtension: return "Extension"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }

    /// Only the comparisons that mean something for this field. "Begins with"
    /// against a size, or "greater than" against a kind, are questions with no
    /// answer rather than questions that answer false.
    var operators: [ShelfWatchOperator] {
        switch self {
        case .name, .fileExtension:
            return [.is, .isNot, .contains, .doesNotContain, .beginsWith, .endsWith]
        case .size:
            return [.greaterThan, .lessThan]
        case .kind:
            return [.is, .isNot]
        }
    }
}

enum ShelfWatchOperator: String, Codable, CaseIterable, Identifiable {
    case `is`
    case isNot
    case contains
    case doesNotContain
    case beginsWith
    case endsWith
    case greaterThan
    case lessThan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .is: return "is"
        case .isNot: return "is not"
        case .contains: return "contains"
        case .doesNotContain: return "does not contain"
        case .beginsWith: return "begins with"
        case .endsWith: return "ends with"
        case .greaterThan: return "is greater than"
        case .lessThan: return "is less than"
        }
    }
}

enum ShelfWatchSizeUnit: String, Codable, CaseIterable, Identifiable {
    case kilobytes
    case megabytes
    case gigabytes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kilobytes: return "KB"
        case .megabytes: return "MB"
        case .gigabytes: return "GB"
        }
    }

    /// Decimal, matching what Finder shows — a 1 MB rule should agree with the
    /// number in the Get Info window rather than being 4.8% off it.
    var bytes: Int {
        switch self {
        case .kilobytes: return 1_000
        case .megabytes: return 1_000_000
        case .gigabytes: return 1_000_000_000
        }
    }
}

/// One condition. Each field keeps its own value rather than sharing a string,
/// so switching a rule from Name to Size and back does not lose what was typed.
struct ShelfWatchRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var field: ShelfWatchField = .fileExtension
    var comparison: ShelfWatchOperator = .is
    var text = ""
    var sizeValue: Double = 1
    var sizeUnit: ShelfWatchSizeUnit = .megabytes
    var kind: WatchedFileKind = .image
    var isCaseSensitive = false

    var sizeInBytes: Int { Int(sizeValue * Double(sizeUnit.bytes)) }

    /// Keeps the comparison meaningful when the field changes under it.
    mutating func normalise() {
        if !field.operators.contains(comparison) {
            comparison = field.operators.first ?? .is
        }
    }

    func matches(_ file: WatchedFile) -> Bool {
        switch field {
        case .name:
            return compare(text: file.name)
        case .fileExtension:
            return compare(text: file.fileExtension)
        case .size:
            switch comparison {
            case .greaterThan: return file.byteSize > sizeInBytes
            case .lessThan: return file.byteSize < sizeInBytes
            default: return false
            }
        case .kind:
            let actual = WatchedFileKind.of(file)
            switch comparison {
            case .is: return actual == kind
            case .isNot: return actual != kind
            default: return false
            }
        }
    }

    private func compare(text subject: String) -> Bool {
        // An empty condition matches nothing rather than everything: a
        // half-written rule must not quietly widen the watch to every file
        // that lands in the folder.
        guard !text.isEmpty else { return false }
        let subject = isCaseSensitive ? subject : subject.lowercased()
        let value = isCaseSensitive ? text : text.lowercased()
        switch comparison {
        case .is: return subject == value
        case .isNot: return subject != value
        case .contains: return subject.contains(value)
        case .doesNotContain: return !subject.contains(value)
        case .beginsWith: return subject.hasPrefix(value)
        case .endsWith: return subject.hasSuffix(value)
        default: return false
        }
    }
}

struct ShelfWatchRules: Codable, Equatable {
    enum Match: String, Codable, CaseIterable, Identifiable {
        case all
        case any

        var id: String { rawValue }
        var title: String { self == .all ? "all" : "any" }
    }

    var match: Match = .all
    var rules: [ShelfWatchRule] = []

    /// No rules means everything, which is what an unconfigured watch should do
    /// — the folder itself is already the filter someone chose.
    func matches(_ file: WatchedFile) -> Bool {
        guard !rules.isEmpty else { return true }
        return match == .all
            ? rules.allSatisfy { $0.matches(file) }
            : rules.contains { $0.matches(file) }
    }
}

/// One watched folder.
struct ShelfFolderWatch: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var path = ""
    var bookmark: Data?
    var isEnabled = true
    var includesSubfolders = false
    var rules = ShelfWatchRules()
    /// Every arrival gets a shelf of its own rather than joining the last one.
    var newShelfPerFile = false
    /// The screenshot watch, which follows wherever macOS is set to save them
    /// rather than a folder someone picked. There is at most one.
    var isScreenshotWatch = false

    var displayName: String {
        if !name.isEmpty { return name }
        if isScreenshotWatch { return "Screenshots" }
        return URL(filePath: path).lastPathComponent
    }

    func resolveURL() -> URL? {
        guard !path.isEmpty else { return nil }
        let direct = URL(filePath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: direct.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return direct
        }
        guard let bookmark else { return nil }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return resolved
    }
}

/// Where macOS is currently set to put screenshots.
enum ScreenshotLocation {
    /// `com.apple.screencapture`'s `location`, which is unset until someone
    /// changes it — the Desktop is the documented default, not a guess.
    static func current() -> URL {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location"), !raw.isEmpty
        else { return fallback }
        return URL(filePath: (raw as NSString).expandingTildeInPath)
    }
}
