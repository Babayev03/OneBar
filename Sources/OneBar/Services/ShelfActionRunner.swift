import AppKit
import Foundation

/// Performs a shelf action against a set of items.
///
/// Every action here is a wrapper over something the system already does —
/// `NSWorkspace`, the share sheet, `FileManager`. Nothing writes a new file, so
/// nothing can leave one behind.
@MainActor
enum ShelfActionRunner {
    static func subject(
        for scope: ShelfActionScope,
        in controller: ShelfController
    ) -> ShelfActionSubject {
        ShelfActionSubject(
            items: scope == .selection ? controller.actionItems : [],
            shelfItemCount: controller.model.items.count
        )
    }

    static func perform(
        _ action: ShelfAction,
        scope: ShelfActionScope,
        in controller: ShelfController,
        anchoredTo view: NSView? = nil
    ) {
        let subject = subject(for: scope, in: controller)
        guard action.isAvailable(for: subject) else { return }

        switch action {
        case .open:
            open(subject.activationURLs)
        case .openWith:
            // Reached through the submenu, which carries the chosen app.
            break
        case .quickLook:
            controller.quickLook()
        case .showInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(subject.fileURLs)
        case .rename:
            guard let item = subject.items.first else { return }
            controller.beginRename(item.id)
        case .copy:
            controller.copySelection()
        case .addFromClipboard:
            controller.addFromClipboard()
        case .moveToNewShelf:
            transfer(subject.items, from: controller, operation: .move)
        case .copyToNewShelf:
            transfer(subject.items, from: controller, operation: .copy)
        case .share:
            share(subject, anchoredTo: view ?? controller.anchorView)
        case .compress:
            let urls = subject.fileURLs
            let folder = defaultFolder
            produce(in: controller, activity: "Compressing…", success: "Compressed") {
                [try await ShelfTransforms.compress(urls, in: folder)]
            }
        case .removeMetadata:
            let urls = subject.imageURLs
            let folder = defaultFolder
            produce(in: controller, activity: "Stripping…", success: "Metadata removed") {
                try await ShelfTransforms.removeMetadata(urls, in: folder)
            }
        case .getInfo:
            showInfo(subject.items, from: controller)
        case .copyPath:
            copyPaths(subject.fileURLs)
        case .convertImage, .resizeImage:
            // Reached through the submenu, which carries the preset or opens
            // the custom panel.
            break
        case .mergePDF:
            let urls = subject.printableURLs
            let folder = defaultFolder
            produce(in: controller, activity: "Merging…", success: "Merged to PDF") {
                [try await ShelfTransforms.mergePDF(urls, in: folder)]
            }
        case .moveToTrash:
            trash(subject, in: controller)
        case .removeFromShelf:
            controller.remove(Set(subject.items.map(\.id)))
        case .clearShelf:
            controller.clear()
        }
    }

    // MARK: - Opening

    private static func open(_ urls: [URL]) {
        for url in uniqued(urls) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Apps offered by Open With: every app that can open *all* the selected
    /// files, so a chosen app never silently skips half of them. The default
    /// app for the first file leads, as it does in Finder.
    static func applications(openingAllOf urls: [URL]) -> [URL] {
        let urls = uniqued(urls)
        guard let first = urls.first else { return [] }
        var shared = NSWorkspace.shared.urlsForApplications(toOpen: first)
        for url in urls.dropFirst() {
            let next = Set(NSWorkspace.shared.urlsForApplications(toOpen: url))
            shared = shared.filter { next.contains($0) }
        }
        guard let preferred = NSWorkspace.shared.urlForApplication(toOpen: first),
              let index = shared.firstIndex(of: preferred)
        else { return shared }
        var ordered = shared
        ordered.remove(at: index)
        ordered.insert(preferred, at: 0)
        return ordered
    }

    static func openWith(application: URL, scope: ShelfActionScope, in controller: ShelfController) {
        let urls = uniqued(subject(for: scope, in: controller).fileURLs)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - Shelf to shelf

    private static func transfer(
        _ items: [ShelfItem],
        from controller: ShelfController,
        operation: ShelfTransferOperation
    ) {
        guard !items.isEmpty, let destination = ShelfManager.shared.newShelf(at: nil) else { return }
        let moved = ShelfManager.shared.transfer(
            items,
            from: controller,
            to: destination,
            operation: operation
        )
        if !moved { HUD.show("Nothing was transferred", symbol: "tray") }
    }

    // MARK: - Command bar

    static func showCommandBar(in controller: ShelfController) {
        let subject = subject(for: .selection, in: controller)
        let commands = ShelfCommandSearch.commands(for: subject)
        guard !commands.isEmpty else { return }
        ShelfDialog.shared.present(
            title: nil,
            subtitle: nil,
            width: 380,
            near: controller.anchorView?.window
        ) {
            ShelfCommandBarView(controller: controller, commands: commands)
        }
    }

    /// A chosen row. Presets act immediately; the two actions that own a
    /// submenu open their dialog, since a flat list cannot nest.
    static func run(_ command: ShelfCommand, in controller: ShelfController) {
        switch command.kind {
        case .action(let action):
            if action == .convertImage || action == .resizeImage {
                customImageRequest(action, scope: .selection, in: controller)
            } else {
                perform(action, scope: .selection, in: controller)
            }
        case .convert(let format):
            let urls = subject(for: .selection, in: controller).imageURLs
            convertImages(
                ImageActionRequest(
                    urls: urls,
                    format: format,
                    folder: defaultFolder,
                    reveal: AppState.shared.shelfOutputReveal
                ),
                in: controller
            )
        case .resize(let resize):
            let urls = subject(for: .selection, in: controller).imageURLs
            convertImages(
                ImageActionRequest(
                    urls: urls,
                    resize: resize,
                    folder: defaultFolder,
                    reveal: AppState.shared.shelfOutputReveal
                ),
                in: controller
            )
        }
    }

    // MARK: - Information

    private static func showInfo(_ items: [ShelfItem], from controller: ShelfController) {
        guard !items.isEmpty else { return }
        ShelfDialog.shared.present(
            title: items.count == 1 ? items[0].title : "\(items.count) items",
            subtitle: nil,
            width: 340,
            near: controller.anchorView?.window
        ) {
            ShelfInfoView(items: items)
        }
    }

    private static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        HUD.show(urls.count == 1 ? "Path copied" : "\(urls.count) paths copied", symbol: "link")
    }

    // MARK: - Transforms

    /// The folder the user last chose, if it is still there. A folder that has
    /// been moved or unmounted falls back rather than failing every action.
    static var defaultFolder: URL? {
        let path = AppState.shared.shelfOutputFolder
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return URL(filePath: path)
    }

    /// Runs a preset straight from the menu.
    static func convertImages(_ request: ImageActionRequest, in controller: ShelfController) {
        guard !request.urls.isEmpty else { return }
        produce(
            in: controller,
            activity: "Converting…",
            success: "Converted",
            reveal: request.reveal
        ) {
            try await ShelfTransforms.convert(request)
        }
    }

    /// Opens the dialog rather than acting, seeded from the selection.
    static func customImageRequest(
        _ action: ShelfAction,
        scope: ShelfActionScope,
        in controller: ShelfController
    ) {
        let urls = subject(for: scope, in: controller).imageURLs
        guard !urls.isEmpty else { return }
        let request = ImageActionRequest(
            urls: urls,
            format: action == .resizeImage ? nil : .jpeg,
            resize: action == .resizeImage ? .longestEdge(1024) : .original,
            folder: defaultFolder,
            reveal: AppState.shared.shelfOutputReveal
        )
        ShelfDialog.shared.present(
            title: action == .resizeImage ? "Resize Image" : "Convert Image Format",
            subtitle: action == .resizeImage
                ? "Scale an image down to the size you choose."
                : "Convert the format of an image to the specified format.",
            width: 340,
            near: controller.anchorView?.window
        ) {
            ShelfImageDialogView(controller: controller, action: action, request: request)
        }
    }

    /// The one path for everything that writes a file: hold the shelf busy, do
    /// the work off the main actor, then put the results on the shelf so they
    /// can be dragged straight out. The originals are left exactly as they were.
    private static func produce(
        in controller: ShelfController,
        activity: String,
        success: String,
        reveal: ShelfOutputReveal? = nil,
        work: @escaping @Sendable () async throws -> [URL]
    ) {
        let reveal = reveal ?? AppState.shared.shelfOutputReveal
        switch controller.beginActivity(activity) {
        case .started:
            break
        case .busy:
            HUD.show("Still working on the last action", symbol: "hourglass")
            return
        case .gone:
            HUD.show("That shelf has closed", symbol: "tray")
            return
        }
        let task = Task { @MainActor in
            defer { controller.endActivity() }
            do {
                // Called directly rather than through `Task.detached`, which is
                // deliberately independent of its parent: cancelling this task
                // would not have reached the work at all, so Stop would have
                // cleared the footer while the run carried on. `work` is
                // nonisolated, so it leaves the main actor on its own.
                let produced = try await work()
                guard controller.isActive, !Task.isCancelled else { return }
                guard !produced.isEmpty else {
                    HUD.show("Nothing was produced", symbol: "exclamationmark.triangle")
                    return
                }
                if reveal.addsToShelf {
                    controller.add(produced.compactMap { ShelfItemReader.fileItem(for: $0) })
                }
                if reveal.revealsInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting(produced)
                }
                HUD.show(success, symbol: "checkmark.circle.fill")
            } catch {
                guard controller.isActive, !Task.isCancelled else { return }
                HUD.show(
                    (error as? ShelfTransformError)?.errorDescription ?? "The action failed",
                    symbol: "exclamationmark.triangle"
                )
            }
        }
        controller.registerActivity(task)
    }

    // MARK: - Sharing

    private static func share(_ subject: ShelfActionSubject, anchoredTo view: NSView?) {
        let items = shareableItems(in: subject)
        guard !items.isEmpty, let view, view.window != nil else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }

    /// URLs where there are files or links, and raw strings for text that never
    /// made it to disk — the share sheet takes both.
    static func shareableItems(in subject: ShelfActionSubject) -> [Any] {
        var shareable: [Any] = []
        for item in subject.items {
            if let url = item.activationURL {
                shareable.append(url)
            } else if item.kind == .text, let text = item.text, !text.isEmpty {
                shareable.append(text)
            }
        }
        return shareable
    }

    // MARK: - Trashing

    /// Trashes the user's own files and takes every acted-on item off the shelf.
    /// Materialised items have no file worth trashing, and `remove` deletes
    /// those from Application Support anyway.
    private static func trash(_ subject: ShelfActionSubject, in controller: ShelfController) {
        let owned = Set(subject.items.filter(\.isMaterialised).map(\.id))
        let byURL = Dictionary(
            subject.items.compactMap { item -> (String, UUID)? in
                guard !item.isMaterialised, let url = item.resolveURL() else { return nil }
                return (url.standardizedFileURL.path, item.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let urls = subject.userFileURLs
        guard !urls.isEmpty else { return }

        NSWorkspace.shared.recycle(urls) { trashed, error in
            let succeeded = Set(trashed.keys.compactMap { byURL[$0.standardizedFileURL.path] })
            let failed = error != nil
            Task { @MainActor in
                guard controller.isActive else { return }
                // Only what actually reached the Trash leaves the shelf; a file
                // that could not be moved is still there, and so is its item.
                controller.remove(succeeded.union(owned))
                guard !failed else {
                    HUD.show("Could not trash every item", symbol: "exclamationmark.triangle")
                    return
                }
                HUD.show(
                    succeeded.count == 1 ? "Moved to Trash" : "Moved \(succeeded.count) to Trash",
                    symbol: "trash"
                )
            }
        }
    }

    // MARK: - Helpers

    /// A multi-item selection can point at one file twice only through separate
    /// shelves, but opening or trashing the same URL twice is still worth not
    /// doing.
    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
