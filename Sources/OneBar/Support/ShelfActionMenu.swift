import AppKit

/// What a menu item was asked to do, carried on the item itself so one selector
/// serves the whole menu.
final class ShelfActionCommand: NSObject {
    let action: ShelfAction
    let scope: ShelfActionScope
    let applicationURL: URL?

    init(_ action: ShelfAction, scope: ShelfActionScope, applicationURL: URL? = nil) {
        self.action = action
        self.scope = scope
        self.applicationURL = applicationURL
    }
}

/// Target of every shelf menu item. `NSMenuItem.target` is weak, so the view
/// raising the menu owns one of these for as long as it lives.
@MainActor
final class ShelfMenuResponder: NSObject {
    weak var controller: ShelfController?
    weak var anchor: NSView?
    /// The share item is vended by a picker that has to outlive the menu.
    private var sharePicker: NSSharingServicePicker?

    init(controller: ShelfController?, anchor: NSView?) {
        self.controller = controller
        self.anchor = anchor
    }

    func shareMenuItem(for subject: ShelfActionSubject) -> NSMenuItem {
        let picker = NSSharingServicePicker(items: ShelfActionRunner.shareableItems(in: subject))
        sharePicker = picker
        return picker.standardShareMenuItem
    }

    @objc func runShelfAction(_ sender: NSMenuItem) {
        guard let controller,
              let command = sender.representedObject as? ShelfActionCommand
        else { return }

        if let application = command.applicationURL {
            ShelfActionRunner.openWith(
                application: application,
                scope: command.scope,
                in: controller
            )
            return
        }
        ShelfActionRunner.perform(
            command.action,
            scope: command.scope,
            in: controller,
            anchoredTo: anchor
        )
    }
}

@MainActor
enum ShelfActionMenu {
    static func menu(
        scope: ShelfActionScope,
        controller: ShelfController,
        target: ShelfMenuResponder
    ) -> NSMenu {
        let subject = ShelfActionRunner.subject(for: scope, in: controller)
        let menu = NSMenu()
        menu.autoenablesItems = false

        for group in ShelfAction.groups {
            let available = group.filter { $0.isAvailable(for: subject) }
            guard !available.isEmpty else { continue }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for action in available {
                menu.addItem(item(for: action, scope: scope, subject: subject, target: target))
            }
        }
        return menu
    }

    private static func item(
        for action: ShelfAction,
        scope: ShelfActionScope,
        subject: ShelfActionSubject,
        target: ShelfMenuResponder
    ) -> NSMenuItem {
        // The system's own share menu, rather than a rebuilt one: it carries
        // AirDrop, Mail, Messages and the user's own "More…" configuration.
        if action == .share {
            let item = target.shareMenuItem(for: subject)
            item.title = action.title
            item.image = symbol(action.symbol)
            return item
        }

        let item = NSMenuItem(
            title: action.title,
            action: #selector(ShelfMenuResponder.runShelfAction(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.image = symbol(action.symbol)
        item.representedObject = ShelfActionCommand(action, scope: scope)

        if action == .openWith {
            item.action = nil
            item.target = nil
            item.submenu = openWithMenu(subject: subject, scope: scope, target: target)
        }
        return item
    }

    private static func openWithMenu(
        subject: ShelfActionSubject,
        scope: ShelfActionScope,
        target: ShelfMenuResponder
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let applications = ShelfActionRunner.applications(openingAllOf: subject.fileURLs)
        guard !applications.isEmpty else {
            let empty = NSMenuItem(
                title: subject.fileURLs.count > 1
                    ? "No app opens all of these"
                    : "No app opens this",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for application in applications {
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: application.path),
                action: #selector(ShelfMenuResponder.runShelfAction(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = ShelfActionCommand(
                .openWith,
                scope: scope,
                applicationURL: application
            )
            let icon = NSWorkspace.shared.icon(forFile: application.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        return menu
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.size = NSSize(width: 15, height: 15)
        return image
    }
}
