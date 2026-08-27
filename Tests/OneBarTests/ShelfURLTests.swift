import Foundation
import Testing
@testable import OneBar

@Suite("onebar:// links")
struct ShelfURLTests {
    private func parse(_ string: String) -> ShelfURLCommand {
        guard let url = URL(string: string) else {
            Issue.record("not a URL: \(string)")
            return .unrecognised
        }
        return ShelfURLCommand.parse(url)
    }

    @Test("The bare scheme opens an empty shelf")
    func bareScheme() {
        #expect(parse("onebar://") == .newShelf)
        #expect(parse("onebar://shelf") == .newShelf)
        #expect(parse("onebar://shelf/new") == .newShelf)
        #expect(parse("onebar://shelf/add") == .newShelf)
    }

    /// Which half of the URL a word lands in depends on how many slashes were
    /// typed, and both are things people write.
    @Test("Two slashes and three mean the same thing")
    func slashCount() {
        #expect(parse("onebar://shelf/close") == .closeAll)
        #expect(parse("onebar:///shelf/close") == .closeAll)
        #expect(parse("onebar://shelf/clipboard") == .fromClipboard)
        #expect(parse("onebar:///shelf/clipboard") == .fromClipboard)
    }

    @Test("Case does not matter")
    func caseInsensitive() {
        #expect(parse("onebar://Shelf/Close") == .closeAll)
        #expect(parse("ONEBAR://shelf/close") == .closeAll)
    }

    @Test("Paths and text arrive as things to put on a shelf")
    func contents() {
        #expect(parse("onebar://shelf/add?path=/tmp/a.png")
            == .add(paths: ["/tmp/a.png"], text: nil, newShelf: false))
        #expect(parse("onebar://shelf/add?path=/tmp/a.png&path=/tmp/b.png")
            == .add(paths: ["/tmp/a.png", "/tmp/b.png"], text: nil, newShelf: false))
        #expect(parse("onebar://shelf/add?text=hello")
            == .add(paths: [], text: "hello", newShelf: false))
    }

    @Test("A new shelf can be asked for either way")
    func newShelfRequest() {
        #expect(parse("onebar://shelf/new?path=/tmp/a.png")
            == .add(paths: ["/tmp/a.png"], text: nil, newShelf: true))
        #expect(parse("onebar://shelf/add?path=/tmp/a.png&new=true")
            == .add(paths: ["/tmp/a.png"], text: nil, newShelf: true))
        #expect(parse("onebar://shelf/add?path=/tmp/a.png&new=TRUE")
            == .add(paths: ["/tmp/a.png"], text: nil, newShelf: true))
        #expect(parse("onebar://shelf/add?path=/tmp/a.png&new=false")
            == .add(paths: ["/tmp/a.png"], text: nil, newShelf: false))
    }

    @Test("A percent-encoded path with spaces survives")
    func encodedPaths() {
        #expect(parse("onebar://shelf/add?path=/tmp/my%20file.png")
            == .add(paths: ["/tmp/my file.png"], text: nil, newShelf: false))
        #expect(parse("onebar://shelf/add?text=hello%20there")
            == .add(paths: [], text: "hello there", newShelf: false))
    }

    @Test("An empty path is not a path")
    func emptyPath() {
        // Otherwise a launcher that substituted nothing would ask OneBar to put
        // the root of the disk on a shelf.
        #expect(parse("onebar://shelf/add?path=") == .newShelf)
    }

    @Test("The clipboard panel has its own link")
    func clipboard() {
        #expect(parse("onebar://clipboard") == .clipboardPanel)
        // Under the shelf, the word means "make a shelf from the clipboard".
        #expect(parse("onebar://shelf/clipboard") == .fromClipboard)
    }

    @Test("Anything unrecognised says so rather than doing something else")
    func unrecognised() {
        #expect(parse("onebar://nonsense") == .unrecognised)
        #expect(parse("onebar://shelf/nonsense") == .unrecognised)
        #expect(parse("https://example.com") == .unrecognised)
    }
}
