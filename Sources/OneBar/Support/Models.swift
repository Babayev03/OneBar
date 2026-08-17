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

/// How a picked screen colour is written to the clipboard.
enum ColorFormat: String, Codable, CaseIterable, Identifiable {
    case hex
    case hexUpper
    case rgb
    case swiftUI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: return "Hex lowercase"
        case .hexUpper: return "Hex uppercase"
        case .rgb: return "CSS rgb()"
        case .swiftUI: return "SwiftUI Color"
        }
    }

    /// `color` must already be in an RGB space — see `ColorPickerService`.
    func string(from color: NSColor) -> String {
        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
        let r8 = Int((r * 255).rounded()), g8 = Int((g * 255).rounded()), b8 = Int((b * 255).rounded())
        switch self {
        case .hex:
            return String(format: "#%02x%02x%02x", r8, g8, b8)
        case .hexUpper:
            return String(format: "#%02X%02X%02X", r8, g8, b8)
        case .rgb:
            return "rgb(\(r8), \(g8), \(b8))"
        case .swiftUI:
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b)
        }
    }

    /// Sample used by the Preferences picker so each option shows its shape.
    var example: String {
        string(from: NSColor(srgbRed: 30 / 255, green: 136 / 255, blue: 229 / 255, alpha: 1))
    }
}
