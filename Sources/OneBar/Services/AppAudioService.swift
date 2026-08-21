import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// One app's saved level.
///
/// Keyed by the app you actually picked — `com.apple.Safari` — not by the
/// process that makes the noise. A browser plays through a helper
/// (`com.apple.WebKit.GPU`), Electron apps do the same, and which helper exists
/// changes from moment to moment. `AppAudioService.processes(for:)` resolves an
/// app to whatever is currently making sound on its behalf.
struct AppAudioSetting: Codable, Equatable {
    var bundleID: String
    var name: String
    var volume: Double
    var isMuted: Bool

    var isDefault: Bool { volume >= 0.999 && !isMuted }
}

/// Per-app volume and mute, without an audio driver.
///
/// Background Music and SoundSource both install a virtual sound card to become
/// the system mixer; OneBar is ad-hoc signed with no installer, so it uses
/// process taps instead (macOS 14.2+):
///
/// - **Mute** costs a tap and nothing else. Apple's header on `CATapMuted`:
///   "audio is captured by the tap but no audio is sent from the process to the
///   audio hardware". Nothing has to be rendered.
/// - **Volume** costs a real-time render loop. The app is silenced while its
///   tap is read (`.mutedWhenTapped`) and `AppMixer` plays it back quieter.
///
/// An app left at 100% and unmuted has **no tap at all**, so with nothing
/// turned down OneBar is not in the audio path.
@MainActor
@Observable
final class AppAudioService {
    static let shared = AppAudioService()

    struct App: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage?
        /// Whether anything is currently making sound on this app's behalf.
        let isPlaying: Bool
        /// Whether the app is running at all.
        let isRunning: Bool
        var volume: Double
        var isMuted: Bool

        static func == (lhs: App, rhs: App) -> Bool {
            lhs.bundleID == rhs.bundleID && lhs.isPlaying == rhs.isPlaying
                && lhs.isRunning == rhs.isRunning
                && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
        }
    }

    /// The apps on the page: every one you added, plus anything currently
    /// making sound.
    private(set) var apps: [App] = []

    /// The last failure from the HAL, shown rather than swallowed — without it
    /// a missing permission is indistinguishable from a bug.
    private(set) var lastError: String?

    @ObservationIgnored private var settings: [String: AppAudioSetting] = [:]
    /// Apps the user added by hand, which stay listed at 100% too.
    @ObservationIgnored private var pinned: Set<String> = []

    @ObservationIgnored private var taps: [String: AudioObjectID] = [:]
    @ObservationIgnored private var tapUIDs: [String: String] = [:]
    @ObservationIgnored private var tapBehaviours: [String: CATapMuteBehavior] = [:]
    /// Which audio processes each tap was built over, so it is only rebuilt
    /// when that set actually changes.
    @ObservationIgnored private var tapProcesses: [String: [AudioObjectID]] = [:]

    /// One mixer per app, so adding or removing one never interrupts another's
    /// audio and a level can never land on the wrong app.
    @ObservationIgnored private var mixers: [String: AppMixer] = [:]
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var processListener: CoreAudioListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.onebar.app.appaudio")

    private init() {
        fileURL = ClipboardStore.shared.baseDirectory.appendingPathComponent("app-volumes.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([AppAudioSetting].self, from: data) {
            // Keep only rows that name an app you could actually launch. This
            // drops two kinds of junk: daemons that hold an audio stream open
            // (com.apple.CoreSpeech), and rows an earlier version saved under
            // the *helper* process rather than its app — com.apple.WebKit.GPU
            // instead of com.apple.Safari — which could never match a running
            // app again and so sat there reading "Not running" forever.
            let usable = decoded.filter {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
            }
            settings = Dictionary(uniqueKeysWithValues: usable.map { ($0.bundleID, $0) })
            pinned = Set(usable.map(\.bundleID))
            if usable.count != decoded.count { write() }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard processListener == nil else { return }
        processListener = CoreAudioListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList),
            queue: queue
        ) { _, _ in
            Task { @MainActor in AppAudioService.shared.refresh() }
        }
        refresh()
    }

    func tearDown() {
        processListener = nil
        for (_, running) in mixers { running.stop() }
        mixers = [:]
        // A tap mutes the app it is on, so one left behind would leave an app
        // silent with nothing running to un-silence it.
        for (_, tap) in taps { AudioHardwareDestroyProcessTap(tap) }
        taps = [:]
        tapUIDs = [:]
        tapBehaviours = [:]
        tapProcesses = [:]
        apps = []
    }

    var adjustedCount: Int {
        settings.values.filter { !$0.isDefault }.count
    }

    /// What the machinery is actually doing. Not shown by default — there is a
    /// commented-out row in `SoundScreen.appsPage` that renders it when
    /// something needs diagnosing.
    ///
    /// Computed on read, never stored. Stored, it was written at the end of the
    /// same refresh that started a mixer — so a freshly started mixer was
    /// always sampled microseconds after starting and always reported zero
    /// renders, which read as "dead" when it was simply new.
    var status: String {
        let adjusted = settings.values.filter { !$0.isDefault }
        guard !adjusted.isEmpty else { return "" }
        return adjusted
            .sorted { $0.name < $1.name }
            .map { setting in
                let mixer = mixers[setting.bundleID]
                return "\(setting.name): "
                    + (taps[setting.bundleID] != nil ? "tapped" : "NO TAP")
                    + ", " + (mixer?.isRunning == true ? "\(mixer?.renderCount ?? 0) renders" : "NO MIXER")
            }
            .joined(separator: " · ")
    }

    // MARK: - Which processes belong to an app

    /// The audio processes currently playing on an app's behalf.
    ///
    /// Matches the app's own bundle id first, then falls back to any process
    /// whose cleaned-up name is the app's — which is what catches
    /// `com.apple.WebKit.GPU` for Safari and the renderer helpers for Electron
    /// apps.
    private func processes(for setting: AppAudioSetting, live: [AudioProcess.Info]) -> [AudioObjectID] {
        var matched: [AudioProcess.Info] = []
        for process in live {
            if process.bundleID == setting.bundleID
                // The system's own attribution: WebKit's GPU process is
                // Safari's responsibility, and that survives a rename.
                || process.responsibleBundleID == setting.bundleID
                || process.name.caseInsensitiveCompare(setting.name) == .orderedSame {
                matched.append(process)
            }
        }
        return matched.map(\.id).sorted()
    }

    // MARK: - Listing

    func refresh() {
        let live = AudioProcess.all()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }

        var listed: [App] = []

        // Everything the user added, running or not.
        for bundleID in pinned {
            let setting = settings[bundleID] ?? AppAudioSetting(
                bundleID: bundleID, name: bundleID, volume: 1, isMuted: false
            )
            let app = running.first { $0.bundleIdentifier == bundleID }
            listed.append(App(
                bundleID: bundleID,
                name: app?.localizedName ?? setting.name,
                icon: app?.icon ?? icon(forBundleID: bundleID),
                isPlaying: !processes(for: setting, live: live).isEmpty,
                isRunning: app != nil,
                volume: setting.volume,
                isMuted: setting.isMuted
            ))
        }

        // Nothing is listed on its own. A list that fills itself cannot also
        // have a remove button that means "stay gone" — removing an app while
        // it was playing put it straight back, which read as a broken button.
        // To change an app's level you add it first.
        apps = listed.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        syncTaps(live: live)
    }

    struct Candidate: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage?
        let isRunning: Bool
        let isPlaying: Bool
    }

    @ObservationIgnored private var candidateCache: [Candidate] = []

    /// Builds the addable list. Reads every installed app's Info.plist and
    /// icon, so it is called when the picker opens — **never** from a view
    /// body, where a hover would re-run it a hundred times a second.
    func refreshCandidates() {
        let live = AudioProcess.all()
        var found: [String: Candidate] = [:]

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            let name = app.localizedName ?? bundleID
            let playing = live.contains {
                $0.bundleID == bundleID || $0.responsibleBundleID == bundleID
                    || $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            found[bundleID] = Candidate(
                bundleID: bundleID, name: name, icon: app.icon,
                isRunning: true, isPlaying: playing
            )
        }

        for url in Self.installedApplications() {
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  found[bundleID] == nil else { continue }
            found[bundleID] = Candidate(
                bundleID: bundleID,
                name: FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: ""),
                icon: NSWorkspace.shared.icon(forFile: url.path),
                isRunning: false,
                isPlaying: false
            )
        }

        candidateCache = found.values.sorted {
            // What is already making sound is what you are most likely
            // reaching for.
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Cheap: filters the cache, nothing else. Safe to call from a view body.
    func candidates(matching query: String = "") -> [Candidate] {
        let already = Set(apps.map(\.bundleID))
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return candidateCache.filter {
            !already.contains($0.bundleID)
                && (trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed))
        }
    }

    /// Scanned once — reading a hundred Info.plists on every keystroke of a
    /// search field would be felt.
    private static let installedCache: [URL] = {
        let manager = FileManager.default
        var roots = ["/Applications", "/Applications/Utilities", "/System/Applications"]
        if let home = manager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(home.path)
        }
        var found: [URL] = []
        for root in roots {
            guard let names = try? manager.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") {
                found.append(URL(fileURLWithPath: root).appendingPathComponent(name))
            }
        }
        return found
    }()

    private static func installedApplications() -> [URL] { installedCache }

    private func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Adding and removing

    /// Puts an app on the page so it can be set before it ever plays a sound.
    func add(bundleID: String, name: String) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return }
        pinned.insert(bundleID)
        if settings[bundleID] == nil {
            settings[bundleID] = AppAudioSetting(
                bundleID: bundleID, name: name, volume: 1, isMuted: false
            )
        }
        write()
        refresh()
    }

    /// Back to untouched: no tap, no row, OneBar out of the way.
    func remove(_ bundleID: String) {
        pinned.remove(bundleID)
        settings.removeValue(forKey: bundleID)
        write()
        refresh()
    }

    // MARK: - Changing a level

    func setVolume(_ value: Double, for bundleID: String) {
        let clamped = min(max(value, 0), 1)
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        setting.volume = clamped
        // Turning it up is how you unmute, exactly as on a device.
        if clamped > 0 { setting.isMuted = false }
        apply(setting)
    }

    func setMuted(_ muted: Bool, for bundleID: String) {
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        setting.isMuted = muted
        apply(setting)
    }

    func toggleMute(for bundleID: String) {
        setMuted(!(settings[bundleID]?.isMuted ?? false), for: bundleID)
    }

    private func blankSetting(for bundleID: String) -> AppAudioSetting {
        AppAudioSetting(
            bundleID: bundleID,
            name: apps.first { $0.bundleID == bundleID }?.name ?? bundleID,
            volume: 1,
            isMuted: false
        )
    }

    private func apply(_ setting: AppAudioSetting) {
        var setting = setting
        if let name = apps.first(where: { $0.bundleID == setting.bundleID })?.name {
            setting.name = name
        }

        let wasNeeded = needsRendering(settings[setting.bundleID])
        settings[setting.bundleID] = setting
        // Touching a row is how it gets remembered — but only if it is a real
        // app, or a stray daemon row would be saved right back.
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: setting.bundleID) != nil {
            pinned.insert(setting.bundleID)
        }
        write()

        if let index = apps.firstIndex(where: { $0.bundleID == setting.bundleID }) {
            apps[index].volume = setting.volume
            apps[index].isMuted = setting.isMuted
        }

        // A level change that does not change *whether* the app is routed
        // through OneBar has no tap to build and none to drop, so it must not
        // pay for a refresh: enumerating the HAL's process list and resolving
        // each one to an app costs ~4ms, which at slider rate is most of a
        // frame. Only crossing the line — 100% and unmuted, or not — is a
        // change to the plumbing.
        if wasNeeded == needsRendering(setting) {
            // Nil while a turned-down app is not playing; it picks the level
            // up when the process listener starts one.
            mixers[setting.bundleID]?.setGain(gain(for: setting))
            return
        }

        refresh()
    }

    // MARK: - Taps

    /// Whether an app should be routed through OneBar at all.
    ///
    /// Mute used to ride on `CATapMuted` alone, on the strength of the header
    /// saying "no audio is sent from the process to the audio hardware" — and
    /// it did nothing. A tap that no one is reading appears not to be running
    /// at all, so nothing enforced the mute. Muting is now simply a gain of
    /// zero through the same path as every other level.
    ///
    /// **Only apps actually turned down or muted.** Holding the route open for
    /// every listed app was tried, to avoid the click when crossing 100%, and
    /// it cost far more than it saved: a running mixer keeps OneBar in the
    /// audio graph, and while one existed the output device could not be
    /// changed at all — an app sitting untouched at 100% silently disabled the
    /// output select. A click when you first turn something down is a much
    /// smaller price than that.
    private func needsRendering(_ setting: AppAudioSetting?) -> Bool {
        guard let setting else { return false }
        return !setting.isDefault
    }

    private func gain(for setting: AppAudioSetting?) -> Float {
        guard let setting else { return 1 }
        return setting.isMuted ? 0 : Float(setting.volume)
    }

    private func syncTaps(live: [AudioProcess.Info]) {
        var wanted: [String: [AudioObjectID]] = [:]
        for setting in settings.values where !setting.isDefault {
            let ids = processes(for: setting, live: live)
            if !ids.isEmpty { wanted[setting.bundleID] = ids }
        }

        // Drop taps for apps back at 100%, or that stopped playing entirely.
        for (bundleID, tap) in taps where wanted[bundleID] == nil {
            AudioHardwareDestroyProcessTap(tap)
            taps.removeValue(forKey: bundleID)
            tapUIDs.removeValue(forKey: bundleID)
            tapBehaviours.removeValue(forKey: bundleID)
            tapProcesses.removeValue(forKey: bundleID)
        }

        for (bundleID, processIDs) in wanted {
            // Always muted-while-read: the mixer is what puts the audio back,
            // at zero for a muted app.
            let behaviour: CATapMuteBehavior = .mutedWhenTapped

            // A tap's behaviour and its process list are both fixed at
            // creation, so either changing means a new tap.
            if taps[bundleID] != nil,
               tapBehaviours[bundleID] == behaviour,
               tapProcesses[bundleID] == processIDs {
                continue
            }
            if let existing = taps[bundleID] {
                AudioHardwareDestroyProcessTap(existing)
                taps.removeValue(forKey: bundleID)
            }

            // Plain mixdown, not the device-bound variant. The device-bound
            // one is the better-sounding API — "streams destined for the
            // selected device" — but an aggregate holding both that tap and
            // the same device never ran its render loop at all, while this one
            // is measured delivering audio.
            let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
            description.name = "OneBar \(settings[bundleID]?.name ?? bundleID)"
            description.isPrivate = true
            description.muteBehavior = behaviour
            description.uuid = UUID()

            var tapID = AudioObjectID(0)
            let status = AudioHardwareCreateProcessTap(description, &tapID)
            guard status == noErr, tapID != 0 else {
                lastError = Self.describe(status)
                continue
            }

            lastError = nil
            taps[bundleID] = tapID
            tapBehaviours[bundleID] = behaviour
            tapProcesses[bundleID] = processIDs
            tapUIDs[bundleID] = CoreAudioProperty.string(
                tapID,
                CoreAudioProperty.address(kAudioTapPropertyUID)
            ) ?? description.uuid.uuidString
        }

        rebuildMixer()
    }

    /// A four-character OSStatus reads as gibberish in decimal; the code is the
    /// only thing that says *why* the HAL refused.
    private static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        let code = printable ? "'\(String(bytes: bytes, encoding: .ascii) ?? "")'" : "\(status)"
        if status == kAudioHardwareIllegalOperationError || !printable {
            return "Couldn't read app audio (\(code)). Check System Settings → Privacy & Security → System Audio Recording."
        }
        return "Couldn't read app audio (\(code))."
    }

    /// Only apps below 100% are rendered. Each gets its own mixer; the others
    /// are torn down.
    private func rebuildMixer() {
        let outputUIDs = SoundService.shared.currentOutputDeviceUIDs
        let rendered = taps.keys.filter { needsRendering(settings[$0]) }

        for (bundleID, running) in mixers where !rendered.contains(bundleID) {
            running.stop()
            mixers.removeValue(forKey: bundleID)
        }

        for bundleID in rendered {
            guard let uid = tapUIDs[bundleID], !outputUIDs.isEmpty else { continue }
            let wanted = gain(for: settings[bundleID])

            // Leave a running mixer alone: creating a tap changes the process
            // list and creating a device changes the device list, and both
            // fire listeners that land back here. Restarting unconditionally
            // is what stopped the loop ever rendering a buffer.
            if let running = mixers[bundleID],
               running.isRunning,
               running.tapUID == uid,
               running.outputUIDs == outputUIDs {
                running.setGain(wanted)
                continue
            }

            let mixer = mixers[bundleID] ?? AppMixer()
            mixers[bundleID] = mixer
            if !mixer.start(outputUIDs: outputUIDs, tapUID: uid, gain: wanted) {
                lastError = "Couldn't start the mixer for \(settings[bundleID]?.name ?? bundleID)."
                mixers.removeValue(forKey: bundleID)
            }
        }
    }

    /// Called on every one of `SoundService`'s refreshes, which is why it has
    /// to decide for itself whether the device really changed.
    ///
    /// When it did, let go of the old device *first* and rebuild a moment
    /// later: tearing an aggregate down and standing a new one up inside the
    /// same instant the system is re-pointing its default is what let a running
    /// mixer fight the switch.
    ///
    /// When it did not, rebuild in place — `rebuildMixer` leaves a matching
    /// running mixer alone. Stepping out unconditionally here was a loop with
    /// no exit: starting a mixer creates an aggregate device, that fires the
    /// device-list listener, `SoundService.refresh()` lands back here and stops
    /// the mixer it just started. The level looked dead because every mixer was
    /// torn down 700ms after it began, forever.
    func outputDeviceChanged() {
        let current = SoundService.shared.currentOutputDeviceUIDs
        let changed = current != lastOutputUIDs
        lastOutputUIDs = current

        guard changed, !mixers.isEmpty else {
            rebuildMixer()
            return
        }

        for (_, running) in mixers { running.stop() }
        mixers = [:]

        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            rebuildMixer()
        }
    }

    /// What the mixers are currently playing into, so a refresh that changed
    /// nothing can be told apart from a real switch.
    @ObservationIgnored private var lastOutputUIDs: [String] = []
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    private func write() {
        var list: [AppAudioSetting] = []
        for bundleID in pinned {
            list.append(settings[bundleID] ?? AppAudioSetting(
                bundleID: bundleID,
                name: apps.first { $0.bundleID == bundleID }?.name ?? bundleID,
                volume: 1,
                isMuted: false
            ))
        }
        guard let data = try? JSONEncoder().encode(list.sorted { $0.bundleID < $1.bundleID }) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
