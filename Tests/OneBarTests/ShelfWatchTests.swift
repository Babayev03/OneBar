import Foundation
import Testing
import UniformTypeIdentifiers
@testable import OneBar

@Suite("Folder watch rules")
struct ShelfWatchTests {
    private func file(
        _ name: String,
        bytes: Int = 1_000,
        type: UTType? = nil,
        directory: Bool = false
    ) -> WatchedFile {
        WatchedFile(
            name: name,
            byteSize: bytes,
            isDirectory: directory,
            contentType: type ?? UTType(filenameExtension: (name as NSString).pathExtension)
        )
    }

    private func rule(
        _ field: ShelfWatchField,
        _ comparison: ShelfWatchOperator,
        text: String = "",
        size: Double = 1,
        unit: ShelfWatchSizeUnit = .megabytes,
        kind: WatchedFileKind = .image,
        caseSensitive: Bool = false
    ) -> ShelfWatchRule {
        ShelfWatchRule(
            field: field,
            comparison: comparison,
            text: text,
            sizeValue: size,
            sizeUnit: unit,
            kind: kind,
            isCaseSensitive: caseSensitive
        )
    }

    // MARK: - Text conditions

    @Test("Name and extension compare the way the words say")
    func textComparisons() {
        let subject = file("Screenshot 2026-08-27.png")
        #expect(rule(.fileExtension, .is, text: "png").matches(subject))
        #expect(!rule(.fileExtension, .is, text: "jpg").matches(subject))
        #expect(rule(.fileExtension, .isNot, text: "jpg").matches(subject))
        #expect(rule(.name, .beginsWith, text: "Screenshot").matches(subject))
        #expect(rule(.name, .endsWith, text: ".png").matches(subject))
        #expect(rule(.name, .contains, text: "2026").matches(subject))
        #expect(rule(.name, .doesNotContain, text: "invoice").matches(subject))
    }

    @Test("Case is ignored unless it is asked for")
    func caseSensitivity() {
        let subject = file("Photo.PNG")
        #expect(rule(.fileExtension, .is, text: "png").matches(subject))
        #expect(!rule(.fileExtension, .is, text: "png", caseSensitive: true).matches(subject))
        #expect(rule(.fileExtension, .is, text: "PNG", caseSensitive: true).matches(subject))
    }

    @Test("A half-written condition matches nothing rather than everything")
    func emptyTextMatchesNothing() {
        let subject = file("anything.png")
        // The dangerous direction: an empty "contains" that matched everything
        // would silently widen the watch to every file that landed.
        #expect(!rule(.name, .contains, text: "").matches(subject))
        #expect(!rule(.name, .doesNotContain, text: "").matches(subject))
        #expect(!rule(.name, .is, text: "").matches(subject))
    }

    // MARK: - Size

    @Test("Size compares in the units Finder shows")
    func sizeComparisons() {
        let small = file("small.png", bytes: 500_000)
        let large = file("large.png", bytes: 4_000_000)
        #expect(rule(.size, .greaterThan, size: 1, unit: .megabytes).matches(large))
        #expect(!rule(.size, .greaterThan, size: 1, unit: .megabytes).matches(small))
        #expect(rule(.size, .lessThan, size: 1, unit: .megabytes).matches(small))
        #expect(rule(.size, .greaterThan, size: 100, unit: .kilobytes).matches(small))
    }

    // MARK: - Kind

    @Test("Kind answers the question people actually ask")
    func kinds() {
        #expect(WatchedFileKind.of(file("a.png")) == .image)
        #expect(WatchedFileKind.of(file("a.mp4")) == .video)
        #expect(WatchedFileKind.of(file("a.mp3")) == .audio)
        #expect(WatchedFileKind.of(file("a.zip")) == .archive)
        #expect(WatchedFileKind.of(file("a.pdf")) == .document)
        #expect(WatchedFileKind.of(file("a.txt")) == .document)
        #expect(WatchedFileKind.of(file("Folder", type: nil, directory: true)) == .folder)

        #expect(rule(.kind, .is, kind: .image).matches(file("a.png")))
        #expect(!rule(.kind, .is, kind: .image).matches(file("a.mp4")))
        #expect(rule(.kind, .isNot, kind: .image).matches(file("a.mp4")))
    }

    // MARK: - Sets

    @Test("An unconfigured watch takes everything")
    func noRulesTakesEverything() {
        #expect(ShelfWatchRules().matches(file("anything.xyz")))
    }

    @Test("All and any mean what they say")
    func matchModes() {
        var rules = ShelfWatchRules()
        rules.rules = [
            rule(.fileExtension, .is, text: "png"),
            rule(.size, .greaterThan, size: 1, unit: .megabytes),
        ]

        let bigPNG = file("a.png", bytes: 4_000_000)
        let smallPNG = file("a.png", bytes: 1_000)
        let bigMovie = file("a.mp4", bytes: 4_000_000)

        rules.match = .all
        #expect(rules.matches(bigPNG))
        #expect(!rules.matches(smallPNG))
        #expect(!rules.matches(bigMovie))

        rules.match = .any
        #expect(rules.matches(bigPNG))
        #expect(rules.matches(smallPNG))
        #expect(rules.matches(bigMovie))
        #expect(!rules.matches(file("a.txt", bytes: 10)))
    }

    // MARK: - Editing

    @Test("Changing a rule's field leaves it asking an answerable question")
    func normalising() {
        // "begins with" against a size is not a question with a false answer,
        // it is not a question — so the comparison moves to one that is.
        var subject = rule(.name, .beginsWith, text: "Screenshot")
        subject.field = .size
        subject.normalise()
        #expect(subject.comparison == .greaterThan)
        #expect(ShelfWatchField.size.operators == [.greaterThan, .lessThan])

        subject.field = .kind
        subject.normalise()
        #expect(subject.comparison == .is)
        // The text is still there for when the field goes back.
        #expect(subject.text == "Screenshot")
    }

    @Test("A watch survives a round trip through its manifest")
    func encoding() throws {
        var watch = ShelfFolderWatch(name: "Invoices", path: "/tmp/x")
        watch.includesSubfolders = true
        watch.rules.match = .any
        watch.rules.rules = [rule(.name, .contains, text: "invoice")]
        let decoded = try JSONDecoder().decode(
            ShelfFolderWatch.self, from: JSONEncoder().encode(watch)
        )
        #expect(decoded == watch)
    }

    @Test("A watch names itself after its folder when it has no name")
    func naming() {
        #expect(ShelfFolderWatch(path: "/Users/x/Downloads").displayName == "Downloads")
        #expect(ShelfFolderWatch(name: "Invoices", path: "/Users/x/Downloads").displayName == "Invoices")
        #expect(ShelfFolderWatch(path: "/Users/x/Desktop", isScreenshotWatch: true)
            .displayName == "Screenshots")
    }
}
