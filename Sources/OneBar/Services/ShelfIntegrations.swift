import AppKit
import Foundation

/// The two ways into the shelf that do not involve dragging: Finder's Services
/// menu, and the `onebar://` URL scheme.
///
/// Both are declared in `Bundle/Info.plist` and both land here, because both
/// answer the same question — some files, and a request to put them somewhere.
@MainActor
final class ShelfIntegrations: NSObject {
    static let shared = ShelfIntegrations()

    private override init() { super.init() }

    func start() {
        // Registering the provider is what makes the Info.plist declaration do
        // anything. macOS caches the services list, so a newly declared entry
        // can take a moment — or a `pbs -flush` — to appear in the menu.
        NSApp.servicesProvider = self
        enableServicesOnce()
        NSUpdateDynamicServices()
    }

    // MARK: - Turning the services on

    /// macOS registers a new third-party service **disabled**, and a disabled
    /// service appears in no menu at all — so the feature looks broken until
    /// someone finds a checkbox in System Settings they had no reason to go
    /// looking for. This ticks ours once, on first run.
    ///
    /// Written exactly once ever, tracked in OneBar's own defaults rather than
    /// by whether the key is there: someone who turns these off deliberately
    /// must not find them back on at the next launch.
    ///
    /// The status dictionary's shape is measured rather than assumed — it is
    /// what System Settings itself writes when the box is ticked by hand — and
    /// its keys are built from the same `NSServices` declaration macOS read, so
    /// renaming a menu item cannot leave the key behind pointing at nothing.
    private func enableServicesOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.enabledOnceKey) else { return }
        defaults.set(true, forKey: Self.enabledOnceKey)

        let keys = Self.serviceStatusKeys
        guard !keys.isEmpty else { return }
        var status = (CFPreferencesCopyValue(
            "NSServicesStatus" as CFString,
            Self.pbsDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any]) ?? [:]

        let enabled: [String: Any] = [
            "enabled_context_menu": true,
            "enabled_services_menu": true,
            "presentation_modes": ["ContextMenu": true, "ServicesMenu": true],
        ]
        var changed = false
        for key in keys where status[key] == nil {
            status[key] = enabled
            changed = true
        }
        guard changed else { return }
        CFPreferencesSetValue(
            "NSServicesStatus" as CFString,
            status as CFDictionary,
            Self.pbsDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(Self.pbsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static let enabledOnceKey = "shelfServicesEnabledOnce"
    /// The pasteboard server's own preferences, which is where the tick in
    /// System Settings ▸ Keyboard ▸ Services is actually stored.
    private static let pbsDomain = "pbs" as CFString

    /// `<bundle id> - <menu title> - <NSMessage>`, the key System Settings
    /// writes. Read back out of `NSServices` rather than spelled out here.
    private static var serviceStatusKeys: [String] {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let services = Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]]
        else { return [] }
        return services.compactMap { service in
            guard let message = service["NSMessage"] as? String,
                  let menu = service["NSMenuItem"] as? [String: Any],
                  let title = menu["default"] as? String
            else { return nil }
            return "\(bundleID) - \(title) - \(message)"
        }
    }

    // MARK: - Services menu

    /// Finder ▸ right-click ▸ Services ▸ Add to OneBar.
    ///
    /// The signature is fixed by AppKit: the selector must take a pasteboard,
    /// a user-data string and an error pointer, and must be `@objc`.
    @objc func addToShelf(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard AppState.shared.shelfEnabled else {
            error.pointee = "The shelf is turned off in OneBar's settings." as NSString
            return
        }
        ShelfItemReader.read(from: pasteboard) { items in
            guard !items.isEmpty else {
                HUD.show("Nothing to put on a shelf", symbol: "exclamationmark.circle")
                return
            }
            Self.deliver(items, toNewShelf: userData == "new")
        }
    }

    @objc func addToNewShelf(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        addToShelf(pasteboard, userData: "new", error: error)
    }

    // MARK: - URL scheme

    /// Handles `onebar://…`.
    func handle(_ url: URL) {
        guard AppState.shared.shelfEnabled else {
            HUD.show("The shelf is turned off", symbol: "tray")
            return
        }
        switch ShelfURLCommand.parse(url) {
        case .newShelf:
            ShelfManager.shared.newShelf(at: nil)
        case .add(let paths, let text, let wantsNewShelf):
            var items = paths.compactMap {
                ShelfItemReader.fileItem(for: URL(filePath: ($0 as NSString).expandingTildeInPath))
            }
            if let text, !text.isEmpty {
                items.append(ShelfItem(kind: .text, text: text, title: String(text.prefix(60))))
            }
            guard !items.isEmpty else {
                HUD.show("Nothing at those paths", symbol: "exclamationmark.circle")
                return
            }
            Self.deliver(items, toNewShelf: wantsNewShelf)
        case .fromClipboard:
            ShelfManager.shared.newShelfFromClipboard()
        case .closeAll:
            ShelfManager.shared.closeAll()
        case .clipboardPanel:
            ClipboardPanelController.shared.toggle()
        case .unrecognised:
            // Said out loud rather than ignored: a URL scheme is something
            // people write by hand, and a typo that does nothing at all is
            // impossible to debug from the outside.
            HUD.show("OneBar did not understand that link", symbol: "questionmark.circle")
        }
    }

    // MARK: - Delivery

    /// Joins the shelf that is already open unless a new one was asked for.
    /// Sending five files from Finder one at a time should build one shelf, not
    /// five, and five is the limit.
    private static func deliver(_ items: [ShelfItem], toNewShelf: Bool) {
        let existing = toNewShelf ? nil : ShelfManager.shared.shelves.last
        guard let shelf = existing ?? ShelfManager.shared.newShelf(at: nil) else {
            ShelfStore.shared.discard(items)
            return
        }
        shelf.add(items)
    }
}
