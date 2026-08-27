import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// How a running transform says where it has got to. `total` of zero means
/// there is no honest fraction to report.
typealias ShelfProgressReport = @Sendable (_ completed: Int, _ total: Int, _ detail: String?) -> Void

enum ShelfTransformError: LocalizedError {
    case noOutputLocation
    case unreadable(URL)
    case writeFailed
    case toolFailed(Int32)
    case noWebPEncoder
    case scriptMissing(String)
    /// Carries the script's own last words, which say far more than a number —
    /// and the number when it said nothing at all, since "failed" alone does not
    /// separate a script that ran and returned an error from one that never got
    /// as far as running.
    case scriptFailed(name: String, status: Int32, message: String?)

    var errorDescription: String? {
        switch self {
        case .noOutputLocation: return "Could not create the output folder"
        case .unreadable(let url): return "Could not read \(url.lastPathComponent)"
        case .writeFailed: return "Could not write the result"
        case .toolFailed: return "The command-line tool failed"
        case .noWebPEncoder: return "WebP needs cwebp, which is not installed"
        case .scriptMissing(let name): return "\(name) is no longer where it was"
        case .scriptFailed(let name, let status, let message):
            return message.map { "\(name): \($0)" } ?? "\(name) failed (exit \(status))"
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

    static func compress(
        _ urls: [URL],
        in folder: URL? = nil,
        store: ShelfStore = .shared,
        progress: ShelfProgressReport? = nil
    ) async throws -> URL {
        guard let first = urls.first else { throw ShelfTransformError.unreadable(URL(filePath: "/")) }

        // Finder's naming: one item keeps its whole name and gains .zip, a
        // group becomes Archive.zip.
        let base = urls.count == 1 ? first.lastPathComponent : "Archive"
        guard let destination = store.outputURL(base: base, extension: "zip", in: folder) else {
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

        // No fraction: ditto says nothing about how far in it is.
        progress?(0, 0, urls.count == 1 ? first.lastPathComponent : "\(urls.count) items")
        let status = try await runTool(
            URL(filePath: "/usr/bin/ditto"),
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
    static func runTool(_ tool: URL, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // `terminate()` raises if the process was never launched, so Stop is
        // only allowed to reach one that actually started.
        let launched = LaunchFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    launched.markLaunched(process)
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            launched.terminate()
        }
    }

    /// Stop has to reach the tool itself. A cancelled Swift task does nothing
    /// to a `Process` that is already several seconds into a large archive.
    // MARK: - Custom scripts

    /// Runs a registered script or Automator workflow over the given files.
    ///
    /// The contract is one sentence in each direction: the files arrive as
    /// arguments, and whatever is left in `ONEBAR_OUTPUT_DIR` comes back. That
    /// directory is a fresh one per run rather than `action-output` itself,
    /// because otherwise there is no way to tell what this run produced from
    /// what was already sitting there. Results are moved into the real output
    /// folder afterwards, so they land exactly where every other action's do.
    static func runCustom(
        _ action: CustomShelfAction,
        script: URL,
        urls: [URL],
        in folder: URL? = nil,
        store: ShelfStore = .shared,
        progress: ShelfProgressReport? = nil
    ) async throws -> [URL] {
        guard !urls.isEmpty else { return [] }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneBarScript-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true
        )) != nil else { throw ShelfTransformError.noOutputLocation }
        defer { try? FileManager.default.removeItem(at: staging) }

        let errorLog = staging.appendingPathComponent(".onebar-stderr")
        progress?(0, 0, action.name)

        let status = try await runScript(
            action,
            script: script,
            urls: urls,
            outputDirectory: staging,
            errorLog: errorLog
        )
        // Read before collecting, since the log lives in the staging directory
        // and must not come back as one of the script's own outputs.
        let message = tail(of: errorLog)
        try? FileManager.default.removeItem(at: errorLog)
        guard status == 0 else {
            throw ShelfTransformError.scriptFailed(
                name: action.name, status: status, message: message
            )
        }

        let produced = (try? FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var results: [URL] = []
        for (index, source) in produced.enumerated() {
            progress?(index, produced.count, source.lastPathComponent)
            guard let destination = store.outputURL(
                base: source.deletingPathExtension().lastPathComponent,
                extension: source.pathExtension,
                in: folder
            ) else { continue }
            // Not `try?`: a result the script worked to produce and that cannot
            // be moved is worth saying so about, rather than silently dropping.
            try FileManager.default.moveItem(at: source, to: destination)
            results.append(destination)
        }
        return results
    }

    /// The one place a user's own code is started.
    ///
    /// Three details are load-bearing. A shell script without its executable
    /// bit is the commonest way this fails, so one is handed to `/bin/sh`
    /// rather than refused. Output goes to files rather than pipes, because a
    /// script that prints more than a pipe buffer holds would block forever
    /// waiting for someone to drain it. And the environment is inherited rather
    /// than replaced, so a script can still find the tools on the user's PATH.
    private static func runScript(
        _ action: CustomShelfAction,
        script: URL,
        urls: [URL],
        outputDirectory: URL,
        errorLog: URL
    ) async throws -> Int32 {
        let paths = urls.map(\.path)
        let process = Process()

        switch action.runner {
        case .automator:
            process.executableURL = URL(filePath: "/usr/bin/automator")
            process.arguments = paths.flatMap { ["-i", $0] } + [script.path]
        case .shell:
            if FileManager.default.isExecutableFile(atPath: script.path) {
                process.executableURL = script
                process.arguments = paths
            } else {
                process.executableURL = URL(filePath: "/bin/sh")
                process.arguments = [script.path] + paths
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["ONEBAR_OUTPUT_DIR"] = outputDirectory.path
        environment["ONEBAR_FILE_COUNT"] = String(urls.count)
        environment["ONEBAR_ACTION_NAME"] = action.name
        process.environment = environment
        process.currentDirectoryURL = outputDirectory

        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        // Both streams go to the same log: a script that reports on stdout and
        // one that reports on stderr are equally common, and the only use made
        // of either is explaining a failure.
        process.standardOutput = errorHandle
        process.standardError = errorHandle
        process.standardInput = FileHandle.nullDevice

        let launched = LaunchFlag()
        defer { try? errorHandle.close() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    launched.markLaunched(process)
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            launched.terminate()
        }
    }

    /// The script's last useful line, which is what a person wants to see when
    /// something failed. Capped because a runaway script can produce megabytes.
    private static func tail(of log: URL) -> String? {
        guard let data = try? Data(contentsOf: log), !data.isEmpty else { return nil }
        let text = String(decoding: data.suffix(4096), as: UTF8.self)
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
            .map { String($0.prefix(200)) }
    }

    private final class LaunchFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func markLaunched(_ process: Process) {
            lock.lock()
            defer { lock.unlock() }
            // Cancellation can arrive before the process is up, in which case
            // it is killed the moment it is.
            if cancelled {
                process.terminate()
            } else {
                self.process = process
            }
        }

        func terminate() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            process?.terminate()
            process = nil
        }
    }

    // MARK: - Images

    static func convert(
        _ request: ImageActionRequest,
        store: ShelfStore = .shared,
        progress: ShelfProgressReport? = nil
    ) async throws -> [URL] {
        var written: [URL] = []
        for (index, url) in request.urls.enumerated() {
            try Task.checkCancellation()
            progress?(index, request.urls.count, url.lastPathComponent)
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
        let original = sourceFormat(of: source)
        let format = request.format ?? original ?? .jpeg
        // `.jpeg` and `.jpg` are both JPEG. Where the format has not actually
        // changed, the file keeps the spelling it already had rather than being
        // quietly renamed to whichever one we happen to prefer.
        let fileExtension = (original == format && !url.pathExtension.isEmpty)
            ? url.pathExtension.lowercased()
            : format.fileExtension
        let resized = request.resize != .original && edge < Int(max(pixelSize.width, pixelSize.height))
        let base = ShelfOutputNaming.imageOutputBase(for: url, longestEdge: edge, resized: resized)
        guard let destination = store.outputURL(
            base: base,
            extension: fileExtension,
            in: request.folder
        ) else { throw ShelfTransformError.noOutputLocation }

        if format.needsExternalEncoder {
            // cwebp cannot read a CGImage, so the already-resized and
            // already-rotated pixels go to a lossless PNG first. Encoding the
            // original instead would throw away the work above.
            let intermediate = FileManager.default.temporaryDirectory
                .appendingPathComponent("OneBarWebP-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: intermediate) }
            try write(image, to: intermediate, as: .png, quality: 1)
            try await WebPEncoder.encode(
                source: intermediate,
                to: destination,
                quality: request.quality
            )
            return destination
        }

        try write(image, to: destination, as: format, quality: request.quality)
        return destination
    }

    private static func write(
        _ image: CGImage,
        to destination: URL,
        as format: ImageFormat,
        quality: Double
    ) throws {
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else { throw ShelfTransformError.writeFailed }

        var settings: [CFString: Any] = [:]
        if format.supportsQuality {
            settings[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(writer, image, settings as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: destination)
            throw ShelfTransformError.writeFailed
        }
    }

    private static func sourceFormat(of source: CGImageSource) -> ImageFormat? {
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier)
        else { return nil }
        return ImageFormat.matching(type)
    }

    // MARK: - Metadata

    /// Strips the tags that say where a photo was taken and on what.
    ///
    /// Written with `AddImageFromSource` rather than a decode and re-encode, so
    /// a JPEG keeps its exact pixels — stripping metadata must not cost a
    /// generation of quality.
    ///
    /// The result is not EXIF-free and cannot be: Image I/O writes back a
    /// structural block of `ColorSpace`, `PixelXDimension` and
    /// `PixelYDimension` whatever it is handed. Those describe the image, not
    /// the photographer, and their presence is not a sign this failed.
    static func removeMetadata(
        _ urls: [URL],
        in folder: URL? = nil,
        store: ShelfStore = .shared,
        progress: ShelfProgressReport? = nil
    ) async throws -> [URL] {
        var written: [URL] = []
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            progress?(index, urls.count, url.lastPathComponent)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  let identifier = CGImageSourceGetType(source)
            else { continue }

            let base = url.deletingPathExtension().lastPathComponent
            guard let destination = store.outputURL(
                base: base,
                extension: url.pathExtension,
                in: folder
            ) else { throw ShelfTransformError.noOutputLocation }

            guard let writer = CGImageDestinationCreateWithURL(
                destination as CFURL, identifier, 1, nil
            ) else { throw ShelfTransformError.writeFailed }

            // The TIFF dictionary is deliberately kept: it carries orientation
            // and resolution, and dropping it turns a sideways photo sideways.
            // Everything below is camera, timestamp and location.
            let stripped: [CFString: Any] = [
                kCGImagePropertyExifDictionary: kCFNull as Any,
                kCGImagePropertyExifAuxDictionary: kCFNull as Any,
                kCGImagePropertyGPSDictionary: kCFNull as Any,
                kCGImagePropertyIPTCDictionary: kCFNull as Any,
                kCGImagePropertyMakerAppleDictionary: kCFNull as Any,
            ]
            CGImageDestinationAddImageFromSource(writer, source, 0, stripped as CFDictionary)
            guard CGImageDestinationFinalize(writer) else {
                try? FileManager.default.removeItem(at: destination)
                throw ShelfTransformError.writeFailed
            }
            written.append(destination)
        }
        guard !written.isEmpty else { throw ShelfTransformError.writeFailed }
        return written
    }

    // MARK: - PDF

    static func mergePDF(
        _ urls: [URL],
        in folder: URL? = nil,
        store: ShelfStore = .shared,
        progress: ShelfProgressReport? = nil
    ) async throws -> URL {
        let merged = PDFDocument()
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            progress?(index, urls.count, url.lastPathComponent)
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
        guard let destination = store.outputURL(base: base, extension: "pdf", in: folder)
        else { throw ShelfTransformError.noOutputLocation }
        guard merged.write(to: destination) else { throw ShelfTransformError.writeFailed }
        return destination
    }
}
