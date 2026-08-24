import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// The shelf panel's content view: an AppKit drop target that hosts the SwiftUI
/// shelf on top of itself.
///
/// AppKit rather than SwiftUI's `.dropDestination` because we need the raw
/// `NSDraggingInfo` — for the promise receiver, and to read what the source is
/// actually offering.
final class ShelfDropView: NSView {
    weak var controller: ShelfController?

    static let acceptedTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL, .URL, .string, .rtf, .rtfd, .png, .tiff, .html
        ]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })
        return types
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = operation(for: sender)
        controller?.model.isDropTargeted = !operation.isEmpty
        if !operation.isEmpty { controller?.peek(true) }
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = operation(for: sender)
        controller?.model.isDropTargeted = !operation.isEmpty
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.model.isDropTargeted = false
        controller?.peekAfterDelay()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.model.isDropTargeted = false
        controller?.peekAfterDelay()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !operation(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.model.isDropTargeted = false
        guard let controller else { return false }

        if let source = sender.draggingSource as? ShelfDragSourceView,
           let sourceController = source.controller {
            let transferred = ShelfManager.shared.transfer(
                source.draggedItems,
                from: sourceController,
                to: controller,
                operation: transferOperation()
            )
            controller.peekAfterDelay()
            return transferred
        }

        ShelfItemReader.read(from: sender) { [weak controller] items in
            guard let controller, controller.isActive else {
                ShelfStore.shared.discard(items)
                return
            }
            controller.add(items)
            controller.peekAfterDelay()
        }
        return true
    }

    // MARK: - Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !(controller?.previewURLs.isEmpty ?? true)
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = controller?.previewSelectionIndex ?? 0
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        controller?.previewDidEnd()
    }

    /// A drag out of our own shelf is a rearrange, not a copy of the file into
    /// itself, and offering `.copy` there would let Finder duplicate it.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        if let source = sender.draggingSource as? ShelfDragSourceView {
            guard source.controller !== controller,
                  controller?.canAccept(source.draggedItems) == true
            else { return [] }
            return transferOperation().dragOperation
        }
        return .copy
    }

    private func transferOperation() -> ShelfTransferOperation {
        ShelfTransferLogic.currentOperation()
    }
}

extension ShelfDropView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        controller?.previewURLs.count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let urls = controller?.previewURLs, urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}

/// Turns a drag into shelf items.
@MainActor
enum ShelfItemReader {
    /// `completion` runs on the main actor, possibly more than once: promised
    /// files arrive after the drop has already been accepted.
    static func read(from info: NSDraggingInfo, completion: @escaping @MainActor ([ShelfItem]) -> Void) {
        let pasteboard = info.draggingPasteboard

        // File URLs first: they are the common case and the only kind that can
        // be referenced rather than copied.
        if let items = fileItems(from: pasteboard) {
            completion(items)
            return
        }

        // Photos, Mail and some browsers hand over a promise instead of a file.
        // Without this those drops silently produce nothing at all.
        if let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            receivePromises(receivers, completion: completion)
            return
        }

        read(from: pasteboard, completion: completion)
    }

    /// The equivalent reader for Add/New From Clipboard, where file promises
    /// cannot occur.
    static func read(
        from pasteboard: NSPasteboard,
        completion: @escaping @MainActor ([ShelfItem]) -> Void
    ) {
        if let items = fileItems(from: pasteboard) {
            completion(items)
        } else if let item = imageItem(from: pasteboard) {
            completion([item])
        } else if let item = linkItem(from: pasteboard) {
            completion([item])
        } else if let item = textItem(from: pasteboard) {
            completion([item])
        } else {
            completion([])
        }
    }

    private static func fileItems(from pasteboard: NSPasteboard) -> [ShelfItem]? {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return nil }
        let items = urls.compactMap { fileItem(for: $0) }
        return items.isEmpty ? nil : items
    }

    // MARK: - Item builders

    static func fileItem(for url: URL) -> ShelfItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let isImage = (try? url.resourceValues(forKeys: [.contentTypeKey]))?
            .contentType?.conforms(to: .image) ?? false
        return ShelfItem(
            kind: isImage ? .image : .file,
            path: url.path,
            bookmark: try? url.bookmarkData(),
            title: url.lastPathComponent,
            byteSize: ShelfStore.shared.fileSize(of: url)
        )
    }

    private static func receivePromises(
        _ receivers: [NSFilePromiseReceiver],
        completion: @escaping @MainActor ([ShelfItem]) -> Void
    ) {
        guard let destination = ShelfStore.shared.promiseDestination() else {
            completion([])
            return
        }
        let queue = OperationQueue()
        // Calling in a promise populates `fileNames`, and one legacy receiver
        // can represent several files. Hold callbacks until the true expected
        // count is known so the queue cannot be released after the first file.
        queue.isSuspended = true
        let deliveryID = UUID()
        promiseQueues[deliveryID] = queue
        var remaining = 0
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: destination,
                options: [:],
                operationQueue: queue
            ) { url, error in
                Task { @MainActor in
                    defer {
                        remaining -= 1
                        if remaining == 0 {
                            promiseQueues[deliveryID] = nil
                            ShelfStore.shared.discardPromiseDestination(destination)
                        }
                    }
                    guard error == nil,
                          let adoptedURL = ShelfStore.shared.adoptPromisedFile(
                            at: url,
                            from: destination
                          ),
                          var item = fileItem(for: adoptedURL)
                    else { return }
                    item.isMaterialised = true
                    completion([item])
                }
            }
            // AppKit promises a callback even for cancellation or failure.
            // Broken legacy providers sometimes omit names, so retain one
            // expected callback for that receiver as a safe fallback.
            remaining += max(receiver.fileNames.count, 1)
        }
        queue.isSuspended = false
    }

    private static var promiseQueues: [UUID: OperationQueue] = [:]

    private static func imageItem(from pasteboard: NSPasteboard) -> ShelfItem? {
        let png: Data?
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let tiff = pasteboard.data(forType: .tiff) {
            // Written out as PNG so the file that lands in Finder is one
            // anything can open, rather than a pasteboard-flavoured TIFF.
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png else { return nil }

        let name = "Image \(timestamp()).png"
        guard let url = ShelfStore.shared.materialise(png, name: name) else { return nil }
        var item = fileItem(for: url)
        item?.kind = .image
        item?.isMaterialised = true
        item?.title = name
        return item
    }

    private static func linkItem(from pasteboard: NSPasteboard) -> ShelfItem? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let url = urls.first(where: { !$0.isFileURL })
        else { return nil }
        let title = pasteboard.string(forType: .urlName) ?? url.host ?? url.absoluteString
        return ShelfItem(
            kind: .link,
            linkString: url.absoluteString,
            title: title
        )
    }

    private static func textItem(from pasteboard: NSPasteboard) -> ShelfItem? {
        let plain = AppState.shared.shelfPlainText
        let rtf = plain ? nil : (pasteboard.data(forType: .rtf) ?? pasteboard.data(forType: .rtfd))
        guard let string = pasteboard.string(forType: .string), !string.isEmpty else { return nil }

        let title = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1)
            .first
            .map { String($0.prefix(60)) } ?? "Text"

        // Materialised straight away so it can be dragged into Finder as a
        // file. Keeping only the string would make the shelf a one-way trip
        // into text fields.
        let ext = rtf == nil ? "txt" : "rtf"
        let data = rtf ?? Data(string.utf8)
        let url = ShelfStore.shared.materialise(data, name: "\(title).\(ext)")

        return ShelfItem(
            kind: .text,
            path: url?.path,
            bookmark: url.flatMap { try? $0.bookmarkData() },
            text: string,
            rtfData: rtf,
            title: title,
            byteSize: data.count,
            isMaterialised: url != nil
        )
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}

private extension NSPasteboard.PasteboardType {
    static let urlName = NSPasteboard.PasteboardType("public.url-name")
}
