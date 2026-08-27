import Foundation
import UniformTypeIdentifiers

/// What an image is being converted to.
enum ImageFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg
    case png
    case heic
    case tiff
    case avif
    /// Not an Image I/O destination on any current macOS — the system reads
    /// WebP and cannot write it. Offered only where `cwebp` is installed.
    case webp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .avif: return "AVIF"
        case .webp: return "WebP"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .avif: return .init("public.avif") ?? .png
        case .webp: return .init("org.webmproject.webp") ?? .png
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .avif: return "avif"
        case .webp: return "webp"
        }
    }

    /// PNG and TIFF are lossless, so a quality slider there would be a control
    /// that does nothing.
    var supportsQuality: Bool { self != .png && self != .tiff }

    /// WebP goes through `cwebp`, everything else through Image I/O.
    var needsExternalEncoder: Bool { self == .webp }

    /// What the menus offer. WebP disappears rather than failing where the
    /// encoder is missing — an option that always errors is worse than no
    /// option at all.
    static var available: [ImageFormat] {
        allCases.filter { !$0.needsExternalEncoder || WebPEncoder.isAvailable }
    }

    /// The format a file already is, where that is one we can write back.
    static func matching(_ type: UTType) -> ImageFormat? {
        allCases.first { type.conforms(to: $0.utType) }
    }
}

/// How much smaller the output should be. Both cases resolve to one number —
/// the longest edge in pixels — because that is what Image I/O takes.
enum ImageResize: Equatable, Hashable {
    case original
    case percent(Int)
    case longestEdge(Int)

    static let presets: [ImageResize] = [
        .percent(25), .percent(50), .longestEdge(1024), .longestEdge(2048),
    ]

    var title: String {
        switch self {
        case .original: return "Original Size"
        case .percent(let value): return "\(value)%"
        case .longestEdge(let value): return "\(value) px"
        }
    }

    /// Never upscales: asking for 2048px from a 900px photo returns 900, so a
    /// preset larger than the original is a no-op rather than a blurry blow-up.
    func targetLongestEdge(for pixelSize: CGSize) -> Int {
        let longest = Int(max(pixelSize.width, pixelSize.height).rounded())
        guard longest > 0 else { return 0 }
        switch self {
        case .original:
            return longest
        case .percent(let value):
            return max(1, min(longest, Int((Double(longest) * Double(value) / 100).rounded())))
        case .longestEdge(let value):
            return max(1, min(longest, value))
        }
    }
}

/// Where the result of an action is put once it exists.
enum ShelfOutputReveal: String, Codable, CaseIterable, Identifiable {
    case shelf
    case finder
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shelf: return "Shelf"
        case .finder: return "Finder"
        case .both: return "Shelf and Finder"
        }
    }

    var addsToShelf: Bool { self != .finder }
    var revealsInFinder: Bool { self != .shelf }

    /// Somewhere to put the result only matters when you are meant to go and
    /// find it. Sending it to the shelf alone keeps it in OneBar's own folder,
    /// where nothing has to be tidied up afterwards.
    var usesChosenFolder: Bool { self != .shelf }
}

/// One image conversion, whether it came from a preset or the custom panel.
struct ImageActionRequest: Equatable {
    var urls: [URL]
    /// `nil` keeps each file in the format it already is, which is what resizing
    /// a PNG should do. One request covers several files, and only `nil` can
    /// say "whatever each of them was".
    var format: ImageFormat?
    var resize: ImageResize
    /// Ignored for the lossless formats.
    var quality: Double
    /// `nil` writes to OneBar's own `action-output` folder.
    var folder: URL?
    var reveal: ShelfOutputReveal

    /// The quality slider is shown unless the format is known to be lossless.
    var showsQuality: Bool { format?.supportsQuality ?? true }

    init(
        urls: [URL],
        format: ImageFormat? = nil,
        resize: ImageResize = .original,
        quality: Double = 0.8,
        folder: URL? = nil,
        reveal: ShelfOutputReveal = .shelf
    ) {
        self.urls = urls
        self.format = format
        self.resize = resize
        self.quality = quality
        self.folder = folder
        self.reveal = reveal
    }
}

enum ShelfOutputNaming {
    /// Finder's convention for a name already in use: " 2", " 3", and so on.
    /// The caller supplies `isTaken` so the rule can be checked without a disk.
    static func unique(base: String, extension ext: String, isTaken: (String) -> Bool) -> String {
        let base = base.isEmpty ? "Untitled" : base
        var candidate = name(base, ext)
        var suffix = 2
        while isTaken(candidate) {
            candidate = name("\(base) \(suffix)", ext)
            suffix += 1
        }
        return candidate
    }

    /// What a converted image is called. The pixel size is in the name because
    /// a folder of `photo.jpg`, `photo 2.jpg`, `photo 3.jpg` tells you nothing
    /// about which one you asked for.
    static func imageOutputBase(for url: URL, longestEdge: Int, resized: Bool) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        return resized ? "\(base) \(longestEdge)px" : base
    }

    private static func name(_ base: String, _ ext: String) -> String {
        ext.isEmpty ? base : "\(base).\(ext)"
    }
}
