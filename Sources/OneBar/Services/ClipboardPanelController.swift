import AppKit
import Foundation
import Observation
import SwiftUI

/// Content filter chips shown under the search field.
enum PanelFilter: String, CaseIterable {
    case all = "All"
    case text = "Text"
    case images = "Images"
    case links = "Links"

    var next: PanelFilter {
        let all = PanelFilter.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// An action row in the popup shown under the selected clipboard item.
enum PanelAction: Equatable {
    case paste
    case pastePlain
    case openURL
    case copyImageText
    case copyQR
    case openQRLink
    case pin
    case unpin
    case delete

    var title: String {
        switch self {
        case .paste: return "Paste"
        case .pastePlain: return "Paste plain text"
        case .openURL: return "Open URL"
        case .copyImageText: return "Copy text from image"
        case .copyQR: return "Copy QR content"
        case .openQRLink: return "Open QR link"
        case .pin: return "Pin"
        case .unpin: return "Unpin"
        case .delete: return "Delete"
        }
    }

    @MainActor
    var keyLabel: String? {
        switch self {
        case .paste: return KeyBinding.keyName(ShortcutStore.shared.binding(for: .pasteOriginal).keyCode)
        case .pastePlain: return KeyBinding.keyName(ShortcutStore.shared.binding(for: .pastePlain).keyCode)
        case .openURL: return "⌘ Enter"
        case .delete: return "Delete"
        case .copyImageText, .copyQR, .openQRLink, .pin, .unpin: return nil
        }
    }

    static func actions(for item: ClipboardItem) -> [PanelAction] {
        var actions: [PanelAction] = [.paste]
        if item.kind == .text { actions.append(.pastePlain) }
        if item.url != nil { actions.append(.openURL) }
        if item.kind == .image {
            if item.ocrText != nil { actions.append(.copyImageText) }
            if item.qrPayload != nil { actions.append(.copyQR) }
            if item.qrURL != nil { actions.append(.openQRLink) }
        }
        actions.append(item.isPinned ? .unpin : .pin)
        actions.append(.delete)
        return actions
    }
}

/// Selection / search / action-popup state for the clipboard panel.
@MainActor
@Observable
final class ClipboardPanelModel {
    var searchText = ""
    var selectedID: UUID?
    var showActions = false
    var showPreview = false
    var actionIndex = 0
    var searchFieldFocused = false
    var filter: PanelFilter = .all
    /// Drives the entrance animation (content scale + card stagger).
    var isPresented = false

    var filteredItems: [ClipboardItem] {
        var all = ClipboardManager.shared.displayItems

        switch filter {
        case .all: break
        case .text: all = all.filter { $0.kind == .text }
        case .images: all = all.filter { $0.kind == .image }
        case .links: all = all.filter { $0.url != nil || $0.qrURL != nil }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { item in
            if let text = item.text, text.localizedCaseInsensitiveContains(query) { return true }
            if let ocr = item.ocrText, ocr.localizedCaseInsensitiveContains(query) { return true }
            if let qr = item.qrPayload, qr.localizedCaseInsensitiveContains(query) { return true }
            if let app = item.sourceAppName, app.localizedCaseInsensitiveContains(query) { return true }
            if item.kind == .image, "copied media".localizedCaseInsensitiveContains(query) { return true }
            return false
        }
    }

    var selectedItem: ClipboardItem? {
        filteredItems.first { $0.id == selectedID }
    }

    var selectedItemActions: [PanelAction] {
        guard let selectedItem else { return [] }
        return PanelAction.actions(for: selectedItem)
    }

    func selectFirst() {
        selectedID = filteredItems.first?.id
    }

    func moveSelection(by delta: Int) {
        // With the popup open, arrows navigate the actions instead of the list.
        if showActions {
            let count = selectedItemActions.count
            guard count > 0 else { return }
            actionIndex = min(max(actionIndex + delta, 0), count - 1)
            return
        }

        let items = filteredItems
        guard !items.isEmpty else { return }
        guard let current = selectedID, let index = items.firstIndex(where: { $0.id == current }) else {
            selectedID = items.first?.id
            return
        }
        let next = min(max(index + delta, 0), items.count - 1)
        selectedID = items[next].id
    }

    func openActions() {
        actionIndex = 0
        showActions = true
    }

    func closeActions() {
        showActions = false
        actionIndex = 0
    }

    func cycleFilter() {
        filter = filter.next
        closeActions()
        selectFirst()
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the floating clipboard-history panel and its keyboard handling.
@MainActor
final class ClipboardPanelController {
    static let shared = ClipboardPanelController()

    let model = ClipboardPanelModel()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private var isHiding = false

    nonisolated private static let savedOriginKey = "panelOrigin"

    var isVisible: Bool { panel?.isVisible ?? false }

    private init() {}

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = ensurePanel()
        model.searchText = ""
        model.filter = .all
        model.showPreview = false
        model.closeActions()
        model.selectFirst()
        model.isPresented = false
        isHiding = false

        position(panel)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // Open with the list focused, not the search field — S opts into search.
        model.searchFieldFocused = false
        panel.makeFirstResponder(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            model.isPresented = true
        }

        installMonitors()
        observeMoves(of: panel)
    }

    func hide() {
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        removeMonitors()
        stopObservingMoves()
        model.closeActions()
        model.showPreview = false
        withAnimation(.easeIn(duration: 0.12)) {
            model.isPresented = false
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.isHiding = false
            }
        })
    }

    private func position(_ panel: NSPanel) {
        // Restore where the user last dragged it, if still on a screen.
        if let saved = UserDefaults.standard.array(forKey: Self.savedOriginKey) as? [Double], saved.count == 2 {
            let origin = NSPoint(x: saved[0], y: saved[1])
            let frame = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - frame.height * 0.06
            ))
        }
    }

    private func observeMoves(of panel: NSPanel) {
        stopObservingMoves()
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            let origin = window.frame.origin
            UserDefaults.standard.set([origin.x, origin.y], forKey: Self.savedOriginKey)
        }
    }

    private func stopObservingMoves() {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ClipboardPanelView(model: model))
        self.panel = panel
        return panel
    }

    // MARK: - Actions

    func perform(_ action: PanelAction, on item: ClipboardItem) {
        switch action {
        case .paste:
            PasteService.paste(item, plainText: false)
        case .pastePlain:
            PasteService.paste(item, plainText: true)
        case .openURL:
            if let url = item.url {
                hide()
                NSWorkspace.shared.open(url)
            }
        case .copyImageText:
            if let text = item.ocrText {
                copyString(text, confirmation: "Image text copied")
            }
        case .copyQR:
            if let payload = item.qrPayload {
                copyString(payload, confirmation: "QR content copied")
            }
        case .openQRLink:
            if let url = item.qrURL {
                hide()
                NSWorkspace.shared.open(url)
            }
        case .pin, .unpin:
            ClipboardManager.shared.togglePin(item)
            model.closeActions()
        case .delete:
            deleteSelected(item)
        }
    }

    private func copyString(_ string: String, confirmation: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        hide()
        HUD.show(confirmation)
    }

    private func deleteSelected(_ item: ClipboardItem) {
        let items = model.filteredItems
        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
        ClipboardManager.shared.delete(item)
        let remaining = model.filteredItems
        model.selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        model.closeActions()
    }

    // MARK: - Event monitors

    private func installMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }
        // Click anywhere outside the panel dismisses it: global covers other
        // apps, local covers our own windows (popover, preferences).
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, event.window !== self.panel {
                    Task { @MainActor in self.hide() }
                }
                return event
            }
        }
    }

    private func removeMonitors() {
        for monitor in [keyMonitor, globalClickMonitor, localClickMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        keyMonitor = nil
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    // MARK: - Keyboard handling

    private var isEditingSearch: Bool {
        guard let responder = panel?.firstResponder else { return false }
        return responder is NSTextView
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard panel?.isKeyWindow == true else { return false }

        let store = ShortcutStore.shared
        let editing = isEditingSearch
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Esc: close preview → close popup → leave search → close panel.
        if event.keyCode == 53 {
            if model.showPreview {
                model.showPreview = false
            } else if model.showActions {
                model.closeActions()
            } else if editing {
                model.searchFieldFocused = false
                panel?.makeFirstResponder(nil)
            } else {
                hide()
            }
            return true
        }

        // Space toggles the full preview of the selected item.
        if event.keyCode == 49 && mods.isEmpty && !editing {
            if model.selectedItem != nil {
                model.closeActions()
                model.showPreview.toggle()
            }
            return true
        }

        // Tab cycles the filter chips.
        if event.keyCode == 48 && mods.isEmpty && !editing {
            withAnimation(.smooth(duration: 0.25)) {
                model.cycleFilter()
            }
            return true
        }

        // ⌘Enter opens a URL item.
        if event.keyCode == 36 && mods == [.command] {
            if let item = model.selectedItem, item.url != nil {
                perform(.openURL, on: item)
            }
            return true
        }

        if store.binding(for: .moveUp).matches(event) {
            model.moveSelection(by: -1)
            return true
        }
        if store.binding(for: .moveDown).matches(event) {
            model.moveSelection(by: 1)
            return true
        }
        if store.binding(for: .selectItem).matches(event) {
            guard let item = model.selectedItem else { return true }
            if model.showActions {
                let actions = model.selectedItemActions
                if actions.indices.contains(model.actionIndex) {
                    perform(actions[model.actionIndex], on: item)
                }
            } else {
                if editing {
                    model.searchFieldFocused = false
                    panel?.makeFirstResponder(nil)
                }
                model.showPreview = false
                model.openActions()
            }
            return true
        }
        if store.binding(for: .pastePlainDirect).matches(event) {
            if let item = model.selectedItem, item.kind == .text {
                perform(.pastePlain, on: item)
            }
            return true
        }

        // Bare-key shortcuts only apply when not typing into search.
        if !editing {
            if store.binding(for: .search).matches(event) {
                model.closeActions()
                model.showPreview = false
                model.searchFieldFocused = true
                return true
            }
            if store.binding(for: .pasteOriginal).matches(event) {
                if let item = model.selectedItem { perform(.paste, on: item) }
                return true
            }
            if store.binding(for: .pastePlain).matches(event) {
                if let item = model.selectedItem, item.kind == .text {
                    perform(.pastePlain, on: item)
                }
                return true
            }
            // Delete removes the selected item.
            if event.keyCode == 51 && mods.isEmpty {
                if let item = model.selectedItem { deleteSelected(item) }
                return true
            }
        }

        return false
    }
}
