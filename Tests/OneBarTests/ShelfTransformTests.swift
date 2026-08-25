import AppKit
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import OneBar

@Suite("Shelf transforms")
struct ShelfTransformTests {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-transforms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real encoded image, since every one of these paths goes through
    /// Image I/O and a stub would test nothing.
    @discardableResult
    private func writePNG(
        _ url: URL,
        width: Int = 400,
        height: Int = 200
    ) throws -> URL {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return CGSize(
            width: (properties[kCGImagePropertyPixelWidth] as? Double) ?? 0,
            height: (properties[kCGImagePropertyPixelHeight] as? Double) ?? 0
        )
    }

    // MARK: - Naming

    @Test("A taken output name gains Finder's numeric suffix")
    func uniqueNaming() {
        var taken: Set<String> = ["photo.png"]
        let second = ShelfOutputNaming.unique(base: "photo", extension: "png") { taken.contains($0) }
        #expect(second == "photo 2.png")

        taken.insert(second)
        let third = ShelfOutputNaming.unique(base: "photo", extension: "png") { taken.contains($0) }
        #expect(third == "photo 3.png")
    }

    @Test("A resized image says its size in its name, an unresized one does not")
    func outputNaming() {
        let url = URL(filePath: "/tmp/holiday.jpg")
        #expect(
            ShelfOutputNaming.imageOutputBase(for: url, longestEdge: 1024, resized: true)
                == "holiday 1024px"
        )
        #expect(
            ShelfOutputNaming.imageOutputBase(for: url, longestEdge: 4000, resized: false)
                == "holiday"
        )
    }

    // MARK: - Resize arithmetic

    @Test("Resizing never upscales")
    func resizeNeverUpscales() {
        let small = CGSize(width: 900, height: 600)
        #expect(ImageResize.longestEdge(2048).targetLongestEdge(for: small) == 900)
        #expect(ImageResize.longestEdge(400).targetLongestEdge(for: small) == 400)
        #expect(ImageResize.percent(50).targetLongestEdge(for: small) == 450)
        #expect(ImageResize.original.targetLongestEdge(for: small) == 900)
    }

    // MARK: - Compress

    @Test("Compressing one file names the archive after it")
    func compressSingle() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)

        let source = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: source)

        let archive = try await ShelfTransforms.compress([source], store: store)
        #expect(archive.lastPathComponent == "notes.txt.zip")
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect((store.fileSize(of: archive) ?? 0) > 0)
        // The original is untouched — that is the point of a separate folder.
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(archive.deletingLastPathComponent() == store.outputDirectory)
    }

    @Test("Compressing several files produces one archive")
    func compressMany() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)

        let first = directory.appendingPathComponent("a.txt")
        let second = directory.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)

        let archive = try await ShelfTransforms.compress([first, second], store: store)
        #expect(archive.lastPathComponent == "Archive.zip")
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test("Two staged files sharing a name both reach the archive")
    func compressCollidingNames() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)

        // The same file name in two folders is an ordinary thing to have on one
        // shelf, and staging both under that name would silently lose one.
        let left = directory.appendingPathComponent("left", isDirectory: true)
        let right = directory.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        let first = left.appendingPathComponent("report.txt")
        let second = right.appendingPathComponent("report.txt")
        try Data("left".utf8).write(to: first)
        try Data("right".utf8).write(to: second)

        let archive = try await ShelfTransforms.compress([first, second], store: store)

        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, unpacked.path]
        try process.run()
        process.waitUntilExit()

        let staged = unpacked.appendingPathComponent("Archive")
        let names = try FileManager.default.contentsOfDirectory(atPath: staged.path).sorted()
        #expect(names == ["report 2.txt", "report.txt"])
    }

    // MARK: - Images

    @Test("Converting rewrites the format and leaves the original alone")
    func convertFormat() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)

        let source = try writePNG(directory.appendingPathComponent("shot.png"))
        let outputs = try await ShelfTransforms.convert(
            ImageActionRequest(urls: [source], format: .jpeg),
            store: store
        )

        #expect(outputs.count == 1)
        let output = try #require(outputs.first)
        #expect(output.lastPathComponent == "shot.jpg")
        #expect(output.conformsToType(.jpeg))
        // No resize was asked for, so the pixels are unchanged.
        #expect(pixelSize(of: output) == CGSize(width: 400, height: 200))
        #expect(source.conformsToType(.png))
    }

    @Test("Resizing without a format keeps the file the format it already was")
    func resizeKeepsFormat() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)

        let source = try writePNG(directory.appendingPathComponent("wide.png"))
        let outputs = try await ShelfTransforms.convert(
            ImageActionRequest(urls: [source], resize: .percent(50)),
            store: store
        )

        let output = try #require(outputs.first)
        #expect(output.pathExtension == "png")
        #expect(output.conformsToType(.png))
        #expect(output.lastPathComponent == "wide 200px.png")
        #expect(pixelSize(of: output) == CGSize(width: 200, height: 100))
    }

    @Test("Converting several images produces one output each")
    func convertMany() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)

        let first = try writePNG(directory.appendingPathComponent("one.png"))
        let second = try writePNG(directory.appendingPathComponent("two.png"))
        let outputs = try await ShelfTransforms.convert(
            ImageActionRequest(urls: [first, second], format: .png, resize: .longestEdge(100)),
            store: store
        )
        #expect(outputs.count == 2)
        #expect(Set(outputs.map(\.lastPathComponent)) == ["one 100px.png", "two 100px.png"])
    }

    // MARK: - PDF

    @Test("Images merge into one PDF, a page each")
    func mergeImages() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)

        let first = try writePNG(directory.appendingPathComponent("page1.png"))
        let second = try writePNG(directory.appendingPathComponent("page2.png"))

        let merged = try await ShelfTransforms.mergePDF([first, second], store: store)
        #expect(merged.lastPathComponent == "Merged.pdf")
        let document = try #require(PDFDocument(url: merged))
        #expect(document.pageCount == 2)
    }

    @Test("An existing PDF contributes all of its pages")
    func mergeDocuments() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)

        let image = try writePNG(directory.appendingPathComponent("cover.png"))
        let twoPage = try await ShelfTransforms.mergePDF([image, image], store: store)

        let combined = try await ShelfTransforms.mergePDF([twoPage, image], store: store)
        let document = try #require(PDFDocument(url: combined))
        #expect(document.pageCount == 3)
    }

    // MARK: - Metadata

    @Test("Stripping metadata drops the camera and location tags and keeps the pixels")
    func removeMetadata() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)

        // A JPEG carrying EXIF and GPS, written the way a camera would.
        let source = directory.appendingPathComponent("trip.jpg")
        let context = CGContext(
            data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let writer = CGImageDestinationCreateWithURL(
            source as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        )!
        let tags: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5,
                kCGImagePropertyGPSLongitude: 0.12,
            ],
        ]
        CGImageDestinationAddImage(writer, context.makeImage()!, tags as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))

        func properties(_ url: URL) -> [CFString: Any] {
            let image = CGImageSourceCreateWithURL(url as CFURL, nil)!
            return CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as! [CFString: Any]
        }
        #expect(properties(source)[kCGImagePropertyGPSDictionary] != nil)

        let outputs = try await ShelfTransforms.removeMetadata([source], store: store)
        let output = try #require(outputs.first)
        let after = properties(output)
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        // Image I/O always writes back a structural EXIF block, so the check is
        // that nothing identifying survived — not that EXIF is absent.
        let exif = (after[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        #expect(exif[kCGImagePropertyExifUserComment] == nil)
        #expect(Set(exif.keys.map { $0 as String }) == [
            "ColorSpace", "PixelXDimension", "PixelYDimension",
        ])
        // The image itself must survive intact.
        #expect(pixelSize(of: output) == CGSize(width: 120, height: 80))
        // …and the original keeps its tags.
        #expect(properties(source)[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test("An explicit folder is where the output lands")
    func explicitOutputFolder() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)

        let chosen = directory.appendingPathComponent("Chosen", isDirectory: true)
        let source = directory.appendingPathComponent("thing.txt")
        try Data("x".utf8).write(to: source)

        let archive = try await ShelfTransforms.compress([source], in: chosen, store: store)
        #expect(archive.deletingLastPathComponent().standardizedFileURL == chosen.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: store.outputDirectory.path))
    }

    @Test("WebP is only offered where its encoder exists")
    func webPAvailability() {
        #expect(ImageFormat.available.contains(.avif))
        #expect(ImageFormat.available.contains(.webp) == WebPEncoder.isAvailable)
        // Every other format is always writable by Image I/O.
        for format in ImageFormat.allCases where format != .webp {
            #expect(ImageFormat.available.contains(format))
        }
    }

    // MARK: - Availability

    @Test("The image actions are offered for images and merging needs two")
    func imageAvailability() throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = try writePNG(directory.appendingPathComponent("a.png"))
        let text = directory.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: text)

        func item(_ url: URL, kind: ShelfItem.Kind) -> ShelfItem {
            ShelfItem(kind: kind, path: url.path, title: url.lastPathComponent)
        }

        let oneImage = ShelfActionSubject(items: [item(image, kind: .image)], shelfItemCount: 1)
        #expect(ShelfAction.convertImage.isAvailable(for: oneImage))
        #expect(ShelfAction.resizeImage.isAvailable(for: oneImage))
        #expect(ShelfAction.compress.isAvailable(for: oneImage))
        // One page is not a merge.
        #expect(!ShelfAction.mergePDF.isAvailable(for: oneImage))

        let two = ShelfActionSubject(
            items: [item(image, kind: .image), item(image, kind: .image)],
            shelfItemCount: 2
        )
        #expect(ShelfAction.mergePDF.isAvailable(for: two))

        // A text file dropped from Finder arrives as `.file`; the rule reads the
        // content type, not the item's kind, so it must not qualify.
        let textOnly = ShelfActionSubject(items: [item(text, kind: .file)], shelfItemCount: 1)
        #expect(!ShelfAction.convertImage.isAvailable(for: textOnly))
        #expect(!ShelfAction.mergePDF.isAvailable(for: textOnly))
        #expect(ShelfAction.compress.isAvailable(for: textOnly))

        // …and an image mislabelled `.file` must still qualify.
        let mislabelled = ShelfActionSubject(items: [item(image, kind: .file)], shelfItemCount: 1)
        #expect(ShelfAction.convertImage.isAvailable(for: mislabelled))
    }
}
