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
