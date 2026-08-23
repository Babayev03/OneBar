import AppKit
import Foundation
import Testing
@testable import OneBar

@Suite("Shelf lifecycle")
struct ShelfLifecycleTests {
    @Test("Legacy snapshots decode with migration defaults")
    func legacySnapshotDecode() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString,
            "items": [],
            "isPinned": true
        ])

        let snapshot = try JSONDecoder().decode(ShelfSnapshot.self, from: data)
        #expect(snapshot.id == id)
        #expect(snapshot.layout == .grid)
        #expect(snapshot.colorSource == .automatic)
        #expect(snapshot.keepInSpace == false)
        #expect(snapshot.isPinned)
    }

    @Test("Snapshot round trips identity and user color provenance")
    func snapshotRoundTrip() throws {
        let snapshot = ShelfSnapshot(
            id: UUID(),
            name: "Design",
            colorName: "purple",
            colorSource: .user,
            isPinned: true,
            layout: .list,
            keepInSpace: true
        )
        let decoded = try JSONDecoder().decode(
            ShelfSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(decoded.colorSource == .user)
        #expect(decoded.colorName == "purple")
    }

    @Test("Persisted shelf lists decode when older files omit a list")
    func persistedListMigration() throws {
        let data = try JSONSerialization.data(withJSONObject: ["pinned": []])
        let persisted = try JSONDecoder().decode(ShelfStore.Persisted.self, from: data)
        #expect(persisted.pinned.isEmpty)
        #expect(persisted.recent.isEmpty)
    }

    @Test("Pinned metadata survives an immediate store round trip")
    func pinnedStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneBarShelfTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ShelfStore(baseDirectory: root)
        let snapshot = ShelfSnapshot(
            id: UUID(),
            name: "Pinned",
            colorName: "orange",
            colorSource: .user,
            items: [ShelfItem(kind: .file, path: "/tmp/reference", title: "reference")],
            originX: 120,
            originY: 240,
            isPinned: true,
            layout: .list,
            keepInSpace: true
        )

        store.savePersisted(.init(pinned: [snapshot]))
        #expect(store.loadPersisted().pinned == [snapshot])
    }

    @Test("Pinned and recent transitions are bounded and reopenable")
    func archiveTransitions() {
        var pinned: [ShelfSnapshot] = []
        var recent: [ShelfSnapshot] = []
        let item = ShelfItem(kind: .file, path: "/tmp/reference", title: "reference")
        let pinnedShelf = ShelfSnapshot(id: UUID(), items: [item], isPinned: true)
        let recentShelf = ShelfSnapshot(id: UUID(), items: [item])
        let evictedShelf = ShelfSnapshot(id: UUID(), items: [item])

        #expect(ShelfArchiveLogic.recordClosed(
            pinnedShelf, pinned: &pinned, recent: &recent, recentLimit: 1
        ).isEmpty)
        #expect(pinned.map(\.id) == [pinnedShelf.id])

        _ = ShelfArchiveLogic.recordClosed(
            evictedShelf, pinned: &pinned, recent: &recent, recentLimit: 1
        )
        let evicted = ShelfArchiveLogic.recordClosed(
            recentShelf, pinned: &pinned, recent: &recent, recentLimit: 1
        )
        #expect(recent.map(\.id) == [recentShelf.id])
        #expect(evicted.count == 1)

        let reopened = ShelfArchiveLogic.take(
            id: pinnedShelf.id, pinned: &pinned, recent: &recent
        )
        #expect(reopened?.id == pinnedShelf.id)
        #expect(pinned.isEmpty)
    }

    @Test("Multi-selection survives drag start and collapses on click release")
    func selectionTransitions() {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        var selection: Set<UUID> = [ids[0], ids[1]]
        var anchor: UUID? = ids[0]

        ShelfSelectionLogic.mouseDown(
            on: ids[1], orderedIDs: ids, modifiers: [],
            selection: &selection, anchor: &anchor
        )
        #expect(selection == [ids[0], ids[1]])

        ShelfSelectionLogic.mouseUpWithoutDrag(
            on: ids[1], modifiers: [], selection: &selection, anchor: &anchor
        )
        #expect(selection == [ids[1]])

        ShelfSelectionLogic.mouseDown(
            on: ids[3], orderedIDs: ids, modifiers: [.shift],
            selection: &selection, anchor: &anchor
        )
        #expect(selection == Set(ids[1...3]))
        #expect(anchor == ids[1])

        ShelfSelectionLogic.mouseDown(
            on: ids[0], orderedIDs: ids, modifiers: [.command],
            selection: &selection, anchor: &anchor
        )
        #expect(selection == Set(ids))
        #expect(anchor == ids[0])
    }

    @Test("Selection modifiers suppress double-click opening")
    func modifiedDoubleClick() {
        #expect(ShelfSelectionLogic.shouldOpen(clickCount: 2, modifiers: []))
        #expect(!ShelfSelectionLogic.shouldOpen(clickCount: 2, modifiers: [.command]))
        #expect(!ShelfSelectionLogic.shouldOpen(clickCount: 2, modifiers: [.shift]))
        #expect(!ShelfSelectionLogic.shouldOpen(clickCount: 1, modifiers: []))
    }

    @Test("Duplicate identity follows item semantics")
    func duplicateIdentity() {
        let file = ShelfItem(kind: .file, path: "/tmp/a", title: "A")
        let sameFile = ShelfItem(kind: .file, path: "/tmp/a", title: "Renamed title")
        let text = ShelfItem(kind: .text, text: "hello", title: "hello")
        let sameText = ShelfItem(kind: .text, text: "hello", title: "hello again")
        let malformedLink = ShelfItem(kind: .link, title: "missing URL")
        #expect(file.hasSameShelfIdentity(as: sameFile))
        #expect(text.hasSameShelfIdentity(as: sameText))
        #expect(!file.hasSameShelfIdentity(as: text))
        #expect(!malformedLink.hasSameShelfIdentity(as: text))
    }

    @Test("Store deletes only OneBar-owned materializations")
    func deletionBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneBarShelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ShelfStore(baseDirectory: root.appendingPathComponent("support"))
        let ownedURL = try #require(store.materialise(Data("owned".utf8), name: "owned.txt"))
        let outsideURL = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outsideURL)

        store.discard([
            ShelfItem(kind: .text, path: ownedURL.path, title: "owned", isMaterialised: true),
            ShelfItem(kind: .text, path: outsideURL.path, title: "outside", isMaterialised: true)
        ])

        #expect(!FileManager.default.fileExists(atPath: ownedURL.path))
        #expect(FileManager.default.fileExists(atPath: outsideURL.path))

        let promised = try #require(store.promiseDestination())
        store.discardPromiseDestination(outsideURL.deletingLastPathComponent())
        store.discardPromiseDestination(promised)
        #expect(!FileManager.default.fileExists(atPath: promised.path))
        #expect(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    @Test("Rejected duplicates do not delete a retained materialization")
    func retainedDuplicateSafety() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneBarShelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ShelfStore(baseDirectory: root.appendingPathComponent("support"))
        let url = try #require(store.materialise(Data("same".utf8), name: "same.txt"))
        let item = ShelfItem(
            kind: .text,
            path: url.path,
            text: "same",
            title: "same",
            isMaterialised: true
        )

        store.discard([item], keeping: [item])
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
