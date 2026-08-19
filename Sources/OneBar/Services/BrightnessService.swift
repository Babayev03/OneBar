import AppKit
import CoreGraphics
import Foundation
import Observation

/// Per-display brightness, over whichever of the three mechanisms a given
/// screen actually answers to: the built-in panel through DisplayServices, an
/// external monitor through DDC/CI, and anything that won't talk DDC through
/// its gamma table.
@MainActor
@Observable
final class BrightnessService {
    static let shared = BrightnessService()

    struct Display: Identifiable {
        enum Method {
            /// Apple's own private brightness API — the built-in panel, and
            /// Apple external displays like the Studio Display, which speak no
            /// DDC either.
            case displayServices
            case ddc
            /// Faking it with the gamma table — dims the picture, not the
            /// backlight.
            case gamma
            /// AirPlay, Sidecar and friends. No backlight to command and a
            /// gamma table that is accepted then ignored — but they still
            /// composite windows, so a black window over the top is what
            /// dims them.
            case shade
            case unsupported
        }

        let id: CGDirectDisplayID
        let name: String
        let method: Method
        var brightness: Double

        var isAdjustable: Bool {
            switch method {
            case .displayServices, .ddc, .gamma, .shade: return true
            case .unsupported: return false
            }
        }
    }

    private(set) var displays: [Display] = []

    /// Gamma dimming outlives the process — whatever is in here has to be put
    /// back before OneBar quits.
    private var gammaValues: [CGDirectDisplayID: Double] = [:]

    /// Software dimming never goes all the way down: a screen you can't see is
    /// a screen you can't undim.
    private static let gammaFloor = 0.15

    /// Displays the user has pushed onto software dimming because DDC did
    /// nothing for them, keyed by something that survives a reconnect.
    private var forcedSoftware: Set<String>
    /// Last level we sent over DDC, for monitors that never answer a read.
    private var lastKnown: [CGDirectDisplayID: Double] = [:]

    private let ddc = DDCBackend()
    private var observer: NSObjectProtocol?
    private var tracker: Timer?
    /// When we last moved a display ourselves. The brightness keys ramp rather
    /// than jump, so a read taken right after our own write comes back
    /// mid-ramp and would drag the slider back under the user's finger.
    private var lastLocalChange = Date.distantPast

    private init() {
        forcedSoftware = Set(UserDefaults.standard.stringArray(forKey: "brightnessForcedSoftware") ?? [])
    }

    /// Flips one display between DDC and gamma. The probe can only guess, and
    /// on a monitor where it guesses wrong this is the way out.
    func toggleSoftwareDimming(for id: CGDirectDisplayID) {
        let key = Self.stableKey(id)
        if forcedSoftware.contains(key) {
            forcedSoftware.remove(key)
        } else {
            forcedSoftware.insert(key)
            // Leaving this display's gamma dimmed under DDC would stack the two
            // dimmings; the others must keep theirs.
            restoreDimming(for: id)
        }
        UserDefaults.standard.set(Array(forcedSoftware), forKey: "brightnessForcedSoftware")
        refresh()
    }

    func usesSoftwareDimming(_ id: CGDirectDisplayID) -> Bool {
        forcedSoftware.contains(Self.stableKey(id))
    }

    /// Display ids are handed out per connection; this survives a replug.
    private static func stableKey(_ id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in BrightnessService.shared.refresh() }
        }
        refresh()
    }

    /// Re-enumerates displays; external ones are probed off the main thread, so
    /// the list updates a moment later rather than in this call.
    func refresh() {
        guard AppState.shared.brightnessEnabled else {
            displays = []
            return
        }

        ShadeController.shared.reposition()

        let names = screenNames()
        var known: [Display] = []
        var externals: [CGDirectDisplayID] = []

        for id in onlineDisplayIDs() {
            let name = names[id] ?? "Display"
            if Self.isVirtual(id) {
                // No backlight to command, and a gamma table that is accepted
                // then ignored. A window over the top is the only lever.
                known.append(Display(
                    id: id,
                    name: name,
                    method: .shade,
                    brightness: ShadeController.shared.brightness(for: id)
                ))
            } else if DisplayServicesShim.canChangeBrightness(id) {
                known.append(Display(
                    id: id,
                    name: name,
                    method: .displayServices,
                    brightness: DisplayServicesShim.brightness(id) ?? 1
                ))
            } else {
                externals.append(id)
            }
        }

        guard !externals.isEmpty else {
            displays = known
            return
        }

        ddc.probe(externals) { [weak self] levels, wired in
            guard let self else { return }
            let fallback = AppState.shared.brightnessSoftwareFallback
            var list = known
            for id in externals {
                let name = names[id] ?? "Display"
                let forced = self.forcedSoftware.contains(Self.stableKey(id))
                if wired.contains(id), !forced {
                    // A channel means a real cable. Answering a read is a
                    // bonus — some monitors only ever listen — so an unanswered
                    // probe still gets DDC, just without a starting value.
                    list.append(Display(
                        id: id,
                        name: name,
                        method: .ddc,
                        brightness: levels[id] ?? self.lastKnown[id] ?? 1
                    ))
                } else if fallback {
                    // Gamma dies with the display's configuration, so a display
                    // we were already dimming has to be dimmed again.
                    let value = self.gammaValues[id] ?? 1
                    if value < 1 { self.applyGamma(value, to: id) }
                    list.append(Display(id: id, name: name, method: .gamma, brightness: value))
                } else {
                    list.append(Display(id: id, name: name, method: .unsupported, brightness: 1))
                }
            }
            self.displays = list
        }
    }

    /// Follows those displays while the menu is on screen: the brightness
    /// keys move it without telling anyone, and a slider that only updates when
    /// reopened looks broken. Polling beats the private change-notification
    /// callback here — reading is a cheap local call, and getting a private
    /// C callback signature wrong crashes the app.
    func startTracking() {
        guard tracker == nil, displays.contains(where: { $0.method == .displayServices }) else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            Task { @MainActor in BrightnessService.shared.pollSystemBrightness() }
        }
        // .common, or it stops dead while the menu is being tracked — which is
        // exactly when it needs to run.
        RunLoop.main.add(timer, forMode: .common)
        tracker = timer
    }

    func stopTracking() {
        tracker?.invalidate()
        tracker = nil
    }

    private func pollSystemBrightness() {
        guard Date().timeIntervalSince(lastLocalChange) > 0.4 else { return }
        for index in displays.indices where displays[index].method == .displayServices {
            guard let value = DisplayServicesShim.brightness(displays[index].id) else { continue }
            if abs(value - displays[index].brightness) > 0.001 {
                displays[index].brightness = value
            }
        }
    }

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, 0), 1)
        displays[index].brightness = clamped
        lastLocalChange = Date()

        switch displays[index].method {
        case .displayServices:
            DisplayServicesShim.setBrightness(id, to: clamped)
        case .ddc:
            lastKnown[id] = clamped
            ddc.set(clamped, for: id)
        case .gamma:
            applyGamma(clamped, to: id)
        case .shade:
            ShadeController.shared.setBrightness(clamped, for: id)
        case .unsupported:
            break
        }
    }

    /// Cheap re-read of whatever DisplayServices drives. The brightness keys
    /// move those displays without telling us, and unlike DDC this costs
    /// nothing — so the menu can do it every time it opens.
    func refreshSystemValues() {
        for index in displays.indices where displays[index].method == .displayServices {
            if let value = DisplayServicesShim.brightness(displays[index].id) {
                displays[index].brightness = value
            }
        }
    }

    /// Called on quit — a gamma table left dimmed would outlive the app and
    /// leave the user with a dark screen and nothing to fix it with. Shades die
    /// with the process, but not with a mere refresh.
    func restoreDimming() {
        ShadeController.shared.removeAll()
        guard !gammaValues.isEmpty else { return }
        CGDisplayRestoreColorSyncSettings()
        gammaValues.removeAll()
    }

    /// macOS says so itself, in the display's CoreDisplay info dictionary.
    /// The fallback is the shape of the vendor id: a real monitor's comes off
    /// its EDID chip and is 16 bits, while a display invented in software has
    /// no EDID and gets ASCII instead — AirPlay reports "aapl" / "airp".
    private static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        if let info = DDC.displayInfo(id) {
            if let virtual = info["kCGDisplayIsVirtualDevice"] as? Bool { return virtual }
            if let airPlay = info["kCGDisplayIsAirPlay"] as? Bool { return airPlay }
        }
        return CGDisplayVendorNumber(id) > 0xFFFF
    }

    /// Undims one display, leaving the rest as they are. There is no
    /// per-display gamma restore, so the others are re-applied afterwards.
    func restoreDimming(for id: CGDirectDisplayID) {
        ShadeController.shared.remove(id)
        guard gammaValues.removeValue(forKey: id) != nil else { return }
        CGDisplayRestoreColorSyncSettings()
        for (other, value) in gammaValues { applyGamma(value, to: other) }
    }

    private func applyGamma(_ value: Double, to id: CGDirectDisplayID) {
        let ceiling = CGGammaValue(Self.gammaFloor + (1 - Self.gammaFloor) * value)
        CGSetDisplayTransferByFormula(id, 0, ceiling, 1, 0, ceiling, 1, 0, ceiling, 1)
        gammaValues[id] = value
    }

    // MARK: - Enumerating displays

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        // A mirrored display shows the same picture as its primary and has no
        // slider of its own to offer.
        return ids.filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    /// `NSScreen` is the only thing that knows a display's human name ("Mi 30
    /// HFCW"), and it keys off the same display id.
    private func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
        }
        return names
    }
}

/// The DDC side, off the main actor: every exchange sleeps for tens of
/// milliseconds, and a slider drag produces far more values than a monitor can
/// swallow.
private final class DDCBackend {
    private let queue = DispatchQueue(label: "com.ilham.onebar.ddc", qos: .userInitiated)
    private let lock = NSLock()

    private var channels: [CGDirectDisplayID: DDC.Channel] = [:]
    private var maxValues: [CGDirectDisplayID: UInt16] = [:]
    private var pending: [CGDirectDisplayID: Double] = [:]
    private var draining = false

    /// Asks each display for its current brightness. Answering at all is what
    /// counts as DDC support here — a monitor that stays silent is handed to
    /// the gamma fallback.
    func probe(
        _ displayIDs: [CGDirectDisplayID],
        completion: @escaping (_ levels: [CGDirectDisplayID: Double], _ wired: Set<CGDirectDisplayID>) -> Void
    ) {
        queue.async {
            var levels: [CGDirectDisplayID: Double] = [:]
            var found: [CGDirectDisplayID: DDC.Channel] = [:]
            var maxes: [CGDirectDisplayID: UInt16] = [:]

            for (id, channel) in DDC.match(channels: DDC.channels(), to: displayIDs) {
                // Keep the channel whether or not the monitor answers: plenty
                // take writes happily while never replying to a read.
                found[id] = channel
                guard let values = DDC.read(channel, vcp: DDC.brightnessVCP) else { continue }
                let maximum = values.max == 0 ? 100 : values.max
                maxes[id] = maximum
                levels[id] = min(Double(values.current) / Double(maximum), 1)
            }

            self.lock.lock()
            self.channels = found
            self.maxValues = maxes
            self.lock.unlock()

            DispatchQueue.main.async { completion(levels, Set(found.keys)) }
        }
    }

    /// Latest value wins. Without this a drag queues a backlog of writes and
    /// the monitor keeps drifting after you've let go of the slider.
    func set(_ value: Double, for displayID: CGDirectDisplayID) {
        lock.lock()
        pending[displayID] = value
        let shouldStart = !draining
        if shouldStart { draining = true }
        lock.unlock()

        guard shouldStart else { return }
        queue.async { self.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending.first else {
                draining = false
                lock.unlock()
                return
            }
            pending.removeValue(forKey: next.key)
            let channel = channels[next.key]
            let maximum = maxValues[next.key] ?? 100
            lock.unlock()

            guard let channel else { continue }
            DDC.write(channel, vcp: DDC.brightnessVCP, value: UInt16((next.value * Double(maximum)).rounded()))
        }
    }
}
