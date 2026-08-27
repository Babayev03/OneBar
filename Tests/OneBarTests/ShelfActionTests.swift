import AppKit
import Foundation
import Testing
@testable import OneBar

@Suite("Shelf actions")
struct ShelfActionTests {
    /// A real file, since every availability rule turns on whether the item
    /// resolves on disk right now.
    private func makeFile(
        in directory: URL,
        named name: String,
        materialised: Bool = false
    ) throws -> ShelfItem {
        let url = directory.appendingPathComponent(name)
        try Data("contents".utf8).write(to: url)
        return ShelfItem(
            kind: .file,
            path: url.path,
            title: name,
            byteSize: 8,
            isMaterialised: materialised
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("An empty subject offers only the shelf-wide actions")
    func emptySubject() {
        let subject = ShelfActionSubject(items: [], shelfItemCount: 3)
        let available = ShelfAction.allCases.filter { $0.isAvailable(for: subject) }
        #expect(Set(available) == [.addFromClipboard, .clearShelf])
    }

    @Test("An empty shelf cannot be cleared")
    func emptyShelf() {
        let subject = ShelfActionSubject(items: [], shelfItemCount: 0)
        #expect(!ShelfAction.clearShelf.isAvailable(for: subject))
        #expect(ShelfAction.addFromClipboard.isAvailable(for: subject))
    }

    @Test("A file on disk offers every action that is not about images")
    func fileOnDisk() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let subject = ShelfActionSubject(
            items: [try makeFile(in: directory, named: "note.txt")],
            shelfItemCount: 1
        )
        // A lone text file is not an image and cannot be merged with itself.
        let inapplicable: Set<ShelfAction> = [
            .convertImage, .resizeImage, .removeMetadata, .mergePDF,
        ]
        for action in ShelfAction.allCases {
            #expect(
                action.isAvailable(for: subject) == !inapplicable.contains(action),
                "\(action.rawValue) availability is wrong for a lone text file"
            )
        }
    }

    @Test("A missing file leaves only what does not touch disk")
    func missingFile() {
        let item = ShelfItem(
            kind: .file,
            path: "/nowhere/gone.txt",
            title: "gone.txt"
        )
        let subject = ShelfActionSubject(items: [item], shelfItemCount: 1)
        #expect(!ShelfAction.open.isAvailable(for: subject))
        #expect(!ShelfAction.showInFinder.isAvailable(for: subject))
        #expect(!ShelfAction.quickLook.isAvailable(for: subject))
        #expect(!ShelfAction.rename.isAvailable(for: subject))
        #expect(!ShelfAction.moveToTrash.isAvailable(for: subject))
        #expect(!ShelfAction.share.isAvailable(for: subject))
        // Taking a dead reference off the shelf is exactly what you want to do
        // with it, so those stay.
        #expect(ShelfAction.removeFromShelf.isAvailable(for: subject))
        #expect(ShelfAction.copy.isAvailable(for: subject))
        #expect(ShelfAction.moveToNewShelf.isAvailable(for: subject))
    }

    @Test("A link opens and shares without ever being a file")
    func link() {
        let item = ShelfItem(
            kind: .link,
            linkString: "https://example.com",
            title: "example.com"
        )
        let subject = ShelfActionSubject(items: [item], shelfItemCount: 1)
        #expect(ShelfAction.open.isAvailable(for: subject))
        #expect(ShelfAction.share.isAvailable(for: subject))
        #expect(!ShelfAction.openWith.isAvailable(for: subject))
        #expect(!ShelfAction.showInFinder.isAvailable(for: subject))
        #expect(!ShelfAction.moveToTrash.isAvailable(for: subject))
    }

    @Test("Text that never reached disk is still shareable")
    func unmaterialisedText() {
        let item = ShelfItem(kind: .text, text: "hello", title: "hello")
        let subject = ShelfActionSubject(items: [item], shelfItemCount: 1)
        #expect(ShelfAction.share.isAvailable(for: subject))
        #expect(!ShelfAction.open.isAvailable(for: subject))
        #expect(!ShelfAction.moveToTrash.isAvailable(for: subject))
    }

    @Test("Trash is offered for user files and never for OneBar's own")
    func trashOwnership() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let owned = try makeFile(in: directory, named: "dropped.txt", materialised: true)
        let ownedOnly = ShelfActionSubject(items: [owned], shelfItemCount: 1)
        #expect(!ShelfAction.moveToTrash.isAvailable(for: ownedOnly))
        #expect(ShelfAction.removeFromShelf.isAvailable(for: ownedOnly))

        let user = try makeFile(in: directory, named: "report.pdf")
        let mixed = ShelfActionSubject(items: [owned, user], shelfItemCount: 2)
        #expect(ShelfAction.moveToTrash.isAvailable(for: mixed))
        #expect(mixed.userFileURLs.count == 1)
        #expect(mixed.userFileURLs.first?.lastPathComponent == "report.pdf")
    }

    @Test("Rename is offered for one file at a time")
    func renameIsSingular() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let one = ShelfActionSubject(
            items: [try makeFile(in: directory, named: "a.txt")],
            shelfItemCount: 2
        )
        #expect(ShelfAction.rename.isAvailable(for: one))

        let two = ShelfActionSubject(
            items: [
                try makeFile(in: directory, named: "b.txt"),
                try makeFile(in: directory, named: "c.txt"),
            ],
            shelfItemCount: 2
        )
        #expect(!ShelfAction.rename.isAvailable(for: two))
    }

    @Test("Every action appears exactly once in the menu order")
    func menuGroupsCoverEveryAction() {
        let listed = ShelfAction.groups.flatMap { $0 }
        #expect(Set(listed) == Set(ShelfAction.allCases))
        #expect(listed.count == ShelfAction.allCases.count)
    }
}

@Suite("Shelf command bar")
struct ShelfCommandTests {
    private func imageSubject() throws -> ShelfActionSubject {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shot.png")
        let context = CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return ShelfActionSubject(
            items: [ShelfItem(kind: .image, path: url.path, title: "shot.png")],
            shelfItemCount: 1
        )
    }

    @Test("Only what is currently possible is listed")
    func listsAvailableOnly() {
        let empty = ShelfActionSubject(items: [], shelfItemCount: 0)
        let kinds = ShelfCommandSearch.commands(for: empty, custom: []).map(\.kind)
        #expect(kinds == [.action(.addFromClipboard)])
    }

    @Test("Presets are rows of their own")
    func presetsAreRows() throws {
        let commands = ShelfCommandSearch.commands(for: try imageSubject(), custom: [])
        #expect(commands.contains { $0.kind == .convert(.png) })
        #expect(commands.contains { $0.kind == .resize(.percent(50)) })
        // The action itself is still there, to reach the custom dialog.
        #expect(commands.contains { $0.kind == .action(.convertImage) })
    }

    @Test("A format name finds its own conversion, not the submenu")
    func formatQuery() throws {
        let commands = ShelfCommandSearch.commands(for: try imageSubject(), custom: [])
        let top = ShelfCommandSearch.rank(commands, query: "png").first
        #expect(top?.kind == .convert(.png))
    }

    @Test("Synonyms reach actions whose titles do not contain them")
    func synonyms() throws {
        let commands = ShelfCommandSearch.commands(for: try imageSubject(), custom: [])
        func top(_ query: String) -> ShelfCommandKind? {
            ShelfCommandSearch.rank(commands, query: query).first?.kind
        }
        #expect(top("zip") == .action(.compress))
        #expect(top("delete") == .action(.moveToTrash))
        #expect(top("exif") == .action(.getInfo))
        #expect(top("reveal") == .action(.showInFinder))
    }

    @Test("A word anywhere in the title matches, and menu order breaks ties")
    func wordMatching() throws {
        let commands = ShelfCommandSearch.commands(for: try imageSubject(), custom: [])
        let trash = ShelfCommandSearch.rank(commands, query: "trash")
        #expect(trash.first?.kind == .action(.moveToTrash))

        let copy = ShelfCommandSearch.rank(commands, query: "copy")
        // Copy Path comes before Copy to New Shelf because the menu lists it first.
        #expect(copy.first?.kind == .action(.copyPath))
    }

    @Test("An unmatched query returns nothing rather than everything")
    func noMatch() throws {
        let commands = ShelfCommandSearch.commands(for: try imageSubject(), custom: [])
        #expect(ShelfCommandSearch.rank(commands, query: "xyzzy").isEmpty)
        // An empty query is not a filter.
        #expect(ShelfCommandSearch.rank(commands, query: "   ").count == commands.count)
    }
}
