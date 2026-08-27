import Foundation

/// WebP export, which macOS cannot do on its own.
///
/// Image I/O reads WebP and has no encoder for it on any current macOS — the
/// writable list runs JPEG, PNG, HEIC, TIFF, AVIF and friends, and WebP is not
/// among them. `cwebp` is the reference encoder, so it is used where it is
/// installed and the format is simply not offered where it is not.
enum WebPEncoder {
    /// Homebrew on Apple silicon, Homebrew on Intel, then anywhere a package
    /// manager might have put it.
    private static let searchPaths = [
        "/opt/homebrew/bin/cwebp",
        "/usr/local/bin/cwebp",
        "/usr/bin/cwebp",
    ]

    static var toolURL: URL? {
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return nil
    }

    static var isAvailable: Bool { toolURL != nil }

    /// `cwebp` reads PNG, JPEG and TIFF, so the caller hands it a losslessly
    /// written intermediate rather than the original — the resize and any
    /// orientation fix have already been applied by then.
    static func encode(source: URL, to destination: URL, quality: Double) async throws {
        guard let tool = toolURL else { throw ShelfTransformError.noWebPEncoder }
        let percent = Int((max(0, min(1, quality)) * 100).rounded())
        let status = try await ShelfTransforms.runTool(
            tool,
            ["-quiet", "-q", String(percent), source.path, "-o", destination.path]
        )
        guard status == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw ShelfTransformError.toolFailed(status)
        }
    }
}
