import AppKit

/// What a menu item was asked to do, carried on the item itself so one selector
/// serves the whole menu.
final class ShelfActionCommand: NSObject {
    let action: ShelfAction
    let scope: ShelfActionScope
    let applicationURL: URL?
    /// A chosen preset. Absent means the custom panel.
    let request: ImageActionRequest?

    init(
        _ action: ShelfAction,
        scope: ShelfActionScope,
        applicationURL: URL? = nil,
        request: ImageActionRequest? = nil
    ) {
        self.action = action
        self.scope = scope
        self.applicationURL = applicationURL
        self.request = request
    }
}

/// A registered script chosen from a menu. Separate from `ShelfActionCommand`
/// because a custom action is not a `ShelfAction` and never will be — the built-
/// in list is a closed enum on purpose.
final class ShelfCustomActionCommand: NSObject {
    let id: UUID
    let scope: ShelfActionScope

    init(id: UUID, scope: ShelfActionScope) {
        self.id = id
        self.scope = scope
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

    @objc func runCustomShelfAction(_ sender: NSMenuItem) {
        guard let controller,
              let command = sender.representedObject as? ShelfCustomActionCommand,
              let action = CustomActionStore.shared.action(command.id)
        else { return }
        ShelfActionRunner.runCustom(
            action,
            on: ShelfActionRunner.subject(for: command.scope, in: controller),
            in: controller
        )
    }

    @objc func runShelfAction(_ sender: NSMenuItem) {
        guard let controller,
              let command = sender.representedObject as? ShelfActionCommand
        else { return }

        if let request = command.request {
            ShelfActionRunner.convertImages(request, in: controller)
            return
        }
        if command.action == .convertImage || command.action == .resizeImage {
            ShelfActionRunner.customImageRequest(
                command.action,
                scope: command.scope,
                in: controller
            )
            return
        }
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

        let customs = CustomActionStore.shared.actions.filter { $0.isAvailable(for: subject) }
        if !customs.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for custom in customs {
                let item = NSMenuItem(
                    title: custom.name,
                    action: #selector(ShelfMenuResponder.runCustomShelfAction(_:)),
                    keyEquivalent: ""
                )
                item.target = target
                item.image = symbol(custom.symbol)
                item.representedObject = ShelfCustomActionCommand(id: custom.id, scope: scope)
                menu.addItem(item)
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

        switch action {
        case .openWith:
            item.action = nil
            item.target = nil
            item.submenu = openWithMenu(subject: subject, scope: scope, target: target)
        case .convertImage, .resizeImage:
            item.action = nil
            item.target = nil
            item.submenu = imageMenu(
                action, subject: subject, scope: scope, target: target
            )
        default:
            break
        }
        return item
    }

    /// Presets first, so the common case is one click, with the custom panel
    /// underneath for the sizes and qualities no preset list can cover.
    private static func imageMenu(
        _ action: ShelfAction,
        subject: ShelfActionSubject,
        scope: ShelfActionScope,
        target: ShelfMenuResponder
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let urls = subject.imageURLs

        if action == .convertImage {
            for format in ImageFormat.allCases {
                menu.addItem(preset(
                    title: format.title,
                    request: ImageActionRequest(urls: urls, format: format),
                    scope: scope,
                    action: action,
                    target: target
                ))
            }
        } else {
            for resize in ImageResize.presets {
                menu.addItem(preset(
                    title: resize.title,
                    // No format: a resized PNG stays a PNG.
                    request: ImageActionRequest(urls: urls, resize: resize),
                    scope: scope,
                    action: action,
                    target: target
                ))
            }
        }

        menu.addItem(.separator())
        let custom = NSMenuItem(
            title: "Custom…",
            action: #selector(ShelfMenuResponder.runShelfAction(_:)),
            keyEquivalent: ""
        )
        custom.target = target
        custom.representedObject = ShelfActionCommand(action, scope: scope)
        menu.addItem(custom)
        return menu
    }

    private static func preset(
        title: String,
        request: ImageActionRequest,
        scope: ShelfActionScope,
        action: ShelfAction,
        target: ShelfMenuResponder
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(ShelfMenuResponder.runShelfAction(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = ShelfActionCommand(
            action, scope: scope, request: request
        )
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
