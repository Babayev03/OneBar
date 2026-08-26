import AppKit
import Foundation
import Testing
@testable import OneBar

@Suite("Shelf window behavior")
struct ShelfWindowBehaviorTests {
    @Test("Shake and notch activation are independent")
    func activationModes() {
        #expect(ShelfActivationMode(
            shelfEnabled: false, shakeEnabled: true, notchEnabled: true
        ) == .inactive)
        #expect(ShelfActivationMode(
            shelfEnabled: true, shakeEnabled: true, notchEnabled: false
        ) == .shakeOnly)
        #expect(ShelfActivationMode(
            shelfEnabled: true, shakeEnabled: false, notchEnabled: true
        ) == .notchOnly)
        #expect(ShelfActivationMode(
            shelfEnabled: true, shakeEnabled: true, notchEnabled: true
        ) == .shakeAndNotch)
        #expect(ShelfActivationMode.notchOnly.observesDrags)
        #expect(!ShelfActivationMode.notchOnly.recognizesShake)
        #expect(ShelfActivationMode.notchOnly.showsNotch)
    }

    @Test("Notch highlight modes follow drag and hover state")
    func notchHighlightModes() {
        #expect(NotchHighlight.whileDragging.visualState(
            dragActive: true, targeted: false
        ) == .ambient)
        #expect(NotchHighlight.whileDragging.visualState(
            dragActive: true, targeted: true
        ) == .targeted)
        #expect(NotchHighlight.whileDragging.visualState(
            dragActive: false, targeted: true
        ) == .targeted)
        #expect(NotchHighlight.whileDragging.visualState(
            dragActive: false, targeted: false
        ) == .hidden)
        #expect(NotchHighlight.onHover.visualState(
            dragActive: true, targeted: false
        ) == .hidden)
        #expect(NotchHighlight.onHover.visualState(
            dragActive: false, targeted: true
        ) == .targeted)
        #expect(NotchHighlight.never.visualState(
            dragActive: true, targeted: true
        ) == .hidden)

        #expect(NotchHighlight.whileDragging.isVisible(dragActive: true, targeted: false))
        #expect(NotchHighlight.whileDragging.isVisible(dragActive: false, targeted: true))
        #expect(!NotchHighlight.whileDragging.isVisible(dragActive: false, targeted: false))
        #expect(NotchHighlight.onHover.isVisible(dragActive: false, targeted: true))
        #expect(!NotchHighlight.onHover.isVisible(dragActive: true, targeted: false))
        #expect(!NotchHighlight.never.isVisible(dragActive: true, targeted: true))
    }

    @Test("Internal transfers move by default and copy with Option")
    func transferDecisions() {
        let existing = ShelfItem(kind: .file, path: "/tmp/a", title: "A")
        let duplicate = ShelfItem(kind: .file, path: "/tmp/a", title: "A again")
        let newItem = ShelfItem(kind: .file, path: "/tmp/b", title: "B")
        let resolution = ShelfTransferLogic.resolve(
            incoming: [duplicate, newItem],
            existing: [existing]
        )

        #expect(resolution.accepted == [newItem])
        #expect(resolution.rejected == [duplicate])
        #expect(ShelfTransferLogic.operation(optionDown: false) == .move)
        #expect(ShelfTransferLogic.operation(optionDown: true) == .copy)
        #expect(ShelfTransferLogic.sourceIDsToRemove(
            accepted: resolution.accepted, operation: .move
        ) == [newItem.id])
        #expect(ShelfTransferLogic.sourceIDsToRemove(
            accepted: resolution.accepted, operation: .copy
        ).isEmpty)
        #expect(!ShelfTransferLogic.shouldApplyCloseBehavior(
            afterInternalTransfer: true,
            remainingItemCount: 1
        ))
        #expect(ShelfTransferLogic.shouldApplyCloseBehavior(
            afterInternalTransfer: true,
            remainingItemCount: 0
        ))
        #expect(ShelfTransferLogic.shouldApplyCloseBehavior(
            afterInternalTransfer: false,
            remainingItemCount: 1
        ))
    }

    @Test("Copy clones owned materializations but only references user files")
    func materializedCopyOwnership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneBarShelfTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(baseDirectory: root)

        let originalURL = try #require(store.materialise(Data("owned".utf8), name: "owned.txt"))
        let original = ShelfItem(
            kind: .text,
            path: originalURL.path,
            bookmark: try? originalURL.bookmarkData(),
            text: "owned",
            title: "owned",
            isMaterialised: true
        )
        let clone = try #require(store.copyForShelf(original))
        let clonePath = try #require(clone.path)

        #expect(clone.id != original.id)
        #expect(clone.isMaterialised)
        #expect(clonePath != originalURL.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: clonePath)) == Data("owned".utf8))

        store.discard([original])
        #expect(!FileManager.default.fileExists(atPath: originalURL.path))
        #expect(FileManager.default.fileExists(atPath: clonePath))

        let reference = ShelfItem(kind: .file, path: "/tmp/user-file", title: "user-file")
        let referenceCopy = try #require(store.copyForShelf(reference))
        #expect(referenceCopy.id != reference.id)
        #expect(referenceCopy.path == reference.path)
        #expect(!referenceCopy.isMaterialised)
    }

    @Test("Sibling promised files receive independent ownership directories")
    func promisedFileIsolation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneBarShelfTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(baseDirectory: root)
        let batch = try #require(store.promiseDestination())
        let first = batch.appendingPathComponent("first.txt")
        let second = batch.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let adoptedFirst = try #require(store.adoptPromisedFile(at: first, from: batch))
        let adoptedSecond = try #require(store.adoptPromisedFile(at: second, from: batch))
        #expect(adoptedFirst.deletingLastPathComponent() != adoptedSecond.deletingLastPathComponent())

        store.discard([ShelfItem(
            kind: .file,
            path: adoptedFirst.path,
            title: "first",
            isMaterialised: true
        )])
        #expect(!FileManager.default.fileExists(atPath: adoptedFirst.path))
        #expect(FileManager.default.fileExists(atPath: adoptedSecond.path))
    }

    @Test("Dock, retract, restore, clamp, and snap geometry is stable")
    func windowGeometry() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let frame = NSRect(x: 400, y: 200, width: 300, height: 220)

        let leftDock = ShelfWindowGeometry.collapsed(frame, mode: .docked, edge: .left, in: visible)
        let rightDock = ShelfWindowGeometry.collapsed(frame, mode: .docked, edge: .right, in: visible)
        let rightRetract = ShelfWindowGeometry.collapsed(frame, mode: .retracted, edge: .right, in: visible)
        #expect(leftDock.minX == -276)
        #expect(rightDock.minX == 976)
        #expect(rightRetract.minX == 904)
        #expect(ShelfWindowGeometry.rested(leftDock, edge: .left, in: visible).minX == 8)
        #expect(ShelfWindowGeometry.rested(rightDock, edge: .right, in: visible).minX == 692)
        #expect(ShelfWindowGeometry.edgeAttached(leftDock, edge: .left, in: visible).minX == 0)
        #expect(ShelfWindowGeometry.edgeAttached(rightDock, edge: .right, in: visible).minX == 700)

        let stackedRight = ShelfWindowGeometry.collapsed(
            frame,
            mode: .retracted,
            edge: .right,
            in: visible,
            stackDepth: 1
        )
        #expect(stackedRight.minX == 780)
        let frontInteraction = ShelfWindowGeometry.collapsedInteractionFrame(
            rightRetract,
            mode: .retracted,
            edge: .right,
            stackDepth: 0
        )
        let backInteraction = ShelfWindowGeometry.collapsedInteractionFrame(
            stackedRight,
            mode: .retracted,
            edge: .right,
            stackDepth: 1
        )
        #expect(frontInteraction.width == 96)
        #expect(backInteraction.width == ShelfWindowGeometry.collapseStackOffset)
        #expect(backInteraction.maxX == frontInteraction.minX)
        let peekedBack = ShelfWindowGeometry.peeked(
            stackedRight,
            mode: .retracted,
            edge: .right,
            in: visible,
            stackDepth: 1
        )
        #expect(peekedBack.maxX == frontInteraction.minX)
        #expect(!peekedBack.intersects(frontInteraction))
        #expect(!ShelfCollapse.docked.revealsOnPointerHover)
        #expect(ShelfCollapse.retracted.revealsOnPointerHover)

        let currentSpace = ShelfWindowGeometry.collectionBehavior(keepInCurrentSpace: true)
        #expect(!currentSpace.contains(.moveToActiveSpace))
        #expect(!currentSpace.contains(.canJoinAllSpaces))
        #expect(currentSpace.contains(.fullScreenAuxiliary))
        let everySpace = ShelfWindowGeometry.collectionBehavior(keepInCurrentSpace: false)
        #expect(everySpace.contains(.canJoinAllSpaces))

        let topRight = NSRect(x: 692, y: 572, width: 300, height: 220)
        let nextShelf = ShelfWindowGeometry.avoidingOverlap(
            topRight,
            in: visible,
            occupiedFrames: [topRight]
        )
        #expect(!topRight.insetBy(dx: -12, dy: -12).intersects(nextShelf))
        #expect(nextShelf != topRight)
        #expect(nextShelf.minX == topRight.minX)

        let retractedFirst = ShelfWindowGeometry.collapsed(
            topRight,
            mode: .retracted,
            edge: .right,
            in: visible
        )
        let besideRetractedShelf = ShelfWindowGeometry.avoidingOverlap(
            topRight,
            in: visible,
            occupiedFrames: [retractedFirst]
        )
        #expect(besideRetractedShelf.minX == topRight.minX)
        #expect(besideRetractedShelf.minY != topRight.minY)
        let retractedSecond = ShelfWindowGeometry.collapsed(
            besideRetractedShelf,
            mode: .retracted,
            edge: .right,
            in: visible
        )
        #expect(!retractedFirst.insetBy(dx: 0, dy: -12).intersects(retractedSecond))

        let unchanged = ShelfWindowGeometry.avoidingOverlap(
            topRight,
            in: visible,
            occupiedFrames: [NSRect(x: 8, y: 8, width: 300, height: 220)]
        )
        #expect(unchanged == topRight)

        let offscreen = NSRect(x: 990, y: 790, width: 300, height: 220)
        let clamped = ShelfWindowGeometry.clamped(offscreen, to: visible)
        #expect(clamped.origin == NSPoint(x: 692, y: 572))

        let other = NSRect(x: 400, y: 300, width: 290, height: 200)
        let nearOther = NSRect(x: 701, y: 302, width: 200, height: 160)
        let snapped = ShelfWindowGeometry.snapped(
            nearOther,
            to: visible,
            otherFrames: [other]
        )
        #expect(snapped.minX == other.maxX + ShelfWindowGeometry.margin)
        #expect(snapped.minY == other.minY)

        #expect(ShelfWindowGeometry.shouldSnap(
            isRealUserMove: true,
            enabled: true,
            isCollapsed: false,
            commandSuppressed: false
        ))
        #expect(!ShelfWindowGeometry.shouldSnap(
            isRealUserMove: false,
            enabled: true,
            isCollapsed: false,
            commandSuppressed: false
        ))
        #expect(!ShelfWindowGeometry.shouldSnap(
            isRealUserMove: true,
            enabled: true,
            isCollapsed: false,
            commandSuppressed: true
        ))

        let notch = ShelfWindowGeometry.notchTargetRect(
            screenFrame: NSRect(x: 0, y: 0, width: 1_512, height: 982),
            safeAreaTop: 32,
            auxiliaryLeft: NSRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryRight: NSRect(x: 848, y: 950, width: 664, height: 32)
        )
        // The obscured housing is exactly the gap between the auxiliary
        // areas (663...848), padded only by the transparent glow outset.
        #expect(notch == NSRect(x: 633, y: 908, width: 245, height: 74))
        let idleNotch = ShelfWindowGeometry.notchTargetRect(
            screenFrame: NSRect(x: 0, y: 0, width: 1_512, height: 982),
            safeAreaTop: 32,
            auxiliaryLeft: NSRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryRight: NSRect(x: 848, y: 950, width: 664, height: 32),
            activationDepth: 0
        )
        #expect(idleNotch == NSRect(x: 633, y: 950, width: 245, height: 32))

        let noNotch = ShelfWindowGeometry.notchTargetRect(
            screenFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            safeAreaTop: 0,
            auxiliaryLeft: NSRect(x: 0, y: 900, width: 720, height: 0),
            auxiliaryRight: NSRect(x: 720, y: 900, width: 720, height: 0)
        )
        #expect(noNotch == nil)
    }

    @Test("Dock handle labels use shelf identity and summarize multiple items")
    func dockHandleLabels() {
        #expect(ShelfHandlePresentation.label(
            shelfName: "Project Files",
            itemTitles: ["First.txt", "Second.txt"],
            fallback: "Shelf"
        ) == "Project Files")
        #expect(ShelfHandlePresentation.label(
            shelfName: nil,
            itemTitles: ["First.txt"],
            fallback: "Shelf"
        ) == "First.txt")
        #expect(ShelfHandlePresentation.label(
            shelfName: nil,
            itemTitles: ["First.txt", "Second.txt", "Third.txt"],
            fallback: "Shelf"
        ) == "First.txt + 2 more")
        #expect(ShelfHandlePresentation.label(
            shelfName: "   ",
            itemTitles: [],
            fallback: "Shelf"
        ) == "Shelf")

        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let size = NSSize(width: 180, height: 34)
        let leftShelf = NSRect(x: -276, y: 300, width: 300, height: 200)
        let rightShelf = NSRect(x: 976, y: 300, width: 300, height: 200)
        let leftLabel = ShelfHandlePresentation.labelFrame(
            size: size,
            shelfFrame: leftShelf,
            edge: .left,
            visibleFrame: visible
        )
        let rightLabel = ShelfHandlePresentation.labelFrame(
            size: size,
            shelfFrame: rightShelf,
            edge: .right,
            visibleFrame: visible
        )
        #expect(leftLabel.minX == 32)
        #expect(rightLabel.maxX == 968)
        #expect(leftLabel.midY == leftShelf.midY)
        #expect(rightLabel.midY == rightShelf.midY)
    }

    @Test("Disconnected-display recovery follows the cursor")
    func displayRecovery() {
        let first = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let second = NSRect(x: 1_000, y: 0, width: 1_000, height: 800)
        let disconnected = NSRect(x: 2_500, y: 200, width: 300, height: 220)
        #expect(ShelfWindowGeometry.targetVisibleFrame(
            for: disconnected,
            visibleFrames: [first, second],
            cursor: NSPoint(x: 1_500, y: 400)
        ) == second)
    }
}

@Suite("Retract packing")
struct ShelfRetractPackingTests {
    private let visible = NSRect(x: 0, y: 0, width: 1500, height: 900)

    @Test("The first shelf takes the top of the column")
    func firstTakesTop() {
        let row = ShelfWindowGeometry.firstFreeRow(height: 200, in: visible, occupiedRows: [])
        #expect(row == 900 - 200 - ShelfWindowGeometry.margin)
    }

    @Test("Later shelves fill downward instead of piling on the first")
    func fillsDownward() throws {
        var occupied: [ClosedRange<CGFloat>] = []
        var rows: [CGFloat] = []
        for _ in 0..<4 {
            let row = try #require(
                ShelfWindowGeometry.firstFreeRow(height: 200, in: visible, occupiedRows: occupied)
            )
            rows.append(row)
            occupied.append(row...(row + 200))
        }
        // Strictly descending, and never overlapping what is already there.
        #expect(rows == rows.sorted(by: >))
        for (index, row) in rows.enumerated().dropFirst() {
            #expect(row + 200 < rows[index - 1])
        }
    }

    @Test("A full column reports no room, which is the cue to stack")
    func fullColumn() {
        // Four 200pt shelves plus spacing do not leave a fifth row in 900pt.
        var occupied: [ClosedRange<CGFloat>] = []
        var placed = 0
        while let row = ShelfWindowGeometry.firstFreeRow(
            height: 200, in: visible, occupiedRows: occupied
        ) {
            occupied.append(row...(row + 200))
            placed += 1
            if placed > 10 { break }
        }
        #expect(placed == 4)
        #expect(ShelfWindowGeometry.firstFreeRow(
            height: 200, in: visible, occupiedRows: occupied
        ) == nil)
    }

    @Test("A gap left by a closed shelf is reused before the bottom")
    func reusesGaps() throws {
        let top = 900 - 200 - ShelfWindowGeometry.margin
        // The top row is free; the one under it is taken.
        let second = top - 10 - 200
        let row = try #require(ShelfWindowGeometry.firstFreeRow(
            height: 200, in: visible, occupiedRows: [second...(second + 200)]
        ))
        #expect(row == top)
    }

    @Test("A shelf taller than the display gets no row at all")
    func tooTall() {
        #expect(ShelfWindowGeometry.firstFreeRow(
            height: 2000, in: visible, occupiedRows: []
        ) == nil)
    }
}
