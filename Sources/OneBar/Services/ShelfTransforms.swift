import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ShelfTransformError: LocalizedError {
    case noOutputLocation
    case unreadable(URL)
    case writeFailed
    case toolFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .noOutputLocation: return "Could not create the output folder"
        case .unreadable(let url): return "Could not read \(url.lastPathComponent)"
        case .writeFailed: return "Could not write the result"
        case .toolFailed: return "Compression failed"
        }
    }
}

/// The actions that produce a new file.
///
/// Everything here writes into `ShelfStore.outputDirectory` and never touches
/// the input, so a conversion cannot damage the original — which is the whole
/// reason the outputs live somewhere else instead of beside them.
enum ShelfTransforms {
    // MARK: - Compress

    static func compress(_ urls: [URL], store: ShelfStore = .shared) async throws -> URL {
        guard let first = urls.first else { throw ShelfTransformError.unreadable(URL(filePath: "/")) }

        // Finder's naming: one item keeps its whole name and gains .zip, a
        // group becomes Archive.zip.
        let base = urls.count == 1 ? first.lastPathComponent : "Archive"
        guard let destination = store.outputURL(base: base, extension: "zip") else {
            throw ShelfTransformError.noOutputLocation
        }

        let source: URL
        var staging: URL?
        if urls.count == 1 {
            source = first
        } else {
            // ditto archives one source, so several items are gathered under a
            // folder first. On APFS a same-volume copy is a clone, so this
            // costs neither time nor space in the ordinary case.
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OneBarArchive-\(UUID().uuidString)", isDirectory: true)
            let folder = root.appendingPathComponent("Archive", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Two items on one shelf can share a name and come from different
            // folders. Staging them both under that name loses one, so the
            // second is numbered the way Finder numbers it — and the copy is
            // not swallowed, since a half-built archive is worse than an error.
            var used: Set<String> = []
            for url in urls {
                let name = ShelfOutputNaming.unique(
                    base: url.deletingPathExtension().lastPathComponent,
                    extension: url.pathExtension
                ) { used.contains($0) }
                used.insert(name)
                try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
            }
            staging = root
            source = folder
        }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }

        let status = try await run(
            "/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]
        )
        guard status == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw ShelfTransformError.toolFailed(status)
        }
        return destination
    }

    /// A still-running deallocated `Process` crashes the app, so the process is
    /// held for the whole wait — the same rule `ScreenCaptureService` follows.
    private static func run(_ launchPath: String, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Images

    static func convert(_ request: ImageActionRequest, store: ShelfStore = .shared) async throws -> [URL] {
        var written: [URL] = []
        for url in request.urls {
            if let output = try await convertOne(url, request: request, store: store) {
                written.append(output)
            }
        }
        guard !written.isEmpty else { throw ShelfTransformError.writeFailed }
        return written
    }

    private static func convertOne(
        _ url: URL,
        request: ImageActionRequest,
        store: ShelfStore
    ) async throws -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw ShelfTransformError.unreadable(url) }

        let pixelSize = CGSize(
            width: (properties[kCGImagePropertyPixelWidth] as? Double) ?? 0,
            height: (properties[kCGImagePropertyPixelHeight] as? Double) ?? 0
        )
        let edge = request.resize.targetLongestEdge(for: pixelSize)
        guard edge > 0 else { throw ShelfTransformError.unreadable(url) }

        // The thumbnail path rather than a full decode plus a redraw: it is the
        // efficient one, and `WithTransform` bakes in EXIF orientation, so a
        // photo shot sideways does not come out sideways in a format that has
        // nowhere to record the rotation.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw ShelfTransformError.unreadable(url) }

        // An unset format keeps the file as it is, so a resized PNG stays a
        // PNG. Anything we cannot write back — GIF, WebP — becomes a JPEG.
        let format = request.format ?? sourceFormat(of: source) ?? .jpeg
        let resized = request.resize != .original && edge < Int(max(pixelSize.width, pixelSize.height))
        let base = ShelfOutputNaming.imageOutputBase(for: url, longestEdge: edge, resized: resized)
        guard let destination = store.outputURL(
            base: base,
            extension: format.fileExtension
        ) else { throw ShelfTransformError.noOutputLocation }

        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else { throw ShelfTransformError.writeFailed }

        var settings: [CFString: Any] = [:]
        if format.supportsQuality {
            settings[kCGImageDestinationLossyCompressionQuality] = request.quality
        }
        CGImageDestinationAddImage(writer, image, settings as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: destination)
            throw ShelfTransformError.writeFailed
        }
        return destination
    }

    private static func sourceFormat(of source: CGImageSource) -> ImageFormat? {
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier)
        else { return nil }
        return ImageFormat.matching(type)
    }

    // MARK: - PDF

    static func mergePDF(_ urls: [URL], store: ShelfStore = .shared) async throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            if let document = PDFDocument(url: url) {
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    merged.insert(page, at: merged.pageCount)
                }
            } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard merged.pageCount > 0 else { throw ShelfTransformError.writeFailed }

        let base = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "Merged"
        guard let destination = store.outputURL(base: base, extension: "pdf")
        else { throw ShelfTransformError.noOutputLocation }
        guard merged.write(to: destination) else { throw ShelfTransformError.writeFailed }
        return destination
    }
}
