import AppKit
import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    let id: UUID
    let kind: Kind
    var text: String?
    var imageFilename: String?
    var byteSize: Int
    var pixelWidth: Int?
    var pixelHeight: Int?
    var sourceBundleID: String?
    var sourceAppName: String?
    var sourceAppPath: String?
    var date: Date
    var isPinned: Bool
    // Filled asynchronously by Vision after an image is captured.
    var ocrText: String?
    var qrPayload: String?

    var qrURL: URL? {
        guard let qrPayload,
              let url = URL(string: qrPayload),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    var characterCount: Int {
        text?.count ?? 0
    }

    var url: URL? {
        guard kind == .text, let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    var resolutionString: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(pixelWidth)x\(pixelHeight)"
    }

    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    var sourceAppIcon: NSImage? {
        guard let sourceAppPath else { return nil }
        return NSWorkspace.shared.icon(forFile: sourceAppPath)
    }
}

struct IgnoredApp: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let path: String
}
