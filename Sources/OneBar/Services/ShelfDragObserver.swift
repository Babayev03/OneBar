import AppKit

/// Observes real AppKit drag sessions and independently feeds shake recognition
/// and the notch target. Ordinary mouse drags never change the drag pasteboard,
/// so window moves, video scrubbing, and rubber-band selection are ignored.
@MainActor
final class ShelfDragObserver {
    static let shared = ShelfDragObserver()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observationTimer: Timer?
    private var dragPasteboardBaseline = 0
    private var isDragSession = false

    private init() {}

    var mode: ShelfActivationMode {
        ShelfActivationMode(
            shelfEnabled: AppState.shared.shelfEnabled,
            shakeEnabled: AppState.shared.shelfShakeEnabled,
            notchEnabled: AppState.shared.shelfNotchDrop
        )
    }

    func restart() {
        stop()
        NotchDropController.shared.refreshAvailability()
        guard mode.observesDrags else { return }
        dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        startObservationTimer()
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        observationTimer?.invalidate()
        observationTimer = nil
        finishDrag()
        NotchDropController.shared.stop()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            finishDrag()
            dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
        case .leftMouseDragged:
            probeDrag()
        case .leftMouseUp:
            finishDrag()
            dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
        default:
            break
        }
    }

    /// Poll continuously while activation is enabled. Finder can hand control
    /// to its `NSDraggingSession` before a global mouse monitor receives even
    /// one dragged event, but it always updates the drag pasteboard. Watching
    /// that transition directly keeps notch activation independent of shake,
    /// ignored applications, and global-monitor timing.
    private func startObservationTimer() {
        guard observationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDragState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        observationTimer = timer
    }

    private func pollDragState() {
        if NSEvent.pressedMouseButtons & 1 != 0 {
            probeDrag()
        } else {
            finishDrag()
            dragPasteboardBaseline = NSPasteboard(name: .drag).changeCount
        }
    }

    private func probeDrag() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            finishDrag()
            return
        }

        let currentMode = mode
        guard currentMode.observesDrags else {
            finishDrag()
            return
        }

        if !isDragSession {
            guard NSPasteboard(name: .drag).changeCount != dragPasteboardBaseline else { return }
            isDragSession = true

            let ignoredForShake = ShelfManager.shared.isDraggingOut || isFrontmostAppIgnored()
            ShakeDetector.shared.dragBegan(ignored: ignoredForShake)
            if currentMode.showsNotch { NotchDropController.shared.dragBegan() }
        }

        if currentMode.recognizesShake {
            ShakeDetector.shared.dragMoved(to: NSEvent.mouseLocation)
        }
    }

    private func finishDrag() {
        guard isDragSession else { return }
        isDragSession = false
        ShakeDetector.shared.dragEnded()
        NotchDropController.shared.dragEnded()
    }

    private func isFrontmostAppIgnored() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return ShelfManager.shared.ignoredApps.contains { $0.bundleID == bundleID }
    }
}
