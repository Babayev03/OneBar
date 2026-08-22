import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// Per-app volume boost multiplier.
enum BoostLevel: Float, CaseIterable, Codable {
    case x1 = 1.0
    case x2 = 2.0
    case x3 = 3.0
    case x4 = 4.0

    var label: String {
        switch self {
        case .x1: "1x"
        case .x2: "2x"
        case .x3: "3x"
        case .x4: "4x"
        }
    }

    var next: BoostLevel {
        switch self {
        case .x1: .x2
        case .x2: .x3
        case .x3: .x4
        case .x4: .x1
        }
    }

    var isBoosted: Bool { self != .x1 }
}

/// Whether an app follows one destination or mirrors to several. Single keeps
/// its own optional device (`nil` means follow the macOS default); Multi keeps
/// a separate list so switching modes never forgets either choice.
enum AppOutputMode: String, Codable, CaseIterable {
    case single
    case multi
}

/// One app's saved level.
struct AppAudioSetting: Codable, Equatable {
    var bundleID: String
    var name: String
    var volume: Double
    var isMuted: Bool
    var boost: BoostLevel = .x1
    var outputDeviceUID: String? = nil
    var outputMode: AppOutputMode = .single
    var multiOutputDeviceUIDs: [String] = []

    var isDefault: Bool {
        abs(volume - 1.0) < 0.001 && !isMuted && boost == .x1
            && outputMode == .single && outputDeviceUID == nil
    }

    enum CodingKeys: String, CodingKey {
        case bundleID, name, volume, isMuted, boost, outputDeviceUID
        case outputMode, multiOutputDeviceUIDs
    }

    init(
        bundleID: String,
        name: String,
        volume: Double,
        isMuted: Bool,
        boost: BoostLevel = .x1,
        outputDeviceUID: String? = nil,
        outputMode: AppOutputMode = .single,
        multiOutputDeviceUIDs: [String] = []
    ) {
        self.bundleID = bundleID
        self.name = name
        self.volume = volume
        self.isMuted = isMuted
        self.boost = boost
        self.outputDeviceUID = outputDeviceUID
        self.outputMode = outputMode
        self.multiOutputDeviceUIDs = multiOutputDeviceUIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        name = try container.decode(String.self, forKey: .name)
        volume = try container.decode(Double.self, forKey: .volume)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        boost = try container.decodeIfPresent(BoostLevel.self, forKey: .boost) ?? .x1
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        outputMode = try container.decodeIfPresent(AppOutputMode.self, forKey: .outputMode) ?? .single
        multiOutputDeviceUIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .multiOutputDeviceUIDs
        ) ?? []
    }
}

/// Per-app volume, boost, mute, and output routing without an audio driver.
@MainActor
@Observable
final class AppAudioService {
    static let shared = AppAudioService()

    struct App: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage?
        let isPlaying: Bool
        let isRunning: Bool
        var volume: Double
        var isMuted: Bool
        var boost: BoostLevel
        var outputDeviceUID: String?
        var outputMode: AppOutputMode
        var multiOutputDeviceUIDs: [String]

        static func == (lhs: App, rhs: App) -> Bool {
            lhs.bundleID == rhs.bundleID && lhs.isPlaying == rhs.isPlaying
                && lhs.isRunning == rhs.isRunning
                && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
                && lhs.boost == rhs.boost && lhs.outputDeviceUID == rhs.outputDeviceUID
                && lhs.outputMode == rhs.outputMode
                && lhs.multiOutputDeviceUIDs == rhs.multiOutputDeviceUIDs
        }
    }

    /// The apps on the page: every one you added, plus anything currently making sound.
    private(set) var apps: [App] = []

    /// The last failure from the HAL, shown rather than swallowed.
    private(set) var lastError: String?

    @ObservationIgnored private var settings: [String: AppAudioSetting] = [:]
    /// Apps the user added by hand, which stay listed at 100% too.
    @ObservationIgnored private var pinned: Set<String> = []

    /// One mixer per app, managing its tap and aggregate device atomically.
    @ObservationIgnored private var mixers: [String: AppMixer] = [:]
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var processListener: CoreAudioListener?
    @ObservationIgnored private var processStateListeners: [AudioObjectID: CoreAudioListener] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "com.onebar.app.appaudio")
    @ObservationIgnored private var processRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var staleMixerTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var routeChangeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var routesChanging: Set<String> = []
    @ObservationIgnored private var transitionMixers: [String: AppMixer] = [:]
    @ObservationIgnored private var routeChangeGenerations: [String: Int] = [:]
    @ObservationIgnored private var outputRebuildTask: Task<Void, Never>?
    /// While the system output is changing, no process-list or device-list
    /// notification may rebuild a mixer onto the device we are releasing.
    @ObservationIgnored private var isChangingSystemOutput = false

    private init() {
        fileURL = ClipboardStore.shared.baseDirectory.appendingPathComponent("app-volumes.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([AppAudioSetting].self, from: data) {
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
            Task { @MainActor in AppAudioService.shared.scheduleProcessRefresh() }
        }
        refresh()
    }

    func tearDown() {
        processListener = nil
        processStateListeners = [:]
        processRefreshTask?.cancel()
        processRefreshTask = nil
        for task in staleMixerTasks.values { task.cancel() }
        staleMixerTasks = [:]
        for task in routeChangeTasks.values { task.cancel() }
        for (_, running) in mixers { running.stop() }
        for (_, running) in transitionMixers { running.stop() }
        mixers = [:]
        transitionMixers = [:]
        routeChangeTasks = [:]
        routesChanging = []
        routeChangeGenerations = [:]
        outputRebuildTask?.cancel()
        outputRebuildTask = nil
        apps = []
    }

    var adjustedCount: Int {
        settings.values.filter { !$0.isDefault }.count
    }

    var status: String {
        let adjusted = settings.values.filter { !$0.isDefault }
        guard !adjusted.isEmpty else { return "" }
        return adjusted
            .sorted { $0.name < $1.name }
            .map { setting in
                let mixer = mixers[setting.bundleID]
                return "\(setting.name): "
                    + (mixer?.isRunning == true ? "\(mixer?.renderCount ?? 0) renders" : "NO MIXER")
            }
            .joined(separator: " · ")
    }

    // MARK: - Which processes belong to an app

    private func processes(for setting: AppAudioSetting, live: [AudioProcess.Info]) -> [AudioObjectID] {
        var matched: [AudioProcess.Info] = []
        // FineTune only taps processes with active audio I/O. This matters most
        // for Safari: WebKit leaves several inactive CoreAudio helper objects
        // registered, and including all of them makes the tap unstable whenever
        // a tab or renderer comes and goes.
        for process in live where process.isPlaying {
            if process.bundleID == setting.bundleID
                || process.responsibleBundleID == setting.bundleID
                || process.name.caseInsensitiveCompare(setting.name) == .orderedSame {
                matched.append(process)
            }
        }
        return matched.map(\.id).sorted()
    }

    /// Process-list notifications do not fire when an existing Safari/WebKit
    /// helper merely starts or stops audio. Mirror FineTune's per-process
    /// listeners so those state changes are observed without polling.
    private func updateProcessStateListeners(_ live: [AudioProcess.Info]) {
        let current = Set(live.map(\.id))
        processStateListeners = processStateListeners.filter { current.contains($0.key) }

        for process in live where processStateListeners[process.id] == nil {
            let listener = CoreAudioListener(
                object: process.id,
                address: CoreAudioProperty.address(kAudioProcessPropertyIsRunningOutput),
                queue: queue
            ) { _, _ in
                Task { @MainActor in AppAudioService.shared.scheduleProcessRefresh() }
            }
            if let listener { processStateListeners[process.id] = listener }
        }
    }

    /// Safari commonly changes several helper states in one burst. Reconcile
    /// once after the burst rather than rebuilding against every intermediate
    /// process set.
    private func scheduleProcessRefresh() {
        processRefreshTask?.cancel()
        processRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            processRefreshTask = nil
            refresh()
        }
    }

    // MARK: - Listing

    func refresh() {
        let live = AudioProcess.all()
        updateProcessStateListeners(live)
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }

        var listed: [App] = []

        for bundleID in pinned {
            let setting = settings[bundleID] ?? AppAudioSetting(
                bundleID: bundleID, name: bundleID, volume: 1, isMuted: false
            )
            settings[bundleID] = setting
            let app = running.first { $0.bundleIdentifier == bundleID }
            listed.append(App(
                bundleID: bundleID,
                name: app?.localizedName ?? setting.name,
                icon: app?.icon ?? icon(forBundleID: bundleID),
                isPlaying: !processes(for: setting, live: live).isEmpty,
                isRunning: app != nil,
                volume: setting.volume,
                isMuted: setting.isMuted,
                boost: setting.boost,
                outputDeviceUID: setting.outputDeviceUID,
                outputMode: setting.outputMode,
                multiOutputDeviceUIDs: setting.multiOutputDeviceUIDs
            ))
        }

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
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func candidates(matching query: String = "") -> [Candidate] {
        let already = Set(apps.map(\.bundleID))
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return candidateCache.filter {
            !already.contains($0.bundleID)
                && (trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed))
        }
    }

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

    func remove(_ bundleID: String) {
        pinned.remove(bundleID)
        settings.removeValue(forKey: bundleID)
        staleMixerTasks.removeValue(forKey: bundleID)?.cancel()
        routeChangeTasks[bundleID]?.cancel()
        mixers[bundleID]?.stop()
        mixers.removeValue(forKey: bundleID)
        write()
        refresh()
    }

    // MARK: - Changing a level

    func setVolume(_ value: Double, for bundleID: String) {
        let clamped = min(max(value, 0), 1.0)
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        setting.volume = clamped
        if clamped > 0 { setting.isMuted = false }
        apply(setting)
    }

    func setBoost(_ boost: BoostLevel, for bundleID: String) {
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        setting.boost = boost
        apply(setting)
    }

    func cycleBoost(for bundleID: String) {
        let current = settings[bundleID]?.boost ?? .x1
        setBoost(current.next, for: bundleID)
    }

    func setMuted(_ muted: Bool, for bundleID: String) {
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        setting.isMuted = muted
        apply(setting)
    }

    func toggleMute(for bundleID: String) {
        setMuted(!(settings[bundleID]?.isMuted ?? false), for: bundleID)
    }

    // MARK: - Changing an output route

    func setOutputMode(_ mode: AppOutputMode, for bundleID: String) {
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        guard setting.outputMode != mode else { return }
        setting.outputMode = mode

        // Multi cannot represent "follow the system" and must never have an
        // empty destination set. Seed it from the remembered single device or
        // from the current macOS output the first time it is opened.
        if mode == .multi, setting.multiOutputDeviceUIDs.isEmpty {
            let seed = setting.outputDeviceUID
                ?? SoundService.shared.currentOutputDeviceUIDs.first
                ?? ""
            if !seed.isEmpty { setting.multiOutputDeviceUIDs = [seed] }
        }
        apply(setting, routeChanged: true)
    }

    func setSingleOutput(_ uid: String?, for bundleID: String) {
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        guard setting.outputDeviceUID != uid || setting.outputMode != .single else { return }
        setting.outputMode = .single
        setting.outputDeviceUID = uid
        apply(setting, routeChanged: true)
    }

    func toggleMultiOutput(_ uid: String, for bundleID: String) {
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        setting.outputMode = .multi

        if let index = setting.multiOutputDeviceUIDs.firstIndex(of: uid) {
            // At least one real destination is required. This avoids presenting
            // an unchecked menu while the untapped app leaks to System Audio.
            guard setting.multiOutputDeviceUIDs.count > 1 else { return }
            setting.multiOutputDeviceUIDs.remove(at: index)
        } else {
            setting.multiOutputDeviceUIDs.append(uid)
        }
        apply(setting, routeChanged: true)
    }

    private func blankSetting(for bundleID: String) -> AppAudioSetting {
        AppAudioSetting(
            bundleID: bundleID,
            name: apps.first { $0.bundleID == bundleID }?.name ?? bundleID,
            volume: 1,
            isMuted: false
        )
    }

    private func apply(_ setting: AppAudioSetting, routeChanged: Bool = false) {
        var setting = setting
        if let name = apps.first(where: { $0.bundleID == setting.bundleID })?.name {
            setting.name = name
        }

        settings[setting.bundleID] = setting
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: setting.bundleID) != nil {
            pinned.insert(setting.bundleID)
        }
        write()

        if let index = apps.firstIndex(where: { $0.bundleID == setting.bundleID }) {
            apps[index].volume = setting.volume
            apps[index].isMuted = setting.isMuted
            apps[index].boost = setting.boost
            apps[index].outputDeviceUID = setting.outputDeviceUID
            apps[index].outputMode = setting.outputMode
            apps[index].multiOutputDeviceUIDs = setting.multiOutputDeviceUIDs
        }

        if routeChanged {
            scheduleRouteRebuild(for: setting.bundleID)
        } else {
            // Direct gain update in the running RT loop without touching
            // hardware or rebuilding.
            let wantedGain = gain(for: setting)
            mixers[setting.bundleID]?.setGain(wantedGain)
        }
    }

    // MARK: - Taps & Mixers

    private func needsRendering(_ setting: AppAudioSetting?) -> Bool {
        setting != nil
    }

    private func gain(for setting: AppAudioSetting?) -> Float {
        guard let setting, !setting.isMuted else { return 0 }
        let vol = Float(setting.volume)
        let boost = setting.boost.rawValue
        // x^2 perceptual curve * boost multiplier (protected by SoftLimiter)
        return (vol * vol) * boost
    }

    private func syncTaps(live: [AudioProcess.Info]) {
        guard !isChangingSystemOutput else { return }

        let systemOutputUIDs = SoundService.shared.currentOutputDeviceUIDs
        var wanted: [String: (processes: [AudioObjectID], outputUIDs: [String])] = [:]

        for setting in settings.values where needsRendering(setting) {
            guard !routesChanging.contains(setting.bundleID) else { continue }
            let ids = processes(for: setting, live: live)
            if !ids.isEmpty {
                let targets = outputUIDs(for: setting, systemOutputUIDs: systemOutputUIDs)
                if !targets.isEmpty {
                    wanted[setting.bundleID] = (ids, targets)
                }
            }
        }

        // A brief inactive report is normal during a device change and common
        // for browser helpers. FineTune keeps stale taps alive for a grace
        // period; doing the same prevents teardown/recreation churn and lets a
        // process resume through the already-running route.
        // A route transition intentionally omits its app from `wanted` while a
        // secondary mixer is warming up. Device-list notifications fired by
        // creating that mixer must not be mistaken for the app disappearing,
        // otherwise this loop tears down the route we are crossfading from.
        for bundleID in mixers.keys
        where wanted[bundleID] == nil && !routesChanging.contains(bundleID) {
            if pinned.contains(bundleID), settings[bundleID] != nil {
                scheduleStaleMixerCleanup(for: bundleID)
            } else {
                staleMixerTasks.removeValue(forKey: bundleID)?.cancel()
                mixers[bundleID]?.stop()
                mixers.removeValue(forKey: bundleID)
            }
        }

        for (bundleID, info) in wanted {
            staleMixerTasks.removeValue(forKey: bundleID)?.cancel()
            let wantedGain = gain(for: settings[bundleID])
            if let mixer = mixers[bundleID] {
                if mixer.processIDs != info.processes || mixer.outputUIDs != info.outputUIDs {
                    // Never call `start` destructively on a live mixer. Safari
                    // helpers change more often, but any app can do this during
                    // an output handoff. Reuse the warmed secondary route.
                    scheduleRouteRebuild(for: bundleID)
                } else {
                    mixer.setGain(wantedGain)
                }
                continue
            }

            let mixer = AppMixer()
            let started = start(
                mixer,
                bundleID: bundleID,
                processIDs: info.processes,
                outputUIDs: info.outputUIDs,
                gain: wantedGain
            )
            if !started {
                lastError = "Couldn't route audio for \(settings[bundleID]?.name ?? bundleID)."
                mixer.stop()
                mixers.removeValue(forKey: bundleID)
            } else {
                lastError = nil
            }
        }
    }

    @discardableResult
    private func start(
        _ mixer: AppMixer,
        bundleID: String,
        processIDs: [AudioObjectID],
        outputUIDs: [String],
        gain: Float
    ) -> Bool {
        mixers[bundleID] = mixer
        let tapDrift = !outputUIDs.contains { SoundService.shared.isBluetooth(uid: $0) }
        return mixer.start(
            processIDs: processIDs,
            outputUIDs: outputUIDs,
            gain: gain,
            label: settings[bundleID]?.name ?? bundleID,
            tapDriftCompensation: tapDrift
        )
    }

    private func scheduleStaleMixerCleanup(for bundleID: String) {
        guard staleMixerTasks[bundleID] == nil else { return }
        staleMixerTasks[bundleID] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            staleMixerTasks[bundleID] = nil

            guard let setting = settings[bundleID], pinned.contains(bundleID) else {
                mixers.removeValue(forKey: bundleID)?.stop()
                return
            }

            // A process-state notification should normally cancel this task.
            // Re-read before destruction in case the HAL notification was lost.
            guard processes(for: setting, live: AudioProcess.all()).isEmpty else {
                refresh()
                return
            }
            if let stale = mixers.removeValue(forKey: bundleID) {
                await stale.stopAndWait()
            }
        }
    }

    private func outputUIDs(
        for setting: AppAudioSetting,
        systemOutputUIDs: [String]
    ) -> [String] {
        let available = Set(SoundService.shared.routingOutputs.map(\.uid))
        switch setting.outputMode {
        case .single:
            guard let explicit = setting.outputDeviceUID else { return systemOutputUIDs }
            // Preserve the saved preference while a device is disconnected,
            // but keep the app audible on the current output in the meantime.
            return available.contains(explicit) ? [explicit] : systemOutputUIDs
        case .multi:
            let alive = setting.multiOutputDeviceUIDs.filter { available.contains($0) }
            return alive.isEmpty ? systemOutputUIDs : alive
        }
    }

    /// FineTune-style route transition: keep the current tap alive, warm a
    /// complete secondary tap, fade between them, promote the secondary, then
    /// destroy the old route. Rapid checkbox clicks coalesce and the loop
    /// catches up to the newest persisted generation without overlapping tasks.
    private func scheduleRouteRebuild(for bundleID: String) {
        routeChangeGenerations[bundleID, default: 0] += 1
        guard routeChangeTasks[bundleID] == nil else { return }
        routesChanging.insert(bundleID)

        routeChangeTasks[bundleID] = Task { @MainActor in
            var activeMixer = mixers[bundleID]

            while !Task.isCancelled {
                let generation = routeChangeGenerations[bundleID, default: 0]
                guard let setting = settings[bundleID] else { break }
                let live = AudioProcess.all()
                let processIDs = processes(for: setting, live: live)
                let targets = outputUIDs(
                    for: setting,
                    systemOutputUIDs: SoundService.shared.currentOutputDeviceUIDs
                )

                guard !processIDs.isEmpty, !targets.isEmpty else { break }
                let wantedGain = gain(for: setting)

                if let activeMixer,
                   activeMixer.isRunning,
                   activeMixer.processIDs == processIDs,
                   activeMixer.outputUIDs == targets {
                    activeMixer.setGain(wantedGain)
                } else {
                    let replacement = AppMixer()
                    transitionMixers[bundleID] = replacement
                    let tapDrift = !targets.contains {
                        SoundService.shared.isBluetooth(uid: $0)
                    }
                    let started = replacement.start(
                        processIDs: processIDs,
                        outputUIDs: targets,
                        gain: 0,
                        label: setting.name,
                        tapDriftCompensation: tapDrift
                    )

                    guard started else {
                        transitionMixers.removeValue(forKey: bundleID)
                        lastError = "Couldn't route audio for \(setting.name)."
                        break
                    }

                    // FineTune uses a longer warmup for Bluetooth because its
                    // callback commonly starts well after AudioDeviceStart.
                    let hasBluetooth = targets.contains {
                        SoundService.shared.isBluetooth(uid: $0)
                    }
                    try? await Task.sleep(
                        for: .milliseconds(hasBluetooth ? 300 : 50)
                    )
                    guard !Task.isCancelled else {
                        activeMixer?.setGain(gain(for: settings[bundleID]))
                        break
                    }

                    // CoreAudio can report a successful start before the new
                    // aggregate is actually delivering render callbacks. Never
                    // fade away the working route unless its replacement has
                    // proven that it is alive.
                    guard replacement.renderCount > 0 else {
                        transitionMixers.removeValue(forKey: bundleID)
                        await replacement.stopAndWait()
                        activeMixer?.setGain(gain(for: settings[bundleID]))
                        lastError = "Couldn't activate the selected output for \(setting.name)."
                        break
                    }

                    // Both mixers use the same one-pole gain ramp. Starting the
                    // new route at zero and moving complementary targets avoids
                    // a step even when old and new routes share one device.
                    let latestGain = gain(for: settings[bundleID])
                    activeMixer?.setGain(0)
                    replacement.setGain(latestGain)
                    try? await Task.sleep(for: .milliseconds(120))

                    guard !Task.isCancelled else {
                        activeMixer?.setGain(gain(for: settings[bundleID]))
                        break
                    }

                    let previous = activeMixer
                    mixers[bundleID] = replacement
                    transitionMixers.removeValue(forKey: bundleID)
                    activeMixer = replacement
                    previous?.stop()
                    lastError = nil
                }

                if routeChangeGenerations[bundleID, default: 0] == generation {
                    break
                }
            }

            // The system-output switch awaits this route task. Its secondary
            // aggregate therefore has to be fully destroyed here, not merely
            // queued for asynchronous cleanup, before the task may complete.
            if let unfinished = transitionMixers.removeValue(forKey: bundleID) {
                await unfinished.stopAndWait()
            }
            routesChanging.remove(bundleID)
            routeChangeTasks[bundleID] = nil
            refresh()
        }
    }

    func outputDeviceChanged() {
        guard !isChangingSystemOutput else { return }

        let current = SoundService.shared.currentOutputDeviceUIDs
        let topology = SoundService.shared.routingOutputs.map(\.uid).sorted()
        if !hasOutputSnapshot {
            lastOutputUIDs = current
            lastRoutingOutputUIDs = topology
            hasOutputSnapshot = true
            return
        }
        let changed = current != lastOutputUIDs || topology != lastRoutingOutputUIDs
        lastOutputUIDs = current
        lastRoutingOutputUIDs = topology

        guard changed, outputRebuildTask == nil else { return }
        outputRebuildTask = Task { @MainActor in
            await prepareForSystemOutputChange()
            guard !Task.isCancelled else { return }
            finishSystemOutputChange()
            outputRebuildTask = nil
        }
    }

    @ObservationIgnored private var lastOutputUIDs: [String] = []
    @ObservationIgnored private var lastRoutingOutputUIDs: [String] = []
    @ObservationIgnored private var hasOutputSnapshot = false

    /// Quiesces any in-flight per-app crossfade before `SoundService` changes
    /// the macOS default. Established taps deliberately stay alive: explicit
    /// routes must never leak briefly to System Audio, and follows-default taps
    /// can crossfade to the accepted default afterward just as FineTune does.
    func prepareForSystemOutputChange() async {
        isChangingSystemOutput = true

        // A per-app crossfade may temporarily own both the old and new output.
        // Let its cancellation clean up the secondary before asking the HAL to
        // change the system default, or that transient aggregate can hold the
        // same device-hostage race this method exists to prevent.
        let routeTasks = Array(routeChangeTasks.values)
        for task in routeTasks { task.cancel() }
        for task in routeTasks { await task.value }

        for task in staleMixerTasks.values { task.cancel() }
        staleMixerTasks = [:]
    }

    /// Explicit and Multi routes remain untouched. A normal refresh sees only
    /// follows-System apps whose effective target changed and sends those
    /// through `scheduleRouteRebuild`, preserving continuous audio.
    func finishSystemOutputChange() {
        lastOutputUIDs = SoundService.shared.currentOutputDeviceUIDs
        lastRoutingOutputUIDs = SoundService.shared.routingOutputs.map(\.uid).sorted()
        hasOutputSnapshot = true
        isChangingSystemOutput = false
        refresh()
        scheduleProcessRefresh()
    }

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
