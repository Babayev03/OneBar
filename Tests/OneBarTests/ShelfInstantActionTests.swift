import AppKit
import Foundation
import Testing
@testable import OneBar

@Suite("Shelf instant actions")
struct ShelfInstantActionTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-instant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real PNG, since the image rules ask the file system what a file is
    /// rather than trusting the extension.
    private func makeImage(in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        return url
    }

    private func makeFile(in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("contents".utf8).write(to: url)
        return url
    }

    private func action(_ id: String) async -> ShelfInstantAction {
        await MainActor.run {
            ShelfInstantAction.catalogue.first { $0.id == id }!
        }
    }

    // MARK: - Layout

    @Test("A button's tile and its drop rectangle are the same rectangle")
    func layoutHitTesting() {
        let size = ShelfInstantActionLayout.size(count: 4)
        #expect(size.width == ShelfInstantActionLayout.padding * 2
            + 4 * ShelfInstantActionLayout.cellWidth
            + 3 * ShelfInstantActionLayout.spacing)

        for index in 0..<4 {
            let frame = ShelfInstantActionLayout.cellFrame(at: index)
            #expect(ShelfInstantActionLayout.index(
                at: NSPoint(x: frame.midX, y: frame.midY),
                count: 4
            ) == index)
        }

        // The gap between two tiles belongs to neither, so a drop that lands
        // between them is refused rather than guessed at.
        let first = ShelfInstantActionLayout.cellFrame(at: 0)
        let between = NSPoint(
            x: first.maxX + ShelfInstantActionLayout.spacing / 2,
            y: first.midY
        )
        #expect(ShelfInstantActionLayout.index(at: between, count: 4) == nil)

        // The padding around the row is background, not a fifth button.
        #expect(ShelfInstantActionLayout.index(at: NSPoint(x: 2, y: 2), count: 4) == nil)
        #expect(ShelfInstantActionLayout.index(
            at: NSPoint(x: size.width - 2, y: size.height / 2),
            count: 4
        ) == nil)
    }

    // MARK: - Placement

    @Test("The strip sits under its shelf, and flips above when there is no room")
    func barPlacement() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = ShelfInstantActionLayout.size(count: 4)

        let middle = NSRect(x: 500, y: 400, width: 300, height: 200)
        let below = ShelfWindowGeometry.instantActionBarFrame(
            size: size, shelfFrame: middle, in: visible
        )
        #expect(below.maxY == middle.minY - ShelfInstantActionLayout.gap)
        #expect(abs(below.midX - middle.midX) < 0.5)

        // A shelf shaken up near the bottom has nothing below it, and a strip
        // clamped into the last few points would sit on the shelf itself.
        let low = NSRect(x: 500, y: 12, width: 300, height: 200)
        let above = ShelfWindowGeometry.instantActionBarFrame(
            size: size, shelfFrame: low, in: visible
        )
        #expect(above.minY == low.maxY + ShelfInstantActionLayout.gap)

        // Centred on a shelf at the edge would hang off the display.
        let edge = NSRect(x: 1400, y: 400, width: 300, height: 200)
        let clamped = ShelfWindowGeometry.instantActionBarFrame(
            size: size, shelfFrame: edge, in: visible
        )
        #expect(clamped.maxX <= visible.maxX - ShelfWindowGeometry.margin + 0.001)
        #expect(clamped.minX >= visible.minX + ShelfWindowGeometry.margin - 0.001)
    }

    // MARK: - Persistence

    @MainActor
    @Test("Saved buttons keep their order, and one the catalogue dropped disappears")
    func resolvingSavedButtons() {
        let resolved = ShelfInstantAction.resolve(["share", "nonsense.action", "compress"])
        #expect(resolved.map(\.id) == ["share", "compress"])
        #expect(ShelfInstantAction.resolve(ShelfInstantAction.defaultIDs).count
            == ShelfInstantAction.defaultIDs.count)
    }

    @MainActor
    @Test("Every default button exists in the catalogue")
    func defaultsAreReal() {
        let ids = Set(ShelfInstantAction.catalogue.map(\.id))
        for id in ShelfInstantAction.defaultIDs {
            #expect(ids.contains(id), "\(id) is not in the catalogue")
        }
    }

    @MainActor
    @Test("The two actions that hold the shelf open are the two that need it")
    func shelfRetention() {
        let keeping = ShelfInstantAction.catalogue.filter(\.keepsShelfOpen).map(\.id)
        #expect(Set(keeping) == ["share", "moveToTrash"])
    }

    // MARK: - Availability

    @Test("A file drag offers the file actions")
    func filePreview() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = ShelfDragPreview(fileURLs: [try makeFile(in: directory, named: "notes.txt")])

        #expect(await action("compress").isAvailable(for: preview))
        #expect(await action("share").isAvailable(for: preview))
        #expect(await action("moveToTrash").isAvailable(for: preview))
        // Nothing here is an image, and one document is not a merge.
        #expect(!(await action("convert.jpeg").isAvailable(for: preview)))
        #expect(!(await action("mergePDF").isAvailable(for: preview)))
    }

    @Test("Merge to PDF needs more than one page's worth")
    func mergeNeedsSeveral() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let one = try makeImage(in: directory, named: "one.png")
        let two = try makeImage(in: directory, named: "two.png")

        #expect(!(await action("mergePDF").isAvailable(for: ShelfDragPreview(fileURLs: [one]))))
        #expect(await action("mergePDF").isAvailable(for: ShelfDragPreview(fileURLs: [one, two])))
        #expect(await action("convert.jpeg").isAvailable(for: ShelfDragPreview(fileURLs: [one])))
    }

    @Test("A dragged link becomes no file, so only sharing applies")
    func linkPreview() async {
        let preview = ShelfDragPreview(hasLink: true)
        #expect(await action("share").isAvailable(for: preview))
        #expect(await action("copy").isAvailable(for: preview))
        #expect(!(await action("compress").isAvailable(for: preview)))
        // Never the user's own file, so never something to put in their Trash.
        #expect(!(await action("moveToTrash").isAvailable(for: preview)))
    }

    @Test("Dragged text becomes a file, so it can be zipped but never trashed")
    func textPreview() async {
        let preview = ShelfDragPreview(hasText: true)
        #expect(await action("compress").isAvailable(for: preview))
        #expect(!(await action("moveToTrash").isAvailable(for: preview)))
        #expect(!(await action("convert.jpeg").isAvailable(for: preview)))
    }

    @Test("A promised file is taken at its word, except where it has to be counted")
    func promisePreview() async {
        let preview = ShelfDragPreview(hasPromises: true)
        #expect(await action("compress").isAvailable(for: preview))
        #expect(await action("convert.jpeg").isAvailable(for: preview))
        // How many files a promise holds is not knowable until it is delivered.
        #expect(!(await action("mergePDF").isAvailable(for: preview)))
    }

    @Test("An empty drag lights nothing up")
    func emptyPreview() async {
        let preview = ShelfDragPreview()
        #expect(preview.isEmpty)
        for id in ["compress", "share", "copy", "convert.jpeg", "mergePDF", "moveToTrash"] {
            #expect(!(await action(id).isAvailable(for: preview)), "\(id) should be unavailable")
        }
    }
}
